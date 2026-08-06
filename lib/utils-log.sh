#!/bin/bash
#
# utils-log.sh — logging DEBUG configurabile e feedback progressivo per le
# fasi non visibili all'utente (selezione file, decisioni di pruning).
# Principio di progetto (CLAUDE.md, "Principi di progettazione"): mai su
# stdout, che è l'output formattato dei tool e la superficie su cui
# asseriscono i test.
#
# Due canali distinti, entrambi su stderr:
#   log_debug/info/warn/error   tracciamento diagnostico, persistente
#   progress_show/progress_clear  feedback all'utente, transiente (in-place)
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

# ─── Decompressore per i log .gz ──────────────────────────────────────────────
# Unica fonte di verità (principio 2): usato da open_log() in dispatch.sh — e
# quindi da tutti i tool — da search_all_logs.sh e da utils-logfiles.sh.
#
# `pigz -dc` sposta CRC e scrittura su thread separati dal decoder e legge in
# readahead: misurato in produzione (2026-08-06) 3-4× più veloce di gunzip
# sullo stesso file (0.09-0.17s vs 0.32-0.38s per 2.1MB → 60MB). Conta perché
# sui .gz la decompressione è ~90% del costo totale della ricerca.
# NON parallelizza la decodifica dello stream: quella è sequenziale per
# costruzione del formato gzip (ogni blocco dipende dal dizionario
# precedente), quindi `-p` alto non aggiunge nulla.
#
# Fallback su gunzip: pigz è drop-in compatible in lettura, l'output è
# identico byte per byte, quindi la sostituzione è sicura in entrambi i versi.
if command -v pigz >/dev/null 2>&1; then
    GZ_CAT="pigz -dc"
else
    GZ_CAT="gunzip -c"
fi

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

# ─── Feedback progressivo (principio 4 di CLAUDE.md) ──────────────────────────
# Sovrascrive in place la stessa riga; progress_clear() la rimuove a fine fase,
# così non resta nulla a schermo. Solo su stderr e solo se stderr è un TTY:
# sotto `$(...)` (modalità --query, tutti i test) stderr non è un terminale,
# quindi resta silenzioso senza bisogno di un flag dedicato.
#
# Il prefisso "⋯ " è OBBLIGATORIO: le asserzioni dei test leggono la prima
# colonna dell'output con pattern tipo `grep -E '^\s*server\.log'` — una riga
# di progresso che inizia a colonna 0 con un nome di log nudo le romperebbe
# (verificato: un'assert leggeva 99 invece di 2).
#
# Disattivabile con BOT_PROGRESS=off, per i casi in cui un tool interattivo
# scrive esso stesso su stderr e non vuole interferenze.
progress_show() {
    [[ -t 2 ]] || return
    [[ "${BOT_PROGRESS:-on}" == "off" ]] && return
    printf "\r\033[K  \033[2m⋯ %s\033[0m" "$1" >&2
}
progress_clear() {
    [[ -t 2 ]] || return
    [[ "${BOT_PROGRESS:-on}" == "off" ]] && return
    printf "\r\033[K" >&2
}
