# Conta richieste HTTP per codice di stato dall'access log Undertow.
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato atteso: IP [DD/Mon/YYYY:HH:MM:SS +TZ] "METHOD URL PROTO" STATUS BYTES TIME CHAIN UA

BEGIN {
    FS = " "
}

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    line = $0
    if (match(line, /" ([0-9]{3}) /, a)) {
        status = a[1]
    } else {
        next
    }

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
    if (total == 0) {
        print "Nessuna richiesta trovata nel periodo selezionato."
        exit
    }

    # Ordina i codici numericamente
    n = 0
    for (s in count) keys[++n] = s
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (keys[i]+0 > keys[j]+0) { t=keys[i]; keys[i]=keys[j]; keys[j]=t }

    # Trova il valore massimo per scalare le barre
    max_count = 0
    for (i = 1; i <= n; i++)
        if (count[keys[i]] > max_count) max_count = count[keys[i]]

    BAR_WIDTH = 20

    printf "%-10s  %9s  %7s  %s\n", "STATUS", "COUNT", "%", "BAR (scala log)"
    printf "%-10s  %9s  %7s  %s\n", "──────────", "─────────", "───────", "────────────────────"

    for (i = 1; i <= n; i++) {
        s = keys[i]
        pct = count[s] / total * 100
        # Scala logaritmica: log(count)/log(max) — garantisce visibilità anche a valori piccoli
        if (count[s] > 0 && max_count > 1)
            bar_len = int(log(count[s]) / log(max_count) * BAR_WIDTH + 0.5)
        else
            bar_len = (count[s] > 0) ? 1 : 0
        if (bar_len < 1 && count[s] > 0) bar_len = 1
        bar = ""
        for (b = 1; b <= bar_len; b++) bar = bar "█"

        if      (substr(s,1,1) == "5") color = RED
        else if (substr(s,1,1) == "4") color = YELLOW
        else if (substr(s,1,1) == "3") color = CYAN
        else                           color = ""
        reset = (color != "") ? RESET : ""

        printf "%s%-10s%s  %9d  %6.1f%%  %s\n", color, s, reset, count[s], pct, bar
    }

    printf "%-10s  %9s  %7s\n", "──────────", "─────────", "───────"
    printf "%-10s  %9d\n\n", "TOTALE", total

    # Calcola raggruppamenti
    s2xx = 0; s3xx = 0; s4xx = 0; s5xx = 0
    for (s in count) {
        p = substr(s,1,1)
        if (p == "2") s2xx += count[s]
        else if (p == "3") s3xx += count[s]
        else if (p == "4") s4xx += count[s]
        else if (p == "5") s5xx += count[s]
    }
    err_total = s4xx + s5xx
    err_rate  = err_total / total * 100

    w = 9  # larghezza colonna numeri nel summary
    printf         "  Successi  2xx:  %*d  (%5.1f%%)\n",        w, s2xx, s2xx/total*100
    if (s3xx > 0)
        printf CYAN   "  Redirect  3xx:  %*d  (%5.1f%%)\n" RESET, w, s3xx, s3xx/total*100
    printf YELLOW "  Errori    4xx:  %*d  (%5.1f%%)\n" RESET, w, s4xx, s4xx/total*100
    printf RED    "  Errori    5xx:  %*d  (%5.1f%%)\n" RESET, w, s5xx, s5xx/total*100
    printf "  ─────────────────────────────\n"
    printf "  Tasso errore:   %*s  %5.2f%%\n", w, "", err_rate
}
