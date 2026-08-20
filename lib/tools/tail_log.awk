# Mostra le prime o le ultime N righe del log (implementazione head/tail in AWK).
# Parametri: -v tail_n="50"
#            -v log_kind="access|server"  (seleziona il parser per il filtro temporale)
#            -v time_from/time_to         (vuoti = nessun filtro, tail grezzo)
#            -v order="head|tail"         (default tail)
#
# NB: time_from/time_to sono passati solo quando la query nomina un tempo
# esplicito (vedi TIME_EXPLICIT in chatbot.sh) — altrimenti restano vuoti e
# in_range() diventa un no-op, mantenendo il tail grezzo del file corrente.
#
# order="head" stampa non appena raggiunge tail_n righe (in finestra, se
# presente) ed esce: niente buffer circolare, niente lettura del resto del
# file — su cc.log (~500.000 righe) sarebbe lavoro sprecato per un risultato
# che si conosce già dopo le prime N righe.

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    last_line_in_range = 1  # righe di stack trace (senza timestamp proprio) eredita lo stato della riga precedente
    head_mode = (order == "head")
    nerror = 0; nwarn = 0; ninfo = 0
}

function print_colored(line) {
    if (match(line, /" ([0-9]{3}) /, sc)) {
        pfx = substr(sc[1], 1, 1)
        if      (pfx == "5") printf "%s%s%s\n", C_CRIT,    line, C_RESET
        else if (pfx == "4") printf "%s%s%s\n", C_WARN, line, C_RESET
        else                 print line
    } else {
        print line
    }
}

# logline_parse() analizza $0: per una riga bufferizzata va assegnata a $0
# prima della chiamata (sicuro qui — il chiamante non usa più i campi
# correnti dopo, vedi la nota in tail_named_log.awk).
function count_level(line) {
    $0 = line
    if (logline_parse()) {
        if      (_ll_level == "ERROR") nerror++
        else if (_ll_level == "WARN")  nwarn++
        else if (_ll_level == "INFO")  ninfo++
    }
}

{
    if (time_from != "" || time_to != "") {
        if (log_kind == "server") {
            if (parse_server_log())
                last_line_in_range = in_range(parse_server(_ts_date, _ts_time))
            # righe senza timestamp (stack frame) mantengono last_line_in_range
        } else {
            last_line_in_range = in_range(access_ts())
        }
        if (!last_line_in_range) next
    }
    if (head_mode) {
        count_level($0)
        print_colored($0)
        count++
        if (count >= n) exit
    } else {
        buf[count % n] = $0; count++
    }
}

END {
    # Il filtro temporale non ha potuto filtrare (nessun timestamp riconosciuto in
    # tutto il file): lo si DICE, invece di presentare dati non filtrati come se lo
    # fossero. Contropartita di in_range(epoch<=0)=1 in utils-time.awk.
    access_ts_format_warning()
    if (head_mode) {
        printf "\n%s── Prime %d righe", C_LBL, count
        if (nerror + nwarn + ninfo > 0) {
            printf " —"
            if (nerror > 0) printf " %s%d ERROR%s", C_CRIT,    nerror, C_RESET C_LBL
            if (nwarn  > 0) printf " %s%d WARN%s",  C_WARN, nwarn,  C_RESET C_LBL
            if (ninfo  > 0) printf " %d INFO", ninfo
        }
        printf " ──%s\n", C_RESET
        exit
    }

    shown = (count < n) ? count : n
    start = (count >= n) ? count - n : 0

    # Conta livelli nelle righe del buffer (formato JBoss/applicativo custom: campo 3 = livello)
    for (i = start; i < count; i++) count_level(buf[i % n])

    for (i = start; i < count; i++) print_colored(buf[i % n])

    printf "\n%s── Ultimi %d di %d righe totali", C_LBL, shown, count
    if (nerror + nwarn + ninfo > 0) {
        printf " —"
        if (nerror > 0) printf " %s%d ERROR%s", C_CRIT,    nerror, C_RESET C_LBL
        if (nwarn  > 0) printf " %s%d WARN%s",  C_WARN, nwarn,  C_RESET C_LBL
        if (ninfo  > 0) printf " %d INFO", ninfo
    }
    printf " ──%s\n", C_RESET
}
