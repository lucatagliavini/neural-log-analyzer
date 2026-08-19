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
# I ruoli semantici (un tema li rende come vuole, la semantica non cambia):
#   C_CRIT    la cosa È grave per definizione — 5xx, ERROR, exception
#   C_WARN    POTREBBE essere un problema — 4xx, WARN, oltre soglia
#   C_OK      esito positivo confermato — 2xx, "GC non è la causa"
#   C_INFO    livello NEUTRO di una scala — status 3xx: né ok né errore
#   C_VAL     valore numerico su cui deve cadere l'occhio — conteggi, medie
#   C_LBL     etichetta di contorno, non il dato — header, unità, note
#   C_ACCENT  riferimento a un'entità — nome di log, path
#   C_TAG     codifica per CATEGORIA, non gravità — metodo HTTP, contatori
#   C_ROW_ALT sfondo per righe alternate — raggruppamento per nodo
#   C_ROW_ALT_FG colore del TESTO quando c'è lo sfondo alternato
#   C_BAR_1..C_BAR_5  gradiente per le barre: 1 = valore basso, 5 = alto
#   C_PARTIAL un valore non è il dato completo che sembra — timestamp
#             solo-ora di search_all_logs (nessuna data nel file, UI-12)
#
# Le barre rappresentano una QUANTITÀ, non un giudizio: 400 occorrenze possono
# essere gravi o normali secondo il contesto. Per questo usano un gradiente di
# intensità dello stesso colore (scala sequenziale) e non rosso/giallo/verde,
# che è una scala divergente — adatta a "sotto/nella norma/sopra" attorno a un
# valore atteso, che per un conteggio non esiste. Così la barra dice "quanto" e
# il colore dello status dice "quanto grave", senza competere per lo stesso
# significato.
# La TONALITÀ è scelta dal tema, perché deve accordarsi con la sua palette
# (richiesta dell'utente, 2026-08-06): rossi nei temi caldi, blu in quelli
# freddi, grigi in high-contrast.
#
# Perché C_ROW_ALT_FG è un ruolo a sé: `C_LBL` è dim, e dim su uno sfondo
# colorato avvicina il testo al fondo — per costruzione, non per scelta di
# palette. Senza questo ruolo un tema non può garantire il contrasto sulla
# propria riga colorata, perché non sa cosa il tool ci scriverà sopra
# (segnalato dall'utente sul tema dark, 2026-08-06; lo stesso problema era già
# stato aggirato il 2026-08-05 sostituendo DIM con lo sfondo pieno).
#
# C_INFO e C_TAG sono opzionali nei .conf: se assenti ricadono su C_ACCENT (il
# comportamento pre-UI-12). Un tema li differenzia quando vuole evitare che una
# categoria (POST) si confonda con una severità — es. dark-warm, che usa il
# giallo come accento.
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

    # Azzera prima di caricare: senza questo un tema EREDITA i ruoli che non
    # definisce dal tema caricato in precedenza. Nel bot non si vedrebbe (un solo
    # theme_load per esecuzione), ma theme-preview.sh ne carica nove in sequenza
    # e mostrerebbe colori che il tema non ha — e un test potrebbe passare per la
    # ragione sbagliata. Bug trovato migrando i tool a C_INFO/C_TAG (UI-12).
    unset C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_INFO C_TAG C_ROW_ALT C_ROW_ALT_FG C_BOLD C_RESET
    unset C_BAR_1 C_BAR_2 C_BAR_3 C_BAR_4 C_BAR_5
    unset C_PARTIAL

    if [[ -f "$f" ]]; then
        # shellcheck source=/dev/null
        source "$f"
    fi

    # Rete di sicurezza: un tema incompleto non deve lasciare variabili non
    # definite (con `set -u` in chatbot.sh sarebbe un errore fatale a runtime,
    # nel punto più lontano possibile dalla causa).
    : "${C_CRIT:=}" "${C_WARN:=}" "${C_OK:=}" "${C_VAL:=}"
    : "${C_LBL:=}" "${C_ACCENT:=}" "${C_ROW_ALT:=}" "${C_BOLD:=}" "${C_RESET:=}"
    # C_INFO (livello neutro di una scala) e C_TAG (categoria, non gravità):
    # default su C_ACCENT, così i temi che non li definiscono si comportano come
    # prima di UI-12.
    : "${C_INFO:=$C_ACCENT}" "${C_TAG:=$C_ACCENT}"
    # C_ROW_ALT_FG: se il tema non lo definisce, resta vuoto — cioè il testo
    # mantiene i colori che il tool userebbe comunque (comportamento
    # pre-2026-08-06). Un tema con sfondo alternato dovrebbe definirlo.
    : "${C_ROW_ALT_FG:=}"
    # Gradiente barre: se il tema non lo definisce, tutti i livelli restano
    # vuoti — la barra esce nel colore di default, come prima del 2026-08-06.
    : "${C_BAR_1:=}" "${C_BAR_2:=}" "${C_BAR_3:=}" "${C_BAR_4:=}" "${C_BAR_5:=}"
    # C_PARTIAL: default su C_LBL (dim), stesso trattamento opzionale di
    # C_INFO/C_TAG — un tema che non lo definisce marca il dato parziale come
    # un'etichetta di contorno piuttosto che introdurre un colore nuovo.
    : "${C_PARTIAL:=$C_LBL}"

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
    for _v in C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_INFO C_TAG C_ROW_ALT C_ROW_ALT_FG C_BOLD C_RESET \
              C_BAR_1 C_BAR_2 C_BAR_3 C_BAR_4 C_BAR_5 C_PARTIAL; do
        printf -v "$_v" '%b' "${!_v}"
    done

    BOT_THEME_ACTIVE="$name"
    export C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_INFO C_TAG C_ROW_ALT C_ROW_ALT_FG C_BOLD C_RESET
    export C_BAR_1 C_BAR_2 C_BAR_3 C_BAR_4 C_BAR_5 C_PARTIAL
    export BOT_THEME_ACTIVE
}

# theme_awk_args — stampa i `-v` con cui passare il tema a gawk.
# I tool AWK non leggono il file .conf: riceverebbero due fonti di verità e
# potrebbero divergere dal lato bash. Qui la palette è già risolta.
theme_awk_args() {
    printf -- "-v C_CRIT='%s' -v C_WARN='%s' -v C_OK='%s' -v C_VAL='%s' -v C_LBL='%s' -v C_ACCENT='%s' -v C_INFO='%s' -v C_TAG='%s' -v C_ROW_ALT='%s' -v C_ROW_ALT_FG='%s' -v C_BOLD='%s' -v C_RESET='%s' -v C_BAR_1='%s' -v C_BAR_2='%s' -v C_BAR_3='%s' -v C_BAR_4='%s' -v C_BAR_5='%s'" \
        "$C_CRIT" "$C_WARN" "$C_OK" "$C_VAL" "$C_LBL" "$C_ACCENT" "$C_INFO" "$C_TAG" "$C_ROW_ALT" "$C_ROW_ALT_FG" "$C_BOLD" "$C_RESET" \
        "$C_BAR_1" "$C_BAR_2" "$C_BAR_3" "$C_BAR_4" "$C_BAR_5"
}
