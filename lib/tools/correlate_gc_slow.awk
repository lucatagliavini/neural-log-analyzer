# Correla pause GC con richieste lente nell'access log.
# Uso: awk -f correlate_gc_slow.awk gc.log access.log
# Parametri: -v threshold_ms="500"
#
# Strategia: costruisce una lista di finestre GC (inizio±pausa+margine),
# poi verifica quante richieste lente cadono in quelle finestre.

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 500
    gc_margin_s = 2
    gc_n = 0
}

# Fase 1: file gc.log — raccoglie timestamp e durata pause.
# parse_gc() restituisce epoch Unix completo (data+ora) — corretto su log multi-giorno.
# in_range() applica il filtro time_from/time_to se impostato dalla query.
FILENAME ~ /gc/ && /Pause (Young|Full|Mixed)/ && /[0-9]+\.[0-9]+ms$/ {
    ts = parse_gc($1)
    if (ts == 0) next
    if ((time_from != "" || time_to != "") && !in_range(ts)) next

    gc_ts[++gc_n] = ts
    if (match($0, /([0-9]+\.[0-9]+)ms$/, pm))
        gc_dur[gc_n] = pm[1]+0
    else
        gc_dur[gc_n] = 0
}

# Fase 2: file access.log — verifica richieste lente.
# parse_access() restituisce epoch Unix — coerente con gc_ts[] per il diff ±gc_margin_s.
FILENAME ~ /access|undertow/ {
    if (!match($0, /" [0-9]+ [0-9]+ ([0-9]+) /, a)) next
    resp_ms = a[1] + 0
    if (resp_ms < threshold_ms + 0) next

    req_epoch = parse_access($2)
    if (req_epoch == 0) next
    if ((time_from != "" || time_to != "") && !in_range(req_epoch)) next

    correlated = 0
    for (i = 1; i <= gc_n; i++) {
        diff = req_epoch - gc_ts[i]
        if (diff < 0) diff = -diff
        if (diff <= gc_margin_s) { correlated = 1; gc_hit[i]++; break }
    }

    total_slow++
    if (correlated) correlated_count++

    if (correlated && correlated_count <= 20) {
        if (match($0, /"([A-Z]+) ([^ ]+) HTTP/, c)) {
            color = (resp_ms >= 5000) ? RED : YELLOW
            printf "%sCORRELATA%s  %s%d ms%s  %s %s\n", \
                color, RESET, color, resp_ms, RESET, c[1], c[2]
        }
    }
}

END {
    pct_corr = total_slow > 0 ? correlated_count*100/total_slow : 0
    col_pct  = (pct_corr >= 30) ? RED : (pct_corr >= 10) ? YELLOW : ""

    if (pct_corr >= 30)
        verdetto = "GC E' PROBABILE CAUSA della lentezza"
    else if (pct_corr >= 10)
        verdetto = "GC CONTRIBUISCE alla lentezza"
    else
        verdetto = "GC NON e' la causa principale"

    printf "\n%s%s%s  (%.0f%% correlato su %d richieste lente)\n\n", \
        (col_pct != "") ? col_pct : BOLD, verdetto, RESET, pct_corr, total_slow+0

    printf "Richieste lente (>%d ms): %d\n", threshold_ms, total_slow+0
    printf "Di cui correlate a pausa GC (±%ds): %s%d (%.0f%%)%s\n", \
        gc_margin_s, col_pct, correlated_count+0, pct_corr, (col_pct!="") ? RESET : ""
    printf "%sPause GC analizzate: %d%s\n", DIM, gc_n, RESET
}
