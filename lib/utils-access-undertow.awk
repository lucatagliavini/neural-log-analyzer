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
# "/portal/api/rest/anag" → "portal". "/" per la radice (richiesta esplicita, non
# un fallimento di estrazione). "" solo se il path non è estraibile affatto.
#
# Deriva da access_url() invece di una regex propria (bug osservato su usnext,
# 2026-08-18): la vecchia classe negata [^\/ "]+ non escludeva "?"/"&"/"="/";",
# quindi ogni variante di query string sullo stesso path diventava un "servizio"
# distinto (~1064 righe fantasma in service_times su un solo access log). Si
# taglia la query string (dopo "?") e il matrix parameter (dopo ";") prima di
# estrarre il primo segmento, così tutte le varianti collassano sullo stesso path.
function access_url_root(    _url, _a) {
    _url = access_url()
    if (_url == "") return ""
    sub(/\?.*/, "", _url)
    sub(/;.*/, "", _url)
    if (_url == "/" || _url == "") return "/"
    if (match(_url, /^\/([^\/]+)/, _a)) return _a[1]
    return ""
}

# Path intero (non solo il primo segmento) normalizzato per raggruppare per
# ENDPOINT esatto, usata da distribute_status: "/rest/claims/998877?type=auto"
# → "/rest/claims/{id}". Granularità diversa da access_url_root() (che collassa
# tutto al primo segmento, "servizio" macro) — questa preserva la rotta intera e
# sostituisce solo le parti variabili: query string, matrix parameter, ID
# numerici lunghi (>= 5 cifre, per non toccare codici brevi legittimi nel path)
# e UUID. Le due funzioni condividono il taglio di query string/matrix parameter
# ma non il resto: unificarle in una sola avrebbe reso service_times più
# grossolano o distribute_status più aggressivo, perdendo la granularità che
# serve a ciascun tool (USNEXT-2).
# Prime `depth` componenti del path, per raggruppare per SERVIZIO a una
# granularità che dipende dal deployment. Generalizza access_url_root(), che è il
# caso depth=1 e resta usata da chi non ha bisogno di scegliere.
#
# SVCGRAN-1 (2026-08-21): perché la profondità è un parametro e non una costante.
# service_times raggruppava sempre sul primo segmento, e su un deployment dove
# ogni servizio ha il proprio context root quello è giusto — MISURATO su usnext:
# profondità 1 → 6 gruppi (portal, spd, api, integration…), la granularità
# corretta. Ma su liquido ogni URL vive sotto lo stesso contesto webapp
# (/essigSXCC/…), quindi il raggruppamento collassava a UN SOLO gruppo: 214.594
# chiamate sotto un'unica etichetta, cioè l'access log intero con dei percentili
# addosso. Misurato sui 295.743 URL reali: profondità 1 → 1 gruppo, 2 → 13,
# 3 → 37.
#
# Non era un difetto del codice ma una COORDINATA mancante (principio 7): quale
# segmento identifichi un servizio dipende da come è montata l'applicazione, non
# da cosa il tool sa fare. Quindi vive in system.conf (SERVICE_PATH_DEPTH) e i due
# profili hanno valori diversi — 1 per usnext, 3 per liquido.
#
# Applica le stesse sostituzioni di access_url_endpoint() (ID numerici lunghi e
# UUID): a profondità 1-3 raramente cambiano qualcosa, ma rendono il
# raggruppamento stabile se un profilo imposta una profondità maggiore.
# Limite noto: un segmento UUID con PREFISSO (`rb_42fa3696-bbf0-…`, il beacon di
# monitoraggio, 105.183 chiamate su liquido e 700 su usnext) non viene collassato,
# perché la regex ancora l'UUID subito dopo lo slash. Resta un gruppo per UUID,
# che ruota raramente — non valeva rendere la regex più permissiva e rischiare di
# collassare path legittimi anche in access_url_endpoint(), che la condivide.
function access_url_service(depth,    _url, _n, _p, _i, _out) {
    _url = access_url()
    if (_url == "") return ""
    sub(/\?.*/, "", _url)
    sub(/;.*/, "", _url)
    if (_url == "/" || _url == "") return "/"
    gsub(/\/[0-9]{5,}/, "/{id}", _url)
    gsub(/\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/, "/{uuid}", _url)
    # Clamp di SANITÀ, non un default di configurazione: una profondità 0,
    # negativa o vuota produrrebbe nomi di servizio vuoti e righe scartate in
    # silenzio. L'obbligo di DICHIARARE il valore vive in dispatch.sh, che rifiuta
    # di eseguire il tool se SERVICE_PATH_DEPTH manca (ARCH-6) — qui si evita solo
    # che un'invocazione diretta di gawk (i test unitari lo fanno) degeneri.
    if (depth + 0 < 1) depth = 1
    # _p[1] è vuoto (lo slash iniziale), quindi il segmento N sta in _p[N+1].
    _n = split(_url, _p, "/")
    _out = ""
    for (_i = 2; _i <= _n && _i <= depth + 1; _i++) {
        if (_p[_i] == "") continue
        _out = (_out == "") ? _p[_i] : _out "/" _p[_i]
    }
    return _out
}

function access_url_endpoint(    _url) {
    _url = access_url()
    if (_url == "") return ""
    sub(/\?.*/, "", _url)
    sub(/;.*/, "", _url)
    gsub(/\/[0-9]{5,}/, "/{id}", _url)
    gsub(/\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/, "/{uuid}", _url)
    return _url
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
