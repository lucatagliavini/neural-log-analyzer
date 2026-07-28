# Richieste con tempo di risposta sopra soglia dall'access log Undertow.
# Parametri: -v threshold_ms="1000"
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato campi: IP [datetime] "METHOD URL PROTO" STATUS BYTES TIME_MS CHAIN UA

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 1000
    count = 0; max_rows = 30
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
}

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    line = $0

    if (!match(line, /" [0-9]+ [0-9]+ ([0-9]+) /, a)) next
    resp_time = a[1] + 0

    if (resp_time < threshold_ms + 0) next

    if (!match(line, /"([A-Z]+) ([^ ]+) HTTP[^"]*"/, b)) next
    method = b[1]; url = b[2]

    if (!match(line, /" ([0-9]{3}) /, c)) next
    status = c[1]

    count++
    if (count <= max_rows) {
        buf_status[count] = status
        buf_method[count] = method
        buf_url[count]    = url
        buf_time[count]   = resp_time
    }
    total_time += resp_time
    if (resp_time > max_time) { max_time = resp_time; max_url = url }
}

END {
    if (count == 0) {
        printf "Nessuna richiesta lenta sopra %d ms trovata.\n", threshold_ms
        exit
    }

    # Larghezza massima URL tra le righe bufferizzate
    shown = (count < max_rows) ? count : max_rows
    col_url = length("URL")
    for (i = 1; i <= shown; i++)
        if (length(buf_url[i]) > col_url) col_url = length(buf_url[i])

    sep = ""
    for (k = 1; k <= col_url; k++) sep = sep "─"

    printf "%-8s  %-6s  %-*s  %s\n", "STATUS", "METHOD", col_url, "URL", "TEMPO"
    printf "%-8s  %-6s  %-*s  %s\n", "────────", "──────", col_url, sep, "──────"

    for (i = 1; i <= shown; i++) {
        color = (substr(buf_status[i],1,1) == "5") ? RED : YELLOW
        printf "%s%-8s%s  %-6s  %-*s  %d ms\n", \
            color, buf_status[i], RESET, buf_method[i], col_url, buf_url[i], buf_time[i]
    }

    if (count > max_rows) printf "... (mostrate %d di %d)\n", max_rows, count
    printf "\nTotale richieste lente: %d (soglia: %d ms)\n", count, threshold_ms
    printf "Risposta più lenta: %d ms → %s\n", max_time, max_url
    printf "Latenza media (lente): %.0f ms\n", total_time / count
}
