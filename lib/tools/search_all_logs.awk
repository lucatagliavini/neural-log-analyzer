# search_all_logs.awk — conta le occorrenze di un pattern in un singolo file
# di log e calcola primo/ultimo match, rispettando il filtro temporale.
#
# Parametri (-v):
#   pat   pattern ERE case-insensitive (stesso valore che prima andava a grep -iE)
#   tf    limite inferiore "YYYY-MM-DD HH:MM:SS" (vuoto = nessun limite)
#   tt    limite superiore "YYYY-MM-DD HH:MM:SS" (vuoto = nessun limite)
#
# Il timestamp è tracciato riga per riga su TUTTO il file (non solo sulle righe
# che matchano): una riga senza timestamp proprio (continuazione di stack
# trace) eredita quello dell'ultima riga con timestamp vista. Senza questa
# eredità un frame "at ..." che matcha il pattern per puro caso testuale
# (es. "SearchHubExtApi" contiene "searchHub") sopravviveva sempre al filtro
# temporale anche quando l'eccezione a cui appartiene è fuori range — bug
# reale (2026-08-05): un'unica passata su tutte le righe è necessaria perché
# solo scandendo il file per intero si sa qual è il timestamp "corrente" nel
# punto in cui si trova la riga di stack trace.
#
# Output: "hits|first_ts|last_ts" su stdout.
#
# Dipende da: nessuna utility esterna (non usa utils-time.awk: qui il
# confronto è per stringa "YYYY-MM-DD HH:MM:SS", non per epoch, per restare
# coerente col resto di search_all_logs.sh che opera sulla stessa rappresentazione).
#
# Due passate sullo STESSO file (il chiamante passa il path due volte come
# argomento): la prima (FNR==NR) testa solo `pat`, a costo di un semplice
# match per riga. Solo se esiste almeno una riga candidata si esegue la
# seconda passata, che fa il lavoro costoso (estrazione timestamp + eredità
# per le righe di stack trace). Misurato su 208k righe: il match() del
# timestamp da solo costa 0.19s su 0.27s totali — con 30 file su 33 senza
# match nel caso comune, la prima passata (0.03s) evita quasi tutto quel
# costo. Non si può sostituire con un pre-gate `grep -qiE`: esistono pattern
# ERE dove gawk e grep divergono (es. `a\.b`, `{brace`), quindi un motore
# diverso da quello di analisi rischierebbe di scartare match reali — le due
# passate usano lo stesso motore, quindi il rischio non esiste (2026-08-06).

BEGIN {
    IGNORECASE = 1
    MONTHS["Jan"]="01"; MONTHS["Feb"]="02"; MONTHS["Mar"]="03"; MONTHS["Apr"]="04"
    MONTHS["May"]="05"; MONTHS["Jun"]="06"; MONTHS["Jul"]="07"; MONTHS["Aug"]="08"
    MONTHS["Sep"]="09"; MONTHS["Oct"]="10"; MONTHS["Nov"]="11"; MONTHS["Dec"]="12"
    do_filter = (tf != "" || tt != "")
    hits = 0; first_ts = ""; last_ts = ""
    # gated=1 → il chiamante ha GIÀ verificato che il pattern esiste nel file
    # (pre-gate `grep -qiF` in search_all_logs.sh) e passa il file UNA volta
    # sola: la prima passata sarebbe lavoro duplicato. Conta soprattutto sui
    # .gz, dove ogni passata è una decompressione e la decompressione è ~90%
    # del costo — senza questo un .gz con match veniva decompresso 3 volte
    # (gate + pass1 + pass2) invece di 2.
    candidate = (gated ? 1 : 0)
    single_pass = (gated ? 1 : 0)
}

FNR == NR && !single_pass {
    if ($0 ~ pat) candidate = 1
    next
}

{
    if (!candidate) exit
    ts = ""
    if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr($0, RSTART, RLENGTH)
        gsub(/T/, " ", ts)
    } else if (match($0, /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        raw = substr($0, RSTART + 1, RLENGTH - 1)
        split(raw, p, "/")
        mnum = MONTHS[p[2]]
        if (mnum != "") {
            split(p[3], q, ":")
            ts = q[1] "-" mnum "-" p[1] " " q[2] ":" q[3] ":" q[4]
        }
    }
    if (ts != "") last_seen_ts = ts
    eff_ts = (ts != "") ? ts : last_seen_ts

    if ($0 !~ pat) next

    if (do_filter && eff_ts != "") {
        if (tf != "" && eff_ts < tf) next
        if (tt != "" && eff_ts > tt) next
    }

    hits++
    if (eff_ts != "") {
        # MINIMO e MASSIMO, non "il primo e l'ultimo incontrati".
        #
        # Il codice precedente assumeva che le righe fossero in ordine
        # cronologico — vero per access log e server log, che sono append-only
        # sequenziali. NON vero per un log applicativo multi-thread: in Pass.log
        # del profilo usnext le righe sono scritte da thread concorrenti e
        # finiscono nel file nell'ordine in cui il buffer viene svuotato, non di
        # timestamp. Risultato: la tabella mostrava ULTIMO MATCH *precedente* a
        # PRIMO MATCH — segnalato dall'utente il 2026-08-17 su
        # `Pass.log.2026-08-17.2` (12:31:14 → 10:55:59, impossibile).
        #
        # Difetto latente da quando search_all_logs esiste: si è manifestato solo
        # ora perché usnext è il primo profilo con un log di questo tipo — lo
        # stesso Pass.log che ha già richiesto il quinto formato di timestamp
        # (TS-1). Su un log ordinato il risultato è identico a prima, quindi
        # nessuna regressione su access/server.
        #
        # Confronto lessicografico e non numerico: il formato è
        # "YYYY-MM-DD HH:MM:SS", a campi di larghezza fissa e dal più
        # significativo al meno, quindi l'ordine delle stringhe coincide con
        # quello temporale — ed è lo stesso confronto già usato dal filtro
        # tf/tt sopra.
        if (first_ts == "" || eff_ts < first_ts) first_ts = eff_ts
        if (eff_ts > last_ts)                    last_ts  = eff_ts
    }
}

END {
    printf "%d|%s|%s\n", hits, first_ts, last_ts
}
