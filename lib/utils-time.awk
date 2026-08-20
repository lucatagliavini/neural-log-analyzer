# utils-time.awk — funzioni di conversione timestamp e filtro temporale.
# Incluso con -f utils-time.awk da tutti i tool che supportano time_from/time_to.
#
# Parametri ricevuti via -v:
#   time_from="YYYY-MM-DDTHH:MM"   (vuoto = nessun limite inferiore)
#   time_to="YYYY-MM-DDTHH:MM"     (vuoto = nessun limite superiore)
#
# Funzioni esposte:
#   parse_iso(s)      → epoch seconds da "YYYY-MM-DDTHH:MM"
#   parse_access(s)   → epoch seconds da "[DD/Mon/YYYY:HH:MM:SS"
#   parse_server(s)   → epoch seconds da "YYYY-MM-DD HH:MM:SS,mmm"
#   parse_gc(s)       → epoch seconds da "[YYYY-MM-DDTHH:MM:SS"
#   in_range(epoch)   → 1 se epoch è nel range [ts_from, ts_to], 0 altrimenti

BEGIN {
    MONTHS["Jan"]=1; MONTHS["Feb"]=2;  MONTHS["Mar"]=3;  MONTHS["Apr"]=4
    MONTHS["May"]=5; MONTHS["Jun"]=6;  MONTHS["Jul"]=7;  MONTHS["Aug"]=8
    MONTHS["Sep"]=9; MONTHS["Oct"]=10; MONTHS["Nov"]=11; MONTHS["Dec"]=12

    ts_from = (time_from != "") ? parse_iso(time_from) : 0
    ts_to   = (time_to   != "") ? parse_iso(time_to)   : 99999999999
}

# Il campo del timestamp è individuato per file, non una volta per esecuzione: i
# tool ricevono più file insieme (corrente + rotazioni via select_log_files, e in
# correlate_gc_slow due sorgenti di formato diverso), e un file potrebbe avere un
# formato diverso dal precedente. Senza questo reset il campo del primo file
# "contaminerebbe" i successivi — con access_ts() il fallback lo correggerebbe
# comunque riga per riga, ma pagando la riscansione su ogni riga del secondo file.
#
# Vive qui e non nei tool perché utils-time.awk è caricato come primo -f da tutti
# (principio 2): un blocco FNR==1 in ogni tool sarebbe la stessa regola in 8 copie.
FNR == 1 { _ats_field = 0 }

# "YYYY-MM-DDTHH:MM" oppure "YYYY-MM-DDTHH:MM:SS"
function parse_iso(s,    parts, dp, tp) {
    if (split(s, parts, "T") < 2) return 0
    split(parts[1], dp, "-")
    split(parts[2], tp, ":")
    return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " (tp[3]+0))
}

# "[DD/Mon/YYYY:HH:MM:SS" (access log Undertow)
#
# Memoizzata su _pa_cache: l'access log ha timestamp al secondo e più richieste
# cadono nello stesso secondo — misurato su produzione 200986 righe / 10909
# secondi distinti, cioè 18.4 righe per secondo, quindi la cache evita ~95%
# delle chiamate a mktime() (che è la parte costosa: una syscall di conversione
# calendario). La cache è corretta per costruzione — stessa stringa timestamp,
# stesso epoch — e la sua dimensione è limitata dai secondi distinti nel file,
# non dalle righe.
# Aggiunta qui e non nei singoli tool perché parse_access() è usata da 8 tool
# (count_status, distribute_status, slow_requests, traffic_volume,
# service_times, filter_ip, correlate_gc_slow, tail_log): principio 2.
function parse_access(s,    parts, dp, key) {
    key = s
    if (key in _pa_cache) return _pa_cache[key]
    gsub(/[\[\]]/, "", s)
    # "27/Jul/2026:09:20:00"
    if (split(s, parts, ":") < 4) { _pa_cache[key] = 0; return 0 }
    split(parts[1], dp, "/")
    _pa_cache[key] = mktime(dp[3] " " MONTHS[dp[2]] " " dp[1]+0 " " parts[2] " " parts[3] " " parts[4]+0)
    return _pa_cache[key]
}

