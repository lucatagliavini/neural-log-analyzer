#!/bin/bash
#
# test-profile-config.sh — un profilo incompleto o mal configurato deve fallire
# con un messaggio PARLANTE, non con l'errore del primo consumatore che inciampa.
#
# Copre due difetti trovati montando il secondo profilo (usnext, 2026-08-17):
#   ENTCONF-1  entities.conf era trattato in tre modi diversi — obbligatorio in
#              normalize-query.sh, opzionale in chatbot.sh e param-extract.sh.
#              Su un profilo che non lo aveva, la query moriva con "No such file
#              or directory" senza dire quale file né a cosa serve.
#   TECH-1     SERVER_LOG_FORMAT carica utils-<fmt>.awk dinamicamente (è così che
#              si aggiunge una tecnologia senza toccare i tool) ma non verificava
#              che il file esistesse: un valore non supportato produceva
#              "gawk: fatal: cannot open source file" a metà risposta, dopo
#              l'header e il path del log.
#
# Uso: bash tests/test-profile-config.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"; fail=$(( fail + 1 ))
    fi
}
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Profilo completo di partenza, da cui si rimuove un pezzo per volta.
_mk_profile() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$ROOT_DIR/profiles/liquido/system.conf"   "$dir/"
    cp "$ROOT_DIR/profiles/liquido/domain.conf"   "$dir/"
    cp "$ROOT_DIR/profiles/liquido/entities.conf" "$dir/"
    # unigrams.txt/bigrams.txt/models NON si copiano più: da NLP-1 vivono nel
    # framework (nlp/) e lib/nlp-paths.sh li risolve lì anche per un PROFILE_DIR in
    # mktemp — la sua auto-locazione punta sempre al repo reale. È la conferma che
    # la risoluzione NON poteva stare in domain.conf, che una fixture copia altrove.
}

# ─── ENTCONF-1: file obbligatori del profilo ─────────────────────────────────
section "File obbligatori: messaggio parlante, non errore del consumatore"

_p="$_FIX/no_entities"
_mk_profile "$_p"; rm -f "$_p/entities.conf"
_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p" --query "test" 2>&1 || true)
assert_true "entities.conf mancante: dice 'Profilo incompleto'" \
    "$([[ "$_out" == *"Profilo incompleto"* ]] && echo 1 || echo 0)"
assert_true "  nomina il file mancante" \
    "$([[ "$_out" == *"entities.conf"* ]] && echo 1 || echo 0)"
assert_true "  spiega a cosa serve (non solo il nome)" \
    "$([[ "$_out" == *"normalizzazione delle entità"* ]] && echo 1 || echo 0)"
assert_true "  indica il profilo di riferimento" \
    "$([[ "$_out" == *"profiles/liquido"* ]] && echo 1 || echo 0)"
assert_true "  NON è l'errore grezzo di bash" \
    "$([[ "$_out" != *"No such file or directory"* ]] && echo 1 || echo 0)"

# normalize-query.sh è invocato anche fuori da chatbot.sh (build-dataset.sh, test,
# invocazione diretta): là il guard sui file non è passato, quindi serve il suo.
_out=$(PROFILE_DIR="$_p" bash "$LIB/normalize-query.sh" "errori oggi" 2>&1 || true)
assert_true "normalize-query diretto: messaggio esplicito, non 'No such file'" \
    "$([[ "$_out" == *"entities.conf mancante"* ]] && echo 1 || echo 0)"
# Lo stdout di normalize-query è passato a `eval` dal chiamante: l'errore deve
# restare nella forma `echo '...' >&2`, altrimenti diventerebbe codice eseguito.
assert_true "  l'errore è eval-safe (forma echo ... >&2)" \
    "$([[ "$_out" == echo*">&2" ]] && echo 1 || echo 0)"

# Anche gli altri due file obbligatori vanno segnalati.
_p2="$_FIX/no_domain"
_mk_profile "$_p2"; rm -f "$_p2/domain.conf"
_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p2" --query "test" 2>&1 || true)
# domain.conf è intercettato da un controllo PREESISTENTE più a monte
# (chatbot.sh:83, "Profilo non valido"), che precede il guard sui file: quel che
# conta è che il messaggio nomini il file e non sia l'errore grezzo di bash.
assert_true "domain.conf mancante: segnalato con un messaggio esplicito" \
    "$([[ "$_out" == *"domain.conf"* && "$_out" != *"No such file or directory"* ]] && echo 1 || echo 0)"

# Un profilo completo NON deve inciampare in questi controlli: l'errore atteso è
# quello sul contesto mancante (--env), che viene dopo.
_p3="$_FIX/completo"
_mk_profile "$_p3"
_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p3" --query "test" 2>&1 || true)
assert_true "profilo completo: nessun falso positivo sui file" \
    "$([[ "$_out" != *"Profilo incompleto"* ]] && echo 1 || echo 0)"

# ─── TECH-1: parser di tecnologia caricato dinamicamente ─────────────────────
section "SERVER_LOG_FORMAT: tecnologia non supportata"

# Fixture con log reali, così il tool arriva davvero al punto di caricare il parser.
_node="$_FIX/logs/prod/lxprjbliq04/prod/ClaimCenter"
mkdir -p "$_node"
for _b in undertow_access_log server gc; do
    echo "2026-08-17 10:00:00,000 ERROR [x.Y] test" > "$_node/${_b}.log"
