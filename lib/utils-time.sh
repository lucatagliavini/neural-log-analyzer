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
# DATE_FILTER:         formato "YYYY-MM-DD"
#
#   ⚠️ DATE_FILTER è VESTIGIALE (verificato 2026-08-20). Questo commento diceva
#   "usato da resolve-logs.sh per selezionare il file di log ruotato corretto":
#   è falso. chatbot.sh:242 lo passa a resolve-logs.sh come variabile d'ambiente,
#   ma resolve-logs.sh non lo legge in nessun punto (grep a zero). La selezione
#   delle rotazioni la fa il walk temporale di select_log_files_grouped() su
#   TIME_FROM/TIME_TO (LOGDISC-4), non questa variabile.
#
#   L'unico effetto vivo è chatbot.sh:398, dove un cambio di DATE_FILTER forza
#   ctx_changed=1 e quindi una nuova risoluzione della sessione — che ricalcola
#   gli stessi path. Resta emesso perché quel segnale di "il contesto è cambiato"
#   è usato, ma non va descritto come un selettore di file: chi lo leggesse così
#   cercherebbe un bug di selezione rotazioni nel posto sbagliato.
#
# Compatibile con GNU date (Linux/WSL). Su AIX usa /usr/linux/bin/date se
# disponibile, altrimenti i valori restano vuoti (comportamento sicuro).
#

# ─── Costanti regex ───────────────────────────────────────────────────────────
#
# Ogni pattern è definito una sola volta qui.
# I branch di resolve_time_range usano solo queste costanti — mai regex inline.
# Ordine: non rilevante per la definizione, rilevante solo per la cascata elif.

