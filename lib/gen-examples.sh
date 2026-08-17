#!/bin/bash
# gen-examples.sh — genera esempi labeled per il dataset tramite espansione di sinonimi
#
# Uso:
#   ./lib/gen-examples.sh [tool|all] [--target N] [--apply]
#
#   tool       nome del tool specifico, o "all" per bilanciare tutti (default: all)
#   --target N porta ogni tool a N esempi (default: 30)
#   --apply    appende i risultati al dataset invece di stamparli su stdout
#
# Esempi:
#   ./lib/gen-examples.sh filter_ip
#   ./lib/gen-examples.sh all --target 30
#   ./lib/gen-examples.sh all --apply

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PROFILE_DIR può essere passata come variabile d'ambiente o via --profile
TARGET=30
APPLY=0
TOOL_ARG="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; export PROFILE_DIR; shift 2 ;;
        --target)  TARGET="$2"; shift 2 ;;
        --apply)   APPLY=1; shift ;;
        *)         TOOL_ARG="$1"; shift ;;
    esac
done

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] gen-examples: PROFILE_DIR non impostata. Usa --profile <dir> oppure esportala." >&2
    exit 1
fi

# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1).
source "$SCRIPT_DIR/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"

DATASET="$LABELED_FILE"

# Conta esempi nel dataset per un tool (considera anche multi-label)
current_count() {
    local t="$1"
    awk -F'\t' -v tool="$t" '
        NF==2 && !/^#/ {
            split($1, ts, ",")
            for (i in ts) if (ts[i] == tool) { c++; break }
        }
        END { print c+0 }
    ' "$DATASET"
}

# ─── Deduplicazione contro il dataset esistente ───────────────────────────────
declare -A SEEN_QUERIES
while IFS=$'\t' read -r _ q; do
    SEEN_QUERIES["${q,,}"]=1
done < <(awk -F'\t' 'NF==2 && !/^#/' "$DATASET" 2>/dev/null)

declare -A TOOL_GEN_COUNT
declare -A TOOL_LIMIT

init_limits() {
    for t in "${TOOL_NAMES[@]}"; do
        if [[ "$TOOL_ARG" == "all" || "$TOOL_ARG" == "$t" ]]; then
            local cur need
            cur=$(current_count "$t")
            need=$(( TARGET - cur ))
            TOOL_LIMIT[$t]=$(( need > 0 ? need : 0 ))
        else
            TOOL_LIMIT[$t]=0
        fi
        TOOL_GEN_COUNT[$t]=0
    done
}

OUTPUT_LINES=()

# Verifica che un esempio abbia almeno una feature attiva nel vocabolario.
# Esempi con vettore tutto-zero sono rumore puro per la rete.
validate_example() {
    local tool="$1" query="$2"
    local features active
    features=$("$SCRIPT_DIR/query-to-features.sh" "$query")
    active=$(echo "$features" | tr ' ' '\n' | grep -c "^[^0]")
    if [[ "$active" -eq 0 ]]; then
        echo "[WARN] nessuna feature attiva, esempio scartato: [$tool] $query" >&2
        return 1
    fi
    return 0
}

emit() {
    local tool="$1"
    local query="${2,,}"
    [[ "${TOOL_LIMIT[$tool]:-0}" -le 0 ]] && return
    [[ "${TOOL_GEN_COUNT[$tool]:-0}" -ge "${TOOL_LIMIT[$tool]}" ]] && return
    [[ -n "${SEEN_QUERIES[$query]:-}" ]] && return
    validate_example "$tool" "$query" || return 0
    SEEN_QUERIES["$query"]=1
    TOOL_GEN_COUNT[$tool]=$(( ${TOOL_GEN_COUNT[$tool]} + 1 ))
    OUTPUT_LINES+=("${tool}"$'\t'"${query}")
}

# ═══════════════════════════════════════════════════════════════════════════════
# TABELLE DI SINONIMI — modificare qui per aggiungere varianti
# ═══════════════════════════════════════════════════════════════════════════════

# Verbi generici di visualizzazione
SYN_SHOW=(  "mostrami" "dammi" "fammi vedere" "visualizza" "elenca"
            "mostra" "dimmi" "recupera" "fornisci" )

# Verbi di conteggio
SYN_COUNT=( "conta" "quanti" "quante" "numero di" "totale di"
            "dammi il numero di" "contami" "calcola quanti" "quanti sono i" )

