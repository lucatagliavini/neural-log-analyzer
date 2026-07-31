# Statistiche GC dal gc.log JVM G1GC.
# Estrae: tipo pausa, durata, heap before/after, regioni, percentili, timeline.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"

BEGIN {
    gc_count = 0
    SLOW_MS = 200; VERYSLOW_MS = 500

    # Granularità timeline adattiva in base alla finestra temporale richiesta.
    # Obiettivo: produrre sempre un numero di bucket utile alla lettura (10-50).
    # Con finestra assente (log intero ~24h) usa 30 min come default.
    # La formula usa la durata in minuti e mira a ~48 bucket come target.
    if (time_from != "" && time_to != "") {
        ts_f = parse_iso(time_from)
        ts_t = parse_iso(time_to)
        window_min = (ts_t - ts_f) / 60
        if      (window_min <=  30) BUCKET_MIN = 1
        else if (window_min <=  60) BUCKET_MIN = 2
        else if (window_min <= 120) BUCKET_MIN = 5
        else if (window_min <= 360) BUCKET_MIN = 10
        else if (window_min <= 720) BUCKET_MIN = 15
        else                        BUCKET_MIN = 30
    } else {
        BUCKET_MIN = 30
    }
}

# ── Raccolta dati regioni per GC(N) corrente ─────────────────────────────────
/GC\([0-9]+\) Eden regions:/   { match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                  match($0, /Eden regions: ([0-9]+)->([0-9]+)\(([0-9]+)\)/, r)
                                  _eden_used[_gc_id] = r[2]+0; _eden_cap[_gc_id] = r[3]+0 }
/GC\([0-9]+\) Survivor regions:/{ match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                  match($0, /Survivor regions: ([0-9]+)->([0-9]+)/, r)
                                  _surv[_gc_id] = r[2]+0 }
/GC\([0-9]+\) Old regions:/    { match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                  match($0, /Old regions: ([0-9]+)->([0-9]+)/, r)
                                  _old[_gc_id] = r[2]+0 }
/GC\([0-9]+\) Humongous regions:/{ match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                  match($0, /Humongous regions: ([0-9]+)->([0-9]+)/, r)
                                  _hum[_gc_id] = r[2]+0 }
/GC\([0-9]+\) Metaspace:/      { match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                  match($0, /Metaspace: ([0-9]+)K\([0-9]+K\)->([0-9]+)K\(([0-9]+)K\)/, r)
                                  _meta_used[_gc_id] = int(r[2]/1024); _meta_cap[_gc_id] = int(r[3]/1024) }

# ── Riga di riepilogo pausa ───────────────────────────────────────────────────
/Pause (Young|Full|Mixed)/ && /[0-9]+M->[0-9]+M/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_gc($1))) next

    match($0, /GC\(([0-9]+)\)/, gi); gid = gi[1]+0

    match($0, /Pause (Young|Full|Mixed)/, pt); pause_type = pt[1]
    sub_cause = ""
    if (match($0, /\(([^)]+)\) [0-9]+M->/, sc)) {
        sub_cause = sc[1]
        gsub(/G1 /, "", sub_cause)
    }

    match($0, /([0-9]+)M->([0-9]+)M\(([0-9]+)M\)/, hm)
    heap_before = hm[1]+0; heap_after = hm[2]+0; heap_cap = hm[3]+0

    match($0, /([0-9]+\.[0-9]+)ms$/, pm); pause_ms = pm[1]+0

    ts = ""
    if (match($0, /\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})/, tm)) ts = tm[1]

    gc_count++
    idx = gc_count
    total_pause_ms  += pause_ms
    total_freed     += (heap_before - heap_after)

    buf_ts[idx]     = ts; buf_type[idx] = pause_type; buf_cause[idx] = sub_cause
    buf_before[idx] = heap_before; buf_after[idx]  = heap_after; buf_cap[idx] = heap_cap
    buf_pause[idx]  = pause_ms
    buf_eden[idx]   = _eden_used[gid]+0; buf_eden_cap[idx] = _eden_cap[gid]+0
    buf_surv[idx]   = _surv[gid]+0
    buf_old[idx]    = _old[gid]+0
    buf_hum[idx]    = _hum[gid]+0
    buf_meta[idx]   = _meta_used[gid]+0; buf_meta_cap[idx] = _meta_cap[gid]+0

    type_count[pause_type]++
    type_pause[pause_type]  += pause_ms
    type_freed[pause_type]  += (heap_before - heap_after)

    if (pause_ms > max_pause_ms) { max_pause_ms = pause_ms; max_pause_ts = ts }

    # Bucket temporale per timeline (ogni BUCKET_MIN minuti)
    if (ts != "" && match(ts, /T([0-9]{2}):([0-9]{2})/, hm2)) {
        bh = hm2[1]+0; bm = int(hm2[2]/BUCKET_MIN)*BUCKET_MIN
        bk = sprintf("%02d:%02d", bh, bm)
        bkt_count[bk]++; bkt_pause[bk] += pause_ms
        bkt_heap[bk]  = heap_after   # ultimo heap after per bucket
        if (!(bk in bkt_first)) bkt_first[bk] = 1
    }
}

