#!/bin/bash
#
# Converte una query testuale in un vettore di feature numerico.
# Uscita: una riga di NUM_FEATURES valori separati da spazio.
#
# Uso: ./lib/query-to-features.sh "mostrami gli errori 500"
# Richiede: PROFILE_DIR esportata dal chiamante.
#
# Il vocabolario (UNIGRAMS, BIGRAMS, NUM_FEATURES) è letto da
# PROFILE_DIR/domain.conf — ogni profilo ha il suo.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] query-to-features: PROFILE_DIR non impostata" >&2
    exit 1
fi

source "$PROFILE_DIR/domain.conf"

# Usa NORM_QUERY se disponibile (prodotta da normalize-query.sh nel pipeline normale).
# Fallback su $1 per invocazioni dirette (test manuali, infer-dry.sh, ecc.).
query="${NORM_QUERY:-${1,,}}"
query="${query,,}"  # lowercase uniforme anche in caso di fallback

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
# Formato: "patA :: patB"          — peso implicito 1
#          "patA :: patB :: N"     — peso esplicito N
for bigram in "${BIGRAMS[@]}"; do
    patA="${bigram%%::*}"
    patA="${patA// /}"
    last="${bigram##*::}"
    last="${last// /}"
    if [[ "$last" =~ ^[0-9]+$ ]]; then
        weight="$last"
        rest="${bigram#*::}"
        patB="${rest%%::*}"
        patB="${patB// /}"
    else
        weight="1"
        patB="$last"
    fi
    if echo "$query" | grep -qE "$patA" 2>/dev/null && \
       echo "$query" | grep -qE "$patB" 2>/dev/null; then
        features+=("$weight")
    else
        features+=("0")
    fi
done

echo "${features[*]}"
