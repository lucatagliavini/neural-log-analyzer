# Statistiche GC dal gc.log JVM G1GC.
# Estrae: tipo pausa, durata, heap before/after, frequenza.
# Parametri: -v time_window="2h|30m|"
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
        heap_max    = hm[3]+0
    }

    # Durata pausa in ms
    pause_ms = 0
    if (match($0, /([0-9]+\.[0-9]+)ms$/, pm))
        pause_ms = pm[1]+0

    # Timestamp ISO8601
    ts = ""
    if (match($0, /\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})/, tm)) ts = tm[1]

    gc_count++
    total_pause_ms += pause_ms
    total_freed    += (heap_before - heap_after)
    if (pause_ms > max_pause_ms) { max_pause_ms = pause_ms; max_pause_ts = ts }

    type_count[pause_type]++
    type_pause[pause_type] += pause_ms

    printf "[%s]  %-8s  before=%4dM  after=%4dM  freed=%4dM  pause=%.1fms\n",
        ts, pause_type, heap_before, heap_after, heap_before-heap_after, pause_ms
}

END {
    if (gc_count == 0) { print "Nessun evento GC trovato."; exit }
    print ""
    print "── Riepilogo ─────────────────────────────────"
    printf "Totale GC events:    %d\n",         gc_count
    printf "Totale pausa:        %.1f ms\n",     total_pause_ms
    printf "Pausa media:         %.1f ms\n",     total_pause_ms / gc_count
    printf "Pausa massima:       %.1f ms (%s)\n", max_pause_ms, max_pause_ts
    printf "Memoria liberata:    %d M totale\n", total_freed
    print ""
    for (t in type_count)
        printf "  %-12s  %3d events  avg %.1f ms\n", t, type_count[t], type_pause[t]/type_count[t]
}
