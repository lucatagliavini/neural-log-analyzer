#!/bin/bash
#
# utils-nodes.sh — scoperta dinamica dei nodi per ambiente dal filesystem.
#
# Richiede che siano già definite (via system.conf):
#   LOG_BASE_DIR, NODE_NAME_TEMPLATE, ENV_NODE_CODE
#
# Funzioni esportate:
#   node_num_from_dir DIR
#     Estrae il numero nodo (zero-padded) dal basename di una directory nodo.
#     Es: /logs/prod/lxprjbliq05 → "05"
#
#   list_env_node_dirs ENV_NAME
#     Stampa (una per riga) i path NODE_DIR di tutti i nodi presenti su disco
#     per l'ambiente dato. Non emette nulla se l'ambiente è sconosciuto.
#
# Il contratto si ferma alla directory del NODO (principio 6): non esiste più una
# funzione che costruisca il path dell'app da un template. `list_env_app_dirs`,
# che lo faceva con APP_SUBPATH, è stata rimossa con CLEAN-1 (2026-08-17) — aveva
# zero chiamanti ed era l'ultimo consumatore reale di quella variabile. Chi deve
# raggiungere i log sotto un nodo usa la scoperta: `resolve_system_log_dir` per
# access/server/gc, `resolve_log_glob` per i named log, `discover_log_dirs` per
# enumerare le directory con log.
#

# node_num_from_dir DIR
node_num_from_dir() {
    local _n; _n=$(basename "$1" | grep -oE "[0-9]+$")
    [[ -z "$_n" ]] && echo "" || printf "%02d" "$((10#$_n))"
}

# _node_prefix ENV_CODE
# Ricava il prefisso del nome nodo espandendo il template con NODE_NUM="".
# Es: 'lx${ENV_CODE}jbliq${NODE_NUM}' + ENV_CODE=pr → "lxprjbliq"
_node_prefix_for() {
    local ENV_CODE="$1" NODE_NUM=""
    eval echo "${NODE_NAME_TEMPLATE}"
}

# list_env_node_dirs ENV_NAME
list_env_node_dirs() {
    local env_name="$1"
    local env_code="${ENV_NODE_CODE[$env_name]:-}"
    [[ -z "$env_code" ]] && return

    local env_base="${LOG_BASE_DIR}/${env_name}"
    [[ ! -d "$env_base" ]] && return

    local prefix; prefix=$(_node_prefix_for "$env_code")
    find "$env_base" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null | sort
}

