# Filtra richieste per indirizzo IP sorgente dall'access log.
# Se ip_filter è specificato: mostra le richieste di quell'IP + statistiche.
# Se ip_filter è vuoto: modalità top-clients — classifica IP per volume.
# Parametri: -v ip_filter="172.30.169.1"   (vuoto = top-clients)
#            -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#            -v top_n="10"                  (solo modalità top-clients)

BEGIN {
    FS = " "
    if (top_n == "") top_n = 10
    max_rows = 50
    RED = "\033[31m"; YELLOW = "\033[33m"; BOLD = "\033[1m"; RESET = "\033[0m"
    DIM = "\033[2m"
}

{
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
    if (ip_filter != "" && index($0, ip_filter) == 0) next

    ip = $1

    if (ip_filter != "") {
        count++
        if (count <= max_rows) {
            if (match($0, /" ([0-9]{3}) /, sc)) {
                st = sc[1]
                color = (substr(st,1,1)=="5") ? RED : (substr(st,1,1)=="4") ? YELLOW : DIM
                # Sostituisce il codice status nella riga con versione colorata
                printf "%s\n", $0
            } else {
                print $0
            }
        }
        if (match($0, /" ([0-9]{3}) /, a)) status_count[a[1]]++
        if (match($0, /" [0-9]+ [0-9]+ ([0-9]+)/, b)) total_ms += b[1]+0
    } else {
        ip_count[ip]++
        if (match($0, /" ([0-9]{3}) /, a)) ip_status[ip, a[1]]++
        if (match($0, /" [0-9]+ [0-9]+ ([0-9]+)/, b)) ip_ms[ip] += b[1]+0
    }
}

END {
    if (ip_filter != "") {
        if (count == 0) {
            printf "Nessuna richiesta trovata per IP: %s\n", ip_filter
            exit
        }
        if (count > max_rows) printf "... (mostrate %d di %d)\n\n", max_rows, count
        printf "%s── Statistiche per IP %s ──%s\n", BOLD, ip_filter, RESET
        printf "Totale richieste: %d\n", count
        printf "Latenza media:    %.0f ms\n", (count > 0 ? total_ms/count : 0)
        printf "Distribuzione status:\n"
        for (s in status_count) {
            color = (substr(s,1,1)=="5") ? RED : (substr(s,1,1)=="4") ? YELLOW : ""
            rst   = (color != "") ? RESET : ""
            printf "  %s%s%s: %d\n", color, s, rst, status_count[s]
        }

    } else {
        if (length(ip_count) == 0) {
            print "Nessuna richiesta trovata nel log."
            exit
        }

        # Insertion sort per conteggio decrescente (O(n²) worst, O(n log n) medio)
        n = 0
        for (ip in ip_count) sorted_ip[++n] = ip
        for (i = 2; i <= n; i++) {
            tip = sorted_ip[i]; tv = ip_count[tip]; j = i-1
            while (j >= 1 && ip_count[sorted_ip[j]] < tv) {
                sorted_ip[j+1] = sorted_ip[j]; j--
            }
            sorted_ip[j+1] = tip
        }

        printf "%-18s  %9s  %8s\n", "IP", "RICHIESTE", "AVG MS"
        printf "%-18s  %9s  %8s\n", "──────────────────", "─────────", "────────"
        limit = (n < top_n ? n : top_n)
        for (i = 1; i <= limit; i++) {
            ip  = sorted_ip[i]
            avg = (ip_count[ip] > 0 ? ip_ms[ip]/ip_count[ip] : 0)
            col_avg = (avg >= 2000) ? RED : (avg >= 1000) ? YELLOW : ""
            rst_avg = (col_avg != "") ? RESET : ""
            printf "%-18s  %9d  %s%8.0f%s\n", ip, ip_count[ip], col_avg, avg, rst_avg
        }
        printf "\nTop %d di %d IP distinti\n", limit, n
    }
}
