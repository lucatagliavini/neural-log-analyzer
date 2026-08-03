# Mostra le ultime N righe del log (implementazione tail in AWK).
# Parametri: -v tail_n="50"
#            -v log_kind="access|server"  (seleziona il parser per il filtro temporale)
#            -v time_from/time_to         (vuoti = nessun filtro, tail grezzo)
#
# NB: time_from/time_to sono passati solo quando la query nomina un tempo
# esplicito (vedi TIME_EXPLICIT in chatbot.sh) — altrimenti restano vuoti e
# in_range() diventa un no-op, mantenendo il tail grezzo del file corrente.

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    last_line_in_range = 1  # righe di stack trace (senza timestamp proprio) eredita lo stato della riga precedente
}

{
    if (time_from != "" || time_to != "") {
        if (log_kind == "server") {
            if (parse_server_log())
                last_line_in_range = in_range(parse_server(_ts_date, _ts_time))
            # righe senza timestamp (stack frame) mantengono last_line_in_range
        } else {
            last_line_in_range = in_range(parse_access($2))
        }
        if (!last_line_in_range) next
    }
    buf[count % n] = $0; count++
}

END {
    shown = (count < n) ? count : n
    start = (count >= n) ? count - n : 0

    # Conta livelli nelle righe del buffer (formato JBoss/Guidewire: campo 3 = livello)
    nerror = 0; nwarn = 0; ninfo = 0
    for (i = start; i < count; i++) {
        line = buf[i % n]
        if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}[, ][0-9]+ (ERROR|WARN|INFO)/, lv)) {
            if      (lv[1] == "ERROR") nerror++
            else if (lv[1] == "WARN")  nwarn++
            else                       ninfo++
        }
    }

    for (i = start; i < count; i++) {
        line = buf[i % n]
        if (match(line, /" ([0-9]{3}) /, sc)) {
            pfx = substr(sc[1], 1, 1)
            if      (pfx == "5") printf "%s%s%s\n", RED,    line, RESET
            else if (pfx == "4") printf "%s%s%s\n", YELLOW, line, RESET
            else                 print line
        } else {
            print line
        }
    }

    printf "\n%s── Ultimi %d di %d righe totali", DIM, shown, count
    if (nerror + nwarn + ninfo > 0) {
        printf " —"
        if (nerror > 0) printf " %s%d ERROR%s", RED,    nerror, RESET DIM
        if (nwarn  > 0) printf " %s%d WARN%s",  YELLOW, nwarn,  RESET DIM
        if (ninfo  > 0) printf " %d INFO", ninfo
    }
    printf " ──%s\n", RESET
}
