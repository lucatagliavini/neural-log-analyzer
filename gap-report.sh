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
#   --top N        max candidati da mostrare IN TOTALE (default: 25) — 0 = tutti.
#                  Dal 2026-08-21 (GAPREP-1) il report è una lista unica ordinata
#                  per forza del candidato, non più "N token per ognuna delle 16
#                  classi": il vecchio default 6 significava ~96 righe, come
#                  totale mostrerebbe 6 candidati su 74 e nasconderebbe il grosso.
#   --compact      stampa solo il riepilogo, senza dettaglio token (usato da train.sh)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_DIR=""
MIN_COUNT=2
TOP_N=25
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

# Il dataset numerico serve SOLO alla sezione 1 (vettori zero): la sezione 2 (gap
# vocabolario) si calcola da queries_labeled.txt e dal vocabolario, che non lo
# richiedono. Fino al 2026-08-21 qui c'era `exit 0`, quindi un profilo senza
# queries.txt generato non riceveva NIENTE — nemmeno la parte misurabile. Stesso
# tema di GAPREP-1: una diagnostica che tace potendo parlare.
HAVE_DATASET_NUM=1
if [[ ! -f "$DATASET_NUM" ]]; then
    HAVE_DATASET_NUM=0
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

if [[ "$HAVE_DATASET_NUM" -eq 1 ]]; then
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
fi

# ─── Intestazione ─────────────────────────────────────────────────────────────
printf "\n${BOLD}── Gap report vocabolario${RESET}  ${DIM}profilo: $(basename "$PROFILE_DIR")${RESET}\n\n"

# ─── Riepilogo zero-vector ────────────────────────────────────────────────────
if [[ "$HAVE_DATASET_NUM" -eq 0 ]]; then
    printf "  ${DIM}Vettori zero: non calcolati — dataset numerico assente (%s).${RESET}\n" \
        "$(basename "$DATASET_NUM")"
    printf "  ${DIM}Eseguire ./build-dataset.sh. Il gap vocabolario qui sotto non lo richiede.${RESET}\n"
elif [[ "$zero_count" -eq 0 ]]; then
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

# Il codice di uscita di vocab-gap.sh va CATTURATO, non gettato.
#
# Fino al 2026-08-21 qui c'era `... 2>/dev/null || true` DENTRO la command
# substitution: inghiottiva qualunque fallimento, `grep -c "[GAP]"` restituiva 0,
# e questo script stampava «✓ Vocabolario: nessun gap rilevante» — un check verde
# per una misura mai avvenuta. Bastava un unigrams.txt cancellato. È la classe di
# difetto che il progetto combatte da LOGSEL-1 D2: una risposta ben formata alla
# domanda sbagliata. Ora i tre esiti sono distinti (GAPREP-1).
#
#   0  misurato
#   2  NON misurabile (python3 assente, artefatti irrisolvibili)
#   *  errore inatteso
#
# Nessun ramo esce con codice non-zero: train.sh:166 invoca questo script sotto
# `set -euo pipefail` e senza `|| true`, quindi un exit non-zero abortirebbe
# l'addestramento — un report diagnostico non deve avere quel potere.
gap_status=0
gap_rows=$("$SCRIPT_DIR/vocab-gap.sh" \
    --profile "$PROFILE_DIR" \
    --min-count "$MIN_COUNT" \
    --top "$TOP_N" --porcelain 2>/dev/null) || gap_status=$?

if [[ "$gap_status" -eq 2 ]]; then
    printf "  ${YELLOW}${BOLD}? Vocabolario: gap NON misurato${RESET}  ${DIM}(python3 non disponibile — vedi CLAUDE.md, Dependencies)${RESET}\n\n"
elif [[ "$gap_status" -ne 0 ]]; then
    printf "  ${RED}${BOLD}✗ Vocabolario: errore nella misura${RESET}  ${DIM}(vocab-gap.sh exit %d)${RESET}\n\n" "$gap_status"
elif [[ -z "$gap_rows" ]]; then
    printf "  ${GREEN}✓${RESET} Vocabolario: nessun candidato  ${DIM}(soglia: >= %d esempi)${RESET}\n\n" "$MIN_COUNT"
else
    _n_gap=$(printf '%s\n' "$gap_rows" | grep -c . || true)
    if [[ "$COMPACT" -eq 0 ]]; then
        printf "  ${YELLOW}${BOLD}! Vocabolario: %d candidati non coperti${RESET}\n" "$_n_gap"
        "$SCRIPT_DIR/vocab-gap.sh" --profile "$PROFILE_DIR" \
            --min-count "$MIN_COUNT" --top "$TOP_N" 2>/dev/null || true
        printf "  ${DIM}→ Aggiungi i token utili in unigrams.txt, poi ./build-dataset.sh e ./train.sh${RESET}\n\n"
    else
        # I TRE candidati più forti PER NOME, non solo il conteggio.
        #
        # È la modifica più importante di GAPREP-1, e la ragione è misurata: la
        # riga compact esisteva già, era accurata, e veniva stampata a ogni
        # addestramento — eppure `fallimenti — 3 esempi` è passato inosservato per
        # settimane (FLEX-1b). Un NUMERO non dà a nessuno una ragione per
        # guardare; tre parole concrete sì.
        # tr+sed e non `paste -sd', '`: paste tratta l'argomento -d come una LISTA
        # di delimitatori da alternare, quindi produrrebbe "a, b c".
        _top3=$(printf '%s\n' "$gap_rows" | head -3 | cut -f1 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        printf "  ${YELLOW}${BOLD}! Vocabolario: %d candidati non coperti${RESET}  ${DIM}(top: %s)${RESET}\n" \
            "$_n_gap" "$_top3"
        printf "  ${DIM}→ Esegui: ./gap-report.sh --profile profiles/$(basename "$PROFILE_DIR")  per il dettaglio${RESET}\n\n"
    fi
fi
