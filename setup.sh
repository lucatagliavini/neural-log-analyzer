#!/bin/bash
#
# Inizializza il modello di classificazione degli intent.
# Crea la rete con la topologia configurata e salva in models/intent_classifier/.
#
# Uso: ./setup.sh
#

set -euo pipefail
source "$(dirname "$0")/config.sh"

echo "[INFO] neural-log-analyzer setup"
echo "[INFO] Topologia: $MODEL_TOPOLOGY"
echo "[INFO] Modello:   $MODEL_DIR"
echo ""

if [[ -d "$MODEL_DIR" ]]; then
    echo "[INFO] Modello esistente trovato. Uso --force per reinizializzare."
fi

"$NNET_INIT" "$MODEL_DIR" "$MODEL_TOPOLOGY" \
    --activation sigmoid \
    --method xavier \
    --force

echo ""
echo "[OK] Modello inizializzato. Ora esegui ./train.sh per addestrarlo."
