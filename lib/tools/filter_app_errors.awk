# Trova errori applicativi nel server.log anche quando loggati come INFO.
# Intercetta due pattern:
#   1. Righe con status= 5xx nel testo seguite dalla riga "message: <causa>"
#   2. Righe con Exception/caused by nel messaggio (sullo stesso livello JBoss)
# Raggruppa per root cause e conta le occorrenze.

BEGIN { FS = " "; waiting_cause = 0 }

# Riga di continuazione: raccoglie causa dell'errore HTTP-5xx del blocco precedente
waiting_cause && /message:/ {
    cause = extract_cause($0)
    register_error("HTTP-" pending_status, pending_logger, cause, pending_ts)
    waiting_cause = 0
    next
}

# Chiusura blocco senza trovare message: — registra senza causa
waiting_cause && /^}/ {
    register_error("HTTP-" pending_status, pending_logger, "(causa non estratta)", pending_ts)
    waiting_cause = 0
    next
}

# Pattern 1: riga JBoss con status= 5xx nel messaggio
/^[0-9][0-9][0-9][0-9]-/ && /status= *5[0-9][0-9]/ {
    pending_logger = short_logger($4)
    if (match($0, /status= *([0-9]+)/, sm)) pending_status = sm[1]+0
    else pending_status = 500
    pending_ts = $1 " " $2
    waiting_cause = 1
    next
}

# Pattern 2: riga JBoss con Exception o caused by nel messaggio diretto
/^[0-9][0-9][0-9][0-9]-/ && /[Ee]xception|[Cc]aused [Bb]y:/ {
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
    # Riduci la stringa eliminando progressivamente "...caused by: XXX caused by:"
    # finché rimane solo l'ultimo blocco "caused by: <root-cause>"
    last = ""
    # Cerca l'ultima "caused by:" rimuovendo tutto ciò che la precede
    while (match(c, /[Cc]aused [Bb]y: */) ) {
        c = substr(c, RSTART + RLENGTH)  # avanza dopo "caused by: "
        last = c
    }
    if (last != "") {
        # Tronca al primo { o newline
        gsub(/[{}\n].*$/, "", last)
        gsub(/[ \t]+$/, "", last)
        return substr(last, 1, 100)
    }
    # Fallback: prima ExceptionClass: messaggio
    if (match(c, /([A-Za-z.]+[Ee]xception)[: ]+([^\n{]+)/, ex)) {
        gsub(/[ \t]+$/, "", ex[2])
        return substr(ex[1] ": " ex[2], 1, 100)
    }
    # Ultimo fallback: rimuovi prefisso logger e prendi i primi 80 char
    sub(/^[0-9-]+ [0-9:,]+ [A-Z]+ +\[[^\]]+\] \([^)]+\) /, "", c)
    gsub(/[ \t]+$/, "", c)
    return substr(c, 1, 80)
}

function register_error(type, logger, cause, ts,    key) {
    key = type SUBSEP cause
    if (!(key in cause_count)) {
        cause_type[key]   = type
        cause_logger[key] = logger
        cause_ts[key]     = ts
        cause_text[key]   = cause
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
    for (i = 1; i <= n; i++) {
        for (j = i+1; j <= n; j++) {
            if (cause_count[keys[j]] > cause_count[keys[i]]) {
                tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
            }
        }
    }

    printf "%-10s  %-28s  %5s  %s\n", "TIPO", "CLASSE", "CNT", "ROOT CAUSE"
    printf "%-10s  %-28s  %5s  %s\n", \
        "──────────", "────────────────────────────", "─────", \
        "──────────────────────────────────────────────────────────────"
    for (i = 1; i <= n; i++) {
        k = keys[i]
        printf "%-10s  %-28s  %5d  %s\n",
            cause_type[k],
            substr(cause_logger[k], 1, 28),
            cause_count[k],
            substr(cause_text[k], 1, 62)
    }
    printf "\nTotale errori applicativi: %d (%d cause distinte)\n", total, n
}
