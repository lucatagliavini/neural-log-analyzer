#!/bin/bash
#
# Addestra il classificatore di intent per un profilo.
#
# Uso: ./train.sh --profile <dir> [--epochs N] [--lr RATE] [--optimizer OPT]
# Es:  ./train.sh --profile profiles/liquido --epochs 5000
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NNET_RUN="$SCRIPT_DIR/../neural-bash/nnet-run.sh"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"
TRAIN_PY="$SCRIPT_DIR/lib/train.py"

PROFILE_DIR=""
EPOCHS=5000
LR=0.01
OPTIMIZER=adam
MIN_DELTA="0.00005"
PATIENCE=100
LOSS=mse
VAL_SPLIT=0
SEED=42
THRESHOLD=""
NO_SAVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)   PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --epochs)    EPOCHS="$2";    shift 2 ;;
        --lr)        LR="$2";        shift 2 ;;
        --optimizer) OPTIMIZER="$2"; shift 2 ;;
        --min-delta) MIN_DELTA="$2"; shift 2 ;;
        --patience)  PATIENCE="$2";  shift 2 ;;
        --loss)      LOSS="$2";      shift 2 ;;
        --val-split) VAL_SPLIT="$2"; shift 2 ;;
        --seed)      SEED="$2";      shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --no-save)   NO_SAVE="--no-save"; shift ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./train.sh --profile profiles/liquido" >&2
    exit 1
fi

if [[ "$LOSS" != "mse" && "$LOSS" != "bce" ]]; then
    echo "[ERROR] --loss deve essere 'mse' o 'bce' (ricevuto: $LOSS)" >&2
    exit 1
fi

source "$PROFILE_DIR/domain.conf"

MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
DATASET_FILE="$PROFILE_DIR/dataset/queries.txt"
LABELED_FILE="$PROFILE_DIR/dataset/queries_labeled.txt"

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non inizializzato. Esegui prima: ./setup.sh --profile $PROFILE_DIR" >&2
    exit 1
fi

if [[ ! -f "$DATASET_FILE" ]]; then
    if [[ -f "$LABELED_FILE" ]]; then
        echo "[INFO] Dataset numerico non trovato — esegui prima: ./build-dataset.sh --profile $PROFILE_DIR" >&2
    else
        echo "[ERROR] Dataset non trovato: $DATASET_FILE" >&2
        echo "        Crea $LABELED_FILE e poi esegui ./build-dataset.sh --profile $PROFILE_DIR" >&2
    fi
    exit 1
fi

# ── Verifica coerenza topologia vocabolario ↔ modello ─────────────────────────
layer1="$MODEL_DIR/layer1.txt"
if [[ -f "$layer1" ]]; then
    model_inputs=$(awk '/^[^A]/{print NF; exit}' "$layer1")
    model_inputs=$(( model_inputs - 1 ))  # rimuove colonna bias
    if [[ "$model_inputs" -ne "$NUM_FEATURES" ]]; then
        echo "[ERROR] Mismatch topologia: il modello ha $model_inputs input, il vocabolario ne ha $NUM_FEATURES." >&2
        echo "        Il vocabolario è cambiato dall'ultimo setup del modello." >&2
        echo "        Rigenera il modello con:" >&2
        echo "          ./setup.sh --profile $PROFILE_DIR" >&2
        echo "        (questo cancella i pesi esistenti e ricrea layer1.txt / layer2.txt)" >&2
        exit 1
    fi
fi

echo "[INFO] Training intent classifier — profilo: $(basename "$PROFILE_DIR")"
echo "[INFO] Dataset: $DATASET_FILE"
echo "[INFO] Epochs: $EPOCHS | LR: $LR | Optimizer: $OPTIMIZER | loss: $LOSS | min-delta: $MIN_DELTA | patience: $PATIENCE | val-split: $VAL_SPLIT"
echo ""

if [[ -x "$VENV_PYTHON" && -f "$TRAIN_PY" ]]; then
    echo "[INFO] Backend: PyTorch ($("$VENV_PYTHON" -c 'import torch; print(torch.__version__)'))"
    echo ""
    "$VENV_PYTHON" "$TRAIN_PY" "$DATASET_FILE" "$MODEL_DIR" \
        --epochs    "$EPOCHS" \
        --lr        "$LR" \
        --optimizer "$OPTIMIZER" \
        --min-delta "$MIN_DELTA" \
        --patience  "$PATIENCE" \
        --loss      "$LOSS" \
        --val-split "$VAL_SPLIT" \
        --seed      "$SEED" \
        ${THRESHOLD:+--threshold "$THRESHOLD"} \
        ${NO_SAVE}
else
    echo "[INFO] Backend: gawk (venv non trovato in $SCRIPT_DIR/.venv)"
    if [[ "$VAL_SPLIT" != "0" && "$VAL_SPLIT" != "0.0" ]]; then
        echo "[WARN] --val-split non supportato dal backend gawk — ignorato." >&2
    fi
    echo ""
    # Il framework AWK chiama la binary cross-entropy "ce", non "bce".
    AWK_LOSS="$LOSS"
    [[ "$LOSS" == "bce" ]] && AWK_LOSS="ce"
    "$NNET_RUN" train "$DATASET_FILE" "$MODEL_DIR" \
        --epochs "$EPOCHS" \
        --lr "$LR" \
        --optimizer "$OPTIMIZER" \
        --loss "$AWK_LOSS" \
        --min-delta "$MIN_DELTA" \
        --patience "$PATIENCE" \
        ${NO_SAVE}
fi

echo ""
echo "[OK] Training completato. Usa: ./chatbot.sh --profile $PROFILE_DIR"

# ── Gap report post-training ──────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/gap-report.sh" ]]; then
    bash "$SCRIPT_DIR/gap-report.sh" --profile "$PROFILE_DIR" --compact
fi
