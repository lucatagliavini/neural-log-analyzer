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

# Pattern di ricerca libero per search_all_logs.
# Estratto da: "cerca X", "trova X", "dove appare X", "in quali log c'è X",
# "cerca ovunque X", "cerca in tutti i log X"
SEARCH_PATTERN=""
_sq="${1,,}"  # query originale in minuscolo
if echo "$_sq" | grep -qiE "\bcerca\b|\btrova\b|\bdove.appare\b|\bdove.si.trova\b|in.quali.log|cerca.ovunque|cerca.in.tutti"; then
    # Pattern di stop-word ambienti costruito dinamicamente dagli ambienti del profilo.
    # Se ENV_NODE_CODE non è disponibile, nessun filtro ambiente (preferibile al filtrare
    # con nomi di un profilo sbagliato).
    if declare -p ENV_NODE_CODE &>/dev/null && [[ "${#ENV_NODE_CODE[@]}" -gt 0 ]]; then
        _env_pat=$(IFS='|'; echo "${!ENV_NODE_CODE[*]}")
    else
        _env_pat=""
    fi
    # Sinonimi italiani: se ENV_SYNONYMS è disponibile (da entities.conf), usa le chiavi;
    # altrimenti stringa vuota.
    if declare -p ENV_SYNONYMS &>/dev/null && [[ "${#ENV_SYNONYMS[@]}" -gt 0 ]]; then
        _env_synonyms=$(IFS='|'; echo "${!ENV_SYNONYMS[*]}")
    else
        _env_synonyms=""
    fi
    # Componi _ctx_pat solo con i componenti non vuoti
    _ctx_pat=""
    [[ -n "$_env_pat"      ]] && _ctx_pat="$_env_pat"
    [[ -n "$_env_synonyms" ]] && _ctx_pat="${_ctx_pat:+${_ctx_pat}|}${_env_synonyms}"

    # Estrai il token dopo il verbo / la frase trigger, poi tronca ai qualificatori.
    # Pipeline:
    #   1. Strip trigger ("cerca in tutti i log", "trova", ...)
    #   2. Strip qualificatori contestuali ovunque nella residua (env/nodo/qualificatori temporali)
    #      — necessario perché il trigger può lasciare "di produzione la stringa X" dove
    #        il contesto precede il prefisso descrittivo
    #   3. Strip prefisso descrittivo ("la stringa", "il pattern", ...)
    #   4. Strip suffissi ("nei log", "ovunque", ...)
    #   5. Trim spazi
    _ctx_strip=""
    if [[ -n "$_ctx_pat" ]]; then
        _ctx_strip="(di |in |su |nel |nella |nei |dal |dalla |dai |dalle )?[[:space:]]*\b(${_ctx_pat})\b[[:space:]]*"
    fi
    # Pattern temporali da stripare — usa le costanti da utils-time.sh.
    # I pattern "prefisso" (stamatt, questa.matt, stanott, staser) vengono estesi
    # con \S* per catturare i caratteri fusi (es. stamatt → stamattina).
    _re_morning_strip="stamatt\S*|questa.matt\S*|\bmattinata\b|\bdi mattina\b|\bin mattina\b"
    _re_night_strip="stanott\S*|questa.notte|\bdi notte\b|\bnotturno\b"
    _re_evening_strip="staser\S*|questa.sera|\bdi sera\b|\bserata\b"
    _time_strip="${_RE_N_DAYS_AGO}|${_RE_N_HOURS_AGO}|${_RE_N_MINS_AGO}|${_RE_HALF_HOUR_AGO}|${_RE_LAST_N_HOURS}|${_RE_LAST_N_MINS}|${_RE_LAST_ONE_HOUR}|${_RE_LAST_DAY}|${_re_morning_strip}|${_RE_AFTERNOON}|${_re_night_strip}|${_re_evening_strip}|${_RE_YESTERDAY}|${_RE_TODAY}|${_RE_JUST_NOW}|${_RE_EXPLICIT_RANGE}|${_RE_SINGLE_HOUR}"
    SEARCH_PATTERN=$(echo "$_sq" | \
        sed -E "s/.*(cerca ovunque|cerca in tutti i log|in quali log c'è|in quali log|dove appare|dove si trova|cerca|trova)[[:space:]]*//" | \
        { [[ -n "$_ctx_strip" ]] && sed -E "s/${_ctx_strip}//gI" || cat; } | \
        sed -E 's/(nodo [0-9]+|su nodo|tutti i nodi)[[:space:]]*//gI' | \
        sed -E "s/\b(nell[ae]?|del[la]*|di|in|a)[[:space:]]*(${_time_strip})//gI" | \
        sed -E "s/(${_time_strip})//gI" | \
        sed -E 's/^(il pattern|il testo|la stringa|il sinistro|l.utente|l.errore|il codice|il messaggio)[[:space:]]*//' | \
        sed -E 's/[[:space:]]*(nei log|ovunque|in tutti i log|nei vari log)$//' | \
        sed -E 's/\b(di|in|nel|nell|dalle|alle|verso|le|la|il|fa|a)[[:space:]]*$//' | \
        sed 's/^ *//' | sed 's/ *$//')
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
