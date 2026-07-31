#!/bin/bash
#
# utils-nodes.sh — scoperta dinamica dei nodi per ambiente dal filesystem.
#
# Richiede che siano già definite (via system.conf):
#   LOG_BASE_DIR, NODE_NAME_TEMPLATE, ENV_NODE_CODE, APP_SUBPATH
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
#   list_env_app_dirs ENV_NAME APP
#     Stampa (una per riga) i path APP_DIR validi (NODE_DIR + APP_SUBPATH)
#     per tutti i nodi trovati. Un nodo è incluso solo se la sua APP_DIR esiste.
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

# list_env_app_dirs ENV_NAME APP
list_env_app_dirs() {
    local env_name="$1"
    local app="${2:-${DEFAULT_APP:-}}"

    while IFS= read -r node_dir; do
        local app_dir="${node_dir}/$(eval echo "$APP_SUBPATH")"
        [[ -d "$app_dir" ]] && echo "$app_dir"
    done < <(list_env_node_dirs "$env_name")
}
