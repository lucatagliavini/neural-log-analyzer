# Filtra richieste per indirizzo IP sorgente dall'access log.
# Cerca sia nel primo campo (IP diretto) sia nella catena X-Forwarded-For.
# Parametri: -v ip_filter="172.30.169.1"
#            -v time_window="2h|30m|"

BEGIN {
    FS = " "
    count = 0
    max_rows = 50
    if (ip_filter == "") {
        print "[WARN] ip_filter non specificato — mostro tutte le richieste" > "/dev/stderr"
    }
}

{
    if (ip_filter != "" && index($0, ip_filter) == 0) next

    count++
    if (count <= max_rows) print $0

    # Accumula statistiche
    if (match($0, /" ([0-9]{3}) /, a)) status_count[a[1]]++
    if (match($0, /" [0-9]+ [0-9]+ ([0-9]+) /, b)) total_ms += b[1]+0
}

END {
    if (count == 0) {
        printf "Nessuna richiesta trovata per IP: %s\n", ip_filter
        exit
    }
    if (count > max_rows) printf "... (mostrate %d di %d)\n\n", max_rows, count
    printf "── Statistiche per IP %s ──\n", ip_filter
    printf "Totale richieste: %d\n", count
    printf "Latenza media:    %.0f ms\n", count > 0 ? total_ms/count : 0
    printf "Distribuzione status:\n"
    for (s in status_count) printf "  %s: %d\n", s, status_count[s]
}
