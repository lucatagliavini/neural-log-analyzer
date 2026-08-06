#!/bin/bash
#
# utils-theme.sh — caricamento del tema colore, unica fonte di verità per bash
# e per awk.
#
# Il problema che risolve: prima i colori vivevano in due mondi separati — 13
# file lib/tools/*.awk con le costanti di utils-colors.awk, e 6 file bash con
# codici ANSI hardcoded inline. Un tema che coprisse solo gli .awk avrebbe
# lasciato invariata metà dell'output (cornice, tabelle, avvisi, progresso).
#
# Uso:
#   source lib/utils-theme.sh
#   theme_load "$BOT_THEME"        # popola le variabili C_*
#   theme_awk_args                 # stampa i -v da passare a gawk
#
# Selezione del tema, in ordine di precedenza:
#   1. --theme <nome> sulla riga di comando (chatbot.sh)
#   2. BOT_THEME nell'ambiente
#   3. BOT_THEME in system.local.conf / system.conf
#   4. default: "mono" (nessun colore)
#
# Perché il DEFAULT è mono e non dark: il bot è usato anche da servizi che
# vogliono output testuale, e con redirect su file (`... > out.txt`) le
# sequenze ANSI sporcano il contenuto. Chi lavora in interattivo sceglie il
# proprio tema una volta in system.local.conf o con --theme.
#
# I 7 ruoli semantici (un tema li rende come vuole, la semantica non cambia):
#   C_CRIT    la cosa È grave per definizione — 5xx, ERROR, exception
#   C_WARN    POTREBBE essere un problema — 4xx, WARN, oltre soglia
#   C_OK      esito positivo confermato — 2xx, "GC non è la causa"
#   C_VAL     valore numerico su cui deve cadere l'occhio — conteggi, medie
#   C_LBL     etichetta di contorno, non il dato — header, unità, note
#   C_ACCENT  riferimento a un'entità — nome di log, path, metodo HTTP
#   C_ROW_ALT sfondo per righe alternate — raggruppamento per nodo
# Più C_BOLD e C_RESET, che ogni tema definisce (mono compreso: la gerarchia
# resta leggibile anche senza colori).

THEME_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../themes" 2>/dev/null && pwd)"

# theme_list — nomi dei temi disponibili, uno per riga
theme_list() {
    local d="${THEME_DIR:-$THEME_DIR_DEFAULT}"
    [[ -d "$d" ]] || return
    local f
    for f in "$d"/*.conf; do
        [[ -f "$f" ]] || continue
        basename "$f" .conf
    done
}

# theme_load [NOME] — popola le variabili C_* del tema richiesto.
# Fallback su "mono" con avviso su stderr se il nome non esiste: un typo non
# deve produrre un output senza colori senza spiegazione, né interrompere il
# lavoro.
theme_load() {
    local name="${1:-mono}"
    local d="${THEME_DIR:-$THEME_DIR_DEFAULT}"
    local f="$d/${name}.conf"

    if [[ ! -f "$f" ]]; then
        printf "\033[33m⚠ Tema '%s' non trovato in %s — uso 'mono'.\033[0m\n" \
            "$name" "$d" >&2
        printf "  Temi disponibili: %s\n" "$(theme_list | tr '\n' ' ')" >&2
        name="mono"
        f="$d/mono.conf"
    fi

    if [[ -f "$f" ]]; then
        # shellcheck source=/dev/null
        source "$f"
    fi

    # Rete di sicurezza: un tema incompleto non deve lasciare variabili non
    # definite (con `set -u` in chatbot.sh sarebbe un errore fatale a runtime,
    # nel punto più lontano possibile dalla causa).
    : "${C_CRIT:=}" "${C_WARN:=}" "${C_OK:=}" "${C_VAL:=}"
    : "${C_LBL:=}" "${C_ACCENT:=}" "${C_ROW_ALT:=}" "${C_BOLD:=}" "${C_RESET:=}"

    # I .conf scrivono le sequenze come "\033[31m" — leggibili e diffabili.
    # Qui vengono convertite nel carattere ESC reale, una volta sola.
    #
    # Perché serve: bash `printf` interpreta `\033` solo nel FORMATO, non negli
    # argomenti `%s`. Il codice del bot usa le variabili dentro il formato
    # (`printf "${C_WARN}[SKIP] %s${C_RESET}\n" "$msg"`) e funzionerebbe
    # comunque, ma chi le passa come argomento — es. theme-preview.sh, o un
    # futuro `printf '%s%s%s' "$C_CRIT" "$v" "$C_RESET"` — stamperebbe la
    # stringa letterale `\033[31m`. Convertire qui rende le variabili corrette
    # in entrambi gli usi, invece di lasciare una trappola a chi le userà.
    local _v
    for _v in C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_ROW_ALT C_BOLD C_RESET; do
        printf -v "$_v" '%b' "${!_v}"
    done

    BOT_THEME_ACTIVE="$name"
    export C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_ROW_ALT C_BOLD C_RESET
    export BOT_THEME_ACTIVE
}

# theme_awk_args — stampa i `-v` con cui passare il tema a gawk.
# I tool AWK non leggono il file .conf: riceverebbero due fonti di verità e
# potrebbero divergere dal lato bash. Qui la palette è già risolta.
theme_awk_args() {
    printf -- "-v C_CRIT='%s' -v C_WARN='%s' -v C_OK='%s' -v C_VAL='%s' -v C_LBL='%s' -v C_ACCENT='%s' -v C_ROW_ALT='%s' -v C_BOLD='%s' -v C_RESET='%s'" \
        "$C_CRIT" "$C_WARN" "$C_OK" "$C_VAL" "$C_LBL" "$C_ACCENT" "$C_ROW_ALT" "$C_BOLD" "$C_RESET"
}
