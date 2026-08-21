# Aggrega i tempi di risposta per nome servizio.
# Sorgente: access log Undertow (stessa struttura di slow_requests).
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#            -v threshold_ms="0"   (filtra solo richieste sopra soglia, 0 = tutte)
#            -v svc_depth="N"      (componenti del path che identificano il
#                                   servizio; da SERVICE_PATH_DEPTH in system.conf)
#
# SVCGRAN-1: `svc_depth` non ha un default qui. Il numero di segmenti che
# identifica un servizio dipende da come è montata l'applicazione — una
# COORDINATA, non una capacità del tool (principio 7) — e ARCH-6 vieta i default
# impliciti nel codice: il guard sta in dispatch.sh, che rifiuta di invocare
# questo tool se il profilo non lo dichiara.
#
# Formato campi access log: IP [datetime] "METHOD /path HTTP/..." STATUS BYTES TIME_MS ...

BEGIN {
    FS = " "
    max_rows = 30
    if (threshold_ms == "") threshold_ms = 0
    # Soglie da domain.conf (UI-13), fallback ai valori storici. Sono molto più
    # alte di quelle del GC: 200ms per una chiamata a servizio è normale.
    SLOW_MS     = (svc_time_warn_ms != "") ? svc_time_warn_ms+0 : 2000
    VERYSLOW_MS = (svc_time_crit_ms != "") ? svc_time_crit_ms+0 : 5000
}

{
    if ((time_from != "" || time_to != "") && !in_range(access_ts())) next

    _ms = access_time_ms()
    if (_ms < 0) next
    ms = _ms
    if (ms < threshold_ms + 0) next

    _svc = access_url_service(svc_depth, svc_transparent)
    if (_svc == "") next
    svc = _svc

    svc_count[svc]++
    svc_total[svc] += ms
    if (ms > svc_max[svc]) svc_max[svc] = ms
    if (svc_min[svc] == "" || ms < svc_min[svc]) svc_min[svc] = ms
    buf_ms[svc, svc_count[svc]] = ms
}

function sev_color(v) {
    return (v >= VERYSLOW_MS) ? C_CRIT : (v >= SLOW_MS) ? C_WARN : C_VAL
}

# Calcola p50/p95/p99 per il servizio svc (n = svc_count[svc]) in _p50/_p95/_p99.
function svc_percentiles(svc, n,    i, tmp) {
    for (i = 1; i <= n; i++) tmp[i] = buf_ms[svc, i]
    asort(tmp)
    _p50 = tmp[int(n * 0.50) + 1]
    _p95 = tmp[int(n * 0.95) + 1]
    _p99 = tmp[int(n * 0.99) + 1]
}

END {
    # Il filtro temporale non ha potuto filtrare (nessun timestamp riconosciuto in
    # tutto il file): lo si DICE, invece di presentare dati non filtrati come se lo
    # fossero. Contropartita di in_range(epoch<=0)=1 in utils-time.awk.
    access_ts_format_warning()
    if (length(svc_count) == 0) {
        if (access_ts_period_ok()) print "Nessun dato trovato nell'access log."
        exit
    }

    # Raggruppamento DEGENERE: un solo servizio significa che la profondità
    # configurata non discrimina nulla su questi URL, e la tabella che segue è
    # l'access log intero con dei percentili addosso — una risposta ben formata
    # che non risponde. Va DETTO (SVCGRAN-1): il difetto è rimasto invisibile per
    # settimane proprio perché il tool non aveva modo di segnalarlo, ed è stato
    # trovato solo eseguendolo sui log di produzione e guardando l'output.
    #
    # La soglia è "un gruppo solo", non "pochi gruppi": due gruppi possono essere
    # la verità di un deployment con due servizi, uno solo non lo è mai —
    # raggruppare per una chiave costante non è raggruppare.
    if (length(svc_count) == 1) {
        for (s in svc_count) _only = s
        printf "%s⚠ Un solo servizio (%s): la profondità configurata (%s) non distingue nulla su questi URL.%s\n", \
            C_WARN, _only, (svc_depth == "" ? "?" : svc_depth), C_RESET
        printf "%s  I numeri sotto sono quindi quelli dell'intero access log, non di un servizio.%s\n", \
            C_LBL, C_RESET
        printf "%s  Alzare SERVICE_PATH_DEPTH in system.conf del profilo per separarli.%s\n\n", \
            C_LBL, C_RESET
    }

    col_svc = length("SERVIZIO")
    for (s in svc_count) if (length(s) > col_svc) col_svc = length(s)

    # Ordina per tempo medio decrescente
    n = 0
    for (s in svc_count) { keys[++n] = s; avgs[n] = svc_total[s]/svc_count[s] }
    for (i = 2; i <= n; i++) {
        tk = keys[i]; tv = avgs[i]; j = i-1
        while (j >= 1 && avgs[j] < tv) { keys[j+1]=keys[j]; avgs[j+1]=avgs[j]; j-- }
        keys[j+1] = tk; avgs[j+1] = tv
    }

    sep = ""; for (k = 1; k <= col_svc; k++) sep = sep "─"
    printf "%-*s  %6s  %8s  %8s  %8s  %8s  %8s  %8s\n", \
        col_svc, "SERVIZIO", "CALLS", "AVG ms", "MIN ms", "MAX ms", "p50 ms", "p95 ms", "p99 ms"
    printf "%-*s  %6s  %8s  %8s  %8s  %8s  %8s  %8s\n", \
        col_svc, sep, "──────", "────────", "────────", "────────", "────────", "────────", "────────"

    for (i = 1; i <= n && i <= max_rows; i++) {
        s   = keys[i]
        avg = svc_total[s] / svc_count[s]
        svc_percentiles(s, svc_count[s])
        col_min = sev_color(svc_min[s])
        col_avg = sev_color(avg)
        col_max = sev_color(svc_max[s])
        col_p50 = sev_color(_p50)
        col_p95 = sev_color(_p95)
        col_p99 = sev_color(_p99)
        printf "%-*s  %s%6d%s  %s%8.0f%s  %s%8d%s  %s%8d%s  %s%8.0f%s  %s%8.0f%s  %s%8.0f%s\n", \
            col_svc, s, C_VAL, svc_count[s], C_RESET, col_avg, avg, C_RESET, \
            col_min, svc_min[s], C_RESET, col_max, svc_max[s], C_RESET, \
            col_p50, _p50, C_RESET, col_p95, _p95, C_RESET, col_p99, _p99, C_RESET
    }
    if (n > max_rows) printf "... (mostrati %d di %d servizi)\n", max_rows, n
}
