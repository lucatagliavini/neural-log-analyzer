#!/bin/bash
#
# Addestra il classificatore di intent per un profilo.
#
# Uso: ./train.sh --profile <dir> [--epochs N] [--lr RATE] [--optimizer OPT]
# Es:  ./train.sh --profile profiles/liquido --epochs 5000
#
# Ciclo di vita (neural-c, non warm-start implicito come il vecchio backend
# PyTorch): se gli iperparametri richiesti divergono da project.conf, il
# modello viene reinizializzato con pesi freschi (flag diversi ⇒ modello
# nuovo). Se coincidono e pesi finalizzati esistono già, il training continua
# da lì per altre --epochs epoche (--additional-epochs, l'equivalente
# esplicito del vecchio warm-start implicito). Se un run precedente è stato
# interrotto, riprende dal checkpoint.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils-log.sh"
source "$SCRIPT_DIR/lib/nc-common.sh"

PROFILE_DIR=""
EPOCHS="$NC_DEFAULT_EPOCHS"
LR="$NC_DEFAULT_LR"
OPTIMIZER="$NC_DEFAULT_OPTIMIZER"
MIN_DELTA="$NC_DEFAULT_MIN_DELTA"
PATIENCE="$NC_DEFAULT_PATIENCE"
LOSS="$NC_DEFAULT_LOSS"
VAL_SPLIT="$NC_DEFAULT_VAL_SPLIT"
SEED="$NC_DEFAULT_SEED"

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

# early_stopping_patience>0 esige validation.txt in neural-c: non esiste più la
# via di mezzo del vecchio backend (early stopping sulla sola training loss).
# La scelta va fatta esplicitamente, non aggirata con un default silenzioso.
if [[ "$PATIENCE" -gt 0 ]] && ! nc_num_diff "$VAL_SPLIT" "0"; then
    echo "[ERROR] --patience > 0 richiede --val-split > 0: neural-c esige validation.txt per l'early stopping." >&2
    echo "        Usa --val-split 0 insieme a --patience 0 per il training a epoche fisse." >&2
    exit 1
fi

# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1).
source "$SCRIPT_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"


if [[ ! -f "$MODEL_DIR/project.conf" ]]; then
    echo "[ERROR] Modello non inizializzato. Esegui prima: ./setup.sh --profile $PROFILE_DIR" >&2
    exit 1
fi

DATASET_MASTER="$MODEL_DIR/dataset.txt"
if [[ ! -f "$DATASET_MASTER" ]]; then
    echo "[ERROR] Dataset neural-c non trovato: $DATASET_MASTER" >&2
    echo "        Esegui prima: ./build-dataset.sh --profile $PROFILE_DIR" >&2
    exit 1
fi

# ── Verifica coerenza topologia vocabolario ↔ modello (ARCH-4, portata su model.txt) ──
model_txt="$MODEL_DIR/model.txt"
if [[ -f "$model_txt" ]]; then
    model_inputs=$(awk '/^input /{print $2; exit}' "$model_txt")
    if [[ "$model_inputs" -ne "$NUM_FEATURES" ]]; then
        echo "[ERROR] Mismatch topologia: il modello ha $model_inputs input, il vocabolario ne ha $NUM_FEATURES." >&2
        echo "        Il vocabolario è cambiato dall'ultimo setup del modello." >&2
        echo "        Rigenera il modello con:" >&2
        echo "          ./setup.sh --profile $PROFILE_DIR" >&2
        exit 1
    fi
fi

echo "[INFO] Training intent classifier — profilo: $(basename "$PROFILE_DIR")"
echo "[INFO] Dataset: $DATASET_MASTER"
echo "[INFO] Epochs: $EPOCHS | LR: $LR | Optimizer: $OPTIMIZER | loss: $LOSS | min-delta: $MIN_DELTA | patience: $PATIENCE | val-split: $VAL_SPLIT | seed: $SEED"
echo ""