# Finestre temporali esplicite
SYN_TIME=(  "nelle ultime 2 ore" "nelle ultime 3 ore" "nell'ultima ora"
            "nelle ultime 6 ore" "nelle ultime 24 ore" "degli ultimi 30 minuti"
            "di oggi" "di ieri" )

# Aggettivi temporali "recenti"
SYN_RECENT=("recenti" "degli ultimi minuti" "dell'ultima ora" "recentemente"
            "appena accaduti" "dell'ultimo quarto d'ora" )

# Riferimento al server log (keyword: log.applicat|server.log — indice 39)
SYN_SRVLOG=("nel server log" "nel log applicativo" "nel server.log"
            "nel log del server" "sui log applicativi" "nel log jboss" )

# Riferimento all'access log
SYN_ACCLOG=("nell'access log" "nel log di accesso" "nel log http"
            "nel log delle richieste" "nel log undertow" )

# Parole per errori/anomalie (keyword: errore|errori — indici 0-1)
SYN_ERRORS=("errori" "eccezioni" "exception" "warning" "problemi"
            "anomalie" "errori gravi" "messaggi di errore" )

# Verbi di ricerca/filtro
SYN_FILTER=("filtra" "cerca" "trova" "mostrami" "dammi" "seleziona" "estrai" )

# Termini SOA / servizi interni (keyword 54-55, discriminano service_times)
SYN_SOA=(   "servizi soa" "web service" "servizi backend" "servizi interni"
            "chiamate soa" "servizi jboss" )

# Termini di riga/tail (keyword 56, discriminano tail_log)
SYN_TAIL=(  "righe" "tail" "ultime righe" "le ultime N righe" )

# Termini di volume/andamento (keyword 56, discriminano traffic_volume)
SYN_VOL=(   "volume" "andamento" "picco" "volumi" "andamento del traffico" )

# Finestre temporali colloquiali — Leva B (keyword 17-19)
SYN_TIMECOLL=( "stamattina" "stanotte" "questa mattina" "poco fa" "questa sera" )

# Termini colloquiali per errori/problemi — Leva A (keyword 57-59)
SYN_BROKEN=( "cosa ha rotto" "non va nel log" "qualcosa di strano" "non funziona"
             "vediamo cosa è successo" "dammi un'occhiata" )

# Termini backend/web service — Leva C (keyword 53 ampliata)
SYN_BACKEND=( "backend" "web service" "web services" "servizi backend" )

# Aggettivi per richieste lente (keyword: lent[oaie]|slow — indici 30-31)
SYN_SLOW=(  "lente" "con latenza alta" "con response time elevato"
            "sopra soglia" "che impiegano troppo" "molto lente"
            "con tempi elevati" "con risposta ritardata" )

# Parole per endpoint/api (keyword: endpoint — 43, url|path — 44, api — 45)
SYN_ENDPOINT=("endpoint" "api" "url" "path" "route" )

# Parole per distribuzione/raggruppamento
SYN_DISTRIB=("distribuzione" "breakdown" "raggruppamento"
             "suddivisione" "ripartizione" )

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATORI PER TOOL
# Note: ogni template deve contenere almeno una keyword del VOCAB del tool target
# ═══════════════════════════════════════════════════════════════════════════════

gen_count_status() {
    # keywords: errore(0,peso2), 500(1), 400(2), status|stato(7), http(8), quant(18), total(20)
    for v in "${SYN_COUNT[@]}"; do
        emit "count_status" "${v} 500 nell'access log"
        emit "count_status" "${v} richieste con status 500"
        emit "count_status" "${v} errori 4xx"
        emit "count_status" "${v} risposte http con errore"
        emit "count_status" "${v} 503 ricevuti"
        emit "count_status" "${v} richieste con status code 400"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "count_status" "quanti 500 ci sono stati ${t}"
        emit "count_status" "numero di errori http ${t}"
        emit "count_status" "totale richieste fallite ${t}"
    done
}

