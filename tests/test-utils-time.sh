#!/bin/bash
#
# test-utils-time.sh — unit test per lib/utils-time.sh e lib/utils-time.awk.
#
# Perché esiste (2026-08-20): 427 righe di parsing di espressioni temporali in
# italiano — la superficie più ricca della prima fase della pipeline — avevano 5
# asserzioni indirette in tests/test-param-extract.sh e nessun test dedicato. Un
# range temporale sbagliato non produce un crash: produce una risposta **ben
# formata alla domanda sbagliata**, che è la classe di difetto più costosa del
# progetto (stessa famiglia di LOGSEL-1 e FORMAT-1).
#
# Copre:
#   resolve_time_range()  i 17 branch della cascata + la loro PRECEDENZA reciproca
#                         (dove un pattern breve può catturare una frase più lunga)
#   TIME_ONLY_QUERY       il segnale di set-context usato da chatbot.sh
#   DATE_FILTER           usato da resolve-logs.sh per scegliere la rotazione
#   parse_iso/in_range    il lato AWK che consuma TIME_FROM/TIME_TO
#
# Le date sono SEMPRE calcolate con date(1), mai cablate: le fixture con date
# hardcoded hanno già prodotto 6 FAIL fantasma il 2026-08-07.
#
# Uso: bash tests/test-utils-time.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

source "$ROOT_DIR/lib/utils-time.sh"

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

# ─── Helper ───────────────────────────────────────────────────────────────────

# _resolve QUERY — popola TF / TT / DF / TOQ dalla resa di resolve_time_range.
_resolve() {
    local _out; _out=$(resolve_time_range "$1")
    TF=""; TT=""; DF=""; TOQ=""
    eval "$(printf '%s\n' "$_out" | sed -E "s/^TIME_FROM=/TF=/; s/^TIME_TO=/TT=/; \
                                            s/^DATE_FILTER=/DF=/; s/^TIME_ONLY_QUERY=/TOQ=/")"
}

# _epoch "YYYY-MM-DDTHH:MM" → epoch, stringa vuota se non convertibile.
_epoch() { [[ -n "$1" ]] && date -d "${1/T/ }" +%s 2>/dev/null || echo ""; }

_ok()   { printf "  ${GREEN}PASS${RESET}  %s\n" "$1"; pass=$(( pass + 1 )); }
_ko()   { printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$1"
          printf "        atteso  : %s\n" "$2"
          printf "        ottenuto: %s\n" "$3"; fail=$(( fail + 1 )); }

# assert_range DESC QUERY EXP_FROM EXP_TO
# EXP_TO può essere la stringa magica NOW (≈ adesso, tolleranza 2 min).
assert_range() {
    local desc="$1" query="$2" exp_from="$3" exp_to="$4"
    _resolve "$query"
    local got="from='$TF' to='$TT'"

    if [[ "$TF" != "$exp_from" ]]; then
        _ko "$desc" "from='$exp_from' to='$exp_to'" "$got"; return
    fi
    if [[ "$exp_to" == "NOW" ]]; then
        local delta; delta=$(( ( $(date +%s) - $(_epoch "$TT") ) / 60 ))
        if [[ "${delta#-}" -gt 2 ]]; then
            _ko "$desc" "to ≈ adesso (±2 min)" "$got (scarto ${delta} min)"; return
        fi
    elif [[ "$TT" != "$exp_to" ]]; then
        _ko "$desc" "from='$exp_from' to='$exp_to'" "$got"; return
    fi
    _ok "$desc"
}

# assert_span DESC QUERY MINUTI — finestra relativa a ora: TIME_TO ≈ adesso e
# l'ampiezza è MINUTI. Non si asseriscono stringhe assolute (dipenderebbero
# dall'istante di esecuzione), si asserisce l'INVARIANTE: l'ampiezza.
assert_span() {
    local desc="$1" query="$2" want_min="$3"
    _resolve "$query"
    local ef et
    ef=$(_epoch "$TF"); et=$(_epoch "$TT")
    if [[ -z "$ef" || -z "$et" ]]; then
        _ko "$desc" "ampiezza ${want_min} min" "from='$TF' to='$TT' (non convertibili)"; return
    fi
    local span=$(( (et - ef) / 60 ))
    local drift=$(( ( $(date +%s) - et ) / 60 ))
    if [[ $(( span - want_min )) -ne 0 && $(( span - want_min )) -ne -1 && $(( span - want_min )) -ne 1 ]]; then
        _ko "$desc" "ampiezza ${want_min} min" "ampiezza ${span} min (from='$TF' to='$TT')"; return
    fi
    if [[ "${drift#-}" -gt 2 ]]; then
        _ko "$desc" "to ≈ adesso (±2 min)" "to='$TT' (scarto ${drift} min)"; return
    fi
    _ok "$desc"
}

