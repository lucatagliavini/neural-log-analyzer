# Volume di traffico per fascia oraria (bucketing a 10 minuti).
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN {
    FS = " "
}

{
    if ((time_from != "" || time_to != "") && !in_range(access_ts())) next
    if (!match($0, /\[([0-9]{2}\/[A-Za-z]+\/[0-9]{4}):([0-9]{2}):([0-9]{2})/, a)) next
    hour   = a[2]
    minute = a[3] + 0
    bucket = hour ":" sprintf("%02d", int(minute/10)*10)
    volume[bucket]++

    if (match($0, /" ([0-9]{3}) /, b)) {
        st = b[1]
        if (substr(st, 1, 1) == "5") errors5xx[bucket]++
        else if (substr(st, 1, 1) == "4") errors4xx[bucket]++
    }
    total++
}

END {
    if (total == 0) { print "Nessuna richiesta trovata."; exit }

    # Calcola picco per barra proporzionale
    max_vol = 0
    for (bk in volume) if (volume[bk] > max_vol) max_vol = volume[bk]

    printf "%-10s  %7s  %6s  %6s  %s\n", "FASCIA", "TOTALE", "4xx", "5xx", "ANDAMENTO"
    printf "%-10s  %7s  %6s  %6s  %s\n", "──────────", "───────", "──────", "──────", "──────────────────────────────"

    n = 0
    for (bk in volume) keys[++n] = bk
    for (i = 2; i <= n; i++) {
        tk = keys[i]; j = i-1
        while (j >= 1 && keys[j] > tk) { keys[j+1]=keys[j]; j-- }
        keys[j+1] = tk
    }

    bar_max = 30
    for (i = 1; i <= n; i++) {
        bk   = keys[i]
        e4   = errors4xx[bk]+0
        e5   = errors5xx[bk]+0
        col4 = (e4 > 0) ? C_WARN : ""
        col5 = (e5 > 0) ? C_CRIT    : ""
        rst  = C_RESET

        # Barra proporzionale al picco
        bar_len = int(volume[bk] * bar_max / max_vol)
        bar = ""
        for (k = 1; k <= bar_len; k++) bar = bar "▪"

        printf "%-10s  %s%7d%s  %s%6d%s  %s%6d%s  %s%s%s\n", \
            bk, C_VAL, volume[bk], rst, \
            col4, e4, (col4!="") ? rst : "", \
            col5, e5, (col5!="") ? rst : "", \
            C_LBL, bar, rst
    }
    printf "\nTotale richieste: %s%d%s in %s%d%s fasce da 10 minuti\n", C_VAL, total, rst, C_VAL, n, rst
}
