#!/bin/bash
#
# Interfaccia conversazionale per l'analisi dei log.
#
# Uso con profilo (consigliato):
#   ./chatbot.sh --profile profiles/liquido [--env coll] [--node 2] [--app ClaimCenter]
#
# Uso con path espliciti (compatibilità legacy):
#   ./chatbot.sh --profile profiles/liquido --access-log path/access.log [--server-log ...] [--gc-log ...]
#
# Modalità non interattiva (--env obbligatorio):
#   ./chatbot.sh --profile profiles/liquido --env coll --query "errori 500 delle ultime 3 ore"
#   echo "..." | ./chatbot.sh --profile profiles/liquido --env prod
#
# In modalità interattiva --env è opzionale: il bot lo deduce dalla prima query
# che menziona l'ambiente (es: "errori 500 in coll nodo 2").
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ─── Parsing CLI ─────────────────────────────────────────────────────────────
PROFILE_DIR=""
ACTIVE_ENV=""
ACTIVE_NODE="01"
ACTIVE_APP=""
BASE_DIR_OVERRIDE=""
ACCESS_LOG=""
SERVER_LOG=""
GC_LOG=""
INTERACTIVE=1
QUERY=""
RESOLVED_DATE_FILTER=""
ACTIVE_NAMED_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)    PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --env)        ACTIVE_ENV="$2";          shift 2 ;;
        --node)       ACTIVE_NODE="$2";         shift 2 ;;
        --app)        ACTIVE_APP="$2";          shift 2 ;;
        --base-dir)   BASE_DIR_OVERRIDE="$2";   shift 2 ;;
        --access-log) ACCESS_LOG="$2";          shift 2 ;;
        --server-log) SERVER_LOG="$2";          shift 2 ;;
        --gc-log)     GC_LOG="$2";              shift 2 ;;
        --query)      QUERY="$2"; INTERACTIVE=0; shift 2 ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!" | head -16 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

# ─── Validazione profilo ─────────────────────────────────────────────────────
if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: --profile profiles/liquido" >&2
    exit 1
fi
if [[ ! -f "$PROFILE_DIR/system.conf" || ! -f "$PROFILE_DIR/domain.conf" ]]; then
    echo "[ERROR] Profilo non valido: $PROFILE_DIR (mancano system.conf o domain.conf)" >&2
    exit 1
fi

# Esporta PROFILE_DIR per tutti i lib (infer, context-extract, query-to-features, resolve-logs)
export PROFILE_DIR

# Carica configurazione di sistema e dominio
source "$PROFILE_DIR/system.conf"
# Override locale (non deployato) — per variabili specifiche dell'ambiente di produzione
[[ -f "$PROFILE_DIR/system.local.conf" ]] && source "$PROFILE_DIR/system.local.conf"
source "$PROFILE_DIR/domain.conf"

# Allinea TZ di sistema con quella dei log del server (tutti i sottoprocessi la ereditano)
[[ -n "${LOG_TZ:-}" ]] && export TZ="$LOG_TZ"

# Override base dir se passato esplicitamente
[[ -n "$BASE_DIR_OVERRIDE" ]] && LOG_BASE_DIR="$BASE_DIR_OVERRIDE"

# App di default dal profilo se non specificata
[[ -z "$ACTIVE_APP" ]] && ACTIVE_APP="$DEFAULT_APP"

# Path del modello addestrato
MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
TOOLS_DIR="$SCRIPT_DIR/lib/tools"

# Carica dispatch (open_log + dispatch_tool)
source "$LIB_DIR/dispatch.sh"

# ─── Modalità non interattiva: deduzione contesto dalla query ────────────────
if [[ "$INTERACTIVE" -eq 0 && -z "$ACCESS_LOG" ]]; then
    if [[ -n "$QUERY" ]]; then
        ctx=$("$LIB_DIR/context-extract.sh" "$QUERY")
        eval "$ctx"
        [[ -n "$CTX_ENV"  && "$CTX_ENV"  != "$ACTIVE_ENV"  ]] && ACTIVE_ENV="$CTX_ENV"
        [[ -n "$CTX_NODE" && "$CTX_NODE" != "$ACTIVE_NODE" ]] && ACTIVE_NODE="$CTX_NODE"
        [[ -n "$CTX_APP"  && "$CTX_APP"  != "$ACTIVE_APP"  ]] && ACTIVE_APP="$CTX_APP"
    fi
    if [[ -z "$ACTIVE_ENV" ]]; then
        echo "[ERROR] --query richiede --env (o --access-log), oppure menziona l'ambiente nella query (es: \"errori in coll\")" >&2
        exit 1
    fi
