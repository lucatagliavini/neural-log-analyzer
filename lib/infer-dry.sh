#!/bin/bash
#
# Esegue l'inferenza e stampa il ranking completo di tutti i tool con probabilità,
# evidenziando il vincitore (verde) e il secondo classificato (giallo).
# Usato da chatbot.sh --dry-run.
#
# Uscita: una riga per tool, ordinata per probabilità decrescente.
#
# Richiede: PROFILE_DIR, TOOL_THRESHOLD, TOOL_NAMES, NUM_TOOLS esportati.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] infer-dry: PROFILE_DIR non impostata" >&2
    exit 1
fi

source "$PROFILE_DIR/domain.conf"

ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NNET_RUN="$ANALYZER_DIR/../nnet-run.sh"
MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
LIB_DIR="$ANALYZER_DIR/lib"

query="$1"
[[ -z "$query" ]] && { echo "[ERROR] query mancante" >&2; exit 1; }
[[ ! -d "$MODEL_DIR" ]] && { echo "[ERROR] Modello non trovato: $MODEL_DIR" >&2; exit 1; }

features=$("$LIB_DIR/query-to-features.sh" "$query")
nonzero=$(echo "$features" | tr ' ' '\n' | awk '$1+0>0{c++} END{print c+0}')

dummy_out=$(printf '0 %.0s' $(seq 1 "$NUM_TOOLS") | sed 's/ $//')
tmp_ds=$(mktemp)
echo "# dry-run" > "$tmp_ds"
echo "$features $dummy_out" >> "$tmp_ds"

raw_output=$("$NNET_RUN" predict "$tmp_ds" "$MODEL_DIR" 2>/dev/null)
rm -f "$tmp_ds"

probs=$(echo "$raw_output" | awk '/^\s*1\s*\|/{
    sub(/^\s*[0-9]+\s*\|\s*/, "")
    sub(/\s*\|.*/, "")
    print; exit
}')

# Associa nome tool → probabilità
declare -a pairs=()
i=0
for prob in $probs; do
    pairs+=("$prob ${TOOL_NAMES[$i]}")
    i=$(( i + 1 ))
done

# Ordina per prob decrescente
sorted=$(printf '%s\n' "${pairs[@]}" | sort -rn -k1)

# Colori
G="\033[32m"; Y="\033[33m"; D="\033[2m"; B="\033[1m"; R="\033[0m"; C="\033[36m"

rank=0
threshold_line_printed=0

echo ""
printf "  ${B}Feature attive:${R} %d / %d\n" "$nonzero" "$NUM_FEATURES"
printf "  ${B}Soglia confidenza:${R} %.0f%%\n\n" "$(awk -v t="$TOOL_THRESHOLD" 'BEGIN{printf "%.0f", t*100}')"
printf "  %-3s  %-6s  %-22s  %s\n" "RNK" "CONF" "TOOL" "DESCRIZIONE"
printf "  %-3s  %-6s  %-22s  %s\n" "───" "──────" "──────────────────────" "────────────────────────────────────"

while IFS=' ' read -r prob tool; do
    rank=$(( rank + 1 ))
    pct=$(awk -v p="$prob" 'BEGIN { printf "%.1f", p * 100 }')
    above=$(awk -v p="$prob" -v t="$TOOL_THRESHOLD" 'BEGIN { exit (p >= t) ? 0 : 1 }' && echo 1 || echo 0)

    # Stampa separatore soglia
    if [[ "$above" -eq 0 && "$threshold_line_printed" -eq 0 ]]; then
        printf "  ${D}  ·  ──────  ── soglia %.0f%% ──────────────────────────────────────────${R}\n" \
            "$(awk -v t="$TOOL_THRESHOLD" 'BEGIN{printf "%.0f", t*100}')"
        threshold_line_printed=1
    fi

    desc="${TOOL_DESC[$tool]:-}"
    if [[ "$rank" -eq 1 && "$above" -eq 1 ]]; then
        printf "  ${G}${B}%2d.  %5.1f%%  %-22s${R}  ${D}%s${R}\n" "$rank" "$pct" "$tool" "$desc"
    elif [[ "$rank" -eq 2 && "$above" -eq 1 ]]; then
        printf "  ${Y}%2d.  %5.1f%%  %-22s${R}  ${D}%s${R}\n" "$rank" "$pct" "$tool" "$desc"
    elif [[ "$above" -eq 1 ]]; then
        printf "  ${C}%2d.  %5.1f%%  %-22s${R}  ${D}%s${R}\n" "$rank" "$pct" "$tool" "$desc"
    else
        printf "  ${D}%2d.  %5.1f%%  %-22s  %s${R}\n" "$rank" "$pct" "$tool" "$desc"
    fi
done <<< "$sorted"
echo ""
