#!/bin/bash
#
# Estrae parametri strutturati da una query in linguaggio naturale.
# Emette variabili shell: TIME_FROM, TIME_TO, DATE_FILTER,
#                         STATUS_CODE, THRESHOLD_MS, IP_FILTER, TAIL_N, NAMED_LOG
#
# Uso: eval "$(./lib/param-extract.sh "errori 500 delle ultime 3 ore")"
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils-time.sh"

# Carica gli ambienti del profilo per costruire il pattern di stop-word dinamico
if [[ -n "${PROFILE_DIR:-}" && -f "$PROFILE_DIR/system.conf" ]]; then
    source "$PROFILE_DIR/system.conf"
fi

query="${1,,}"

# Finestra temporale — delegata a utils-time.sh
eval "$(resolve_time_range "$query")"

# Codice HTTP specifico: 200, 404, 500, 503, 4xx, 5xx ...
STATUS_CODE=""
if   echo "$query" | grep -qE "\b[45][0-9]{2}\b"; then
    STATUS_CODE=$(echo "$query" | grep -oE "\b[45][0-9]{2}\b" | head -1)
elif echo "$query" | grep -qE "\b[2][0-9]{2}\b"; then
    STATUS_CODE=$(echo "$query" | grep -oE "\b[2][0-9]{2}\b" | head -1)
elif echo "$query" | grep -qE "5xx"; then
    STATUS_CODE="5xx"
elif echo "$query" | grep -qE "4xx"; then
    STATUS_CODE="4xx"
fi

# Soglia latenza in ms: "più lente di N ms" / "sopra i N ms" / "oltre N ms"
THRESHOLD_MS=""
if echo "$query" | grep -qE "[0-9]+ ms"; then
    THRESHOLD_MS=$(echo "$query" | grep -oE "[0-9]+ ms" | grep -oE "[0-9]+" | head -1)
elif echo "$query" | grep -qE "lent"; then
    THRESHOLD_MS="1000"  # default: > 1 secondo
fi

