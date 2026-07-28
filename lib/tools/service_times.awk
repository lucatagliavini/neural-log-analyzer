# Estrae e aggrega i tempi di esecuzione dei servizi SOA dal server.log.
# Formato riga target: ... RETURN(service.name) in X msec. ...
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN {
    max_rows = 20
    YELLOW = "\033[33m"; RED = "\033[31m"; RESET = "\033[0m"
    SLOW_MS = 2000; VERYSLOW_MS = 5000
}

/RETURN\(/ && /in [0-9]+ msec/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    if (match($0, /RETURN\(([^)]+)\) in ([0-9]+) msec/, a)) {
        svc  = a[1]
        ms   = a[2] + 0
        svc_count[svc]++
        svc_total[svc] += ms
        if (ms > svc_max[svc]) svc_max[svc] = ms
        if (svc_min[svc] == "" || ms < svc_min[svc]) svc_min[svc] = ms
    }
}

END {
    if (length(svc_count) == 0) {
        print "Nessun dato SOA trovato nel server log."
        exit
    }

    # Larghezza dinamica sul nome servizio
    col_svc = length("SERVIZIO")
    for (s in svc_count) if (length(s) > col_svc) col_svc = length(s)

    # Ordina per tempo medio decrescente
    n = 0
    for (s in svc_count) { keys[++n] = s; avgs[n] = svc_total[s]/svc_count[s] }
    for (i = 2; i <= n; i++) {
        tk = keys[i]; tv = avgs[i]; j = i-1
        while (j >= 1 && avgs[j] < tv) { keys[j+1]=keys[j]; avgs[j+1]=avgs[j]; j-- }
        keys[j+1] = tk; avgs[j+1] = tv
    }

    sep = ""; for (k = 1; k <= col_svc; k++) sep = sep "─"
    printf "%-*s  %6s  %8s  %8s  %8s\n", col_svc, "SERVIZIO", "CALLS", "AVG ms", "MIN ms", "MAX ms"
    printf "%-*s  %6s  %8s  %8s  %8s\n", col_svc, sep, "──────", "────────", "────────", "────────"

    for (i = 1; i <= n && i <= max_rows; i++) {
        s   = keys[i]
        avg = svc_total[s] / svc_count[s]
        if (avg >= VERYSLOW_MS)    color = RED
        else if (avg >= SLOW_MS)   color = YELLOW
        else                       color = ""
        rst = (color != "") ? RESET : ""
        printf "%-*s  %6d  %s%8.0f%s  %8d  %8d\n", \
            col_svc, s, svc_count[s], color, avg, rst, svc_min[s], svc_max[s]
    }
    if (n > max_rows) printf "... (mostrati %d di %d servizi)\n", max_rows, n
}
