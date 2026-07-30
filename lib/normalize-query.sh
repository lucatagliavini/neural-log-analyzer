#!/bin/bash
#
# normalize-query.sh — normalizzazione entità e rilevamento contesto.
#
# Sostituisce context-extract.sh: è l'unica fonte di verità per
# DETECTED_APP, DETECTED_ENV, DETECTED_NODE.
# Produce anche NORM_QUERY con placeholder canonici (<APP>, <ENV>, <NODE>)
# da passare a query-to-features.sh per la vectorizzazione.
#
# Uso:   eval "$(./lib/normalize-query.sh "errori jboss prod nodo 3")"
# Emette: NORM_QUERY  DETECTED_APP  DETECTED_ENV  DETECTED_NODE
#
# Richiede: PROFILE_DIR esportata dal chiamante.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "echo '[ERROR] normalize-query: PROFILE_DIR non impostata' >&2"
    exit 1
fi

source "$PROFILE_DIR/system.conf"
source "$PROFILE_DIR/entities.conf"

query="${1,,}"
norm_query="$query"

DETECTED_APP=""
DETECTED_ENV=""
DETECTED_NODE=""

# ─── 1. Normalizzazione APP (longest-match) ───────────────────────────────────
# Ordina gli alias per lunghezza decrescente: "contactmanager" prima di "cc"
_sorted_apps=$(for k in "${!ENTITY_APP[@]}"; do printf '%d %s\n' "${#k}" "$k"; done \
               | sort -rn | awk '{print $2}')

for _alias in $_sorted_apps; do
    if echo "$norm_query" | grep -qiE "(^|[^a-z])${_alias}([^a-z]|$)"; then
        DETECTED_APP="$_alias"
        norm_query=$(echo "$norm_query" | sed -E "s/(^|[^a-zA-Z])${_alias}([^a-zA-Z]|$)/\1<APP>\2/g")
        break  # first (longest) match wins
    fi
done

# ─── 2. Normalizzazione ENV ───────────────────────────────────────────────────
# 2a. Match diretto sulle chiavi di ENV_NODE_CODE (prod, coll, cert, ...)
for _env_name in "${!ENV_NODE_CODE[@]}"; do
    if echo "$norm_query" | grep -qE "(^|[^a-z])${_env_name}([^a-z]|$)"; then
        DETECTED_ENV="$_env_name"
        norm_query=$(echo "$norm_query" | sed -E "s/(^|[^a-zA-Z])${_env_name}([^a-zA-Z]|$)/\1<ENV>\2/g")
        break
    fi
done

# 2b. Sinonimi italiani (da ENV_SYNONYMS in entities.conf) se non ancora trovato
if [[ -z "$DETECTED_ENV" ]] && declare -p ENV_SYNONYMS &>/dev/null; then
    for _syn in "${!ENV_SYNONYMS[@]}"; do
        if echo "$norm_query" | grep -qiE "(^|[^a-z])${_syn}([^a-z]|$)"; then
            DETECTED_ENV="${ENV_SYNONYMS[$_syn]}"
            norm_query=$(echo "$norm_query" | sed -E "s/(^|[^a-zA-Z])${_syn}([^a-zA-Z]|$)/\1<ENV>\2/g")
            break
        fi
    done
fi

# 2c. Hostname completo → ENV dal codice a 2 lettere, NODE dal numero
# NODE_HOST_REGEX è definito in system.conf; fallback sul pattern generico se assente.
# Assegnazione esplicita per evitare ${VAR:-regex-con-graffe} che può confondere il parser.
if [[ -n "${NODE_HOST_REGEX:-}" ]]; then
    _host_regex="$NODE_HOST_REGEX"
else
    _host_regex='lx[a-z]{2}[a-z]+[a-z]{2}[0-9]+'
fi
if [[ -z "$DETECTED_ENV" || -z "$DETECTED_NODE" ]]; then
    _hostname=$(echo "$norm_query" | grep -oE "$_host_regex" | head -1)
    if [[ -n "$_hostname" ]]; then
        _node_code="${_hostname:2:2}"      # terzo e quarto carattere = codice ambiente
        _node_num=$(echo "$_hostname" | grep -oE "[0-9]+$" | sed 's/^0*//')
        [[ -z "$_node_num" ]] && _node_num="0"
        if [[ -z "$DETECTED_ENV" ]]; then
            # Inverti ENV_NODE_CODE: valore (codice) → chiave (nome env)
            for _env_name in "${!ENV_NODE_CODE[@]}"; do
                if [[ "${ENV_NODE_CODE[$_env_name]}" == "$_node_code" ]]; then
                    DETECTED_ENV="$_env_name"
                    break
                fi
            done
        fi
        if [[ -z "$DETECTED_NODE" && -n "$_node_num" ]]; then
            DETECTED_NODE="$_node_num"
        fi
        norm_query=$(echo "$norm_query" | sed -E "s/${_hostname}/<ENV> <NODE>/g")
    fi
fi

# ─── 3. Normalizzazione NODE ──────────────────────────────────────────────────
# Prova i pattern in NODE_PATTERNS (dal più specifico al più generico)
if [[ -z "$DETECTED_NODE" ]]; then
    for _pat in "${NODE_PATTERNS[@]}"; do
        if echo "$norm_query" | grep -qiE "$_pat"; then
            DETECTED_NODE=$(echo "$norm_query" | grep -oiE "$_pat" | grep -oE "[0-9]+" | head -1)
            norm_query=$(echo "$norm_query" | sed -E "s/${_pat}/<NODE>/g")
            break
        fi
    done
fi

# ─── 4. Normalizzazione APP: abbreviazioni e alias residui ───────────────────
# Dopo i placeholder ENV/NODE, gestisci abbreviazioni contestuali
# cc → ClaimCenter (se non ancora rilevato e ClaimCenter è disponibile)
if [[ -z "$DETECTED_APP" ]]; then
    if echo "$norm_query" | grep -qE "\bcc\b"; then
        for _app in "${AVAILABLE_APPS[@]}"; do
            if [[ "$_app" == "ClaimCenter" ]]; then
                DETECTED_APP="claimcenter"
                norm_query=$(echo "$norm_query" | sed -E "s/\bcc\b/<APP>/g")
                break
            fi
        done
    elif echo "$norm_query" | grep -qE "\bcm\b|contact.?manager"; then
        for _app in "${AVAILABLE_APPS[@]}"; do
            if [[ "$_app" == "ContactManager" ]]; then
                DETECTED_APP="contactmanager"
                norm_query=$(echo "$norm_query" | sed -E "s/\bcm\b|contact.?manager/<APP>/g")
                break
            fi
        done
    fi
fi

# ─── Output ───────────────────────────────────────────────────────────────────
printf "NORM_QUERY=%q\n"     "$norm_query"
printf "DETECTED_APP=%q\n"   "$DETECTED_APP"
printf "DETECTED_ENV=%q\n"   "$DETECTED_ENV"
printf "DETECTED_NODE=%q\n"  "$DETECTED_NODE"
