# Statistiche GC dal gc.log JVM G1GC.
# Estrae: tipo pausa, durata, heap before/after, frequenza.
# Parametri: -v time_window="2h|30m|"
#            -v verbose="1"    (mostra righe grezze oltre al riepilogo)
#
# Formato: [ISO8601][uptime][loglevel][tag] GC(N) ...

BEGIN { gc_count = 0 }

# Riga di riepilogo GC: "Pause Young ... 1769M->1293M(2159M) 9.671ms"
/Pause (Young|Full|Mixed)/ && /[0-9]+M->[0-9]+M/ {
    if (match($0, /Pause (Young|Full|Mixed)/, pt)) pause_type = pt[1]
    else pause_type = "Unknown"

    if (match($0, /([0-9]+)M->([0-9]+)M\(([0-9]+)M\)/, hm)) {
        heap_before = hm[1]+0
        heap_after  = hm[2]+0
    }

    pause_ms = 0
    if (match($0, /([0-9]+\.[0-9]+)ms$/, pm)) pause_ms = pm[1]+0

    ts = ""
    if (match($0, /\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})/, tm)) ts = tm[1]

    gc_count++
    total_pause_ms += pause_ms
    total_freed    += (heap_before - heap_after)
    if (pause_ms > max_pause_ms) { max_pause_ms = pause_ms; max_pause_ts = ts }

    type_count[pause_type]++
    type_pause[pause_type] += pause_ms

    # Bufferizza per output verbose
    buf_ts[gc_count]     = ts
    buf_type[gc_count]   = pause_type
    buf_before[gc_count] = heap_before
    buf_after[gc_count]  = heap_after
    buf_pause[gc_count]  = pause_ms
}

END {
    if (gc_count == 0) { print "Nessun evento GC trovato."; exit }

    print "── Riepilogo ─────────────────────────────────"
    printf "Totale GC events:    %d\n",          gc_count
    printf "Totale pausa:        %.1f ms\n",      total_pause_ms
    printf "Pausa media:         %.1f ms\n",      total_pause_ms / gc_count
    printf "Pausa massima:       %.1f ms (%s)\n", max_pause_ms, max_pause_ts
    printf "Memoria liberata:    %d M totale\n",  total_freed
    print ""
    for (t in type_count)
        printf "  %-12s  %3d events  avg %.1f ms\n", t, type_count[t], type_pause[t]/type_count[t]

    if (verbose == "1") {
        print ""
        print "── Dettaglio eventi ──────────────────────────"
        for (i = 1; i <= gc_count; i++)
            printf "[%s]  %-8s  before=%4dM  after=%4dM  freed=%4dM  pause=%.1fms\n",
                buf_ts[i], buf_type[i], buf_before[i], buf_after[i],
                buf_before[i]-buf_after[i], buf_pause[i]
    }
}
