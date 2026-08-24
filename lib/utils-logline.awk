# utils-logline.awk — riconoscimento della riga di log (timestamp + livello +
# messaggio) per FORMA, non per posizione — stessa strategia già usata per
# l'access log (access_ts(), FORMAT-1) e per la selezione dei file
# (_logfiles_read_first_ts() in lib/utils-logfiles.sh, di cui questo modulo è
# il gemello lato AWK: le due liste di grammatiche vanno mantenute in
# parità — verificata da tests/test-logline.sh, non dedotta a occhio).
#
# logline_parse() analizza $0 e imposta:
#   _ll_ts        "YYYY-MM-DD HH:MM:SS"  oppure  "HH:MM:SS"  ("" se non riconosciuto)
#   _ll_has_date  1 se _ll_ts porta un giorno, 0 se è solo ora
#   _ll_epoch     epoch, oppure -1 se _ll_has_date == 0 (non calcolabile)
#   _ll_level     ERROR|WARN|INFO|DEBUG|TRACE  ("" se assente dalla riga)
#   _ll_msg       resto della riga dopo timestamp (e livello, se presente)
# Ritorna 1 se una grammatica ha riconosciuto la riga, 0 altrimenti — valori
# neutri, non un fallimento (principio 5): sta al chiamante decidere se
# scartare la riga o includerla senza livello.
#
# Dipende da: utils-time.awk, caricato PRIMA di questo file — si riusano
# parse_access(), parse_gc(), parse_server(), parse_iso() per l'epoch. Nessun
# mktime() diretto qui: resta un solo punto di conversione calendario.

BEGIN {
    # Byte ESC (0x1b) via sprintf: un letterale \033 dentro una regex ERE non
    # è portabile fra le implementazioni di gawk, sprintf("%c",27) lo è.
    _ll_esc = sprintf("%c", 27)
    _ll_ansi_re = _ll_esc "\\[[0-9;]*m"
}

