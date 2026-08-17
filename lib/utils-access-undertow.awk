# utils-access-undertow.awk — estrazione dei campi di una riga di access log,
# formato Undertow (il default: ACCESS_LOG_FORMAT="undertow").
# Incluso con -f da dispatch.sh in tutti i tool che leggono l'access log.
#
# Perché esiste (ACCESS-1, 2026-08-17): le stesse quattro estrazioni erano
# duplicate in 13 punti su 6 tool (count_status, distribute_status, slow_requests,
# traffic_volume, service_times, filter_ip). Una duplicazione di questa forma è
# già stata la causa dei bug di LOGDISC-3 e LOGSEL-1: si corregge un punto e gli
# altri restano indietro. E infatti divergevano già — vedi la nota su
# access_time_ms().
#
# Funzioni esposte (tutte operano sulla riga corrente, $0):
#   access_status()      → codice HTTP a 3 cifre, "" se assente
#   access_time_ms()     → tempo di risposta in ms, -1 se non misurabile
#   access_method()      → metodo HTTP (GET, POST, …), "" se assente
#   access_url()         → path della richiesta, "" se assente
#   access_ip()          → IP del client
#   access_ts()          → timestamp epoch (in utils-time.awk, vedi FORMAT-1)
#
# CONTRATTO PER UN NUOVO FORMATO. Questo file implementa il formato Undertow
# osservato sui profili liquido e usnext:
#   IP [DD/Mon/YYYY:HH:MM:SS +ZZZZ] "METODO /path HTTP/1.1" STATUS BYTES MS ...
# Per supportare un middleware con un formato diverso (es. il *combined* di
# Apache/WebSphere, `%h %l %u %t "%r" %>s %b`) si crea utils-access-<formato>.awk
# con le stesse funzioni e si imposta ACCESS_LOG_FORMAT in system.conf — stesso
# meccanismo di SERVER_LOG_FORMAT per il parser del server log, e nessuna
# modifica ai tool.
#
# Le funzioni restituiscono un valore neutro ("" o -1) invece di fallire: un
# campo non estraibile è un dato mancante, non un errore, e il chiamante decide
# se scartare la riga o contarla a parte (principio 5). filter_ip conta
# separatamente le righe senza tempo misurabile proprio per questo (O6).

# Codice di stato HTTP. Ancorato alla virgoletta di chiusura della request line,
# così non collide con i byte trasmessi o con un "200" dentro l'URL.
function access_status(    _a) {
    if (match($0, /" ([0-9]{3}) /, _a)) return _a[1]
    return ""
}

# Tempo di risposta in millisecondi; -1 se la riga non lo ha in forma estraibile.
#
# NOTA SULLA VARIANTE SCELTA (verificata in produzione il 2026-08-17). Cinque
# tool usavano `([0-9]+) ` con lo spazio finale, filter_ip `([0-9]+)` senza:
# divergenza preesistente, non introdotta da questa centralizzazione. Misurata
# sui log reali, cambia UNA riga su 127.320 — l'ultima del file corrente, quella
# ancora in scrittura e priva del newline finale: la variante con lo spazio non la
# vede.
#
# Si adotta la PERMISSIVA (senza spazio finale, quella di filter_ip): perdere
# l'ultima richiesta di un log attivo è un difetto di correttezza, includerla al
# più aggiunge una riga (principio 5). Conseguenza attesa e voluta: sui tool che
# prima usavano la variante restrittiva i conteggi possono aumentare di 1 su un
# log in scrittura — mai diminuire.
function access_time_ms(    _a) {
    if (match($0, /" [0-9]+ [0-9-]+ ([0-9]+)/, _a)) return _a[1] + 0
    return -1
}

# Metodo HTTP della request line.
function access_method(    _a) {
    if (match($0, /"([A-Z]+) [^ ]+ HTTP/, _a)) return _a[1]
    return ""
}

# Path completo della richiesta (senza metodo né versione del protocollo).
function access_url(    _a) {
    if (match($0, /"[A-Z]+ ([^ ]+) HTTP/, _a)) return _a[1]
    return ""
}

# Primo segmento del path, usato da service_times per raggruppare per servizio:
# "/portal/api/rest/anag" → "portal". "" se il path non è estraibile.
function access_url_root(    _a) {
    if (match($0, /"[A-Z]+ \/([^\/ "]+)/, _a)) return _a[1]
    return ""
}

# Ora e minuto della richiesta, come "HH" e "MM" (stringhe, per non perdere lo
# zero iniziale). Usata da traffic_volume per il raggruppamento in fasce da 10
# minuti: aveva una regex propria sul timestamp, l'ultima assunzione di formato
# rimasta nei tool HTTP dopo la centralizzazione delle altre quattro.
#
# Perché non derivarla da access_ts(): quello restituisce un epoch, e convertirlo
# in ora locale richiederebbe strftime() con la timezone del server di log —
# un'informazione che i tool non hanno (LOG_TZ è in system.conf, non passata
# all'AWK). Leggere i due campi dalla riga è più diretto e non introduce una
# dipendenza dal fuso.
function access_hour(    _a) {
    if (match($0, /\[[0-9]{2}\/[A-Za-z]+\/[0-9]{4}:([0-9]{2}):([0-9]{2})/, _a)) return _a[1]
    return ""
}
function access_minute(    _a) {
    if (match($0, /\[[0-9]{2}\/[A-Za-z]+\/[0-9]{4}:([0-9]{2}):([0-9]{2})/, _a)) return _a[2]
    return ""
}

# IP del client: primo campo della riga in questo formato.
# Isolata come funzione perché in un formato diverso non è detto che sia $1 (nel
# combined di Apache lo è, ma con un proxy davanti può essere un X-Forwarded-For
# in coda — su usnext quel campo esiste già, in posizione variabile).
function access_ip() {
    return $1
}
