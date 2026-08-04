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

# Il matching usa il costrutto nativo `[[ =~ ]]` invece di `echo | grep -qE`: questo
# script gira una volta per query e con 108 pattern faceva ~242 fork (2 processi per
# unigram, fino a 4 per bigram), cioè 112 ms per query contro ~5 ms nativi.
#
# ATTENZIONE — il pattern va passato NON quotato: `[[ $q =~ $p ]]`, non
# `[[ $q =~ "$p" ]]`. Quotandolo, bash lo tratta come stringa LETTERALE e ~100 regex
# smettono silenziosamente di matchare. È l'opposto della regola abituale "quota
# sempre le variabili", quindi un linter o un refactoring "che sistema il quoting"
# romperebbe tutto senza errori. Verificato: `grep -E` e `[[ =~ ]]` danno lo stesso
# risultato su 116.610 confronti (115 pattern × 1014 query reali), incluse le \b che
# sono un'estensione GNU. Su glibc bash e grep condividono la stessa libreria regex;
# con musl (Alpine) o BSD la garanzia decade.
# La rete di sicurezza è tests/test-normalize-parity.sh, che confronta i 108 valori
# di feature fra questo script e vectorize() in Python su tutte le query.

# ─── UNIGRAM ─────────────────────────────────────────────────────────────────
features=()
for entry in "${UNIGRAMS[@]}"; do
    pattern="${entry%%::*}"
    weight="${entry##*::}"
    pattern="${pattern// /}"
    weight="${weight// /}"
    if [[ "$query" =~ $pattern ]]; then
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
    # Pattern non quotati: vedi la nota sopra
    if [[ "$query" =~ $patA ]] && [[ "$query" =~ $patB ]]; then
        features+=("$weight")
    else
        features+=("0")
    fi
done

echo "${features[*]}"
