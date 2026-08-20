# Distribuisce richieste con errore per endpoint (path normalizzato).
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti gli errori 4xx/5xx)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN {
    FS = " "; max_rows = 20

}

{
    if ((time_from != "" || time_to != "") && !in_range(access_ts())) next
    line = $0

    # Estrai status
    _st = access_status()
    if (_st == "") next
    status = _st

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

    # Endpoint normalizzato (query string/matrix param tagliati, ID e UUID
    # sostituiti da placeholder): access_url_endpoint(), utils-access-undertow.awk.
    _url = access_url_endpoint()
    if (_url == "") next
    url = _url

    endpoint_count[url][status]++
    endpoint_total[url]++
    total++
}

END {
    # Il filtro temporale non ha potuto filtrare (nessun timestamp riconosciuto in
    # tutto il file): lo si DICE, invece di presentare dati non filtrati come se lo
    # fossero. Contropartita di in_range(epoch<=0)=1 in utils-time.awk.
    access_ts_format_warning()
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
            color = (substr(st,1,1) == "5") ? C_CRIT : C_WARN
            printf "%-*s  %s%-8s%s  %s%d%s\n", col_ep, ep, color, st, C_RESET, C_VAL, endpoint_count[ep][st], C_RESET
            shown++
        }
    }
    printf "\nTotale richieste con errore: %d\n", total
}
