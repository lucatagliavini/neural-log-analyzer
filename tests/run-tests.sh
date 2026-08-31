#!/bin/bash
#
# Test suite neural-log-analyzer.
#
# Uso:
#   bash tests/run-tests.sh [--level1] [--level2 --env <env> --node <node>] [--profile <dir>]
#
# --level1          esegue i test di intent (locale, nessun log) e le unit test
#                    con fixture locali: utils-logfiles, param-extract,
#                    search_all_logs, correlate_gc_slow, slow_requests
# --level2          esegue anche i test di output (richiede --env e --node)
# --env <env>       ambiente target per level2 (es: prod, coll)
# --node <node>     nodo target per level2 (es: 5, 12)
# --profile <dir>   profilo da usare (default: profiles/liquido)
# --parity          esegue anche il test di parità bash/Python (~4 min, 1008 query)
#
# Test standalone non inclusi qui (eseguirli separatamente):
#   tests/test-normalize-query.sh     unit test della normalizzazione entità
#   tests/test-normalize-parity.sh    parità bash/Python (vedi --parity)
#   tests/smoke-tools.sh              smoke test sul server, richiede log reali
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"

PROFILE_DIR="$ROOT_DIR/profiles/liquido"
RUN_L1=1; RUN_L2=0; RUN_PARITY=0
L2_ENV=""; L2_NODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --level1)  RUN_L1=1; shift ;;
        --level2)  RUN_L2=1; shift ;;
        --parity)  RUN_PARITY=1; shift ;;
        --env)     L2_ENV="$2";  shift 2 ;;
        --node)    L2_NODE="$2"; shift 2 ;;
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

export PROFILE_DIR

# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1).
source "$LIB_DIR/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"

# ─── Colori ──────────────────────────────────────────────────────────────────
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"
BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"

pass=0; fail=0; warn=0

# ─── Helpers ─────────────────────────────────────────────────────────────────
print_header() {
    printf "\n${BOLD}%s${RESET}\n" "$1"
    printf "%s\n" "────────────────────────────────────────────────────────────────────"
}

result_line() {
    local status="$1" label="$2" tool="$3" query="$4" detail="$5"
    case "$status" in
        PASS) printf "${GREEN}PASS${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              pass=$(( pass + 1 )) ;;
        FAIL) printf "${RED}${BOLD}FAIL${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              fail=$(( fail + 1 )) ;;
        WARN) printf "${YELLOW}WARN${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              warn=$(( warn + 1 )) ;;
    esac
}

# ─── Prima fase della pipeline: un solo punto di verità ───────────────────────
#
# Replica la sequenza esatta di chatbot.sh (righe 336-363) per la fase che
# precede i tool: normalizza → esporta le entità → inferisce → estrae i
# parametri. Esiste come funzione unica perché i due loop che la usano
# (run_intent_tests, run_param_tests) devono misurare lo STESSO percorso: due
# repliche indipendenti divergerebbero, ed è precisamente il difetto che ha reso
# invisibile il train/serve skew sui named log (NLOG-4) e che il principio 2 di
# CLAUDE.md vieta.
#
# Tre dettagli che rendono la replica fedele, e che una versione approssimata
# sbaglierebbe:
#   1. NORM_QUERY esportata prima di infer.sh — è ciò che la rete vede davvero
#   2. DETECTED_APP/ENV/NODE esportate prima di param-extract.sh, che le
#      ri-emette invariate (chatbot.sh:345; ometterle azzerava il nodo appena
#      rilevato — bug reale del 2026-08-05)
#   3. param-extract.sh riceve la query GREZZA, non NORM_QUERY: i placeholder
#      <APP>/<LOGFILE> servono al classificatore, non all'estrazione parametri
#
# _front_end QUERY [tool|all]
#   tool → emette solo "TOOL <nome> <prob>"
#   all  → emette anche le righe VAR='valore' di param-extract.sh
_front_end() {
    local query="$1" want="${2:-all}"
    (
        export PROFILE_DIR
        source <("$LIB_DIR/normalize-query.sh" "$query")
        export NORM_QUERY
        export DETECTED_APP DETECTED_ENV DETECTED_NODE

        bash "$LIB_DIR/infer.sh" "$query" 2>/dev/null \
            | awk '{ if ($2+0 > max) { max=$2+0; line=$0 } } END { print "TOOL " line }'

        # if/fi e non `[[ ]] && cmd`: con want=tool quel costrutto sarebbe
        # l'ultimo comando della subshell e restituirebbe 1, facendo abortire il
        # chiamante sotto `set -e`. È la stessa trappola di HELP-1 (commit
        # 3859d62, `return` nudo che troncava l'help).
        if [[ "$want" == "all" ]]; then
            bash "$LIB_DIR/param-extract.sh" "$query" 2>/dev/null
        fi
    )
}