END {
    if (gc_count == 0) { print "Nessun evento GC trovato."; exit }

    # ── Percentili su array ordinato ─────────────────────────────────────────
    for (i = 1; i <= gc_count; i++) sorted_p[i] = buf_pause[i]
    # insertion sort (gc_count tipicamente < 2000, ok)
    for (i = 2; i <= gc_count; i++) {
        v = sorted_p[i]; j = i-1
        while (j >= 1 && sorted_p[j] > v) { sorted_p[j+1] = sorted_p[j]; j-- }
        sorted_p[j+1] = v
    }
    p50 = sorted_p[int(gc_count * 0.50) + 1]
    p95 = sorted_p[int(gc_count * 0.95) + 1]
    p99 = sorted_p[int(gc_count * 0.99) + 1]

    avg_ms  = total_pause_ms / gc_count
    col_max = (max_pause_ms >= VERYSLOW_MS) ? RED : (max_pause_ms >= SLOW_MS) ? YELLOW : ""
    col_avg = (avg_ms       >= VERYSLOW_MS) ? RED : (avg_ms       >= SLOW_MS) ? YELLOW : ""
    col_p95 = (p95          >= VERYSLOW_MS) ? RED : (p95          >= SLOW_MS) ? YELLOW : ""
    col_p99 = (p99          >= VERYSLOW_MS) ? RED : (p99          >= SLOW_MS) ? YELLOW : ""

    # ── Heap medio (after) ────────────────────────────────────────────────────
    heap_sum = 0
    for (i = 1; i <= gc_count; i++) heap_sum += buf_after[i]
    heap_avg = heap_sum / gc_count
    heap_cap_last = buf_cap[gc_count]

    # ── Medie regioni (ultimo evento disponibile) ─────────────────────────────
    # calcoliamo media pesata sugli eventi che hanno dati regioni
    eden_sum = 0; surv_sum = 0; old_sum = 0; hum_sum = 0; meta_sum = 0; reg_n = 0
    for (i = 1; i <= gc_count; i++) {
        if (buf_eden_cap[i] > 0) {
            eden_sum += buf_eden[i]; surv_sum += buf_surv[i]
            old_sum  += buf_old[i];  hum_sum  += buf_hum[i]
            meta_sum += buf_meta[i]; reg_n++
        }
    }

    # ── Riepilogo ─────────────────────────────────────────────────────────────
    print ""
    print BOLD "── Riepilogo GC ─────────────────────────────────────────────" RESET

    # Mostra il periodo analizzato: se filtrato dalla query usa time_from/to,
    # altrimenti mostra il range effettivo dei dati (primo e ultimo evento nel log).
    if (time_from != "" || time_to != "") {
        _pf = time_from; _pt = time_to
        gsub(/T/, " ", _pf); gsub(/T/, " ", _pt)
        if (_pf == "") _pf = "inizio log"
        if (_pt == "") _pt = "fine log"
        printf "  " DIM "Periodo:" RESET "  " WHT "%s" RESET "  " DIM "→" RESET "  " WHT "%s" RESET "\n\n", _pf, _pt
    } else {
        # Range effettivo: primo e ultimo timestamp nei dati raccolti
        _first = buf_ts[1]; _last = buf_ts[gc_count]
        gsub(/T/, " ", _first); gsub(/T/, " ", _last)
        if (_first != "" && _last != "")
            printf "  " DIM "Dati:    " RESET "  " WHT "%s" RESET "  " DIM "→" RESET "  " WHT "%s" RESET "  " DIM "(log completo)" RESET "\n\n", _first, _last
    }

    printf "  Totale eventi:    %d\n", gc_count
    printf "  Pausa totale:     %.1f ms\n", total_pause_ms
    printf "  Pausa media:      %s%.1f ms%s\n",   col_avg, avg_ms,      col_avg != "" ? RESET : ""
    printf "  Pausa massima:    %s%.1f ms%s  %s(%s)%s\n", \
        col_max, max_pause_ms, col_max != "" ? RESET : "", DIM, max_pause_ts, RESET
    printf "  p50 / p95 / p99:  %.1f ms  /  %s%.1f ms%s  /  %s%.1f ms%s\n", \
        p50, col_p95, p95, col_p95 != "" ? RESET : "", col_p99, p99, col_p99 != "" ? RESET : ""
    printf "  Memoria liberata: %d M totale\n", total_freed
    printf "  Heap medio after: %.0f M  (capacità %d M)\n\n", heap_avg, heap_cap_last

    # ── Per tipo pausa ────────────────────────────────────────────────────────
    print BOLD "── Per tipo di pausa ────────────────────────────────────────" RESET
    printf "  %-8s  %5s  %8s  %8s  %8s\n", "TIPO", "N", "AVG", "MAX", "FREED"
    printf "  %-8s  %5s  %8s  %8s  %8s\n", "────────", "─────", "────────", "────────", "────────"
    for (t in type_count) {
        tavg  = type_pause[t]  / type_count[t]
        tmax  = 0
        tfree = type_freed[t]
        for (i = 1; i <= gc_count; i++)
            if (buf_type[i] == t && buf_pause[i] > tmax) tmax = buf_pause[i]
        tc = (tavg >= VERYSLOW_MS) ? RED : (tavg >= SLOW_MS) ? YELLOW : ""
        printf "  %-8s  %5d  %s%7.1f ms%s  %7.1f ms  %5d M\n", \
            t, type_count[t], tc, tavg, tc != "" ? RESET : "", tmax, tfree
    }

    # ── Regioni G1 (medie) ────────────────────────────────────────────────────
    if (reg_n > 0) {
        print ""
        print BOLD "── Regioni G1 (media dopo GC) ───────────────────────────────" RESET
        printf "  Eden:       %4.0f regions\n",         eden_sum / reg_n
        printf "  Survivor:   %4.0f regions\n",         surv_sum / reg_n
        printf "  Old:        %4.0f regions\n",         old_sum  / reg_n
        printf "  Humongous:  %4.0f regions\n",         hum_sum  / reg_n
        if (meta_sum > 0)
            printf "  Metaspace:  %4.0f M usati (ultimo: %d M / %d M)\n", \
                meta_sum / reg_n, buf_meta[gc_count], buf_meta_cap[gc_count]
    }

    # ── Timeline heap + frequenza GC ─────────────────────────────────────────
    n_bkt = 0
    for (bk in bkt_count) bkt_keys[++n_bkt] = bk
    for (i = 2; i <= n_bkt; i++) {
        tk = bkt_keys[i]; j = i-1
        while (j >= 1 && bkt_keys[j] > tk) { bkt_keys[j+1] = bkt_keys[j]; j-- }
        bkt_keys[j+1] = tk
    }

    if (n_bkt > 0) {
        # scala heap per barra (max heap_cap_last)
        BAR_W = 24
        print ""
        printf BOLD "── Timeline heap (ogni %d min) ────────────────────────────────\n" RESET, BUCKET_MIN
        printf "  %-5s  %6s  %5s  %6s  %s\n", "ORA", "HEAP", "GC/p", "AVG ms", "HEAP AFTER"
        printf "  %-5s  %6s  %5s  %6s  %s\n", "─────", "──────", "─────", "──────", "──────────────────────────"
        for (i = 1; i <= n_bkt; i++) {
            bk   = bkt_keys[i]
            h    = bkt_heap[bk]+0
            cnt  = bkt_count[bk]
            bavg = bkt_pause[bk] / cnt
            bar_len = (heap_cap_last > 0) ? int(h * BAR_W / heap_cap_last) : 0
            bar = ""; for (k = 1; k <= bar_len; k++) bar = bar "▪"
            heap_pct = (heap_cap_last > 0) ? int(h * 100 / heap_cap_last) : 0
            hc = (heap_pct >= 85) ? RED : (heap_pct >= 70) ? YELLOW : ""
            printf "  %s  %s%5dM%s  %5d  %6.1f  %s%s%s\n", \
                bk, hc, h, hc != "" ? RESET : "", cnt, bavg, DIM, bar, RESET
        }
    }
    print ""
}
