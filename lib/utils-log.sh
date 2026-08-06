#!/bin/bash
#
# utils-log.sh — logging DEBUG configurabile per le fasi non visibili
# all'utente (selezione file, decisioni di pruning). Principio di progetto
# (CLAUDE.md, "Principi di progettazione"): mai su stdout, che è l'output
# formattato dei tool e la superficie su cui asseriscono i test.
#
# Configurazione (system.conf):
#   BOT_LOG_LEVEL  debug|info|warn|error|off (default: warn)
#   BOT_LOG_FILE   path del file di log (vuoto = stderr)
#
# Uso: log_debug "messaggio"   log_info/log_warn/log_error allo stesso modo.
# Sopra la soglia di BOT_LOG_LEVEL la funzione ritorna subito (un confronto
# intero, nessuna subshell) — conta perché può essere chiamata per ogni file
# in un ciclo di selezione.

declare -A _LOG_LEVEL_NUM=([debug]=0 [info]=1 [warn]=2 [error]=3 [off]=4)

_log_write() {
    local level="$1" num="$2" msg="$3"
    # Letto ad ogni chiamata (non cachato al source): BOT_LOG_LEVEL può
    # essere impostato dopo che questo file è stato sourcato (es. come
    # prefisso di comando in un test).
    local threshold="${_LOG_LEVEL_NUM[${BOT_LOG_LEVEL:-warn}]:-2}"
    [[ "$num" -lt "$threshold" ]] && return
    local line
    line="$(date '+%Y-%m-%dT%H:%M:%S') ${level^^} [${BOT_LOG_COMPONENT:-nla}] ${msg}"
    if [[ -n "${BOT_LOG_FILE:-}" ]]; then
        echo "$line" >> "$BOT_LOG_FILE" 2>/dev/null
    else
        echo "$line" >&2
    fi
}

log_debug() { _log_write debug 0 "$1"; }
log_info()  { _log_write info  1 "$1"; }
log_warn()  { _log_write warn  2 "$1"; }
log_error() { _log_write error 3 "$1"; }
