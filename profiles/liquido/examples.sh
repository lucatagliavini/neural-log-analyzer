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
        local lname="${log%.log}"
        # Errori ERROR (default e più comune)
        emit "grep_named_log" "errori nel ${log}"
        emit "grep_named_log" "mostrami gli errori del ${lname}"
        emit "grep_named_log" "cerca errori nel ${log}"
        emit "grep_named_log" "exception nel ${log}"
        emit "grep_named_log" "eccezioni nel ${lname} log"
        # Warning
        emit "grep_named_log" "warning nel ${log}"
        emit "grep_named_log" "warn del ${lname}"
        # Con finestra temporale
        emit "grep_named_log" "errori nel ${log} nell'ultima ora"
        emit "grep_named_log" "errori nel ${log} di stamattina"
    done
}

gen_tail_named_log() {
    for log in "${GW_LOGS[@]}"; do
        local lname="${log%.log}"
        emit "tail_named_log" "ultime righe del ${log}"
        emit "tail_named_log" "mostrami il ${log}"
        emit "tail_named_log" "cosa c'è nel ${log} recentemente"
        emit "tail_named_log" "tail del ${lname} log"
        emit "tail_named_log" "ultimi eventi nel ${log}"
        emit "tail_named_log" "dammi le ultime righe del ${log}"
        emit "tail_named_log" "cosa sta loggando il ${log}"
        emit "tail_named_log" "righe recenti del ${lname}"
    done
}