# assert_var DESC QUERY VARNAME EXPECTED — per DATE_FILTER / TIME_ONLY_QUERY.
assert_var() {
    local desc="$1" query="$2" var="$3" exp="$4"
    _resolve "$query"
    local got
    case "$var" in
        DATE_FILTER)     got="$DF" ;;
        TIME_ONLY_QUERY) got="$TOQ" ;;
        TIME_FROM)       got="$TF" ;;
        TIME_TO)         got="$TT" ;;
    esac
    [[ "$got" == "$exp" ]] && _ok "$desc" || _ko "$desc" "$var='$exp'" "$var='$got'"
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "──────────────────────"; }

printf "${BOLD}test-utils-time.sh${RESET}  oggi=%s  ieri=%s\n" "$TODAY" "$YESTERDAY"

# ─── 1. Fasce colloquiali intraday ────────────────────────────────────────────
# Confini fissi per convenzione (utils-time.sh:230-237). Un test qui non
# verifica un calcolo ma PINZA una decisione di prodotto: se qualcuno sposta
# "mattina" a 05:00-13:00 lo fa deliberatamente, non per effetto collaterale.
section "Fasce colloquiali"

assert_range "stamattina → 06:00-12:00"        "errori di stamattina"        "${TODAY}T06:00" "${TODAY}T12:00"
assert_range "questa mattina → 06:00-12:00"    "errori questa mattina"      "${TODAY}T06:00" "${TODAY}T12:00"
assert_range "in mattinata → 06:00-12:00"      "errori in mattinata"        "${TODAY}T06:00" "${TODAY}T12:00"
assert_range "nel pomeriggio → 12:00-18:00"    "errori nel pomeriggio"      "${TODAY}T12:00" "${TODAY}T18:00"
assert_range "questo pomeriggio → 12:00-18:00" "errori questo pomeriggio"   "${TODAY}T12:00" "${TODAY}T18:00"
assert_range "stanotte → 00:00-06:00"          "errori di stanotte"         "${TODAY}T00:00" "${TODAY}T06:00"
assert_range "stasera → 18:00-23:59"           "errori di stasera"          "${TODAY}T18:00" "${TODAY}T23:59"
assert_range "questa sera → 18:00-23:59"       "errori questa sera"         "${TODAY}T18:00" "${TODAY}T23:59"

# ─── 2. Giorni di calendario + DATE_FILTER ────────────────────────────────────
# "oggi" e "ieri" coprono il giorno INTERO (non "fino a ora"): decisione presa il
# 2026-08-05 (commit 8838683) perché "oggi" esplicito dava una finestra più corta
# del default di sessione — sorprendente per l'utente.
section "Giorni di calendario"

assert_range "oggi → giornata intera"      "errori di oggi"        "${TODAY}T00:00"     "${TODAY}T23:59"
assert_range "ieri → giornata intera"      "errori di ieri"        "${YESTERDAY}T00:00" "${YESTERDAY}T23:59"
assert_var   "oggi: nessun DATE_FILTER"    "errori di oggi"        DATE_FILTER ""
assert_var   "ieri: DATE_FILTER = ieri"    "errori di ieri"        DATE_FILTER "$YESTERDAY"

_d2=$(date -d "2 days ago" +%Y-%m-%d)
_d3=$(date -d "3 days ago" +%Y-%m-%d)
assert_range "2 giorni fa → giornata intera" "errori 2 giorni fa"  "${_d2}T00:00" "${_d2}T23:59"
assert_range "3 giorni fa → giornata intera" "errori 3 giorni fa"  "${_d3}T00:00" "${_d3}T23:59"
assert_var   "2 giorni fa: DATE_FILTER"      "errori 2 giorni fa"  DATE_FILTER "$_d2"