# ── Decisione di ciclo di vita: iperparametri divergenti ⇒ modello nuovo ──────
cur_epochs=$(nc_project_conf_get "$MODEL_DIR" epochs || echo "")
cur_lr=$(nc_project_conf_get "$MODEL_DIR" learning_rate || echo "")
cur_optimizer=$(nc_project_conf_get "$MODEL_DIR" optimizer || echo "")
cur_loss=$(nc_project_conf_get "$MODEL_DIR" loss || echo "")
cur_seed=$(nc_project_conf_get "$MODEL_DIR" seed || echo "")
cur_patience=$(nc_project_conf_get "$MODEL_DIR" early_stopping_patience || echo "0")
cur_min_delta=$(nc_project_conf_get "$MODEL_DIR" early_stopping_min_delta || echo "0")

hp_diverge=0
nc_num_diff "$cur_epochs" "$EPOCHS" && hp_diverge=1
nc_num_diff "$cur_lr" "$LR" && hp_diverge=1
nc_str_diff "$cur_optimizer" "$OPTIMIZER" && hp_diverge=1
nc_str_diff "$cur_loss" "$LOSS" && hp_diverge=1
nc_num_diff "$cur_seed" "$SEED" && hp_diverge=1
nc_num_diff "$cur_patience" "$PATIENCE" && hp_diverge=1
nc_num_diff "$cur_min_delta" "$MIN_DELTA" && hp_diverge=1

if [[ "$hp_diverge" -eq 1 ]]; then
    echo "[INFO] Iperparametri diversi da project.conf — reinizializzo il modello (pesi freschi)."
    nc_init_project "$MODEL_DIR" "$MODEL_TOPOLOGY" \
        "$EPOCHS" "$LR" "$OPTIMIZER" "$LOSS" "$SEED" "$PATIENCE" "$MIN_DELTA"
fi

# ── Split stratificato (solo se early stopping richiesto) ──────────────────────
# Rieseguito ad ogni training: dataset.txt può essere cambiato (nuovi esempi
# labeled), quindi train.txt/validation.txt vanno rigenerati sempre, non solo
# quando gli iperparametri divergono.
if [[ "$PATIENCE" -gt 0 ]]; then
    gawk -v val_split="$VAL_SPLIT" -v seed="$SEED" \
        -v out_train="$MODEL_DIR/train.txt" -v out_val="$MODEL_DIR/validation.txt" \
        -f "$SCRIPT_DIR/lib/stratified-split.awk" "$DATASET_MASTER"
else
    cp "$DATASET_MASTER" "$MODEL_DIR/train.txt"
    rm -f "$MODEL_DIR/validation.txt"
fi

# ── Scelta del comando train in base allo stato del progetto ──────────────────
weights_exist=0; checkpoint_exist=0
[[ -f "$MODEL_DIR/weights.txt" ]] && weights_exist=1
[[ -f "$MODEL_DIR/checkpoint.txt" ]] && checkpoint_exist=1

if [[ "$checkpoint_exist" -eq 1 ]]; then
    echo "[INFO] Checkpoint di un run interrotto trovato — riprendo (--resume)."
    "$NC_BIN" train "$MODEL_DIR" --resume --history --report-interval 10
elif [[ "$weights_exist" -eq 1 ]]; then
    echo "[INFO] Pesi finalizzati esistenti — continuo per altre $EPOCHS epoche (--additional-epochs)."
    "$NC_BIN" train "$MODEL_DIR" --additional-epochs "$EPOCHS" --history --report-interval 10
else
    echo "[INFO] Nessun peso esistente — training da zero."
    "$NC_BIN" train "$MODEL_DIR" --history --report-interval 10
fi

echo ""
"$NC_BIN" inspect "$MODEL_DIR" --state

echo ""
echo "[OK] Training completato. Usa: ./chatbot.sh --profile $PROFILE_DIR"

# ── Gap report post-training ──────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/gap-report.sh" ]]; then
    bash "$SCRIPT_DIR/gap-report.sh" --profile "$PROFILE_DIR" --compact
fi
