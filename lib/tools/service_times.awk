# Estrae e aggrega i tempi di esecuzione dei servizi SOA dal server.log.
# Formato riga target: ... RETURN(service.name) in X msec. ...
# Parametri: -v time_window="2h|30m|"

BEGIN { max_rows = 20 }

/RETURN\(/ && /in [0-9]+ msec/ {
    # Estrai nome servizio e tempo
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

    printf "%-45s  %6s  %8s  %8s  %8s\n", "SERVIZIO", "CALLS", "AVG ms", "MIN ms", "MAX ms"
    printf "%-45s  %6s  %8s  %8s  %8s\n", \
        "─────────────────────────────────────────────", "──────", "────────", "────────", "────────"

    # Ordina per tempo medio decrescente
    n = 0
    for (s in svc_count) { keys[++n] = s; avgs[n] = svc_total[s]/svc_count[s] }
    for (i = 2; i <= n; i++) {
        tk = keys[i]; tv = avgs[i]; j = i-1
        while (j >= 1 && avgs[j] < tv) { keys[j+1]=keys[j]; avgs[j+1]=avgs[j]; j-- }
        keys[j+1] = tk; avgs[j+1] = tv
    }

    for (i = 1; i <= n && i <= max_rows; i++) {
        s = keys[i]
        printf "%-45s  %6d  %8.0f  %8d  %8d\n", \
            substr(s, 1, 45), svc_count[s], svc_total[s]/svc_count[s], svc_min[s], svc_max[s]
    }
}
