#!/bin/bash
#
# utils-time.sh — traduce espressioni temporali in linguaggio naturale
# in range ISO8601 (TIME_FROM, TIME_TO) e DATE_FILTER (YYYY-MM-DD).
#
# Uso: source lib/utils-time.sh && resolve_time_range "$query"
# Emette (via echo): TIME_FROM='...' TIME_TO='...' DATE_FILTER='...' TIME_ONLY_QUERY='0|1'
#
# TIME_ONLY_QUERY=1 se la query conteneva SOLO un'espressione temporale senza
# altri token semantici — usato da chatbot.sh per rilevare frasi di set-context
# ("dalle 10 alle 12", "ultimi 30 minuti") senza duplicare i pattern qui.
#
# TIME_FROM / TIME_TO: formato "YYYY-MM-DDTHH:MM" — usato dai tool AWK
# DATE_FILTER:         formato "YYYY-MM-DD"       — usato da resolve-logs.sh
#                      per selezionare il file di log ruotato corretto
#
# Compatibile con GNU date (Linux/WSL). Su AIX usa /usr/linux/bin/date se
# disponibile, altrimenti i valori restano vuoti (comportamento sicuro).
#

# ─── Costanti regex ───────────────────────────────────────────────────────────
#
# Ogni pattern è definito una sola volta qui.
# I branch di resolve_time_range usano solo queste costanti — mai regex inline.
# Ordine: non rilevante per la definizione, rilevante solo per la cascata elif.

# "ultime 2 ore" / "ultima 1 ora" / "ultimi 3 ore"
readonly _RE_LAST_N_HOURS="ultim[aei] [0-9]+ or[ae]"
# "ultimi 30 minuti" / "ultima 1 minuto"
readonly _RE_LAST_N_MINS="ultim[aei] [0-9]+ minut"
# "ultima ora" (singolo, senza numero)
readonly _RE_LAST_ONE_HOUR="ultim[aei] (un[a']? )?ora\b"
# "ultima giornata" / "ultimo giorno" / "ultimi giorni"
readonly _RE_LAST_DAY="ultim[aei] giorn"
# "2 giorni fa" / "3 giorni fa"
readonly _RE_N_DAYS_AGO="[0-9]+ giorn[oi] fa"
# "2 ore fa" / "3 ore fa"
readonly _RE_N_HOURS_AGO="[0-9]+ or[ae] fa"
# "30 minuti fa" / "10 minuti fa"
readonly _RE_N_MINS_AGO="[0-9]+ minut[oi] fa"
# "mezz'ora fa" / "mezzora fa" / "ultima mezzora" / "nell'ultima mezzora"
readonly _RE_HALF_HOUR_AGO="mezz.?ora fa|ultim[aei] mezz.?ora"
# "poco fa" / "adesso" / "ore fa" (generico ±30 min)
readonly _RE_JUST_NOW="poco.fa|adesso\b|or[ae] fa\b"
# Fasce colloquiali intraday
readonly _RE_MORNING="stamatt|questa.matt|\bmattinata\b|\bdi mattina\b|\bin mattina\b"
readonly _RE_AFTERNOON="questo.pomeriggio|nel.pomeriggio|\bdi pomeriggio\b|\bpomeriggio\b"
readonly _RE_NIGHT="stanotte|questa.notte|\bdi notte\b|\bnotturno\b"
readonly _RE_EVENING="questa.sera|stasera|\bdi sera\b|\bserata\b"
# "dalle HH:MM alle HH:MM" / "tra le HH e le HH" / "dalle 10 alle 14"
readonly _RE_EXPLICIT_RANGE="dalle [0-9]{1,2}(:[0-9]{2})? alle [0-9]{1,2}(:[0-9]{2})?"
# "alle 10:30" / "verso le 14" / "alle 9" — finestra ±30 min
readonly _RE_SINGLE_HOUR="(alle|verso le?) [0-9]{1,2}(:[0-9]{2})?"
# "ieri" e "oggi"
readonly _RE_YESTERDAY="\bieri\b"
readonly _RE_TODAY="\boggi\b"


# ─── Helper interni ───────────────────────────────────────────────────────────