# ─── 3. Range esplicito "dalle X alle Y" ──────────────────────────────────────
section "Range esplicito"

assert_range "dalle 10 alle 14"           "errori dalle 10 alle 14"        "${TODAY}T10:00" "${TODAY}T14:00"
assert_range "dalle 10:30 alle 14:45"     "errori dalle 10:30 alle 14:45"  "${TODAY}T10:30" "${TODAY}T14:45"
assert_range "dalle 9 alle 17:30"         "errori dalle 9 alle 17:30"      "${TODAY}T09:00" "${TODAY}T17:30"
assert_range "zero-padding ore singole"   "errori dalle 8 alle 9"          "${TODAY}T08:00" "${TODAY}T09:00"

# Forma documentata in utils-time.sh:50 ("tra le HH e le HH") ma la regex
# _RE_EXPLICIT_RANGE richiede letteralmente "dalle ... alle ...". Se questa
# asserzione fallisce, il commento promette una capacità che non esiste — e la
# query cade su "nessun range", cioè filtro silenziosamente assente.
assert_range "tra le 10 e le 12 (forma documentata)" "errori tra le 10 e le 12" "${TODAY}T10:00" "${TODAY}T12:00"

# ── Range a cavallo di mezzanotte (D1) ────────────────────────────────────────
# Prima entrambi gli estremi erano ancorati allo stesso giorno, quindi
# "dalle 22 alle 2" dava from > to: intervallo VUOTO, in_range() sempre 0, e il
# tool rispondeva "nessun risultato nel periodo" su una frase legittima.
#
# La regola (indicata dall'utente il 2026-08-20) ancora la finestra al passato:
# `from` è l'occorrenza più recente già passata di quell'ora. Si verifica su
# _range_window() con un `now` SINTETICO invece che end-to-end, per due ragioni:
#   1. l'esito dipende dall'ora di esecuzione — un'asserzione end-to-end su
#      "ieri 22:00" fallirebbe se la suite girasse dopo le 22:00, che è la stessa
#      fragilità delle date cablate (6 FAIL fantasma il 2026-08-07)
#   2. entrambi i rami della regola vanno esercitati, e uno solo dei due è
#      raggiungibile a una data ora del giorno
_rw() {  # _rw DESC BASE FMIN TMIN DAY_EXPL NOW_HHMM EXPECTED
    local desc="$1" base="$2" fmin="$3" tmin="$4" dex="$5" nowh="$6" exp="$7"
    local now_ep got
    now_ep=$(date -d "$base $nowh" +%s)
    got=$(_range_window "$base" "$fmin" "$tmin" "$dex" "$now_ep")
    [[ "$got" == "$exp" ]] && _ok "$desc" || _ko "$desc" "$exp" "$got"
}

# Caso 1 dell'utente: sono le 21:00, "dalle 22 alle 02" → le 22 di oggi non sono
# ancora arrivate, quindi intende la notte appena passata.
_rw "alle 21:00 'dalle 22 alle 2' → ieri 22:00 → oggi 02:00" \
    "$TODAY" 1320 120 0 "21:00" "${YESTERDAY}T22:00 ${TODAY}T02:00"

# Caso 2 dell'utente: sono le 23:00, "dalle 22 alle 02" → le 22 sono passate
# un'ora fa, quindi intende da allora fino alle 2 (finestra che comprende ora).
_rw "alle 23:00 'dalle 22 alle 2' → oggi 22:00 → domani 02:00" \
    "$TODAY" 1320 120 0 "23:00" "${TODAY}T22:00 $(date -d "$TODAY +1 day" +%Y-%m-%d)T02:00"

# Un giorno NOMINATO vince sulla regola: nessun arretramento.
_rw "'ieri dalle 22 alle 2' → ancora esplicita, nessuno spostamento" \
    "$YESTERDAY" 1320 120 1 "21:00" "${YESTERDAY}T22:00 ${TODAY}T02:00"

# Un range che NON attraversa la mezzanotte non viene mai spostato, anche se
# interamente futuro: contiene forse dati, e arretrare li butterebbe via
# (principio 5). Qui il comportamento è identico a prima dell'intervento.
_rw "range normale futuro NON viene arretrato" \
    "$TODAY" 630 885 0 "09:00" "${TODAY}T10:30 ${TODAY}T14:45"

