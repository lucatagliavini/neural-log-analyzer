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

# Estrae e normalizza il timestamp da una singola riga di log in formato leggibile
# YYYY-MM-DD HH:MM:SS. Supporta:
#   server.log  → YYYY-MM-DD HH:MM:SS,mmm (o con T)
#   gc.log      → [YYYY-MM-DDTHH:MM:SS
#   access log  → [DD/Mon/YYYY:HH:MM:SS
# Restituisce stringa vuota se nessun formato riconosciuto.
log_ts_from_line() {
    local _line="$1" _ts
    _ts=$(echo "$_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
    if [[ -n "$_ts" ]]; then echo "${_ts/T/ }"; return; fi
    _ts=$(echo "$_line" | grep -oE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
    if [[ -n "$_ts" ]]; then
        local _d="${_ts:1:2}" _m="${_ts:4:3}" _y="${_ts:8:4}" _t="${_ts:13:8}" _mn
        case "${_m,,}" in
            jan) _mn=01;; feb) _mn=02;; mar) _mn=03;; apr) _mn=04;;
            may) _mn=05;; jun) _mn=06;; jul) _mn=07;; aug) _mn=08;;
            sep) _mn=09;; oct) _mn=10;; nov) _mn=11;; dec) _mn=12;; *) _mn="??";;
        esac
        echo "${_y}-${_mn}-${_d} ${_t}"
    fi
}

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
    elif [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}) ]]; then
        # Log Guidewire: [thread] USER 2026-08-04T15:50:01,443 INFO messaggio
        # Timestamp ISO8601 in posizione variabile, NON fra parentesi quadre e non
        # a inizio riga — nessuno dei tre pattern sopra lo catturava, quindi tutti i
        # log Guidewire davano ts_start=0 e il filtro temporale di select_log_files
        # non poteva discriminarli. Difetto preesistente, emerso testando il glob
        # sulle rotazioni (2026-08-04). Va ULTIMO: il ramo GC sopra è più specifico
        # (richiede la parentesi quadra) e deve avere precedenza.
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

# Rimuove il suffisso di rotazione dal nome di un file di log, restituendo il
# "nome logico" — la chiave per capire se due file sono lo stesso log in momenti
# diversi o due log distinti.
#   prod1nsse-cc.log                      -> prod1nsse-cc
#   prod1nsse-cc.log-2026-07-26-17850.gz  -> prod1nsse-cc
#   prod1nsse-cc.log.3.gz                 -> prod1nsse-cc
logfile_logical_name() {
    local base="${1##*/}"
    base="${base%.gz}"
    # -DATE-EPOCH oppure .N appesi dopo .log
    base=$(sed -E 's/\.log([-.].*)?$/.log/' <<< "$base")
    echo "${base%.log}"
}

# Risolve un glob in un singolo file "rappresentante", disambiguando quando il
# pattern matcha log logicamente diversi (es. "*cc*.log" → cc, ccJBatch, ccCanaliz).
#
# Distinzione necessaria: le ROTAZIONI dello stesso log vanno lette insieme (ci
# pensa select_log_files), mentre log DIVERSI richiedono una scelta. Senza questa
# distinzione un `sort | head -1` sceglierebbe silenziosamente, che è il difetto
# che questo progetto ha già pagato altrove.
#
# Uso:  path=$(resolve_log_glob DIR GLOB)
# Stampa su stdout il path scelto; l'elenco di disambiguazione va su stderr, così
# non inquina il valore di ritorno.
resolve_log_glob() {
    local dir="$1" glob="$2"
    [[ -z "$dir" || -z "$glob" ]] && return 1

    local -a matches=()
    while IFS= read -r f; do [[ -n "$f" ]] && matches+=("$f"); done \
        < <(find "$dir" -maxdepth 1 -name "$glob" 2>/dev/null | sort)
    [[ "${#matches[@]}" -eq 0 ]] && return 1

    # Raggruppa per nome logico; per ogni gruppo preferisce il file non ruotato
    local -A rep=()
    local -a order=()
    local f lname
    for f in "${matches[@]}"; do
        lname=$(logfile_logical_name "$f")
        if [[ -z "${rep[$lname]:-}" ]]; then
            rep["$lname"]="$f"
            order+=("$lname")
        fi
        # un file che finisce esattamente in .log è il corrente: ha priorità
        [[ "$f" == *.log ]] && rep["$lname"]="$f"
    done

    # La SCELTA deve essere deterministica: `order[@]` segue l'ordine di find, che
    # varia con locale e filesystem — basarsi su quello la renderebbe arbitraria
    # (verificato: sul server "*cc*.log" sceglieva ccCanaliz, in locale cc).
    # Criterio: nome logico più corto, poi alfabetico. Fra "cc", "ccCanaliz" e
    # "ccJBatch" vince "cc" — il log base, non una sua variante: l'interpretazione
    # più probabile di "*cc*". A parità di lunghezza preferisce il non-ruotato.
    local _by_len
    _by_len=$(for lname in "${order[@]}"; do printf '%d %s\n' "${#lname}" "$lname"; done \
              | sort -k1,1n -k2,2 | awk '{print $2}')
    local chosen="" _first=""
    while IFS= read -r lname; do
        [[ -z "$lname" ]] && continue
        [[ -z "$_first" ]] && _first="${rep[$lname]}"
        if [[ -z "$chosen" && "${rep[$lname]}" == *.log ]]; then chosen="${rep[$lname]}"; fi
    done <<< "$_by_len"
    [[ -z "$chosen" ]] && chosen="$_first"

    # L'ELENCO invece si presenta in ordine alfabetico: è quello che l'utente si
    # aspetta scorrendo una lista di nomi.
    local _by_name
    _by_name=$(printf '%s\n' "${order[@]}" | sort)
    order=()
    while IFS= read -r lname; do [[ -n "$lname" ]] && order+=("$lname"); done <<< "$_by_name"

    if [[ "${#order[@]}" -gt 1 ]]; then
        local _Y="\033[33m" _D="\033[2m" _X="\033[0m"
        printf "${_Y}⚠ '%s' corrisponde a %d log diversi — mostrato il primo non ruotato:${_X}\n" \
            "$glob" "${#order[@]}" >&2
        local i=1
        for lname in "${order[@]}"; do
            if [[ "$i" -gt 10 ]]; then
                printf "    ${_D}… e altri %d${_X}\n" "$(( ${#order[@]} - 10 ))" >&2
                break
            fi
            local tag=""
            [[ "${rep[$lname]}" == "$chosen" ]] && tag="  (mostrato)"
            printf "    %d) %s%s\n" "$i" "${rep[$lname]##*/}" "$tag" >&2
            i=$(( i + 1 ))
        done
        # Suggerisce il pattern che avrebbe selezionato univocamente il file scelto:
        # dal nome logico si prende il segmento dopo l'ultimo '-' (il serverID che
        # precede è la parte che l'utente non ricorda).
        local _hint
        _hint=$(logfile_logical_name "$chosen")
        printf "  ${_D}Restringi il pattern per un match univoco, es: \"*-%s.log\"${_X}\n" \
            "${_hint##*-}" >&2
    fi

    echo "$chosen"
}
