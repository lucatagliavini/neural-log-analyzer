#!/bin/bash
#
# Interfaccia conversazionale per l'analisi dei log JBoss/Undertow.
# Legge una query, classifica l'intent con la rete neurale, esegue i tool.
#
# Uso:
#   ./chatbot.sh --access-log path/access.log [--server-log path/server.log] [--gc-log path/gc.log]
#   echo "errori 500 delle ultime 3 ore" | ./chatbot.sh --access-log ...
#

set -euo pipefail
source "$(dirname "$0")/config.sh"

ACCESS_LOG=""
SERVER_LOG=""
GC_LOG=""
INTERACTIVE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --access-log) ACCESS_LOG="$2";  shift 2 ;;
        --server-log) SERVER_LOG="$2";  shift 2 ;;
        --gc-log)     GC_LOG="$2";      shift 2 ;;
        --query)      QUERY="$2"; INTERACTIVE=0; shift 2 ;;
        -h|--help)
            echo "Uso: $0 --access-log <file> [--server-log <file>] [--gc-log <file>]"
            exit 0
            ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ACCESS_LOG" ]]; then
    echo "[ERROR] --access-log è obbligatorio" >&2
    exit 1
fi

if [[ ! -f "$ACCESS_LOG" ]]; then
    echo "[ERROR] File non trovato: $ACCESS_LOG" >&2
    exit 1
fi

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non trovato. Esegui prima ./setup.sh e ./train.sh" >&2
    exit 1
fi

dispatch_tool() {
    local tool="$1"
    local access="$ACCESS_LOG"
    local server="${SERVER_LOG:-}"
    local gc="${GC_LOG:-}"

    case "$tool" in
        count_status)
            gawk -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$access"
            ;;
        distribute_status)
            gawk -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$access"
            ;;
        slow_requests)
            gawk -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                -v time_window="$TIME_WINDOW" \
                "$access"
            ;;
        traffic_volume)
            gawk -f "$TOOLS_DIR/traffic_volume.awk" \
                -v time_window="$TIME_WINDOW" \
                "$access"
            ;;
        filter_errors)
            [[ -z "$server" ]] && { echo "[SKIP] --server-log non fornito per filter_errors"; return; }
            gawk -f "$TOOLS_DIR/filter_errors.awk" \
                -v time_window="$TIME_WINDOW" \
                "$server"
            ;;
        service_times)
            [[ -z "$server" ]] && { echo "[SKIP] --server-log non fornito per service_times"; return; }
            gawk -f "$TOOLS_DIR/service_times.awk" \
                -v time_window="$TIME_WINDOW" \
                "$server"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { echo "[SKIP] --gc-log non fornito per gc_stats"; return; }
            gawk -f "$TOOLS_DIR/gc_stats.awk" \
                -v time_window="$TIME_WINDOW" \
                "$gc"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { echo "[SKIP] --gc-log non fornito per correlate_gc_slow"; return; }
            gawk -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$gc" "$access"
            ;;
        tail_log)
            gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$access"
            ;;
        filter_ip)
            gawk -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v time_window="$TIME_WINDOW" \
                "$access"
            ;;
        filter_app_errors)
            [[ -z "$server" ]] && { echo "[SKIP] --server-log non fornito per filter_app_errors"; return; }
            gawk -f "$TOOLS_DIR/filter_app_errors.awk" \
                -v time_window="$TIME_WINDOW" \
                "$server"
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}

run_query() {
    local query="$1"

    echo ""
    echo "┌─ Query: $query"

    # Classificazione intent
    local tools
    tools=$("$LIB_DIR/infer.sh" "$query" 2>/dev/null)

    if [[ -z "$tools" ]]; then
        echo "└─ [INFO] Nessun tool attivato con confidenza >= $TOOL_THRESHOLD"
        echo "   Prova a riformulare la query."
        return
    fi

    # Estrazione parametri
    eval "$("$LIB_DIR/param-extract.sh" "$query")"

    echo "│  Tool attivati:"
    while IFS=' ' read -r tool prob; do
        pct=$(awk "BEGIN { printf \"%.0f\", $prob * 100 }")
        echo "│    ▸ $tool (${pct}%) — ${TOOL_DESC[$tool]:-}"
    done <<< "$tools"
    echo "│"

    # Esecuzione tool
    while IFS=' ' read -r tool _prob; do
        echo "├─── $tool ─────────────────────────────"
        dispatch_tool "$tool"
        echo ""
    done <<< "$tools"

    echo "└──────────────────────────────────────────"
}

# Modalità interattiva o singola query
if [[ "$INTERACTIVE" -eq 0 ]]; then
    run_query "${QUERY:-}"
else
    echo "Neural Log Analyzer — JBoss/Undertow"
    echo "Log: $ACCESS_LOG"
    [[ -n "$SERVER_LOG" ]] && echo "     $SERVER_LOG"
    [[ -n "$GC_LOG"     ]] && echo "     $GC_LOG"
    echo "Digita la tua domanda (Ctrl+C per uscire)"
    echo ""

    while true; do
        printf "> "
        read -r query || break
        [[ -z "$query" ]] && continue
        [[ "$query" == "exit" || "$query" == "quit" ]] && break
        run_query "$query"
    done
fi
