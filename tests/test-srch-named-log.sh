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
_today_eu="$(date +%d-%m-%Y)"

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT
_node="$_FIX/prod/lxprjbliq04"
mkdir -p "$_node/prod/ClaimCenter" "$_node/ClaimCenter/Guidewire"
echo "${_today_plain} 10:00:00,000 ERROR srv" > "$_node/prod/ClaimCenter/server.log"
echo "${_today_plain} 10:00:01,000 ERROR ServerBoomToken problema" >> "$_node/prod/ClaimCenter/server.log"
# Bug prod 2026-08-19: stringa reale che ha fatto crashare grep_named_log
# (eval risplittava il pattern sugli spazi, gawk leggeva le parole in più
# come nomi di file). Riusata verbatim, non un placeholder generico.
echo "${_today_plain} 10:00:02,000 WARN No HeadersTranscoder provided. fallback attivo" \
    >> "$_node/prod/ClaimCenter/server.log"
# Formato reale riconosciuto da logline_parse (ramo 2, utils-logline.awk):
# "[YYYY-MM-DDTHH:MM:SS.mmm+ZZZZ]" — non uno pseudo-formato "data INFO msg",
# che non ha alcun ramo dedicato e finirebbe nel messaggio "formato non
# riconosciuto" invece di essere trovato dalla ricerca (SRCH-2).
echo "[${_today_plain}T10:00:00.000+0200] GC pause (young) 45M->12M(128M) 20.000ms" \
    > "$_node/prod/ClaimCenter/gc.log"
echo "[${_today_plain}T10:00:01.000+0200] GC pause (young) GcPauseToken 45M->12M(128M) 25.432ms" \
    >> "$_node/prod/ClaimCenter/gc.log"
echo "10.0.0.1 [${_today_apache}:10:00:00 +0200] \"GET /a HTTP/1.1\" 200 100 100 - UA" \
    > "$_node/prod/ClaimCenter/undertow_access_log.log"
echo "10.0.0.1 [${_today_apache}:10:00:01 +0200] \"GET /AccessMarkerToken HTTP/1.1\" 200 100 100 - UA" \
    >> "$_node/prod/ClaimCenter/undertow_access_log.log"

# SRCH-2: seconda app senza gc.log — serve al caso "sorgente non disponibile
# per l'app di sessione" (deve dare [SKIP] esplicito, non output vuoto).
mkdir -p "$_node/prod/ContactManager"
echo "${_today_plain} 10:00:00,000 ERROR srv-cm" > "$_node/prod/ContactManager/server.log"
echo "10.0.0.1 [${_today_apache}:10:00:00 +0200] \"GET /cm HTTP/1.1\" 200 100 100 - UA" \
    > "$_node/prod/ContactManager/undertow_access_log.log"
# "searchHub" appare su ERROR, INFO e WARN; "NullPointer" solo su ERROR.
cat > "$_node/ClaimCenter/Guidewire/prod1nssd-cc.log" <<EOF
[main] USER ${_today_plain}T10:00:00,000 ERROR searchHub timeout su chiamata
[main] USER ${_today_plain}T10:01:00,000 ERROR NullPointerException altrove
[main] USER ${_today_plain}T10:02:00,000 INFO  searchHub chiamata riuscita
[main] USER ${_today_plain}T10:03:00,000 WARN  searchHub lento
EOF

# LOGSEL-1: log applicativo con formato NON Guidewire (nessun timestamp
# ISO+livello riconoscibile) — righe presenti ma nessuna nel formato atteso.
# Generico per costruzione: qualunque log con questo schema di contenuto
# innesca lo stesso messaggio, non solo l'access log (già gestito da un tool
# dedicato, mai instradato qui).
cat > "$_node/ClaimCenter/Guidewire/prod1nssd-formatolibero.log" <<EOF
10.0.0.1 [${_today_apache}:10:05:00 +0200] "GET /b HTTP/1.1" 500 200 100 - UA
10.0.0.1 [${_today_apache}:10:06:00 +0200] "GET /c HTTP/1.1" 200 100 100 - UA
EOF

# TS-1/bug#2: formato data EUROPEA (Pass.log, profilo usnext) — DD-MM-YYYY
# HH:MM:SS.mmm LEVEL messaggio. Prima della migrazione a logline_parse()
# (Intervento 1/2), grep_named_log.awk riconosceva solo la grammatica ISO
# Guidewire e scartava ogni riga di questo formato: "Nessuna riga riconosciuta
# nel formato atteso" anche con ERROR/WARN presenti. Fail-before/pass-after.
cat > "$_node/ClaimCenter/Guidewire/prod1nssd-euformat.log" <<EOF
${_today_eu} 10:00:00.132 ERROR SubjectUnisalute problema di validazione
${_today_eu} 10:01:00.132 WARN  SubjectUnisalute lentezza
${_today_eu} 10:02:00.132 INFO  SubjectUnisalute ok
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

section "LOGSEL-1: formato non riconosciuto distinto da 'nessuna riga col livello'"

