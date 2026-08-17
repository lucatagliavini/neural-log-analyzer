#!/bin/bash
#
# gap-report.sh — report post-training sulla qualità del vocabolario.
#
# Rileva:
#   1. Esempi con vettore feature tutto-zero (query invisibili alla rete)
#   2. Token frequenti nel dataset non coperti dal vocabolario (via vocab-gap.sh)
#
# Uso: ./gap-report.sh --profile <dir> [--min-count N] [--top N] [--compact]
#
#   --min-count N  soglia minima esempi per segnalare un token mancante (default: 2)
#   --top N        max token da mostrare per classe (default: 6)
#   --compact      stampa solo il riepilogo, senza dettaglio token (usato da train.sh)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_DIR=""
MIN_COUNT=2
TOP_N=6
COMPACT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)   PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --min-count) MIN_COUNT="$2"; shift 2 ;;
        --top)       TOP_N="$2"; shift 2 ;;
        --compact)   COMPACT=1; shift ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./gap-report.sh --profile profiles/liquido" >&2
    exit 1
fi

# Risoluzione degli artefatti NLP (vocabolario, dataset, modello): un solo punto
# di verità in lib/nlp-paths.sh. Va PRIMA di domain.conf, che ha bisogno di
# TOOLS_CONF_FILE (NLP-1).
source "$SCRIPT_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 1
source "$PROFILE_DIR/domain.conf"

DATASET_NUM="$DATASET_FILE"
LABELED="$LABELED_FILE"

if [[ ! -f "$DATASET_NUM" ]]; then
    echo "[SKIP] gap-report: dataset numerico non trovato ($DATASET_NUM)" >&2
    exit 0
fi

BOLD="\033[1m"; CYAN="\033[36m"; YELLOW="\033[33m"
RED="\033[31m"; GREEN="\033[32m"; DIM="\033[2m"; RESET="\033[0m"

# ─── Sezione 1: vettori zero ──────────────────────────────────────────────────
# Legge queries.txt (già generato) e queries_labeled.txt in parallelo per
# associare ogni riga zero al testo originale della query.

# Estrae le query dal labeled nello stesso ordine in cui build-dataset.sh le ha scritte
LABELED_QUERIES=()
while IFS=$'\t' read -r labels query; do
    [[ -z "$query" || "$query" == \#* || "$labels" == \#* ]] && continue
    LABELED_QUERIES+=("[$labels] $query")
done < "$LABELED"

# Scorre il dataset numerico contando zero-vector e raccogliendo gli indici
zero_count=0
zero_total=0
declare -a zero_examples=()
row_idx=0

while IFS= read -r line; do
    [[ "$line" =~ ^# || -z "$line" ]] && continue
    zero_total=$(( zero_total + 1 ))
    # Somma le prime NUM_FEATURES colonne
    feat_sum=$(echo "$line" | awk -v n="$NUM_FEATURES" '{s=0; for(i=1;i<=n;i++) s+=$i+0; print s}')
    if [[ "$feat_sum" -eq 0 ]]; then
        zero_count=$(( zero_count + 1 ))
        if [[ "$row_idx" -lt "${#LABELED_QUERIES[@]}" ]]; then
            zero_examples+=("${LABELED_QUERIES[$row_idx]}")
        fi
    fi
    row_idx=$(( row_idx + 1 ))
done < "$DATASET_NUM"

# ─── Intestazione ─────────────────────────────────────────────────────────────
printf "\n${BOLD}── Gap report vocabolario${RESET}  ${DIM}profilo: $(basename "$PROFILE_DIR")${RESET}\n\n"

# ─── Riepilogo zero-vector ────────────────────────────────────────────────────
if [[ "$zero_count" -eq 0 ]]; then
    printf "  ${GREEN}✓${RESET} Vettori zero: nessuno  ${DIM}(%d esempi coperti)${RESET}\n" "$zero_total"
else
    pct=$(awk "BEGIN{printf \"%.1f\", $zero_count * 100 / $zero_total}")
    col="$YELLOW"; [[ "$zero_count" -ge 5 ]] && col="$RED"
    printf "  ${col}${BOLD}! Vettori zero: %d / %d esempi (%.1f%%)${RESET}\n" \
        "$zero_count" "$zero_total" "$pct"
    printf "  ${DIM}Queste query sono invisibili alla rete — il modello non può impararle.${RESET}\n"
    if [[ "$COMPACT" -eq 0 ]]; then
        for ex in "${zero_examples[@]}"; do
            printf "    ${YELLOW}%-70s${RESET}\n" "$ex"
        done
    else
        # In compact mostra solo il primo esempio come indicazione
        [[ "${#zero_examples[@]}" -gt 0 ]] && \
            printf "    ${DIM}es: %s${RESET}\n" "${zero_examples[0]}"
    fi
fi

# ─── Sezione 2: gap vocabolario ───────────────────────────────────────────────
if [[ ! -f "$LABELED" || ! -f "$UNIGRAMS_FILE" ]]; then
    printf "\n  ${DIM}(vocab-gap non disponibile — unigrams.txt mancante)${RESET}\n\n"
    exit 0
fi

printf "\n"

gap_output=$("$SCRIPT_DIR/vocab-gap.sh" \
    --profile "$PROFILE_DIR" \
    --min-count "$MIN_COUNT" \
    --top "$TOP_N" 2>/dev/null || true)

# Conta le classi con gap (righe [GAP])
gap_classes=$(echo "$gap_output" | grep -c "\[GAP\]" || true)

if [[ "$gap_classes" -eq 0 ]]; then
    printf "  ${GREEN}✓${RESET} Vocabolario: nessun gap rilevante  ${DIM}(soglia: >= %d esempi)${RESET}\n\n" "$MIN_COUNT"
else
    printf "  ${YELLOW}${BOLD}! Token non coperti: %d classi con gap${RESET}  ${DIM}(soglia: >= %d esempi)${RESET}\n" \
        "$gap_classes" "$MIN_COUNT"
    if [[ "$COMPACT" -eq 0 ]]; then
        # Stampa il report vocab-gap completo (senza la sua intestazione ridondante)
        echo "$gap_output" | grep -v "^$\|^Vocab gap report\|^Token unici\|^Suggerimento" || true
        printf "  ${DIM}→ Aggiungi i token mancanti in unigrams.txt, poi riesegui build-dataset.sh e train.sh${RESET}\n"
    else
        printf "  ${DIM}→ Esegui: ./gap-report.sh --profile profiles/$(basename "$PROFILE_DIR")  per il dettaglio${RESET}\n"
    fi
    printf "\n"
fi
