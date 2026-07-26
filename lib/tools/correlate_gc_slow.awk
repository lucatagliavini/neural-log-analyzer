# Correla pause GC con richieste lente nell'access log.
# Uso: awk -f correlate_gc_slow.awk gc.log access.log
# Parametri: -v threshold_ms="500"
#
# Strategia: costruisce una lista di finestre GC (inizio±pausa+margine),
# poi verifica quante richieste lente cadono in quelle finestre.

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 500
    gc_margin_s = 2  # finestra di correlazione: ±2 secondi dalla pausa GC
    gc_n = 0
}

# Fase 1: file gc.log — raccoglie timestamp e durata pause
FILENAME ~ /gc/ && /Pause (Young|Full|Mixed)/ && /[0-9]+\.[0-9]+ms$/ {
    if (match($0, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T([0-9][0-9]):([0-9][0-9]):([0-9][0-9])/, tm)) {
        h = tm[1]+0; m = tm[2]+0; s = tm[3]+0
        gc_ts[++gc_n] = h*3600 + m*60 + s
    }
    if (match($0, /([0-9]+\.[0-9]+)ms$/, pm))
        gc_dur[gc_n] = pm[1]+0
    else
        gc_dur[gc_n] = 0
}

# Fase 2: file access.log — verifica richieste lente
FILENAME ~ /access|undertow/ {
    # Estrai tempo risposta
    if (!match($0, /" [0-9]+ [0-9]+ ([0-9]+) /, a)) next
    resp_ms = a[1] + 0
    if (resp_ms < threshold_ms + 0) next

    # Estrai ora dalla data
    if (!match($0, /:([0-9][0-9]):([0-9][0-9]):([0-9][0-9]) /, b)) next
    req_s = b[1]*3600 + b[2]*60 + b[3]+0

    # Cerca correlazione con una pausa GC
    correlated = 0
    for (i = 1; i <= gc_n; i++) {
        diff = req_s - gc_ts[i]
        if (diff < 0) diff = -diff
        if (diff <= gc_margin_s) { correlated = 1; gc_hit[i]++; break }
    }

    total_slow++
    if (correlated) correlated_count++

    if (correlated && correlated_count <= 20) {
        if (match($0, /"([A-Z]+) ([^ ]+) HTTP/, c))
            printf "CORRELATA  %d ms  %s %s\n", resp_ms, c[1], substr(c[2],1,60)
    }
}

END {
    print ""
    printf "Richieste lente (>%d ms): %d\n", threshold_ms, total_slow+0
    pct_corr = total_slow > 0 ? correlated_count*100/total_slow : 0
    printf "Di cui correlate a pausa GC (±%ds): %d (%.0f%%)\n",
        gc_margin_s, correlated_count+0, pct_corr
    printf "Pause GC analizzate: %d\n", gc_n
}
