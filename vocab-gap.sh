#!/bin/bash
#
# vocab-gap.sh — individua token frequenti nel dataset non coperti dal vocabolario.
# Non modifica nulla. Produce un report per guidare l'espansione di vocab.sh.
#
# Uso: ./vocab-gap.sh --profile profiles/liquido [--min-count N] [--top N]
#
# --min-count N  soglia minima di esempi per segnalare un token (default: 3)
# --top N        massimo token da mostrare per classe (default: 8)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_DIR=""
MIN_COUNT=3
TOP_N=8

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)   PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --min-count) MIN_COUNT="$2"; shift 2 ;;
        --top)       TOP_N="$2"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./vocab-gap.sh --profile profiles/liquido" >&2
    exit 1
fi

LABELED="$PROFILE_DIR/dataset/queries_labeled.txt"
if [[ ! -f "$LABELED" ]]; then
    echo "[ERROR] Dataset non trovato: $LABELED" >&2; exit 1
fi
if [[ ! -f "$PROFILE_DIR/unigrams.txt" || ! -f "$PROFILE_DIR/bigrams.txt" ]]; then
    echo "[ERROR] unigrams.txt o bigrams.txt non trovati in $PROFILE_DIR" >&2; exit 1
fi

# ─── Costruisce regex combinata da tutti i pattern del vocab ──────────────────
# Legge direttamente dai file .txt — più semplice di sourceare vocab.sh
COMBINED_RE=$(
    grep -hv '^[[:space:]]*#\|^[[:space:]]*$' \
        "$PROFILE_DIR/unigrams.txt" \
        "$PROFILE_DIR/bigrams.txt" \
    | awk -F'::' '{
        # unigram: colonna 1 = pattern
        # bigram:  colonna 1 = patA, colonna 2 = patB (colonna 3 = peso opzionale)
        gsub(/[[:space:]]/, "", $1); printf "%s|", $1
        if (NF >= 2) {
            pat2 = $2
            # se colonna 2 è solo un numero è il peso del bigram — salta
            gsub(/[[:space:]]/, "", pat2)
            if (pat2 !~ /^[0-9]+$/) printf "%s|", pat2
        }
    }' | sed 's/|$//'
)

COMBINED_RE="${COMBINED_RE:-NOMATCH}"

# ─── Phase 1: tokenizza il dataset → class TAB token TAB count ───────────────
TOKEN_TABLE=$(mktemp)
COVERED_FILE=$(mktemp)
_cleanup() { rm -f "$TOKEN_TABLE" "$COVERED_FILE"; }
trap _cleanup EXIT

awk -F'\t' '
/^#/ || NF < 2 { next }
{
    # Usa solo il label primario (prima etichetta prima della virgola)
    split($1, labels, /,/)
    class = labels[1]
    query = tolower($2)
    n = split(query, words, /[^a-zA-ZàèéìòùÀÈÉÌÒÙ]+/)
    for (i = 1; i <= n; i++) {
        w = words[i]
        if (length(w) >= 4)
            print class "\t" w
    }
}
' "$LABELED" | sort | uniq -c \
    | awk '{ print $2 "\t" $3 "\t" $1 }' \
    > "$TOKEN_TABLE"

# ─── Phase 2: individua i token NON coperti dal vocab ────────────────────────
while IFS= read -r tok; do
    if ! echo "$tok" | grep -qE "$COMBINED_RE" 2>/dev/null; then
        echo "$tok"
    fi
done < <(awk -F'\t' '{print $2}' "$TOKEN_TABLE" | sort -u) > "$COVERED_FILE"

UNCOVERED=$(wc -l < "$COVERED_FILE")
TOTAL=$(awk -F'\t' '{print $2}' "$TOKEN_TABLE" | sort -u | wc -l)

# ─── Phase 3: report per classe ──────────────────────────────────────────────
BOLD="\033[1m"; CYAN="\033[36m"; YELLOW="\033[33m"; DIM="\033[2m"; RESET="\033[0m"

printf "\n${BOLD}Vocab gap report${RESET} — profilo: $(basename "$PROFILE_DIR")\n"
printf "${DIM}Token unici nel dataset: %d | non coperti dal vocab: %d | soglia: >= %d esempi${RESET}\n\n" \
    "$TOTAL" "$UNCOVERED" "$MIN_COUNT"

# Join: filtra TOKEN_TABLE ai soli token non coperti, ordina e raggruppa per classe
awk -F'\t' -v min_count="$MIN_COUNT" '
    NR == FNR { uncovered[$1] = 1; next }
    { class=$1; tok=$2; cnt=$3+0
      if (cnt >= min_count && tok in uncovered)
          printf "%s\t%s\t%d\n", class, tok, cnt }
' "$COVERED_FILE" "$TOKEN_TABLE" \
| sort -t$'\t' -k1,1 -k3,3rn \
| awk -F'\t' -v top_n="$TOP_N" -v bold="$BOLD" -v cyan="$CYAN" \
             -v yellow="$YELLOW" -v dim="$DIM" -v reset="$RESET" '
{
    class=$1; tok=$2; cnt=$3+0
    if (class != prev) {
        if (prev != "") printf "\n"
        printf "%s[GAP]%s %s%s%s — token frequenti non coperti:\n", bold, reset, cyan, class, reset
        prev=class; n=0
    }
    if (n < top_n) {
        printf "      %s%-22s%s %s%d esempi%s\n", yellow, tok, reset, dim, cnt, reset
        n++
    }
}
END { if (prev != "") printf "\n" }
'

printf "${DIM}Suggerimento: valuta se aggiungere questi token come unigram o estendere un pattern esistente in vocab.sh.${RESET}\n\n"
