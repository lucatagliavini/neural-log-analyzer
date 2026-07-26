#!/bin/bash
#
# Risolve i path dei file di log data la tupla (base_dir, env, nodo, app).
# Emette variabili shell: ACCESS_LOG, SERVER_LOG, GC_LOG
#
# Uso: eval "$(./lib/resolve-logs.sh <base_dir> <env> <nodo_num> [<app>])"
#
# Struttura attesa:
#   <base_dir>/<env>/lx<envcode>jbliq<nn>/<env>/<app>/
#     server.log
#     gc.log
#     undertow_access_log.YYYY-MM-DD.log   ← si usa il più recente
#
# <envcode> è derivato da ENV_NODE_CODE[] definito in config.sh.
#

source "$(dirname "$0")/../config.sh"

BASE_DIR="${1:-$LOG_BASE_DIR}"
ENV_NAME="${2:-}"
NODE_NUM="${3:-01}"
APP="${4:-$DEFAULT_APP}"

# ─── Validazione ─────────────────────────────────────────────────────────────

if [[ -z "$ENV_NAME" ]]; then
    echo "echo '[ERROR] resolve-logs: ambiente non specificato' >&2" >&2
    exit 1
fi

ENV_CODE="${ENV_NODE_CODE[$ENV_NAME]:-}"
if [[ -z "$ENV_CODE" ]]; then
    echo "echo '[ERROR] resolve-logs: ambiente sconosciuto: $ENV_NAME' >&2" >&2
    exit 1
fi

# ─── Risoluzione nodo ────────────────────────────────────────────────────────
# Normalizza il numero nodo a 2 cifre (1 → 01)
NODE_NUM=$(printf "%02d" "$NODE_NUM" 2>/dev/null || echo "$NODE_NUM")
NODE_NAME="lx${ENV_CODE}jbliq${NODE_NUM}"
NODE_DIR="$BASE_DIR/$ENV_NAME/$NODE_NAME"

if [[ ! -d "$NODE_DIR" ]]; then
    # Prova a trovare il primo nodo disponibile
    NODE_DIR=$(find "$BASE_DIR/$ENV_NAME" -maxdepth 1 -type d -name "lx${ENV_CODE}jbliq*" | sort | head -1)
    if [[ -z "$NODE_DIR" ]]; then
        echo "echo '[ERROR] resolve-logs: nodo non trovato in $BASE_DIR/$ENV_NAME' >&2" >&2
        exit 1
    fi
    NODE_NAME=$(basename "$NODE_DIR")
fi

# ─── Risoluzione app ─────────────────────────────────────────────────────────
APP_DIR="$NODE_DIR/$ENV_NAME/$APP"

if [[ ! -d "$APP_DIR" ]]; then
    echo "echo '[ERROR] resolve-logs: app dir non trovata: $APP_DIR' >&2" >&2
    exit 1
fi

# ─── File di log ─────────────────────────────────────────────────────────────
# Risolve un file di log: restituisce il path del file plain o .gz più recente.
# Se il file è .gz, restituisce il path con suffisso .gz invariato — il
# chiamante usa open_log() in chatbot.sh per gestire la decompressione.
resolve_log_file() {
    local base_path="$1"
    if   [[ -f "${base_path}" ]];     then echo "${base_path}"
    elif [[ -f "${base_path}.gz" ]];  then echo "${base_path}.gz"
    else echo ""
    fi
}

SERVER_LOG_PATH=$(resolve_log_file "$APP_DIR/server.log")
GC_LOG_PATH=$(resolve_log_file "$APP_DIR/gc.log")

# Access log: prende il più recente tra plain e .gz, preferisce plain
ACCESS_LOG_PATH=$(
    { find "$APP_DIR" -maxdepth 1 -name "undertow_access_log*.log" -o \
                                   -name "undertow_access_log*.log.gz"; } 2>/dev/null \
    | sort -r | head -1
)

if [[ -z "$ACCESS_LOG_PATH" ]]; then
    echo "echo '[ERROR] resolve-logs: nessun undertow_access_log in $APP_DIR' >&2" >&2
    exit 1
fi

# ─── Output ──────────────────────────────────────────────────────────────────
echo "ACCESS_LOG='${ACCESS_LOG_PATH}'"
echo "SERVER_LOG='${SERVER_LOG_PATH}'"
echo "GC_LOG='${GC_LOG_PATH}'"
echo "ACTIVE_NODE='${NODE_NUM}'"
echo "ACTIVE_ENV='${ENV_NAME}'"
echo "ACTIVE_APP='${APP}'"
echo "GUIDEWIRE_LOG_DIR='${NODE_DIR}/${APP}/Guidewire'"
