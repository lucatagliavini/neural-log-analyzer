#!/bin/bash
#
# Esegue l'inferenza della rete e restituisce i tool da invocare.
# Uscita: lista di nomi tool (uno per riga) con probabilità >= TOOL_THRESHOLD.
#
# Uso: ./lib/infer.sh "errori 500 delle ultime 3 ore"
#

source "$(dirname "$0")/../config.sh"

query="$1"

if [[ -z "$query" ]]; then
    echo "[ERROR] query mancante" >&2
    exit 1
fi

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non trovato: $MODEL_DIR — esegui prima ./train.sh" >&2
    exit 1
fi

# Converte la query in vettore di feature
features=$("$LIB_DIR/query-to-features.sh" "$query")

# Crea dataset temporaneo a una riga (feature + dummy output 0×NUM_TOOLS)
dummy_out=$(printf '0 %.0s' $(seq 1 "$NUM_TOOLS") | sed 's/ $//')
tmp_ds=$(mktemp)
echo "# query features dummy_output" > "$tmp_ds"
echo "$features $dummy_out" >> "$tmp_ds"

# Esegui inferenza con il framework
raw_output=$("$NNET_RUN" predict "$tmp_ds" "$MODEL_DIR" 2>/dev/null)
rm -f "$tmp_ds"

# Estrai le probabilità dalla riga delle predizioni:
# formato: "1        | 0.956 0.091 ... | 0 0 ... | ✓ CORRECT"
# Il primo blocco tra | contiene le probabilità predette.
probs=$(echo "$raw_output" | awk '/^\s*1\s*\|/{
    # Taglia dalla prima | fino alla seconda |
    sub(/^\s*[0-9]+\s*\|\s*/, "")   # rimuove "1 |"
    sub(/\s*\|.*/, "")               # rimuove tutto da | in poi
    print
    exit
}')

# Seleziona tool con probabilità >= soglia
i=0
for prob in $probs; do
    tool="${TOOL_NAMES[$i]}"
    if awk "BEGIN { exit ($prob >= $TOOL_THRESHOLD) ? 0 : 1 }"; then
        echo "$tool $prob"
    fi
    i=$((i + 1))
done
