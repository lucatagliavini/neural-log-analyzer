# Correla pause GC con richieste lente nell'access log.
# Uso: awk -f correlate_gc_slow.awk gc.log access.log
# Parametri: -v threshold_ms="500"  -v max_rows="20"
#
# GCCORR-1 (2026-08-25): il tool originale rispondeva solo «esiste una pausa
# entro ±gc_margin_s?» — con Young G1 frequenti, quasi ogni istante soddisfa
# quella condizione, quindi la percentuale tende al 100% per DENSITÀ
# temporale, non per causalità. Qui si aggiunge un gruppo di controllo (le
# richieste VELOCI) e si giudica sul LIFT — quante volte più correlate le
# lente rispetto alle veloci sullo stesso traffico — non sulla densità grezza.
# Il verdetto ha quattro stati, non due: «non discriminabile» quando manca un
# controllo attendibile, «GC pervasivo» quando la copertura temporale delle
# pause è così alta che la vicinanza non discrimina più nulla. Collassare
# questi due casi su «non è la causa» sarebbe un'assoluzione senza prove.
#
# gc_at[sec] è l'indice della pausa più vicina (non solo un flag): il tool ora
# dichiara QUALE pausa, di che tipo, quanto lunga, quanto prima/dopo, e con
# quali regioni G1 — dato che prima veniva scartato di proposito.
#
# Indice per secondo, non scansione lineare: la ricerca è O(richieste ×
# 2·margin) invece di O(richieste × pause_GC) — su dati reali 18665 × 543 ≈ 10
# milioni di iterazioni evitate (misurato 2026-08-06). La correlazione
# booleana (parte B, baseline) è memoizzata per secondo — dipende solo dal
# secondo, non dalla richiesta — mentre l'attribuzione (parte A) resta non
# memoizzata: riguarda solo le richieste lente, che sono poche.

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 500
    gc_margin_s = 2
    max_rows = (max_rows != "") ? max_rows+0 : 20

    # Soglie da domain.conf via dispatch.sh (UI-13), fallback ai valori storici.
    CORR_WARN = (gc_corr_warn_pct != "") ? gc_corr_warn_pct+0 : 10
    CORR_CRIT = (gc_corr_crit_pct != "") ? gc_corr_crit_pct+0 : 30
    REQ_CRIT  = (req_time_crit_ms != "") ? req_time_crit_ms+0 : 5000
    # Lift: quante volte più correlate le lente rispetto alle veloci. 1,0 = il
    # GC non discrimina, è solo denso nel tempo.
    LIFT_WARN = (gc_corr_lift_warn != "") ? gc_corr_lift_warn+0 : 1.5
    LIFT_CRIT = (gc_corr_lift_crit != "") ? gc_corr_lift_crit+0 : 3.0
    # Copertura temporale oltre la quale la vicinanza a una pausa non è più
    # discriminante: quasi ogni istante ne ha una vicina per costruzione.
    COVER_SAT = (gc_corr_cover_sat_pct != "") ? gc_corr_cover_sat_pct+0 : 80

    gc_n = 0
}

# ── Fase 0: righe regione G1, associate al GC(N) più recente ────────────────
# Stesso guard di lib/tools/gc_stats.awk (principio 8 — centralizzare significa
# migrare TUTTI i chiamanti della stessa assunzione, non solo il tool nuovo):
# GC(N) non è univoco, riparte da 0 al restart JVM e fra le rotazioni
# concatenate da open_gc_logs, quindi senza un guard di prossimità temporale un
# vecchio GC(N) riuserebbe le regioni di un evento diverso — e qui,
# diversamente da gc_stats, diventerebbe un numero STAMPATO per una pausa che
# non è la sua. `next` esclude queste righe dalla Fase 2: già oggi ci
# arriverebbero morte su access_time_ms()<0 (ogni regex access è ancorata su
# `"`), quindi il comportamento sulle righe access non cambia.
/GC\([0-9]+\) Eden regions:/    { match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                   _pend_ts[_gc_id] = parse_gc($1)
                                   match($0, /Eden regions: ([0-9]+)->([0-9]+)\(([0-9]+)\)/, r)
                                   _eden[_gc_id] = r[2]+0; _eden_cap[_gc_id] = r[3]+0
                                   next }