# Righe presenti (2, lette) ma nessuna nel formato timestamp+livello atteso:
# il messaggio deve dirlo esplicitamente, non implicare "nessun errore" come
# faceva prima (falso negativo silenzioso, verificato in diagnosi su un
# access log Undertow reale).
_out_fmt=$(_run 'errori nel formatolibero.log')
assert_eq "righe non nel formato atteso: messaggio distinto, non 'Nessuna riga trovata (level=...)'" "1" \
    "$([[ "$_out_fmt" == *"formato atteso"* && "$_out_fmt" != *"Nessuna riga trovata (level="* ]] && echo 1 || echo 0)"
assert_eq "il messaggio riporta il numero di righe lette" "1" \
    "$([[ "$_out_fmt" == *"2 righe lette"* ]] && echo 1 || echo 0)"

section "TS-1/bug#2: formato data europea (Pass.log) riconosciuto, non 'formato atteso'"

assert_eq "'errori nel euformat.log' trova la riga ERROR (formato europeo)" "1" \
    "$(_righe 'errori nel euformat.log')"
assert_eq "livello ERROR riconosciuto in formato europeo" "ERROR" \
    "$(_livello 'errori nel euformat.log')"
_out_eu=$(_run 'errori nel euformat.log')
assert_eq "formato europeo: NON il messaggio 'formato atteso' (era il bug)" "1" \
    "$([[ "$_out_eu" != *"formato atteso"* ]] && echo 1 || echo 0)"

section "SRCH-2: ricerca testuale in un log di sistema (server/gc/access)"

# Stessa catena di SRCH-1 ma sul ramo nuovo: SYSLOG_KIND (param-extract.sh) al
# posto di NAMED_LOG, require_tool_sources sempre in testa (A3), kind passato a
# grep_named_log.awk per non trattare il timestamp fra quadre come un thread (A4).
assert_eq "'cerca X nel server.log' trova la riga" "1" \
    "$(_righe 'cerca "ServerBoomToken" nel server.log')"
assert_eq "  usa level=ALL (pattern senza livello nominato, stessa regola di SRCH-1)" "ALL" \
    "$(_livello 'cerca "ServerBoomToken" nel server.log')"

assert_eq "'cerca X nel gc.log' trova la riga" "1" \
    "$(_righe 'cerca "GcPauseToken" nel gc.log')"

assert_eq "'trova X nell.access log' trova la riga" "1" \
    "$(_righe "trova \"AccessMarkerToken\" nell'access log")"

section "Bug prod 2026-08-19: pattern con spazi non crasha (eval doppio parsing)"

# Diagnosi: "eval gawk ... -v pattern=\"\$_gnl_pattern\" ..." fa un secondo giro
# di parsing della shell; le virgolette che protteggono "$_gnl_pattern" nel
# primo giro non sopravvivono al secondo, quindi un pattern con spazi veniva
# risplittato in più argomenti — gawk legge le parole senza "=" come nomi di
# file da aprire ("cannot open file 'HeadersTranscoder' for reading"). Fix:
# printf '%q' produce una forma auto-quotata che regge il secondo giro.
_out_multi=$(_run 'cerca "No HeadersTranscoder provided." nel server.log')
assert_eq "pattern con spazi: nessun crash gawk" "1" \
    "$([[ "$_out_multi" != *"gawk:"*"fatal"* ]] && echo 1 || echo 0)"
assert_eq "pattern con spazi: trova la riga" "1" \
    "$(_righe 'cerca "No HeadersTranscoder provided." nel server.log')"

section "SRCH-2: pattern assente su un log di sistema — messaggio esplicito"

_out_srv_none=$(_run 'cerca "QQQNONESISTE" nel server.log')
assert_eq "pattern assente sul server.log: lo dice, e riporta il pattern" "1" \
    "$([[ "$_out_srv_none" == *"Nessuna riga trovata"* && "$_out_srv_none" == *"QQQNONESISTE"* ]] && echo 1 || echo 0)"

section "SRCH-2: sorgente non disponibile per l'app di sessione — [SKIP], non vuoto"

# ContactManager non ha gc.log nella fixture (esiste solo sotto ClaimCenter):
# require_tool_sources deve fermarsi con [SKIP], non restituire output vuoto —
# altrimenti l'utente non distingue "pattern non trovato" da "log inesistente".
_out_noskip=$(QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$PROFILE_DIR" \
    --base-dir "$_FIX" --env prod --node 4 --app ContactManager \
    --query 'cerca "GcPauseToken" nel gc.log' 2>&1)
assert_eq "gc.log assente sotto ContactManager: [SKIP] esplicito, non output vuoto" "1" \
    "$([[ "$_out_noskip" == *"[SKIP]"* ]] && echo 1 || echo 0)"
assert_eq "  il messaggio indica dove esiste davvero (ClaimCenter)" "1" \
    "$([[ "$_out_noskip" == *"ClaimCenter"* ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
