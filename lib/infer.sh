#!/bin/bash
#
# Esegue l'inferenza della rete e restituisce i tool da invocare.
# Uscita: lista di nomi tool (uno per riga) con probabilità >= TOOL_THRESHOLD.
#
# Uso: ./lib/infer.sh "errori 500 delle ultime 3 ore"
# Richiede: PROFILE_DIR esportata dal chiamante.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] infer: PROFILE_DIR non impostata" >&2
    exit 1
fi

# ANALYZER_DIR va calcolato PRIMA di sourciare domain.conf: da NLP-1 quel file ha
# bisogno di TOOLS_CONF_FILE, che è risolto da lib/nlp-paths.sh — a sua volta
# raggiungibile solo da ANALYZER_DIR. L'ordine precedente (domain.conf prima)
# funzionava per caso, perché domain.conf non aveva dipendenze esterne.
#
# nlp_resolve_paths() è chiamata in proprio e non si affida al chiamante: questo
# script è invocato sia come subprocesso da chatbot.sh (che l'ha già chiamata) sia
# direttamente dai test. È idempotente — pochi stat — quindi chiamarla comunque è
# la scelta robusta.
ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ANALYZER_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 1

source "$PROFILE_DIR/domain.conf"
source "$ANALYZER_DIR/lib/utils-log.sh"
source "$ANALYZER_DIR/lib/nc-common.sh"

LIB_DIR="$ANALYZER_DIR/lib"

query="$1"
if [[ -z "$query" ]]; then
    echo "[ERROR] query mancante" >&2
    exit 1
fi

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non trovato: $MODEL_DIR — esegui prima ./train.sh --profile" >&2
    exit 1
fi

features=$("$LIB_DIR/query-to-features.sh" "$query")

probs=$(nc_predict "$MODEL_DIR" "$NUM_TOOLS" $features) || exit 1

i=0
for prob in $probs; do
    tool="${TOOL_NAMES[$i]}"
    if awk -v p="$prob" -v t="$TOOL_THRESHOLD" 'BEGIN { exit (p >= t) ? 0 : 1 }'; then
        echo "$tool $prob"
    fi
    i=$((i + 1))
done
