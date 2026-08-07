#!/bin/bash
#
# Risolve i path dei file di log data la tupla (base_dir, env, nodo, app).
# Emette variabili shell: ACCESS_LOG, ACCESS_LOG_DIR, ACCESS_LOG_BASE,
#                         SERVER_LOG, GC_LOG, GC_LOG_DIR, GC_LOG_BASE,
#                         CUSTOM_LOG_DIR, LOG_SEARCH_ROOT
#
# LOG_SEARCH_ROOT è la directory del nodo: il contratto del profilo si ferma
# lì, sotto la struttura è ignota e va scoperta ricorsivamente (vedi
# CLAUDE.md, "Principi di progettazione").
#
# La selezione temporale dei file di rotazione è delegata a utils-logfiles.sh
# (chiamata in open_logs() dentro dispatch.sh ad ogni query).
#
# Uso: eval "$(./lib/resolve-logs.sh <base_dir> <env> <nodo_num> [<app>])"
#
# Struttura attesa:
#   <base_dir>/<env>/<NODE_NAME_TEMPLATE>/<APP_SUBPATH>/
#     ${SERVER_LOG_BASE}.log, ${GC_LOG_BASE}.log, ${ACCESS_LOG_BASE}.*.log
#
# NODE_NAME_TEMPLATE, APP_SUBPATH, CUSTOM_LOG_SUBPATH e i tre *_LOG_BASE sono
# definiti in system.conf — niente hardcoded qui (ARCH-6, "nessun default
# implicito nel codice", consolidato 2026-08-06 rimuovendo la duplicazione
# 'undertow_access_log'/'server'/'gc' che c'era prima in questo file).
#

# Carica sistema e dominio dal profilo attivo
if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "echo '[ERROR] resolve-logs: PROFILE_DIR non impostata' >&2" >&2
    exit 1
fi
source "$PROFILE_DIR/system.conf"
source "$(dirname "${BASH_SOURCE[0]}")/utils-nodes.sh"

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

# ─── Risoluzione nodo ─────────────────────────────────────────────────────────
NODE_NUM=$(printf "%02d" "$NODE_NUM" 2>/dev/null || echo "$NODE_NUM")
# NODE_NAME_TEMPLATE è definito in system.conf (es: 'lx${ENV_CODE}jbliq${NODE_NUM}')
NODE_NAME=$(eval echo "${NODE_NAME_TEMPLATE}")
NODE_DIR="$BASE_DIR/$ENV_NAME/$NODE_NAME"

if [[ ! -d "$NODE_DIR" ]]; then
    # Fallback: scoperta dinamica tramite utils-nodes.sh (unica fonte di verità)
    NODE_DIR=$(list_env_node_dirs "$ENV_NAME" | head -1)
    if [[ -z "$NODE_DIR" ]]; then
        echo "echo '[ERROR] resolve-logs: nodo non trovato in $BASE_DIR/$ENV_NAME' >&2" >&2
        exit 1
    fi
    NODE_NUM=$(node_num_from_dir "$NODE_DIR")
fi

# ─── Risoluzione app dir (espande il template APP_SUBPATH) ───────────────────
APP_DIR="$NODE_DIR/$(eval echo "$APP_SUBPATH")"

if [[ ! -d "$APP_DIR" ]]; then
    echo "echo '[ERROR] resolve-logs: app dir non trovata: $APP_DIR' >&2" >&2
    exit 1
fi

# ─── Validazione *_LOG_BASE ────────────────────────────────────────────────────
# Nessun default implicito (ARCH-6): un profilo che non li definisce deve
# fallire qui in modo esplicito, non produrre path come "${APP_DIR}/.log"
# con basename vuoto. Stesso pattern di guard di SERVER_LOG_FORMAT in
# dispatch.sh.
for _b in ACCESS_LOG_BASE SERVER_LOG_BASE GC_LOG_BASE; do
    if [[ -z "${!_b:-}" ]]; then
        echo "echo '[ERROR] resolve-logs: $_b non impostato in system.conf' >&2" >&2
        exit 1
    fi
done

# ─── File di log ─────────────────────────────────────────────────────────────
resolve_log_file() {
    local base_path="$1"
    if   [[ -f "${base_path}" ]];    then echo "${base_path}"
    elif [[ -f "${base_path}.gz" ]]; then echo "${base_path}.gz"
    else echo ""
    fi
}

SERVER_LOG_PATH=$(resolve_log_file "$APP_DIR/${SERVER_LOG_BASE}.log")

# Access log: path del file corrente (usato solo per validazione esistenza)
ACCESS_LOG_PATH=$(resolve_log_file "$APP_DIR/${ACCESS_LOG_BASE}.log")
if [[ -z "$ACCESS_LOG_PATH" ]]; then
    # fallback: qualsiasi file undertow presente
    ACCESS_LOG_PATH=$(find "$APP_DIR" -maxdepth 1 -name "${ACCESS_LOG_BASE}*" 2>/dev/null | sort -r | head -1)
fi
if [[ -z "$ACCESS_LOG_PATH" ]]; then
    echo "echo '[ERROR] resolve-logs: nessun ${ACCESS_LOG_BASE} in $APP_DIR' >&2" >&2
    exit 1
fi

# GC log: path del file corrente (usato solo per validazione esistenza)
GC_LOG_PATH=$(resolve_log_file "$APP_DIR/${GC_LOG_BASE}.log")

# ─── Directory log applicativi custom (opzionale, vuota se CUSTOM_LOG_SUBPATH è vuoto) ─
# "Custom" = cartella flat, formato non standard JBoss (server/gc/access):
# nel profilo liquido è la cartella dei log Guidewire, ma il contratto non
# presume alcun middleware specifico (CLAUDE.md, "Principi di progettazione").
CUSTOM_LOG_DIR=""
if [[ -n "${CUSTOM_LOG_SUBPATH:-}" ]]; then
    CUSTOM_LOG_DIR="$NODE_DIR/$(eval echo "$CUSTOM_LOG_SUBPATH")"
fi

# ─── Output ──────────────────────────────────────────────────────────────────
echo "ACCESS_LOG='${ACCESS_LOG_PATH}'"
echo "ACCESS_LOG_DIR='${APP_DIR}'"
echo "ACCESS_LOG_BASE='${ACCESS_LOG_BASE}'"
echo "SERVER_LOG='${SERVER_LOG_PATH}'"
echo "SERVER_LOG_DIR='${APP_DIR}'"
echo "SERVER_LOG_BASE='${SERVER_LOG_BASE}'"
echo "GC_LOG='${GC_LOG_PATH:-}'"
echo "GC_LOG_DIR='${APP_DIR}'"
echo "GC_LOG_BASE='${GC_LOG_BASE}'"
echo "ACTIVE_NODE='${NODE_NUM}'"
echo "ACTIVE_ENV='${ENV_NAME}'"
echo "ACTIVE_APP='${APP}'"
echo "CUSTOM_LOG_DIR='${CUSTOM_LOG_DIR}'"
echo "LOG_SEARCH_ROOT='${NODE_DIR}'"
