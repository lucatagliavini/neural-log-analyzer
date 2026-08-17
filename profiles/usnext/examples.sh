#!/bin/bash
#
# examples.sh — generatori di esempi specifici del profilo "usnext".
# Sourcato da lib/gen-examples.sh DOPO le definizioni core.
#
# Ridefinire qui qualunque gen_<tool>() per personalizzare i generatori core.
#
# CORREZIONE (2026-08-17): la versione precedente dichiarava «questo profilo non
# ha log applicativi custom, quindi non definisce gen_tail_named_log()». È falso,
# verificato sul filesystem di lxprworkerlana01: accanto ai log di sistema ci sono
# Pass.log (320 file, ~40 MB per nodo), console.log (323), audit.log (36) e
# backupgc.log (29). Non stanno in una sottodirectory dedicata come i Guidewire di
# liquido — ed è per questo che CUSTOM_LOG_SUBPATH resta vuoto — ma i log
# esistono, e dopo LOGDISC-1 sono raggiungibili per nome perché la ricerca è
# ricorsiva sotto il nodo.
#
# Conseguenza pratica di quella riga sbagliata: gen-examples.sh generava esempi
# per i named log con i nomi di un altro sistema, ereditati dai template core.
#

# Log applicativi custom realmente presenti su questo sistema.
#
# NOTA sul case: "Pass.log" ha la maiuscola su disco. Qui vale la forma che
# l'utente digita, e gli esempi generati passano da normalize-query.sh (che fa
# lowercase) prima della vectorizzazione — quindi la maiuscola non incide sul
# vocabolario. La risoluzione del file su disco usa invece il case ORIGINALE,
# perché `find -name` è case-sensitive (param-extract.sh, lezione di NLOG2-6).
APP_LOGS=(
    "Pass.log"
    "console.log"
    "audit.log"
    "backupgc.log"
)

# I due generatori dei named log NON esistono nel core di gen-examples.sh
# (verificato: solo i profili li definiscono), quindi ridefinire APP_LOGS non
# basta — senza le funzioni qui sotto, `gen-examples.sh tail_named_log` su questo
# profilo risponde "[SKIP] nessun generatore". Template identici a quelli di
# liquido: cambiano solo i nomi dei log, che vengono da APP_LOGS.

gen_grep_named_log() {
    for log in "${APP_LOGS[@]}"; do
        # Tutti i template usano ${log} (con .log) per attivare gli unigram GW [60-67]
        emit "grep_named_log" "errori nel ${log}"
        emit "grep_named_log" "mostrami gli errori del ${log}"
        emit "grep_named_log" "cerca errori nel ${log}"
        emit "grep_named_log" "exception nel ${log}"
        emit "grep_named_log" "eccezioni nel ${log}"
        # Warning
        emit "grep_named_log" "warning nel ${log}"
        emit "grep_named_log" "warn nel ${log}"
        # Con finestra temporale
        emit "grep_named_log" "errori nel ${log} nell'ultima ora"
        emit "grep_named_log" "errori nel ${log} di stamattina"
        # Confine negativo vs tail_named_log: filtro esplicito
        emit "grep_named_log" "filtra gli errori nel ${log}"
        emit "grep_named_log" "cerca exception nel ${log}"
    done
}

gen_tail_named_log() {
    for log in "${APP_LOGS[@]}"; do
        # Tutti i template usano ${log} (con .log) per attivare gli unigram GW [60-67]
        emit "tail_named_log" "ultime righe del ${log}"
        emit "tail_named_log" "mostrami il ${log}"
        emit "tail_named_log" "cosa c'è nel ${log} recentemente"
        emit "tail_named_log" "tail del ${log}"
        emit "tail_named_log" "ultimi eventi nel ${log}"
        emit "tail_named_log" "dammi le ultime righe del ${log}"
        emit "tail_named_log" "cosa sta loggando il ${log}"
        emit "tail_named_log" "righe recenti del ${log}"
        # Confine negativo vs grep_named_log: visualizzazione pura
        emit "tail_named_log" "visualizza il ${log}"
        emit "tail_named_log" "apri il ${log}"
        emit "tail_named_log" "contenuto del ${log}"
    done
}
