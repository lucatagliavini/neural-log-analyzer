#!/bin/bash
#
# test-train-regression.sh — verifica che neural-c produca sempre gli stessi
# pesi a parita' di input. neural-c e' bit-riproducibile per costruzione sulla
# stessa macchina (ordine di riduzione fisso, indipendente da --threads, somma
# compensata di Neumaier — vedi Fase 3 esperimento 5 nel piano di migrazione),
# quindi stesso seed + stesso dataset + stessi iperparametri devono dare pesi
# bit-identici, run dopo run — senza il vincolo single-thread che serviva a
# PyTorch (nnet-run.sh/train.py sono stati rimossi, vedi CLAUDE.md).
#
# Se questo test fallisce dopo una modifica al training, la modifica ha
# alterato il comportamento di default (non solo aggiunto una capacita'
# opt-in) — va capito se e' voluto prima di procedere.
#
# Uso: bash tests/test-train-regression.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NC_BIN="$ROOT_DIR/../neural-c/neural-c.sh"
# Il dataset vive nel framework da NLP-1 (2026-08-17), non più nel profilo.
DATASET="$ROOT_DIR/nlp/dataset/queries.txt"
NUM_FEATURES=114

WORK="$ROOT_DIR/tmp/train-regression-$$"
rm -rf "$WORK"
mkdir -p "$WORK/model"
trap 'rm -rf "$WORK"' EXIT

RED="\033[31m"; GREEN="\033[32m"; RESET="\033[0m"

# Checksum di riferimento — rigenerato il 2026-08-20 (C2: nuova feature <ip>,
# 113 → 114, più 20 esempi per C1/C2), verificato bit-identico su 3 run consecutivi
# sulla stessa macchina.
#
# Nota: questo checksum dipende da (topologia, dataset, seed, iperparametri).
# Qualsiasi modifica al vocabolario o a queries_labeled.txt lo invalida per
# costruzione — in quel caso rigenerarlo, non "aggiustarlo", e verificare che
# la riproducibilità regga su almeno 3 run consecutivi.
#
# Storia dei riferimenti, utile per riconoscere una regressione da una modifica
# voluta: 111 feature fino al 2026-08-19, 113 con SRCH-2/QUOTE-1, 114 da C2.
EXPECTED_WEIGHTS_MD5="4ffd799112a0ab14d25383d19983b56c"

# La topologia deve combaciare con NUM_FEATURES del profilo: righe con un numero
# di colonne diverso da num_features+num_outputs vengono scartate dalla
# conversione sotto, e con dataset e topologia disallineati il dataset si
# svuota (train fallirebbe con un errore esplicito).
# Derivata da NUM_FEATURES invece di riscritta a mano: erano lo stesso fatto in due
# posti (più `--inputs` sotto, tre), e tenerli allineati a mano è precisamente il
# modo in cui una divergenza passa inosservata (principio 2).
TOPOLOGY="${NUM_FEATURES},48,16"

echo "[INFO] Inizializzo il modello (seed 7, topologia $TOPOLOGY)..."
"$NC_BIN" init "$WORK/model" --inputs "$NUM_FEATURES" --layer 48:sigmoid --layer 16:sigmoid \
    --loss mse --optimizer adam --learning-rate 0.01 --seed 7 --epochs 200 --force > /dev/null

# DOPO l'init, non prima: `init` scrive un train.txt scaffold col solo commento
# di esempio quando il file non esiste ancora — scriverlo prima verrebbe
# sovrascritto dallo scaffold.
echo "[INFO] Convertendo $DATASET nel formato neural-c..."
{
    echo "neural-c dataset 1"
    echo ""
    awk -v nf="$NUM_FEATURES" '
        /^[[:space:]]*#/ { next }
        NF == 0 { next }
        {
            row = $1
            for (i = 2; i <= nf; i++) row = row " " $i
            row = row " ->"
            for (i = nf + 1; i <= NF; i++) row = row " " $i
            print row
        }
    ' "$DATASET"
} > "$WORK/model/train.txt"

echo "[INFO] Training deterministico: 200 epoche, patience 0 (no early stop)..."
"$NC_BIN" train "$WORK/model" > "$WORK/train.log" 2>&1

got_weights=$(md5sum "$WORK/model/weights.txt" | awk '{print $1}')

fail=0
if [[ "$EXPECTED_WEIGHTS_MD5" == "__PLACEHOLDER__" ]]; then
    echo "[INFO] Checksum di riferimento non ancora pinnato — valore ottenuto: $got_weights"
elif [[ "$got_weights" != "$EXPECTED_WEIGHTS_MD5" ]]; then
    echo -e "${RED}[FAIL]${RESET} weights.txt: atteso $EXPECTED_WEIGHTS_MD5, ottenuto $got_weights"
    fail=1
fi

if [[ "$fail" -eq 0 ]]; then
    echo -e "${GREEN}[OK]${RESET} neural-c deterministico — pesi bit-identici al riferimento."
else
    echo ""
    echo "Log del training: $WORK/train.log (rimosso all'uscita — rilanciare senza trap per ispezionarlo)"
    exit 1
fi