gen_distribute_status() {
    # keywords: distribuzion(17), raggrupp(21), frequen(22), per(23), endpoint(39), api(41)
    for ep in "${SYN_ENDPOINT[@]}"; do
        for d in "${SYN_DISTRIB[@]}"; do
            emit "distribute_status" "${d} degli errori per ${ep}"
            emit "distribute_status" "${d} dei 500 per ${ep}"
        done
    done
    for t in "${SYN_TIME[@]}"; do
        emit "distribute_status" "distribuzione degli errori per endpoint ${t}"
        emit "distribute_status" "quali api hanno più 500 ${t}"
    done
    emit "distribute_status" "per quale endpoint si concentrano i 404"
    emit "distribute_status" "quali api restituiscono più errori"
    emit "distribute_status" "raggruppami i 500 per url"
    emit "distribute_status" "frequenza errori 503 per path"
    emit "distribute_status" "distribuzione errori http per route"
}

gen_slow_requests() {
    # keywords: lent(27,peso2), latenz(28), ms(29), prestazion(30)
    # bigram[55]: lento+servizi attiva service_times, NON slow_requests — evitare soa/servizi
    for s in "${SYN_SLOW[@]}"; do
        emit "slow_requests" "richieste ${s}"
        emit "slow_requests" "chiamate http ${s}"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "slow_requests" "richieste lente ${t}"
        emit "slow_requests" "chiamate sopra 1000 ms ${t}"
        emit "slow_requests" "latenza alta ${t}"
    done
    for v in "${SYN_SHOW[@]}"; do
        emit "slow_requests" "${v} le richieste più lente"
        emit "slow_requests" "${v} i timeout nell'access log"
        emit "slow_requests" "${v} le prestazioni degradate"
    done
    # Esempi espliciti senza keyword SOA — rinforzano il confine
    emit "slow_requests" "richieste http con risposta lenta"
    emit "slow_requests" "endpoint con latenza elevata"
    emit "slow_requests" "chiamate con response time alto"
    emit "slow_requests" "richieste che superano i 500 ms"
    emit "slow_requests" "quali url rispondono lentamente"
    # Confine negativo vs filter_errors: slow_requests opera sull'access log, non sul server.log
    emit "slow_requests" "tempi di risposta nell'access log"
    emit "slow_requests" "richieste lente nel log undertow"
    emit "slow_requests" "latenza delle richieste http nell'access log"
    emit "slow_requests" "quali url hanno response time alto nell'access log"
    emit "slow_requests" "top endpoint lenti nell'access log di oggi"
    emit "slow_requests" "richieste più lente registrate nel log di accesso"
}

gen_traffic_volume() {
    # keywords: ora|ore(9,peso2), minut(10,peso2), giorn(11), ultim(14,peso2), quant(18), total(20)
    # unigram 53: volum|picco|andament; bigram[56]: volume+tempo (discrimina da tail_log)
    for t in "${SYN_TIME[@]}"; do
        emit "traffic_volume" "traffico ${t}"
        emit "traffic_volume" "volume di richieste ${t}"
        emit "traffic_volume" "quante chiamate ${t}"
        emit "traffic_volume" "andamento del traffico ${t}"
    done
    for v in "${SYN_SHOW[@]}"; do
        emit "traffic_volume" "${v} il traffico per ora"
        emit "traffic_volume" "${v} il picco di richieste"
        emit "traffic_volume" "${v} le richieste al minuto"
    done
    # Esempi con keyword 57 (volume/andamento/picco) senza keyword temporali
    for vol in "${SYN_VOL[@]}"; do
        emit "traffic_volume" "${vol} del traffico http"
        emit "traffic_volume" "${vol} delle richieste al server"
    done
    emit "traffic_volume" "andamento richieste nell'arco della giornata"
    emit "traffic_volume" "picco di traffico nelle ultime ore"
    emit "traffic_volume" "richieste totali per ora di ieri"
    emit "traffic_volume" "volume totale di accessi"
    emit "traffic_volume" "picco di accessi al server"
    # Leva B: temporali colloquiali
    for tc in "${SYN_TIMECOLL[@]}"; do
        emit "traffic_volume" "traffico ${tc}"
        emit "traffic_volume" "quante richieste ${tc}"
    done
}

