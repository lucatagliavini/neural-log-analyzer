# Filtra righe ERROR e WARN dal server.log JBoss/WildFly/WebSphere.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Gestisce stack trace multiriga: ogni frame "at ..." viene riconosciuto come
# continuazione dell'eccezione precedente, non come errore distinto.
# Mostra: messaggio eccezione + prime 3 righe at + "... N frame omessi"
#
# Dipende da: utils-colors.awk, utils-jboss.awk (o formato alternativo),
#             utils-dedup.awk, utils-time.awk

BEGIN {
    FS = " "; max_rows = 50
    in_exc = 0; exc_omitted = 0
}

function norm_key(msg,    k) {
    # Rimuove "Exception in thread \"...\": " per fare collassare istanze dello stesso errore
    # lanciate da thread diversi (pattern JBoss/stderr).
    k = msg
    sub(/^Exception in thread "[^"]*" /, "", k)
    return substr(k, 1, 80)
}

function flush_exception(    dk, full_msg, f) {
    if (!in_exc) return
    if (exc_level == "ERROR") nerror++
    else nwarn++
    count++

    full_msg = exc_msg
    for (f = 1; f <= exc_frame_n && f <= 3; f++)
        full_msg = full_msg "\n    " exc_frame[f]
    if (exc_omitted > 0)
        full_msg = full_msg "\n    " C_LBL "... (" exc_omitted " frame omessi)" C_RESET

    dk = exc_level SUBSEP norm_key(exc_msg)
    dedup_add(dk, exc_level, full_msg, exc_ts, exc_log)

    in_exc = 0; exc_frame_n = 0; exc_omitted = 0
    delete exc_frame
}

/ERROR|WARN/ {
    if (!parse_server_log()) next
    if ((time_from != "" || time_to != "") && !in_range(parse_server(_ts_date, _ts_time))) next
    level = _level
    msg   = _msg

    if (is_stack_frame(msg)) {
        if (in_exc) {
            sub(/^\t/, "", msg)
            exc_frame_n++
            if (exc_frame_n <= 3)
                exc_frame[exc_frame_n] = substr(msg, 1, 100)
            else
                exc_omitted++
        }
        next
    }

    if (msg == "") next

    flush_exception()

    in_exc      = 1
    exc_level   = level
    exc_msg     = msg
    exc_ts      = _ts
    exc_log     = _logger
    exc_frame_n = 0; exc_omitted = 0
}

END {
    flush_exception()

    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
        exit
    }

    dedup_sort()
    dedup_print(max_rows)

    if (_dup_n > max_rows) printf "... (mostrati %d di %d errori distinti)\n", max_rows, _dup_n
    printf "Totale: %s%d ERROR%s, %s%d WARN%s (%d distinti)\n", \
        C_CRIT, nerror+0, C_RESET, C_WARN, nwarn+0, C_RESET, _dup_n
}
