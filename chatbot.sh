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
DRY_RUN=0
RESOLVED_DATE_FILTER=""
ACTIVE_NAMED_LOG=""
# Default temporale: oggi (00:00→23:59). L'utente può sovrascrivere con query esplicita.
ACTIVE_TIME_FROM="$(date +%Y-%m-%dT00:00)"
ACTIVE_TIME_TO="$(date +%Y-%m-%dT23:59)"

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
        --dry-run)    DRY_RUN=1; shift ;;
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

# Esporta PROFILE_DIR per tutti i lib (infer, normalize-query, query-to-features, resolve-logs)
export PROFILE_DIR

# Carica configurazione di sistema e dominio
source "$PROFILE_DIR/system.conf"
# Override locale (non deployato) — per variabili specifiche dell'ambiente di produzione
[[ -f "$PROFILE_DIR/system.local.conf" ]] && source "$PROFILE_DIR/system.local.conf"
source "$PROFILE_DIR/domain.conf"
# Dizionario entità (APP alias, ENV synonyms, NODE patterns) per normalize-query.sh
[[ -f "$PROFILE_DIR/entities.conf" ]] && source "$PROFILE_DIR/entities.conf"

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
        source <("$LIB_DIR/normalize-query.sh" "$QUERY")
        export NORM_QUERY
        [[ -n "$DETECTED_ENV"  && "$DETECTED_ENV"  != "$ACTIVE_ENV"  ]] && ACTIVE_ENV="$DETECTED_ENV"
        [[ -n "$DETECTED_NODE" && "$DETECTED_NODE" != "$ACTIVE_NODE" ]] && ACTIVE_NODE="$DETECTED_NODE"
        if [[ -n "$DETECTED_APP" && -z "$ACTIVE_APP" ]]; then
            ACTIVE_APP="${APP_CANONICAL[$DETECTED_APP]:-$DETECTED_APP}"
        fi
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
# (in dry-run non servono i log — skip)
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -n "$ACTIVE_ENV" && -z "$ACCESS_LOG" ]]; then
        resolve_session_logs || exit 1
    elif [[ -n "$ACCESS_LOG" && ! -f "$ACCESS_LOG" ]]; then
        echo "[ERROR] File non trovato: $ACCESS_LOG" >&2
        exit 1
    fi
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

    # Normalizza la query ed estrai entità (APP, ENV, NODE) — unica fonte di verità
    source <("$LIB_DIR/normalize-query.sh" "$query")
    export NORM_QUERY

    local ctx_changed=0
    [[ -n "$DETECTED_ENV"  && "$DETECTED_ENV"  != "$ACTIVE_ENV"  ]] && { ACTIVE_ENV="$DETECTED_ENV";  ctx_changed=1; }
    if [[ -n "$DETECTED_NODE" ]]; then
        local _norm_node; _norm_node=$(printf "%02d" "$((10#$DETECTED_NODE))" 2>/dev/null || echo "$DETECTED_NODE")
        [[ "$_norm_node" != "$ACTIVE_NODE" ]] && { ACTIVE_NODE="$_norm_node"; ctx_changed=1; }
    fi
    if [[ -n "$DETECTED_APP" ]]; then
        local _canonical="${APP_CANONICAL[$DETECTED_APP]:-$DETECTED_APP}"
        if [[ "$_canonical" != "$ACTIVE_APP" ]]; then
            ACTIVE_APP="$_canonical"
            ACTIVE_NAMED_LOG=""
            ctx_changed=1
        fi
    fi

    # Estrai parametri strutturati (TIME_FROM, TIME_TO, DATE_FILTER, ...) prima di resolve
    eval "$("$LIB_DIR/param-extract.sh" "$query")"

    # NAMED_LOG: aggiorna il contesto solo se la query specifica un log esplicito;
    # altrimenti riusa l'ultimo log menzionato in sessione (es. "stessa cosa" / "nello stesso log")
    if [[ -n "$NAMED_LOG" ]]; then
        ACTIVE_NAMED_LOG="$NAMED_LOG"
    else
        NAMED_LOG="$ACTIVE_NAMED_LOG"
    fi

    # CTX-1 — filtro temporale persistente.
    # Se la query specifica un tempo → aggiorna il contesto attivo.
    # Se non lo specifica → eredita da ACTIVE_TIME_FROM/TO (come già avviene per ACTIVE_NODE).
    if [[ -n "$TIME_FROM" || -n "$TIME_TO" ]]; then
        [[ "$TIME_FROM" != "$ACTIVE_TIME_FROM" || "$TIME_TO" != "$ACTIVE_TIME_TO" ]] && ctx_changed=1
        ACTIVE_TIME_FROM="$TIME_FROM"
        ACTIVE_TIME_TO="$TIME_TO"
    else
        TIME_FROM="$ACTIVE_TIME_FROM"
        TIME_TO="$ACTIVE_TIME_TO"
    fi

    # DATE_FILTER è una dimensione del contesto: se cambia → re-resolve
    [[ "${DATE_FILTER:-}" != "$RESOLVED_DATE_FILTER" ]] && { RESOLVED_DATE_FILTER="${DATE_FILTER:-}"; ctx_changed=1; }

    # CTX-3 — intercetta frasi di solo-contesto prima della lazy resolution e del classificatore.
    # Deve stare qui: "stamattina" senza env è un aggiornamento temporale valido anche senza log.
    # Usa NORM_QUERY (già normalizzata con placeholder <ENV>/<NODE>/<APP>) invece della query
    # originale: "sul nodo 4 di produzione" → "sul <NODE> di <ENV>" → residuo vuoto dopo strip.
    # Due casi:
    # A) ctx_changed=1 e il residuo di NORM_QUERY (senza placeholder e connettivi) è ≤4 char
    # B) TIME_ONLY_QUERY=1 — rilevato direttamente in utils-time.sh usando i suoi stessi pattern
    local _ctx_only=0
    local _ctx_query_stripped
    _ctx_query_stripped=$(echo "${NORM_QUERY:-$query}" | \
        sed -E 's/<(ENV|NODE|APP)>//gI' | \
        sed -E 's/\b(considera|lavoriamo|lavora|siamo|stiamo|parliamo|analizziamo|guardiam[oi]|fissa|imposta|usa|usiam[oi]|sul|sulla|sullo|sulle|sugli|nel|nella|nello|nelle|negli|del|della|dello|delle|degli|al|alla|allo|alle|agli|dal|dalla|dallo|dalle|dagli|col|nodo|in|su|di|da|per|il|la|lo|le|gli|un|una|e|a|o|con)\b//gI' | \
        sed -E 's/[[:space:]]+/ /g' | sed 's/^ *//; s/ *$//')
    [[ "$ctx_changed" -eq 1 && ${#_ctx_query_stripped} -le 4 ]] && _ctx_only=1
    [[ "${TIME_ONLY_QUERY:-0}" == "1" ]] && _ctx_only=1
    if [[ "$_ctx_only" -eq 1 ]]; then
        # Se env/nodo è cambiato, re-resolve i log prima di tornare — altrimenti
        # la query successiva usa ancora i log del nodo precedente.
        if [[ "$DRY_RUN" -eq 0 && "$ctx_changed" -eq 1 && -n "$ACTIVE_ENV" ]]; then
            resolve_session_logs || true
        fi
        printf "\n"
        context_line
        printf "  \033[2mContesto aggiornato.\033[0m\n\n"
        return
    fi

    # show_help non richiede contesto — intercetta prima della lazy resolution
    if echo "${query,,}" | grep -qiE "^(aiuto|help|\?|cosa (sai|puoi)[[:space:]]+(fare|fai)|cosa (fai|fare)|che (cosa )?(sai|puoi)[[:space:]]+(fare|fai)|strumenti|comandi)[[:space:]]*\?*$"; then
        printf "\n\033[1m┌─\033[0m Query: %s\n" "$query"
        print_help
        printf "\033[1m└──────────────────────────────────────────\033[0m\n"
        return
    fi

    # Lazy resolution: se ancora senza log, tenta ora che potremmo avere il contesto
    # (in dry-run non servono i log — skip)
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ -z "$ACCESS_LOG" ]]; then
            if [[ -z "$ACTIVE_ENV" ]]; then
                echo "  [INFO] Ambiente non impostato. Specifica env nella query (es: \"errori in coll\") oppure avvia con --env."
                return
            fi
            resolve_session_logs || return 1
        elif [[ "$ctx_changed" -eq 1 && -n "$ACTIVE_ENV" ]]; then
            resolve_session_logs || return 1
        fi
    fi

    printf "\n\033[1m┌─\033[0m Query: %s\n" "$query"

    # Modalità dry-run: mostra ranking classificatore senza eseguire tool
    if [[ "$DRY_RUN" -eq 1 ]]; then
        "$LIB_DIR/infer-dry.sh" "$query"
        return
    fi

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
        if [[ "$tool" == "search_all_logs" && -z "${DETECTED_NODE:-}" && -n "${ACTIVE_ENV:-}" ]]; then
            context_line "no_node"
        else
            context_line
        fi
        echo ""
        dispatch_tool "$tool" || true
        echo ""
    done <<< "$tools"

    printf "\033[1m└──────────────────────────────────────────\033[0m\n"
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Stampa il contesto attivo su stderr in formato leggibile.
# Colori: DIM per le etichette, WHT (bianco puro) per i valori — coerente con UI-8.
# Viene chiamata in cima ad ogni risposta (CTX-2).
# context_line [no_node]
# Con argomento "no_node": omette il nodo dal contesto (es. ricerca multi-nodo).
context_line() {
    local _hide_node="${1:-}"
    local _D="\033[2m" _W="\033[97m" _B="\033[1m" _X="\033[0m"
    local parts=()

    local _has_any=0
    [[ -n "$ACTIVE_ENV" || -n "$ACTIVE_TIME_FROM" || -n "$ACTIVE_TIME_TO" || -n "$ACCESS_LOG" ]] && _has_any=1

    if [[ "$_has_any" -eq 1 ]]; then
        if [[ -n "$ACCESS_LOG" && -z "$ACTIVE_ENV" ]]; then
            printf "  ${_D}[log: ${_X}${_W}%s${_X}${_D}]${_X}\n" "$ACCESS_LOG"
            return
        fi
        local _NA="${_D}N/A${_X}"
        parts+=("${_W}${ACTIVE_ENV:-${_NA}}${_X}")
        if [[ "$_hide_node" == "no_node" ]]; then
            parts+=("${_D}tutti i nodi${_X}")
        else
            parts+=("${_D}nodo${_X} ${_W}${ACTIVE_NODE:-${_NA}}${_X}")
        fi
        [[ -n "$ACTIVE_APP"       ]] && parts+=("${_W}${ACTIVE_APP}${_X}")
        [[ -n "$ACTIVE_NAMED_LOG" ]] && parts+=("${_D}log${_X} ${_W}${ACTIVE_NAMED_LOG}${_X}")
        if [[ -n "$ACTIVE_TIME_FROM" || -n "$ACTIVE_TIME_TO" ]]; then
            local tf="${ACTIVE_TIME_FROM:-inizio}" tt="${ACTIVE_TIME_TO:-fine}"
            tf="${tf/T/ }"; tt="${tt/T/ }"
            parts+=("${_W}${tf}${_X}${_D}→${_X}${_W}${tt}${_X}")
        fi
        local joined="" sep=""
        for _p in "${parts[@]}"; do
            joined="${joined}${sep}${_p}"
            sep="${_D} · ${_X}"
        done
        printf "  ${_D}[${_X}${joined}${_D}]${_X}\n"
    else
        printf "  ${_D}[contesto non impostato — es: \"errori in coll\"]${_X}\n"
    fi
}

profile_name=$(basename "$PROFILE_DIR")
_init_query_log

if [[ "$INTERACTIVE" -eq 0 ]]; then
    run_query "${QUERY:-}"
else
    printf "\033[1mNeural Log Analyzer\033[0m — profilo: \033[36m${profile_name}\033[0m\n"
    context_line
    [[ -n "${SERVER_LOG:-}" ]] && printf "     server.log: \033[2m$SERVER_LOG\033[0m\n"
    [[ -n "${GC_LOG:-}"     ]] && printf "     gc.log:     \033[2m$GC_LOG\033[0m\n"
    printf "\033[2mDigita la tua domanda (Ctrl+C per uscire) — \033[0m\033[1maiuto\033[0m\033[2m per la lista degli strumenti\033[0m\n\n"

    while true; do
        printf "> "
        read -r query || break
        [[ -z "$query" ]] && continue
        [[ "$query" == "exit" || "$query" == "quit" ]] && break
        # Keyword detection help — intercetta prima del classificatore
        if echo "$query" | grep -qiE "^(aiuto|help|\?|cosa (sai|puoi)[[:space:]]+(fare|fai)|cosa (fai|fare)|che (cosa )?(sai|puoi)[[:space:]]+(fare|fai)|strumenti|comandi)[[:space:]]*\?*$"; then
            print_help
            continue
        fi
        run_query "$query"
    done
fi
