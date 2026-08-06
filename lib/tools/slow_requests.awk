# Richieste con tempo di risposta sopra soglia dall'access log Undertow.
# Parametri: -v threshold_ms="1000"
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato campi: IP [datetime] "METHOD URL PROTO" STATUS BYTES TIME_MS CHAIN UA

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 1000
    count = 0; buf_n = 0; max_rows = 30
}

{
    line = $0

    # Ordine dei filtri: prima la soglia sul tempo di risposta (una regex e un
    # confronto), poi il filtro temporale — che chiama parse_access() e quindi
    # mktime(), molto più costoso. La soglia è fortemente selettiva: su dati
    # reali di produzione solo l'8.1% delle righe supera i 1000ms, quindi
    # invertendo si evita mktime sul 92% delle righe.
    # Misurato su snapshot statico, 5 round interlacciati: mediana 3.55s →
    # 2.81s (-21%), vince 4 round su 5 (2026-08-06).
    # L'inversione è sicura perché questo tool conta SOLO le richieste lente:
    # non ha un contatore su tutte le righe in range, a differenza di
    # count_status, dove all_total serve come denominatore nel summary e
    # obbliga a filtrare per tempo su ogni riga.
    if (!match(line, /" [0-9]+ [0-9-]+ ([0-9]+) /, a)) next
    resp_time = a[1] + 0

    if (resp_time < threshold_ms + 0) next

    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next

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
        method_color = (buf_method[i] == "GET") ? GREEN : (buf_method[i] == "POST") ? CYAN : ""
        printf "%s%-8s%s  %s%-6s%s  %-*s  %s%d ms%s\n", \
            color, buf_status[i], RESET, method_color, buf_method[i], RESET, col_url, buf_url[i], WHT, buf_time[i], RESET
    }

    if (count > max_rows) printf "... (mostrate le %d più lente di %d)\n", max_rows, count
    printf "\nTotale richieste lente: %s%d%s (soglia: %s%d ms%s)\n", WHT, count, RESET, WHT, threshold_ms, RESET
    printf "Risposta più lenta: %s%d ms%s → %s\n", WHT, max_time, RESET, max_url
    printf "Latenza media (lente): %s%.0f ms%s\n", WHT, total_time / count, RESET
}
