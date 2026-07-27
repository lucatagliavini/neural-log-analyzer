# Volume di traffico per fascia oraria (bucketing a 10 minuti).
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN { FS = " " }

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    # Estrai ora:minuto dal campo datetime
    if (!match($0, /\[([0-9]{2}\/[A-Za-z]+\/[0-9]{4}):([0-9]{2}):([0-9]{2})/, a)) next
    hour   = a[2]
    minute = a[3] + 0
    bucket = hour ":" sprintf("%02d", int(minute/10)*10)
    volume[bucket]++

    # Traccia status per bucket
    if (match($0, /" ([0-9]{3}) /, b)) {
        st = b[1]
        if (substr(st, 1, 1) == "5") errors5xx[bucket]++
        else if (substr(st, 1, 1) == "4") errors4xx[bucket]++
    }
    total++
}

END {
    printf "%-10s  %7s  %6s  %6s\n", "FASCIA", "TOTALE", "4xx", "5xx"
    printf "%-10s  %7s  %6s  %6s\n", "──────────", "───────", "──────", "──────"

    n = 0
    for (bk in volume) keys[++n] = bk
    for (i = 2; i <= n; i++) {
        tk = keys[i]; j = i-1
        while (j >= 1 && keys[j] > tk) { keys[j+1]=keys[j]; j-- }
        keys[j+1] = tk
    }

    for (i = 1; i <= n; i++) {
        bk = keys[i]
        printf "%-10s  %7d  %6d  %6d\n", bk, volume[bk], errors4xx[bk]+0, errors5xx[bk]+0
    }
    printf "\nTotale richieste: %d in %d bucket da 10 minuti\n", total, n
}
