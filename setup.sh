#!/bin/bash
#
# Inizializza il modello di classificazione degli intent per un profilo.
#
# Uso: ./setup.sh --profile <dir>
# Es:  ./setup.sh --profile profiles/liquido
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NNET_INIT="$SCRIPT_DIR/../neural-bash/nnet-init.sh"

PROFILE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./setup.sh --profile profiles/liquido" >&2
    exit 1
fi

source "$PROFILE_DIR/system.conf"
source "$PROFILE_DIR/domain.conf"

MODEL_DIR="$PROFILE_DIR/models/intent_classifier"

echo "[INFO] neural-log-analyzer setup — profilo: $(basename "$PROFILE_DIR")"
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
echo "[OK] Modello inizializzato. Ora esegui: ./train.sh --profile $PROFILE_DIR"
