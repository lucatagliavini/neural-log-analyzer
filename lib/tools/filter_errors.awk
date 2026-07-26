# Filtra righe ERROR e WARN dal server.log JBoss.
# Parametri: -v time_window="2h|30m|"
#
# Formato: YYYY-MM-DD HH:MM:SS,mmm LEVEL [classe] (thread) messaggio

BEGIN { FS = " "; max_rows = 50; count = 0 }

/ERROR|WARN/ {
    level = $3
    if (level != "ERROR" && level != "WARN") next

    # Classe logger: campo 4 tra parentesi quadre
    logger = $4
    gsub(/[\[\]]/, "", logger)

    # Thread: campo 5 tra parentesi tonde
    thread = $5
    gsub(/[()]/, "", thread)

    # Messaggio: tutto il resto
    msg = ""
    for (i = 6; i <= NF; i++) msg = msg " " $i
    sub(/^ /, "", msg)

    count++
    if (count <= max_rows) {
        printf "[%s] %-8s %-40s\n", $1 " " $2, level, substr(msg, 1, 80)
        printf "        Classe: %s | Thread: %s\n\n", logger, thread
    }
    if (level == "ERROR") nerror++
    else nwarn++
}

END {
    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
    } else {
        if (count > max_rows) printf "... (mostrate %d di %d)\n", max_rows, count
        printf "Totale: %d ERROR, %d WARN\n", nerror+0, nwarn+0
    }
}
