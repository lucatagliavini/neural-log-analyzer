#!/bin/bash
#
# Genera il dataset di training da profiles/<n>/dataset/queries_labeled.txt.
# Output: profiles/<n>/dataset/queries.txt
#
# Uso: ./build-dataset.sh --profile <dir>
# Es:  ./build-dataset.sh --profile profiles/liquido
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

PROFILE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./build-dataset.sh --profile profiles/liquido" >&2
    exit 1
fi

export PROFILE_DIR
source "$PROFILE_DIR/domain.conf"
source "$PROFILE_DIR/vocab.sh"

LABELED="$PROFILE_DIR/dataset/queries_labeled.txt"
DATASET_FILE="$PROFILE_DIR/dataset/queries.txt"

if [[ ! -f "$LABELED" ]]; then
    echo "[ERROR] File sorgente non trovato: $LABELED" >&2
    exit 1
fi

echo "# Neural Log Analyzer — intent classification dataset" > "$DATASET_FILE"
echo "# Profilo: $(basename "$PROFILE_DIR") | ${NUM_FEATURES:-?} feature + $NUM_TOOLS tool output (multi-label)" >> "$DATASET_FILE"
echo "# Generato da build-dataset.sh — non modificare a mano" >> "$DATASET_FILE"

count=0
while IFS=$'\t' read -r labels query; do
    [[ -z "$query" || "$query" == \#* ]] && continue

    features=$("$LIB_DIR/query-to-features.sh" "$query")

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

    # Scarta esempi con vettore output tutto-zero (label non riconosciuto)
    has_label=0
    for v in "${output_vec[@]}"; do [[ "$v" != "0" ]] && { has_label=1; break; }; done
    [[ "$has_label" -eq 0 ]] && { echo "[WARN] build-dataset: label sconosciuto '$labels', riga scartata" >&2; continue; }

    echo "$features ${output_vec[*]}" >> "$DATASET_FILE"
    count=$((count + 1))
done < "$LABELED"

echo "[OK] Dataset generato: $count esempi → $DATASET_FILE"
