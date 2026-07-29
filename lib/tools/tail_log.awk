# Mostra le ultime N righe del log (implementazione tail in AWK).
# Parametri: -v tail_n="50"

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    RED = "\033[31m"; YELLOW = "\033[33m"; DIM = "\033[2m"; RESET = "\033[0m"
}

{ buf[count % n] = $0; count++ }

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
