#!/bin/bash
#
# test-normalize-parity.sh — parita' bash/Python sulla normalizzazione entita'.
#
# lib/normalize-query.sh (produzione, chatbot.sh) e
# lib/build_dataset.normalize_query() (rebuild dataset, ~100x piu' veloce)
# sono due implementazioni indipendenti della stessa logica. Questo test
# confronta NORM_QUERY su tutte le query di queries_labeled.txt: qualsiasi
# divergenza indica che una delle due e' stata modificata senza l'altra.
#
# Uso: bash tests/test-normalize-parity.sh [--profile <dir>]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$ROOT_DIR/profiles/liquido"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "[ERROR] $VENV_PYTHON non trovato — richiede .venv (pip install -r requirements.txt)" >&2
    exit 1
fi

exec "$VENV_PYTHON" "$SCRIPT_DIR/test-normalize-parity.py" --profile "$PROFILE_DIR"
