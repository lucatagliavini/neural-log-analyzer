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

# Nome log Guidewire specifico: "cc.log", "api.log", "database log", "messaging", ...
NAMED_LOG=""
for _log_name in cc api database messaging performance_integr jgroups plugin ruleengine studio \
                 ccJBatch ccCanaliz claimnumgen contactsearch velocity arbitrato; do
    if echo "$query" | grep -qiE "\b${_log_name}"; then
        NAMED_LOG="$_log_name"
        break
    fi
done

# Pattern di ricerca libero per search_all_logs.
# Estratto da: "cerca X", "trova X", "dove appare X", "in quali log c'è X",
# "cerca ovunque X", "cerca in tutti i log X"
SEARCH_PATTERN=""
_sq="${1,,}"  # query originale in minuscolo
if echo "$_sq" | grep -qiE "\bcerca\b|\btrova\b|\bdove.appare\b|\bdove.si.trova\b|in.quali.log|cerca.ovunque|cerca.in.tutti"; then
    # Pattern di stop-word ambienti costruito dinamicamente dagli ambienti del profilo
    # (fallback sulla lista statica se system.conf non è disponibile)
    if declare -p ENV_NODE_CODE &>/dev/null && [[ "${#ENV_NODE_CODE[@]}" -gt 0 ]]; then
        _env_pat=$(IFS='|'; echo "${!ENV_NODE_CODE[*]}")
    else
        _env_pat="prod|euro|inte|cert|coll|test"
    fi
    # Sinonimi italiani degli ambienti (sempre presenti)
    _env_synonyms="produzion[ei]|integrazion[ei]|collaudo|certificazion[ei]"
    _ctx_pat="${_env_pat}|${_env_synonyms}"

    # Estrai il token dopo il verbo / la frase trigger, poi tronca ai qualificatori
    SEARCH_PATTERN=$(echo "$_sq" | \
        sed -E 's/.*(cerca ovunque|cerca in tutti i log|in quali log c.è|in quali log|dove appare|dove si trova|cerca|trova)[[:space:]]*//' | \
        sed -E 's/^(il pattern|il testo|la stringa|il sinistro|l.utente|l.errore|il codice|il messaggio)[[:space:]]*//' | \
        sed -E 's/[[:space:]]*(nei log|ovunque|in tutti i log|nei vari log)$//' | \
        sed -E "s/[[:space:]]+(di |in |su )?(oggi|ieri|stamattina|mattinata|pomeriggio|stasera|stanotte|questa settimana|${_ctx_pat}|nodo [0-9]+|nel log|nei log|su nodo|ovunque)[[:space:]].*\$//" | \
        sed -E "s/[[:space:]]+(di |in |su )?(oggi|ieri|stamattina|mattinata|pomeriggio|stasera|stanotte|questa settimana|${_ctx_pat}|nodo [0-9]+|nel log|nei log|su nodo|ovunque)\$//" | \
        sed 's/^ *//' | sed 's/ *$//')
fi

echo "TIME_FROM='${TIME_FROM}'"
echo "TIME_TO='${TIME_TO}'"
echo "DATE_FILTER='${DATE_FILTER}'"
echo "STATUS_CODE='${STATUS_CODE}'"
echo "THRESHOLD_MS='${THRESHOLD_MS}'"
echo "IP_FILTER='${IP_FILTER}'"
echo "TAIL_N='${TAIL_N}'"
echo "NAMED_LOG='${NAMED_LOG}'"
echo "LOG_LEVEL='${LOG_LEVEL}'"
echo "SEARCH_PATTERN='${SEARCH_PATTERN}'"
