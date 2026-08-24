#!/bin/bash
#
# utils-quoted.sh — isolamento della REGIONE QUOTATA di una query.
#
# Ragione d'essere (SRCH-5, 2026-08-24). La parte fra virgolette di una query è
# la stringa che l'utente vuole CERCARE: è l'unico pezzo della frase che non è
# linguaggio naturale, e nessun estrattore di entità o di parametri deve leggerci
# dentro. Prima di questo file lo facevano tutti, con conseguenze misurate in
# produzione:
#
#   cerca "chiamata al nodo 7" nel nodo 4   → il bot cercava sul nodo 07
#   cerca "utente su ContactManager"        → DETECTED_APP=contactmanager
#   cerca "api-gateway timeout"             → NAMED_LOG='api', avviso spurio
#
# cioè la stringa CERCATA decideva DOVE si cercava.
#
# Vive in un file proprio e non in utils-logfiles.sh — dove abita
# _is_system_log_base(), l'altra funzione condivisa dalle due pipeline di
# estrazione — perché non ha niente a che vedere con i file di log: metterla là
# sarebbe centralizzare per comodità di `source`, non per pertinenza (principio 2).
#
# Consumatori: lib/normalize-query.sh (entità) e lib/param-extract.sh (parametri).
# Sono due pipeline INDIPENDENTI — chatbot.sh passa loro la query grezza
# separatamente — quindi la correzione è in due punti, ma la regola è una sola e
# sta qui.
#
# Replica Python: lib/build_dataset.py rispecchia normalize-query.sh e deve
# restare bit-identica (tests/run-tests.sh --parity).

# Sentinella: un singolo byte SOH (0x01).
#
# Perché un byte di controllo e non un testo tipo "__SPAN__":
#   - non può comparire in una query digitata da un utente, quindi non collide;
#   - non contiene CIFRE, e questo è il vincolo decisivo: gli estrattori di
#     param-extract.sh cercano numeri (STATUS_CODE, THRESHOLD_MS, TAIL_N), quindi
#     una sentinella con un indice numerico (`\x01 1 \x01`) fabbricherebbe un
#     falso parametro — il difetto che si sta correggendo, reintrodotto dal
#     rimedio;
#   - non contiene LETTERE, quindi non può essere letto come nome di app, di
#     ambiente o di log;
#   - non è alfanumerico, quindi funziona da confine di parola per le regex che
#     usano `[^a-z]` come delimitatore (sezioni 1-3 di normalize-query.sh).
#
# Tutte le sentinelle sono IDENTICHE (nessun indice): il ripristino avviene in
# ORDINE, sostituendo la prima occorrenza con il primo span, e così via.
readonly _Q_SENTINEL=$'\001'

# quoted_spans_of TEXT
# Emette una riga per ogni span quotato trovato, virgolette INCLUSE, in ordine
# POSIZIONALE (da sinistra a destra).
#
# L'ordine posizionale è un requisito, non un'eleganza: unmask_quoted ripristina
# la prima sentinella con il primo span, e le sentinelle stanno nella stringa
# nell'ordine in cui gli span comparivano. Una prima versione di questa funzione
# emetteva prima TUTTE le doppie e poi le singole, e su una query con span di
# entrambi i tipi — `trova 'x' e "y" ora` — il ripristino li avrebbe SCAMBIATI.
# Da qui la scansione unica con alternanza: `grep -o` restituisce i match non
# sovrapposti da sinistra a destra, quindi l'ordine è posizionale per costruzione.
quoted_spans_of() {
    local text="$1"
    grep -oE "\"[^\"]*\"|(^|[[:space:]])'[^']*'([[:space:]]|\$)" <<< "$text" 2>/dev/null \
        | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//"
}

# mask_quoted TEXT
# Emette TEXT con ogni span quotato sostituito da $_Q_SENTINEL.
#
# Le virgolette DOPPIE si mascherano senza condizioni: in italiano non hanno
# altro uso, quindi una coppia è sempre una citazione.
#
# Le SINGOLE no, e la differenza non è teorica: l'apostrofo italiano è
# graficamente lo stesso carattere. Una regex `'[^']*'` su
# «errori nell'ultima ora dell'app» matcherebbe «'ultima ora dell'» — cioè
# mangerebbe l'espressione temporale e il filtro si disattiverebbe in silenzio,
# la firma di FORMAT-1 su un'altra superficie. Quindi si maschera una coppia di
# apostrofi solo quando è DELIMITATA da spazi o dagli estremi della stringa,
# che è come si scrive una citazione e non come si scrive un'elisione.
#
# Il bot documenta entrambe le forme nel proprio messaggio d'aiuto
# («Racchiudi la stringa tra virgolette doppie o singole»), quindi trattare solo
# le doppie lascerebbe un buco che l'utente raggiunge seguendo le istruzioni.
mask_quoted() {
    local text="$1"
    text=$(sed -E "s/\"[^\"]*\"/${_Q_SENTINEL}/g" <<< "$text")
    # \1 e \3 preservano i delimitatori: senza, due span adiacenti si
    # incollerebbero e una parola confinante perderebbe il proprio spazio.
    text=$(sed -E "s/(^|[[:space:]])'[^']*'([[:space:]]|\$)/\1${_Q_SENTINEL}\2/g" <<< "$text")
    printf '%s' "$text"
}

# unmask_quoted TEXT SPAN...
# Inverso di mask_quoted: sostituisce le sentinelle, in ordine, con gli span
# passati come argomenti (virgolette incluse, come li emette quoted_spans_of).
#
# Serve a normalize-query.sh e non a param-extract.sh, e la ragione è una scelta
# di progetto: la sezione che trasforma la regione quotata in <PATTERN> /
# <LOGFILE> ha quattro sotto-rami in ordine deliberato, uno dei quali RIMUOVE le
# virgolette lasciando il nome letterale (SRCH-4). Spostare quel blocco prima del
# rilevamento entità lo esporrebbe alle stesse sezioni da cui lo stiamo
# proteggendo — sposterebbe il difetto invece di chiuderlo. Quindi si maschera,
# si rilevano le entità, si RIPRISTINA, e quel blocco continua a vedere
# esattamente ciò che vedeva prima: è anche ciò che garantisce NORM_QUERY
# invariato sul dataset, quindi nessun retrain.
unmask_quoted() {
    local text="$1"; shift
    local span
    for span in "$@"; do
        # Sostituzione della PRIMA sentinella per iterazione, via espansione bash
        # e non sed: lo span è testo dell'utente e potrebbe contenere `&`, `\` o
        # `/`, che in un rimpiazzo sed sarebbero interpretati.
        text="${text/${_Q_SENTINEL}/$span}"
    done
    printf '%s' "$text"
}
