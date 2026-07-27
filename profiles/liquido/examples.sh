#!/bin/bash
#
# examples.sh — generatori di esempi specifici del profilo "liquido".
# Sourcato da lib/gen-examples.sh DOPO le definizioni core.
#
# Definisce gen_tail_named_log() che usa i log Guidewire di questo sistema.
# Ridefinire qui qualunque gen_<tool>() per personalizzare gli esempi.
#

# Log Guidewire presenti su questo sistema (vedi system.conf GUIDEWIRE_SUBPATH)
GW_LOGS=(
    "cc.log"
    "api.log"
    "database.log"
    "messaging.log"
    "performance_integr.log"
    "jgroups.log"
)

gen_grep_named_log() {
    for log in "${GW_LOGS[@]}"; do
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
    for log in "${GW_LOGS[@]}"; do
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