# ─── LEVEL 1: intent test ─────────────────────────────────────────────────────
# Formato: "expected_tool|query"
# Se expected_tool è "NONE" verifica che infer.sh non produca output (sotto soglia)
# Prefisso "!" = verifica che expected_tool NON sia il top-1
INTENT_TESTS=(
    # count_status
    "count_status|quanti errori 500 ci sono stati stamattina"
    "count_status|numero di 4xx nell'ultima ora"
    "!count_status|distribuzione degli errori per endpoint"

    # distribute_status
    "distribute_status|distribuzione degli errori per endpoint in produzione nodo 5"
    "distribute_status|quali api hanno più fallimenti"
    "distribute_status|distribuzione degli errori 400 per endpoint in produzione"

    # slow_requests
    "slow_requests|dammi le chiamate lente in produzione nodo 5"
    "slow_requests|chiamate lente di stamattina"
    "slow_requests|richieste con latenza alta stamattina"
    "!show_help|dammi le chiamate lente in produzione nodo 5"
    "!show_help|chiamate lente di stamattina"

    # traffic_volume
    "traffic_volume|mostrami il volume di traffico di stamattina"
    "traffic_volume|andamento delle richieste per fascia oraria"
    "!show_help|mostrami il volume di traffico di stamattina sul nodo 3"

    # filter_errors
    "filter_errors|errori nel server log del nodo 3"
    "filter_errors|righe di errore nel server.log"

    # count_status — LOGSEL-1: "errore" + access log senza status code non deve
    # finire su filter_errors (bug prod 2026-08-07). count_status/distribute_status
    # sono entrambi sopra soglia (multi-label), qui si verifica solo il top-1.
    "count_status|errori nel access.log di produzione stamattina del nodo 4"
    "!filter_errors|errori nell'access log di stamattina"

    # service_times
    "service_times|tempi dei servizi backend di stamattina"
    "service_times|latenza dei servizi SOA"

    # gc_stats
    "gc_stats|statistiche GC del nodo 5"
    "gc_stats|pause garbage collector stamattina"

    # correlate_gc_slow
    "correlate_gc_slow|il GC sta causando lentezza sul nodo 6"
    "correlate_gc_slow|correlazione tra pause GC e richieste lente"

    # tail_log
    "tail_log|ultime righe del log"
    "tail_log|ultime 100 righe"

    # tail_log — LOG_ORDER (NEXT-2): "prime" resta tail_log, cambia solo la
    # direzione estratta da param-extract.sh, non la classe.
    "tail_log|prime 10 righe del log"
    "tail_log|dammi le prime 20 richieste"

    # filter_ip
    "filter_ip|traffico per indirizzo ip sul nodo 2"
    "filter_ip|traffico dall'ip 10.0.0.1"

    # filter_app_errors
    "filter_app_errors|errori applicativi nascosti sul nodo 8"
    "filter_app_errors|exception loggati come INFO"

    # tail_named_log
    "tail_named_log|ultime righe del cc.log"
    "tail_named_log|dammi la coda del api.log"
    "!grep_named_log|ultime righe del cc.log"

    # tail_named_log — LOG_ORDER (NEXT-2)
    "tail_named_log|prime 10 righe del cc.log"
    "tail_named_log|mostrami le prime 20 righe del database.log"

    # grep_named_log — fix backlog
    "grep_named_log|problemi sul cc.log del nodo 12 di produzione"
    "grep_named_log|anomalie nel api.log"
    "grep_named_log|errori nel cc.log"
    "!tail_named_log|problemi sul cc.log del nodo 12"
    "!tail_named_log|anomalie nel api.log"

    # named log senza feature dedicata prima di NLOG-5 — coperti dall'alternanza
    # sui 15 nomi di APP_LOG_NAMES. arbitrato e ccCanaliz hanno ZERO esempi nel
    # dataset: se passano, la feature generalizza a nomi mai visti in training.
    "tail_named_log|ultime righe del ccJBatch.log"
    "grep_named_log|errori nel arbitrato.log"
    "tail_named_log|ultime righe del claimnumgen.log"
    "tail_named_log|mostrami il ccCanaliz.log"
    # Nomi con maiuscole: normalize-query.sh fa lowercase e grep -qE è
    # case-sensitive, quindi i pattern del vocabolario devono essere minuscoli.
    # Prima del fix (2026-08-04) queste due instradavano su tail_log: ccJBatch
    # passava solo grazie a `batch\b`, ccCanaliz non aveva rete di riserva.
    "tail_named_log|ultime 2 righe del ccCanaliz.log"
    "grep_named_log|errori nel ccCanaliz.log"

    # escape hatch glob (NLOG-6) — il placeholder <LOGFILE> prodotto da
    # normalize-query.sh è ciò che rende queste query classificabili.
    "tail_named_log|ultime 10 righe di \"*c1nssprod*.log\""
    "grep_named_log|errori nel \"*c1nssprod*.log\""
    "tail_named_log|ultime righe di \"*-cc.log\""
    "grep_named_log|warning nel '*-database.log'"

    # Generalizzazione (BACKLOG LOGF): log NON presenti in APP_LOG_NAMES e mai visti
    # in training. Se questi passano, il modello ha imparato la *forma* "<nome>.log"
    # e non l'elenco dei nomi — è l'obiettivo dell'intero refactor.
    "tail_named_log|ultime righe del policysearch.log"
    "tail_named_log|ultime righe del concurrentDataChangeExceptionLog.log"
    "grep_named_log|errori nel inbound_mq_messages.log"
    "grep_named_log|errori nel controllo_pagamenti.log"
    "tail_named_log|ultime 10 righe del pc1nssprod.log"

    # SRCH-2: ricerca testuale libera in un solo log di sistema (server/gc/access)
    # → grep_named_log, non filter_errors né search_all_logs. <PATTERN> (QUOTE-1)
    # + il bigramma server.log|gc.log|access.log sono il segnale.
    "grep_named_log|cerca \"NullPointerException\" nel server.log"
    "grep_named_log|cerca \"OutOfMemory\" nel gc.log"
    "grep_named_log|trova \"timeout\" nell'access log"

    # SRCH-4: come SRCH-2 ma col nome del log di sistema QUOTATO e senza wildcard.
    # Bug prod 2026-08-19: entrambe le stringhe quotate diventavano <PATTERN>, il
    # bigramma letterale server.log|gc.log|access.log non si attivava e la query
    # finiva su search_all_logs (87%). La prima è la query reale dell'utente.
    "grep_named_log|sul nodo 3 di produzione trova \"No HeadersTranscoder provided\" nel \"server.log\" di oggi"
    "!search_all_logs|sul nodo 3 di produzione trova \"No HeadersTranscoder provided\" nel \"server.log\" di oggi"
    "grep_named_log|cerca \"NPE\" nel \"gc.log\""
    "grep_named_log|cerca 'OutOfMemory' nel 'access.log'"

    # I log di infrastruttura NON devono finire sui tool named-log: hanno i propri
    # (filter_errors / tail_log via LOG_TYPE).
    "!tail_named_log|righe di errore nel server.log"
    "!grep_named_log|ultime righe del gc.log"

    # show_help — C14
    "show_help|aiuto"
    "show_help|cosa puoi fare"
    "show_help|help"
    "show_help|che strumenti hai"

    # list_logs — LIST-1
    "list_logs|che log ci sono"
    "list_logs|quali log posso vedere"
    "list_logs|elenco dei log disponibili"
    "list_logs|lista dei log"
    "list_logs|che log ci sono sul nodo 5"
    "list_logs|quali log sono presenti sul nodo"
    "list_logs|elenca tutti i log del nodo"
    # confini — più importanti dei positivi: proteggono le due collisioni con
    # show_help (capacità vs esistenza) e search_all_logs (c'è vs ci sono)
    "!list_logs|quali log sai analizzare"
    "!list_logs|in quali log c'è il claim 1-8101-2026-0473954"
    "!list_logs|cerca NullPointerException in tutti i log"
    "!list_logs|elenca le ultime righe del log"
    "show_help|quali log sai leggere"
    "search_all_logs|in quali log c'è la stringa NullPointerException"
)