fi

# ─── Validazione modello ─────────────────────────────────────────────────────
if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non trovato: $MODEL_DIR" >&2
    echo "        Esegui prima: ./setup.sh --profile $PROFILE_DIR && ./train.sh --profile $PROFILE_DIR" >&2
    exit 1
fi

# ─── Risoluzione log da env/nodo/app ─────────────────────────────────────────
resolve_session_logs() {
    local resolved
    resolved=$(DATE_FILTER="${DATE_FILTER:-}" "$LIB_DIR/resolve-logs.sh" "$LOG_BASE_DIR" "$ACTIVE_ENV" "$ACTIVE_NODE" "$ACTIVE_APP") || {
        echo "[ERROR] Impossibile risolvere i log per: env=$ACTIVE_ENV node=$ACTIVE_NODE app=$ACTIVE_APP" >&2
        return 1
    }
    eval "$resolved"
}

# Risoluzione iniziale solo se --env è stato passato o se --access-log è esplicito
if [[ -n "$ACTIVE_ENV" && -z "$ACCESS_LOG" ]]; then
    resolve_session_logs || exit 1
elif [[ -n "$ACCESS_LOG" && ! -f "$ACCESS_LOG" ]]; then
    echo "[ERROR] File non trovato: $ACCESS_LOG" >&2
    exit 1
fi

# ─── Query logging ───────────────────────────────────────────────────────────
_QUERY_LOG_FILE=""

_init_query_log() {
    [[ -z "${QUERY_LOG_DIR:-}" ]] && return
    mkdir -p "$QUERY_LOG_DIR" 2>/dev/null || return
    _QUERY_LOG_FILE="${QUERY_LOG_DIR}/chatbot-$(date +%Y-%m-%d).log"
}

log_query() {
    [[ -z "$_QUERY_LOG_FILE" ]] && return
    local query="$1" tools="$2"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" \
        "${ACTIVE_ENV:-?}" "${ACTIVE_NODE:-?}" \
        "$query" \
        "$tools" \
        "${profile_name:-}" \
        >> "$_QUERY_LOG_FILE" 2>/dev/null || true
}

_rotate_query_logs() {
    [[ -z "${QUERY_LOG_DIR:-}" ]] && return
    local days="${QUERY_LOG_RETENTION_DAYS:-15}"
    find "$QUERY_LOG_DIR" -maxdepth 1 -name 'chatbot-*.log' \
        -mtime "+${days}" -delete 2>/dev/null || true
}