/GC\([0-9]+\) Survivor regions:/{ match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                   _pend_ts[_gc_id] = parse_gc($1)
                                   match($0, /Survivor regions: ([0-9]+)->([0-9]+)/, r)
                                   _surv[_gc_id] = r[2]+0
                                   next }
/GC\([0-9]+\) Old regions:/     { match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                   _pend_ts[_gc_id] = parse_gc($1)
                                   match($0, /Old regions: ([0-9]+)->([0-9]+)/, r)
                                   _old[_gc_id] = r[2]+0
                                   next }
/GC\([0-9]+\) Humongous regions:/{ match($0, /GC\(([0-9]+)\)/, g); _gc_id = g[1]
                                   _pend_ts[_gc_id] = parse_gc($1)
                                   match($0, /Humongous regions: ([0-9]+)->([0-9]+)/, r)
                                   _hum[_gc_id] = r[2]+0
                                   next }

# ── Fase 1: righe di pausa nel gc.log — indicizza QUALE pausa, non solo SE ──
# parse_gc() restituisce epoch Unix completo (data+ora) — corretto su log
# multi-giorno. in_range() applica il filtro time_from/time_to della query.
/Pause (Young|Full|Mixed)/ && /[0-9]+\.[0-9]+ms$/ {
    ts = parse_gc($1)
    # parse_gc puo' restituire -1 su timestamp non riconoscibile: "== 0" non
    # lo intercetta, e gc_at[-1] verrebbe creato silenziosamente (letto solo
    # dopo "in", ma comunque una pausa fantasma nel conteggio finale).
    if (ts <= 0) next
    if ((time_from != "" || time_to != "") && !in_range(ts)) next

    match($0, /GC\(([0-9]+)\)/, gi); gid = gi[1]+0
    match($0, /Pause (Young|Full|Mixed)/, pt); pause_type = pt[1]
    sub_cause = ""
    if (match($0, /\(([^)]+)\) [0-9]+M->/, sc)) {
        sub_cause = sc[1]
        gsub(/G1 /, "", sub_cause)
    }
    match($0, /([0-9]+\.[0-9]+)ms$/, pm); dur = pm[1]+0
    hms = ""
    if (match($0, /T([0-9]{2}:[0-9]{2}:[0-9]{2})/, tm)) hms = tm[1]

    gc_n++
    p_ts[gc_n] = ts; p_hms[gc_n] = hms
    p_type[gc_n] = pause_type; p_sub[gc_n] = sub_cause; p_dur[gc_n] = dur

    # Pending accettato solo se dello stesso evento (stesso gid RIUSATO da un
    # restart/rotazione precedente avrebbe un _pend_ts molto più vecchio).
    if ((gid in _pend_ts) && (ts - _pend_ts[gid] <= 2)) {
        p_eden[gc_n] = _eden[gid]+0; p_eden_cap[gc_n] = _eden_cap[gid]+0
        p_surv[gc_n] = _surv[gid]+0
        p_old[gc_n]  = _old[gid]+0
        p_hum[gc_n]  = _hum[gid]+0
    } else {
        p_eden[gc_n] = 0; p_eden_cap[gc_n] = 0
        p_surv[gc_n] = 0
        p_old[gc_n]  = 0
        p_hum[gc_n]  = 0
    }
    delete _eden[gid]; delete _eden_cap[gid]; delete _surv[gid]
    delete _old[gid]; delete _hum[gid]; delete _pend_ts[gid]

    # gc_at[sec] = indice della pausa più LUNGA in quel secondo (non solo un
    # flag: al tool ora serve sapere quale pausa, non solo se ce n'è una).
    # Obbligatorio leggere gc_at[ts] solo DOPO "in": un lookup diretto su
    # chiave assente la CREA in gawk con valore vuoto, e ogni "in gc_at"
    # successivo la troverebbe già presente — su ±2s per centinaia di
    # migliaia di richieste il danno sarebbe totale.
    if (!(ts in gc_at) || p_dur[gc_at[ts]] < dur) gc_at[ts] = gc_n
}

