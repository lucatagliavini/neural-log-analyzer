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
for _log_name in "${APP_LOG_NAMES[@]:-}"; do
    [[ -z "$_log_name" ]] && continue
    if echo "$query" | grep -qiE "\b${_log_name}"; then
        NAMED_LOG="$_log_name"
        break
    fi
done

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
# Entità normalizzate — arrivano da normalize-query.sh (unica fonte di verità).
# param-extract le riemette invariate così il chiamante può fare un unico eval.
echo "DETECTED_APP='${DETECTED_APP:-}'"
echo "DETECTED_ENV='${DETECTED_ENV:-}'"
echo "DETECTED_NODE='${DETECTED_NODE:-}'"
