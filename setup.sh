#!/bin/bash
#
# Inizializza il modello di classificazione degli intent per un profilo.
#
# Uso: ./setup.sh --profile <dir>
# Es:  ./setup.sh --profile profiles/liquido
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils-log.sh"
source "$SCRIPT_DIR/lib/nc-common.sh"

PROFILE_DIR=""
SEED="$NC_DEFAULT_SEED"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --seed)    SEED="$2"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./setup.sh --profile profiles/liquido" >&2
    exit 1
fi

source "$PROFILE_DIR/system.conf"
# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1).
source "$SCRIPT_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"


echo "[INFO] neural-log-analyzer setup — profilo: $(basename "$PROFILE_DIR")"
echo "[INFO] Topologia: $MODEL_TOPOLOGY"
echo "[INFO] Modello:   $MODEL_DIR"
echo "[INFO] Seed:      $SEED (default: epochs=$NC_DEFAULT_EPOCHS lr=$NC_DEFAULT_LR optimizer=$NC_DEFAULT_OPTIMIZER loss=$NC_DEFAULT_LOSS patience=$NC_DEFAULT_PATIENCE)"
echo ""

if [[ -d "$MODEL_DIR" ]]; then
    echo "[INFO] Modello esistente trovato — verrà reinizializzato (pesi persi, sempre incondizionato)."
fi

mkdir -p "$MODEL_DIR"
nc_init_project "$MODEL_DIR" "$MODEL_TOPOLOGY" \
    "$NC_DEFAULT_EPOCHS" "$NC_DEFAULT_LR" "$NC_DEFAULT_OPTIMIZER" "$NC_DEFAULT_LOSS" \
    "$SEED" "$NC_DEFAULT_PATIENCE" "$NC_DEFAULT_MIN_DELTA"

echo ""
echo "[OK] Modello inizializzato. Ora esegui: ./build-dataset.sh --profile $PROFILE_DIR && ./train.sh --profile $PROFILE_DIR"
