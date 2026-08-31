# Trova errori applicativi nel server.log anche quando loggati come INFO.
# Intercetta due pattern:
#   1. Righe con status= 5xx nel testo seguite dalla riga "message: <causa>"
#   2. Righe con Exception/caused by nel messaggio (sullo stesso livello JBoss)
# Raggruppa per root cause e conta le occorrenze.
#
# Dipende da: utils-colors.awk, utils-jboss.awk, utils-dedup.awk, utils-time.awk

BEGIN {
    FS = " "; waiting_cause = 0
}

waiting_cause && /message:/ {
    register_error("HTTP-" pending_status, pending_logger, extract_cause($0), pending_ts)
    waiting_cause = 0
    next
}

waiting_cause && /^}/ {
    register_error("HTTP-" pending_status, pending_logger, "(causa non estratta)", pending_ts)
    waiting_cause = 0
    next
}

/status= *5[0-9][0-9]/ {
    if (!parse_server_log()) next
    if ((time_from != "" || time_to != "") && !in_range(parse_server(_ts_date, _ts_time))) next
    pending_logger = short_logger(_logger)
    if (match($0, /status= *([0-9]+)/, sm)) pending_status = sm[1]+0
    else pending_status = 500
    pending_ts = _ts
    waiting_cause = 1
    next
}

/[Ee]xception|[Cc]aused [Bb]y:/ {
    if (!parse_server_log()) next
    if ((time_from != "" || time_to != "") && !in_range(parse_server(_ts_date, _ts_time))) next
    register_error("EXCEPTION", short_logger(_logger), extract_cause($0), _ts)
}

function short_logger(fqcn,    parts, n) {
    n = split(fqcn, parts, ".")
    return n > 0 ? parts[n] : fqcn
}

function extract_cause(line,    c, last) {
    c = line
    last = ""
    while (match(c, /[Cc]aused [Bb]y: */)) {
        c = substr(c, RSTART + RLENGTH)
        last = c
    }
    if (last != "") {
        gsub(/[{}\n].*$/, "", last)
        gsub(/[ \t]+$/, "", last)
        return substr(last, 1, 100)
    }
    if (match(c, /([A-Za-z.]+[Ee]xception)[: ]+([^\n{]+)/, ex)) {
        gsub(/[ \t]+$/, "", ex[2])
        return substr(ex[1] ": " ex[2], 1, 100)
    }
    sub(/^[0-9-]+ [0-9:,]+ [A-Z]+ +\[[^\]]+\] \([^)]+\) /, "", c)
    gsub(/[ \t]+$/, "", c)
    return substr(c, 1, 80)
}

function register_error(type, logger, cause, ts,    key) {
    # La CHIAVE resta un substr nudo: il taglio a 80 è il meccanismo che fa
    # collassare due cause che differiscono solo nella coda, e un "…" la
    # allungherebbe senza cambiare cosa raggruppa.
    key = type SUBSEP substr(cause, 1, 80)
    # Il terzo argomento invece viene STAMPATO (colonna ROOT CAUSE), quindi il
    # taglio va dichiarato — TRUNC-1. La larghezza di colonna è calcolata da
    # length(_dup_msg[k]) nella END, quindi si allarga da sé e la tabella resta
    # allineata.
    dedup_add(key, type, ellipsize(cause, 80), ts, logger)
    total++
    _scope_n++
}

END {
    if (total == 0) {
        print "Nessun errore applicativo trovato nel server log."
        exit
    }

    dedup_sort()  # ascendente — iteriamo in reverse per avere più frequenti prima

    col_log = length("CLASSE")
    col_cau = length("ROOT CAUSE")
    for (i = _dup_n; i >= 1; i--) {
        k = _dup_order[i]
        if (length(_dup_extra[k]) > col_log) col_log = length(_dup_extra[k])
        if (length(_dup_msg[k])   > col_cau) col_cau = length(_dup_msg[k])
    }
    if (col_cau > 80) col_cau = 80

    sep_log = ""; for (k = 1; k <= col_log; k++) sep_log = sep_log "─"
    sep_cau = ""; for (k = 1; k <= col_cau; k++) sep_cau = sep_cau "─"

    printf "%-10s  %-*s  %5s  %-*s\n", "TIPO", col_log, "CLASSE", "COUNT", col_cau, "ROOT CAUSE"
    printf "%-10s  %-*s  %5s  %-*s\n", "──────────", col_log, sep_log, "─────", col_cau, sep_cau

    max_print = 30
    printed = 0
    for (i = _dup_n; i >= 1 && printed < max_print; i--) {
        printed++
        k = _dup_order[i]
        color = (_dup_level[k] ~ /^HTTP-5/) ? C_CRIT : C_WARN
        printf "%s%-10s%s  %-*s  %s%5d%s  %-*s\n", \
            color, _dup_level[k], C_RESET, \
            col_log, _dup_extra[k], \
            C_VAL, _dup_cnt[k], C_RESET, \
            col_cau, substr(_dup_msg[k], 1, col_cau)
    }
    if (_dup_n > max_print) printf "... (%d cause distinte aggiuntive)\n", _dup_n - max_print
    printf "\nTotale errori applicativi: %d (%d cause distinte)\n", total, _dup_n
}
