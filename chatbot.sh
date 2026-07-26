#!/bin/bash
#
# Interfaccia conversazionale per l'analisi dei log Guidewire/JBoss/Undertow.
#
# Uso con resolver automatico (consigliato):
#   ./chatbot.sh --env coll [--node 2] [--app ClaimCenter]
#
# Uso con path espliciti (compatibilità legacy):
#   ./chatbot.sh --access-log path/access.log [--server-log ...] [--gc-log ...]
#
# Modalità non interattiva:
#   ./chatbot.sh --env test --query "errori 500 delle ultime 3 ore"
#   echo "..." | ./chatbot.sh --env prod
#

set -euo pipefail
source "$(dirname "$0")/config.sh"

# ─── Stato di sessione ───────────────────────────────────────────────────────
ACTIVE_ENV=""
ACTIVE_NODE="01"
ACTIVE_APP="$DEFAULT_APP"
ACCESS_LOG=""
SERVER_LOG=""
GC_LOG=""
INTERACTIVE=1
QUERY=""

# ─── Parsing CLI ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)        ACTIVE_ENV="$2";   shift 2 ;;
        --node)       ACTIVE_NODE="$2";  shift 2 ;;
        --app)        ACTIVE_APP="$2";   shift 2 ;;
        --base-dir)   LOG_BASE_DIR="$2"; shift 2 ;;
        --access-log) ACCESS_LOG="$2";   shift 2 ;;
        --server-log) SERVER_LOG="$2";   shift 2 ;;
        --gc-log)     GC_LOG="$2";       shift 2 ;;
        --query)      QUERY="$2"; INTERACTIVE=0; shift 2 ;;
        -h|--help)
            grep "^#" "$0" | head -14 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

# ─── Risoluzione log ─────────────────────────────────────────────────────────
resolve_session_logs() {
    if [[ -n "$ACTIVE_ENV" ]]; then
        local resolved
        resolved=$("$LIB_DIR/resolve-logs.sh" "$LOG_BASE_DIR" "$ACTIVE_ENV" "$ACTIVE_NODE" "$ACTIVE_APP") || {
            echo "[ERROR] Impossibile risolvere i log per: env=$ACTIVE_ENV node=$ACTIVE_NODE app=$ACTIVE_APP" >&2
            return 1
        }
        eval "$resolved"
    fi
}

# Risoluzione iniziale
if [[ -z "$ACCESS_LOG" ]]; then
    resolve_session_logs || exit 1
fi

if [[ -z "$ACCESS_LOG" ]]; then
    echo "[ERROR] Specifica --env oppure --access-log" >&2
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

# ─── Helper: apertura trasparente di log plain o .gz ─────────────────────────
# Uso: gawk ... $(log_args "$file")
# Restituisce il path diretto oppure un process substitution gunzip -c.
# Compatibile con Linux, WSL e AIX (gunzip -c è POSIX).
open_log() {
    local f="$1"
    [[ -z "$f" ]] && return
    if [[ "$f" == *.gz ]]; then
        echo "<(gunzip -c '$f')"
    else
        echo "'$f'"
    fi
}