# access_ts() → epoch del timestamp della riga corrente di access log, 0 se la
# riga non ne ha uno riconoscibile.
#
# Trova il campo del timestamp per FORMA, non per posizione. Prima gli 8 tool
# scrivevano `parse_access($2)`, cablando l'assunzione che il timestamp sia il
# secondo campo: vero per il formato di Undertow osservato
# (`IP [17/Aug/2026:00:00:04 +0200] "GET ..." 200 ...`, verificato su prod/cert/
# test), ma il formato *combined* di Apache/WebSphere (`%h %l %u %t`) lo mette in
# $4 — e il fallimento sarebbe SILENZIOSO: parse_access() restituirebbe 0, il
# codice tratta 0 come "ignoto" e per il principio 5 include la riga, quindi il
# filtro temporale smetterebbe di filtrare senza dare errore (FORMAT-1).
#
# Riconoscere per forma è la stessa strategia già usata da
# _logfiles_read_first_ts() (utils-logfiles.sh), che identifica 4 formati di
# timestamp senza che nessuno sia configurato: nessuna variabile nuova da
# mantenere, e funziona su un formato mai visto prima invece di richiedere che
# qualcuno conti i campi del proprio log.
#
# Costo: la scansione avviene UNA VOLTA per file (ts_field viene memorizzato) —
# dalla seconda riga in poi si va diretti al campo noto, quindi il costo per riga
# è identico a prima. Il fallback rilegge tutti i campi solo sulle righe che non
# matchano il campo memorizzato (es. righe malformate), non su tutte.
function access_ts(    i, v) {
    # Campo già individuato per questo file: via diretta.
    if (_ats_field > 0) {
        v = parse_access($_ats_field)
        if (v > 0) return v
        # Il campo noto non ha prodotto un timestamp: riga malformata o formato
        # che cambia a metà file. Si ri-scandisce sotto invece di restituire 0 —
        # principio 5, non escludere per ignoranza.
    }
    for (i = 1; i <= NF; i++) {
        # La forma cercata è "[DD/Mon/YYYY:HH:MM:SS", con o senza la quadra:
        # abbastanza specifica da non collidere con IP, status o byte count.
        if ($i ~ /^\[?[0-9]{1,2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
            v = parse_access($i)
            if (v > 0) { _ats_field = i; return v }
        }
    }
    _ats_unmatched++
    return 0
}

# access_ts_ok() → 1 se in questo file è stato riconosciuto almeno un timestamp.
# Serve ai tool per DIRE che il formato non è quello atteso, invece di presentare
# un risultato non filtrato come se il filtro avesse funzionato (la lezione di
# LOGSEL-1c: "formato non riconosciuto" ≠ "nessuna riga trovata").
function access_ts_ok() {
    return (_ats_field > 0)
}

# "YYYY-MM-DD HH:MM:SS,mmm" (server.log)
function parse_server(date_s, time_s,    dp, tp) {
    split(date_s, dp, "-")
    split(time_s, tp, ":")
    return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " int(tp[3]))
}

# "[YYYY-MM-DDTHH:MM:SS" (gc.log)
function parse_gc(s) {
    gsub(/[\[\]]/, "", s)
    sub(/\+.*/, "", s)   # rimuove timezone "+0200"
    return parse_iso(s)
}

# in_range(epoch) → 1 se epoch cade nella finestra, 0 altrimenti.
#
# Un epoch ≤ 0 significa "istante IGNOTO", non "istante zero": è ciò che
# restituiscono access_ts()/parse_*() quando la riga non ha un timestamp
# riconoscibile. Viene INCLUSO, per il principio 5 (pruning conservativo): non
# sapere quando è avvenuta una riga non è una ragione per affermare che sia fuori
# dal periodo richiesto.
#
# Prima veniva escluso, perché `0 >= ts_from` è falso per qualunque finestra
# reale. La conseguenza era il difetto misurato in FORMAT-1: su un file di formato
# inatteso il tool rispondeva «Nessuna richiesta trovata nel periodo selezionato»
# — un falso negativo PIENO, indistinguibile da "ho guardato e non c'era nulla".
# FORMAT-1 ne ha rimosso la causa più frequente (il timestamp cercato per forma
# invece che per posizione) ma non questa scelta, che resta il comportamento su
# ogni riga che davvero non si sa datare.
#
# Il rovescio della medaglia — se NESSUNA riga del file è databile, il filtro non
# esclude più niente e un risultato non filtrato sembrerebbe filtrato — è
# presidiato da access_ts_format_warning(), che i tool chiamano nel loro END.
# Includere senza quel guard scambierebbe un falso negativo con un falso positivo.
function in_range(epoch) {
    if (time_from == "" && time_to == "") return 1
    if (epoch <= 0) return 1
    return (epoch >= ts_from && epoch <= ts_to)
}

# access_ts_unmatched() → quante righe non hanno prodotto un timestamp in questo
# file. Zero nel caso normale; un valore alto su un access log reale segnala
# righe malformate o un formato in parte diverso da quello atteso.
function access_ts_unmatched() {
    return _ats_unmatched + 0
}

# Traccia su file, a livello DEBUG, quante righe non si è saputo datare. Il file
# arriva da dispatch.sh (-v ats_debug_file) e vale solo con BOT_LOG_LEVEL=debug:
# senza la variabile questo END non fa nulla, quindi il costo nel caso normale è
# un confronto di stringa a fine esecuzione. Su file e non su stdout, che è il
# canale su cui asseriscono i test (principio 3).
#
# Serve a rendere MISURABILE la scelta di includere le righe non databili
# (in_range, sotto): se in produzione il numero è ~0 la decisione è gratuita, se è
# alto significa che su quei file il filtro temporale sta filtrando meno di quanto
# l'utente creda, e va rivista.
END {
    if (ats_debug_file != "" && _ats_unmatched > 0) {
        printf "[DEBUG] utils-time: %d righe su %d senza timestamp riconosciuto (incluse per principio 5)\n", \
               _ats_unmatched, NR >> ats_debug_file
    }
}

# access_ts_format_warning() → 1 (e stampa il messaggio) se il file ha righe, un
# filtro temporale è attivo e NESSUNA riga ha prodotto un timestamp: il filtro non
# ha potuto filtrare, quindi il risultato mostrato NON è quello chiesto e va detto.
# 0 (e nessun output) in tutti gli altri casi.
#
# È la contropartita necessaria di in_range(epoch<=0)=1 sopra: senza, il tool
# presenterebbe un file intero come se fosse il periodo richiesto. È anche la
# stessa distinzione già introdotta per grep_named_log da LOGSEL-1c — «formato non
# riconosciuto» ≠ «nessuna riga trovata» — qui applicata ai tool che leggono
# l'access log, che ne erano rimasti privi: access_ts_ok() esisteva da FORMAT-1 ma
# non aveva un solo chiamante (principio 8: la funzione condivisa era stata creata
# senza migrare chi doveva usarla).
#
# Vive qui e non in 7 copie nei tool perché utils-time.awk è caricato come primo
# -f da tutti (principio 2).
function access_ts_format_warning(    c_warn, c_reset) {
    if (time_from == "" && time_to == "") return 0
    if (NR == 0 || access_ts_ok()) return 0
    c_warn  = (C_WARN  != "") ? C_WARN  : ""
    c_reset = (C_RESET != "") ? C_RESET : ""
    printf "\n  %sFormato non riconosciuto: nessuna delle %d righe lette ha un timestamp di access log.%s\n", \
           c_warn, NR, c_reset
    printf "  Il filtro temporale non è stato applicato — il risultato non è limitato al periodo richiesto.\n\n"
    _ats_fmt_bad = 1
    return 1
}

# access_ts_period_ok() → 0 se il periodo richiesto NON è stato applicato (formato
# non riconosciuto), 1 altrimenti.
#
# I tool la usano per non stampare "Nessuna richiesta trovata NEL PERIODO
# SELEZIONATO" subito dopo aver detto che il periodo non è stato applicato: le due
# frasi insieme si contraddicono, e una contraddizione è peggio del falso negativo
# che questo lavoro elimina — l'utente non sa più a quale delle due credere.
function access_ts_period_ok() {
    return (_ats_fmt_bad + 0) == 0
}