run_intent_tests() {
    print_header "LEVEL 1 — Intent classification"
    printf "${DIM}%-4s  %-18s  %-45s  %s${RESET}\n" "ESIT" "TOOL ATTESO" "QUERY" "DETTAGLIO"
    echo ""

    for entry in "${INTENT_TESTS[@]}"; do
        negate=0
        expected="${entry%%|*}"
        query="${entry#*|}"
        if [[ "$expected" == "!"* ]]; then
            negate=1
            expected="${expected#!}"
        fi

        # Percorso reale di chatbot.sh via _front_end (vedi sopra). La subshell è
        # dentro _front_end: le DETECTED_*/NORM_QUERY di un test non sopravvivono
        # al successivo. Nota che questa è anche la LIMITAZIONE strutturale di
        # Level 1 — chatbot.sh le eredita di proposito fra query consecutive, e
        # quel comportamento è coperto da tests/test-repl-state.sh, non qui.
        top_result=$(_front_end "$query" tool)
        top_result="${top_result#TOOL }"
        top_tool="${top_result%% *}"
        top_prob="${top_result##* }"
        top_pct=$(awk -v p="${top_prob:-0}" 'BEGIN { printf "%.0f", p * 100 }')

        if [[ "$negate" -eq 1 ]]; then
            if [[ "$top_tool" == "$expected" ]]; then
                result_line FAIL "!$expected" "$top_tool" "$query" "→ ${top_pct}% (non doveva essere top-1)"
            else
                result_line PASS "!$expected" "${top_tool:-NONE}" "$query" "top-1=${top_tool} (${top_pct}%) ✓"
            fi
        else
            if [[ "$top_tool" == "$expected" ]]; then
                result_line PASS "$expected" "$top_tool" "$query" "→ ${top_pct}%"
            else
                result_line FAIL "$expected" "${top_tool:-NONE}" "$query" "→ ${top_tool:-NONE} (${top_pct}%) invece di $expected"
            fi
        fi
    done
}