trap '_rotate_query_logs' EXIT

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

    # Estrai parametri strutturati (TIME_FROM, TIME_TO, DATE_FILTER, ...) prima di resolve
    eval "$("$LIB_DIR/param-extract.sh" "$query")"

    # NAMED_LOG: aggiorna il contesto solo se la query specifica un log esplicito;
    # altrimenti riusa l'ultimo log menzionato in sessione (es. "stessa cosa" / "nello stesso log")
    if [[ -n "$NAMED_LOG" ]]; then
        ACTIVE_NAMED_LOG="$NAMED_LOG"
    else
        NAMED_LOG="$ACTIVE_NAMED_LOG"
    fi

    # DATE_FILTER è una dimensione del contesto: se cambia → re-resolve
    [[ "${DATE_FILTER:-}" != "$RESOLVED_DATE_FILTER" ]] && { RESOLVED_DATE_FILTER="${DATE_FILTER:-}"; ctx_changed=1; }

    # Lazy resolution: se ancora senza log, tenta ora che potremmo avere il contesto
    if [[ -z "$ACCESS_LOG" ]]; then
        if [[ -z "$ACTIVE_ENV" ]]; then
            echo "  [INFO] Ambiente non impostato. Specifica env nella query (es: \"errori in coll\") oppure avvia con --env."
            return
        fi
        resolve_session_logs || return 1
    elif [[ "$ctx_changed" -eq 1 && -n "$ACTIVE_ENV" ]]; then
        resolve_session_logs || return 1
    fi

    if [[ "$ctx_changed" -eq 1 ]]; then
        local ctx_msg
        printf "  \033[2m[Contesto: \033[0m\033[1m%s\033[0m\033[2m  nodo \033[0m\033[1m%s\033[0m\033[2m  %s" \
            "$ACTIVE_ENV" "$ACTIVE_NODE" "$ACTIVE_APP"
        [[ -n "$ACTIVE_NAMED_LOG" ]] && printf "\033[2m  log=\033[0m\033[1m%s\033[0m" "$ACTIVE_NAMED_LOG"
        printf "\033[2m]\033[0m\n"
    fi

    printf "\n\033[1m┌─\033[0m Query: %s\n" "$query"

    local tools
    tools=$("$LIB_DIR/infer.sh" "$query" 2>/dev/null)

    if [[ -z "$tools" ]]; then
        log_query "$query" "none"
        printf "\033[1m└─\033[0m \033[2m[INFO] Nessun tool attivato con confidenza >= %s\033[0m\n" "$TOOL_THRESHOLD"
        printf "   Prova a riformulare la query. Digita \033[1maiuto\033[0m per vedere cosa so fare.\n"
        return
    fi

    # Loga: tool attivati come "tool1:pct,tool2:pct"
    local tools_log
    tools_log=$(awk '{printf "%s:%d%%,", $1, $2*100}' <<< "$tools" | sed 's/,$//')
    log_query "$query" "$tools_log"

    printf "\033[1m│\033[0m  Tool attivati:\n"
    while IFS=' ' read -r tool prob; do
        pct=$(awk -v p="$prob" 'BEGIN { printf "%.0f", p * 100 }')
        printf "\033[1m│\033[0m    \033[1m▸ %s\033[0m \033[2m(%s%%)\033[0m — %s\n" \
            "$tool" "$pct" "${TOOL_DESC[$tool]:-}"
    done <<< "$tools"
    printf "\033[1m│\033[0m\n"

    while IFS=' ' read -r tool _prob; do
        printf "\033[1m├─── %s\033[0m ─────────────────────────────\n" "$tool"
        dispatch_tool "$tool"
        echo ""
    done <<< "$tools"

    printf "\033[1m└──────────────────────────────────────────\033[0m\n"
}

# ─── Main ────────────────────────────────────────────────────────────────────
context_line() {
    if [[ -n "$ACTIVE_ENV" ]]; then
        local ctx="Contesto: $ACTIVE_ENV  nodo $ACTIVE_NODE  ($ACTIVE_APP)"
        [[ -n "$ACTIVE_NAMED_LOG" ]] && ctx+="  log=$ACTIVE_NAMED_LOG"
        echo "$ctx"
    elif [[ -n "$ACCESS_LOG" ]]; then
        echo "Log: $ACCESS_LOG"
    else
        echo "Contesto: non impostato — specificalo nella prima query (es: \"errori in coll\")"
    fi
}

profile_name=$(basename "$PROFILE_DIR")
_init_query_log

if [[ "$INTERACTIVE" -eq 0 ]]; then
    run_query "${QUERY:-}"
else
    printf "\033[1mNeural Log Analyzer\033[0m — profilo: \033[36m${profile_name}\033[0m\n"
    printf "$(context_line)\n"
    [[ -n "${SERVER_LOG:-}" ]] && printf "     server.log: \033[2m$SERVER_LOG\033[0m\n"
    [[ -n "${GC_LOG:-}"     ]] && printf "     gc.log:     \033[2m$GC_LOG\033[0m\n"
    printf "\033[2mDigita la tua domanda (Ctrl+C per uscire) — \033[0m\033[1maiuto\033[0m\033[2m per la lista degli strumenti\033[0m\n\n"

    while true; do
        printf "> "
        read -r query || break
        [[ -z "$query" ]] && continue
        [[ "$query" == "exit" || "$query" == "quit" ]] && break
        # Keyword detection help — intercetta prima del classificatore
        if echo "$query" | grep -qiE "^(aiuto|help|\?|cosa (sai|puoi|fai)|che (cosa )?(sai|puoi|fai)|strumenti|comandi)$"; then
            print_help
            continue
        fi
        run_query "$query"
    done
fi