# ─── Dispatch tool ───────────────────────────────────────────────────────────
dispatch_tool() {
    local tool="$1"
    local access="$ACCESS_LOG"
    local server="${SERVER_LOG:-}"
    local gc="${GC_LOG:-}"

    case "$tool" in
        count_status)
            eval gawk -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        distribute_status)
            eval gawk -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        slow_requests)
            eval gawk -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        traffic_volume)
            eval gawk -f "$TOOLS_DIR/traffic_volume.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        filter_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_errors"; return; }
            eval gawk -f "$TOOLS_DIR/filter_errors.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$server")"
            ;;
        service_times)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per service_times"; return; }
            eval gawk -f "$TOOLS_DIR/service_times.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$server")"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per gc_stats"; return; }
            eval gawk -f "$TOOLS_DIR/gc_stats.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$gc")"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per correlate_gc_slow"; return; }
            eval gawk -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$(open_log "$gc")" "$(open_log "$access")"
            ;;
        tail_log)
            eval gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$access")"
            ;;
        filter_ip)
            eval gawk -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        filter_app_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_app_errors"; return; }
            eval gawk -f "$TOOLS_DIR/filter_app_errors.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$server")"
            ;;
        tail_named_log)
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            local named_log="${NAMED_LOG:-}"
            if [[ -z "$named_log" ]]; then
                echo "[SKIP] Nessun log Guidewire specificato nella query"
                return
            fi
            local log_path=""
            if [[ -n "$gw_dir" ]]; then
                log_path=$(find "$gw_dir" -maxdepth 1 \
                    \( -name "*${named_log}*.log" -o -name "*${named_log}*.log.gz" \) \
                    | sort -r | head -1)
            fi
            if [[ -z "$log_path" ]]; then
                echo "[SKIP] Log '$named_log' non trovato in $gw_dir"
                return
            fi
            echo "  Log: $log_path"
            eval gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$log_path")"
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}

# ─── Esecuzione query ────────────────────────────────────────────────────────
run_query() {
    local query="$1"

    # Estrai eventuale cambio di contesto dalla query
    local ctx
    ctx=$("$LIB_DIR/context-extract.sh" "$query")
    eval "$ctx"

    local ctx_changed=0
    [[ -n "$CTX_ENV"  && "$CTX_ENV"  != "$ACTIVE_ENV"  ]] && { ACTIVE_ENV="$CTX_ENV";   ctx_changed=1; }
    [[ -n "$CTX_NODE" && "$CTX_NODE" != "$ACTIVE_NODE" ]] && { ACTIVE_NODE="$CTX_NODE"; ctx_changed=1; }
    [[ -n "$CTX_APP"  && "$CTX_APP"  != "$ACTIVE_APP"  ]] && { ACTIVE_APP="$CTX_APP";   ctx_changed=1; }

    if [[ "$ctx_changed" -eq 1 ]]; then
        resolve_session_logs || return 1
        echo "  [Contesto: env=$ACTIVE_ENV  nodo=$ACTIVE_NODE  app=$ACTIVE_APP]"
    fi

    echo ""
    echo "┌─ Query: $query"

    local tools
    tools=$("$LIB_DIR/infer.sh" "$query" 2>/dev/null)

    if [[ -z "$tools" ]]; then
        echo "└─ [INFO] Nessun tool attivato con confidenza >= $TOOL_THRESHOLD"
        echo "   Prova a riformulare la query."
        return
    fi

    eval "$("$LIB_DIR/param-extract.sh" "$query")"

    echo "│  Tool attivati:"
    while IFS=' ' read -r tool prob; do
        pct=$(awk "BEGIN { printf \"%.0f\", $prob * 100 }")
        echo "│    ▸ $tool (${pct}%) — ${TOOL_DESC[$tool]:-}"
    done <<< "$tools"
    echo "│"

    while IFS=' ' read -r tool _prob; do
        echo "├─── $tool ─────────────────────────────"
        dispatch_tool "$tool"
        echo ""
    done <<< "$tools"

    echo "└──────────────────────────────────────────"
}

# ─── Main ────────────────────────────────────────────────────────────────────
context_line() {
    local env_info="${ACTIVE_ENV:-path esplicito}"
    local node_info="${ACTIVE_NODE:-}"
    local app_info="${ACTIVE_APP:-}"
    [[ -n "$node_info" && -n "$ACTIVE_ENV" ]] && echo "Contesto: $env_info  nodo $node_info  ($app_info)" \
                                               || echo "Log: $ACCESS_LOG"
}

if [[ "$INTERACTIVE" -eq 0 ]]; then
    run_query "${QUERY:-}"
else
    echo "Neural Log Analyzer — Guidewire/JBoss"
    context_line
    [[ -n "$SERVER_LOG" ]] && echo "     server.log: $SERVER_LOG"
    [[ -n "$GC_LOG"     ]] && echo "     gc.log:     $GC_LOG"
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
