#!/bin/bash
#
# Genera il dataset di training da profiles/<n>/dataset/queries_labeled.txt.
# Output: profiles/<n>/dataset/queries.txt
#
# Uso: ./build-dataset.sh --profile <dir>
# Es:  ./build-dataset.sh --profile profiles/liquido
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

PROFILE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./build-dataset.sh --profile profiles/liquido" >&2
    exit 1
fi

export PROFILE_DIR

# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1). Spostata PRIMA della scelta del backend perché
# entrambi i backend — e il passo train.txt condiviso in coda — hanno bisogno
# di MODEL_DIR/DATASET_FILE, non solo il ramo bash.
source "$LIB_DIR/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"   # carica vocabolario e configurazione dominio

# Backend Python (se disponibile): 1900× più veloce — nessun fork per riga
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"
BUILD_PY="$SCRIPT_DIR/lib/build_dataset.py"
if [[ -x "$VENV_PYTHON" && -f "$BUILD_PY" ]]; then
    echo "[INFO] Backend: Python ($("$VENV_PYTHON" -c 'import sys; print(sys.version.split()[0])'))"
    "$VENV_PYTHON" "$BUILD_PY" --profile "$PROFILE_DIR"
    build_status=$?
else
    echo "[INFO] Backend: bash (venv non trovato in $SCRIPT_DIR/.venv)"

    # Pre-carica entities.conf se disponibile per la normalizzazione degli esempi
    _ENTITIES_CONF="$PROFILE_DIR/entities.conf"

    LABELED="$LABELED_FILE"
    # DATASET_FILE già esportata da nlp_resolve_paths

    if [[ ! -f "$LABELED" ]]; then
        echo "[ERROR] File sorgente non trovato: $LABELED" >&2
        exit 1
    fi

    echo "# Neural Log Analyzer — intent classification dataset" > "$DATASET_FILE"
    echo "# Profilo: $(basename "$PROFILE_DIR") | ${NUM_FEATURES:-?} feature + $NUM_TOOLS tool output (multi-label)" >> "$DATASET_FILE"
    echo "# Generato da build-dataset.sh — non modificare a mano" >> "$DATASET_FILE"

    count=0
    zero_vec_count=0
    declare -a zero_vec_examples=()

    while IFS=$'\t' read -r labels query; do
        [[ -z "$query" || "$query" == \#* || "$labels" == \#* ]] && continue

        # Normalizza la query (sostituisce alias app/env/node con placeholder canonici)
        # prima della vectorizzazione, così il modello impara i pattern generici.
        if [[ -f "$_ENTITIES_CONF" ]]; then
            unset NORM_QUERY DETECTED_APP DETECTED_ENV DETECTED_NODE
            source <("$LIB_DIR/normalize-query.sh" "$query" 2>/dev/null)
            export NORM_QUERY
        fi

        features=$("$LIB_DIR/query-to-features.sh" "$query")

        # Linter: vettore feature tutto-zero → la query non attiva alcun pattern del vocab
        if echo "$features" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i+0; exit (s==0)?0:1}'; then
            zero_vec_count=$(( zero_vec_count + 1 ))
            zero_vec_examples+=("[$labels] \"$query\"")
        fi

        IFS=',' read -ra label_list <<< "$labels"
        primary_tool="${label_list[0]}"
        output_vec=()
        for tool in "${TOOL_NAMES[@]}"; do
            if [[ "$tool" == "$primary_tool" ]]; then
                output_vec+=("1")
            elif echo "$labels" | grep -qwF "$tool"; then
                output_vec+=("0.7")
            else
                output_vec+=("0")
            fi
        done

        # Scarta esempi con vettore output tutto-zero (label non riconosciuto)
        has_label=0
        for v in "${output_vec[@]}"; do [[ "$v" != "0" ]] && { has_label=1; break; }; done
        [[ "$has_label" -eq 0 ]] && { echo "[WARN] build-dataset: label sconosciuto '$labels', riga scartata" >&2; continue; }

        echo "$features ${output_vec[*]}" >> "$DATASET_FILE"
        count=$((count + 1))
    done < "$LABELED"

    echo "[OK] Dataset generato: $count esempi → $DATASET_FILE"

    # ─── Linter: report vettori zero ──────────────────────────────────────
    if [[ "$zero_vec_count" -gt 0 ]]; then
        echo "" >&2
        echo "[WARN] vocab-linter: $zero_vec_count esempi con feature vector tutto-zero (la rete non può imparare da questi):" >&2
        for ex in "${zero_vec_examples[@]}"; do
            echo "         → $ex" >&2
        done
        echo "" >&2
        echo "       Suggerimento: estendi unigrams.txt con un pattern che copra queste query," >&2
        echo "       oppure riformula gli esempi usando termini già nel vocabolario." >&2
    fi

    build_status=0
fi

if [[ "$build_status" -ne 0 ]]; then
    exit "$build_status"
fi

# ─── neural-c: dataset.txt, solo passo aggiuntivo dopo queries.txt ────────────
# Non un generatore separato: le due viste dello stesso dataset nascerebbero da
# comandi diversi e divergerebbero senza che nulla lo segnali. Incondizionato
# (non più opt-in su una sottocartella neural-c/): neural-c è l'unico backend,
# quindi ogni build-dataset.sh produce anche l'input che train.sh userà.
# Nome "dataset.txt", non "train.txt": il file qui è il dataset COMPLETO e non
# ancora splittato — lo split train/validation è responsabilità di train.sh
# (lib/stratified-split.awk), rieseguito ad ogni training perché dipende da
# iperparametri (val-split) che qui non sono ancora noti.
NC_DATASET_FILE="$MODEL_DIR/dataset.txt"
mkdir -p "$MODEL_DIR"
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
    ' "$DATASET_FILE"
} > "$NC_DATASET_FILE"
nc_rows=$(grep -c ' -> ' "$NC_DATASET_FILE")
echo "[OK] dataset.txt (neural-c) rigenerato: $nc_rows righe → $NC_DATASET_FILE"
