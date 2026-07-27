#!/bin/bash
#
# Estrae cambio di contesto (ambiente, nodo, app) da una query in linguaggio naturale.
# Emette variabili shell: CTX_ENV, CTX_NODE, CTX_APP  (vuote se non menzionati)
#
# Uso: eval "$(./lib/context-extract.sh "errori 500 in coll nodo 2")"
# Richiede: PROFILE_DIR esportata dal chiamante.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "echo '[ERROR] context-extract: PROFILE_DIR non impostata' >&2" >&2
    exit 1
fi

source "$PROFILE_DIR/system.conf"

query="${1,,}"

# ─── Ambiente ────────────────────────────────────────────────────────────────
# Sinonimi italiani per i nomi ambiente. Il profilo può aggiungerne via ENV_SYNONYMS
# prima di sourcere questo script. Formato: "regex::nome_env"
declare -a _ENV_SYNONYMS=(
    "produzion[ei]::prod"
    "integrazion[ei]|integr\b::inte"
    "collaudo::coll"
    "certificazion[ei]|certif\b::cert"
)
if declare -p ENV_SYNONYMS &>/dev/null; then
    _ENV_SYNONYMS+=("${ENV_SYNONYMS[@]}")
fi

CTX_ENV=""
# Prima: match diretto sul nome env (es: "prod", "test", "coll")
for env_name in "${!ENV_NODE_CODE[@]}"; do
    if echo "$query" | grep -qE "\b${env_name}\b"; then
        CTX_ENV="$env_name"
        break
    fi
done
# Poi: sinonimi italiani se non ancora trovato
if [[ -z "$CTX_ENV" ]]; then
    for syn_entry in "${_ENV_SYNONYMS[@]}"; do
        syn_pat="${syn_entry%%::*}"
        syn_env="${syn_entry##*::}"
        if echo "$query" | grep -qE "\b${syn_pat}"; then
            CTX_ENV="$syn_env"
            break
        fi
    done
fi

# ─── Nodo ────────────────────────────────────────────────────────────────────
CTX_NODE=""
if echo "$query" | grep -qE "\bnodo\b.*[0-9]+|sul nodo [0-9]+"; then
    CTX_NODE=$(echo "$query" | grep -oE "\bnodo\b[^0-9]*([0-9]+)" | grep -oE "[0-9]+" | head -1)
fi
if [[ -z "$CTX_NODE" ]]; then
    node_full=$(echo "$query" | grep -oE "lx[a-z]{2}jbliq[0-9]+" | head -1)
    if [[ -n "$node_full" ]]; then
        CTX_NODE=$(echo "$node_full" | grep -oE "[0-9]+$")
        if [[ -z "$CTX_ENV" ]]; then
            node_code="${node_full:2:2}"
            for env_name in "${!ENV_NODE_CODE[@]}"; do
                if [[ "${ENV_NODE_CODE[$env_name]}" == "$node_code" ]]; then
                    CTX_ENV="$env_name"
                    break
                fi
            done
        fi
    fi
fi

# ─── Applicazione ────────────────────────────────────────────────────────────
CTX_APP=""
for app in "${AVAILABLE_APPS[@]}"; do
    app_lower="${app,,}"
    if echo "$query" | grep -qiE "\b${app_lower}\b"; then
        CTX_APP="$app"
        break
    fi
done
# Abbreviazioni comuni (cc → ClaimCenter, cm → ContactManager)
if [[ -z "$CTX_APP" ]]; then
    if echo "$query" | grep -qE "\bcc\b"; then
        # Verifica che ClaimCenter esista nelle app del profilo
        for app in "${AVAILABLE_APPS[@]}"; do
            [[ "$app" == "ClaimCenter" ]] && { CTX_APP="ClaimCenter"; break; }
        done
    elif echo "$query" | grep -qE "\bcm\b|contact.?manager"; then
        for app in "${AVAILABLE_APPS[@]}"; do
            [[ "$app" == "ContactManager" ]] && { CTX_APP="ContactManager"; break; }
        done
    fi
fi

# ─── Output ──────────────────────────────────────────────────────────────────
echo "CTX_ENV='${CTX_ENV}'"
echo "CTX_NODE='${CTX_NODE}'"
echo "CTX_APP='${CTX_APP}'"
