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
#   list_env_nodes ENV_NAME
#     Come sopra ma emette la COPPIA `DIR<TAB>NUM`, cioè il nodo già appaiato al
#     suo numero canonico. È la forma che serve a chi itera sui nodi: prima ogni
#     chiamante rifaceva l'appaiamento con la propria chiamata a
#     node_num_from_dir, e due chiamanti sono già la premessa del principio 8.
#     Si legge con `while IFS=$'\t' read -r dir num`.
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

# list_env_nodes ENV_NAME  →  righe "DIR<TAB>NUM"
#
# Perché una funzione che emette COPPIE e non una che accetta una callback:
# i chiamanti accumulano in array del PROPRIO scope (search_all_logs.sh riempie
# all_labels/all_paths/all_nodes/all_apps dentro il ciclo). Con `while … < <(qui)`
# il produttore gira in subshell ma il CORPO del ciclo resta nella shell
# chiamante, quindi gli array si popolano; una callback invocata dall'interno
# della funzione girerebbe nello scope sbagliato e gli append andrebbero perduti
# in silenzio — il tipo di regressione che una centralizzazione non deve
# introdurre proprio mentre riduce la duplicazione.
#
# Il TAB come separatore e non lo spazio: i path possono contenere spazi.
#
# L'ORDINE DEI CAMPI NON È ARBITRARIO, ed è un difetto trovato dal test la prima
# volta che è girato. La forma naturale `NUM<TAB>DIR` è SBAGLIATA: il TAB è un
# carattere di IFS *whitespace*, quindi bash collassa le sequenze e SCARTA i
# separatori iniziali. Su una riga `\t/path/del/nodo` — cioè un nodo il cui nome
# non espone un numero — la lettura `IFS=$'\t' read -r num dir` non assegna
# num="" e dir=/path: scarta il TAB iniziale, mette il PATH in `num` e lascia
# `dir` VUOTO. Il chiamante, che salta le righe con dir vuoto, avrebbe ignorato
# quel nodo in silenzio: il falso negativo che il paragrafo qui sotto dichiara di
# evitare, introdotto dalla riga che doveva evitarlo.
#
# Con DIR per primo un NUM vuoto è un campo FINALE mancante, che `read` gestisce
# correttamente, e il campo che può contenere spazi sta in prima posizione, dove
# arriva integro. Resta l'esposizione teorica a un path che contenga un TAB: è la
# stessa che il progetto già accetta ovunque legga l'output di `find` riga per
# riga (list_env_node_dirs compreso), e non è uno scenario reale per una
# directory di log.
#
# Un nodo la cui directory non espone un numero riconoscibile viene EMESSO
# comunque, con NUM vuoto: escluderlo qui significherebbe far sparire i suoi log
# dai risultati senza dirlo (principio 5, e la classe di difetto di NODE-1). Chi
# consuma decide come etichettarlo.
list_env_nodes() {
    local env_name="$1"
    local _d _n
    while IFS= read -r _d; do
        [[ -z "$_d" ]] && continue
        _n=$(node_num_from_dir "$_d")
        printf '%s\t%s\n' "$_d" "$_n"
    done < <(list_env_node_dirs "$env_name")
}

