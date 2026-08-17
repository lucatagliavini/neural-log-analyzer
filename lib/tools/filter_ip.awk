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
    # Soglie da domain.conf via dispatch.sh (UI-13), fallback ai valori storici.
    REQ_WARN = (req_time_warn_ms != "") ? req_time_warn_ms+0 : 1000
    REQ_CRIT = (req_time_crit_ms != "") ? req_time_crit_ms+0 : 2000
}

{
    # Ordine dei filtri: `index()` sull'IP prima di parse_access(). index() è
    # una ricerca di sottostringa senza regex — molto più economica di mktime()
    # — e in modalità IP singolo scarta la grande maggioranza delle righe.
    # In modalità top-clients (ip_filter vuoto) l'ordine è irrilevante: servono
    # tutte le righe.
    if (ip_filter != "" && index($0, ip_filter) == 0) next
    if ((time_from != "" || time_to != "") && !in_range(access_ts())) next

    ip = access_ip()

    # UNA sola estrazione di status e tempo per riga, riusata da entrambi i
    # rami. Prima la regex dello status girava fino a 3 volte sulla stessa riga
    # (una per scegliere il printf — con risultato mai usato, vedi sotto — una
    # per status_count, una per ip_status) e quella del tempo 2 volte.
    # Nel ramo di stampa il match serviva a calcolare `st` e `color`, che poi
    # NON venivano usati: i due printf stampavano entrambi `$0` invariato. Il
    # commento diceva "sostituisce il codice status con versione colorata" ma
    # la sostituzione non c'era — codice morto rimosso (2026-08-06).
    _st = access_status(); has_st = (_st != "")
    st = has_st ? _st : ""
    _ms = access_time_ms(); has_ms = (_ms >= 0)
    ms = has_ms ? _ms : 0

    # O6: `count`/`ip_count` contano le RICHIESTE, `ms_count`/`ip_ms_count`
    # solo quelle di cui si è potuto MISURARE il tempo. La media va divisa per
    # il secondo, non per il primo: una riga senza campo tempo estraibile
    # contribuisce 0 al numeratore, e usarla nel denominatore sottostima il
    # risultato (100ms su 2 richieste, una malformata, dava 50ms invece di 100).
    #
    # Questo tool è l'unico dei sei esaminati ad avere il difetto, e la ragione
    # è strutturale: conta le righe con `index()` sull'IP, che non garantisce
    # nulla sul formato del resto della riga. slow_requests, service_times e
    # gc_stats arrivano al contatore solo dopo `match(...) || next`, quindi ogni
    # riga contata è già validata. In count_status e correlate_gc_slow il
    # denominatore su TUTTE le righe è invece VOLUTO (tasso di errore sul
    # traffico totale): correggerli sarebbe un bug, non un fix.
    if (ip_filter != "") {
        count++
        if (count <= max_rows) print $0
        if (has_st) status_count[st]++
        if (has_ms) { total_ms += ms; ms_count++ }
    } else {
        ip_count[ip]++
        if (has_st) ip_status[ip, st]++
        if (has_ms) { ip_ms[ip] += ms; ip_ms_count[ip]++ }
    }
}

END {
    if (ip_filter != "") {
        if (count == 0) {
            printf "Nessuna richiesta trovata per IP: %s\n", ip_filter
            exit
        }
        if (count > max_rows) printf "... (mostrate %d di %d)\n\n", max_rows, count
        printf "%s── Statistiche per IP %s ──%s\n", C_BOLD, ip_filter, C_RESET
        printf "Totale richieste: %d\n", count
        printf "Latenza media:    %.0f ms\n", (ms_count > 0 ? total_ms/ms_count : 0)
        # Trasparenza: se alcune righe non avevano un tempo misurabile, dirlo —
        # altrimenti una media calcolata su un sottoinsieme sembra calcolata su
        # tutto, ed è indistinguibile da un dato completo.
        if (ms_count < count)
            printf "%s  (media su %d richieste con tempo misurabile, %d senza)%s\n", \
                C_LBL, ms_count, count - ms_count, C_RESET
        printf "Distribuzione status:\n"
        for (s in status_count) {
            color = (substr(s,1,1)=="5") ? C_CRIT : (substr(s,1,1)=="4") ? C_WARN : ""
            rst   = (color != "") ? C_RESET : ""
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
            avg = (ip_ms_count[ip] > 0 ? ip_ms[ip]/ip_ms_count[ip] : 0)
            col_avg = (avg >= REQ_CRIT) ? C_CRIT : (avg >= REQ_WARN) ? C_WARN : C_VAL
            printf "%-18s  %s%9d%s  %s%8.2f%s\n", ip, C_VAL, ip_count[ip], C_RESET, col_avg, avg, C_RESET
        }
        printf "\nTop %d di %d IP distinti\n", limit, n
    }
}
