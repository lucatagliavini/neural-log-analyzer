# Statistiche GC dal gc.log JVM G1GC.
# Estrae: tipo pausa, durata, heap before/after, frequenza.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#            -v verbose="1"    (mostra righe grezze oltre al riepilogo)
#
# Formato: [ISO8601][uptime][loglevel][tag] GC(N) ...

BEGIN {
    gc_count = 0
    SLOW_MS = 200; VERYSLOW_MS = 500
}

# Riga di riepilogo GC: "Pause Young ... 1769M->1293M(2159M) 9.671ms"
/Pause (Young|Full|Mixed)/ && /[0-9]+M->[0-9]+M/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_gc($1))) next
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

    if (verbose == "1") {
        buf_ts[gc_count]     = ts
        buf_type[gc_count]   = pause_type
        buf_before[gc_count] = heap_before
        buf_after[gc_count]  = heap_after
        buf_pause[gc_count]  = pause_ms
    }
}

END {
    if (gc_count == 0) { print "Nessun evento GC trovato."; exit }

    avg_ms = total_pause_ms / gc_count
    col_max = (max_pause_ms >= VERYSLOW_MS) ? RED : (max_pause_ms >= SLOW_MS) ? YELLOW : ""
    col_avg = (avg_ms       >= VERYSLOW_MS) ? RED : (avg_ms       >= SLOW_MS) ? YELLOW : ""

    print ""
    print "── Riepilogo ─────────────────────────────────"
    printf "Totale GC events:    %d\n",                          gc_count
    printf "Totale pausa:        %.1f ms\n",                     total_pause_ms
    printf "Pausa media:         %s%.1f ms%s\n",                 col_avg, avg_ms, (col_avg!="") ? RESET : ""
    printf "Pausa massima:       %s%.1f ms%s  (%s)\n",           col_max, max_pause_ms, (col_max!="") ? RESET : "", max_pause_ts
    printf "Memoria liberata:    %d M totale\n\n",               total_freed

    for (t in type_count) {
        tavg = type_pause[t] / type_count[t]
        tc   = (tavg >= VERYSLOW_MS) ? RED : (tavg >= SLOW_MS) ? YELLOW : DIM
        printf "  %-12s  %3d events  avg %s%.1f ms%s\n", t, type_count[t], tc, tavg, RESET
    }

    if (verbose == "1") {
        print ""
        print "── Dettaglio eventi ──────────────────────────"
        for (i = 1; i <= gc_count; i++) {
            pm = buf_pause[i]
            pc = (pm >= VERYSLOW_MS) ? RED : (pm >= SLOW_MS) ? YELLOW : ""
            printf "[%s]  %-8s  before=%4dM  after=%4dM  freed=%4dM  pause=%s%.1fms%s\n",
                buf_ts[i], buf_type[i], buf_before[i], buf_after[i],
                buf_before[i]-buf_after[i], pc, pm, (pc!="") ? RESET : ""
        }
    }
}