gen_filter_errors() {
    # keywords: warn(31), exception|eccezione(32), stack.trace(33), crash|fatal(34), log.applicat(35)
    # bigram[54]: exception+tempo attiva filter_errors (non traffic_volume)
    for e in "${SYN_ERRORS[@]}"; do
        emit "filter_errors" "${e} nel server log"
        emit "filter_errors" "${e} recenti nel log applicativo"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "filter_errors" "errori nel server log ${t}"
        emit "filter_errors" "eccezioni nel log applicativo ${t}"
    done
    emit "filter_errors" "righe di errore nel server.log"
    emit "filter_errors" "exception e warning nel log jboss"
    emit "filter_errors" "cosa ha lanciato eccezioni nel log"
    # Confine negativo vs slow_requests: filter_errors opera sul server.log, non sull'access log
    emit "filter_errors" "errori nel server log applicativo jboss"
    emit "filter_errors" "eccezioni java nel log del server"
    emit "filter_errors" "warning e exception nel server.log di oggi"
    emit "filter_errors" "stack trace nel log applicativo"
    emit "filter_errors" "cosa è andato in errore nel server log"
    emit "filter_errors" "exception loggati nel server log dell'applicazione"
    # Leva B: temporali colloquiali
    for tc in "${SYN_TIMECOLL[@]}"; do
        emit "filter_errors" "errori ${tc} nel server log"
        emit "filter_errors" "eccezioni ${tc} nel log applicativo"
    done
    # Leva A: colloquiale
    for br in "${SYN_BROKEN[@]}"; do
        emit "filter_errors" "${br} nel server log"
    done
}

gen_service_times() {
    # keywords: lent(27,peso2), latenz(28), ms(29), prestazion(30)
    # unigram 50: servizi|servizio; unigram 51: soa (segnale forte esclusivo)
    # bigram[55]: lento+servizi → service_times (discrimina da slow_requests)
    for v in "${SYN_SHOW[@]}"; do
        emit "service_times" "${v} i tempi di risposta dei servizi soa"
        emit "service_times" "${v} la latenza dei web service"
        emit "service_times" "${v} i servizi più lenti"
        emit "service_times" "${v} le performance dei servizi backend"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "service_times" "tempi dei servizi soa ${t}"
        emit "service_times" "latenza dei servizi interni ${t}"
        emit "service_times" "performance backend ${t}"
    done
    # Esempi con keyword 54/55 che rinforzano il confine con slow_requests
    for soa in "${SYN_SOA[@]}"; do
        emit "service_times" "tempi di risposta ${soa}"
        emit "service_times" "latenza ${soa}"
        emit "service_times" "${soa} lenti"
    done
    emit "service_times" "quanto ci mette il servizio di autenticazione"
    emit "service_times" "durata media delle chiamate soa"
    emit "service_times" "quale servizio è più lento in ms"
    emit "service_times" "tempi di esecuzione dei web service jboss"
    emit "service_times" "servizio con latenza alta"
    # Leva C: backend/web service espliciti
    for be in "${SYN_BACKEND[@]}"; do
        emit "service_times" "latenza del ${be}"
        emit "service_times" "${be} lenti"
        emit "service_times" "performance del ${be}"
        emit "service_times" "tempi di risposta del ${be}"
    done
}

gen_gc_stats() {
    # keywords: gc|garbage(36), heap(37), memori|jvm(38)
    for v in "${SYN_SHOW[@]}"; do
        emit "gc_stats" "${v} le statistiche del garbage collector"
        emit "gc_stats" "${v} le pause gc"
        emit "gc_stats" "${v} l'utilizzo della heap"
        emit "gc_stats" "${v} la memoria jvm"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "gc_stats" "statistiche gc ${t}"
        emit "gc_stats" "pause garbage collector ${t}"
        emit "gc_stats" "gc events ${t}"
    done
    emit "gc_stats" "quanto dura una pausa gc in media"
    emit "gc_stats" "quante volte ha collezionato la old gen"
    emit "gc_stats" "heap usage dopo il gc"
    emit "gc_stats" "frequenza delle pause gc"
    emit "gc_stats" "analisi della memoria heap jvm"
    emit "gc_stats" "impatto del gc sulla heap"
}

