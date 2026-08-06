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
}

{
    # Ordine dei filtri: `index()` sull'IP prima di parse_access(). index() è
    # una ricerca di sottostringa senza regex — molto più economica di mktime()
    # — e in modalità IP singolo scarta la grande maggioranza delle righe.
    # In modalità top-clients (ip_filter vuoto) l'ordine è irrilevante: servono
    # tutte le righe.
    if (ip_filter != "" && index($0, ip_filter) == 0) next
    if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next

    ip = $1

    # UNA sola estrazione di status e tempo per riga, riusata da entrambi i
    # rami. Prima la regex dello status girava fino a 3 volte sulla stessa riga
    # (una per scegliere il printf — con risultato mai usato, vedi sotto — una
    # per status_count, una per ip_status) e quella del tempo 2 volte.
    # Nel ramo di stampa il match serviva a calcolare `st` e `color`, che poi
    # NON venivano usati: i due printf stampavano entrambi `$0` invariato. Il
    # commento diceva "sostituisce il codice status con versione colorata" ma
    # la sostituzione non c'era — codice morto rimosso (2026-08-06).
    has_st = match($0, /" ([0-9]{3}) /, _a)
    st = has_st ? _a[1] : ""
    has_ms = match($0, /" [0-9]+ [0-9-]+ ([0-9]+)/, _b)
    ms = has_ms ? _b[1]+0 : 0

    if (ip_filter != "") {
        count++
        if (count <= max_rows) print $0
        if (has_st) status_count[st]++
        if (has_ms) total_ms += ms
    } else {
        ip_count[ip]++
        if (has_st) ip_status[ip, st]++
        if (has_ms) ip_ms[ip] += ms
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
            col_avg = (avg >= 2000) ? RED : (avg >= 1000) ? YELLOW : WHT
            printf "%-18s  %s%9d%s  %s%8.2f%s\n", ip, WHT, ip_count[ip], RESET, col_avg, avg, RESET
        }
        printf "\nTop %d di %d IP distinti\n", limit, n
    }
}