# End-to-end, indipendente dall'ora di esecuzione: qualunque sia l'ora, la
# finestra non deve MAI essere invertita — che era il difetto.
_resolve "errori dalle 22 alle 2"
_ef=$(_epoch "$TF"); _et=$(_epoch "$TT")
if [[ -n "$_ef" && -n "$_et" && "$_et" -gt "$_ef" ]]; then
    _ok "dalle 22 alle 2: finestra non invertita (from < to)"
else
    _ko "dalle 22 alle 2: finestra non invertita (from < to)" "to > from" "from='$TF' to='$TT'"
fi

# ─── 4. Ora singola, finestra ±30 min ─────────────────────────────────────────
section "Ora singola ±30 min"

assert_range "alle 10:30 → 10:00-11:00"  "errori alle 10:30"   "${TODAY}T10:00" "${TODAY}T11:00"
assert_range "alle 9 → 08:30-09:30"      "errori alle 9"       "${TODAY}T08:30" "${TODAY}T09:30"
assert_range "verso le 14 → 13:30-14:30" "errori verso le 14"  "${TODAY}T13:30" "${TODAY}T14:30"
assert_range "verso l'una → 00:30-01:30" "errori verso le 1"   "${TODAY}T00:30" "${TODAY}T01:30"
# Clamp al giorno: alle 00:10 il limite inferiore non può andare a ieri 23:40
assert_range "alle 0:10 → clamp a 00:00" "errori alle 0:10"    "${TODAY}T00:00" "${TODAY}T00:40"
assert_range "alle 23:50 → clamp a 23:59" "errori alle 23:50"  "${TODAY}T23:20" "${TODAY}T23:59"

# ─── 5. Finestre relative a ora ───────────────────────────────────────────────
# Qui si asserisce l'AMPIEZZA, non stringhe assolute: l'invariante è la durata.
section "Finestre relative a ora"

assert_span "ultime 2 ore → 120 min"      "errori nelle ultime 2 ore"   120
assert_span "ultima 1 ora → 60 min"       "errori nell'ultima 1 ora"    60
assert_span "ultime 24 ore → 1440 min"    "errori nelle ultime 24 ore"  1440
assert_span "ultima ora (senza numero)"   "errori nell'ultima ora"      60
assert_span "ultimi 30 minuti → 30 min"   "errori negli ultimi 30 minuti" 30
assert_span "ultimi 90 minuti → 90 min"   "errori negli ultimi 90 minuti" 90
assert_span "3 ore fa → 180 min"          "errori 3 ore fa"             180
assert_span "45 minuti fa → 45 min"       "errori 45 minuti fa"         45
assert_span "mezz'ora fa → 30 min"        "errori mezz'ora fa"          30
assert_span "mezzora fa (senza apostrofo)" "errori mezzora fa"          30
assert_span "ultima mezzora → 30 min"     "errori nell'ultima mezzora"  30
assert_span "poco fa → 30 min"            "errori poco fa"              30
assert_span "adesso → 30 min"             "errori adesso"               30

# "ultima giornata" = da mezzanotte a ORA (non a 23:59): è "la giornata in
# corso", diverso da "oggi" che è il giorno di calendario.
assert_range "ultima giornata → 00:00-ora" "errori nell'ultima giornata" "${TODAY}T00:00" "NOW"
assert_range "ultimo giorno → 00:00-ora"   "errori nell'ultimo giorno"   "${TODAY}T00:00" "NOW"

# ─── 6. PRECEDENZA nella cascata ──────────────────────────────────────────────
# La sezione più importante del file. utils-time.sh:126-128 dichiara la regola:
# "ordinati dal più specifico al più generico per evitare che un pattern breve
# catturi per primo una frase più lunga". Qui si verifica che sia vero quando DUE
# espressioni temporali coesistono nella stessa query — il caso che un utente
# reale produce continuamente ("ieri mattina", "ieri alle 10").
section "Precedenza fra pattern coesistenti"

