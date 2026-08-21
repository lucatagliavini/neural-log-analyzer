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

# ANALYZER_DIR va calcolato PRIMA di sourciare domain.conf: da NLP-1 quel file ha
# bisogno di TOOLS_CONF_FILE, che è risolto da lib/nlp-paths.sh — a sua volta
# raggiungibile solo da ANALYZER_DIR. L'ordine precedente (domain.conf prima)
# funzionava per caso, perché domain.conf non aveva dipendenze esterne.
#
# nlp_resolve_paths() è chiamata in proprio e non si affida al chiamante: questo
# script è invocato sia come subprocesso da chatbot.sh (che l'ha già chiamata) sia
# direttamente dai test. È idempotente — pochi stat — quindi chiamarla comunque è
# la scelta robusta.
ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ANALYZER_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 1

source "$PROFILE_DIR/domain.conf"
source "$ANALYZER_DIR/lib/utils-log.sh"
source "$ANALYZER_DIR/lib/nc-common.sh"

LIB_DIR="$ANALYZER_DIR/lib"

query="$1"
[[ -z "$query" ]] && { echo "[ERROR] query mancante" >&2; exit 1; }
[[ ! -d "$MODEL_DIR" ]] && { echo "[ERROR] Modello non trovato: $MODEL_DIR" >&2; exit 1; }

features=$("$LIB_DIR/query-to-features.sh" "$query")
nonzero=$(echo "$features" | tr ' ' '\n' | awk '$1+0>0{c++} END{print c+0}')

probs=$(nc_predict "$MODEL_DIR" "$NUM_TOOLS" $features) || exit 1

# Associa nome tool → probabilità
declare -a pairs=()
i=0
for prob in $probs; do
    pairs+=("$prob ${TOOL_NAMES[$i]}")
    i=$(( i + 1 ))
done

# Ordina per prob decrescente.
#
# `sort -g` e non `-n`: nc_predict emette notazione scientifica per i valori
# piccoli (es. "9.5657479403040116e-05") e `-n` NON la interpreta — legge quel
# valore come 9.56 e lo mette in cima, davanti a un 0.99 legittimo. Il sintomo
# era un ranking con il vincitore vero al terzo posto e il separatore di soglia
# stampato SOPRA il rank 1, cioè esattamente il contrario di ciò che questo
# strumento serve a mostrare. Il routing di produzione non era affetto:
# infer.sh confronta con awk, che la notazione scientifica la capisce.
#
# `LC_ALL=C` perché sia -n sia -g usano il separatore decimale della locale:
# sotto una locale italiana (LC_NUMERIC=it_IT, separatore ",") "0.995" viene
# letto come 0 e tutti i tool pareggiano a zero. Qui non si riproduce solo
# perché it_IT non è installata — il server di produzione può averla.
sorted=$(printf '%s\n' "${pairs[@]}" | LC_ALL=C sort -grk1)

# Colori
G="${C_OK}"; Y="${C_WARN}"; D="${C_LBL}"; B="${C_BOLD}"; R="${C_RESET}"; C="${C_ACCENT}"

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
