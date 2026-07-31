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
#
# Dipende da: utils-colors.awk, utils-dedup.awk, utils-time.awk

BEGIN {
    FS = " "
    n = (tail_n+0 > 0) ? tail_n+0 : 50
    if (level == "") level = "ERROR"
    count = 0
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

    thread = $0
    if (match(thread, /\[([^\]]+)\]/, th)) thread = th[1]
    else thread = ""

    buf_ts[count % n]     = row_ts
    buf_level[count % n]  = row_level
    buf_msg[count % n]    = row_msg
    buf_thread[count % n] = thread
    count++
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

    for (i = 0; i < shown; i++) {
        idx = (start + i) % n
        dk  = buf_level[idx] SUBSEP substr(buf_msg[idx], 1, 120)
        dedup_add(dk, buf_level[idx], buf_msg[idx], buf_ts[idx], buf_thread[idx])
    }

    dedup_sort()

    for (i = 1; i <= _dup_n; i++) {
        dk    = _dup_order[i]
        rl    = _dup_level[dk]
        cnt   = _dup_cnt[dk]
        color = (rl == "ERROR") ? RED : (rl == "WARN") ? YELLOW : (rl == "INFO") ? WHT : ""
        rst   = (color != "") ? RESET : ""
        cnt_str = (cnt > 1) ? sprintf(" (×%d)", cnt) : ""
        printf "%s%-5s%s  %s%s%s  %s%s\n", \
            color, rl, rst, \
            DIM, substr(_dup_ts[dk], 1, 19), RESET, \
            substr(_dup_msg[dk], 1, 100), cnt_str
        if (_dup_extra[dk] != "")
            printf "       %s[%s]%s\n", DIM, substr(_dup_extra[dk], 1, 60), RESET
    }

    distinct = _dup_n
    if (count > shown)
        printf "\n... (mostrate ultime %d di %d totali, %d messaggi distinti)\n", shown, count, distinct
    else
        printf "\nTotale: %d righe, %d messaggi distinti\n", count, distinct
}