done

_p4="$_FIX/tech_ignota"
_mk_profile "$_p4"
sed -i 's/^SERVER_LOG_FORMAT=.*/SERVER_LOG_FORMAT="tecnologia_inesistente"/' "$_p4/system.conf"
sed -i "s#^LOG_BASE_DIR=.*#LOG_BASE_DIR=\"$_FIX/logs\"#" "$_p4/system.conf"

_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p4" --env prod --node 4 \
        --query "errori nel server.log oggi" 2>&1 || true)
assert_true "tecnologia non supportata: dice quale manca" \
    "$([[ "$_out" == *"SERVER_LOG_FORMAT='tecnologia_inesistente' non supportato"* ]] && echo 1 || echo 0)"
# "Formati disponibili" (non "Tecnologie"): il messaggio è emesso da
# _require_awk_parser, l'helper condiviso fra SERVER_LOG_FORMAT e
# ACCESS_LOG_FORMAT introdotto con ACCESS-1.
assert_true "  elenca i formati disponibili" \
    "$([[ "$_out" == *"Formati disponibili:"*"jboss"* ]] && echo 1 || echo 0)"
# L'elenco NON deve includere i parser di un'altra famiglia: prima del filtro sul
# prefisso, fra le "tecnologie" del server log compariva "access-undertow", che è
# un parser di access log — un suggerimento sbagliato è peggio di nessuno.
assert_true "  e non include i parser di access log" \
    "$([[ "$_out" != *"Formati disponibili:"*"access-"* ]] && echo 1 || echo 0)"
assert_true "  spiega come aggiungerne una (le due funzioni richieste)" \
    "$([[ "$_out" == *"parse_server_log()"* && "$_out" == *"is_stack_frame()"* ]] && echo 1 || echo 0)"
assert_true "  NON è il 'gawk: fatal' grezzo" \
    "$([[ "$_out" != *"gawk: fatal"* ]] && echo 1 || echo 0)"

# La tecnologia supportata deve continuare a funzionare: il controllo non deve
# introdurre un falso negativo sui tool che leggono il server log.
_p5="$_FIX/tech_ok"
_mk_profile "$_p5"
sed -i "s#^LOG_BASE_DIR=.*#LOG_BASE_DIR=\"$_FIX/logs\"#" "$_p5/system.conf"
_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p5" --env prod --node 4 \
        --query "errori nel server.log oggi" 2>&1 || true)
assert_true "jboss (supportata): il tool gira, nessun errore di formato" \
    "$([[ "$_out" != *"non supportato"* ]] && echo 1 || echo 0)"
assert_true "  e trova l'ERROR nella fixture" \
    "$([[ "$_out" == *"ERROR"* ]] && echo 1 || echo 0)"

# ─── ACCESS_LOG_FORMAT: stesso meccanismo per il parser dell'access log ──────
section "ACCESS_LOG_FORMAT: plugin del parser access (ACCESS-1)"

# Dopo ACCESS-1 i 6 tool HTTP non contengono più regex di formato: le estrazioni
# vengono dalle funzioni di utils-access-<formato>.awk, selezionato da
# ACCESS_LOG_FORMAT. È il meccanismo che rende il bot portabile su un middleware
# con access log diverso (es. il combined di Apache) senza toccare i tool.
_p6="$_FIX/access_fmt_ignoto"
_mk_profile "$_p6"
sed -i "s#^LOG_BASE_DIR=.*#LOG_BASE_DIR=\"$_FIX/logs\"#" "$_p6/system.conf"
echo 'ACCESS_LOG_FORMAT="formato_inventato"' >> "$_p6/system.conf"
_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p6" --env prod --node 4 \
        --query "quanti errori 500 oggi" 2>&1 || true)
assert_true "ACCESS_LOG_FORMAT non supportato: messaggio dedicato" \
    "$([[ "$_out" == *"ACCESS_LOG_FORMAT='formato_inventato' non supportato"* ]] && echo 1 || echo 0)"
assert_true "  elenca i formati access disponibili (undertow)" \
    "$([[ "$_out" == *"Formati disponibili:"*"undertow"* ]] && echo 1 || echo 0)"
assert_true "  elenca le 6 funzioni che un nuovo parser deve fornire" \
    "$([[ "$_out" == *"access_status()"* && "$_out" == *"access_ip()"* ]] && echo 1 || echo 0)"

# Il default (nessun ACCESS_LOG_FORMAT in system.conf) deve essere "undertow":
# i profili esistenti non lo dichiarano e devono continuare a funzionare.
_p7="$_FIX/access_fmt_default"
_mk_profile "$_p7"
sed -i "s#^LOG_BASE_DIR=.*#LOG_BASE_DIR=\"$_FIX/logs\"#" "$_p7/system.conf"
assert_true "ACCESS_LOG_FORMAT assente: default undertow, nessun errore" \
    "$(_out=$("$ROOT_DIR/chatbot.sh" --profile "$_p7" --env prod --node 4 \
        --query "quanti errori 500 oggi" 2>&1 || true); \
      [[ "$_out" != *"non supportato"* ]] && echo 1 || echo 0)"

echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
