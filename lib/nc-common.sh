#!/bin/bash
#
# nc-common.sh — funzioni condivise dal backend neural-c fra setup.sh e train.sh
# (principio 2, logica centralizzata: entrambi gli script conoscono la stessa
# topologia e gli stessi iperparametri di default, e non devono duplicarli).
#
# Richiede: BASH_SOURCE risolvibile (sourciato da uno script in $SCRIPT_DIR o
# lib/). Non richiede domain.conf — usa solo MODEL_TOPOLOGY come stringa.
#

NC_ANALYZER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NC_BIN="$NC_ANALYZER_DIR/../neural-c/neural-c.sh"

# ─── Default iperparametri, unica fonte di verità ──────────────────────────────
# setup.sh li usa per il primo `init`; train.sh li usa come default dei propri
# flag. Cambiarli qui basta a mantenerli sincronizzati fra le due invocazioni,
# così un ./setup.sh + ./train.sh senza flag produce un project.conf coerente
# fin dal primo giro (nessun reinit spurio per divergenza fra i due default).
NC_DEFAULT_EPOCHS=5000
NC_DEFAULT_LR=0.01
NC_DEFAULT_OPTIMIZER=adam
NC_DEFAULT_LOSS=mse
NC_DEFAULT_SEED=42
NC_DEFAULT_PATIENCE=100
NC_DEFAULT_MIN_DELTA=0.00005
# early_stopping_patience>0 esige validation.txt (neural-c non supporta più
# l'early stopping sulla sola training loss, a differenza del vecchio backend
# PyTorch) — la scelta è binaria, quindi il default abilita uno split holdout.
NC_DEFAULT_VAL_SPLIT=0.15

# nc_topology_init_args TOPOLOGY -> stampa "--inputs N --layer S:sigmoid ..."
# TOPOLOGY es. "111,48,16" (da nlp/tools.conf:MODEL_TOPOLOGY — le dimensioni
# sono già derivate lì da NUM_FEATURES/NUM_TOOLS, mai letterali qui).
nc_topology_init_args() {
    local topology="$1"
    local -a sizes
    IFS=',' read -ra sizes <<< "$topology"
    if [[ "${#sizes[@]}" -lt 2 ]]; then
        log_error "MODEL_TOPOLOGY malformata: '$topology'"
        return 1
    fi
    local args="--inputs ${sizes[0]}"
    local i
    for (( i = 1; i < ${#sizes[@]}; i++ )); do
        args="$args --layer ${sizes[$i]}:sigmoid"
    done
    echo "$args"
}

# nc_init_project MODEL_DIR TOPOLOGY EPOCHS LR OPTIMIZER LOSS SEED PATIENCE MIN_DELTA
# Wrapper unico su `neural-c init --force`: lo stesso identico comando che
# setup.sh usa per il primo init e che train.sh usa quando gli iperparametri
# richiesti divergono da project.conf (rende esplicito che "flag diversi ⇒
# modello nuovo").
nc_init_project() {
    local model_dir="$1" topology="$2" epochs="$3" lr="$4" optimizer="$5" \
          loss="$6" seed="$7" patience="$8" min_delta="$9"
    local layer_args
    layer_args=$(nc_topology_init_args "$topology") || return 1

    local -a es_args=()
    if [[ "$patience" -gt 0 ]]; then
        es_args=(--early-stopping-patience "$patience" --early-stopping-min-delta "$min_delta")
    fi

    "$NC_BIN" init "$model_dir" $layer_args \
        --loss "$loss" \
        --optimizer "$optimizer" \
        --learning-rate "$lr" \
        --seed "$seed" \
        --epochs "$epochs" \
        "${es_args[@]}" \
        --force
}

# nc_project_conf_get MODEL_DIR KEY -> valore, o stringa vuota se assente
nc_project_conf_get() {
    local model_dir="$1" key="$2"
    local conf="$model_dir/project.conf"
    [[ -f "$conf" ]] || return 1
    awk -v k="$key" '$1==k{print $2; exit}' "$conf"
}

# nc_num_diff A B -> vero (exit 0) se A e B, confrontati come numeri, differiscono.
# Necessario perché project.conf scrive alcuni valori con l'espansione decimale
# completa del double (es. "0.90000000000000002" per un default "0.9"): un
# confronto testuale segnalerebbe una divergenza inesistente.
nc_num_diff() {
    awk -v a="$1" -v b="$2" 'BEGIN{exit (a+0!=b+0)?0:1}'
}

# nc_str_diff A B -> vero (exit 0) se le due stringhe differiscono.
nc_str_diff() {
    [[ "$1" != "$2" ]]
}

# nc_predict MODEL_DIR NUM_TOOLS FEATURE... -> stampa su stdout le NUM_TOOLS
# probabilità (spazio-separate), o fallisce con log_error già chiamato.
# FEATURE... va passato non quotato dal chiamante (word-splitting voluto: sono
# posizionali flat, non un unico argomento — è la stessa forma che `predict`
# richiede per gli input diretti da riga di comando).
# Sostituisce l'apparato dummy-output/file-temporaneo/sed del vecchio backend
# nnet-run.sh: `predict` di neural-c accetta gli input direttamente sulla riga
# di comando, senza bisogno di un dataset con colonna output fittizia.
nc_predict() {
    local model_dir="$1" num_tools="$2"
    shift 2
    local raw status
    raw=$("$NC_BIN" predict "$model_dir" "$@" 2>&1)
    status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "neural-c predict fallito (exit $status): $raw"
        return 1
    fi

    local probs count
    probs=$(awk '/^sample 0 /{ sub(/^sample 0 /, ""); print; exit }' <<< "$raw")
    count=$(wc -w <<< "$probs")
    if [[ "$count" -ne "$num_tools" ]]; then
        log_error "neural-c predict: $count probabilità ricevute, ne erano attese $num_tools. Output: $raw"
        return 1
    fi

    echo "$probs"
}
