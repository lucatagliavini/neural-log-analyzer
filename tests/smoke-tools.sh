#!/bin/bash
#
# smoke-tools.sh — esegue una query di smoke test per ogni tool disponibile.
# Lanciare sul server dopo il deploy. Ogni tool viene testato con una query
# realistica; lo script fa pausa tra una query e l'altra per permettere
# di commentare l'output in diretta.
#
# Uso:
#   bash tests/smoke-tools.sh [--profile profiles/liquido] [--tool <nome>]
#
# Opzioni:
#   --profile <dir>   profilo da usare (default: profiles/liquido)
#   --tool <nome>     esegui solo il test per questo tool
#   --no-pause        non fare pausa tra i tool (utile per redirect su file)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE="profiles/liquido"
FILTER_TOOL=""
DO_PAUSE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)  PROFILE="$2"; shift 2 ;;
        --tool)     FILTER_TOOL="$2"; shift 2 ;;
        --no-pause) DO_PAUSE=false; shift ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# ─── Lista tool con query di test ─────────────────────────────────────────────
declare -a TOOL_ORDER=(
    count_status
    distribute_status
    slow_requests
    traffic_volume
    filter_ip
    filter_errors
    filter_app_errors
    service_times
    gc_stats
    correlate_gc_slow
    tail_log
    tail_named_log
    grep_named_log
    search_all_logs
    show_help
    list_logs
)

declare -A TOOL_QUERY
TOOL_QUERY[count_status]="quanti errori 500 ci sono stati stamattina"
TOOL_QUERY[distribute_status]="quali endpoint generano più errori 5xx"
TOOL_QUERY[slow_requests]="chiamate lente di stamattina"
TOOL_QUERY[traffic_volume]="volume traffico di stamattina"
TOOL_QUERY[filter_ip]="chi ha fatto più richieste"
TOOL_QUERY[filter_errors]="errori e warning nel server log"
TOOL_QUERY[filter_app_errors]="errori applicativi nascosti"
TOOL_QUERY[service_times]="tempi dei servizi SOA di stamattina"
TOOL_QUERY[gc_stats]="statistiche GC"
TOOL_QUERY[correlate_gc_slow]="il GC sta causando lentezza?"
TOOL_QUERY[tail_log]="ultime 50 righe del log"
TOOL_QUERY[tail_named_log]="ultime 30 righe del cc.log"
TOOL_QUERY[grep_named_log]="problemi e anomalie nel cc.log"
TOOL_QUERY[search_all_logs]="cerca NullPointerException nei log"
TOOL_QUERY[show_help]="aiuto"
TOOL_QUERY[list_logs]="che log ci sono"

# ─── Filtra se --tool specificato ─────────────────────────────────────────────
if [[ -n "$FILTER_TOOL" ]]; then
    TOOL_ORDER=("$FILTER_TOOL")
fi

# ─── Intestazione ─────────────────────────────────────────────────────────────
total=${#TOOL_ORDER[@]}
inner="  Smoke test — ${total} tool — profilo: $(basename "$PROFILE")  "
width=${#inner}
border=$(printf '═%.0s' $(seq 1 "$width"))
printf "\n${BOLD}╔%s╗${RESET}\n" "$border"
printf "${BOLD}║%s║${RESET}\n"   "$inner"
printf "${BOLD}╚%s╝${RESET}\n\n" "$border"
printf "  ${DIM}Ogni query viene inviata a chatbot.sh con --query.\n"
printf "  Premi ${RESET}${BOLD}Invio${RESET}${DIM} per passare al tool successivo.${RESET}\n\n"

# ─── Loop sui tool ─────────────────────────────────────────────────────────────
idx=0
for tool in "${TOOL_ORDER[@]}"; do
    idx=$(( idx + 1 ))
    query="${TOOL_QUERY[$tool]:-}"
    if [[ -z "$query" ]]; then
        printf "${YELLOW}[SKIP]${RESET} $tool — nessuna query definita\n"
        continue
    fi

    # Separatore
    printf "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────┐${RESET}\n"
    printf "${CYAN}${BOLD}│  [%2d/%d]  %-49s│${RESET}\n" "$idx" "$total" "$tool"
    printf "${CYAN}${BOLD}│  Query:  %-49s│${RESET}\n" "\"$query\""
    printf "${CYAN}${BOLD}└─────────────────────────────────────────────────────────┘${RESET}\n\n"

    # Esegui chatbot con --query
    cd "$ROOT_DIR"
    bash chatbot.sh \
        --profile "$PROFILE" \
        --query "$query" \
        --env prod \
        --node 1 \
        2>/dev/null || true

    printf "\n${DIM}────────────────────────────────────────────────────────────${RESET}\n"

    if [[ "$DO_PAUSE" == true && "$idx" -lt "$total" ]]; then
        printf "${DIM}  [ %d/%d completato ]  Premi ${RESET}${BOLD}Invio${RESET}${DIM} per il prossimo tool...${RESET}" \
            "$idx" "$total"
        read -r _
    fi
done

printf "\n${GREEN}${BOLD}✓ Smoke test completato — %d tool testati.${RESET}\n\n" "$idx"
