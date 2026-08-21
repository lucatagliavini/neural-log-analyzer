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

# NUM_FEATURES / NUM_TOOLS / MODEL_TOPOLOGY vengono LETTI dalla fonte di verità
# (nlp/tools.conf, dove NUM_FEATURES = |UNIGRAMS| + |BIGRAMS|), non riscritti qui.
# Fino al 2026-08-21 c'era `NUM_FEATURES=115` letterale: al retrain a 119 feature
# questo test è diventato l'unico FAIL della suite, e il messaggio parlava di un
# checksum sbagliato — che è il sintomo, non la causa. Con la topologia ferma a
# 115 su un dataset a 119 colonne la conversione awk qui sotto produce righe con
# 4 input in meno e 4 output in più: il dataset si sfalsa e i pesi cambiano per
# una ragione che non ha nulla a che vedere con la riproducibilità di neural-c,
# cioè l'unica cosa che questo test deve misurare (principio 2 — era lo stesso
# fatto in due posti; il commento su TOPOLOGY più sotto lo diceva già, ma si era
# fermato un livello troppo in basso).
#
# Volutamente NON si passa per nlp_resolve_paths(): quella risolve profilo →
# framework, e un profilo con vocabolario proprio renderebbe il checksum pinnato
# valido solo per quel profilo. Qui si testano gli artefatti del framework, gli
# stessi da cui viene $DATASET.
UNIGRAMS_FILE="$ROOT_DIR/nlp/unigrams.txt"
BIGRAMS_FILE="$ROOT_DIR/nlp/bigrams.txt"
source "$ROOT_DIR/nlp/tools.conf"

WORK="$ROOT_DIR/tmp/train-regression-$$"
rm -rf "$WORK"
mkdir -p "$WORK/model"
trap 'rm -rf "$WORK"' EXIT

RED="\033[31m"; GREEN="\033[32m"; RESET="\033[0m"

# Checksum di riferimento — rigenerato il 2026-08-21 (VOCFIX-1: ancoraggio \b su
# `per`/`ora`/i codici di stato, 4 feature nuove, 115 → 119, più 46 esempi),
# verificato bit-identico su 3 run consecutivi sulla stessa macchina.
#
# Nota: questo checksum dipende da (topologia, dataset, seed, iperparametri).
# Qualsiasi modifica al vocabolario o a queries_labeled.txt lo invalida per
# costruzione — in quel caso rigenerarlo, non "aggiustarlo", e verificare che
# la riproducibilità regga su almeno 3 run consecutivi.
#
# Storia dei riferimenti, utile per riconoscere una regressione da una modifica
# voluta: 111 feature fino al 2026-08-19, 113 con SRCH-2/QUOTE-1, 114 con C2 (<ip>),
# 115 con FLEX-1b (fallit|fallim|fallis), 119 con VOCFIX-1 (secondi\b, superat|oltre\b,
# comand, + il bigram quantificatore×codice).
EXPECTED_WEIGHTS_MD5="7e6fc068d442369f7bb2599109cf6fab"

# La topologia deve combaciare con NUM_FEATURES: righe con un numero di colonne
# diverso da num_features+num_outputs vengono scartate dalla conversione sotto, e
# con dataset e topologia disallineati il dataset si svuota (train fallirebbe con
# un errore esplicito). Ora viene da MODEL_TOPOLOGY, che tools.conf calcola già.
TOPOLOGY="$MODEL_TOPOLOGY"
HIDDEN="$(cut -d, -f2 <<< "$MODEL_TOPOLOGY")"

# Guard esplicita sul disallineamento vocabolario ↔ dataset. Senza, il sintomo è
# un checksum diverso e il messaggio incolpa la riproducibilità di neural-c: la
# causa vera (un `./build-dataset.sh` non eseguito dopo una modifica al
# vocabolario) resta da indovinare. È la stessa forma di verifica che train.sh fa
# fra NUM_FEATURES e la riga `input N` di model.txt (ARCH-4).
_ds_cols=$(awk '!/^[[:space:]]*#/ && NF > 0 { print NF; exit }' "$DATASET")
_want_cols=$(( NUM_FEATURES + NUM_TOOLS ))
if [[ "$_ds_cols" -ne "$_want_cols" ]]; then
    echo -e "${RED}[FAIL]${RESET} $DATASET ha $_ds_cols colonne, il vocabolario ne richiede $_want_cols ($NUM_FEATURES feature + $NUM_TOOLS tool)."
    echo "       Il dataset è più vecchio del vocabolario: eseguire ./build-dataset.sh --profile profiles/liquido"
    exit 1
fi

echo "[INFO] Inizializzo il modello (seed 7, topologia $TOPOLOGY)..."
"$NC_BIN" init "$WORK/model" --inputs "$NUM_FEATURES" --layer "$HIDDEN:sigmoid" --layer "$NUM_TOOLS:sigmoid" \
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