# ORDINE DELLA TABELLA = CONTRATTO (LOGF-9, stessa motivazione del gemello
# bash a utils-logfiles.sh:83). Ogni ramo sotto è commentato sul PERCHÉ di
# quella posizione, non va dedotto né riordinato senza aggiornare il commento.
function logline_parse(    line, a) {
    # STRIP ANSI come primo passo, su una COPIA locale — mai su $0: chi stampa
    # la riga colorata (print_colored in tail_log.awk/tail_named_log.awk) ha
    # bisogno dei byte originali. console.log (profilo usnext) apre ogni riga
    # con un reset ANSI reale (ESC[0m...): senza lo strip qualunque grammatica
    # ancorata a ^ fallirebbe — non solo quella time-only sotto, qualunque log
    # preceduto da un codice colore avrebbe lo stesso problema.
    line = $0
    gsub(_ll_ansi_re, "", line)

    _ll_ts = ""; _ll_has_date = 0; _ll_epoch = -1; _ll_level = ""; _ll_msg = ""

    # 1) Access log Undertow: IP [DD/Mon/YYYY:HH:MM:SS +ZZZZ] "..." — nessun
    #    livello testuale (access_status() lo deriva dal codice HTTP, non da
    #    questa riga: quella è una responsabilità di utils-access-*.awk, non
    #    di questo modulo). Primo perché è il formato più frequente nei log
    #    misti che search_all_logs attraversa (l'access log è la maggioranza
    #    dei file su entrambi i profili).
    if (match(line, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}) [+-][0-9]{4}\]/, a)) {
        _ll_epoch = parse_access(a[1])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            _ll_ts = strftime("%Y-%m-%d %H:%M:%S", _ll_epoch)
            _ll_msg = substr(line, RSTART + RLENGTH)
            sub(/^ /, "", _ll_msg)
            return 1
        }
    }

    # 2) GC log: [YYYY-MM-DDTHH:MM:SS.mmm+ZZZZ] — precede il ramo ISO custom
    #    (4 sotto) per la stessa ragione del gemello bash
    #    (utils-logfiles.sh:90-91): è il ramo più specifico, richiede la
    #    parentesi quadra che il formato Guidewire non ha mai. In pratica le
    #    due forme non collidono (millisecondi con punto qui, con virgola
    #    lì), ma l'ordine resta quello del gemello per non introdurre una
    #    seconda fonte di verità sulla precedenza.
    if (match(line, /\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?[+-][0-9]{4})\]/, a)) {
        _ll_epoch = parse_gc(a[1])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            _ll_ts = strftime("%Y-%m-%d %H:%M:%S", _ll_epoch)
            _ll_msg = substr(line, RSTART + RLENGTH)
            sub(/^ /, "", _ll_msg)
            return 1
        }
    }

    # 3) Server log JBoss, ANCORATO a inizio riga: YYYY-MM-DD HH:MM:SS,mmm
    #    LEVEL [logger] (thread) messaggio. L'ancora è deliberata: senza ^
    #    questa forma collide con il ramo ISO custom sotto, che ha lo stesso
    #    aspetto dell'orario ma "T" al posto dello spazio fra data e ora e
    #    nessuna posizione fissa nella riga.
    if (match(line, /^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}),[0-9]+ +(ERROR|WARN|INFO|DEBUG|TRACE)/, a)) {
        _ll_epoch = parse_server(a[1], a[2])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            _ll_ts = a[1] " " a[2]
            _ll_level = a[3]
            _ll_msg = substr(line, RSTART + RLENGTH)
            sub(/^ /, "", _ll_msg)
            return 1
        }
    }

    # 4) ISO custom (es. Guidewire nel profilo liquido): [thread] USER
    #    YYYY-MM-DDTHH:MM:SS,mmm LEVEL messaggio — timestamp NON ancorato a
    #    inizio riga (posizione variabile dopo [thread] USER). Va DOPO i due
    #    rami fra quadre sopra (più specifici) e prima del ramo europeo sotto,
    #    che ha una forma della data incompatibile (giorno-mese-anno con
    #    trattini, non anno-mese-giorno con "T") quindi l'ordine reciproco fra
    #    questo e l'europeo non è ambiguo — resta comunque quello del gemello
    #    bash (utils-logfiles.sh:84-91) per una sola fonte di verità.
    if (match(line, /([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]+) +(ERROR|WARN|INFO|DEBUG|TRACE)/, a)) {
        _ll_epoch = parse_iso(a[1])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            gsub(/T/, " ", a[1]); gsub(/,.*/, "", a[1])
            _ll_ts = a[1]
            _ll_level = a[2]
            _ll_msg = substr(line, RSTART + RLENGTH)
            sub(/^ /, "", _ll_msg)
            return 1
        }
    }

    # 5) Data EUROPEA giorno-mese-anno, ANCORATA a inizio riga (formato di
    #    Pass.log nel profilo usnext, TS-1): DD-MM-YYYY HH:MM:SS[.mmm] LEVEL
    #    messaggio. L'ancora è la stessa scelta del gemello bash
    #    (utils-logfiles.sh:100-104) e per la stessa ragione: una data
    #    europea a metà riga in un log assicurativo è più probabilmente un
    #    dato applicativo (scadenza polizza, data sinistro) che il timestamp
    #    della riga — interpretarla come tale falserebbe la selezione.
    if (match(line, /^([0-9]{2})-([0-9]{2})-([0-9]{4}) ([0-9]{2}:[0-9]{2}:[0-9]{2})([.,][0-9]+)? +(ERROR|WARN|INFO|DEBUG|TRACE)/, a)) {
        _ll_epoch = parse_iso(a[3] "-" a[2] "-" a[1] "T" a[4])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            _ll_ts = a[3] "-" a[2] "-" a[1] " " a[4]
            _ll_level = a[6]
            _ll_msg = substr(line, RSTART + RLENGTH)
            sub(/^ /, "", _ll_msg)
            return 1
        }
    }

    # 6) Solo ora, senza data (console.log nel profilo usnext): HH:MM:SS,mmm
    #    LEVEL messaggio. ULTIMO perché è il ramo meno informativo — nessuna
    #    data con cui discriminare un falso positivo — ma per costruzione non
    #    collide con nessuno dei rami sopra: tutti richiedono almeno 4 cifre
    #    prima del primo separatore, questo ne richiede 2 seguite subito da
    #    ":". Epoch non calcolabile (decisione presa con l'utente: si mostra
    #    l'ora dichiarata dal log, non si deduce una data dal nome del file).
    if (match(line, /^([0-9]{2}:[0-9]{2}:[0-9]{2})[.,][0-9]+ +(ERROR|WARN|INFO|DEBUG|TRACE)/, a)) {
        _ll_has_date = 0
        _ll_epoch = -1
        _ll_ts = a[1]
        _ll_level = a[2]
        _ll_msg = substr(line, RSTART + RLENGTH)
        sub(/^ /, "", _ll_msg)
        return 1
    }

    # 7) Timestamp dentro un CAMPO JSON (log JSON-lines):
    #      {"UpdateTime":"2026-08-24 03:08:01.352","DocUID":"…"}   (spazio)
    #      {"appCode":"LIQ",…,"time":"2026-08-24T07:12:12.514CEST",…}  (T + tz)
    #
    #    Aggiunto per SRCH-5 (2026-08-24) dopo aver misurato in produzione un
    #    errore di 15,25× su una query filtrata per data: 61 occorrenze riportate
    #    contro 4 corrette. Senza questo ramo il filtro riga di
    #    search_all_logs.awk non si applica (richiede _ll_has_date) e le righe
    #    passano tutte, quindi il conteggio includeva l'intera retention.
    #
    #    ULTIMO, e la ragione è verificata ramo per ramo, non presunta: nessuno
    #    dei 6 sopra matcha una riga JSON — 1 e 2 richiedono la parentesi quadra,
    #    3, 5 e 6 sono ancorati a `^` e la riga apre con `{`, 4 richiede un LEVEL
    #    dopo il timestamp che una riga JSON non ha. Non c'è quindi
    #    ombreggiamento possibile; e stare per ultimo PROTEGGE il caso inverso —
    #    una riga di access log che contenga un corpo JSON resta gestita dal
    #    ramo 1, che viene prima.
    #
    #    La cattura tiene data e ora SEPARATE e le ricompone con "T" per
    #    parse_iso(): così la forma con lo spazio e quella con la "T" convergono
    #    su un solo punto di conversione, e la frazione di secondo con eventuale
    #    suffisso di timezone (".514CEST") resta FUORI dalla cattura invece di
    #    essere troncata per coercizione numerica dentro parse_iso.
    if (match(line, /"[^"]*":"([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}:[0-9]{2})/, a)) {
        _ll_epoch = parse_iso(a[1] "T" a[2])
        if (_ll_epoch > 0) {
            _ll_has_date = 1
            _ll_ts = a[1] " " a[2]
            # Nessun livello: un log JSON non ha una posizione convenzionale per
            # ERROR/WARN — il livello, se esiste, è un campo fra gli altri e
            # dedurlo dalla forma sarebbe un'assunzione sul singolo cliente.
            # _ll_msg è la riga INTERA, non il resto dopo il timestamp: il campo
            # può stare in mezzo all'oggetto (in JF4U è il terzo), quindi
            # troncare a RSTART+RLENGTH mangerebbe l'inizio del JSON. L'oggetto
            # per intero È il messaggio.
            _ll_msg = line
            return 1
        }
    }

    return 0
}

