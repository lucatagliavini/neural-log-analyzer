#!/bin/bash
#
# test-param-extract.sh — unit test per lib/param-extract.sh.
#
# Copre i parametri che decidono QUALE file viene letto, dove un errore non
# produce un crash ma un risultato plausibile e sbagliato:
#   NAMED_LOG        nome del log: alias da APP_LOG_NAMES, oppure qualsiasi
#                    "<nome>.log" via fallback (la whitelist è di alias, non di
#                    log ammessi) — esclusi i log di infrastruttura
#   NAMED_LOG_GLOB   escape hatch glob tra virgolette (+ validazione path traversal)
#   SEARCH_PATTERN   stringa di ricerca per search_all_logs
#
# Copre anche suggest_available_logs() e skip_msg() di dispatch.sh, che completano
# la diagnostica quando il log richiesto non esiste.
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

# ─── LOG_ORDER (NEXT-2: head/tail come parametro) ─────────────────────────────
section "LOG_ORDER (direzione head/tail)"

assert_eq "default: tail"              "tail" "$(_extract 'ultime 10 righe del log' LOG_ORDER)"
assert_eq "'prime N righe' -> head"    "head" "$(_extract 'prime 10 righe del log' LOG_ORDER)"
# "prima" singolare non e' coperto di proposito: e' ambiguo in italiano
# ("prima riga" ordinale vs "successo prima" temporale/"before"), e zero query
# nel dataset lo usano nel senso ordinale. Solo "prime" plurale -> head.
assert_eq "'prime righe' -> head"      "head" "$(_extract 'mostrami le prime righe' LOG_ORDER)"
assert_eq "'righe iniziali' -> head"   "head" "$(_extract 'righe iniziali del cc.log' LOG_ORDER)"
assert_eq "'dall'inizio' -> head"      "head" "$(_extract "leggi il log dall'inizio" LOG_ORDER)"
# "primavera" non deve attivare head: \bprim[ei]\b richiede il confine di parola
assert_eq "falso positivo evitato ('primavera')" "tail" \
    "$(_extract 'log della primavera scorsa' LOG_ORDER)"

# ─── TAIL_N — "prime N righe" deve rispettare N, non ricadere sul default ────
# Bug reale (2026-08-05): il branch TAIL_N riconosceva solo "ultim[ei] N righe",
# non "prim[ei] N righe" — quindi "prime 10 righe" restava a TAIL_N=50 (il
# default) pur avendo scritto un numero esplicito. LOG_ORDER intanto diventava
# correttamente "head": i due parametri divergevano silenziosamente.
section "TAIL_N con \"prime N righe\""

assert_eq "'prime 10 righe' -> TAIL_N=10 (non il default 50)" "10" \
    "$(_extract 'prime 10 righe del log' TAIL_N)"
assert_eq "'prime 10 righe di \"server.log\"' -> TAIL_N=10" "10" \
    "$(_extract 'prime 10 righe del "server.log"' TAIL_N)"

# ─── LOG_TYPE — "server log"/"server.log" deve risolvere al server log ──────
# Bug reale (2026-08-05): la regex copriva solo l'ordine "log <parola>" (log
# applicativo, log jboss, log di sistema), mai l'ordine inverso "<parola> log"
# (server log, server.log) — nonostante il dataset labeled contenga entrambi gli
# ordini per "server". "ultime righe del server.log" restava con LOG_TYPE=''
# (fallback access log) invece di leggere il server log richiesto esplicitamente.
section "LOG_TYPE (\"server log\" / \"server.log\" in entrambi gli ordini)"

assert_eq "'server log' -> LOG_TYPE=server"    "server" \
    "$(_extract 'ultime righe del server log' LOG_TYPE)"
assert_eq "'server.log' tra virgolette -> LOG_TYPE=server" "server" \
    "$(_extract 'ultime 10 righe del "server.log"' LOG_TYPE)"
assert_eq "'log \"server.log\"' -> LOG_TYPE=server" "server" \
    "$(_extract 'ultime 10 righe del log "server.log"' LOG_TYPE)"
assert_eq "'log applicativo' (ordine originale) -> LOG_TYPE=server" "server" \
    "$(_extract 'ultime righe del log applicativo' LOG_TYPE)"
assert_eq "'log di sistema' -> LOG_TYPE=server"  "server" \
    "$(_extract 'ultime righe del log di sistema' LOG_TYPE)"