# ─── LEVEL 1b: parametri estratti ─────────────────────────────────────────────
#
# Perché esiste (2026-08-20): Level 1 asserisce SOLO il nome del tool. Una query
# instradata correttamente ma con un parametro sbagliato passava la suite — e
# quella è la classe di difetto più costosa del progetto, perché produce una
# risposta ben formata alla domanda sbagliata invece di un errore (LOGSEL-1,
# FORMAT-1, e il bug "oggi" del 2026-08-05).
#
# Copre gli 11 parametri che param-extract.sh emette e che nessun test asseriva:
# STATUS_CODE, THRESHOLD_MS, IP_FILTER, LOG_LEVEL, LEVEL_EXPLICIT,
# NAMED_LOG_GLOB, DATE_FILTER, TIME_ONLY_QUERY.
#
# Asserisce tool E parametri sulla STESSA invocazione, di proposito: la lezione
# di LOGDISC-4e è che un test per-feature non coglie l'interazione fra feature —
# lì la combinazione "path senza app attraverso require_app" non era mai stata
# esercitata pur essendo entrambe le metà coperte.
#
# Formato: "expected_tool|VAR=valore,VAR=valore|query"
#   expected_tool vuoto = non asserire il tool, solo i parametri
#   VAR=  (valore vuoto) = asserisce che il parametro sia vuoto
PARAM_TESTS=(
    # ── STATUS_CODE ──────────────────────────────────────────────────────────
    "count_status|STATUS_CODE=500|quanti errori 500 ci sono stati stamattina"
    "count_status|STATUS_CODE=404|quanti 404 nell'ultima ora"
    "count_status|STATUS_CODE=4xx|numero di 4xx nell'ultima ora"
    "count_status|STATUS_CODE=5xx|quanti 5xx stamattina"
    "distribute_status|STATUS_CODE=400|distribuzione degli errori 400 per endpoint in produzione"
    # Confine: una query senza codice non deve inventarne uno.
    "filter_errors|STATUS_CODE=|errori nel server log del nodo 3"
    # Collisione: "500" in "ultime 500 righe" è un CONTEGGIO, non uno status HTTP.
    # La regex \b[45][0-9]{2}\b non distingue i due ruoli del numero.
    "tail_log|STATUS_CODE=,TAIL_N=500|ultime 500 righe del log"
    # Collisione: "500 ms" è una SOGLIA, non uno status HTTP.
    "slow_requests|STATUS_CODE=,THRESHOLD_MS=500|richieste sopra i 500 ms"

    # ── THRESHOLD_MS ─────────────────────────────────────────────────────────
    # NB: fino al 2026-08-21 le asserzioni qui erano SOLO in millisecondi, cioè
    # nell'unica unità che funzionava — ed è la ragione per cui THR-1 è sopravvissuto
    # fino a un test sui log di produzione. Le righe in secondi sotto sono il
    # fail-before: senza il fix danno 1000 (o vuoto), non il valore convertito.
    "slow_requests|THRESHOLD_MS=1000|dammi le chiamate lente in produzione nodo 5"
    "slow_requests|THRESHOLD_MS=2000|richieste più lente di 2000 ms"
    "slow_requests|THRESHOLD_MS=3000|chiamate oltre 3000 ms stamattina"
    "count_status|THRESHOLD_MS=|quanti errori 500 ci sono stati stamattina"
    # secondi → millisecondi (il modo in cui una persona la dice davvero)
    "slow_requests|THRESHOLD_MS=5000|chiamate lente sopra 5 secondi"
    "slow_requests|THRESHOLD_MS=5000|chiamate lente sopra i 5 secondi"
    "slow_requests|THRESHOLD_MS=3000|richieste oltre 3 secondi"
    "slow_requests|THRESHOLD_MS=10000|richieste che hanno superato i 10 secondi"
    "slow_requests|THRESHOLD_MS=2000|chiamate lente sopra 2 sec"
    "slow_requests|THRESHOLD_MS=1000|chiamate lente con latenza sopra 1 secondo"
    # millisecondi per esteso, e forma attaccata senza spazio — due esempi di
    # training del corpus usano `5000ms`, e prima davano 1000
    "slow_requests|THRESHOLD_MS=500|chiamate lente sopra 500 millisecondi"
    "slow_requests|THRESHOLD_MS=5000|chiamate lente sopra i 5000ms"
    # `millisecondi` CONTIENE `secondi`: se l'ordine dei rami si invertisse, questa
    # darebbe 500000 invece di 500. È la riga che protegge quell'ordine.
    "slow_requests|THRESHOLD_MS=500|richieste più lente di 500 millisecondi"

    # ── IP_FILTER ────────────────────────────────────────────────────────────
    "filter_ip|IP_FILTER=10.0.0.1|traffico dall'ip 10.0.0.1"
    "filter_ip|IP_FILTER=192.168.1.100|richieste da 192.168.1.100 stamattina"
    "filter_ip|IP_FILTER=|traffico per indirizzo ip sul nodo 2"

    # ── LOG_LEVEL + LEVEL_EXPLICIT ───────────────────────────────────────────
    # LEVEL_EXPLICIT distingue "livello chiesto" da "default applicato": è ciò
    # che permette a SRCH-1 di cercare in TUTTO il file quando la query porta un
    # pattern ma non nomina un livello. Introdotto il 2026-08-06, mai asserito.
    "grep_named_log|LOG_LEVEL=ERROR,LEVEL_EXPLICIT=1|errori nel cc.log"
    "grep_named_log|LOG_LEVEL=WARN,LEVEL_EXPLICIT=1|warning nel cc.log"
    "grep_named_log|LOG_LEVEL=WARN+,LEVEL_EXPLICIT=1|problemi sul cc.log del nodo 12 di produzione"
    "grep_named_log|LOG_LEVEL=WARN+,LEVEL_EXPLICIT=1|anomalie nel api.log"
    # Senza asserzione sul tool: "righe info" / "tutti i livelli" sono frasi
    # ambigue fra tail_named_log e grep_named_log (entrambe leggono lo stesso
    # file, cambia solo il filtro) e qui si misura l'ESTRAZIONE del livello, non
    # il routing. Vincolare anche il tool renderebbe il test un doppio
    # esperimento con una sola conclusione possibile.
    "|LOG_LEVEL=INFO,LEVEL_EXPLICIT=1|righe info nel cc.log"
    "|LOG_LEVEL=ALL,LEVEL_EXPLICIT=1|tutti i livelli nel cc.log"
    # Il caso che LEVEL_EXPLICIT esiste per servire: pattern quotato senza
    # livello nominato → default ERROR ma NON esplicito, così dispatch.sh
    # allarga a tutto il file invece di filtrare sui soli errori.
    "grep_named_log|LEVEL_EXPLICIT=0,SEARCH_PATTERN=NullPointerException|cerca \"NullPointerException\" nel cc.log"
    "grep_named_log|LEVEL_EXPLICIT=0|cerca \"timeout\" nel api.log"

    # ── SEARCH_PATTERN + NAMED_LOG_GLOB (disambiguazione per forma, QUOTE-1) ──
    "grep_named_log|SEARCH_PATTERN=NullPointerException,NAMED_LOG_GLOB=|cerca \"NullPointerException\" nel server.log"
    "search_all_logs|SEARCH_PATTERN=NullPointerException|cerca \"NullPointerException\" in tutti i log"
    # Le virgolette sono OBBLIGATORIE per design (param-extract.sh:236): senza,
    # il pattern è __MISSING__ e il tool chiede di quotare invece di indovinare
    # quale parola della frase sia il termine di ricerca. Questa query è nel
    # Level 1 come caso positivo di routing — instrada bene e poi chiede le
    # virgolette, che è il comportamento voluto, non un difetto.
    "search_all_logs|SEARCH_PATTERN=__MISSING__|in quali log c'è la stringa NullPointerException"
    # Pattern con spazi: la stringa reale del bug prod SRCH-3.
    "grep_named_log|SEARCH_PATTERN=No HeadersTranscoder provided.|cerca \"No HeadersTranscoder provided.\" nel server.log"
    # Glob-like → NAMED_LOG_GLOB, e SEARCH_PATTERN resta vuoto: mutuamente
    # esclusivi per forma. Prima si popolavano entrambi con lo stesso testo e
    # dispatch.sh cercava il glob DENTRO il file.
    "tail_named_log|NAMED_LOG_GLOB=*c1nssprod*.log,SEARCH_PATTERN=|ultime 10 righe di \"*c1nssprod*.log\""
    "grep_named_log|NAMED_LOG_GLOB=*-database.log|warning nel '*-database.log'"
    # Entrambi presenti: il glob è il file, il pattern è il testo.
    "grep_named_log|NAMED_LOG_GLOB=*-cc.log,SEARCH_PATTERN=timeout|cerca \"timeout\" nel \"*-cc.log\""
    # Trigger di ricerca senza stringa quotata → __MISSING__, non vuoto: i tool
    # devono poter dire "quale stringa?" invece di cercare il nulla.
    "|SEARCH_PATTERN=__MISSING__|cerca nel cc.log"

    # ── NAMED_LOG (longest-match) ────────────────────────────────────────────
    # Il bug del longest-match: "ccJBatch.log" risolto come "cc" faceva aprire
    # il file sbagliato con routing corretto — silenzioso per definizione.
    "tail_named_log|NAMED_LOG=ccJBatch|ultime righe del ccJBatch.log"
    "tail_named_log|NAMED_LOG=ccCanaliz|ultime 2 righe del ccCanaliz.log"
    "tail_named_log|NAMED_LOG=cc|ultime righe del cc.log"
    # Log di infrastruttura: hanno tool dedicati, NAMED_LOG deve restare vuoto.
    "filter_errors|NAMED_LOG=,SYSLOG_KIND=server|righe di errore nel server.log"
    "tail_log|NAMED_LOG=,SYSLOG_KIND=gc|ultime righe del gc.log"

    # ── LOG_ORDER + TAIL_N ───────────────────────────────────────────────────
    "tail_log|LOG_ORDER=tail,TAIL_N=50|ultime righe del log"
    "tail_log|LOG_ORDER=tail,TAIL_N=100|ultime 100 righe"
    "tail_log|LOG_ORDER=head,TAIL_N=10|prime 10 righe del log"
    "tail_named_log|LOG_ORDER=head,TAIL_N=20|mostrami le prime 20 righe del database.log"

    # ── DATE_FILTER (sceglie la ROTAZIONE in resolve-logs.sh) ────────────────
    # Un DATE_FILTER vuoto su una query datata fa leggere il file di OGGI: è la
    # seconda metà dell'errore composto: finestra sbagliata + file sbagliato,
    # concordi, quindi la risposta è coerente e completamente errata.
    "filter_errors|DATE_FILTER=$(date -d yesterday +%Y-%m-%d)|errori nel server log di ieri"
    "filter_errors|DATE_FILTER=$(date -d '2 days ago' +%Y-%m-%d)|errori nel server log 2 giorni fa"
    "filter_errors|DATE_FILTER=|errori nel server log di oggi"

    # ── TIME_ONLY_QUERY (set-context, non una domanda) ───────────────────────
    "|TIME_ONLY_QUERY=1|dalle 10 alle 12"
    "|TIME_ONLY_QUERY=1|ultimi 30 minuti"
    "|TIME_ONLY_QUERY=0|errori di stamattina"

    # ── LOG_TYPE / SYSLOG_KIND (quale sorgente di sistema) ───────────────────
    "filter_errors|LOG_TYPE=server,SYSLOG_KIND=server|errori nel server log del nodo 3"
    "count_status|LOG_TYPE=,SYSLOG_KIND=access|errori nel access.log di produzione stamattina del nodo 4"
    # SYSLOG_KIND si popola quando l'utente NOMINA un log di sistema, non per
    # dichiarare la sorgente del tool: gc_stats sa da sé di leggere il gc log
    # (TOOL_SOURCES), quindi su "statistiche GC" il campo resta vuoto ed è
    # corretto. Si asserisce il caso in cui il log è nominato davvero.
    "gc_stats|SYSLOG_KIND=|statistiche GC del nodo 5"
    "|SYSLOG_KIND=gc|errori nel log gc"
    # Plurale: "log applicativi" deve valere "log applicativo". Senza tool
    # asserito — qui si misura l'estrazione, e LOG_TYPE derivato da SYSLOG_KIND
    # è ciò che decide se si legge il server log o (per fallback) l'access log.
    "|SYSLOG_KIND=server,LOG_TYPE=server|errori nei log applicativi del nodo 3"
)

