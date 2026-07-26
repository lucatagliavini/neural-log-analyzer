#!/bin/bash
#
# Genera il dataset di training da esempi etichettati in dataset/queries_labeled.txt
# Formato sorgente: <etichette_tool_separati_da_virgola> TAB <testo_query>
# Esempio:  count_status,distribute_status   quanti errori 500 ci sono stati oggi
#
# Output: dataset/queries.txt (formato framework: 50 feature + 10 output)
#

set -euo pipefail
source "$(dirname "$0")/config.sh"

LABELED="$ANALYZER_DIR/dataset/queries_labeled.txt"

if [[ ! -f "$LABELED" ]]; then
    echo "[ERROR] File sorgente non trovato: $LABELED" >&2
    exit 1
fi

echo "# Neural Log Analyzer — intent classification dataset" > "$DATASET_FILE"
echo "# 50 feature input (keyword presence) + 10 tool output (multi-label)" >> "$DATASET_FILE"
echo "# Generato da build-dataset.sh" >> "$DATASET_FILE"

count=0
while IFS=$'\t' read -r labels query; do
    [[ -z "$query" || "$query" == \#* ]] && continue

    # Genera vettore feature
    features=$("$LIB_DIR/query-to-features.sh" "$query")

    # Genera vettore output: 1.0 per il tool primario (primo nella lista etichette),
    # 0.7 per tool secondari (soft label), 0 per i tool assenti.
    IFS=',' read -ra label_list <<< "$labels"
    primary_tool="${label_list[0]}"
    output_vec=()
    for tool in "${TOOL_NAMES[@]}"; do
        if [[ "$tool" == "$primary_tool" ]]; then
            output_vec+=("1")
        elif echo "$labels" | grep -qwF "$tool"; then
            output_vec+=("0.7")
        else
            output_vec+=("0")
        fi
    done

    echo "$features ${output_vec[*]}" >> "$DATASET_FILE"
    count=$((count + 1))
done < "$LABELED"

echo "[OK] Dataset generato: $count esempi → $DATASET_FILE"
