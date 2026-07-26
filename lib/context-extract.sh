#!/bin/bash
#
# Estrae cambio di contesto (ambiente, nodo, app) da una query in linguaggio naturale.
# Emette variabili shell: CTX_ENV, CTX_NODE, CTX_APP  (vuote se non menzionati)
#
# Uso: eval "$(./lib/context-extract.sh "errori 500 in coll nodo 2")"
#

source "$(dirname "$0")/../config.sh"

query="${1,,}"

# ─── Ambiente ────────────────────────────────────────────────────────────────
CTX_ENV=""
for env_name in "${!ENV_NODE_CODE[@]}"; do
    if echo "$query" | grep -qE "\b${env_name}\b"; then
        CTX_ENV="$env_name"
        break
    fi
done

# ─── Nodo ────────────────────────────────────────────────────────────────────
# "nodo 2", "nodo 02", "nodo numero 3", "sul nodo 1", "node 2"
CTX_NODE=""
if echo "$query" | grep -qE "\bnodo\b.*[0-9]+|sul nodo [0-9]+"; then
    CTX_NODE=$(echo "$query" | grep -oE "\bnodo\b[^0-9]*([0-9]+)" | grep -oE "[0-9]+" | head -1)
fi
# Forma esplicita: lx??jbliq01, lx??jbliq02, ...
if [[ -z "$CTX_NODE" ]]; then
    node_full=$(echo "$query" | grep -oE "lx[a-z]{2}jbliq[0-9]+" | head -1)
    if [[ -n "$node_full" ]]; then
        CTX_NODE=$(echo "$node_full" | grep -oE "[0-9]+$")
        # Sovrascrive anche env se deducibile dal codice nodo
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
    # Cerca forma abbreviata o completa: "claimcenter", "claim center", "cc"
    if echo "$query" | grep -qiE "\b${app_lower}\b"; then
        CTX_APP="$app"
        break
    fi
done
# Abbreviazioni comuni
if [[ -z "$CTX_APP" ]]; then
    if echo "$query" | grep -qE "\bcc\b"; then
        CTX_APP="ClaimCenter"
    elif echo "$query" | grep -qE "\bcm\b|contact.?manager"; then
        CTX_APP="ContactManager"
    fi
fi

# ─── Output ──────────────────────────────────────────────────────────────────
echo "CTX_ENV='${CTX_ENV}'"
echo "CTX_NODE='${CTX_NODE}'"
echo "CTX_APP='${CTX_APP}'"