# Un giorno esplicito deve ANCORARE la fascia: "ieri mattina" è la mattina di
# ieri, non quella di oggi. I branch delle fasce (righe 230-237) precedono
# quello di "ieri" (riga 240) e usano now_date, quindi se questa asserzione
# fallisce il bot risponde con la fascia giusta del giorno SBAGLIATO — e senza
# DATE_FILTER va anche a leggere la rotazione di oggi.
assert_range "ieri mattina → mattina di IERI"    "errori ieri mattina"     "${YESTERDAY}T06:00" "${YESTERDAY}T12:00"
assert_range "ieri pomeriggio → pom. di IERI"    "errori ieri pomeriggio"  "${YESTERDAY}T12:00" "${YESTERDAY}T18:00"
assert_range "ieri sera → sera di IERI"          "errori ieri sera"        "${YESTERDAY}T18:00" "${YESTERDAY}T23:59"
assert_var   "ieri mattina: DATE_FILTER = ieri"  "errori ieri mattina"     DATE_FILTER "$YESTERDAY"

# Stesso principio con un'ora puntuale e con un range.
assert_range "ieri alle 10 → ±30 min su IERI"    "errori ieri alle 10"     "${YESTERDAY}T09:30" "${YESTERDAY}T10:30"
assert_range "ieri dalle 10 alle 14 → su IERI"   "errori ieri dalle 10 alle 14" "${YESTERDAY}T10:00" "${YESTERDAY}T14:00"

# "oggi" + fascia: la fascia è più specifica e deve vincere (stesso giorno,
# quindi qui non c'è ambiguità di data — si verifica solo che non degradi).
assert_range "oggi pomeriggio → fascia vince"    "errori oggi pomeriggio"  "${TODAY}T12:00" "${TODAY}T18:00"

# "N giorni fa" + fascia
assert_range "2 giorni fa di mattina"            "errori 2 giorni fa di mattina" "${_d2}T06:00" "${_d2}T12:00"

# Pattern generico che non deve rubare a uno specifico (già garantito
# dall'ordine, qui si blinda contro un riordino accidentale).
assert_span "3 ore fa non diventa 'ore fa' (±30)" "errori 3 ore fa"        180
assert_span "mezz'ora fa non diventa 'poco fa'"   "errori mezz'ora fa"     30
assert_range "stamattina alle 10 → ora puntuale"  "errori stamattina alle 10" "${TODAY}T09:30" "${TODAY}T10:30"

# ─── 7. TIME_ONLY_QUERY (segnale di set-context) ──────────────────────────────
# chatbot.sh lo usa per capire che "dalle 10 alle 12" non è una domanda ma un
# cambio di contesto. Un falso positivo qui fa sparire una query vera.
section "TIME_ONLY_QUERY"

assert_var "solo tempo: 'dalle 10 alle 12'"      "dalle 10 alle 12"           TIME_ONLY_QUERY "1"
assert_var "solo tempo: 'ultimi 30 minuti'"      "ultimi 30 minuti"           TIME_ONLY_QUERY "1"
assert_var "solo tempo: 'stamattina'"            "stamattina"                 TIME_ONLY_QUERY "1"
assert_var "solo tempo: 'ieri'"                  "ieri"                       TIME_ONLY_QUERY "1"
assert_var "con intento: 'errori di stamattina'" "errori di stamattina"       TIME_ONLY_QUERY "0"
assert_var "con intento: 'chiamate lente ieri'"  "chiamate lente ieri"        TIME_ONLY_QUERY "0"
assert_var "con intento: 'quanti 500 alle 10'"   "quanti 500 alle 10"         TIME_ONLY_QUERY "0"
assert_var "senza tempo: TIME_ONLY_QUERY=0"      "errori nel server log"      TIME_ONLY_QUERY "0"

# ─── 8. Robustezza: input degeneri ────────────────────────────────────────────
# Principio 5 (pruning conservativo): in caso di dubbio NON restringere. Una
# finestra vuota è preferibile a una finestra inventata — perché un range
# assente lascia il default di sessione, un range sbagliato lo sostituisce.
section "Input degeneri"