gen_correlate_gc_slow() {
    # keywords: gc|garbage(36), lent(27,peso2), latenz(28), memori(38)
    for t in "${SYN_TIME[@]}"; do
        emit "correlate_gc_slow" "correlazione tra gc e richieste lente ${t}"
        emit "correlate_gc_slow" "il garbage collector causa latenze ${t}"
        emit "correlate_gc_slow" "gc e slow request ${t}"
    done
    emit "correlate_gc_slow" "le pause gc coincidono con i timeout"
    emit "correlate_gc_slow" "quando fa gc le richieste rallentano"
    emit "correlate_gc_slow" "impatto delle pause gc sul response time"
    emit "correlate_gc_slow" "durante il gc ci sono stati timeout"
    emit "correlate_gc_slow" "richieste lente in corrispondenza del garbage collector"
    emit "correlate_gc_slow" "quanto impatta il gc sulla latenza"
    emit "correlate_gc_slow" "le pause gc peggiorano i tempi di risposta"
    emit "correlate_gc_slow" "gc e lentezza nelle richieste http"
    emit "correlate_gc_slow" "il garbage collection rallenta il server"
    emit "correlate_gc_slow" "slow request dopo una pausa garbage collector"
    emit "correlate_gc_slow" "memoria e latenza alta sono correlate"
    # Varianti aggiuntive per raggiungere il target
    for t in "${SYN_TIME[@]}"; do
        emit "correlate_gc_slow" "heap alta e latenze ${t}"
        emit "correlate_gc_slow" "pause gc e timeout ${t}"
    done
    for v in "${SYN_SHOW[@]}"; do
        emit "correlate_gc_slow" "${v} quando gc causa latenza"
        emit "correlate_gc_slow" "${v} correlazione gc e slow request"
    done
    emit "correlate_gc_slow" "garbage collection e response time degradato"
    emit "correlate_gc_slow" "richieste lente durante le pause jvm"
    emit "correlate_gc_slow" "il gc rallenta le risposte http"
    emit "correlate_gc_slow" "coincidenza pause gc e picchi di latenza"
    emit "correlate_gc_slow" "timeout durante il garbage collector"
    emit "correlate_gc_slow" "performance degradate per gc frequente"
    emit "correlate_gc_slow" "latenza anomala in corrispondenza del gc"
}

gen_tail_log() {
    # keywords: ultim(14,peso2), recent(16), list(24), mostr(44)
    # unigram 52: rig|tail; bigram[57]: righe+recente (discrimina da traffic_volume)
    for v in "${SYN_SHOW[@]}"; do
        emit "tail_log" "${v} le ultime righe del log"
        emit "tail_log" "${v} gli ultimi accessi"
        emit "tail_log" "${v} le ultime 100 righe dell'access log"
        emit "tail_log" "${v} gli ultimi eventi nel log"
    done
    for r in "${SYN_RECENT[@]}"; do
        emit "tail_log" "log ${r}"
        emit "tail_log" "righe di log ${r}"
        emit "tail_log" "accessi ${r}"
    done
    # Esempi con keyword 56 (rig/tail) che rinforzano il confine con traffic_volume
    for tl in "${SYN_TAIL[@]}"; do
        emit "tail_log" "${tl} del log di accesso"
        emit "tail_log" "ultime ${tl} dell'access log"
    done
    emit "tail_log" "ultime 50 righe dell'access log"
    emit "tail_log" "cosa è successo di recente nel log"
    emit "tail_log" "attività recente nel log di accesso"
    emit "tail_log" "ultime 200 richieste al server"
    emit "tail_log" "le richieste più recenti"
    emit "tail_log" "tail dell'access log"
    emit "tail_log" "le ultime righe del log undertow"
    # Leva B: temporali colloquiali
    for tc in "${SYN_TIMECOLL[@]}"; do
        emit "tail_log" "log ${tc}"
        emit "tail_log" "righe di log ${tc}"
    done
}

gen_filter_ip() {
    # keywords: \bip\b(42), client|indirizz(43)
    local IPS=("172.30.100.5" "10.0.1.25" "192.168.50.10" "203.0.113.1" "198.51.100.3"
               "172.16.0.50" "10.10.20.30" )
    for ip in "${IPS[@]}"; do
        emit "filter_ip" "richieste dall'ip ${ip}"
        emit "filter_ip" "cosa ha fatto l'ip ${ip}"
        emit "filter_ip" "traffico dal client ${ip}"
        emit "filter_ip" "attività dall'indirizzo ${ip}"
        emit "filter_ip" "accessi dall'ip ${ip} nelle ultime ore"
        emit "filter_ip" "errori http dall'ip ${ip}"
    done
    for v in "${SYN_FILTER[@]}"; do
        emit "filter_ip" "${v} le richieste per indirizzo ip"
        emit "filter_ip" "${v} per un ip specifico"
        emit "filter_ip" "${v} per client ip"
    done
    emit "filter_ip" "traccia le chiamate di un client specifico"
    emit "filter_ip" "analisi traffico per sorgente ip"
    emit "filter_ip" "quali endpoint ha chiamato il client 10.0.1.25"
    emit "filter_ip" "quante richieste ha fatto uno specifico indirizzo"
}

