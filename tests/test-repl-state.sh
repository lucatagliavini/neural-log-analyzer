#!/bin/bash
#
# test-repl-state.sh — comportamento dello STATO fra query consecutive.
#
# Perché esiste (2026-08-20): il REPL di chatbot.sh eredita stato di proposito
# fra query (contesto env/nodo/app, finestra temporale CTX-1, ultimo log
# nominato), ma ogni test della suite eseguiva UNA query in una subshell pulita
# — run-tests.sh:245 lo dichiara esplicitamente («chatbot.sh le eredita di
# proposito, i test no»). Quel commento descrive una scelta corretta per il test
# di classificazione e una cecità totale per il resto: due bug reali sono venuti
# esattamente da qui e nessuno dei due era catturabile dalla suite.
#
#   e43d1c6  fix(tail_log): TIME_EXPLICIT non persistente + filtro riga-per-riga
#   01c5f6f  fix(chatbot): esporta DETECTED_* prima dell'eval di param-extract.sh
#            (DETECTED_NODE tornava vuoto dopo l'eval, perdendo il nodo appena
#             rilevato)
#
# Metodo: le query vengono inviate sullo STDIN di un SOLO processo chatbot.sh
# (il REPL legge in loop, chatbot.sh:603-606), così lo stato è quello vero. Le
# asserzioni guardano ciò che l'UTENTE VEDE — il banner di contesto, la riga
# `Log:`, le etichette dei tool — perché quello è il contratto osservabile; una
# sonda sulle variabili interne verificherebbe l'implementazione, non la promessa.
#
# Le due invarianti che questo file presidia:
#   PERSISTE      contesto (env/nodo/app), finestra temporale, ultimo log nominato
#   NON PERSISTE  ogni parametro derivato dalla singola query: STATUS_CODE,
#                 THRESHOLD_MS, LOG_LEVEL, TIME_EXPLICIT, LOG_EXPLICIT
#
# Uso: bash tests/test-repl-state.sh [--profile <dir>]
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$ROOT_DIR/profiles/liquido"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

# ─── Fixture ──────────────────────────────────────────────────────────────────
# Date SEMPRE calcolate, mai cablate: una fixture datata smette di trovare dati
# appena cambia il giorno (bug reale del 2026-08-07, 6 FAIL fantasma).
_T=$(date +%Y-%m-%d)          # oggi, formato server.log
_Y=$(date -d yesterday +%Y-%m-%d)
_TA=$(date +%d/%b/%Y)         # oggi, formato access log
_YA=$(date -d yesterday +%d/%b/%Y)

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Due nodi, per poter verificare che un cambio di nodo persista e che il nodo
# letto sia quello giusto: il contenuto porta un marcatore distinto.
for _n in 03 04; do
    _d="$_FIX/prod/lxprjbliq${_n}/prod/ClaimCenter"
    mkdir -p "$_d"
    # server.log corrente: solo OGGI. Rotazione datata: solo IERI.
    # Serve a distinguere "ha letto il corrente" da "ha letto la rotazione",
    # che è l'unico modo di osservare TIME_EXPLICIT dall'esterno.
    printf '%s 10:00:00,000 ERROR boom-nodo%s-OGGI\n'   "$_T" "$_n" > "$_d/server.log"
    printf '%s 10:00:01,000 WARN  attenzione-nodo%s\n'  "$_T" "$_n" >> "$_d/server.log"
    printf '%s 11:00:00,000 ERROR boom-nodo%s-IERI\n'   "$_Y" "$_n" > "$_d/server.${_Y}.log"

    # access log: 4 richieste di OGGI con status e latenze diversi, così
    # count_status e slow_requests hanno segnali discriminanti.
    {
      printf '10.0.0.1 [%s:07:00:00 +0200] "GET /a HTTP/1.1" 200 100 100 - UA\n'  "$_TA"
      printf '10.0.0.1 [%s:07:00:01 +0200] "GET /b HTTP/1.1" 500 200 2500 - UA\n' "$_TA"
      printf '10.0.0.2 [%s:07:00:02 +0200] "GET /c HTTP/1.1" 404 100 90 - UA\n'   "$_TA"
      printf '10.0.0.2 [%s:13:00:00 +0200] "GET /d HTTP/1.1" 500 100 80 - UA\n'   "$_TA"
      printf '10.0.0.3 [%s:11:00:00 +0200] "GET /e HTTP/1.1" 503 100 70 - UA\n'   "$_YA"
    } > "$_d/undertow_access_log.log"

    _g="$_FIX/prod/lxprjbliq${_n}/ClaimCenter/Guidewire"
    mkdir -p "$_g"
    printf '[main] USER %sT10:00:00,000 ERROR cc-boom-nodo%s\n'    "$_T" "$_n" > "$_g/prod1nssd-cc.log"
    printf '[main] USER %sT10:00:01,000 WARN  cc-warn-nodo%s\n'    "$_T" "$_n" >> "$_g/prod1nssd-cc.log"
    printf '[main] USER %sT10:00:00,000 ERROR api-boom-nodo%s\n'   "$_T" "$_n" > "$_g/prod1nssd-api.log"
