# Filtra richieste per indirizzo IP sorgente dall'access log.
# Se ip_filter è specificato: mostra le richieste di quell'IP + statistiche.
# Se ip_filter è vuoto: modalità top-clients — classifica IP per volume.
# Parametri: -v ip_filter="172.30.169.1"   (vuoto = top-clients)
#            -v time_window="2h|30m|"
#            -v top_n="10"                  (solo modalità top-clients)

BEGIN {
    FS = " "
    if (top_n == "") top_n = 10
    max_rows = 50
}

{
    if (ip_filter != "" && index($0, ip_filter) == 0) next

    # Estrae IP dal primo campo
    ip = $1

    if (ip_filter != "") {
        # ── Modalità filtro su IP specifico ──────────────────────────────────
        count++
        if (count <= max_rows) print $0
        if (match($0, /" ([0-9]{3}) /, a)) status_count[a[1]]++
        if (match($0, /" [0-9]+ [0-9]+ ([0-9]+)/, b)) total_ms += b[1]+0
    } else {
        # ── Modalità top-clients: accumula per IP ─────────────────────────────
        ip_count[ip]++
        if (match($0, /" ([0-9]{3}) /, a)) ip_status[ip, a[1]]++
        if (match($0, /" [0-9]+ [0-9]+ ([0-9]+)/, b)) ip_ms[ip] += b[1]+0
    }
}

END {
    if (ip_filter != "") {
        # ── Output modalità filtro ────────────────────────────────────────────
        if (count == 0) {
            printf "Nessuna richiesta trovata per IP: %s\n", ip_filter
            exit
        }
        if (count > max_rows) printf "... (mostrate %d di %d)\n\n", max_rows, count
        printf "── Statistiche per IP %s ──\n", ip_filter
        printf "Totale richieste: %d\n", count
        printf "Latenza media:    %.0f ms\n", (count > 0 ? total_ms/count : 0)
        printf "Distribuzione status:\n"
        for (s in status_count) printf "  %s: %d\n", s, status_count[s]

    } else {
        # ── Output modalità top-clients ───────────────────────────────────────
        if (length(ip_count) == 0) {
            print "Nessuna richiesta trovata nel log."
            exit
        }

        # Ordina per conteggio decrescente (selection sort su array sparso)
        n = 0
        for (ip in ip_count) { sorted_ip[++n] = ip }
        for (i = 1; i <= n; i++)
            for (j = i+1; j <= n; j++)
                if (ip_count[sorted_ip[j]] > ip_count[sorted_ip[i]]) {
                    tmp = sorted_ip[i]; sorted_ip[i] = sorted_ip[j]; sorted_ip[j] = tmp
                }

        printf "%-18s  %8s  %8s\n", "IP", "RICHIESTE", "AVG MS"
        printf "%-18s  %8s  %8s\n", "──────────────────", "─────────", "──────"
        limit = (n < top_n ? n : top_n)
        for (i = 1; i <= limit; i++) {
            ip = sorted_ip[i]
            avg = (ip_count[ip] > 0 ? ip_ms[ip]/ip_count[ip] : 0)
            printf "%-18s  %8d  %8.0f\n", ip, ip_count[ip], avg
        }
        printf "\nTop %d di %d IP distinti\n", limit, n
    }
}
