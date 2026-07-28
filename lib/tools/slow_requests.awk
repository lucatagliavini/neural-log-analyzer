# Richieste con tempo di risposta sopra soglia dall'access log Undertow.
# Parametri: -v threshold_ms="1000"
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato campi: IP [datetime] "METHOD URL PROTO" STATUS BYTES TIME_MS CHAIN UA

BEGIN { FS = " "; if (threshold_ms == "") threshold_ms = 1000; count = 0; max_rows = 30; col_url = 52 }

function trunc_end(s, n,    r) {
    if (length(s) <= n) return s
    return "…" substr(s, length(s) - n + 2)
}

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    line = $0

    # Estrai tempo risposta (7° campo dopo la stringa HTTP)
    # Formato: IP [date] "M U P" STATUS BYTES TIME ...
    if (!match(line, /" [0-9]+ [0-9]+ ([0-9]+) /, a)) next
    resp_time = a[1] + 0

    if (resp_time < threshold_ms + 0) next

    # Estrai campi utili
    if (!match(line, /"([A-Z]+) ([^ ]+) HTTP[^"]*"/, b)) next
    method = b[1]; url = b[2]

    if (!match(line, /" ([0-9]{3}) /, c)) next
    status = c[1]

    count++
    if (count <= max_rows) {
        printf "%-8s  %-6s  %-*s  %d ms\n", status, method, col_url, trunc_end(url, col_url), resp_time
    }
    total_time += resp_time
    if (resp_time > max_time) { max_time = resp_time; max_url = url }
}

END {
    if (count == 0) {
        printf "Nessuna richiesta lenta sopra %d ms trovata.\n", threshold_ms
    } else {
        if (count > max_rows) printf "... (mostrate %d di %d)\n", max_rows, count
        printf "\nTotale richieste lente: %d (soglia: %d ms)\n", count, threshold_ms
        printf "Risposta più lenta: %d ms → %s\n", max_time, max_url
        printf "Latenza media (lente): %.0f ms\n", total_time / count
    }
}