run_param_tests() {
    print_header "LEVEL 1b — Parametri estratti (param-extract.sh sul percorso reale)"
    printf "${DIM}%-4s  %-18s  %-45s  %s${RESET}\n" "ESIT" "PARAMETRO" "QUERY" "DETTAGLIO"
    echo ""

    for entry in "${PARAM_TESTS[@]}"; do
        local_expected="${entry%%|*}"
        rest="${entry#*|}"
        assertions="${rest%%|*}"
        query="${rest#*|}"

        out=$(_front_end "$query" all)
        got_tool=$(printf '%s\n' "$out" | awk '/^TOOL /{ print $2; exit }')

        # Tool: asserito solo se indicato. Un parametro giusto su un tool
        # sbagliato non è un successo — chi legge il parametro è il tool.
        if [[ -n "$local_expected" && "$got_tool" != "$local_expected" ]]; then
            result_line FAIL "tool" "$got_tool" "$query" "tool=${got_tool:-NONE} invece di $local_expected"
            continue
        fi

        # Ogni VAR=valore della lista è un'asserzione indipendente.
        IFS=',' read -r -a _asserts <<< "$assertions"
        for _a in "${_asserts[@]}"; do
            var="${_a%%=*}"; exp="${_a#*=}"
            got=$(printf '%s\n' "$out" | grep "^${var}=" | head -1 | cut -d= -f2- | sed "s/^'//; s/'$//")
            if [[ "$got" == "$exp" ]]; then
                result_line PASS "$var" "$got_tool" "$query" "$var='$got'"
            else
                result_line FAIL "$var" "$got_tool" "$query" "$var='$got' invece di '$exp'"
            fi
        done
    done
}

