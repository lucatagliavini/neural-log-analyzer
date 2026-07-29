# Trova errori applicativi nel server.log anche quando loggati come INFO.
# Intercetta due pattern:
#   1. Righe con status= 5xx nel testo seguite dalla riga "message: <causa>"
#   2. Righe con Exception/caused by nel messaggio (sullo stesso livello JBoss)
# Raggruppa per root cause e conta le occorrenze.

BEGIN {
    FS = " "; waiting_cause = 0
}

waiting_cause && /message:/ {
    cause = extract_cause($0)
    register_error("HTTP-" pending_status, pending_logger, cause, pending_ts)
    waiting_cause = 0
    next
}

waiting_cause && /^}/ {
    register_error("HTTP-" pending_status, pending_logger, "(causa non estratta)", pending_ts)
    waiting_cause = 0
    next
}

/^[0-9][0-9][0-9][0-9]-/ && /status= *5[0-9][0-9]/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    pending_logger = short_logger($4)
    if (match($0, /status= *([0-9]+)/, sm)) pending_status = sm[1]+0
    else pending_status = 500
    pending_ts = $1 " " $2
    waiting_cause = 1
    next
}

/^[0-9][0-9][0-9][0-9]-/ && /[Ee]xception|[Cc]aused [Bb]y:/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    logger = short_logger($4)
    cause  = extract_cause($0)
    register_error("EXCEPTION", logger, cause, $1 " " $2)
}

function short_logger(fqcn,    parts, n) {
    gsub(/[\[\]]/, "", fqcn)
    n = split(fqcn, parts, ".")
    return n > 0 ? parts[n] : fqcn
}

function extract_cause(line,    c, last, pos) {
    c = line
    last = ""
    while (match(c, /[Cc]aused [Bb]y: */) ) {
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

function register_error(type, logger, cause, ts,    key, short) {
    short = substr(cause, 1, 80)
    key = type SUBSEP short
    if (!(key in cause_count)) {
        cause_type[key]   = type
        cause_logger[key] = logger
        cause_ts[key]     = ts
        cause_text[key]   = short
    }
    cause_count[key]++
    total++
}

END {
    if (total == 0) {
        print "Nessun errore applicativo trovato nel server log."
        exit
    }

    # Ordina per conteggio decrescente
    n = 0
    for (k in cause_count) keys[++n] = k
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (cause_count[keys[j]] > cause_count[keys[i]]) {
                tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
            }

    # Larghezza dinamica per classe e root cause
    col_log = length("CLASSE")
    col_cau = length("ROOT CAUSE")
    for (i = 1; i <= n; i++) {
        k = keys[i]
        if (length(cause_logger[k]) > col_log) col_log = length(cause_logger[k])
        if (length(cause_text[k])   > col_cau) col_cau = length(cause_text[k])
    }
    if (col_cau > 80) col_cau = 80

    sep_log = ""; for (k = 1; k <= col_log; k++) sep_log = sep_log "─"
    sep_cau = ""; for (k = 1; k <= col_cau; k++) sep_cau = sep_cau "─"

    printf "%-10s  %-*s  %5s  %-*s\n", "TIPO", col_log, "CLASSE", "CNT", col_cau, "ROOT CAUSE"
    printf "%-10s  %-*s  %5s  %-*s\n", "──────────", col_log, sep_log, "─────", col_cau, sep_cau

    max_print = 30
    for (i = 1; i <= n && i <= max_print; i++) {
        k = keys[i]
        color = (cause_type[k] ~ /^HTTP-5/) ? RED : YELLOW
        printf "%s%-10s%s  %-*s  %5d  %-*s\n", \
            color, cause_type[k], RESET, \
            col_log, cause_logger[k], \
            cause_count[k], \
            col_cau, substr(cause_text[k], 1, col_cau)
    }
    if (n > max_print) printf "... (%d cause distinte in più)\n", n - max_print
    printf "\nTotale errori applicativi: %d (%d cause distinte)\n", total, n
}
