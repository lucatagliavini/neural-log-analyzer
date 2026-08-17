# Correla pause GC con richieste lente nell'access log.
# Uso: awk -f correlate_gc_slow.awk gc.log access.log
# Parametri: -v threshold_ms="500"
#
# Strategia: indicizza per secondo gli istanti delle pause GC (gc_at), poi per
# ogni richiesta lenta verifica con (2*gc_margin_s+1) lookup se esiste una pausa
# vicina. Prima era una scansione lineare di TUTTE le pause per OGNI richiesta
# lenta — O(richieste_lente × pause_GC): su dati reali 18665 × 543 ≈ 10 milioni
# di iterazioni (2026-08-06). Equivalenza verificata su snapshot di produzione:
# 7 combinazioni soglia/finestra e le 20 righe di dettaglio, output identico.

BEGIN {
    FS = " "
    if (threshold_ms == "") threshold_ms = 500
    gc_margin_s = 2
    # Soglie da domain.conf via dispatch.sh (UI-13), fallback ai valori storici.
    # Le percentuali determinano anche il VERDETTO mostrato all'utente, non solo
    # il colore: alzarle rende il bot più prudente nell'attribuire la colpa al GC.
    CORR_WARN = (gc_corr_warn_pct != "") ? gc_corr_warn_pct+0 : 10
    CORR_CRIT = (gc_corr_crit_pct != "") ? gc_corr_crit_pct+0 : 30
    REQ_CRIT  = (req_time_crit_ms != "") ? req_time_crit_ms+0 : 5000
    gc_n = 0
}

# Fase 1: file gc.log — indicizza gli istanti delle pause.
# parse_gc() restituisce epoch Unix completo (data+ora) — corretto su log multi-giorno.
# in_range() applica il filtro time_from/time_to se impostato dalla query.
# NB: distinzione per pattern di contenuto, non per FILENAME — i file .gz sono aperti
# da dispatch.sh via process substitution (<(gunzip -c ...)), che assegna a FILENAME
# un percorso tipo /dev/fd/63 privo di "gc"/"access", rendendo un filtro su FILENAME
# silenziosamente inefficace sui log ruotati.
/Pause (Young|Full|Mixed)/ && /[0-9]+\.[0-9]+ms$/ {
    ts = parse_gc($1)
    if (ts == 0) next
    if ((time_from != "" || time_to != "") && !in_range(ts)) next

    # gc_n alimenta "Pause GC analizzate" nel report finale. Gli array gc_ts[]
    # e gc_dur[] sono stati rimossi (2026-08-06): servivano al loop lineare
    # sostituito dall'indice qui sotto, e la durata della pausa non è mai
    # entrata nell'output — restavano scritti e mai letti.
    gc_n++

    # Indice per secondo: gc_at[epoch] = 1 se in quell'istante c'è una pausa.
    # La correlazione cerca una pausa entro ±gc_margin_s secondi, quindi con
    # questo indice bastano (2*margin+1) lookup in tabella hash invece di
    # scandire tutte le pause per ogni richiesta lenta — il loop lineare era
    # O(richieste_lente × pause_GC): su dati reali 18665 × 543 ≈ 10 milioni di
    # iterazioni, misurate ~8s su ~18s totali (2026-08-06).
    # Basta un flag e non l'indice della pausa: al tool serve sapere SE esiste
    # una pausa vicina, non quale. Più pause nello stesso secondo collassano in
    # una sola voce, che è la semantica corretta per quella domanda.
    gc_at[ts] = 1
}

# Fase 2: file access.log — verifica richieste lente.
# parse_access() restituisce epoch Unix — stessa unità delle chiavi di gc_at[],
# quindi il confronto ±gc_margin_s è una somma di interi.
# Pattern di contenuto (non FILENAME, vedi nota Fase 1): una riga GC non ha mai il
# gruppo status/bytes/time tra virgolette dell'access log, quindi resta esclusa.
!/Pause (Young|Full|Mixed)/ {
    resp_ms = access_time_ms()
    if (resp_ms < 0) next

    req_epoch = access_ts()
    if (req_epoch == 0) next
    if ((time_from != "" || time_to != "") && !in_range(req_epoch)) next

    total_requests++
    if (resp_ms < threshold_ms + 0) next

    # Lookup nell'indice per secondo (vedi Fase 1): (2*margin+1) accessi a
    # tabella hash invece di scandire tutte le pause. Delta dal centro verso
    # l'esterno: si esce al primo trovato, quindi il risultato non dipende
    # dall'ordine delle pause nel file.
    correlated = 0
    for (d = 0; d <= gc_margin_s; d++) {
        if (((req_epoch - d) in gc_at) || ((req_epoch + d) in gc_at)) { correlated = 1; break }
    }

    total_slow++
    if (correlated) correlated_count++

    if (correlated && correlated_count <= 20) {
        method = access_method()
        if (method != "") {
            # Il metodo HTTP è una CATEGORIA, non una gravità: GET non è più "positivo"
            # di POST. Usa C_TAG, che un tema può differenziare da C_OK/C_ACCENT —
            # con C_OK, in un tema dove il verde è "esito positivo", GET sembrerebbe
            # un successo e POST un'entità (UI-12).
            method_color = C_TAG
            color = (resp_ms >= REQ_CRIT) ? C_CRIT : C_WARN
            printf "%sCORRELATA%s  %s%d ms%s  %s%s%s %s\n", \
                color, C_RESET, color, resp_ms, C_RESET, method_color, method, C_RESET, access_url()
        }
    }
}

END {
    pct_corr = total_slow > 0 ? correlated_count*100/total_slow : 0
    col_pct  = (pct_corr >= CORR_CRIT) ? C_CRIT : (pct_corr >= CORR_WARN) ? C_WARN : ""

    if (pct_corr >= CORR_CRIT)
        verdetto = "GC E' PROBABILE CAUSA della lentezza"
    else if (pct_corr >= CORR_WARN)
        verdetto = "GC CONTRIBUISCE alla lentezza"
    else
        verdetto = "GC NON e' la causa principale"

    printf "\n%s%s%s  (%.0f%% correlato su %d richieste lente)\n\n", \
        (col_pct != "") ? col_pct : C_BOLD, verdetto, C_RESET, pct_corr, total_slow+0

    printf "Richieste lente (>%d ms): %s%d/%d%s\n", \
        threshold_ms, C_VAL, total_slow+0, total_requests+0, C_RESET
    printf "Di cui correlate a pausa GC (±%ds): %s%d (%.0f%%)%s\n", \
        gc_margin_s, col_pct, correlated_count+0, pct_corr, (col_pct!="") ? C_RESET : ""
    printf "%sPause GC analizzate: %d%s\n", C_LBL, gc_n, C_RESET
}