# correlated_at(epoch) — esiste una pausa entro ±gc_margin_s? Memoizzata per
# secondo: la risposta dipende solo dal secondo, non dalla richiesta, quindi
# richieste diverse nello stesso secondo condividono il risultato — usata sia
# per le lente che per il gruppo di controllo (le veloci), che sono la
# maggioranza del traffico.
function correlated_at(epoch,    d, c) {
    if (epoch in corr_memo) return corr_memo[epoch]
    c = 0
    for (d = 0; d <= gc_margin_s; d++) {
        if (((epoch - d) in gc_at) || ((epoch + d) in gc_at)) { c = 1; break }
    }
    corr_memo[epoch] = c
    return c
}

# attribute_pause(epoch) — indice della pausa più vicina, con segno del delta
# in _att_delta (side effect: awk non restituisce due valori). I due rami sono
# SEPARATI, non in ||: il codice originale (lib/tools/correlate_gc_slow.awk,
# prima di GCCORR-1) usava `||` in corto circuito e perdeva il segno. A parità
# di distanza vince il ramo "prima" (epoch-d): è il solo causalmente
# plausibile — una pausa dopo la richiesta non può averla resa lenta.
function attribute_pause(epoch,    d) {
    for (d = 0; d <= gc_margin_s; d++) {
        if ((epoch - d) in gc_at) { _att_delta = -d; return gc_at[epoch - d] }
        if ((epoch + d) in gc_at) { _att_delta = d;  return gc_at[epoch + d] }
    }
    _att_delta = 0
    return 0
}

# ── Fase 2: righe access log — richieste lente E gruppo di controllo ───────
# Pattern di contenuto (non FILENAME: i .gz sono aperti da dispatch.sh via
# process substitution, che assegna a FILENAME un path privo di "gc"/"access").
!/Pause (Young|Full|Mixed)/ {
    resp_ms = access_time_ms()
    if (resp_ms < 0) next

    req_epoch = access_ts()
    if (req_epoch == 0) next
    if ((time_from != "" || time_to != "") && !in_range(req_epoch)) next

    total_requests++
    if (req_min_epoch == 0 || req_epoch < req_min_epoch) req_min_epoch = req_epoch
    if (req_epoch > req_max_epoch) req_max_epoch = req_epoch

    correlated = correlated_at(req_epoch)

    if (resp_ms >= threshold_ms + 0) {
        total_slow++
        if (correlated) {
            correlated_count++

            # Attribuzione: SEMPRE calcolata (alimenta le aggregazioni per
            # pausa/tipo), a prescindere da se questa riga viene anche
            # stampata come CORRELATA — sono conteggi additivi, non
            # percentuali: ogni lenta si attribuisce a una sola pausa, quindi
            # non riproducono il difetto "quasi tutto correlato al ~100%".
            pi = attribute_pause(req_epoch)
            if (pi > 0) {
                delta = _att_delta
                att_n[pi]++; att_delta[pi] += delta
                type_att[p_type[pi]]++; type_ms[p_type[pi]] += p_dur[pi]
            }

            if (correlated_count <= max_rows) {
                method = access_method()
                if (method != "") {
                    # Il metodo HTTP è una CATEGORIA, non una gravità (UI-12).
                    method_color = C_TAG
                    color = (resp_ms >= REQ_CRIT) ? C_CRIT : C_WARN
                    extra = ""
                    if (pi > 0)
                        extra = sprintf("  ·  %s %s%.0f ms%s  " "\xce\x94" "%+ds", \
                            p_type[pi], C_LBL, p_dur[pi], C_RESET, delta)
                    printf "%sCORRELATA%s  %s%d ms%s  %s%s%s %s%s\n", \
                        color, C_RESET, color, resp_ms, C_RESET, method_color, method, C_RESET, access_url(), extra
                }
            }
        }
    } else {
        total_fast++
        if (correlated) corr_fast++
    }
}