# Falso positivo da evitare: un NAMED_LOG che contiene "server" come sottostringa
# non deve attivare LOG_TYPE=server (il \b finale su "server" li distingue).
assert_eq "falso positivo evitato ('serverfarm.log')" "" \
    "$(_extract 'ultime righe del serverfarm.log' LOG_TYPE)"

# ─── "oggi" — giorno di calendario intero, non "fino a ora" ──────────────────
# Bug reale (2026-08-05): "oggi" produceva TIME_TO=now_hhmm invece di 23:59,
# incoerente col default di sessione (chatbot.sh: oggi 00:00->23:59) e con
# "ieri" (00:00->23:59). Segnalato dall'utente confrontando "stamattina" (finestra
# fissa 06:00-12:00, coerente) con "oggi" (finestra che si restringeva all'ora
# della query). Fix in lib/utils-time.sh: _RE_TODAY ora usa 23:59 fisso.
section "\"oggi\" (giorno di calendario intero)"

today="$(date +%Y-%m-%d)"
assert_eq "'oggi' -> TIME_FROM inizio giornata" "${today}T00:00" \
    "$(_extract 'errori oggi' TIME_FROM)"
assert_eq "'oggi' -> TIME_TO fine giornata (23:59, non ora corrente)" "${today}T23:59" \
    "$(_extract 'errori oggi' TIME_TO)"

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

# File ruotati: sul nodo la rotazione produce "…-cc.log-2026-07-26-<epoch>.gz",
# dove ".log" sta IN MEZZO. Richiedere ".log" finale rendeva il glob incapace di
# raggiungere qualsiasi storico.
assert_eq "glob ruotato .log.gz accettato" "*-cc.log.gz" \
    "$(_extract 'ultime righe di "*-cc.log.gz"' NAMED_LOG_GLOB)"
assert_eq "glob ruotato con data accettato" "*-cc.log-2026-07-26-1785016801.gz" \
    "$(_extract 'ultime righe di "*-cc.log-2026-07-26-1785016801.gz"' NAMED_LOG_GLOB)"
assert_eq "glob ruotato con wildcard finale accettato" "*-cc.log-*.gz" \
    "$(_extract 'ultime righe di "*-cc.log-*.gz"' NAMED_LOG_GLOB)"
# ".logico" non e' un log: la regex ancora ".log" a fine token o prima di [-.]
assert_eq "'.logico' rifiutato" "" \
    "$(_extract 'ultime righe di "*.logico"' NAMED_LOG_GLOB)"

