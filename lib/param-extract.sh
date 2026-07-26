#!/bin/bash
#
# Estrae parametri strutturati da una query in linguaggio naturale.
# Emette variabili shell: TIME_WINDOW, STATUS_CODE, THRESHOLD_MS, IP_FILTER, TAIL_N
#
# Uso: eval "$(./lib/param-extract.sh "errori 500 delle ultime 3 ore")"
#

query="${1,,}"

# Finestra temporale: "ultime N ore" / "ultimi N minuti" / "ultimo giorno"
TIME_WINDOW=""
if   echo "$query" | grep -qE "ultim[aei] ([0-9]+) or"; then
    h=$(echo "$query" | grep -oE "([0-9]+) or" | grep -oE "[0-9]+")
    TIME_WINDOW="${h}h"
elif echo "$query" | grep -qE "ultim[aei] ([0-9]+) minut"; then
    m=$(echo "$query" | grep -oE "([0-9]+) minut" | grep -oE "[0-9]+")
    TIME_WINDOW="${m}m"
elif echo "$query" | grep -qE "ultim[aei] (ora|giorn|giorno)"; then
    echo "$query" | grep -q "giorn" && TIME_WINDOW="24h" || TIME_WINDOW="1h"
fi

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

# Numero di righe per tail
TAIL_N="50"
if echo "$query" | grep -qE "ultim[ei] [0-9]+"; then
    TAIL_N=$(echo "$query" | grep -oE "ultim[ei] [0-9]+" | grep -oE "[0-9]+" | head -1)
fi

echo "TIME_WINDOW='${TIME_WINDOW}'"
echo "STATUS_CODE='${STATUS_CODE}'"
echo "THRESHOLD_MS='${THRESHOLD_MS}'"
echo "IP_FILTER='${IP_FILTER}'"
echo "TAIL_N='${TAIL_N}'"
