#!/bin/bash
#
# test-param-extract.sh — unit test per lib/param-extract.sh.
#
# Copre i parametri che decidono QUALE file viene letto, dove un errore non
# produce un crash ma un risultato plausibile e sbagliato:
#   NAMED_LOG        nome log Guidewire risolto dalla whitelist APP_LOG_NAMES
#   NAMED_LOG_GLOB   escape hatch glob tra virgolette (+ validazione path traversal)
#   UNRESOLVED_LOG   la query nomina un .log che non siamo riusciti a risolvere
#   SEARCH_PATTERN   stringa di ricerca per search_all_logs
#
# Uso: bash tests/test-param-extract.sh [--profile <dir>]
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

export PROFILE_DIR
GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

# Esegue param-extract.sh e restituisce il valore di una variabile emessa.
_extract() {
    local query="$1" var="$2"
    bash "$ROOT_DIR/lib/param-extract.sh" "$query" 2>/dev/null \
        | grep "^${var}=" | head -1 | cut -d= -f2- | sed "s/^'//; s/'$//"
}

assert_eq() {
    local desc="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"
        printf "        atteso : '%s'\n" "$expected"
        printf "        ottenuto: '%s'\n" "$got"
        fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

# ─── NAMED_LOG dalla whitelist ────────────────────────────────────────────────
section "NAMED_LOG (whitelist APP_LOG_NAMES)"

assert_eq "cc.log risolto"           "cc"       "$(_extract 'ultime righe del cc.log' NAMED_LOG)"
assert_eq "api.log risolto"          "api"      "$(_extract 'errori nel api.log' NAMED_LOG)"
assert_eq "ccJBatch risolto"         "ccJBatch" "$(_extract 'ultime righe del ccJBatch.log' NAMED_LOG)"
assert_eq "senza log: vuoto"         ""         "$(_extract 'ultime 100 righe' NAMED_LOG)"

# ─── NAMED_LOG_GLOB — escape hatch ────────────────────────────────────────────
section "NAMED_LOG_GLOB (escape hatch)"

assert_eq "glob valido estratto" "*c1nssprod*.log" \
    "$(_extract 'ultime 10 righe di "*c1nssprod*.log"' NAMED_LOG_GLOB)"
assert_eq "glob con maiuscole preservate" "*ccJBatch*.log" \
    "$(_extract 'ultime righe di "*ccJBatch*.log"' NAMED_LOG_GLOB)"
assert_eq "senza asterisco: non e' un glob" "" \
    "$(_extract 'ultime righe di "cc.log"' NAMED_LOG_GLOB)"
assert_eq "senza .log finale: non e' un glob" "" \
    "$(_extract 'ultime righe di "*c1nss*"' NAMED_LOG_GLOB)"

# Validazione: input che finisce in `find -name`, la whitelist e' obbligatoria
assert_eq "path traversal '..' rifiutato" "" \
    "$(_extract 'righe di "../*.log"' NAMED_LOG_GLOB)"
assert_eq "slash rifiutato" "" \
    "$(_extract 'righe di "/etc/*.log"' NAMED_LOG_GLOB)"
assert_eq "traversal senza glob ignorato" "" \
    "$(_extract 'righe di "../../etc/passwd"' NAMED_LOG_GLOB)"

# ─── UNRESOLVED_LOG — la query nomina un log che non sappiamo risolvere ───────
section "UNRESOLVED_LOG (avviso all'utente)"

# Il caso reale che ha motivato questa variabile: senza avviso, tail_log apre
# l'access log di Undertow e l'utente non ha modo di accorgersene.
assert_eq "nome fuori whitelist rilevato" "pc1nssprod.log" \
    "$(_extract 'ultime 10 righe del pc1nssprod.log del nodo 5 di produzione' UNRESOLVED_LOG)"
assert_eq "match parziale della whitelist rilevato" "xyzapi.log" \
    "$(_extract 'ultime righe del xyzapi.log' UNRESOLVED_LOG)"
assert_eq "log risolto: nessun avviso" "" \
    "$(_extract 'ultime righe del cc.log' UNRESOLVED_LOG)"
assert_eq "glob valido: nessun avviso" "" \
    "$(_extract 'ultime 10 righe di "*c1nssprod*.log"' UNRESOLVED_LOG)"
assert_eq "server.log legittimo: nessun avviso" "" \
    "$(_extract 'ultime righe del server.log' UNRESOLVED_LOG)"
assert_eq "gc.log legittimo: nessun avviso" "" \
    "$(_extract 'ultime righe del gc.log' UNRESOLVED_LOG)"
assert_eq "nessun .log nella query: nessun avviso" "" \
    "$(_extract 'ultime 100 righe' UNRESOLVED_LOG)"

# ─── SEARCH_PATTERN — non deve collidere con il glob ──────────────────────────
section "SEARCH_PATTERN vs NAMED_LOG_GLOB"

assert_eq "pattern di ricerca estratto" "NullPointerException" \
    "$(_extract 'cerca "NullPointerException" in produzione' SEARCH_PATTERN)"
assert_eq "ricerca non popola il glob" "" \
    "$(_extract 'cerca "NullPointerException" in produzione' NAMED_LOG_GLOB)"
assert_eq "trigger senza virgolette: __MISSING__" "__MISSING__" \
    "$(_extract 'cerca NullPointerException in produzione' SEARCH_PATTERN)"

# ─── Riepilogo ────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" \
    "$pass" "$fail" "$(( pass + fail ))"
printf "═══════════════════════════════════════════════════\n"

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