# ─── Unit test con fixture locali (delegati, nessun log reale richiesto) ──────
# Prima (fino al 2026-08-06) nessun runner aggregato li invocava: erano
# eseguiti solo a mano, quindi senza rete di regressione automatica.
run_unit_tests() {
    print_header "UNIT — utils-logfiles, param-extract, search_all_logs, correlate_gc_slow, gc_stats, slow_requests, dispatch-perf, logline, logname-display, help-sources, vocab-gap, normalize-query"
    for _t in test-utils-logfiles.sh test-param-extract.sh test-search-all-logs.sh \
              test-correlate-gc-slow.sh test-gc-stats.sh test-slow-requests.sh test-dispatch-perf.sh \
              test-theme.sh test-filter-ip.sh test-srch-named-log.sh test-log-discovery.sh \
              test-logdisc-4.sh test-access-format.sh test-profile-config.sh \
              test-train-regression.sh test-logline.sh test-logname-display.sh \
              test-help-sources.sh test-utils-time.sh test-repl-state.sh \
              test-vocab-gap.sh test-python-resolve.sh test-normalize-query.sh \
              test-vocab-format.sh test-level-count.sh test-logfile-name-perf.sh \
              test-node-resolve.sh test-tool-scope.sh; do
        # Tre esiti, non due (VENVGATE-1): 0 PASS, 2 NON ESEGUIBILE, altro FAIL.
        # Un harness che non può misurare — perché manca qualcosa nell'ambiente,
        # non perché il codice è rotto — non va contato fra i PASS (sarebbe un
        # verde per una verifica mai avvenuta) né fra i FAIL (non c'è nulla di
        # rotto). È la stessa distinzione di gap-report.sh, applicata al runner.
        _t_rc=0
        bash "$SCRIPT_DIR/$_t" || _t_rc=$?
        if [[ "$_t_rc" -eq 0 ]]; then
            pass=$(( pass + 1 ))
            printf "  ${GREEN}PASS${RESET}  %s\n" "$_t"
        elif [[ "$_t_rc" -eq 2 ]]; then
            printf "  ${YELLOW}${BOLD}SKIP${RESET}  %s — non eseguibile in questo ambiente\n" "$_t"
        else
            fail=$(( fail + 1 ))
            printf "  ${RED}${BOLD}FAIL${RESET}  %s — vedi output sopra\n" "$_t"
        fi
    done
}