gen_filter_app_errors() {
    # keywords: applicat(46), nascost|intern(47), root.cause|business(48), loggat(49)
    # exception|eccezione(32) è un segnale forte aggiuntivo
    for v in "${SYN_SHOW[@]}"; do
        emit "filter_app_errors" "${v} gli errori applicativi nel server log"
        emit "filter_app_errors" "${v} le exception loggati come info"
        emit "filter_app_errors" "${v} i problemi applicativi nascosti nel log"
        emit "filter_app_errors" "${v} le eccezioni interne dell'applicazione"
    done
    for t in "${SYN_TIME[@]}"; do
        emit "filter_app_errors" "errori applicativi nel server log ${t}"
        emit "filter_app_errors" "exception nascoste nei log applicativi ${t}"
        emit "filter_app_errors" "errori interni loggati come info ${t}"
    done
    emit "filter_app_errors" "quali eccezioni java sono nel log info"
    emit "filter_app_errors" "status 500 loggati come informazioni"
    emit "filter_app_errors" "chiamate interne fallite nel log applicativo"
    emit "filter_app_errors" "errori di business nel server.log"
    emit "filter_app_errors" "null pointer exception nel log info jboss"
    emit "filter_app_errors" "root cause degli errori applicativi"
    emit "filter_app_errors" "exception nel server log loggati come info"
    emit "filter_app_errors" "quali servizi lanciano eccezioni nascoste"
    emit "filter_app_errors" "errori 500 applicativi loggati"
    emit "filter_app_errors" "exception interne nell'applicazione"
    emit "filter_app_errors" "analisi root cause errori applicativi"
}

# ─── Override dal profilo (opzionale) ────────────────────────────────────────
# Sourca examples.sh dal profilo DOPO le definizioni core, così il profilo può
# ridefinire qualunque gen_<tool>() o aggiungerne di nuovi specifici del dominio.
[[ -f "$PROFILE_DIR/examples.sh" ]] && source "$PROFILE_DIR/examples.sh"

# ─── Dispatch e output ────────────────────────────────────────────────────────

run_gen() {
    local fn="gen_${1//-/_}"
    if declare -f "$fn" > /dev/null 2>&1; then
        "$fn"
    else
        echo "[SKIP] nessun generatore per '$1' (definisci ${fn}() in examples.sh)" >&2
    fi
}

init_limits

# Stampa riepilogo dei gap
if [[ "${VERBOSE:-0}" == "1" || "$TOOL_ARG" == "all" ]]; then
    echo "── Gap dataset (target: ${TARGET}) ──────────────────" >&2
    for t in "${TOOL_NAMES[@]}"; do
        cur=$(current_count "$t")
        need="${TOOL_LIMIT[$t]:-0}"
        [[ $need -gt 0 ]] && echo "  ${t}: ${cur} → +${need}" >&2
    done
    echo "────────────────────────────────────────────────────" >&2
fi

if [[ "$TOOL_ARG" == "all" ]]; then
    for t in "${TOOL_NAMES[@]}"; do
        run_gen "$t"
    done
else
    run_gen "$TOOL_ARG"
fi

if [[ ${#OUTPUT_LINES[@]} -eq 0 ]]; then
    echo "Nessun nuovo esempio da generare (tutti i tool già a ${TARGET} esempi)." >&2
    exit 0
fi

if [[ "$APPLY" -eq 1 ]]; then
    {
        echo ""
        echo "# ─── generati automaticamente $(date '+%Y-%m-%d') ──────────────────────────────"
        for line in "${OUTPUT_LINES[@]}"; do echo "$line"; done
    } >> "$DATASET"
    echo "Aggiunti ${#OUTPUT_LINES[@]} esempi al dataset." >&2
else
    for line in "${OUTPUT_LINES[@]}"; do echo "$line"; done
    echo "" >&2
    echo "─── ${#OUTPUT_LINES[@]} esempi generati — usa --apply per aggiungerli al dataset" >&2
fi
