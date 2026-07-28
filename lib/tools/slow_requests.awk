# Richieste con tempo di risposta sopra soglia dall'access log Undertow.
# Parametri: -v threshold_ms="1000"
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato campi: IP [datetime] "METHOD URL PROTO" STATUS BYTES TIME_MS CHAIN UA

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 1000
    count = 0; buf_n = 0; max_rows = 30
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
    total_time += resp_time
    if (resp_time > max_time) { max_time = resp_time; max_url = url }

    # Top-K buffer (ascending su buf_time — buf_time[1] è il minimo corrente)
    if (buf_n < max_rows) {
        # Buffer non pieno: inserimento in posizione (insertion sort ascending)
        buf_n++
        pos = buf_n
        while (pos > 1 && buf_time[pos-1] > resp_time) {
            buf_time[pos]   = buf_time[pos-1]
            buf_status[pos] = buf_status[pos-1]
            buf_method[pos] = buf_method[pos-1]
            buf_url[pos]    = buf_url[pos-1]
            pos--
        }
        buf_time[pos] = resp_time; buf_status[pos] = status
        buf_method[pos] = method;  buf_url[pos]    = url
    } else if (resp_time > buf_time[1]) {
        # Buffer pieno: sostituisce il minimo e reinserisce in posizione
        pos = 1
        while (pos < buf_n && buf_time[pos+1] < resp_time) {
            buf_time[pos]   = buf_time[pos+1]
            buf_status[pos] = buf_status[pos+1]
            buf_method[pos] = buf_method[pos+1]
            buf_url[pos]    = buf_url[pos+1]
            pos++
        }
        buf_time[pos] = resp_time; buf_status[pos] = status
        buf_method[pos] = method;  buf_url[pos]    = url
    }
}

END {
    if (count == 0) {
        printf "Nessuna richiesta lenta sopra %d ms trovata.\n", threshold_ms
        exit
    }

    # Buffer è ascending: stampiamo dal fondo (più lento prima)
    col_url = length("URL")
    for (i = buf_n; i >= 1; i--)
        if (length(buf_url[i]) > col_url) col_url = length(buf_url[i])

    sep = ""
    for (k = 1; k <= col_url; k++) sep = sep "─"

    printf "%-8s  %-6s  %-*s  %s\n", "STATUS", "METHOD", col_url, "URL", "TEMPO"
    printf "%-8s  %-6s  %-*s  %s\n", "────────", "──────", col_url, sep, "──────"

    for (i = buf_n; i >= 1; i--) {
        color = (substr(buf_status[i],1,1) == "5") ? RED : YELLOW
        printf "%s%-8s%s  %-6s  %-*s  %d ms\n", \
            color, buf_status[i], RESET, buf_method[i], col_url, buf_url[i], buf_time[i]
    }

    if (count > max_rows) printf "... (mostrate le %d più lente di %d)\n", max_rows, count
    printf "\nTotale richieste lente: %d (soglia: %d ms)\n", count, threshold_ms
    printf "Risposta più lenta: %d ms → %s\n", max_time, max_url
    printf "Latenza media (lente): %.0f ms\n", total_time / count
}
