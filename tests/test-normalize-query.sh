#!/bin/bash
#
# test-normalize-query.sh — unit test per lib/normalize-query.sh
#
# Uso: bash tests/test-normalize-query.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
export PROFILE_DIR="$PROJECT_DIR/profiles/liquido"

PASS=0
FAIL=0

# eval in funzione bash non propaga le variabili allo scope chiamante.
# Usiamo un file temporaneo per passare il risultato all'esterno.
_NORM_TMP=$(mktemp)
trap 'rm -f "$_NORM_TMP"' EXIT

_run() {
    local query="$1"
    "$LIB_DIR/normalize-query.sh" "$query" 2>/dev/null > "$_NORM_TMP"
    # Unset prima per evitare che un run precedente inquini il successivo
    unset NORM_QUERY DETECTED_APP DETECTED_ENV DETECTED_NODE
    source "$_NORM_TMP"
}

assert_eq() {
    local label="$1" got="$2" expected="$3"
    if [[ "$got" == "$expected" ]]; then
        printf "  \033[32mPASS\033[0m  %s\n" "$label"
        (( PASS++ ))
    else
        printf "  \033[31mFAIL\033[0m  %s\n        got:      '%s'\n        expected: '%s'\n" \
               "$label" "$got" "$expected"
        (( FAIL++ ))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  \033[32mPASS\033[0m  %s\n" "$label"
        (( PASS++ ))
    else
        printf "  \033[31mFAIL\033[0m  %s\n        '%s' non trovato in: '%s'\n" \
               "$label" "$needle" "$haystack"
        (( FAIL++ ))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── APP alias ────────────────────────────────────────────────────────────"

_run "errori jboss di stamattina"
assert_eq "jboss → DETECTED_APP" "$DETECTED_APP" "jboss"
assert_contains "jboss → NORM_QUERY contiene <APP>" "$NORM_QUERY" "<APP>"

_run "problemi su liquido in prod"
assert_eq "liquido → DETECTED_APP" "$DETECTED_APP" "liquido"

_run "anomalie guidewire sul nodo 5"
assert_eq "guidewire → DETECTED_APP" "$DETECTED_APP" "guidewire"

_run "log del claimcenter"
assert_eq "claimcenter → DETECTED_APP" "$DETECTED_APP" "claimcenter"

_run "errori contactmanager"
assert_eq "contactmanager → DETECTED_APP" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── ENV (nomi diretti) ───────────────────────────────────────────────────"

_run "errori in prod nodo 2"
assert_eq "prod → DETECTED_ENV" "$DETECTED_ENV" "prod"
assert_contains "prod → NORM_QUERY contiene <ENV>" "$NORM_QUERY" "<ENV>"

_run "statistiche su cert"
assert_eq "cert → DETECTED_ENV" "$DETECTED_ENV" "cert"

_run "GC su coll nodo 7"
assert_eq "coll → DETECTED_ENV" "$DETECTED_ENV" "coll"

_run "access log di euro"
assert_eq "euro → DETECTED_ENV" "$DETECTED_ENV" "euro"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── ENV (sinonimi italiani) ──────────────────────────────────────────────"

_run "errori in produzione"
assert_eq "produzione → DETECTED_ENV=prod" "$DETECTED_ENV" "prod"

_run "log di integrazione nodo 3"
assert_eq "integrazione → DETECTED_ENV=inte" "$DETECTED_ENV" "inte"

_run "anomalie in collaudo"
assert_eq "collaudo → DETECTED_ENV=coll" "$DETECTED_ENV" "coll"

_run "errori in certificazione"
assert_eq "certificazione → DETECTED_ENV=cert" "$DETECTED_ENV" "cert"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── NODE ─────────────────────────────────────────────────────────────────"

_run "errori nodo 3"
assert_eq "nodo 3 → DETECTED_NODE=3" "$DETECTED_NODE" "3"
assert_contains "nodo 3 → NORM_QUERY contiene <NODE>" "$NORM_QUERY" "<NODE>"

_run "GC su nodo3"
assert_eq "nodo3 → DETECTED_NODE=3" "$DETECTED_NODE" "3"

_run "lentezza worker1"
assert_eq "worker1 → DETECTED_NODE=1" "$DETECTED_NODE" "1"

_run "sul nodo numero 12"
assert_eq "nodo numero 12 → DETECTED_NODE=12" "$DETECTED_NODE" "12"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Hostname completo ────────────────────────────────────────────────────"

_run "errori su lxprworkerliq01"
assert_eq "hostname → DETECTED_ENV=prod" "$DETECTED_ENV" "prod"
assert_eq "hostname → DETECTED_NODE=1"   "$DETECTED_NODE" "1"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Combinazione APP + ENV + NODE ────────────────────────────────────────"

_run "errori jboss in prod nodo 3 stamattina"
assert_eq "combo → DETECTED_APP" "$DETECTED_APP" "jboss"
assert_eq "combo → DETECTED_ENV" "$DETECTED_ENV" "prod"
assert_eq "combo → DETECTED_NODE" "$DETECTED_NODE" "3"
assert_contains "combo → NORM_QUERY <APP>"  "$NORM_QUERY" "<APP>"
assert_contains "combo → NORM_QUERY <ENV>"  "$NORM_QUERY" "<ENV>"
assert_contains "combo → NORM_QUERY <NODE>" "$NORM_QUERY" "<NODE>"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Query senza entità ───────────────────────────────────────────────────"

_run "quanti errori 500 ci sono stati stamattina"
assert_eq "no-entity → DETECTED_APP vuoto"  "$DETECTED_APP"  ""
assert_eq "no-entity → DETECTED_ENV vuoto"  "$DETECTED_ENV"  ""
assert_eq "no-entity → DETECTED_NODE vuoto" "$DETECTED_NODE" ""

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Abbreviazioni (cc, cm) ───────────────────────────────────────────────"

_run "errori nel cc sul nodo 5"
assert_eq "cc → DETECTED_APP=claimcenter" "$DETECTED_APP" "claimcenter"

_run "log cm in cert"
assert_eq "cm → DETECTED_APP=contactmanager" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Longest-match: contactmanager non matchato come 'contact' ────────────"

_run "log contactmanager in prod"
assert_eq "longest-match contactmanager" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── NORM_QUERY non contiene più i nomi concreti ──────────────────────────"

_run "errori jboss prod nodo 3"
# jboss, prod, nodo 3 devono essere rimpiazzati
if [[ "$NORM_QUERY" != *"jboss"* && "$NORM_QUERY" != *"prod"* && "$NORM_QUERY" != *"nodo"* ]]; then
    printf "  \033[32mPASS\033[0m  NORM_QUERY non contiene token concreti\n"
    (( PASS++ ))
else
    printf "  \033[31mFAIL\033[0m  NORM_QUERY contiene ancora token concreti: '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── LOGFILE: generalizzazione dei nomi di log ────────────────────────────"

# Il classificatore non deve conoscere i nomi dei log: normalize-query.sh li
# sostituisce con <LOGFILE>, così il modello impara la *forma* e resta valido per
# profili con log completamente diversi.

_run "errori nel cc.log"
assert_contains "cc.log → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"
assert_eq "cc.log preserva DETECTED_APP" "$DETECTED_APP" "claimcenter"

_run "errori nel cm.log"
assert_contains "cm.log → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"
assert_eq "cm.log preserva DETECTED_APP" "$DETECTED_APP" "contactmanager"

_run "errori nel api.log"
assert_contains "api.log → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"
assert_eq "api.log non implica un'app" "$DETECTED_APP" ""

# Il punto centrale: funziona anche per nomi NON in APP_LOG_NAMES. Sul nodo di
# produzione i log sono 28 e la whitelist ne elenca 16 — se la sostituzione
# dipendesse dalla lista, i restanti resterebbero senza segnale.
_run "ultime righe del policysearch.log"
assert_contains "log fuori whitelist → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"

_run "ultime righe del pc1nssprod.log"
assert_contains "nome mai visto → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"

# Glob quotato: sostituito virgolette incluse
_run 'ultime 10 righe di "*-cc.log"'
assert_contains "glob doppie virgolette → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"

_run "ultime 10 righe di '*-cc.log'"
assert_contains "glob apici singoli → <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"

# I log di infrastruttura hanno tool dedicati (filter_errors / tail_log via
# LOG_TYPE): generalizzarli li farebbe collassare sulla classe named-log.
_run "righe di errore nel server.log"
if [[ "$NORM_QUERY" == *"<LOGFILE>"* ]]; then
    printf "  \033[31mFAIL\033[0m  server.log NON deve diventare <LOGFILE>: '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
else
    printf "  \033[32mPASS\033[0m  server.log resta letterale (tool dedicato)\n"
    (( PASS++ ))
fi

_run "ultime righe del gc.log"
if [[ "$NORM_QUERY" == *"<LOGFILE>"* ]]; then
    printf "  \033[31mFAIL\033[0m  gc.log NON deve diventare <LOGFILE>: '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
else
    printf "  \033[32mPASS\033[0m  gc.log resta letterale (tool dedicato)\n"
    (( PASS++ ))
fi

# Bug reale in produzione (2026-08-07): "access.log" è un sinonimo digitato
# dagli utenti, ma il file su disco si chiama undertow_access_log.log
# (ACCESS_LOG_BASE). Senza SYSTEM_LOG_SYNONYMS, "access" non coincideva mai col
# basename esatto e la query collassava su <LOGFILE> (named-log generico)
# invece che sul tool dedicato dell'access log.
_run "ultime 50 righe del access.log"
if [[ "$NORM_QUERY" == *"<LOGFILE>"* ]]; then
    printf "  \033[31mFAIL\033[0m  access.log NON deve diventare <LOGFILE> (sinonimo di ACCESS_LOG_BASE): '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
else
    printf "  \033[32mPASS\033[0m  access.log resta letterale (sinonimo riconosciuto, tool dedicato)\n"
    (( PASS++ ))
fi

# "api" senza ".log" significa endpoint HTTP, non api.log: 17 esempi
# distribute_status dipendono da questa distinzione.
_run "quali api hanno più fallimenti"
if [[ "$NORM_QUERY" == *"<LOGFILE>"* ]]; then
    printf "  \033[31mFAIL\033[0m  'api' senza .log non deve diventare <LOGFILE>: '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
else
    printf "  \033[32mPASS\033[0m  'api' senza .log resta invariato (endpoint HTTP)\n"
    (( PASS++ ))
fi

# ─── SRCH-4: log di sistema quotato senza wildcard ───────────────────────────
# Bug prod segnalato il 2026-08-19: in `trova "X" nel "server.log"` ENTRAMBE le
# stringhe quotate diventavano <PATTERN>, perché "server.log" senza '*' non è
# glob-like. Il bigramma che discrimina SRCH-2 matcha la sottostringa LETTERALE
# server.log|gc.log|access.log, quindi non si attivava e la query cadeva su
# search_all_logs invece di grep_named_log.
printf "\n\033[1m── SRCH-4: nome di log di sistema quotato \033[0m\n"

_run 'sul nodo 3 di produzione trova "No HeadersTranscoder provided" nel "server.log" di oggi'
assert_contains "il nome del log di sistema resta LETTERALE" "$NORM_QUERY" "server.log"
assert_contains "la stringa di ricerca diventa <PATTERN>"    "$NORM_QUERY" "<PATTERN>"
# Non deve diventare <LOGFILE>: la sezione (b) esclude deliberatamente i log di
# sistema da quella generalizzazione, perché hanno tool dedicati.
if [[ "$NORM_QUERY" != *"<LOGFILE>"* ]]; then
    printf "  \033[32mPASS\033[0m  non diventa <LOGFILE> (i log di sistema ne sono esclusi)\n"; (( PASS++ ))
else
    printf "  \033[31mFAIL\033[0m  non diventa <LOGFILE>\n        got: '%s'\n" "$NORM_QUERY"; (( FAIL++ ))
fi

_run 'cerca "NPE" nel "gc.log"'
assert_contains "gc.log quotato resta letterale" "$NORM_QUERY" "gc.log"
_run "cerca 'NPE' nel 'access.log'"
assert_contains "access.log quotato (apici singoli) resta letterale" "$NORM_QUERY" "access.log"

# Confine: un glob quotato resta <LOGFILE>, la (a) ha priorità sulla (a-ter).
_run 'cerca "timeout" nel "*-cc.log"'
assert_contains "glob quotato resta <LOGFILE>" "$NORM_QUERY" "<LOGFILE>"
# Confine: una stringa quotata che NON è un log di sistema resta <PATTERN>.
_run 'cerca "NullPointerException" in tutti i log'
assert_contains "stringa non-log resta <PATTERN>" "$NORM_QUERY" "<PATTERN>"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: \033[32m%d\033[0m   FAIL: \033[31m%d\033[0m   TOTAL: %d\n" \
       "$PASS" "$FAIL" "$(( PASS + FAIL ))"
printf "═══════════════════════════════════════════════════\n"
echo ""
[[ "$FAIL" -eq 0 ]]