# ─── Conteggio dei livelli ────────────────────────────────────────────────────
#
# logline_count_level(LVL) — incrementa nerror/nwarn/ninfo secondo il livello.
# count_level(LINE)        — parsa la riga e conta, per i tool che ricevono una
#                            riga bufferizzata invece del record corrente.
#
# Vivono qui, e non in tre copie nei tool, per un difetto misurato in produzione
# (LVLCNT-1, sweep del 2026-08-24): lo stesso conteggio era scritto TRE volte e due
# copie erano corrette. `tail_log.awk` e `tail_named_log.awk` avevano
#
#     if (lvl == "ERROR") nerror++; else if (lvl == "WARN") nwarn++; else if …
#
# cioè un livello estraneo non veniva conteggiato; `filter_errors.awk` aveva
#
#     if (lvl == "ERROR") nerror++; else nwarn++
#
# una classificazione BINARIA, che faceva finire nei WARN qualsiasi altro livello.
# La copia sbagliata era quella che nessuno aveva riletto — e il difetto non è di
# ragionamento ma di divergenza fra copie, quindi il rimedio è non averne copie.
#
# Il conteggio è ESPLICITO per livello e senza `else` finale: un livello che non
# conosciamo (DEBUG, TRACE, o una stringa vuota da una riga non riconosciuta) non
# viene attribuito a nessun contatore. Attribuirlo per esclusione è esattamente il
# difetto: `filter_errors` dichiarava 46 WARN su un log che ne aveva 2, perché 44
# righe INFO italiane contenenti la parola «ERRORI» finivano nel ramo `else`.
#
# Incrementa direttamente nerror/nwarn/ninfo, che in AWK sono globali condivise fra
# tutti i file caricati con -f: così i tool continuano a stamparle come prima e la
# migrazione non tocca il loro output.
function logline_count_level(lvl) {
    if      (lvl == "ERROR") nerror++
    else if (lvl == "WARN")  nwarn++
    else if (lvl == "INFO")  ninfo++
    # Nessun ramo `else`: vedi sopra — è deliberato, non un caso non gestito.
}

# count_level(LINE) — per i tool che accumulano righe in un buffer e le contano a
# posteriori (tail_log, tail_named_log): imposta $0 e delega a logline_parse().
#
# Sostituisce $0, quindi va chiamata solo dove il record corrente non serve più —
# è il comportamento che avevano già le due copie identiche da cui nasce.
function count_level(line) {
    $0 = line
    if (logline_parse()) logline_count_level(_ll_level)
}
