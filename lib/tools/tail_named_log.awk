# Mostra le prime o le ultime N righe di un log applicativo custom con
# colorazione WARN/ERROR.
# Parametri: -v tail_n="50"
#            -v order="head|tail"  (default tail)
#
# Formato (es. Guidewire nel profilo liquido): [thread] USER YYYY-MM-DDTHH:MM:SS,mmm LEVEL messaggio
#
# order="head": stampa non appena raggiunge tail_n righe ed esce, niente
# buffer circolare — stesso ragionamento di tail_log.awk.

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    GW_RE = "([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]+) (ERROR|WARN|INFO|DEBUG|TRACE)"
    head_mode = (order == "head")
    nerror = 0; nwarn = 0; ninfo = 0
}

function print_colored(line) {
    color = ""
    if (match(line, GW_RE, lv)) {
        if      (lv[2] == "ERROR") color = C_CRIT
        else if (lv[2] == "WARN")  color = C_WARN
    }
    if (color != "")
        printf "%s%s%s\n", color, line, C_RESET
    else
        print line
}

function count_level(line) {
    if (match(line, GW_RE, lv)) {
        if      (lv[2] == "ERROR") nerror++
        else if (lv[2] == "WARN")  nwarn++
        else if (lv[2] == "INFO")  ninfo++
    }
}

{
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
