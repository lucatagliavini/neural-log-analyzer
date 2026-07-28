# Filtra righe ERROR e WARN dal server.log JBoss.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato: YYYY-MM-DD HH:MM:SS,mmm LEVEL [classe] (thread) messaggio

BEGIN {
    FS = " "; max_rows = 50; count = 0
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
    DIM = "\033[2m"
}

/ERROR|WARN/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    level = $3
    if (level != "ERROR" && level != "WARN") next

    logger = $4; gsub(/[\[\]]/, "", logger)
    thread = $5; gsub(/[()]/, "", thread)

    msg = ""
    for (i = 6; i <= NF; i++) msg = msg " " $i
    sub(/^ /, "", msg)

    count++
    if (level == "ERROR") nerror++
    else nwarn++

    if (count <= max_rows) {
        color = (level == "ERROR") ? RED : YELLOW
        printf "%s[%s %s] %-5s%s  %s\n", color, $1, $2, level, RESET, substr(msg, 1, 100)
        printf "  %s%s | %s%s\n\n", DIM, logger, thread, RESET
    }
}

END {
    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
    } else {
        if (count > max_rows) printf "... (mostrate %d di %d)\n", max_rows, count
        printf "Totale: %s%d ERROR%s, %s%d WARN%s\n", \
            RED, nerror+0, RESET, YELLOW, nwarn+0, RESET
    }
}
