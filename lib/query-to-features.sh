#!/bin/bash
#
# Converte una query testuale in un vettore di feature numerico.
# Uscita: una riga di NUM_FEATURES valori separati da spazio.
#
# Uso: ./lib/query-to-features.sh "mostrami gli errori 500"
# Richiede: PROFILE_DIR esportata dal chiamante.
#
# Il vocabolario (UNIGRAMS, BIGRAMS, NUM_FEATURES) è letto da
# PROFILE_DIR/vocab.sh — ogni profilo ha il suo.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] query-to-features: PROFILE_DIR non impostata" >&2
    exit 1
fi

source "$PROFILE_DIR/vocab.sh"

query="${1,,}"  # lowercase

# ─── UNIGRAM ─────────────────────────────────────────────────────────────────
features=()
for entry in "${UNIGRAMS[@]}"; do
    pattern="${entry%%::*}"
    weight="${entry##*::}"
    pattern="${pattern// /}"
    weight="${weight// /}"
    if echo "$query" | grep -qE "$pattern" 2>/dev/null; then
        features+=("$weight")
    else
        features+=("0")
    fi
done

# ─── BIGRAM (co-presenza) ─────────────────────────────────────────────────────
for bigram in "${BIGRAMS[@]}"; do
    patA="${bigram%%::*}"
    patB="${bigram##*::}"
    patA="${patA// /}"
    patB="${patB// /}"
    if echo "$query" | grep -qE "$patA" 2>/dev/null && \
       echo "$query" | grep -qE "$patB" 2>/dev/null; then
        features+=("1")
    else
        features+=("0")
    fi
done

echo "${features[*]}"