done

# ─── Helper ───────────────────────────────────────────────────────────────────

# _session QUERY... — invia tutte le query a UN SOLO processo chatbot.sh.
# È il punto centrale del file: con --query si otterrebbe un processo per query,
# cioè esattamente il percorso che NON ha stato.
_session() {
    printf '%s\n' "$@" | QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" \
        --profile "$PROFILE_DIR" --base-dir "$_FIX" --env prod --node 4 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g'
}

# _block N OUTPUT — il blocco della N-esima query (delimitato da "┌─ Query:").
_block() {
    printf '%s\n' "$2" | awk -v want="$1" '
        /^┌─ Query:/ { n++ }
        n == want    { print }
    '
}

_ok() { printf "  ${GREEN}PASS${RESET}  %s\n" "$1"; pass=$(( pass + 1 )); }
_ko() { printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$1"
        printf "        atteso  : %s\n" "$2"
        printf "        ottenuto: %s\n" "$3"; fail=$(( fail + 1 )); }

# _assert_in DESC HAYSTACK NEEDLE — il blocco DEVE contenere NEEDLE.
_assert_in() {
    if printf '%s\n' "$2" | grep -qF -- "$3"; then _ok "$1"
    else _ko "$1" "contiene '$3'" "$(printf '%s\n' "$2" | grep -E '^(  \[|Log:|Totale|TOTALE|[0-9]{3} )' | tr '\n' '|' | head -c 200)"; fi
}

# _assert_line / _assert_no_line DESC HAYSTACK REGEX — presenza/assenza di una
# RIGA che matcha REGEX. Serve per le righe di tabella (`200 ...`), dove un
# match di sottostringa colpirebbe anche il riepilogo ("Errori 4xx:") e dove un
# needle multilinea passato a `grep -F` degenererebbe in pattern vuoto — che
# matcha qualunque cosa (errore commesso alla prima stesura di questo file).
_assert_line() {
    if printf '%s\n' "$2" | grep -qE -- "$3"; then _ok "$1"
    else _ko "$1" "una riga che matcha /$3/" "$(printf '%s\n' "$2" | grep -E '^[0-9]{3} ' | tr '\n' '|')"; fi
}
_assert_no_line() {
    if printf '%s\n' "$2" | grep -qE -- "$3"; then
        _ko "$1" "nessuna riga che matcha /$3/" "$(printf '%s\n' "$2" | grep -E -- "$3" | head -2 | tr '\n' '|')"
    else _ok "$1"; fi
}

# _assert_not_in DESC HAYSTACK NEEDLE — il blocco NON deve contenere NEEDLE.
_assert_not_in() {
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        _ko "$1" "NON contiene '$3'" "$(printf '%s\n' "$2" | grep -F -- "$3" | head -2 | tr '\n' '|')"
    else _ok "$1"; fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "──────────────────"; }

printf "${BOLD}test-repl-state.sh${RESET}  oggi=%s  ieri=%s\n" "$_T" "$_Y"

# ─── A. Il contesto PERSISTE ──────────────────────────────────────────────────
# Comportamento voluto e documentato (CTX-1 e la gestione DETECTED_* in
# chatbot.sh:348-356). I test lo blindano perché è la metà del modello di stato
# su cui poggia l'usabilità: senza, ogni query andrebbe riscritta per intero.
section "A. Il contesto persiste"

_out=$(_session "errori nel server log del nodo 3" "quanti errori ci sono")
_assert_in "q1 usa il nodo 3 appena nominato"      "$(_block 1 "$_out")" "nodo 03"
_assert_in "q2 EREDITA il nodo 3 (non torna a 04)" "$(_block 2 "$_out")" "nodo 03"