END {
    if (total_requests == 0) { print "Nessuna richiesta access log trovata."; exit }

    pct_corr = total_slow > 0 ? correlated_count*100/total_slow : 0
    col_pct  = (pct_corr >= CORR_CRIT) ? C_CRIT : (pct_corr >= CORR_WARN) ? C_WARN : ""

    # ── Copertura temporale: unione degli intervalli ±gc_margin_s sulla
    # finestra osservata. Complementare al lift (pesato sul traffico): un
    # picco a raffiche può avere lift alto e copertura bassa, o viceversa — è
    # quella divergenza a essere informativa, non solo il numero singolo.
    for (i = 1; i <= gc_n; i++) sorted_ts[i] = p_ts[i]
    for (i = 2; i <= gc_n; i++) {
        v = sorted_ts[i]; j = i - 1
        while (j >= 1 && sorted_ts[j] > v) { sorted_ts[j+1] = sorted_ts[j]; j-- }
        sorted_ts[j+1] = v
    }
    covered = 0; have_cur = 0
    for (i = 1; i <= gc_n; i++) {
        s = sorted_ts[i] - gc_margin_s; e = sorted_ts[i] + gc_margin_s
        if (!have_cur) { cur_start = s; cur_end = e; have_cur = 1; continue }
        if (s > cur_end) { covered += cur_end - cur_start + 1; cur_start = s; cur_end = e }
        else if (e > cur_end) cur_end = e
    }
    if (have_cur) covered += cur_end - cur_start + 1

    if (time_from != "" && time_to != "") window = parse_iso(time_to) - parse_iso(time_from) + 1
    else if (req_min_epoch > 0 && req_max_epoch >= req_min_epoch) window = req_max_epoch - req_min_epoch + 1
    else window = 0

    cover_computable = (window > 0)
    pct_cover = cover_computable ? covered*100/window : 0
    if (pct_cover > 100) pct_cover = 100

    # ── Verdetto a quattro stati (GCCORR-1) ──────────────────────────────────
    # Il gruppo di controllo sono le richieste VELOCI, non tutto il traffico:
    # un baseline su tutte le richieste includerebbe le lente stesse, e il
    # lift si autoannullerebbe (→1) proprio quando il problema è grave.
    # Campione minimo da tabella di contingenza (attesa ≥5), non una soglia
    # arbitraria: scala col traffico.
    #
    # PERVASIVE si controlla PRIMA del campione minimo, non dopo: la copertura
    # è calcolata dal solo gc.log (nessuna dipendenza da corr_fast/pct_fast), e
    # proprio nello scenario che questo stato descrive — pause così dense da
    # toccare quasi ogni istante — pct_fast tende a 100%, il che fa collassare
    # exp2 verso 0 e farebbe fallire il campione minimo per costruzione. Se il
    # guard fosse controllato prima, il caso più pervasivo darebbe sempre
    # «non discriminabile» invece di «pervasivo»: il collasso dei due esiti
    # positivi che questo quarto stato esiste per evitare (misurato con una
    # fixture di pause ogni 3s: pct_fast=100%, exp2=0, PERVASIVE atteso).
    # pct_fast è una statistica descrittiva del solo gruppo di controllo
    # (serve solo total_fast>0): la riga "Gruppo di controllo" deve poterla
    # stampare correttamente anche con zero richieste lente (total_slow=0),
    # caso in cui il campione minimo — che riguarda invece total_slow — non
    # è nemmeno definito. Tenerli distinti evita che l'assenza di lente
    # spenga anche la percentuale del solo gruppo di controllo.
    have_control  = (total_fast > 0)
    if (have_control) pct_fast = corr_fast / total_fast

    min_sample_ok = 0
    if (have_control && total_slow > 0) {
        exp1 = pct_fast * total_slow
        exp2 = total_slow - exp1
        min_sample_ok = (exp1 >= 5 && exp2 >= 5)
        if (min_sample_ok) lift = (pct_corr/100) / pct_fast
    }

    if (cover_computable && pct_cover >= COVER_SAT) {
        verdict_state = "PERVASIVE"
    } else if (!min_sample_ok) {
        verdict_state = "NODISC"
    } else if (pct_corr >= CORR_CRIT && lift >= LIFT_CRIT) {
        verdict_state = "CRIT"
    } else if (pct_corr >= CORR_WARN && lift >= LIFT_WARN) {
        verdict_state = "WARN"
    } else {
        verdict_state = "NONCAUSE"
    }

    if (verdict_state == "NODISC") {
        verdetto = "GC: correlazione NON DISCRIMINABILE (manca un gruppo di controllo attendibile)"
        col_verdetto = C_INFO
    } else if (verdict_state == "PERVASIVE") {
        verdetto = "GC PERVASIVO — la vicinanza a una pausa non discrimina qui"
        col_verdetto = C_INFO
    } else if (verdict_state == "CRIT") {
        verdetto = "GC E' PROBABILE CAUSA della lentezza"
        col_verdetto = C_CRIT
    } else if (verdict_state == "WARN") {
        verdetto = "GC CONTRIBUISCE alla lentezza"
        col_verdetto = C_WARN
    } else {
        verdetto = "GC NON e' la causa principale"
        col_verdetto = C_OK
    }

    printf "\n%s%s%s  (%.0f%% correlato su %d richieste lente)\n\n", \
        col_verdetto, verdetto, C_RESET, pct_corr, total_slow+0

    if (total_fast > 0)
        printf "Gruppo di controllo (richieste veloci): %s%d/%d%s (%.0f%%)\n", \
            C_VAL, corr_fast+0, total_fast+0, C_RESET, pct_fast*100

    if (min_sample_ok) {
        printf "Lift: %s%.1f\xc3\x97%s", C_VAL, lift, C_RESET
        if (cover_computable)
            printf "   \xc2\xb7   copertura temporale delle pause: %s%.0f%%%s della finestra\n", C_VAL, pct_cover, C_RESET
        else
            printf "\n"
    } else if (cover_computable) {
        printf "Copertura temporale delle pause: %s%.0f%%%s della finestra\n", C_VAL, pct_cover, C_RESET
    }

    printf "\nRichieste lente (>%d ms): %s%d/%d%s\n", \
        threshold_ms, C_VAL, total_slow+0, total_requests+0, C_RESET
    printf "Di cui correlate a pausa GC (\xc2\xb1%ds): %s%d (%.0f%%)%s\n", \
        gc_margin_s, col_pct, correlated_count+0, pct_corr, (col_pct!="") ? C_RESET : ""
    printf "%sPause GC analizzate: %d%s\n", C_LBL, gc_n, C_RESET

    if (correlated_count > max_rows)
        printf "%s(mostrate le prime %d di %d richieste correlate)%s\n", \
            C_LBL, max_rows, correlated_count+0, C_RESET

    # ── Pause GC coinvolte (quali pause hanno prodotto richieste lente) ─────
    n_att = 0
    for (i = 1; i <= gc_n; i++) if (att_n[i] > 0) n_att++

    if (n_att > 0) {
        print ""
        print C_BOLD "\xe2\x94\x80\xe2\x94\x80 Pause GC coinvolte \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" C_RESET
        shown = 0
        for (i = 1; i <= gc_n; i++) {
            if (att_n[i] == 0) continue
            shown++
            if (shown > max_rows) continue

            label = p_type[i]
            if (p_sub[i] != "") label = label " (" p_sub[i] ")"
            avg_delta = att_delta[i] / att_n[i]
            word = (att_n[i] == 1) ? "lenta" : "lente"

            regions = ""
            if (p_eden_cap[i] > 0) regions = regions sprintf("  Eden %d/%d", p_eden[i]+0, p_eden_cap[i]+0)
            if (p_old[i]  > 0)     regions = regions sprintf("  Old %d",  p_old[i]+0)
            if (p_hum[i]  > 0)     regions = regions sprintf("  Hum %d",  p_hum[i]+0)

            printf "  %s%-8s%s  %s%-20s%s  %s%5.0f ms%s  \xe2\x86\x92 %s%d%s %s  (\xce\x94 medio %+.1fs)%s\n", \
                C_LBL, p_hms[i], C_RESET, C_VAL, label, C_RESET, C_VAL, p_dur[i], C_RESET, \
                C_VAL, att_n[i], C_RESET, word, avg_delta, regions
        }
        if (n_att > max_rows)
            printf "  %s(mostrate le prime %d di %d, per richieste attribuite)%s\n", \
                C_LBL, max_rows, n_att, C_RESET

        # ── Attribuzione per tipo di pausa ──────────────────────────────────
        print ""
        print C_BOLD "\xe2\x94\x80\xe2\x94\x80 Attribuzione per tipo di pausa \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" C_RESET
        for (t in type_att) {
            word = (type_att[t] == 1) ? "lenta" : "lente"
            printf "  %-8s  %s%3d%s %s   pausa totale %s%.0f ms%s\n", \
                t, C_VAL, type_att[t], C_RESET, word, C_VAL, type_ms[t], C_RESET
        }
    }
    print ""
}