# Validazione: input che finisce in `find -name`, la whitelist e' obbligatoria
assert_eq "path traversal '..' rifiutato" "" \
    "$(_extract 'righe di "../*.log"' NAMED_LOG_GLOB)"
assert_eq "slash rifiutato" "" \
    "$(_extract 'righe di "/etc/*.log"' NAMED_LOG_GLOB)"
assert_eq "traversal senza glob ignorato" "" \
    "$(_extract 'righe di "../../etc/passwd"' NAMED_LOG_GLOB)"

# ─── NAMED_LOG oltre la whitelist ─────────────────────────────────────────────
section "NAMED_LOG fuori whitelist (fallback)"

# NAMED_LOG risolve QUALSIASI "<token>.log" sintatticamente valido, non solo i nomi
# in APP_LOG_NAMES: quella è una lista di alias (scorciatoie usabili senza
# estensione), non di log ammessi. Sul nodo i log sono 28 contro 16 in whitelist.
assert_eq "nome fuori whitelist risolto" "pc1nssprod" \
    "$(_extract 'ultime 10 righe del pc1nssprod.log del nodo 5 di produzione' NAMED_LOG)"
# Il case va preservato: i nomi reali hanno maiuscole e finiscono in `find -name`,
# che è case-sensitive
assert_eq "case preservato per find -name" "concurrentDataChangeExceptionLog" \
    "$(_extract 'ultime righe del concurrentDataChangeExceptionLog.log' NAMED_LOG)"
assert_eq "match parziale whitelist risolto per intero" "xyzapi" \
    "$(_extract 'ultime righe del xyzapi.log' NAMED_LOG)"
# I log di infrastruttura restano esclusi: hanno tool dedicati (filter_errors,
# tail_log via LOG_TYPE)
assert_eq "server.log escluso dal fallback" "" \
    "$(_extract 'righe di errore nel server.log' NAMED_LOG)"
assert_eq "gc.log escluso dal fallback" "" \
    "$(_extract 'ultime righe del gc.log' NAMED_LOG)"
assert_eq "nessun .log: NAMED_LOG vuoto" "" \
    "$(_extract 'ultime 100 righe' NAMED_LOG)"
# Il valore finisce in `find -name`: serve almeno un alfanumerico, altrimenti
# "..log" darebbe base "." e "-.log" darebbe "-"
assert_eq "'..log' rifiutato (nessun alfanumerico)" "" \
    "$(_extract 'righe di ..log' NAMED_LOG)"
assert_eq "'-.log' rifiutato (nessun alfanumerico)" "" \
    "$(_extract 'righe di -.log' NAMED_LOG)"

# UNRESOLVED_LOG è stato rimosso: da quando NAMED_LOG risolve qualsiasi nome restava
# vuoto in ogni caso reale, e suggest_available_logs() fa lo stesso lavoro guardando
# i file del nodo invece degli alias di configurazione. Qui si verifica che non venga
# più emesso, così un ripristino accidentale non passa inosservato.
_emitted=$(bash "$ROOT_DIR/lib/param-extract.sh" 'ultime righe del qualsiasi.log' 2>/dev/null \
           | grep -c "^UNRESOLVED_LOG=" || true)
assert_eq "UNRESOLVED_LOG non piu' emesso" "0" "$_emitted"

# ─── SEARCH_PATTERN — non deve collidere con il glob ──────────────────────────
section "SEARCH_PATTERN vs NAMED_LOG_GLOB"

assert_eq "pattern di ricerca estratto" "NullPointerException" \
    "$(_extract 'cerca "NullPointerException" in produzione' SEARCH_PATTERN)"
assert_eq "ricerca non popola il glob" "" \
    "$(_extract 'cerca "NullPointerException" in produzione' NAMED_LOG_GLOB)"
assert_eq "trigger senza virgolette: __MISSING__" "__MISSING__" \
    "$(_extract 'cerca NullPointerException in produzione' SEARCH_PATTERN)"

# ─── DETECTED_NODE deve sopravvivere all'eval di param-extract.sh ─────────────
# Bug reale (2026-08-05): chatbot.sh:179-198 esegue normalize-query.sh (che
# popola DETECTED_NODE), poi invoca param-extract.sh via `eval "$(... )"`.
# param-extract.sh gira in un sottoprocesso (command substitution) e non fa
# altro che RI-EMETTERE DETECTED_NODE così com'è nel suo ambiente (vedi righe
# 223-227 del file) — non lo calcola. Se DETECTED_NODE non è esportata dalla
# shell chiamante prima di quella eval, il sottoprocesso lo eredita vuoto e lo
# ri-emette vuoto, azzerando nella shell padre il valore appena rilevato da
# normalize-query.sh. Impattava solo search_all_logs, l'unico tool che legge
# DETECTED_NODE direttamente invece di ACTIVE_NODE (già risolto prima
# dell'eval): "cerca X nel log del nodo 12" perdeva lo scope sul nodo 12 e
# cercava su tutti i nodi. Fix: export DETECTED_APP DETECTED_ENV DETECTED_NODE
# subito dopo normalize-query.sh, stesso pattern già usato per NORM_QUERY.
section "DETECTED_NODE attraverso l'eval di param-extract.sh (replica chatbot.sh)"

_query='cerca "searchHub" nel log del nodo 12'

_without_export=$(
    source <("$ROOT_DIR/lib/normalize-query.sh" "$_query")
    eval "$(bash "$ROOT_DIR/lib/param-extract.sh" "$_query")"
    echo "$DETECTED_NODE"
)
assert_eq "senza export: DETECTED_NODE si azzera (bug riprodotto)" "" "$_without_export"

_with_export=$(
    source <("$ROOT_DIR/lib/normalize-query.sh" "$_query")
    export DETECTED_APP DETECTED_ENV DETECTED_NODE
    eval "$(bash "$ROOT_DIR/lib/param-extract.sh" "$_query")"
    echo "$DETECTED_NODE"
)
assert_eq "con export: DETECTED_NODE sopravvive (fix)" "12" "$_with_export"

assert_eq "chatbot.sh esporta DETECTED_NODE prima dell'eval" "1" \
    "$(awk '
        /export NORM_QUERY/  { seen_norm=1 }
        seen_norm && /export DETECTED_APP DETECTED_ENV DETECTED_NODE/ { found=1 }
        /param-extract\.sh/ && found { print 1; exit }
    ' "$ROOT_DIR/chatbot.sh")"

# ─── utils-logfiles: nome logico e risoluzione glob ───────────────────────────
section "utils-logfiles (rotazione e disambiguazione)"

source "$ROOT_DIR/lib/utils-logfiles.sh"

# Il "nome logico" e' la chiave per distinguere le rotazioni dello stesso log
# (da leggere insieme) da log diversi (da disambiguare).
assert_eq "nome logico: file corrente" "prod1nsse-cc" \
    "$(logfile_logical_name "prod1nsse-cc.log")"
assert_eq "nome logico: ruotato con data" "prod1nsse-cc" \
    "$(logfile_logical_name "/dir/prod1nsse-cc.log-2026-07-26-1785016801.gz")"
assert_eq "nome logico: ruotato numerico" "prod1nsse-cc" \
    "$(logfile_logical_name "prod1nsse-cc.log.3.gz")"
assert_eq "nome logico: log diverso non collide" "prod1nsse-ccJBatch" \
    "$(logfile_logical_name "prod1nsse-ccJBatch.log")"

# resolve_log_glob su fixture temporanea
_FIX=$(mktemp -d)
for _f in prod1nsse-cc.log prod1nsse-ccCanaliz.log prod1nsse-ccJBatch.log; do
    echo "[main] SYSTEM 2026-08-04T12:00:00,000 INFO riga" > "$_FIX/$_f"
done
echo "[main] SYSTEM 2026-08-01T10:00:00,000 INFO storica" | gzip \
    > "$_FIX/prod1nsse-cc.log-2026-08-01-178500000.gz"

# Match univoco (solo rotazioni dello stesso log): nessuna disambiguazione
assert_eq "glob univoco sceglie il corrente" "prod1nsse-cc.log" \
    "$(basename "$(resolve_log_glob "$_FIX" '*-cc.log' 2>/dev/null)")"
# Match ambiguo (log diversi): sceglie il non-ruotato e avvisa su stderr
assert_eq "glob ambiguo sceglie un non-ruotato" "prod1nsse-cc.log" \
    "$(basename "$(resolve_log_glob "$_FIX" '*cc*.log' 2>/dev/null)")"
_amb_msg=$(resolve_log_glob "$_FIX" '*cc*.log' 2>&1 >/dev/null | head -1)
if [[ "$_amb_msg" == *"corrisponde a 3 log diversi"* ]]; then
    printf "  ${GREEN}PASS${RESET}  glob ambiguo avvisa con l'elenco\n"; pass=$(( pass + 1 ))
else
    printf "  ${RED}${BOLD}FAIL${RESET}  glob ambiguo: avviso assente o diverso\n"
    printf "        ottenuto: '%s'\n" "$_amb_msg"; fail=$(( fail + 1 ))
fi

# Timestamp Guidewire: prima non era riconosciuto (ts=0 per tutti i log Guidewire),
# quindi il filtro temporale di select_log_files non poteva discriminare.
_gw_ts=$(_logfiles_read_first_ts "$_FIX/prod1nsse-cc.log")
assert_eq "ts Guidewire letto (non 0)" "2026-08-04" \
    "$(date -d "@$_gw_ts" +%Y-%m-%d 2>/dev/null)"
_gz_ts=$(_logfiles_read_first_ts "$_FIX/prod1nsse-cc.log-2026-08-01-178500000.gz")
assert_eq "ts Guidewire letto da .gz" "2026-08-01" \
    "$(date -d "@$_gz_ts" +%Y-%m-%d 2>/dev/null)"

rm -rf "$_FIX"

# ─── suggest_available_logs: cosa c'è davvero sul nodo ────────────────────────
section "suggest_available_logs (aiuto sui log inesistenti)"

# L'avviso di param-extract mostra gli ALIAS di entities.conf, che possono divergere
# dal disco ("plugin" in whitelist contro "plugins" reale). Qui si guarda il disco.
source "$ROOT_DIR/lib/dispatch.sh" 2>/dev/null || true

_FIX2=$(mktemp -d)
for _f in prod1nsse-cc.log prod1nsse-plugins.log prod1nsse-policysearch.log; do
    echo "[main] SYSTEM 2026-08-04T12:00:00,000 INFO r" > "$_FIX2/$_f"
done

_near=$(suggest_available_logs "$_FIX2" "plugin" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if [[ "$_near" == *"Forse cercavi"* && "$_near" == *"plugins.log"* ]]; then
    printf "  ${GREEN}PASS${RESET}  nome simile suggerito (plugin → plugins)\n"; pass=$(( pass + 1 ))
else
    printf "  ${RED}${BOLD}FAIL${RESET}  nome simile non suggerito: '%s'\n" "$_near"; fail=$(( fail + 1 ))
fi

_all=$(suggest_available_logs "$_FIX2" "inesistente" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if [[ "$_all" == *"Log presenti"* && "$_all" == *"policysearch"* ]]; then
    printf "  ${GREEN}PASS${RESET}  nome assente → elenco dei log reali\n"; pass=$(( pass + 1 ))
else
    printf "  ${RED}${BOLD}FAIL${RESET}  elenco non prodotto: '%s'\n" "$_all"; fail=$(( fail + 1 ))
fi

_empty=$(suggest_available_logs "$_FIX2/inesistente" "x" 2>&1)
assert_eq "dir inesistente: nessun output" "" "$_empty"

rm -rf "$_FIX2"

# ─── skip_msg: warning visibile ───────────────────────────────────────────────
section "skip_msg (visibilita' dei warning)"

# Gli [SKIP] erano testo bianco identico all'output normale e si perdevano fra
# le righe di log: devono essere evidenziati come warning.
#
# Dal 2026-08-06 il colore viene dal TEMA attivo (C_WARN), non è più `\033[33m`
# hardcoded — e il default del progetto è mono (nessun colore). Quindi il test
# verifica la PROPRIETÀ ("usa il colore di warning del tema") e non un valore
# fisso: con un tema a colori lo [SKIP] è avvolto in C_WARN…C_RESET, con mono
# resta testo puro. Asserire `\033[33m` legherebbe il test a un tema
# particolare, e fallirebbe legittimamente cambiando il default.
_sk_theme=$(C_WARN=$'\033[33m' C_RESET=$'\033[0m' bash -c 'source "$1/lib/dispatch.sh" 2>/dev/null; skip_msg "messaggio di prova"' _ "$ROOT_DIR" 2>/dev/null)
if [[ "$_sk_theme" == $'\033[33m'* && "$_sk_theme" == *$'\033[0m' ]]; then
    printf "  ${GREEN}PASS${RESET}  [SKIP] usa C_WARN/C_RESET del tema\n"; pass=$(( pass + 1 ))
else
    printf "  ${RED}${BOLD}FAIL${RESET}  [SKIP] non usa i colori del tema: %q\n" "$_sk_theme"; fail=$(( fail + 1 ))
fi
# Con il tema mono (default) non deve emettere NESSUNA sequenza ANSI: è il
# requisito per cui mono esiste — output consumabile da un servizio.
_sk_mono=$(C_WARN="" C_RESET="" bash -c 'source "$1/lib/dispatch.sh" 2>/dev/null; skip_msg "messaggio di prova"' _ "$ROOT_DIR" 2>/dev/null)
assert_eq "[SKIP] con tema mono: nessuna sequenza ANSI" "[SKIP] messaggio di prova" "$_sk_mono"

_sk=$(skip_msg "messaggio di prova")
assert_eq "[SKIP] conserva il messaggio" "[SKIP] messaggio di prova" \
    "$(sed 's/\x1b\[[0-9;]*m//g' <<< "$_sk")"
# printf con il messaggio come ARGOMENTO, non come formato: un % nel nome di un log
# non deve essere interpretato
assert_eq "[SKIP] robusto su '%'" "[SKIP] Log 100%_x non trovato" \
    "$(skip_msg 'Log 100%_x non trovato' | sed 's/\x1b\[[0-9;]*m//g')"

# Nessun `echo "[SKIP]` residuo in dispatch.sh: tutti devono passare da skip_msg,
# altrimenti sfuggirebbero alla colorazione
_raw=$(grep -c 'echo "\[SKIP\]' "$ROOT_DIR/lib/dispatch.sh" || true)
assert_eq "nessun [SKIP] non colorato in dispatch.sh" "0" "$_raw"

# ─── Riepilogo ────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" \
    "$pass" "$fail" "$(( pass + fail ))"
printf "═══════════════════════════════════════════════════\n"

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
