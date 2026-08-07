#!/bin/bash
#
# test-srch-named-log.sh — SRCH-1: ricerca testuale in un log nominato.
#
# Copre la catena completa "cerca X nel cc.log", che attraversa tre componenti:
#   param-extract.sh   → SEARCH_PATTERN + LOG_LEVEL + LEVEL_EXPLICIT
#   dispatch.sh        → decide il livello e passa -v pattern al tool
#   grep_named_log.awk → applica il filtro testuale
#
# Il canale `pattern` esisteva già nel tool AWK (sua riga 5 e 35) e
# SEARCH_PATTERN era già estratto da param-extract.sh: mancava solo il
# collegamento in dispatch.sh. Nessun retrain — il classificatore instradava
# già su grep_named_log al 96.7%.
#
# LA REGOLA SEMANTICA (decisa con l'utente, 2026-08-06) è ciò che questi test
# proteggono: se la query porta un pattern esplicito e NON nomina un livello,
# si cerca in TUTTO il file (level=ALL), perché l'intento è trovare quel testo.
# Se il livello è nominato, vince quello. Senza pattern, comportamento di prima.
# Un errore qui non produce un crash: restituisce MENO righe di quelle che
# l'utente si aspetta, silenziosamente.
#
# Uso: bash tests/test-srch-named-log.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROFILE_DIR="$ROOT_DIR/profiles/liquido"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso: '%s'\n        avuto:  '%s'\n" \
            "$desc" "$expected" "$actual"; fail=$(( fail + 1 ))
    fi
}
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

# ─── Fixture: un log applicativo con lo stesso testo su livelli diversi ───────
# Le query senza range esplicito filtrano sulla data corrente: la fixture usa
# SEMPRE la data del giorno di esecuzione, non un valore hardcoded — altrimenti
# il test smette di trovare dati appena cambia il giorno (bug reale osservato
# 2026-08-07: fixture datata 2026-08-06).
_today_plain="$(date +%Y-%m-%d)"
_today_apache="$(date +%d/%b/%Y)"

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT
_node="$_FIX/prod/lxprjbliq04"
mkdir -p "$_node/prod/ClaimCenter" "$_node/ClaimCenter/Guidewire"
echo "${_today_plain} 10:00:00,000 ERROR srv" > "$_node/prod/ClaimCenter/server.log"
echo "${_today_plain}T10:00:00 INFO gc" > "$_node/prod/ClaimCenter/gc.log"
echo "10.0.0.1 [${_today_apache}:10:00:00 +0200] \"GET /a HTTP/1.1\" 200 100 100 - UA" \
    > "$_node/prod/ClaimCenter/undertow_access_log.log"
# "searchHub" appare su ERROR, INFO e WARN; "NullPointer" solo su ERROR.
cat > "$_node/ClaimCenter/Guidewire/prod1nssd-cc.log" <<EOF
[main] USER ${_today_plain}T10:00:00,000 ERROR searchHub timeout su chiamata
[main] USER ${_today_plain}T10:01:00,000 ERROR NullPointerException altrove
[main] USER ${_today_plain}T10:02:00,000 INFO  searchHub chiamata riuscita
[main] USER ${_today_plain}T10:03:00,000 WARN  searchHub lento
EOF

_run() {
    QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$PROFILE_DIR" \
        --base-dir "$_FIX" --env prod --node 4 --query "$1" 2>&1
}
# _righe QUERY → numero di righe trovate (dal footer "Totale: N righe")
_righe() {
    local o; o=$(_run "$1")
    grep -oE 'Totale: [0-9]+ righe' <<< "$o" | grep -oE '[0-9]+' | head -1 || echo 0
}
# _livello QUERY → il livello effettivamente usato, dall'etichetta mostrata
_livello() {
    _run "$1" | grep -oE 'level=[A-Z+]+' | head -1 | cut -d= -f2
}

section "param-extract: LEVEL_EXPLICIT distingue livello chiesto da default"

_pe() { bash "$ROOT_DIR/lib/param-extract.sh" "$1" | grep -E "^$2=" | cut -d"'" -f2; }

assert_eq "'cerca X nel cc.log': pattern estratto"        "searchHub" "$(_pe 'cerca "searchHub" nel cc.log' SEARCH_PATTERN)"
assert_eq "'cerca X nel cc.log': livello NON esplicito"   "0"         "$(_pe 'cerca "searchHub" nel cc.log' LEVEL_EXPLICIT)"
assert_eq "'errori nel cc.log': livello esplicito"        "1"         "$(_pe 'errori nel cc.log' LEVEL_EXPLICIT)"
assert_eq "'errori nel cc.log': nessun pattern"           ""          "$(_pe 'errori nel cc.log' SEARCH_PATTERN)"
assert_eq "'warning nel cc.log': livello WARN esplicito"  "1"         "$(_pe 'warning nel cc.log' LEVEL_EXPLICIT)"
assert_eq "'warning nel cc.log': livello è WARN"          "WARN"      "$(_pe 'warning nel cc.log' LOG_LEVEL)"

section "La regola: pattern senza livello → cerca in tutto il file"

assert_eq "'cerca X nel cc.log' usa level=ALL"     "ALL" "$(_livello 'cerca "searchHub" nel cc.log')"
assert_eq "trova searchHub su ERROR+INFO+WARN"     "3"   "$(_righe 'cerca "searchHub" nel cc.log')"
assert_eq "'cerca NullPointer' trova solo l'ERROR" "1"   "$(_righe 'cerca "NullPointer" nel cc.log')"

section "Il livello esplicito vince sul pattern"

assert_eq "'cerca X negli errori del cc.log' usa ERROR" "ERROR" \
    "$(_livello 'cerca "searchHub" negli errori del cc.log')"
assert_eq "e trova solo la riga ERROR" "1" \
    "$(_righe 'cerca "searchHub" negli errori del cc.log')"

section "Senza pattern: comportamento invariato (nessuna regressione)"

assert_eq "'errori nel cc.log' usa ERROR"        "ERROR" "$(_livello 'errori nel cc.log')"
assert_eq "'errori nel cc.log' trova 2 righe"    "2"     "$(_righe 'errori nel cc.log')"

section "Pattern inesistente: messaggio esplicito, non output vuoto"

_out_none=$(_run 'cerca "QQQNONESISTE" nel cc.log')
assert_eq "pattern non trovato: lo dice, e riporta il pattern" "1" \
    "$([[ "$_out_none" == *"Nessuna riga trovata"* && "$_out_none" == *"QQQNONESISTE"* ]] && echo 1 || echo 0)"

section "Il pattern compare nell'etichetta mostrata all'utente"

# Senza questa, "(level=ALL)" da solo sembrerebbe un errore di configurazione.
_out_lbl=$(_run 'cerca "searchHub" nel cc.log')
assert_eq "l'etichetta mostra il pattern cercato" "1" \
    "$([[ "$_out_lbl" == *'cerca "searchHub"'* ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