# La classe di caratteri include SEMPRE la 'o' del maschile singolare: con
# `ultim[aei]` la forma "ultimo giorno" — grammaticalmente corretta e già
# dichiarata supportata nel commento di _RE_LAST_DAY — non matchava nulla, e la
# query finiva senza alcun filtro temporale (quindi con il default di sessione,
# silenziosamente più larga di quanto chiesto). Il filtro non falliva: si
# disattivava, che è la firma di FORMAT-1 su un'altra superficie.
#
# "ultime 2 ore" / "ultima 1 ora" / "ultimi 3 ore"
readonly _RE_LAST_N_HOURS="ultim[aeio] [0-9]+ or[ae]"
# "ultimi 30 minuti" / "ultima 1 minuto"
readonly _RE_LAST_N_MINS="ultim[aeio] [0-9]+ minut"
# "ultima ora" (singolo, senza numero)
readonly _RE_LAST_ONE_HOUR="ultim[aeio] (un[a']? )?ora\b"
# "ultima giornata" / "ultimo giorno" / "ultimi giorni"
readonly _RE_LAST_DAY="ultim[aeio] giorn"
# "2 giorni fa" / "3 giorni fa"
readonly _RE_N_DAYS_AGO="[0-9]+ giorn[oi] fa"
# "2 ore fa" / "3 ore fa"
readonly _RE_N_HOURS_AGO="[0-9]+ or[ae] fa"
# "30 minuti fa" / "10 minuti fa"
readonly _RE_N_MINS_AGO="[0-9]+ minut[oi] fa"
# "mezz'ora fa" / "mezzora fa" / "ultima mezzora" / "nell'ultima mezzora"
readonly _RE_HALF_HOUR_AGO="mezz.?ora fa|ultim[aeio] mezz.?ora"
# "poco fa" / "adesso" / "ore fa" (generico ±30 min)
readonly _RE_JUST_NOW="poco.fa|adesso\b|or[ae] fa\b"
# Fasce colloquiali intraday.
#
# Ogni fascia accetta anche la parola NUDA ("mattina", "sera", "notte"), non solo
# le forme con determinante ("di mattina", "questa sera"). Prima solo
# _RE_AFTERNOON aveva `\bpomeriggio\b` nudo, e l'asimmetria — non progettata, un
# accidente di scrittura delle regex — produceva due difetti diversi sulla stessa
# frase: "ieri pomeriggio" entrava nel branch della fascia e prendeva la data di
# OGGI (giorno sbagliato), mentre "ieri mattina" non matchava, cadeva sul branch
# del giorno e restituiva la giornata intera (fascia persa). Con la parola nuda in
# tutte e quattro, più la separazione giorno/ora sotto, le due frasi si comportano
# allo stesso modo.
readonly _RE_MORNING="stamatt|questa.matt|\bmattinata\b|\bmattina\b|\bmattino\b"
readonly _RE_AFTERNOON="questo.pomeriggio|nel.pomeriggio|\bpomeriggio\b"
readonly _RE_NIGHT="stanotte|questa.notte|\bnotte\b|\bnotturno\b"
readonly _RE_EVENING="questa.sera|stasera|\bserata\b|\bsera\b"
# "dalle HH:MM alle HH:MM" / "tra le HH e le HH" / "dalle 10 alle 14"
#
# La forma "tra le X e le Y" era dichiarata qui nel commento da sempre ma non
# esisteva nella regex: la query cadeva fuori da ogni branch e restava senza
# filtro. Aggiunta come alternativa, con gli stessi due gruppi orari.
readonly _RE_EXPLICIT_RANGE="dalle [0-9]{1,2}(:[0-9]{2})? alle [0-9]{1,2}(:[0-9]{2})?|(tra|fra) le [0-9]{1,2}(:[0-9]{2})? e le [0-9]{1,2}(:[0-9]{2})?"
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
# Restituisce minuti dall'inizio del giorno, oppure -1 se l'orario non è valido.
#
# La validazione (h≤23, m≤59) non è difensiva: senza, "alle 99" produceva
# TIME_FROM='...T98:30' e mktime() in AWK NORMALIZZA i valori fuori scala, quindi
# l'ora 98 diventava un istante 4 giorni nel futuro. La query cercava
# silenziosamente in una finestra dove non esistono log — falso negativo, non
# errore. Un orario impossibile deve produrre "nessun range" (e quindi il default
# di sessione), non un range inventato.
_hhmm_to_min() {
    local s="$1"
    local h m
    if [[ "$s" == *:* ]]; then
        h="${s%%:*}"; m="${s##*:}"
    else
        h="$s"; m="0"
    fi
    h=$(( 10#$h )); m=$(( 10#${m:-0} ))
    if (( h < 0 || h > 23 || m < 0 || m > 59 )); then
        echo "-1"; return
    fi
    echo $(( h * 60 + m ))
}

# _pad_hhmm HH MM — restituisce "HH:MM" con zero-padding
_pad_hhmm() {
    printf "%02d:%02d" "$1" "$2"
}

# _min_to_hhmm MINUTI — minuti dall'inizio del giorno → "HH:MM"
_min_to_hhmm() { _pad_hhmm $(( $1 / 60 )) $(( $1 % 60 )); }

# _day_window BASE_DATE FROM_MIN TO_MIN → "FROM_ISO TO_ISO"
# Finestra interamente dentro un giorno. Usata dalle fasce colloquiali e dal
# giorno pieno: entrambe sono porzioni NOMINATE di un giorno, mai a cavallo.
_day_window() {
    echo "${1}T$(_min_to_hhmm "$2") ${1}T$(_min_to_hhmm "$3")"
}

# _range_window BASE_DATE FROM_MIN TO_MIN DAY_EXPLICIT NOW_EPOCH → "FROM_ISO TO_ISO"
#
# Finestra da un range esplicito ("dalle X alle Y"), che è l'unica forma capace di
# attraversare la mezzanotte. Due regole, applicate in quest'ordine:
#
#   1. to ≤ from  →  il range attraversa la mezzanotte: `to` va al giorno
#      successivo. Prima entrambi gli estremi erano ancorati allo stesso giorno,
#      quindi "dalle 22 alle 2" produceva from > to: un intervallo VUOTO, su cui
#      in_range() restituisce sempre 0 e il tool risponde "nessun risultato nel
#      periodo" — un falso negativo pieno su una frase legittima.
#
#   2. se il giorno NON è nominato e `from` cade nel futuro → arretra di un
#      giorno. È la regola indicata dall'utente (2026-08-20): alle 21:00
#      "dalle 22 alle 2" significa la notte APPENA passata (ieri 22:00 → oggi
#      02:00), perché le 22 di oggi non sono ancora arrivate; alle 23:00 la stessa
#      frase significa "dalle 22, un'ora fa, fino alle 2" (oggi 22:00 → domani
#      02:00, che comprende ora). Una regola sola, due esiti.
#
# L'arretramento vale SOLO quando la finestra è interamente futura (from > now):
# se contiene già dati — anche solo in parte — arretrare li butterebbe via
# (principio 5). Per questo un range che non attraversa la mezzanotte non viene
# mai spostato, e il comportamento preesistente resta identico.
#
# L'aritmetica sulle date passa da date(1) (`-1 day`, `+1 day`) e non da ±86400
# secondi: attraverso un cambio di ora legale l'offset fisso sposterebbe l'orario
# di parete di un'ora.
_range_window() {
    local base="$1" fmin="$2" tmin="$3" day_explicit="$4" now_ep="$5"
    local from_date="$base" to_date="$base"
    local crosses=0

    if (( tmin <= fmin )); then
        crosses=1
        to_date=$(_date -d "$base +1 day" +%Y-%m-%d 2>/dev/null) || to_date="$base"
    fi

    # L'arretramento vale SOLO per un range che attraversa la mezzanotte. Su un
    # range normale sarebbe una sorpresa: "dalle 10:30 alle 14:45" chiesto alle
    # 09:00 risponderebbe su IERI, pur avendo l'utente nominato ore di oggi —
    # e il difetto sarebbe invisibile, perché la risposta è ben formata. Un range
    # che non attraversa la mezzanotte non è ambiguo, quindi non va disambiguato:
    # qui il comportamento resta bit-identico a prima di questo intervento.
    if (( crosses == 1 && day_explicit == 0 )) && [[ -n "$now_ep" ]]; then
        local from_ep
        from_ep=$(_date -d "$from_date $(_min_to_hhmm "$fmin")" +%s 2>/dev/null)
        if [[ -n "$from_ep" ]] && (( from_ep > now_ep )); then
            from_date=$(_date -d "$from_date -1 day" +%Y-%m-%d 2>/dev/null) || :
            to_date=$(_date   -d "$to_date -1 day"   +%Y-%m-%d 2>/dev/null) || :
        fi
    fi

    echo "${from_date}T$(_min_to_hhmm "$fmin") ${to_date}T$(_min_to_hhmm "$tmin")"
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

    # ─── Fase 1 — l'ANCORA DI GIORNO ─────────────────────────────────────────
    #
    # Il giorno e l'ora del giorno sono due DIMENSIONI INDIPENDENTI di una
    # espressione temporale: "ieri" fissa il giorno, "pomeriggio" fissa la fascia,
    # "ieri pomeriggio" fissa entrambi. Prima erano rami alternativi della stessa
    # cascata, quindi mutuamente esclusivi — e una frase che nominava l'uno e
    # l'altro ne perdeva necessariamente uno dei due:
    #
    #   "ieri pomeriggio"     → fascia di OGGI    (giorno perso, risposta sul
    #                                              giorno sbagliato)
    #   "ieri mattina"        → giornata di ieri  (fascia persa, finestra 4× più
    #                                              larga del richiesto)
    #   "ieri alle 10"        → ±30 min su OGGI   (giorno perso)
    #   "ieri dalle 10 alle 14" → range su OGGI   (giorno perso)
    #
    # Quale dei due si perdeva dipendeva soltanto da quale regex capitava di
    # matchare per prima — non da una decisione. Risolvendo il giorno PRIMA e
    # passandolo come base alla finestra oraria, le due dimensioni si compongono
    # invece di escludersi, e i quattro casi sopra diventano uno solo.
    local anchor_date="$now_date" day_explicit=0
    if _m=$(_qmatch "$query" "$_RE_N_DAYS_AGO"); [[ -n "$_m" ]]; then
        local _dd; _dd=$(_safe_int "$_m")
        if [[ "$_dd" -gt 0 ]]; then
            local _target; _target=$(_date -d "$_dd days ago" +%Y-%m-%d 2>/dev/null)
            if [[ -n "$_target" ]]; then
                anchor_date="$_target"; day_explicit=1; date_filter="$_target"
            fi
        fi
    elif [[ -n "$(_qmatch "$query" "$_RE_YESTERDAY")" ]]; then
        local _yst; _yst=$(_date -d "yesterday" +%Y-%m-%d 2>/dev/null)
        if [[ -n "$_yst" ]]; then
            anchor_date="$_yst"; day_explicit=1; date_filter="$_yst"
        fi
    elif [[ -n "$(_qmatch "$query" "$_RE_TODAY")" ]]; then
        # date_filter resta vuoto: "oggi" è il file corrente, non una rotazione.
        day_explicit=1
    fi

    # ─── Fase 2 — la FINESTRA ORARIA, ancorata al giorno di Fase 1 ────────────
    #
    # I branch restano ordinati dal più specifico al più generico, per evitare che
    # un pattern breve catturi per primo una frase più lunga: "mezz'ora fa" prima
    # di "poco fa", range espliciti prima delle fasce colloquiali.
    #
    # Il primo gruppo sono OFFSET DA ORA ("ultime 2 ore", "30 minuti fa"): non
    # sono ore del giorno, quindi ignorano l'ancora per costruzione — "ieri nelle
    # ultime 2 ore" non è una frase sensata, e l'offset è la lettura più specifica.
    # Dal range esplicito in giù i branch usano invece $anchor_date.
    local _w=""

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

    # NOTA: "N giorni fa" NON è più un branch di finestra — è diventata un'ancora
    # di giorno in Fase 1. Una query che la contiene senza indicare un'ora cade
    # sul ramo finale "giorno nominato → giornata intera", che produce lo stesso
    # risultato di prima; una che indica anche un'ora ("2 giorni fa alle 10") ora
    # la compone invece di scartarla.

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
    # "la giornata in corso": da mezzanotte a ORA. Diverso da "oggi", che è il
    # giorno di calendario intero — per questo non usa l'ancora.
    elif [[ -n "$(_qmatch "$query" "$_RE_LAST_DAY")" ]]; then
        time_from="${now_date}T00:00"
        time_to="${now_date}T${now_hhmm}"

    # ── "dalle HH:MM alle HH:MM" / "tra le HH e le HH" ───────────────────────
    elif _m=$(_qmatch "$query" "$_RE_EXPLICIT_RANGE"); [[ -n "$_m" ]]; then
        # I due token orari si estraggono per POSIZIONE nella sottostringa
        # matchata (primo e secondo numero), non per separatore: la stessa
        # estrazione serve così sia "dalle 10:30 alle 14:45" sia "tra le 10 e le
        # 12", invece di richiedere una sed per forma. La regex del token include
        # il gruppo ":MM" opzionale, quindi "10:30" resta un solo token.
        local from_tok to_tok
        from_tok=$(echo "$_m" | grep -oE "[0-9]{1,2}(:[0-9]{2})?" | sed -n 1p)
        to_tok=$(echo   "$_m" | grep -oE "[0-9]{1,2}(:[0-9]{2})?" | sed -n 2p)
        if [[ -n "$from_tok" && -n "$to_tok" ]]; then
            local from_min to_min
            from_min=$(_hhmm_to_min "$from_tok")
            to_min=$(_hhmm_to_min   "$to_tok")
            # -1 = orario impossibile (es. "alle 99"): nessun range, mai un range
            # inventato che mktime normalizzerebbe in un istante futuro.
            if [[ "$from_min" -ge 0 && "$to_min" -ge 0 ]]; then
                _w=$(_range_window "$anchor_date" "$from_min" "$to_min" "$day_explicit" "$now_epoch")
            fi
        fi

    # ── "alle HH:MM" / "verso le HH" — finestra ±30 min ────────────────────
    elif _m=$(_qmatch "$query" "$_RE_SINGLE_HOUR"); [[ -n "$_m" ]]; then
        local tok; tok=$(echo "$_m" | grep -oE "[0-9]{1,2}(:[0-9]{2})?")
        if [[ -n "$tok" ]]; then
            local center_min; center_min=$(_hhmm_to_min "$tok")
            if [[ "$center_min" -ge 0 ]]; then
                local from_min=$(( center_min - 30 ))
                local to_min=$(( center_min + 30 ))
                # Clamp al giorno ancorato: la finestra di cortesia ±30 min non
                # deve sfondare nel giorno adiacente, che l'utente non ha nominato.
                [[ "$from_min" -lt 0    ]] && from_min=0
                [[ "$to_min"   -gt 1439 ]] && to_min=1439
                _w=$(_day_window "$anchor_date" "$from_min" "$to_min")
            fi
        fi

    # ── "poco fa" / "adesso" / "ore fa" (generico ±30 min) ──────────────────
    elif [[ -n "$(_qmatch "$query" "$_RE_JUST_NOW")" ]]; then
        [[ -n "$now_epoch" ]] && \
            time_from=$(_date -d "@$(( now_epoch - 1800 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
        time_to="${now_date}T${now_hhmm}"

    # ── Fasce colloquiali intraday, sul giorno ancorato ──────────────────────
    # Confini fissi per convenzione. Usano $anchor_date, non $now_date: è ciò che
    # rende "ieri pomeriggio" il pomeriggio di ieri.
    elif [[ -n "$(_qmatch "$query" "$_RE_MORNING")"   ]]; then
        _w=$(_day_window "$anchor_date"  360  720)   # 06:00 → 12:00
    elif [[ -n "$(_qmatch "$query" "$_RE_AFTERNOON")" ]]; then
        _w=$(_day_window "$anchor_date"  720 1080)   # 12:00 → 18:00
    elif [[ -n "$(_qmatch "$query" "$_RE_NIGHT")"     ]]; then
        _w=$(_day_window "$anchor_date"    0  360)   # 00:00 → 06:00
    elif [[ -n "$(_qmatch "$query" "$_RE_EVENING")"   ]]; then
        _w=$(_day_window "$anchor_date" 1080 1439)   # 18:00 → 23:59

    # ── Giorno nominato senza ora: giornata intera ───────────────────────────
    # Copre "ieri", "oggi" e "N giorni fa" quando la query non indica un'ora.
    # Un unico ramo al posto dei tre branch separati di prima: la data l'ha già
    # risolta Fase 1, qui resta solo da dire che la finestra è il giorno intero.
    #
    # Giorno di calendario INTERO (00:00→23:59), non "ultime ore da ora" — quello
    # è il gruppo _RE_LAST_*. Coerente col default di sessione di chatbot.sh
    # (ACTIVE_TIME_FROM/TO a oggi 00:00→23:59): senza, dire "oggi" esplicitamente
    # produceva una finestra più CORTA del default, comportamento sorprendente
    # segnalato dall'utente il 2026-08-05.
    elif [[ "$day_explicit" -eq 1 ]]; then
        _w=$(_day_window "$anchor_date" 0 1439)
    fi

    # I branch ancorati emettono la coppia in $_w ("FROM TO"); quelli a offset da
    # ora scrivono direttamente time_from/time_to. Un solo punto di traduzione,
    # invece di due assegnamenti ripetuti in ognuno dei nove rami.
    if [[ -n "$_w" ]]; then
        time_from="${_w%% *}"
        time_to="${_w##* }"
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
