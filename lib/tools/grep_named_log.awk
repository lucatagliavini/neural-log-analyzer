# Filtra un log Guidewire per livello (ERROR/WARN/INFO) e/o pattern testuale.
#
# Parametri:
#   -v level="ERROR"        livello (ERROR|WARN|INFO|WARN+|ALL)
#   -v pattern=""           pattern ERE aggiuntivo (vuoto = nessun filtro)
#   -v tail_n=50            massimo righe di output
#   -v time_from="YYYY-MM-DDTHH:MM"
#   -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato Guidewire: [thread] USER YYYY-MM-DDTHH:MM:SS,mmm LEVEL messaggio
# Il timestamp è in posizione variabile — estratto con regex.

BEGIN {
    FS = " "
    n = (tail_n+0 > 0) ? tail_n+0 : 50
    if (level == "") level = "ERROR"
    count = 0
    RED = "\033[31m"; YELLOW = "\033[33m"; DIM = "\033[2m"; RESET = "\033[0m"
    GW_RE = "([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]+) (ERROR|WARN|INFO|DEBUG|TRACE)(.*)"
}

{
    if (!match($0, GW_RE, m)) next

    row_ts    = m[1]
    row_level = m[2]
    row_msg   = m[3]
    sub(/^ /, "", row_msg)

    if (level == "WARN+") {
        if (row_level != "ERROR" && row_level != "WARN") next
    } else if (level != "ALL" && row_level != level) next

    if (pattern != "" && $0 !~ pattern) next

    if (time_from != "" || time_to != "") {
        ts_str = row_ts
        gsub(/T/, " ", ts_str); gsub(/,.*/, "", ts_str)
        split(ts_str, dt, " ")
        split(dt[1], d, "-"); split(dt[2], t, ":")
        epoch = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " t[3])
        if (!in_range(epoch)) next
    }

    # Ring buffer: tieni le ultime n righe corrispondenti
    thread = $0
    if (match(thread, /\[([^\]]+)\]/, th)) thread = th[1]
    else thread = ""

    buf_ts[count % n]     = row_ts
    buf_level[count % n]  = row_level
    buf_msg[count % n]    = row_msg
    buf_thread[count % n] = thread
    count++
}

function dedup_key(rl, msg) {
    return rl SUBSEP substr(msg, 1, 120)
}

END {
    if (count == 0) {
        printf "Nessuna riga trovata"
        if (level == "WARN+")    printf " (level=ERROR+WARN)"
        else if (level != "ALL") printf " (level=%s)", level
        if (pattern != "")       printf " (pattern=%s)", pattern
        print "."
        exit
    }

    shown = (count < n) ? count : n
    start = (count < n) ? 0 : (count % n)

    # Conta occorrenze per dedup
    for (i = 0; i < shown; i++) {
        idx = (start + i) % n
        dk = dedup_key(buf_level[idx], buf_msg[idx])
        if (!(dk in dedup_cnt)) {
            dedup_order[++dedup_n] = dk
            dedup_rl[dk]  = buf_level[idx]
            dedup_ts[dk]  = buf_ts[idx]
            dedup_th[dk]  = buf_thread[idx]
            dedup_msg[dk] = buf_msg[idx]
        }
        dedup_cnt[dk]++
    }

    # Ordina: prima rari (cnt=1), poi frequenti (cnt>1) per conteggio desc
    # insertion sort su dedup_order
    for (i = 2; i <= dedup_n; i++) {
        tk = dedup_order[i]; tv = dedup_cnt[tk]; j = i-1
        while (j >= 1 && dedup_cnt[dedup_order[j]] > tv) {
            dedup_order[j+1] = dedup_order[j]; j--
        }
        dedup_order[j+1] = tk
    }

    for (i = 1; i <= dedup_n; i++) {
        dk  = dedup_order[i]
        rl  = dedup_rl[dk]
        cnt = dedup_cnt[dk]
        color = (rl == "ERROR") ? RED : (rl == "WARN") ? YELLOW : ""
        rst   = (color != "") ? RESET : ""
        cnt_str = (cnt > 1) ? sprintf(" (×%d)", cnt) : ""
        printf "%s%-5s%s  %s%s%s  %s%s\n", \
            color, rl, rst, \
            DIM, substr(dedup_ts[dk], 1, 19), RESET, \
            substr(dedup_msg[dk], 1, 100), cnt_str
        if (dedup_th[dk] != "")
            printf "       %s[%s]%s\n", DIM, substr(dedup_th[dk], 1, 60), RESET
    }

    distinct = dedup_n
    if (count > shown) printf "\n... (mostrate ultime %d di %d totali, %d messaggi distinti)\n", shown, count, distinct
    else printf "\nTotale: %d righe, %d messaggi distinti\n", count, distinct
}
