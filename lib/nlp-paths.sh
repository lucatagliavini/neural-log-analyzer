#!/bin/bash
#
# nlp-paths.sh — punto UNICO di risoluzione dei path degli artefatti NLP.
#
# Il vocabolario, il dataset e il modello NON dipendono dall'applicazione: sono
# 196 righe di linguaggio naturale italiano con i placeholder <APP>/<LOGFILE>/
# <ENV>/<NODE>, e un modello che ne è la conseguenza deterministica. Quindi
# vivono nel FRAMEWORK (nlp/), non nel profilo (NLP-1, 2026-08-17).
#
# Il criterio che separa le due cose: **il profilo contiene COORDINATE** — dove
# sono i log, come si chiamano le cose, quale tecnologia — **non CAPACITÀ**.
# La prova che la collocazione precedente era sbagliata: montare il secondo
# profilo (usnext) aveva richiesto tre symlink verso liquido.
#
# Uso: source questo file, poi chiamare nlp_resolve_paths(). Richiede PROFILE_DIR.
# Va chiamata PRIMA di sourciare domain.conf, che ha bisogno di TOOLS_CONF_FILE.
#
# Variabili esportate:
#   NLP_DIR          la directory del framework
#   UNIGRAMS_FILE    vocabolario unigram (profilo se presente, altrimenti framework)
#   BIGRAMS_FILE     vocabolario bigram
#   TOOLS_CONF_FILE  NUM_TOOLS / TOOL_THRESHOLD / MODEL_TOPOLOGY / TOOL_NAMES
#   DATASET_DIR      directory del dataset
#   LABELED_FILE     dataset/queries_labeled.txt (input di build-dataset)
#   DATASET_FILE     dataset/queries.txt (generato, input di train)
#   MODEL_DIR        pesi della rete — DERIVATO, vedi sotto
#   NLP_CUSTOM       1 se il profilo sovrascrive almeno un artefatto
#

# nlp_resolve_paths
# Risolve ogni artefatto con precedenza PROFILO → FRAMEWORK, per SINGOLO file e non
# tutto-o-niente: un profilo può avere un proprio unigrams.txt e usare il dataset
# condiviso. Stesso schema di system.local.conf, che è per-file.
nlp_resolve_paths() {
    : "${PROFILE_DIR:?nlp_resolve_paths: PROFILE_DIR non impostata}"

    # Auto-locazione di QUESTO file, non del profilo: è la ragione per cui la
    # risoluzione vive qui e non in domain.conf. tests/test-profile-config.sh crea
    # profili in `mktemp -d`, FUORI dall'albero del repo — un domain.conf copiato
    # là non può sapere dove sta nlp/. Questo file invece è sempre sourciato con un
    # path che parte da SCRIPT_DIR/ANALYZER_DIR reali, quindi si localizza sempre.
    local _self_lib
    _self_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    NLP_DIR="$(cd "$_self_lib/.." && pwd)/nlp"
    if [[ ! -d "$NLP_DIR" ]]; then
        echo "[ERROR] nlp_resolve_paths: directory del framework non trovata: $NLP_DIR" >&2
        return 1
    fi

    # ARCH-6, nessun default implicito: se un artefatto non esiste in nessuno dei
    # due posti, errore esplicito con ENTRAMBI i path controllati — non un fallback
    # silenzioso su una stringa vuota, che a valle diventerebbe un path tipo
    # "/unigrams.txt" o un dataset vuoto.
    _nlp_resolve_file() {
        local rel="$1"
        if   [[ -f "$PROFILE_DIR/$rel" ]]; then echo "$PROFILE_DIR/$rel"
        elif [[ -f "$NLP_DIR/$rel"     ]]; then echo "$NLP_DIR/$rel"
        else
            echo "[ERROR] nlp_resolve_paths: '$rel' non trovato" >&2
            echo "        cercato in: $PROFILE_DIR/$rel" >&2
            echo "                    $NLP_DIR/$rel" >&2
            return 1
        fi
    }

    UNIGRAMS_FILE=$(_nlp_resolve_file unigrams.txt) || return 1
    BIGRAMS_FILE=$(_nlp_resolve_file bigrams.txt)   || return 1
    TOOLS_CONF_FILE=$(_nlp_resolve_file tools.conf) || return 1

    # Il dataset è una DIRECTORY: si risolve per directory, non per file, così un
    # profilo che la sovrascrive fornisce entrambi i file (labeled e generato) e non
    # una combinazione incoerente dei due.
    if [[ -d "$PROFILE_DIR/dataset" ]]; then
        DATASET_DIR="$PROFILE_DIR/dataset"
    else
        DATASET_DIR="$NLP_DIR/dataset"
    fi
    LABELED_FILE="$DATASET_DIR/queries_labeled.txt"
    DATASET_FILE="$DATASET_DIR/queries.txt"

    # MODEL_DIR è DERIVATO, non una configurazione a sé. Un profilo che sovrascrive
    # vocabolario, topologia o dataset ha per definizione bisogno di pesi propri: il
    # modello condiviso è addestrato su input diversi dai suoi, quindi non è valido.
    # Renderlo un flag separato permetterebbe di configurare quell'incoerenza.
    #
    # Derivarlo dagli INPUT risolve anche l'uovo-e-gallina di setup.sh, che deve
    # decidere dove CREARE il modello prima che esista: i file di testo su cui si
    # basa la decisione sono già presenti se il profilo li vuole personalizzare.
    NLP_CUSTOM=0
    [[ "$UNIGRAMS_FILE"   == "$PROFILE_DIR"/* ]] && NLP_CUSTOM=1
    [[ "$BIGRAMS_FILE"    == "$PROFILE_DIR"/* ]] && NLP_CUSTOM=1
    [[ "$TOOLS_CONF_FILE" == "$PROFILE_DIR"/* ]] && NLP_CUSTOM=1
    [[ "$DATASET_DIR"     == "$PROFILE_DIR"/* ]] && NLP_CUSTOM=1

    if [[ "$NLP_CUSTOM" -eq 1 ]]; then
        MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
    else
        MODEL_DIR="$NLP_DIR/models/intent_classifier"
    fi

    # export su TUTTO: diversi consumatori invocano script come SUBPROCESSO e non
    # con `source` — query-to-features.sh da gen-examples.sh, infer.sh e
    # infer-dry.sh da chatbot.sh, build_dataset.py da build-dataset.sh. Un processo
    # figlio eredita solo le variabili esportate, quindi senza export la
    # risoluzione fatta dal padre sarebbe invisibile al figlio.
    export NLP_DIR UNIGRAMS_FILE BIGRAMS_FILE TOOLS_CONF_FILE \
           DATASET_DIR LABELED_FILE DATASET_FILE MODEL_DIR NLP_CUSTOM
}
