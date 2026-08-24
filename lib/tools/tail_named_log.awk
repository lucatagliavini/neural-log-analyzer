# Mostra le prime o le ultime N righe di un log applicativo custom con
# colorazione WARN/ERROR.
# Parametri: -v tail_n="50"
#            -v order="head|tail"  (default tail)
#
# Il riconoscimento del livello è delegato a logline_parse() (utils-logline.awk):
# il formato è una proprietà del file, non un'assunzione di questo tool.
#
# order="head": stampa non appena raggiunge tail_n righe ed esce, niente
# buffer circolare — stesso ragionamento di tail_log.awk.
#
# Dipende da: utils-time.awk, utils-logline.awk, utils-colors.awk

BEGIN {
    if (tail_n == "" || tail_n+0 <= 0) tail_n = 50
    n = tail_n+0; count = 0
    head_mode = (order == "head")
    nerror = 0; nwarn = 0; ninfo = 0
}

# logline_parse() analizza $0: per una riga bufferizzata (non l'ultima letta)
# va assegnata a $0 prima della chiamata — sicuro qui, siamo in END o in una
# regola che non userà più i campi correnti dopo questa chiamata.
function print_colored(line,    color) {
    $0 = line
    color = ""
    if (logline_parse()) {
        if      (_ll_level == "ERROR") color = C_CRIT
        else if (_ll_level == "WARN")  color = C_WARN
    }
    if (color != "")
        printf "%s%s%s\n", color, line, C_RESET
    else
        print line
}

# count_level() vive in lib/utils-logline.awk, caricato prima di questo file
# (LVLCNT-1, 2026-08-24): questa funzione era duplicata BYTE PER BYTE qui e in
# tail_log.awk, e una terza variante in filter_errors.awk classificava per
# esclusione — dichiarando 46 WARN su un log che ne aveva 2. Tre copie, una
# divergente: il rimedio è non averne copie.

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