assert_var "query senza tempo → TIME_FROM vuoto" "errori nel cc.log"      TIME_FROM ""
assert_var "query senza tempo → TIME_TO vuoto"   "errori nel cc.log"      TIME_TO   ""
assert_var "query vuota → TIME_FROM vuoto"       ""                        TIME_FROM ""
assert_var "'ultime 0 ore' → nessun range"       "errori ultime 0 ore"    TIME_FROM ""
assert_var "'0 giorni fa' → nessun range"        "errori 0 giorni fa"     TIME_FROM ""
# "primavera" contiene "prima" ma non è un'espressione temporale risolvibile:
# stesso falso positivo già presidiato per LOG_ORDER in test-param-extract.sh.
assert_var "'primavera' non è un range"          "errori di primavera"    TIME_FROM ""
# Ora fuori scala: non deve produrre un range invertito o un'ora >23.
assert_var "'alle 99' non produce ora invalida"  "errori alle 99"         TIME_FROM ""

# ─── 9. Lato AWK: parse_iso e in_range ────────────────────────────────────────
# Il contratto ha due metà: bash produce le stringhe, AWK le consuma. Un test
# solo sulla prima metà lascerebbe scoperto il punto in cui il range diventa
# davvero un filtro.
section "Lato AWK (parse_iso, in_range)"

_awk_check() {
    local desc="$1" tf="$2" tt="$3" prog="$4" exp="$5"
    local got
    got=$(gawk -v time_from="$tf" -v time_to="$tt" \
               -f "$ROOT_DIR/lib/utils-time.awk" \
               -e "BEGIN { $prog }" </dev/null 2>&1)
    [[ "$got" == "$exp" ]] && _ok "$desc" || _ko "$desc" "$exp" "$got"
}

_awk_check "parse_iso round-trip HH:MM" "" "" \
    'printf "%s", strftime("%Y-%m-%dT%H:%M", parse_iso("2026-08-20T14:30"))' "2026-08-20T14:30"
_awk_check "parse_iso accetta i secondi" "" "" \
    'printf "%s", strftime("%Y-%m-%dT%H:%M:%S", parse_iso("2026-08-20T14:30:45"))' "2026-08-20T14:30:45"
_awk_check "parse_iso su stringa non ISO → 0" "" "" \
    'printf "%d", parse_iso("non-una-data")' "0"

_awk_check "in_range: dentro la finestra" "2026-08-20T10:00" "2026-08-20T12:00" \
    'printf "%d", in_range(parse_iso("2026-08-20T11:00"))' "1"
_awk_check "in_range: prima della finestra" "2026-08-20T10:00" "2026-08-20T12:00" \
    'printf "%d", in_range(parse_iso("2026-08-20T09:59"))' "0"
_awk_check "in_range: estremi inclusi (from)" "2026-08-20T10:00" "2026-08-20T12:00" \
    'printf "%d", in_range(parse_iso("2026-08-20T10:00"))' "1"
_awk_check "in_range: estremi inclusi (to)" "2026-08-20T10:00" "2026-08-20T12:00" \
    'printf "%d", in_range(parse_iso("2026-08-20T12:00"))' "1"
_awk_check "in_range: nessun limite → tutto passa" "" "" \
    'printf "%d", in_range(parse_iso("1999-01-01T00:00"))' "1"
_awk_check "in_range: solo limite superiore" "" "2026-08-20T12:00" \
    'printf "%d", in_range(parse_iso("2020-01-01T00:00"))' "1"

# Timestamp NON riconosciuto (epoch 0) con un filtro attivo. Il principio 5 dice
# "in caso di dubbio, includere": una riga di cui non sappiamo l'istante non
# dovrebbe essere esclusa da un filtro temporale, altrimenti il tool risponde
# "nessun risultato" su dati che non ha saputo datare — il falso negativo pieno
# misurato in FORMAT-1.
_awk_check "in_range(0) con filtro attivo → incluso (principio 5)" \
    "2026-08-20T10:00" "2026-08-20T12:00" 'printf "%d", in_range(0)' "1"

# ─── Esito ────────────────────────────────────────────────────────────────────
printf "\n────────────────────────────────────────────────────────\n"
printf "${BOLD}test-utils-time.sh${RESET}  "
printf "${GREEN}%d PASS${RESET}  " "$pass"
[[ "$fail" -gt 0 ]] && printf "${RED}${BOLD}%d FAIL${RESET}\n" "$fail" || printf "${GREEN}0 FAIL${RESET}\n"

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
