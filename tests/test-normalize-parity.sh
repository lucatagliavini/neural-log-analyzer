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
source "$ROOT_DIR/lib/utils-python.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

# VENVGATE-1: prima qui c'era `[[ ! -x "$ROOT_DIR/.venv/bin/python3" ]] && exit 1`,
# con un messaggio che suggeriva `pip install -r requirements.txt`. Due cose
# sbagliate:
#
#   1. il venv NON è necessario — test-normalize-parity.py importa build_dataset,
#      che usa solo stdlib. Il python3 di sistema basta, e in produzione è l'unico
#      che c'è: là questo test FALLIVA per una ragione puramente ambientale, e
#      `run-tests.sh --parity` riportava un FAIL senza che nulla fosse rotto.
#   2. `exit 1` confonde "non ho potuto misurare" con "la misura è fallita".
#      Sono cose diverse e il chiamante deve poterle distinguere — la stessa
#      lezione di GAPREP-1, dove gap-report.sh dichiarava «nessun gap» per una
#      misura mai avvenuta.
#
# Ora: exit 2 = non misurabile (nessun python3), riportato da run-tests.sh come
# «NON eseguito» e non come PASS né come FAIL.
PY="$(resolve_python || true)"
if [[ -z "$PY" ]]; then
    echo "[UNAVAILABLE] parità non misurata: nessun python3 disponibile." >&2
    echo "              Il confronto bash/Python richiede un interprete; non è" >&2
    echo "              un fallimento della parità, è una misura non eseguita." >&2
    exit 2
fi

exec "$PY" "$SCRIPT_DIR/test-normalize-parity.py" --profile "$PROFILE_DIR"
