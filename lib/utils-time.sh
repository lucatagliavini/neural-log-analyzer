#!/bin/bash
#
# utils-time.sh — traduce espressioni temporali in linguaggio naturale
# in range ISO8601 (TIME_FROM, TIME_TO) e DATE_FILTER (YYYY-MM-DD).
#
# Uso: source lib/utils-time.sh && resolve_time_range "$query"
# Emette (via echo): TIME_FROM='...' TIME_TO='...' DATE_FILTER='...'
#
# TIME_FROM / TIME_TO: formato "YYYY-MM-DDTHH:MM" — usato dai tool AWK
# DATE_FILTER:         formato "YYYY-MM-DD"       — usato da resolve-logs.sh
#                      per selezionare il file di log ruotato corretto
#
# Compatibile con GNU date (Linux/WSL). Su AIX usa /usr/linux/bin/date se
# disponibile, altrimenti i valori restano vuoti (comportamento sicuro).
#

_date() {
    if date --version &>/dev/null 2>&1; then
        date "$@"
    elif [[ -x /usr/linux/bin/date ]]; then
        /usr/linux/bin/date "$@"
    else
        echo ""
    fi
}

resolve_time_range() {
    local query="${1,,}"
    local now_epoch now_date now_hhmm
    now_epoch=$(_date +%s 2>/dev/null) || now_epoch=""
    now_date=$(_date +%Y-%m-%d 2>/dev/null) || now_date=""
    now_hhmm=$(_date +%H:%M 2>/dev/null) || now_hhmm=""

    local time_from="" time_to="" date_filter=""

    # ── "ultime N ore" / "ultimi N minuti" ──────────────────────────────────
    if echo "$query" | grep -qE "ultim[aei] ([0-9]+) or"; then
        local h
        h=$(echo "$query" | grep -oE "([0-9]+) or" | grep -oE "[0-9]+")
        time_from=$(_date -d "@$(( now_epoch - h*3600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"
        [[ "$time_from" == *"T"* ]] || time_from=""
    elif echo "$query" | grep -qE "ultim[aei] ([0-9]+) minut"; then
        local m
        m=$(echo "$query" | grep -oE "([0-9]+) minut" | grep -oE "[0-9]+")
        time_from=$(_date -d "@$(( now_epoch - m*60 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"
        [[ "$time_from" == *"T"* ]] || time_from=""
    elif echo "$query" | grep -qE "ultim[aei] (ora|giorn|giorno)\b"; then
        if echo "$query" | grep -q "giorn"; then
            time_from="${now_date}T00:00"
            time_to="${now_date}T${now_hhmm}"
        else
            time_from=$(_date -d "@$(( now_epoch - 3600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
            time_to="${now_date}T${now_hhmm}"
            [[ "$time_from" == *"T"* ]] || time_from=""
        fi

    # ── Colloquiali intraday ─────────────────────────────────────────────────
    elif echo "$query" | grep -qE "stamatt|questa.matt|\bmattinata\b|\bdi mattina\b|\bin mattina\b"; then
        time_from="${now_date}T06:00"
        time_to="${now_date}T12:00"
    elif echo "$query" | grep -qE "questo.pomeriggio|nel.pomeriggio|\bdi pomeriggio\b|\bnel pomeriggio\b|\bpomeriggio\b"; then
        time_from="${now_date}T12:00"
        time_to="${now_date}T18:00"
    elif echo "$query" | grep -qE "stanotte|questa.notte|\bdi notte\b|\bnotturno\b"; then
        time_from="${now_date}T00:00"
        time_to="${now_date}T06:00"
    elif echo "$query" | grep -qE "questa.sera|stasera|\bdi sera\b|\bserata\b"; then
        time_from="${now_date}T18:00"
        time_to="${now_date}T23:59"
    elif echo "$query" | grep -qE "poco.fa|adesso\b|or[ae] fa"; then
        time_from=$(_date -d "@$(( now_epoch - 1800 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"
        [[ "$time_from" == *"T"* ]] || time_from=""

    # ── "ieri" ───────────────────────────────────────────────────────────────
    elif echo "$query" | grep -qE "\bieri\b"; then
        local yesterday
        yesterday=$(_date -d "yesterday" +%Y-%m-%d 2>/dev/null)
        if [[ -n "$yesterday" ]]; then
            time_from="${yesterday}T00:00"
            time_to="${yesterday}T23:59"
            date_filter="$yesterday"
        fi

    # ── "oggi" ───────────────────────────────────────────────────────────────
    elif echo "$query" | grep -qE "\boggi\b"; then
        time_from="${now_date}T00:00"
        time_to="${now_date}T${now_hhmm}"
    fi

    echo "TIME_FROM='${time_from}'"
    echo "TIME_TO='${time_to}'"
    echo "DATE_FILTER='${date_filter}'"
}
