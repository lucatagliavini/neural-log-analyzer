# Distribuisce richieste con errore per endpoint (path normalizzato).
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti gli errori 4xx/5xx)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN {
    FS = " "; max_rows = 20
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
}

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    line = $0

    # Estrai status
    if (!match(line, /" ([0-9]{3}) /, a)) next
    status = a[1]

    # Filtro status
    if (status_filter != "") {
        if (status_filter ~ /xx$/) {
            prefix = substr(status_filter, 1, 1)
            if (substr(status, 1, 1) != prefix) next
        } else if (status != status_filter) {
            next
        }
    } else {
        # Default: solo errori 4xx/5xx
        if (substr(status, 1, 1) != "4" && substr(status, 1, 1) != "5") next
    }

    # Estrai URL (terzo campo tra virgolette: METHOD URL PROTO)
    if (match(line, /"[A-Z]+ ([^ ]+) HTTP/, b)) {
        url = b[1]
    } else {
        next
    }

    # Normalizza URL: rimuovi query string e ID numerici lunghi
    sub(/\?.*/, "", url)
    gsub(/\/[0-9]{5,}/, "/{id}", url)
    gsub(/\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/, "/{uuid}", url)

    endpoint_count[url][status]++
    endpoint_total[url]++
    total++
}

END {
    # Calcola larghezza massima endpoint tra quelli che verranno mostrati
    n = 0
    for (ep in endpoint_total) { keys[++n] = ep; vals[n] = endpoint_total[ep] }
    for (i = 2; i <= n; i++) {
        tk = keys[i]; tv = vals[i]; j = i-1
        while (j >= 1 && vals[j] < tv) { keys[j+1]=keys[j]; vals[j+1]=vals[j]; j-- }
        keys[j+1] = tk; vals[j+1] = tv
    }

    col_ep = length("ENDPOINT")
    shown = 0
    for (i = 1; i <= n && shown < max_rows; i++) {
        ep = keys[i]
        for (st in endpoint_count[ep]) {
            if (length(ep) > col_ep) col_ep = length(ep)
            shown++
        }
    }

    sep = ""
    for (k = 1; k <= col_ep; k++) sep = sep "─"

    printf "%-*s  %-8s  %s\n", col_ep, "ENDPOINT", "STATUS", "COUNT"
    printf "%-*s  %-8s  %s\n", col_ep, sep, "────────", "──────"

    shown = 0
    for (i = 1; i <= n && shown < max_rows; i++) {
        ep = keys[i]
        for (st in endpoint_count[ep]) {
            color = (substr(st,1,1) == "5") ? RED : YELLOW
            printf "%-*s  %s%-8s%s  %d\n", col_ep, ep, color, st, RESET, endpoint_count[ep][st]
            shown++
        }
    }
    printf "\nTotale richieste con errore: %d\n", total
}