_out=$(_session "errori di stamattina nel server log" "quanti errori ci sono" "chiamate lente")
_assert_in "q1 imposta la finestra 06:00→12:00" "$(_block 1 "$_out")" "06:00→"
_assert_in "q2 eredita la finestra"             "$(_block 2 "$_out")" "06:00→"
_assert_in "q3 eredita ancora la finestra"      "$(_block 3 "$_out")" "06:00→"
# La finestra ereditata deve essere DICHIARATA, non applicata in silenzio:
# è ciò che distingue un contesto da un effetto collaterale.
_assert_in "la finestra ereditata è dichiarata nel banner" "$(_block 2 "$_out")" "${_T} 06:00→${_T} 12:00"

# ...e deve essere APPLICATA, non solo dichiarata. Le due cose sono variabili
# diverse: il banner stampa ACTIVE_TIME_FROM/TO, i tool ricevono TIME_FROM/TO.
# Verificato con una mutazione deliberata (TIME_FROM svuotato nel ramo di
# eredità): il banner restava corretto e le asserzioni sopra passavano tutte.
# Asserire l'etichetta senza l'effetto è la stessa cecità di LOGSEL-1 D2.
#
# Segnale: la fixture ha DUE richieste 500, una alle 07:00 (dentro la fascia
# mattutina) e una alle 13:00 (fuori). Con la finestra applicata la riga 500
# conta 1; senza, conta 2.
_out2=$(_session "errori di stamattina nel server log" "quanti errori 500 ci sono")
_assert_line    "q2 APPLICA la finestra ereditata (500 → 1 occorrenza)" \
                "$(_block 2 "$_out2")" '^500 +1 '
_assert_no_line "q2 non conta la richiesta fuori fascia (13:00)" \
                "$(_block 2 "$_out2")" '^500 +2 '

# ─── B. Una nuova indicazione SOSTITUISCE quella vecchia ──────────────────────
# Il rischio simmetrico alla persistenza: uno stato che persiste troppo. Se
# "oggi" non scacciasse "ieri", il bot risponderebbe per sempre sul primo giorno
# nominato nella sessione.
section "B. Una nuova indicazione sostituisce la vecchia"

_out=$(_session "errori nel server log di ieri" "errori nel server log di oggi")
_assert_in     "q1 finestra su IERI"          "$(_block 1 "$_out")" "${_Y} 00:00→${_Y} 23:59"
_assert_in     "q2 finestra spostata su OGGI" "$(_block 2 "$_out")" "${_T} 00:00→${_T} 23:59"
_assert_not_in "q2 non resta su ieri"         "$(_block 2 "$_out")" "${_Y} 00:00→${_Y} 23:59"

_out=$(_session "errori di stamattina nel server log" "errori nel pomeriggio nel server log")
_assert_in "q2 passa alla fascia pomeriggio" "$(_block 2 "$_out")" "12:00→${_T} 18:00"

_out=$(_session "errori nel server log del nodo 3" "errori nel server log del nodo 4")
_assert_in "q2 cambia nodo"          "$(_block 2 "$_out")" "nodo 04"
_assert_in "q2 legge il file del nodo 4" "$(_block 2 "$_out")" "lxprjbliq04"

# ─── C. I parametri per-query NON persistono ──────────────────────────────────
# param-extract.sh ri-emette TUTTE le variabili a ogni query, anche vuote, quindi
# l'eval le sovrascrive: la non-persistenza è garantita per COSTRUZIONE. Ma
# "garantito per costruzione" è precisamente ciò che il principio 8 invita a
# verificare invece di assumere — e qui è osservabile a costo zero.
section "C. I parametri per-query non persistono"

# Si asserisce la PRESENZA/ASSENZA delle righe di stato, non i totali: un totale
# dipende da quante richieste della fixture cadono nella finestra, quindi
# legherebbe il test all'aritmetica della fixture invece al comportamento. Tre
# asserzioni di questo file sono fallite alla prima stesura proprio così — e
# sembravano un bug del codice (la lezione di metodo di FORMAT-1).
_out=$(_session "quanti errori 500 stamattina" "quanti errori ci sono")
_assert_line    "q1 filtra sul 500: la riga 500 c'è"     "$(_block 1 "$_out")" '^500 '
_assert_no_line "q1 filtra sul 500: nessuna riga 200"    "$(_block 1 "$_out")" '^200 '
_assert_no_line "q1 filtra sul 500: nessuna riga 404"    "$(_block 1 "$_out")" '^404 '
_assert_line    "q2 NON eredita STATUS_CODE (200 c'è)"   "$(_block 2 "$_out")" '^200 '
_assert_line    "q2 NON eredita STATUS_CODE (404 c'è)"   "$(_block 2 "$_out")" '^404 '