# ─── LEVEL 2: output test ─────────────────────────────────────────────────────
# Formato: "expected_tool|query"
# SKIP_OK = se dispatch stampa [SKIP] è accettabile (log non disponibile per quel nodo)
OUTPUT_TESTS=(
    "slow_requests|chiamate lente"
    "distribute_status|distribuzione errori per endpoint"
    "count_status|quanti errori 500 stamattina"
    "traffic_volume|volume di traffico stamattina"
    "filter_errors|errori nel server log"
    "service_times|tempi dei servizi backend"
    "gc_stats|statistiche GC"
    "correlate_gc_slow|il GC sta causando lentezza"
    "tail_log|ultime 20 righe del log"
    "filter_ip|chi ha fatto più richieste"
    "filter_app_errors|errori applicativi nascosti"
    "grep_named_log|problemi sul cc.log"
    "tail_named_log|ultime righe del cc.log"
    "show_help|aiuto"
)

run_output_tests() {
    if [[ -z "$L2_ENV" || -z "$L2_NODE" ]]; then
        echo "[ERROR] --level2 richiede --env e --node" >&2
        exit 1
    fi

    print_header "LEVEL 2 — Output test (env=$L2_ENV  node=$L2_NODE)"
    printf "${DIM}%-4s  %-18s  %-45s  %s${RESET}\n" "ESIT" "TOOL" "QUERY" "DETTAGLIO"
    echo ""

    for entry in "${OUTPUT_TESTS[@]}"; do
        expected="${entry%%|*}"
        query="${entry#*|}"

        output=$(bash "$ROOT_DIR/chatbot.sh" \
            --profile "$PROFILE_DIR" \
            --env "$L2_ENV" --node "$L2_NODE" \
            --query "$query" 2>&1) || true

        parsed=$(printf '%s\n' "$output" | awk '
            /\[ERROR\]/          { sub(/.*\[ERROR\] /, ""); err=$0; next }
            /\[SKIP\]/           { skip=1; next }
            /Nessun tool attivato|Nessuna riga trovata/ { warn=$0; next }
            END {
                if (err  != "") { print "ERR:" err; exit }
                if (skip)       { print "SKIP:log non disponibile"; exit }
                if (warn != "")  { print "WARN:" warn; exit }
                print "OK:"
            }
        ')
        tag="${parsed%%:*}"
        detail="${parsed#*:}"
        case "$tag" in
            ERR)  result_line FAIL "$expected" "$expected" "$query" "[ERROR] ${detail:0:60}" ;;
            SKIP) result_line WARN "$expected" "$expected" "$query" "[SKIP] $detail" ;;
            WARN) result_line WARN "$expected" "$expected" "$query" "$detail" ;;
            OK)
                preview=$(printf '%s\n' "$output" | awk '
                    /^[│├└┌]/ || /^[[:space:]]*$/ || /^[[:space:]]*\[/ { next }
                    { gsub(/\033\[[0-9;]*m/, ""); sub(/^[[:space:]]+/, ""); print; exit }
                ')
                result_line PASS "$expected" "$expected" "$query" "${preview:0:60}"
                ;;
        esac
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
printf "${BOLD}Neural Log Analyzer — Test Suite${RESET}  profilo: $(basename "$PROFILE_DIR")\n"

[[ "$RUN_L1" -eq 1 ]] && run_intent_tests
[[ "$RUN_L1" -eq 1 ]] && run_param_tests
[[ "$RUN_L1" -eq 1 ]] && run_unit_tests
[[ "$RUN_L2" -eq 1 ]] && run_output_tests

if [[ "$RUN_PARITY" -eq 1 ]]; then
    print_header "PARITÀ — normalize-query.sh (bash) vs build_dataset.py (Python)"
    # Opt-in: ~4 min (2 fork bash per query × 1008). Delega al test standalone,
    # che è l'unica fonte di verità sul confronto — qui si aggrega solo l'esito.
    # Tre esiti, non due (VENVGATE-1): 0 misurato, 2 NON misurabile (nessun
    # python3), altro = divergenza vera. Prima il codice 1 dell'assenza di Python si
    # confondeva con una divergenza, quindi su una macchina senza `.venv` — la
    # produzione — questa riga diceva FAIL senza che nulla fosse rotto. Un "non
    # eseguito" non va contato né fra i PASS (non è verificato) né fra i FAIL (non
    # è rotto): è la stessa distinzione che gap-report.sh fa da GAPREP-1.
    _parity_rc=0
    bash "$SCRIPT_DIR/test-normalize-parity.sh" --profile "$PROFILE_DIR" || _parity_rc=$?
    if [[ "$_parity_rc" -eq 0 ]]; then
        pass=$(( pass + 1 ))
        printf "  ${GREEN}PASS${RESET}  parità bash/Python su NORM_QUERY e vettori feature\n"
    elif [[ "$_parity_rc" -eq 2 ]]; then
        printf "  ${YELLOW}${BOLD}SKIP${RESET}  parità NON eseguita (nessun python3) — vedi output sopra\n"
    else
        fail=$(( fail + 1 ))
        printf "  ${RED}${BOLD}FAIL${RESET}  divergenza bash/Python — vedi output sopra\n"
    fi
fi

echo ""
printf "────────────────────────────────────────────────────────────────────\n"
printf "${BOLD}Risultato:${RESET}  "
printf "${GREEN}%d PASS${RESET}  " "$pass"
[[ "$warn" -gt 0 ]] && printf "${YELLOW}%d WARN${RESET}  " "$warn"
[[ "$fail" -gt 0 ]] && printf "${RED}${BOLD}%d FAIL${RESET}" "$fail" || printf "${GREEN}0 FAIL${RESET}"
echo ""

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
