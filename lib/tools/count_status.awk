# Conta richieste HTTP per codice di stato dall'access log Undertow.
# Parametri: -v status_filter="500|5xx|4xx|" (vuoto = tutti)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato atteso: IP [DD/Mon/YYYY:HH:MM:SS +TZ] "METHOD URL PROTO" STATUS BYTES TIME CHAIN UA

BEGIN {
    FS = " "
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
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
    printf "%-10s  %s\n", "STATUS", "COUNT"
    printf "%-10s  %s\n", "──────────", "──────"

    n = 0
    for (s in count) keys[++n] = s
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (keys[i]+0 > keys[j]+0) { t=keys[i]; keys[i]=keys[j]; keys[j]=t }

    for (i = 1; i <= n; i++) {
        s = keys[i]
        if (substr(s,1,1) == "5")      color = RED
        else if (substr(s,1,1) == "4") color = YELLOW
        else                           color = ""
        reset = (color != "") ? RESET : ""
        printf "%s%-10s%s  %d\n", color, s, reset, count[s]
    }
    printf "%-10s  %s\n", "──────────", "──────"
    printf "%-10s  %d\n", "TOTALE", total
}
