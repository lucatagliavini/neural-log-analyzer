# Distribuisce richieste con errore per endpoint (path normalizzato).
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti gli errori 4xx/5xx)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN { FS = " "; max_rows = 20 }

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
    printf "%-50s  %-8s  %s\n", "ENDPOINT", "STATUS", "COUNT"
    printf "%-50s  %-8s  %s\n", "──────────────────────────────────────────────────", "────────", "──────"

    # Ordina per totale decrescente (insertion sort)
    n = 0
    for (ep in endpoint_total) { keys[++n] = ep; vals[n] = endpoint_total[ep] }
    for (i = 2; i <= n; i++) {
        tk = keys[i]; tv = vals[i]; j = i-1
        while (j >= 1 && vals[j] < tv) { keys[j+1]=keys[j]; vals[j+1]=vals[j]; j-- }
        keys[j+1] = tk; vals[j+1] = tv
    }

    shown = 0
    for (i = 1; i <= n && shown < max_rows; i++) {
        ep = keys[i]
        for (st in endpoint_count[ep]) {
            printf "%-50s  %-8s  %d\n", ep, st, endpoint_count[ep][st]
            shown++
        }
    }
    printf "\nTotale richieste con errore: %d\n", total
}
