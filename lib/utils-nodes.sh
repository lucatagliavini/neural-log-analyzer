#!/bin/bash
#
# utils-nodes.sh — scoperta dinamica dei nodi per ambiente dal filesystem.
#
# Richiede che siano già definite (via system.conf):
#   LOG_BASE_DIR, NODE_NAME_TEMPLATE, ENV_NODE_CODE
#
# Funzioni esportate:
#   node_num_canonical VALUE
#     Canonicalizza un numero di nodo alla forma a due cifre dei nomi directory.
#     Es: "9" → "09", "09" → "09", "12" → "12". Unico punto di verità.
#
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

# node_num_canonical VALUE
# Numero di nodo → forma a due cifre usata nei nomi directory ("9" → "09").
# Ritorna 1 senza stampare nulla se VALUE non è un numero: il chiamante decide
# cosa fare, invece di ricevere un valore inventato.
#
# `10#` NON è ornamentale (bug trovato in produzione il 2026-08-27): il printf di
# bash converte `%d` con semantica base 0, quindi lo zero iniziale significa
# OTTALE e 8/9 non sono cifre valide. `printf "%02d" 09` scrive "00" su stdout,
# *poi* esce con stato 1 — e la forma `$(printf … || echo "$v")` che stava in
# resolve-logs.sh non sostituiva il valore, lo APPENDEVA all'output parziale:
# "00" + "09" = "0009". Da lì NODE_NAME=lxprjbliq0009, directory inesistente,
# fallback sul primo nodo dell'ambiente. Affetti i soli nodi 08 e 09 — unici a
# due cifre con zero iniziale e cifra non ottale — che rispondevano in silenzio
# coi dati del nodo 01.
#
# Perché la funzione esiste: la stessa logica viveva in QUATTRO copie (qui,
# chatbot.sh ×2, resolve-logs.sh) e solo due usavano `10#`. È il principio 8 di
# CLAUDE.md — assunzioni parallele sullo stesso formato, una corretta e le altre
# rimaste indietro, tanto più difficili da notare perché "sembra" già risolto
# altrove. Nuovi chiamanti usano questa, non una quinta copia.
node_num_canonical() {
    local _n="${1//[[:space:]]/}"
    [[ "$_n" =~ ^[0-9]+$ ]] || return 1
    printf "%02d" "$((10#$_n))"
}

# node_num_from_dir DIR
node_num_from_dir() {
    local _n; _n=$(basename "$1" | grep -oE "[0-9]+$")
    node_num_canonical "$_n" || echo ""
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

