#!/bin/bash
#
# test-train-regression.sh — verifica che lib/train.py produca sempre gli stessi
# pesi a parita' di input. train.py e' deterministico (nessun random.shuffle,
# full-batch gradient descent), quindi stesso seed + stesso dataset + stessi
# iperparametri devono dare pesi bit-identici, run dopo run.
#
# Se questo test fallisce dopo una modifica a train.py, la modifica ha alterato
# il comportamento di default (non solo aggiunto una capacita' opt-in) — va
# capito se e' voluto prima di procedere.
#
# Uso: bash tests/test-train-regression.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NNET_INIT="$ROOT_DIR/../neural-bash/nnet-init.sh"
TRAIN_PY="$ROOT_DIR/lib/train.py"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python3"
DATASET="$ROOT_DIR/profiles/liquido/dataset/queries.txt"

WORK="$ROOT_DIR/tmp/train-regression-$$"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

RED="\033[31m"; GREEN="\033[32m"; RESET="\033[0m"

# Checksum di riferimento — presi da un run pre-modifica il 2026-08-03, quando
# --loss/--val-split sono stati aggiunti (default = comportamento identico,
# verificato a mano allora; qui lo si fissa una volta per tutte).
EXPECTED_L1="7b526733610bdfa8da152fba674e4364"
EXPECTED_L2="ed37e5cdeeb9bf52a4438b83b6ba7cfe"

echo "[INFO] Genero pesi freschi (seed 7, topologia 117,48,15)..."
"$NNET_INIT" "$WORK/model" 117,48,15 --activation sigmoid --method xavier --seed 7 --force > /dev/null

echo "[INFO] Training deterministico: 200 epoche, patience 0 (no early stop)..."
"$VENV_PYTHON" "$TRAIN_PY" "$DATASET" "$WORK/model" \
    --epochs 200 --lr 0.01 --optimizer adam --min-delta 0.00005 --patience 0 \
    > "$WORK/train.log" 2>&1

got_l1=$(md5sum "$WORK/model/layer1.txt" | awk '{print $1}')
got_l2=$(md5sum "$WORK/model/layer2.txt" | awk '{print $1}')

fail=0
if [[ "$got_l1" != "$EXPECTED_L1" ]]; then
    echo -e "${RED}[FAIL]${RESET} layer1.txt: atteso $EXPECTED_L1, ottenuto $got_l1"
    fail=1
fi
if [[ "$got_l2" != "$EXPECTED_L2" ]]; then
    echo -e "${RED}[FAIL]${RESET} layer2.txt: atteso $EXPECTED_L2, ottenuto $got_l2"
    fail=1
fi

if [[ "$fail" -eq 0 ]]; then
    echo -e "${GREEN}[OK]${RESET} train.py deterministico — pesi bit-identici al riferimento."
else
    echo ""
    echo "Log del training: $WORK/train.log (rimosso all'uscita — rilanciare senza trap per ispezionarlo)"
    exit 1
fi
