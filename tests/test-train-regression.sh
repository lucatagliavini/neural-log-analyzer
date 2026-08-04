#!/bin/bash
#
# test-train-regression.sh — verifica che lib/train.py produca sempre gli stessi
# pesi a parita' di input. train.py e' algoritmicamente deterministico (nessun
# random.shuffle, full-batch gradient descent), quindi stesso seed + stesso dataset
# + stessi iperparametri devono dare pesi bit-identici, run dopo run.
#
# Se questo test fallisce dopo una modifica a train.py, la modifica ha alterato
# il comportamento di default (non solo aggiunto una capacita' opt-in) — va
# capito se e' voluto prima di procedere.
#
# ATTENZIONE — thread e riproducibilita' bit-per-bit (verificato 2026-08-04).
# PyTorch parallelizza le op su CPU: con piu' thread l'ordine di riduzione in
# floating point non e' garantito, quindi gli md5 dei pesi VARIANO tra run pur
# essendo l'algoritmo deterministico. Misurato su 8 core: 3 run multi-thread ->
# 2 checksum distinti; 3 run con OMP_NUM_THREADS=1 -> bit-identici.
# Per questo il test forza il single-thread: senza, fallisce a intermittenza e
# il fallimento sembra una regressione di train.py quando non lo e'.
# Nota: il training di produzione (train.sh) NON forza il single-thread — la',
# la velocita' conta piu' della riproducibilita' bit-per-bit.
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

# Checksum di riferimento — rigenerati il 2026-08-04 dopo la generalizzazione dei nomi
# di log con il placeholder <LOGFILE> (BACKLOG LOGF): il vocabolario è passato da 114 a
# 108 feature e il dataset da 1008 a 1014 esempi, quindi i valori precedenti non sono
# più raggiungibili.
# Prodotti e verificati con OMP_NUM_THREADS=1 (3 run bit-identici) — vedi la nota sui
# thread in testa al file: i valori multi-thread NON sono stabili.
#
# Nota: questi checksum dipendono da (topologia, dataset, seed, iperparametri, n. thread).
# Qualsiasi modifica al vocabolario o a queries_labeled.txt li invalida per costruzione —
# in quel caso rigenerarli, non "aggiustarli", e verificare che la riproducibilità regga
# su almeno 3 run consecutivi.
EXPECTED_L1="c302165305eb23819a7dfb92800ab0da"
EXPECTED_L2="4b506c4253bba751de45bf335111b305"

# La topologia deve combaciare con NUM_FEATURES del profilo: train.py scarta le righe
# con un numero di colonne diverso da num_features+num_outputs, e con dataset e topologia
# disallineati il dataset si svuota (errore esplicito "Dataset vuoto", ma il test
# morirebbe per set -e prima del confronto checksum — vedi sessione 2026-08-04).
TOPOLOGY="108,48,15"

echo "[INFO] Genero pesi freschi (seed 7, topologia $TOPOLOGY)..."
"$NNET_INIT" "$WORK/model" "$TOPOLOGY" --activation sigmoid --method xavier --seed 7 --force > /dev/null

echo "[INFO] Training deterministico: 200 epoche, patience 0 (no early stop), 1 thread..."
# OMP/MKL a 1 thread: vedi nota sulla riproducibilita' in testa al file. Senza questo
# il test e' flaky (checksum diversi a run diversi sulla stessa macchina).
OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
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
