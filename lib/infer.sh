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

source "$PROFILE_DIR/domain.conf"

ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NNET_RUN="$ANALYZER_DIR/../neural-bash/nnet-run.sh"
MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
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

dummy_out=$(printf '0 %.0s' $(seq 1 "$NUM_TOOLS") | sed 's/ $//')
tmp_ds=$(mktemp)
echo "# query features dummy_output" > "$tmp_ds"
echo "$features $dummy_out" >> "$tmp_ds"

raw_output=$("$NNET_RUN" predict "$tmp_ds" "$MODEL_DIR" 2>/dev/null)
rm -f "$tmp_ds"

probs=$(echo "$raw_output" | awk '/^\s*1\s*\|/{
    sub(/^\s*[0-9]+\s*\|\s*/, "")
    sub(/\s*\|.*/, "")
    print
    exit
}')

i=0
for prob in $probs; do
    tool="${TOOL_NAMES[$i]}"
    if awk -v p="$prob" -v t="$TOOL_THRESHOLD" 'BEGIN { exit (p >= t) ? 0 : 1 }'; then
        echo "$tool $prob"
    fi
    i=$((i + 1))
done
