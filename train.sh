#!/bin/bash
#
# Addestra il classificatore di intent sul dataset queries.txt.
#
# Uso: ./train.sh [--epochs N] [--lr RATE] [--optimizer OPT]
#

set -euo pipefail
source "$(dirname "$0")/config.sh"

EPOCHS=5000
LR=0.01
OPTIMIZER=adam
MIN_DELTA="0.00005"
PATIENCE=100

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epochs)    EPOCHS="$2";    shift 2 ;;
        --lr)        LR="$2";        shift 2 ;;
        --optimizer) OPTIMIZER="$2"; shift 2 ;;
        --min-delta) MIN_DELTA="$2"; shift 2 ;;
        --patience)  PATIENCE="$2";  shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non inizializzato. Esegui prima ./setup.sh" >&2
    exit 1
fi

if [[ ! -f "$DATASET_FILE" ]]; then
    echo "[ERROR] Dataset non trovato: $DATASET_FILE" >&2
    echo "        Esegui ./build-dataset.sh per generarlo." >&2
    exit 1
fi

echo "[INFO] Training intent classifier"
echo "[INFO] Dataset: $DATASET_FILE"
echo "[INFO] Epochs: $EPOCHS | LR: $LR | Optimizer: $OPTIMIZER | min-delta: $MIN_DELTA | patience: $PATIENCE"
echo ""

"$NNET_RUN" train "$DATASET_FILE" "$MODEL_DIR" \
    --epochs "$EPOCHS" \
    --lr "$LR" \
    --optimizer "$OPTIMIZER" \
    --loss mse \
    --min-delta "$MIN_DELTA" \
    --patience "$PATIENCE"

echo ""
echo "[OK] Training completato. Usa ./chatbot.sh per interrogare i log."
