# Mostra le ultime N righe di un log Guidewire con colorazione WARN/ERROR.
# Parametri: -v tail_n="50"
#
# Formato Guidewire: [thread] USER YYYY-MM-DDTHH:MM:SS,mmm LEVEL messaggio

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    GW_RE = "([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]+) (ERROR|WARN|INFO|DEBUG|TRACE)"
}

{ buf[count % n] = $0; count++ }

END {
    shown = (count < n) ? count : n
    start = (count >= n) ? count - n : 0

    nerror = 0; nwarn = 0; ninfo = 0
    for (i = start; i < count; i++) {
        line = buf[i % n]
        if (match(line, GW_RE, lv)) {
            if      (lv[2] == "ERROR") nerror++
            else if (lv[2] == "WARN")  nwarn++
            else if (lv[2] == "INFO")  ninfo++
        }
    }

    for (i = start; i < count; i++) {
        line = buf[i % n]
        color = ""
        if (match(line, GW_RE, lv)) {
            if      (lv[2] == "ERROR") color = RED
            else if (lv[2] == "WARN")  color = YELLOW
        }
        if (color != "")
            printf "%s%s%s\n", color, line, RESET
        else
            print line
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
