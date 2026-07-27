# Conta richieste HTTP per codice di stato dall'access log Undertow.
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato atteso: IP [DD/Mon/YYYY:HH:MM:SS +TZ] "METHOD URL PROTO" STATUS BYTES TIME CHAIN UA

BEGIN { FS = " " }

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next

    # Estrai data/ora: campo 2 = [DD/Mon/YYYY:HH:MM:SS
    gsub(/[\[\]]/, "", $2)
    datetime = $2
    split(datetime, dt, /[\/: ]/)
    # dt[1]=DD dt[2]=Mon dt[3]=YYYY dt[4]=HH dt[5]=MM dt[6]=SS

    # Estrai status: campo 5 (dopo chiusura virgolette)
    # Formato: ... "METHOD URL PROTO" STATUS BYTES TIME ...
    # Conta i campi dentro le virgolette per trovare STATUS
    line = $0
    if (match(line, /" ([0-9]{3}) /, a)) {
        status = a[1]
    } else {
        next
    }

    # Filtro per status
    if (status_filter != "") {
        if (status_filter ~ /xx$/) {
            prefix = substr(status_filter, 1, 1)
            if (substr(status, 1, 1) != prefix) next
        } else if (status != status_filter) {
            next
        }
    }

    count[status]++
    total++
}

END {
    printf "%-10s  %s\n", "STATUS", "COUNT"
    printf "%-10s  %s\n", "──────────", "──────"
    # Stampa in ordine crescente di status code
    n = 0
    for (s in count) keys[++n] = s
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (keys[i]+0 > keys[j]+0) { t=keys[i]; keys[i]=keys[j]; keys[j]=t }
    for (i = 1; i <= n; i++)
        printf "%-10s  %d\n", keys[i], count[keys[i]]
    printf "%-10s  %s\n", "──────────", "──────"
    printf "%-10s  %d\n", "TOTALE", total
}