# Wrapper GNU/AIX date — restituisce stringa vuota se date non è disponibile.
_date() {
    if date --version &>/dev/null 2>&1; then
        date "$@"
    elif [[ -x /usr/linux/bin/date ]]; then
        /usr/linux/bin/date "$@"
    else
        echo ""
    fi
}

# _qmatch QUERY PATTERN
# Testa se QUERY contiene PATTERN e restituisce la prima sottostringa matchata.
# Uso: if _m=$(_qmatch "$query" "$_RE_LAST_N_HOURS"); [[ -n "$_m" ]]; then
_qmatch() {
    echo "$1" | grep -oE "$2" | head -1
}

# _safe_int STRING
# Estrae il primo intero da STRING. Stampa 0 se nessun numero trovato.
# Il chiamante può distinguere "0 trovato" da "nessun numero" controllando
# se la stringa sorgente conteneva cifre — ma per tutti i casi d'uso correnti
# 0 è il fallback sicuro (produce time_from = time_to = adesso, filtro vuoto).
_safe_int() {
    local v; v=$(echo "$1" | grep -oE "[0-9]+" | head -1)
    echo "${v:-0}"
}

# _hhmm_to_min "HH:MM" oppure "H" (solo ora, minuti assunti 0)
# Restituisce minuti dall'inizio del giorno. Usato per _RE_EXPLICIT_RANGE.
_hhmm_to_min() {
    local s="$1"
    local h m
    if [[ "$s" == *:* ]]; then
        h="${s%%:*}"; m="${s##*:}"
    else
        h="$s"; m="0"
    fi
    echo $(( 10#$h * 60 + 10#${m:-0} ))
}

# _pad_hhmm HH MM — restituisce "HH:MM" con zero-padding
_pad_hhmm() {
    printf "%02d:%02d" "$1" "$2"
}


# ─── Funzione pubblica ────────────────────────────────────────────────────────

resolve_time_range() {
    local query="${1,,}"

    # Calcola now una volta sola — tutti i branch usano queste variabili.
    local now_epoch now_date now_hhmm
    now_epoch=$(_date +%s 2>/dev/null)  || now_epoch=""
    now_date=$(_date +%Y-%m-%d 2>/dev/null) || now_date=""
    now_hhmm=$(_date +%H:%M 2>/dev/null)    || now_hhmm=""

    local time_from="" time_to="" date_filter=""
    # Segnala se la query conteneva SOLO un'espressione temporale.
    # Viene impostato a 1 dopo il branch che produce il range, se la stringa
    # residua (query privata del match temporale) è quasi vuota (≤4 char).
    local time_only_query=0

    # I branch sono ordinati dal più specifico al più generico per evitare
    # che un pattern breve catturi per primo una frase più lunga.
    # Regola: "N giorni fa" prima di "N ore fa", "mezz'ora fa" prima di
    # "poco fa", fasce esplicite prima di quelle colloquiali.

    # ── "mezz'ora fa" ────────────────────────────────────────────────────────
    if [[ -n "$(_qmatch "$query" "$_RE_HALF_HOUR_AGO")" ]]; then
        [[ -n "$now_epoch" ]] && \
            time_from=$(_date -d "@$(( now_epoch - 1800 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"

    # ── "N minuti fa" ────────────────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_N_MINS_AGO"); [[ -n "$_m" ]]; then
        local m; m=$(_safe_int "$_m")
        if [[ "$m" -gt 0 && -n "$now_epoch" ]]; then
            time_from=$(_date -d "@$(( now_epoch - m*60 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        fi
        time_to="${now_date}T${now_hhmm}"

    # ── "N giorni fa" ────────────────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_N_DAYS_AGO"); [[ -n "$_m" ]]; then
        local d; d=$(_safe_int "$_m")
        if [[ "$d" -gt 0 ]]; then
            local target_date
            target_date=$(_date -d "$d days ago" +%Y-%m-%d 2>/dev/null)
            if [[ -n "$target_date" ]]; then
                time_from="${target_date}T00:00"
                time_to="${target_date}T23:59"
                date_filter="$target_date"
            fi
        fi

    # ── "N ore fa" ───────────────────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_N_HOURS_AGO"); [[ -n "$_m" ]]; then
        local h; h=$(_safe_int "$_m")
        if [[ "$h" -gt 0 && -n "$now_epoch" ]]; then
            time_from=$(_date -d "@$(( now_epoch - h*3600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        fi
        time_to="${now_date}T${now_hhmm}"

    # ── "ultime N ore" ───────────────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_LAST_N_HOURS"); [[ -n "$_m" ]]; then
        local h; h=$(_safe_int "$_m")
        if [[ "$h" -gt 0 && -n "$now_epoch" ]]; then
            time_from=$(_date -d "@$(( now_epoch - h*3600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        fi
        time_to="${now_date}T${now_hhmm}"

    # ── "ultimi N minuti" ────────────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_LAST_N_MINS"); [[ -n "$_m" ]]; then
        local m; m=$(_safe_int "$_m")
        if [[ "$m" -gt 0 && -n "$now_epoch" ]]; then
            time_from=$(_date -d "@$(( now_epoch - m*60 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        fi
        time_to="${now_date}T${now_hhmm}"

    # ── "ultima ora" (senza numero) ──────────────────────────────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_LAST_ONE_HOUR")" ]]; then
        [[ -n "$now_epoch" ]] && \
            time_from=$(_date -d "@$(( now_epoch - 3600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"

    # ── "ultima giornata" / "ultimo giorno" ──────────────────────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_LAST_DAY")" ]]; then
        time_from="${now_date}T00:00"
        time_to="${now_date}T${now_hhmm}"

    # ── "dalle HH:MM alle HH:MM" ─────────────────────────────────────────────
    elif _m=$(_qmatch "$query" "$_RE_EXPLICIT_RANGE"); [[ -n "$_m" ]]; then
        # Estrae i due token orari dalla sottostringa matchata usando sed posizionale:
        # "dalle 10:00 alle 14:30" → from_tok=10:00, to_tok=14:30
        # sed rimuove tutto fino a "dalle " per il primo; rimuove tutto fino all'
        # ultimo " alle " per il secondo — evita che "alle" dentro "dalle" causi match errato.
        local from_tok to_tok
        from_tok=$(echo "$_m" | sed -E 's/.*dalle //; s/ alle .*//' | grep -oE "^[0-9]{1,2}(:[0-9]{2})?")
        to_tok=$(echo   "$_m" | sed -E 's/.* alle //'               | grep -oE "^[0-9]{1,2}(:[0-9]{2})?")
        if [[ -n "$from_tok" && -n "$to_tok" ]]; then
            local from_min to_min
            from_min=$(_hhmm_to_min "$from_tok")
            to_min=$(_hhmm_to_min   "$to_tok")
            time_from="${now_date}T$(_pad_hhmm $(( from_min/60 )) $(( from_min%60 )))"
            time_to="${now_date}T$(_pad_hhmm   $(( to_min/60   )) $(( to_min%60   )))"
        fi

    # ── "alle HH:MM" / "verso le HH" — finestra ±30 min ────────────────────
    elif _m=$(_qmatch "$query" "$_RE_SINGLE_HOUR"); [[ -n "$_m" ]]; then
        local tok; tok=$(echo "$_m" | grep -oE "[0-9]{1,2}(:[0-9]{2})?")
        if [[ -n "$tok" && -n "$now_epoch" ]]; then
            local center_min; center_min=$(_hhmm_to_min "$tok")
            local from_min=$(( center_min - 30 ))
            local to_min=$(( center_min + 30 ))
            # Clamp al giorno corrente
            [[ "$from_min" -lt 0    ]] && from_min=0
            [[ "$to_min"   -gt 1439 ]] && to_min=1439
            time_from="${now_date}T$(_pad_hhmm $(( from_min/60 )) $(( from_min%60 )))"
            time_to="${now_date}T$(_pad_hhmm   $(( to_min/60   )) $(( to_min%60   )))"
        fi

    # ── "poco fa" / "adesso" / "ore fa" (generico ±30 min) ──────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_JUST_NOW")" ]]; then
        [[ -n "$now_epoch" ]] && \
            time_from=$(_date -d "@$(( now_epoch - 1800 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"

    # ── Fasce colloquiali intraday ────────────────────────────────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_MORNING")"   ]]; then
        time_from="${now_date}T06:00"; time_to="${now_date}T12:00"
    elif [[ -n "$(_qmatch "$query" "$_RE_AFTERNOON")" ]]; then
        time_from="${now_date}T12:00"; time_to="${now_date}T18:00"
    elif [[ -n "$(_qmatch "$query" "$_RE_NIGHT")"     ]]; then
        time_from="${now_date}T00:00"; time_to="${now_date}T06:00"
    elif [[ -n "$(_qmatch "$query" "$_RE_EVENING")"   ]]; then
        time_from="${now_date}T18:00"; time_to="${now_date}T23:59"

    # ── "ieri" ────────────────────────────────────────────────────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_YESTERDAY")" ]]; then
        local yesterday
        yesterday=$(_date -d "yesterday" +%Y-%m-%d 2>/dev/null)
        if [[ -n "$yesterday" ]]; then
            time_from="${yesterday}T00:00"
            time_to="${yesterday}T23:59"
            date_filter="$yesterday"
        fi

    # ── "oggi" ────────────────────────────────────────────────────────────────
    # Giorno di calendario intero (00:00→23:59), come "ieri" — non "ultime ore
    # da ora" (quello è il gruppo _RE_LAST_*). Coerente col default di sessione
    # in chatbot.sh (ACTIVE_TIME_FROM/TO inizializzati a oggi 00:00→23:59): senza
    # questo, dire "oggi" esplicitamente in una query produceva una finestra più
    # corta del default della sessione, un comportamento sorprendente segnalato
    # dall'utente (2026-08-05).
    elif [[ -n "$(_qmatch "$query" "$_RE_TODAY")" ]]; then
        time_from="${now_date}T00:00"
        time_to="${now_date}T23:59"
    fi

    # Sanity check: se _date ha restituito stringa vuota, azzera time_from
    # (preferibile a passare un timestamp vuoto a mktime in AWK).
    [[ "$time_from" != *"T"* ]] && time_from=""
    [[ "$time_to"   != *"T"* ]] && time_to=""

    # TIME_ONLY_QUERY: 1 se la query conteneva solo un'espressione temporale.
    # Metodo: rimuovi il match temporale trovato dalla query; se il residuo è
    # quasi vuoto (≤4 char non-spazio) la query era solo-temporale.
    # Questo calcolo avviene UNA VOLTA qui, dopo tutti i branch, usando i
    # pattern già definiti — nessuna duplicazione nel chiamante.
    if [[ -n "$time_from" ]]; then
        local _temporal_patterns=(
            "$_RE_HALF_HOUR_AGO"   "$_RE_N_MINS_AGO"    "$_RE_N_HOURS_AGO"
            "$_RE_N_DAYS_AGO"      "$_RE_LAST_N_HOURS"  "$_RE_LAST_N_MINS"
            "$_RE_LAST_ONE_HOUR"   "$_RE_LAST_DAY"      "$_RE_EXPLICIT_RANGE"
            "$_RE_SINGLE_HOUR"     "$_RE_JUST_NOW"
            "$_RE_MORNING"         "$_RE_AFTERNOON"     "$_RE_NIGHT"
            "$_RE_EVENING"         "$_RE_YESTERDAY"     "$_RE_TODAY"
        )
        local _residuo="$query"
        for _pat in "${_temporal_patterns[@]}"; do
            _residuo=$(echo "$_residuo" | sed -E "s/${_pat}//gI")
        done
        # Rimuovi anche articoli/preposizioni rimasti dopo lo strip del pattern
        _residuo=$(echo "$_residuo" | sed -E "s/\b(di|in|nel|nell|dalle|alle|verso|le|la|il|lo|un|una|e|o|ma|per|su|da|con|tra|fra|a)\b//gI; s/'//g" | tr -s ' ' | sed 's/^ *//; s/ *$//')
        [[ ${#_residuo} -le 4 ]] && time_only_query=1
    fi

    echo "TIME_FROM='${time_from}'"
    echo "TIME_TO='${time_to}'"
    echo "DATE_FILTER='${date_filter}'"
    echo "TIME_ONLY_QUERY='${time_only_query}'"
}
