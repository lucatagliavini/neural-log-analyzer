# Filtra righe ERROR e WARN dal server.log JBoss.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato: YYYY-MM-DD HH:MM:SS,mmm LEVEL [classe] (thread) messaggio

BEGIN {
    FS = " "; max_rows = 50; count = 0
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
    DIM = "\033[2m"
}

/ERROR|WARN/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    level = $3
    if (level != "ERROR" && level != "WARN") next

    logger = $4; gsub(/[\[\]]/, "", logger)
    thread = $5; gsub(/[()]/, "", thread)

    msg = ""
    for (i = 6; i <= NF; i++) msg = msg " " $i
    sub(/^ /, "", msg)

    if (level == "ERROR") nerror++
    else nwarn++
    count++

    # Dedup: tieni ultima occorrenza per chiave level+msg(80)
    dk = level SUBSEP substr(msg, 1, 80)
    if (!(dk in dedup_cnt)) {
        dedup_order[++dedup_n] = dk
        dedup_level[dk]  = level
        dedup_msg[dk]    = msg
        dedup_ts[dk]     = $1 " " $2
        dedup_log[dk]    = logger
        dedup_thread[dk] = thread
    }
    dedup_cnt[dk]++
    dedup_ts[dk]    = $1 " " $2
    dedup_log[dk]   = logger
}

END {
    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
        exit
    }

    # Ordina: rari (cnt=1) prima, frequenti alla fine
    for (i = 2; i <= dedup_n; i++) {
        tk = dedup_order[i]; tv = dedup_cnt[tk]; j = i-1
        while (j >= 1 && dedup_cnt[dedup_order[j]] > tv) {
            dedup_order[j+1] = dedup_order[j]; j--
        }
        dedup_order[j+1] = tk
    }

    printed = 0
    for (i = 1; i <= dedup_n && printed < max_rows; i++) {
        dk    = dedup_order[i]
        rl    = dedup_level[dk]
        cnt   = dedup_cnt[dk]
        color = (rl == "ERROR") ? RED : YELLOW
        cnt_str = (cnt > 1) ? sprintf(" (×%d)", cnt) : ""
        printf "%s[%s] %-5s%s  %s%s\n", color, dedup_ts[dk], rl, RESET, substr(dedup_msg[dk], 1, 100), cnt_str
        printf "  %s%s | %s%s\n\n", DIM, dedup_log[dk], dedup_thread[dk], RESET
        printed++
    }

    if (dedup_n > max_rows) printf "... (mostrati %d di %d messaggi distinti)\n", max_rows, dedup_n
    printf "Totale: %s%d ERROR%s, %s%d WARN%s (%d distinti)\n", \
        RED, nerror+0, RESET, YELLOW, nwarn+0, RESET, dedup_n
}
