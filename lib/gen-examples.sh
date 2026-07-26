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
source "$SCRIPT_DIR/../config.sh"

TARGET=30
APPLY=0
TOOL_ARG="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --apply)  APPLY=1; shift ;;
        *)        TOOL_ARG="$1"; shift ;;
    esac
done

DATASET="$SCRIPT_DIR/../dataset/queries_labeled.txt"

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
emit() {
    local tool="$1"
    local query="${2,,}"
    [[ "${TOOL_LIMIT[$tool]:-0}" -le 0 ]] && return
    [[ "${TOOL_GEN_COUNT[$tool]:-0}" -ge "${TOOL_LIMIT[$tool]}" ]] && return
    [[ -n "${SEEN_QUERIES[$query]:-}" ]] && return
    SEEN_QUERIES["$query"]=1
    TOOL_GEN_COUNT[$tool]=$(( ${TOOL_GEN_COUNT[$tool]} + 1 ))
    OUTPUT_LINES+=("${tool}"$'\t'"${query}")
}

# ═══════════════════════════════════════════════════════════════════════════════
# TABELLE DI SINONIMI — modificare qui per aggiungere varianti
# ═══════════════════════════════════════════════════════════════════════════════

# Verbi generici di visualizzazione
SYN_SHOW=(  "mostrami" "dammi" "fammi vedere" "visualizza" "elenca"
            "voglio vedere" "mostra" "dimmi" "recupera" "fornisci" )

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
    # keywords: errore(0-1), 500(2), 400(3), status|stato(8), http(9), quant(21), total(23)
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
    # keywords: distribuzion(20), raggrupp(24), frequen(25), per(26), endpoint(43), api(45)
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
    # keywords: lent(30-31), latenz(32), ms(33), prestazion|performanc(34)
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
}

gen_traffic_volume() {
    # keywords: ora|ore(10-11), minut(12-13), giorn(14), ultim(17-18), quant(21), total(23)
    for t in "${SYN_TIME[@]}"; do
        emit "traffic_volume" "traffico ${t}"
        emit "traffic_volume" "volume di richieste ${t}"
        emit "traffic_volume" "quante chiamate ${t}"
        emit "traffic_volume" "andamento del traffico ${t}"
    done
    for v in "${SYN_SHOW[@]}"; do
        emit "traffic_volume" "${v} il traffico per ora"
        emit "traffic_volume" "${v} i picchi di richieste"
        emit "traffic_volume" "${v} le richieste al minuto"
    done
    emit "traffic_volume" "andamento richieste nell'arco della giornata"
    emit "traffic_volume" "picco di traffico nelle ultime ore"
    emit "traffic_volume" "richieste totali per ora di ieri"
}

gen_filter_errors() {
    # keywords: warn(35), exception|eccezione(36), stack.trace(37), crash|fatal(38), log.applicat(39)
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
}

gen_service_times() {
    # keywords: lent(30-31), latenz(32), ms(33), prestazion|performanc(34)
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
    emit "service_times" "quanto ci mette il servizio di autenticazione"
    emit "service_times" "durata media delle chiamate soa"
    emit "service_times" "servizi con response time alto"
    emit "service_times" "quale servizio è più lento in ms"
    emit "service_times" "tempi di esecuzione dei web service jboss"
}

gen_gc_stats() {
    # keywords: gc|garbage(40), heap(41), memori|jvm(42)
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
    # keywords: gc|garbage(40), lent(30-31), latenz(32), memori(42)
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
}

gen_tail_log() {
    # keywords: ultim(17-18), recent|ultim(49), list(27), mostr(48)
    for v in "${SYN_SHOW[@]}"; do
        emit "tail_log" "${v} le ultime righe del log"
        emit "tail_log" "${v} gli ultimi accessi"
        emit "tail_log" "${v} le ultime 100 righe dell'access log"
        emit "tail_log" "${v} gli ultimi eventi nel log"
    done
    for r in "${SYN_RECENT[@]}"; do
        emit "tail_log" "log ${r}"
        emit "tail_log" "richieste ${r}"
        emit "tail_log" "accessi ${r}"
    done
    emit "tail_log" "ultime 50 righe dell'access log"
    emit "tail_log" "cosa è successo di recente nel log"
    emit "tail_log" "attività recente nel log di accesso"
    emit "tail_log" "ultime 200 richieste al server"
    emit "tail_log" "le richieste più recenti"
}

gen_filter_ip() {
    # keywords: \bip\b(46), client|indirizz(47)
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
    # keywords: applicat(50), nascost|intern(51), root.cause|business(52), loggat(53)
    # exception|eccezione(36) è un segnale forte aggiuntivo
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

# ─── Dispatch e output ────────────────────────────────────────────────────────

run_gen() {
    case "$1" in
        count_status)      gen_count_status ;;
        distribute_status) gen_distribute_status ;;
        slow_requests)     gen_slow_requests ;;
        traffic_volume)    gen_traffic_volume ;;
        filter_errors)     gen_filter_errors ;;
        service_times)     gen_service_times ;;
        gc_stats)          gen_gc_stats ;;
        correlate_gc_slow) gen_correlate_gc_slow ;;
        tail_log)          gen_tail_log ;;
        filter_ip)         gen_filter_ip ;;
        filter_app_errors) gen_filter_app_errors ;;
        *) echo "[ERROR] tool sconosciuto: $1" >&2; exit 1 ;;
    esac
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
