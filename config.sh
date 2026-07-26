#!/bin/bash
#
# Configurazione centrale per neural-log-analyzer.
# Incluso da tutti gli altri script con: source "$(dirname "$0")/config.sh"
#

ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "$ANALYZER_DIR/.." && pwd)"

NNET_RUN="$FRAMEWORK_DIR/nnet-run.sh"
NNET_INIT="$FRAMEWORK_DIR/nnet-init.sh"

MODEL_DIR="$ANALYZER_DIR/models/intent_classifier"
DATASET_FILE="$ANALYZER_DIR/dataset/queries.txt"
LIB_DIR="$ANALYZER_DIR/lib"
TOOLS_DIR="$ANALYZER_DIR/lib/tools"

# Numero di feature del vettore di input.
# Composizione: 54 unigram (0..53) + 4 bigram di co-presenza (54..57).
# Aggiornare qui e in lib/query-to-features.sh in modo coerente.
NUM_FEATURES=58

# Numero di tool (classi output della rete)
NUM_TOOLS=11

# Soglia di confidenza per attivare un tool
TOOL_THRESHOLD=0.20

# Architettura della rete: 58 input → 32 hidden → 11 output
MODEL_TOPOLOGY="${NUM_FEATURES},32,${NUM_TOOLS}"

# Nomi dei tool nell'ordine dell'output layer (indice 0..10)
TOOL_NAMES=(
    count_status
    distribute_status
    slow_requests
    traffic_volume
    filter_errors
    service_times
    gc_stats
    correlate_gc_slow
    tail_log
    filter_ip
    filter_app_errors
)

# Descrizioni leggibili per l'utente
declare -A TOOL_DESC
TOOL_DESC[count_status]="Conta richieste HTTP per codice di stato"
TOOL_DESC[distribute_status]="Distribuisce errori per endpoint, IP o fascia oraria"
TOOL_DESC[slow_requests]="Richieste con tempo di risposta sopra soglia"
TOOL_DESC[traffic_volume]="Volume di traffico per finestra temporale"
TOOL_DESC[filter_errors]="Righe ERROR/WARN dal server.log con classe e messaggio"
TOOL_DESC[service_times]="Tempi di esecuzione servizi SOA dal server.log"
TOOL_DESC[gc_stats]="Statistiche GC: pause, heap usage, frequenza"
TOOL_DESC[correlate_gc_slow]="Correlazione tra pause GC e richieste lente"
TOOL_DESC[tail_log]="Ultime N righe di un file di log"
TOOL_DESC[filter_ip]="Traffico filtrato per indirizzo IP sorgente"
TOOL_DESC[filter_app_errors]="Errori applicativi nel server.log (status 5xx e exception loggati come INFO)"
