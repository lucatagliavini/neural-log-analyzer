#!/bin/bash
#
# utils-logfiles.sh — selezione file di log per range temporale.
#
# Funzione principale:
#   select_log_files DIR BASENAME [TIME_FROM] [TIME_TO]
#
#   DIR      : directory dove cercare i file
#   BASENAME : nome base del log (es: "undertow_access_log", "gc")
#   TIME_FROM: "YYYY-MM-DDTHH:MM" (vuoto = nessun limite inferiore)
#   TIME_TO  : "YYYY-MM-DDTHH:MM" (vuoto = nessun limite superiore)
#
# Restituisce (stdout) la lista |-separata di file candidati, ordinata
# cronologicamente, che si sovrappongono al range [TIME_FROM, TIME_TO].
#
# Strategia per ogni file candidato:
#   - ts_end   = mtime del file (accurato per file ruotati/chiusi)
#   - ts_start = primo timestamp leggibile nella prima riga del file
#               (zcat|head -c4096 per gz: legge solo il primo blocco)
#   - include se l'intervallo [ts_start, ts_end] si sovrappone a [tf, tt]
#
# Gestisce qualsiasi naming di rotazione:
#   - BASENAME.log           (log corrente)
#   - BASENAME.log.0 / .1   (rotazione JVM numerata)
#   - BASENAME.log-DATE-EPOCH.gz  (rotazione per dimensione Undertow)
#   - BASENAME.DATE.log / .gz     (rotazione giornaliera)
#   - BASENAME.log-DATE-EPOCH.gz  (rotazione giornaliera compressa)
#

_logfiles_read_first_ts() {
    local f="$1"
    local line=""
    if [[ "$f" == *.gz ]]; then
        line=$(zcat "$f" 2>/dev/null | head -c 4096 | grep -m1 '')
    else
        line=$(head -1 "$f" 2>/dev/null)
    fi
    # Prova i tre formati timestamp noti:
    # access log:  [DD/Mon/YYYY:HH:MM:SS
    # gc.log:      [YYYY-MM-DDTHH:MM:SS
    # server.log:  YYYY-MM-DD HH:MM:SS,mmm
    local ts=""
    if [[ "$line" =~ \[([0-9]{2}/[A-Za-z]{3}/[0-9]{4}):([0-9]{2}):([0-9]{2}) ]]; then
        # Undertow: [29/Jul/2026:06:00:07
        local day="${BASH_REMATCH[1]%%/*}"
        local rest="${BASH_REMATCH[1]#*/}"
        local mon="${rest%%/*}"
        local yr="${rest#*/}"
        local hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
        declare -A _M=([Jan]=01 [Feb]=02 [Mar]=03 [Apr]=04 [May]=05 [Jun]=06
                       [Jul]=07 [Aug]=08 [Sep]=09 [Oct]=10 [Nov]=11 [Dec]=12)
        local mnum="${_M[$mon]:-01}"
        ts=$(date -d "${yr}-${mnum}-${day} ${hh}:${mm}:00" +%s 2>/dev/null || echo "")
    elif [[ "$line" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}) ]]; then
        # GC log: [2026-07-29T11:51:37
        ts=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null || echo "")
    elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}):([0-9]{2}) ]]; then
        # Server log (JBoss): 2026-07-29 08:01:23,456
        ts=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null || echo "")
    fi
    echo "${ts:-0}"
}

select_log_files() {
    local dir="$1"
    local base="$2"
    local tf_raw="${3:-}"
    local tt_raw="${4:-}"

    local tf_epoch=0 tt_epoch=99999999999
    [[ -n "$tf_raw" ]] && tf_epoch=$(date -d "${tf_raw//T/ }" +%s 2>/dev/null || echo 0)
    [[ -n "$tt_raw" ]] && tt_epoch=$(date -d "${tt_raw//T/ }" +%s 2>/dev/null || echo 99999999999)

    local do_filter=0
    [[ -n "$tf_raw" || -n "$tt_raw" ]] && do_filter=1

    # Raccogli tutti i candidati: qualsiasi file che inizia con BASENAME
    local -a candidates=()
    while IFS= read -r f; do
        [[ -s "$f" ]] && candidates+=("$f")
    done < <(find "$dir" -maxdepth 1 -name "${base}*" 2>/dev/null | sort)

    # Per ogni candidato: calcola [ts_start, ts_end] e filtra
    local -a selected=()
    local -A ts_start_map=()

    for f in "${candidates[@]}"; do
        local ts_end
        ts_end=$(stat -c %Y "$f" 2>/dev/null || echo 99999999999)
        # Il log corrente (non ancora ruotato) ha ts_end = adesso ≈ futuro
        [[ "$f" == "${dir}/${base}.log" || "$f" == "${dir}/${base}" ]] && ts_end=99999999999

        local ts_start
        ts_start=$(_logfiles_read_first_ts "$f")

        if [[ $do_filter -eq 1 ]]; then
            # Sovrappone se ts_start <= tt_epoch AND ts_end >= tf_epoch
            if [[ $ts_start -gt $tt_epoch || $ts_end -lt $tf_epoch ]]; then
                continue
            fi
        fi

        ts_start_map["$f"]=$ts_start
        selected+=("$f")
    done

    # Ordina per ts_start (insertion sort sugli indici)
    local n=${#selected[@]}
    for (( i=1; i<n; i++ )); do
        local key="${selected[$i]}"
        local key_ts="${ts_start_map[$key]}"
        local j=$(( i - 1 ))
        while (( j >= 0 )) && [[ "${ts_start_map[${selected[$j]}]}" -gt "$key_ts" ]]; do
            selected[$(( j+1 ))]="${selected[$j]}"
            (( j-- )) || true
        done
        selected[$(( j+1 ))]="$key"
    done

    # Output |-separato
    local out=""
    for f in "${selected[@]}"; do
        out+="${f}|"
    done
    echo "${out%|}"
}
