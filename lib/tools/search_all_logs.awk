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
# Output: "hits|first_ts|last_ts|partial|unfiltered" su stdout.
#   partial=1    first_ts/last_ts sono solo-ora (nessun match datato nel file)
#   unfiltered=N delle `hits`, quante sono state INCLUSE senza che il filtro
#                temporale potesse valutarle (nessun timestamp, o senza data).
#                Vale 0 quando non è stato chiesto alcun filtro: non c'è nulla da
#                dichiarare. Sono due assi DISTINTI e non vanno confusi —
#                `partial` dice che il min/max è un orario, `unfiltered` dice che
#                il conteggio comprende righe che la finestra non ha filtrato.
#                Aggiunto con SRCH-5 (2026-08-24): senza, un'inclusione
#                conservativa (principio 5) era indistinguibile da un risultato
#                filtrato, e il numero sbagliato veniva presentato come giusto.
#
# Il riconoscimento del timestamp è delegato a logline_parse()
# (utils-logline.awk): il formato è una proprietà del file (5 grammatiche,
# incluso il solo-ora di console.log), non un'assunzione di questo tool.
# Il confronto resta per stringa "YYYY-MM-DD HH:MM:SS" (non per epoch): è
# _ll_ts, non _ll_epoch, il valore usato qui, per restare coerente col resto
# di search_all_logs.sh che opera sulla stessa rappresentazione testuale.
#
# Dipende da: utils-time.awk, utils-logline.awk (caricati da search_all_logs.sh).
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
    do_filter = (tf != "" || tt != "")
    hits = 0
    # Occorrenze incluse ma non filtrabili per data (vedi header). Esplicito e
    # non implicito-zero: è un campo del contratto di output, non una variabile
    # di comodo.
    unfiltered = 0
    # Due min/max SEPARATI (datato / solo-ora): mai mescolati, perché il
    # confronto è per stringa e "10:03:37" ordina sempre prima di qualsiasi
    # "2026-...". In END si emette il datato se esiste almeno un match
    # datato nel file, altrimenti l'orario marcato come parziale (4° campo).
    first_ts_dated = ""; last_ts_dated = ""
    first_ts_time  = ""; last_ts_time  = ""
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
    row_recognized = logline_parse()
    ts = row_recognized ? _ll_ts : ""
    ts_has_date = row_recognized ? _ll_has_date : 0
    if (ts != "") { last_seen_ts = ts; last_seen_has_date = ts_has_date }
    eff_ts = (ts != "") ? ts : last_seen_ts
    eff_has_date = (ts != "") ? ts_has_date : last_seen_has_date

    if ($0 !~ pat) next

    # tf/tt sono sempre datati ("YYYY-MM-DD HH:MM:SS"): confrontarli con un
    # eff_ts solo-ora (console.log, profilo usnext) per stringa darebbe un
    # esito falso (una cifra ora ordina sempre prima di un anno). Senza data
    # non si può stabilire se la riga è nel range: si include (principio 5),
    # esattamente il comportamento di prima della migrazione a
    # logline_parse(), quando queste righe non avevano affatto un ts.
    if (do_filter && eff_ts != "" && eff_has_date) {
        if (tf != "" && eff_ts < tf) next
        if (tt != "" && eff_ts > tt) next
    } else if (do_filter) {
        # La riga viene INCLUSA (principio 5) ma il filtro non ha potuto
        # valutarla: nessun timestamp, o un timestamp senza data. Contarla in
        # silenzio è ciò che ha prodotto l'errore di 15,25× misurato in
        # produzione con SRCH-5 (61 occorrenze riportate contro 4 corrette su una
        # query filtrata per oggi). Il conteggio risale al chiamante, che lo
        # dichiara in tabella: l'inclusione resta conservativa, ma non è più
        # indistinguibile da un risultato filtrato.
        #
        # Un CONTATORE e non un flag per-file: un log può essere MISTO — righe
        # datate e righe senza timestamp nello stesso file — e in quel caso un
        # flag direbbe "tutto sospetto" o "niente sospetto", entrambi falsi.
        unfiltered++
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
        # Confronto lessicografico e non numerico: sia "YYYY-MM-DD HH:MM:SS"
        # sia "HH:MM:SS" sono a campi di larghezza fissa dal più significativo
        # al meno, quindi l'ordine delle stringhe coincide con quello
        # temporale — ed è lo stesso confronto già usato dal filtro tf/tt
        # sopra. I due min/max restano su binari separati (vedi BEGIN):
        # mescolarli produrrebbe un minimo falso, perché un orario di 8
        # caratteri ordina sempre prima di una data di 19.
        if (eff_has_date) {
            if (first_ts_dated == "" || eff_ts < first_ts_dated) first_ts_dated = eff_ts
            if (eff_ts > last_ts_dated)                          last_ts_dated  = eff_ts
        } else {
            if (first_ts_time == "" || eff_ts < first_ts_time) first_ts_time = eff_ts
            if (eff_ts > last_ts_time)                          last_ts_time  = eff_ts
        }
    }
}

END {
    # Emesso il datato se il file ne ha almeno uno; altrimenti l'orario,
    # marcato "parziale" nel 4° campo — un file può attraversare la
    # mezzanotte, quindi il minimo/massimo dell'orario non è garantito essere
    # il primo/ultimo evento cronologico: limite del log (console.log non
    # scrive la data), non del tool.
    if (first_ts_dated != "")
        printf "%d|%s|%s|0|%d\n", hits, first_ts_dated, last_ts_dated, unfiltered
    else if (first_ts_time != "")
        printf "%d|%s|%s|1|%d\n", hits, first_ts_time, last_ts_time, unfiltered
    else
        printf "%d|%s|%s|0|%d\n", hits, "", "", unfiltered
}