# IP sorgente
IP_FILTER=""
if echo "$query" | grep -qE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"; then
    IP_FILTER=$(echo "$query" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
fi

# Numero di righe per tail — richiede "ultime/ultimi N righe/righe/record/log"
# per non confliggere con "ultime 2 ore" / "ultimi 30 minuti"
TAIL_N="50"
if echo "$query" | grep -qE "ultim[ei] [0-9]+ *(rig[ah]|record|log|linee|lin)"; then
    TAIL_N=$(echo "$query" | grep -oE "ultim[ei] [0-9]+" | grep -oE "[0-9]+" | head -1)
elif echo "$query" | grep -qE "(mostra|dammi|visualizza) [0-9]+ *(rig[ah]|record|log|linee)"; then
    TAIL_N=$(echo "$query" | grep -oE "[0-9]+" | head -1)
fi

# Livello log per grep_named_log: "problemi/anomalie" → WARN+ (ERROR+WARN),
# "errori/error" → ERROR, "warning/warn" → WARN, "info" → INFO, "tutti/all" → ALL
LOG_LEVEL="ERROR"
if   echo "$query" | grep -qE "\bwarn(ing)?\b|\bavviso\b"; then
    LOG_LEVEL="WARN"
elif echo "$query" | grep -qE "\binfo\b|\binformazioni\b"; then
    LOG_LEVEL="INFO"
elif echo "$query" | grep -qE "\btutti?\b.*livell|\ball\b.*level|ogni.livell"; then
    LOG_LEVEL="ALL"
elif echo "$query" | grep -qE "\bprobl[ei]|anomal|cosa.non.va|non.va\b|incident|stran"; then
    LOG_LEVEL="WARN+"
fi

# Nome log applicativo specifico — la lista viene dal profilo (entities.conf: APP_LOG_NAMES).
# Fallback su array vuoto se il profilo non definisce APP_LOG_NAMES.
NAMED_LOG=""
if [[ -n "${PROFILE_DIR:-}" && -f "$PROFILE_DIR/entities.conf" ]]; then
    source "$PROFILE_DIR/entities.conf"
fi
# Longest-match: ordina per lunghezza decrescente prima di iterare, come fa
# normalize-query.sh per gli alias APP. Senza questo "ccJBatch.log" veniva risolto
# come "cc" (il pattern è `\bcc` senza ancora finale, e "cc" viene prima nel file):
# il classificatore instradava correttamente su tail_named_log ma dispatch.sh
# apriva cc.log invece di ccJBatch.log. Colpiva ccJBatch e ccCanaliz.
_sorted_log_names=$(for _n in "${APP_LOG_NAMES[@]:-}"; do
                        [[ -n "$_n" ]] && printf '%d %s\n' "${#_n}" "$_n"
                    done | sort -k1,1rn -k2,2 | awk '{print $2}')
for _log_name in $_sorted_log_names; do
    [[ -z "$_log_name" ]] && continue
    if echo "$query" | grep -qiE "\b${_log_name}"; then
        NAMED_LOG="$_log_name"
        break
    fi
done

# Fallback: la query nomina un "<token>.log" che non è nella whitelist.
# APP_LOG_NAMES è una lista di ALIAS noti (scorciatoie che l'utente può usare senza
# estensione, es. "errori nel cc"), non di log AMMESSI: sul nodo di produzione i log
# sono 28 e la whitelist ne elenca 16, quindi limitarsi ad essa renderebbe
# irraggiungibili 12 log reali — fra cui concurrentDataChangeExceptionLog,
# inbound_mq_messages, controllo_pagamenti. La risoluzione del path la fa `find` in
# dispatch.sh, che sa già cosa c'è sul disco.
#
# Si usa il case ORIGINALE ($1, non $query lowercase): i nomi reali contengono
# maiuscole (ccJBatch, JF4U_TRACKING, concurrentDataChangeExceptionLog) e finiscono
# in `find -name`, che è case-sensitive.
#
# Esclusi i log di infrastruttura (basename da system.conf): hanno tool dedicati.
if [[ -z "$NAMED_LOG" ]]; then
    _fb=$(grep -oE "[A-Za-z0-9_.-]+\.log\b" <<< "$1" | head -1)
    if [[ -n "$_fb" ]]; then
        _fb_base="${_fb%.log}"
        _fb_ok=1
        # Il valore finisce in `find -name`: whitelist obbligatoria, non difensiva.
        [[ "$_fb_base" == *".."* ]] && _fb_ok=0
        [[ ! "$_fb_base" =~ ^[A-Za-z0-9_.-]+$ ]] && _fb_ok=0
        # Serve almeno un alfanumerico: "..log" passerebbe la whitelist con base "."
        # e "-.log" con base "-", che non sono nomi di log. Innocui per `find -name`
        # (che tratta il valore come pattern di nome, non come path) ma privi di senso.
        [[ ! "$_fb_base" =~ [A-Za-z0-9] ]] && _fb_ok=0
        for _sysb in "${ACCESS_LOG_BASE:-}" "${SERVER_LOG_BASE:-}" "${GC_LOG_BASE:-}"; do
            [[ -n "$_sysb" && "${_fb_base,,}" == "${_sysb,,}" ]] && _fb_ok=0
        done
        [[ "$_fb_ok" -eq 1 ]] && NAMED_LOG="$_fb_base"
    fi
fi

# Tipo di log per tail_log: "server"/"applicativo" → server.log, default → access log
# SERVER_LOG_FORMAT viene da system.conf — non hardcodiamo il nome della tecnologia.
LOG_TYPE=""
_srv_fmt="${SERVER_LOG_FORMAT:-server}"
if echo "$query" | grep -qiE "\b(log[[:space:]]+(applicativ|dell.applicaz|di[[:space:]]+sistema|${_srv_fmt})|applicativ[oa][[:space:]]+log)\b"; then
    LOG_TYPE="server"
fi

# Pattern di ricerca per search_all_logs.
# La stringa da cercare deve essere tra virgolette doppie o singole:
#   cerca "NullPointerException" in produzione
#   trova 'claim 1-8101-2026-0473954' nel nodo 5
# Se il trigger è presente ma mancano le virgolette → __MISSING__ (messaggio in search_all_logs.sh).
SEARCH_PATTERN=""
_sq="${1,,}"  # query originale in minuscolo
if echo "$_sq" | grep -qiE "\bcerca\b|\btrova\b|\bdove.appare\b|\bdove.si.trova\b|in.quali.log|cerca.ovunque|cerca.in.tutti"; then
    # Usa $1 (case originale) per preservare maiuscole nel pattern
    SEARCH_PATTERN=$(echo "$1" | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
    [[ -z "$SEARCH_PATTERN" ]] && \
        SEARCH_PATTERN=$(echo "$1" | sed -n "s/.*'\([^']*\)'.*/\1/p" | head -1)
    [[ -z "$SEARCH_PATTERN" ]] && SEARCH_PATTERN="__MISSING__"
fi

# Escape hatch per log fuori da APP_LOG_NAMES: glob tra virgolette.
#   ultime 10 righe di "*c1nssprod*.log"
# Stesso meccanismo di estrazione di SEARCH_PATTERN (stringa tra virgolette dalla
# query originale, per preservare le maiuscole nei nomi file), ma discriminato dalla
# *forma* del contenuto: deve contenere '*' e terminare in '.log'. Così una query
# `cerca "NullPointerException"` non finisce qui, e questa non finisce in SEARCH_PATTERN.
#
# Su `cerca "*errore*.log"` entrambe si popolano: è voluto, non una collisione. Ogni
# tool legge solo la propria variabile, quindi è il classificatore a decidere l'intento.
# Un'esclusione mutua romperebbe query legittime come `cerca errori nel "*c1nss*.log"`.
#
# Il valore finisce in `find -name` (dispatch.sh): è input non fidato, quindi la
# whitelist di caratteri è obbligatoria, non difensiva. '/' e '..' permetterebbero
# di uscire dalla directory dei log nonostante -maxdepth 1.
#
# Accetta anche le forme dei file ruotati: sul nodo la rotazione produce
# `prod1nsse-cc.log-2026-07-26-1785016801.gz`, dove ".log" sta IN MEZZO e
# l'estensione finale è ".gz". Richiedere ".log" finale (come faceva la prima
# versione) rendeva il glob incapace di raggiungere qualsiasi storico.
# Nota: la forma canonica resta `"*-cc.log"` — dispatch.sh la espande alle
# rotazioni via select_log_files, quindi l'utente non deve scrivere il .gz a mano.
NAMED_LOG_GLOB=""
_glob_raw=$(echo "$1" | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
[[ -z "$_glob_raw" ]] && _glob_raw=$(echo "$1" | sed -n "s/.*'\([^']*\)'.*/\1/p" | head -1)
if [[ -n "$_glob_raw" && "$_glob_raw" == *'*'* \
      && "$_glob_raw" =~ \.log([-.][A-Za-z0-9_.*-]*)?$ ]]; then
    if [[ "$_glob_raw" == *".."* ]]; then
        echo "[WARN] param-extract: glob rifiutato (contiene '..'): $_glob_raw" >&2
    elif [[ ! "$_glob_raw" =~ ^[A-Za-z0-9_.*-]+$ ]]; then
        echo "[WARN] param-extract: glob rifiutato (caratteri non ammessi, consentiti [A-Za-z0-9_.*-]): $_glob_raw" >&2
    else
        NAMED_LOG_GLOB="$_glob_raw"
    fi
fi

# UNRESOLVED_LOG rimosso (2026-08-04): segnalava un ".log" che non riuscivamo a
# risolvere, per avvisare l'utente prima che il tool leggesse un altro file. Da quando
# NAMED_LOG risolve QUALSIASI "<token>.log" (vedi il fallback sopra) restava vuoto in
# ogni caso reale — e il suo lavoro lo fa meglio suggest_available_logs() in
# dispatch.sh, che elenca i log effettivamente presenti sul nodo invece degli alias
# di entities.conf: informazione più accurata, perché la whitelist può divergere dal
# disco ("plugin" in configurazione contro "plugins" reale).

echo "TIME_FROM='${TIME_FROM}'"
echo "TIME_TO='${TIME_TO}'"
echo "DATE_FILTER='${DATE_FILTER}'"
echo "TIME_ONLY_QUERY='${TIME_ONLY_QUERY:-0}'"
echo "STATUS_CODE='${STATUS_CODE}'"
echo "THRESHOLD_MS='${THRESHOLD_MS}'"
echo "IP_FILTER='${IP_FILTER}'"
echo "TAIL_N='${TAIL_N}'"
echo "NAMED_LOG='${NAMED_LOG}'"
echo "LOG_LEVEL='${LOG_LEVEL}'"
echo "LOG_TYPE='${LOG_TYPE}'"
echo "SEARCH_PATTERN='${SEARCH_PATTERN}'"
echo "NAMED_LOG_GLOB='${NAMED_LOG_GLOB}'"
# Entità normalizzate — arrivano da normalize-query.sh (unica fonte di verità).
# param-extract le riemette invariate così il chiamante può fare un unico eval.
echo "DETECTED_APP='${DETECTED_APP:-}'"
echo "DETECTED_ENV='${DETECTED_ENV:-}'"
echo "DETECTED_NODE='${DETECTED_NODE:-}'"