# Soglia 2000: la fixture ha una richiesta da 2500 ms, quindi il tool produce la
# riga "soglia:" invece del messaggio di nessun risultato.
_out=$(_session "richieste sopra i 2000 ms" "chiamate lente")
_assert_in "q1 usa la soglia chiesta"                "$(_block 1 "$_out")" "soglia: 2000 ms"
_assert_in "q2 torna alla soglia di default (1000)"  "$(_block 2 "$_out")" "soglia: 1000 ms"

_out=$(_session "warning nel cc.log" "errori nel cc.log")
_assert_in "q1 livello WARN"                    "$(_block 1 "$_out")" "cc-warn-nodo04"
_assert_in "q2 livello ERROR, non WARN eredit." "$(_block 2 "$_out")" "cc-boom-nodo04"
_assert_not_in "q2 non mostra la riga WARN"     "$(_block 2 "$_out")" "cc-warn-nodo04"

# ─── D. TIME_EXPLICIT non persiste (il bug e43d1c6) ───────────────────────────
# tail_log usa TIME_EXPLICIT per decidere se IGNORARE la finestra ereditata: a
# riposo deve mostrare "cosa succede ORA", cioè il log corrente, non la rotazione
# del giorno ereditato dal contesto. È l'unica invariante di stato osservabile
# dalla riga `Log:`, e la ragione per cui la fixture ha una rotazione datata.
section "D. TIME_EXPLICIT non persiste"

_out=$(_session "errori nel server log di ieri" "ultime 5 righe del server log")
_assert_in "q1 legge la rotazione di ieri" "$(_block 1 "$_out")" "server.${_Y}.log"
_assert_in "q2 torna al log CORRENTE"      "$(_block 2 "$_out")" "server.log"
_assert_not_in "q2 non resta sulla rotazione di ieri" "$(_block 2 "$_out")" "server.${_Y}.log"

# ─── E. L'ultimo log nominato persiste, i log di sistema non lo ereditano ─────
# ACTIVE_NAMED_LOG è persistente di proposito ("cerca X nello stesso log"), ma un
# log di SISTEMA ha un tool dedicato e non deve essere dirottato sul named log
# rimasto in sessione.
section "E. Ultimo log nominato"

_out=$(_session "ultime righe del cc.log" "errori nel server log")
_assert_in     "q1 legge cc.log"                    "$(_block 1 "$_out")" "prod1nssd-cc.log"
_assert_in     "q2 legge il server.log"             "$(_block 2 "$_out")" "server.log"
_assert_not_in "q2 non dirotta sul cc.log ereditato" "$(_block 2 "$_out")" "prod1nssd-cc.log"

_out=$(_session "ultime righe del cc.log" "ultime righe del api.log")
_assert_in     "q2 passa al api.log"          "$(_block 2 "$_out")" "prod1nssd-api.log"
_assert_not_in "q2 non resta sul cc.log"      "$(_block 2 "$_out")" "prod1nssd-cc.log"

# ─── F. Il contesto sopravvive a una query che non produce risultati ──────────
# Una query a vuoto non deve azzerare il contesto: altrimenti l'utente perde
# nodo e finestra proprio quando sta affinando la ricerca.
section "F. Il contesto sopravvive a una query a vuoto"

_out=$(_session "errori nel server log del nodo 3" "quanti errori 302 ci sono" "errori nel server log")
_assert_in "q3 mantiene il nodo 3 dopo una query a vuoto" "$(_block 3 "$_out")" "nodo 03"
_assert_in "q3 legge ancora il file del nodo 3"           "$(_block 3 "$_out")" "lxprjbliq03"

# ─── Esito ────────────────────────────────────────────────────────────────────
printf "\n────────────────────────────────────────────────────────\n"
printf "${BOLD}test-repl-state.sh${RESET}  "
printf "${GREEN}%d PASS${RESET}  " "$pass"
[[ "$fail" -gt 0 ]] && printf "${RED}${BOLD}%d FAIL${RESET}\n" "$fail" || printf "${GREEN}0 FAIL${RESET}\n"

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
