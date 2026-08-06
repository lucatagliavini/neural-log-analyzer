#!/bin/bash
#
# perf-report.sh — analisi offline dei tempi di risposta dal query log.
#
# Legge i TSV prodotti da log_query() (chatbot.sh) in QUERY_LOG_DIR e aggrega
# i tempi per tool, per fase e per volume di dati, per capire DOVE va il tempo
# prima di ottimizzare a naso.
#
# Uso:
#   ./perf-report.sh [--profile <dir>] [--log-dir <dir>] [--tool <nome>] [--slowest N]
#
# --log-dir   sovrascrive QUERY_LOG_DIR del profilo
# --tool      filtra su un singolo tool (es. search_all_logs)
# --slowest   mostra le N query più lente (default 10)
#
# Colonne attese nel TSV (contratto documentato in chatbot.sh:log_query):
#   1 ts  2 env  3 node  4 query  5 tools  6 profilo  7 totale_ms
#   8 select_ms  9 search_ms  10 file  11 file_match  12 byte  13 worker
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles/liquido"
LOG_DIR=""
FILTER_TOOL=""
SLOWEST=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --tool)    FILTER_TOOL="$2"; shift 2 ;;
        --slowest) SLOWEST="$2"; shift 2 ;;
        -h|--help) grep "^#" "$0" | grep -v "^#!" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$LOG_DIR" ]]; then
    [[ -f "$PROFILE_DIR/system.conf" ]] && source "$PROFILE_DIR/system.conf"
    LOG_DIR="${QUERY_LOG_DIR:-}"
fi

if [[ -z "$LOG_DIR" ]]; then
    echo "[ERROR] QUERY_LOG_DIR non impostato in $PROFILE_DIR/system.conf" >&2
    echo "        Impostalo (es. QUERY_LOG_DIR=/product/lana-bot/logs) o usa --log-dir." >&2
    exit 1
fi
if [[ ! -d "$LOG_DIR" ]]; then
    echo "[ERROR] directory log non trovata: $LOG_DIR" >&2
    exit 1
fi

_B="\033[1m" _D="\033[2m" _Y="\033[33m" _G="\033[32m" _X="\033[0m"

_rows=$(cat "$LOG_DIR"/chatbot-*.log 2>/dev/null | awk -F'\t' -v t="$FILTER_TOOL" '
    NF >= 13 && (t == "" || index($5, t) > 0)')

if [[ -z "$_rows" ]]; then
    printf "${_Y}Nessuna riga con metriche di performance in %s${_X}\n" "$LOG_DIR"
    printf "${_D}Le colonne di timing esistono dal 2026-08-06: le righe precedenti hanno 6 campi e vengono ignorate.${_X}\n"
    exit 0
fi

printf "\n${_B}Report performance${_X}  ${_D}%s${_X}\n" "$LOG_DIR"
[[ -n "$FILTER_TOOL" ]] && printf "${_D}filtro tool: %s${_X}\n" "$FILTER_TOOL"

# ─── Aggregato per tool ───────────────────────────────────────────────────────
printf "\n${_B}Per tool${_X}  ${_D}(mediana e p95 sui tempi totali)${_X}\n"
printf "${_D}%-22s %6s %9s %9s %9s %9s${_X}\n" "TOOL" "QUERY" "MEDIANA" "p95" "MAX" "MEDIA"
printf "${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 70))"
awk -F'\t' '
    {
        # $5 = "tool1:96%,tool2:80%" — la chiave è il primo tool (il dominante)
        split($5, a, ",")
        split(a[1], b, ":")
        tool = b[1]
        times[tool] = times[tool] " " $7
        n[tool]++
        sum[tool] += $7
    }
    END {
        for (t in times) {
            cnt = split(times[t], arr, " ")
            # arr può avere elementi vuoti dallo spazio iniziale: compatta
            m = 0
            for (i = 1; i <= cnt; i++) if (arr[i] != "") v[++m] = arr[i] + 0
            # insertion sort (poche decine di elementi per tool)
            for (i = 2; i <= m; i++) {
                k = v[i]; j = i - 1
                while (j > 0 && v[j] > k) { v[j+1] = v[j]; j-- }
                v[j+1] = k
            }
            med = v[int((m + 1) / 2)]
            p95 = v[int(m * 0.95) < 1 ? 1 : int(m * 0.95)]
            printf "%-22s %6d %8dms %8dms %8dms %8dms\n", t, n[t], med, p95, v[m], sum[t] / n[t]
            delete v
        }
    }' <<< "$_rows" | sort -k4 -rn

# ─── Scomposizione per fase (solo righe che hanno le metriche di fase) ────────
printf "\n${_B}Scomposizione fasi${_X}  ${_D}(solo query con metriche di fase, es. search_all_logs)${_X}\n"
awk -F'\t' '
    ($8 + $9) > 0 {
        n++
        sel += $8; sea += $9; tot += $7
        files += $10; matched += $11; bytes += $12
    }
    END {
        if (n == 0) { print "  (nessuna)"; exit }
        other = tot - sel - sea
        printf "  query con metriche di fase: %d\n", n
        printf "  selezione log:   %7dms medi  (%4.1f%% del totale)\n", sel/n, 100*sel/tot
        printf "  ricerca/analisi: %7dms medi  (%4.1f%% del totale)\n", sea/n, 100*sea/tot
        printf "  altro (nnet, setup, render): %dms medi  (%4.1f%%)\n", other/n, 100*other/tot
        printf "  volume medio: %d file (%d con match), %.1f MB\n", files/n, matched/n, bytes/n/1048576
        if (bytes > 0) printf "  throughput: %.1f MB/s nella fase di ricerca\n", (bytes/1048576)/(sea/1000)
    }' <<< "$_rows"

# ─── Query più lente ──────────────────────────────────────────────────────────
printf "\n${_B}Le %s query più lente${_X}\n" "$SLOWEST"
printf "${_D}%9s %6s %6s %5s  %s${_X}\n" "TOTALE" "SEL" "SEARCH" "FILE" "QUERY"
printf "${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 78))"
sort -t$'\t' -k7 -rn <<< "$_rows" | head -"$SLOWEST" | \
    awk -F'\t' '{ q = substr($4, 1, 44); printf "%7dms %5dms %5dms %5d  %s\n", $7, $8, $9, $10, q }'

# ─── Correlazione volume/tempo, per capire se scala linearmente ───────────────
printf "\n${_B}Tempo per MB${_X}  ${_D}(se cresce col volume, non scala linearmente)${_X}\n"
awk -F'\t' '
    $12 > 1048576 && $9 > 0 {
        mb = $12 / 1048576
        bucket = (mb < 10 ? "  <10 MB" : (mb < 50 ? " 10-50 MB" : (mb < 200 ? " 50-200 MB" : "  >200 MB")))
        n[bucket]++; t[bucket] += $9; v[bucket] += mb
    }
    END {
        if (length(n) == 0) { print "  (nessuna query sopra 1 MB)"; exit }
        for (b in n) printf "  %-11s %3d query  %7.1f ms/MB\n", b, n[b], t[b] / v[b]
    }' <<< "$_rows" | sort

echo ""
