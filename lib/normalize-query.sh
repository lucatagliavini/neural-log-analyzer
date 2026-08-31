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
# Emette: NORM_QUERY  DETECTED_APP  DETECTED_ENV  DETECTED_NODE  DETECTED_NODE_ALL
#
# Richiede: PROFILE_DIR esportata dal chiamante.
#

if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "echo '[ERROR] normalize-query: PROFILE_DIR non impostata' >&2"
    exit 1
fi

# entities.conf è OBBLIGATORIO: senza la mappa APP/ENV/NODE non esiste la
# normalizzazione delle entità, cioè il passo che rende il modello indipendente
# dai nomi del cliente. Il controllo è esplicito perché questo script è invocato
# anche fuori da chatbot.sh (build-dataset.sh, i test, invocazione diretta), dove
# il guard sui file del profilo non è passato: senza, `source` su un file assente
# dà "No such file or directory" senza dire quale profilo né cosa serve
# (ENTCONF-1, 2026-08-17).
#
# L'errore è emesso nella forma `echo '...' >&2` perché lo stdout di questo script
# viene passato a `eval` dal chiamante: un messaggio in chiaro diventerebbe codice.
for _req_f in system.conf entities.conf; do
    if [[ ! -f "$PROFILE_DIR/$_req_f" ]]; then
        echo "echo '[ERROR] normalize-query: $_req_f mancante in $PROFILE_DIR — file obbligatorio del profilo' >&2"
        exit 1
    fi
done

source "$PROFILE_DIR/system.conf"
source "$PROFILE_DIR/entities.conf"
source "$(dirname "${BASH_SOURCE[0]}")/utils-logfiles.sh"

query="${1,,}"
norm_query="$query"

DETECTED_APP=""
DETECTED_ENV=""
DETECTED_NODE=""
# Distinto da DETECTED_NODE vuoto: 1 significa "nodo vuoto CHIESTO
# esplicitamente" (SCOPE-1 passo 3), non "nodo non nominato". Vedi sezione
# 3-bis sotto per il perché della sostituzione con <NODE>.
DETECTED_NODE_ALL=0

# ─── SRCH-5: la regione quotata si SOTTRAE al rilevamento entità ──────────────
#
# La parte fra virgolette è la stringa che l'utente vuole CERCARE, cioè l'unico
# pezzo della frase che non è linguaggio naturale. Le sezioni 1-3 qui sotto
# leggevano anche là dentro, con questo esito misurato in produzione il
# 2026-08-24:
#
#   cerca "chiamata al nodo 7" nel nodo 4   → DETECTED_NODE=7, e il bot ha
#                                             cercato sul nodo 07 nonostante
#                                             `--node 4` sulla riga di comando
#   cerca "utente su ContactManager"        → DETECTED_APP=contactmanager
#
# cioè la stringa CERCATA decideva DOVE si cercava.
#
# Perché mascherare-e-ripristinare invece di spostare le sezioni: il blocco che
# trasforma la regione quotata in <LOGFILE>/<PATTERN> (sezione a, a-ter, a-bis
# sotto) ha quattro sotto-rami in ordine deliberato, e uno di essi — SRCH-4 —
# RIMUOVE le virgolette lasciando il nome di log letterale. Spostarlo prima delle
# sezioni 1-3 esporrebbe quel nome letterale esattamente alle sezioni da cui lo
# stiamo proteggendo: sposterebbe il difetto, non lo chiuderebbe. Così invece quel
# blocco continua a vedere ciò che vedeva prima, ed è anche la ragione per cui
# NORM_QUERY resta identico su tutte le query del dataset — verificato sulle 36
# con virgolette, quindi nessun retrain.
#
# La sezione 4 (APP_SHORT_ALIASES) gira già DOPO quel blocco: era la prova, già
# presente nel file, che l'ordine corretto è questo.
#
# La normalizzazione IP resta prima: un IP dentro le virgolette è comunque un IP
# per forma, e <IP> non è un'entità di sessione — non decide dove si cerca.
source "$(dirname "${BASH_SOURCE[0]}")/utils-quoted.sh"
mapfile -t _nq_spans < <(quoted_spans_of "$norm_query")
if [[ "${#_nq_spans[@]}" -gt 0 ]]; then
    norm_query="$(mask_quoted "$norm_query")"
fi

# ─── 0. Normalizzazione IP → <IP> ─────────────────────────────────────────────
# Un indirizzo IPv4 letterale diventa <IP>, come un nome di log diventa <LOGFILE>
# e una stringa quotata <PATTERN>: riconoscimento per FORMA, non per elenco.
#
# Il difetto che chiude (trovato 2026-08-20 con le asserzioni di Level 1b):
# "richieste da 192.168.1.100 stamattina" veniva instradata a tail_log invece di
# filter_ip. I soli segnali disponibili per filter_ip erano gli unigrammi `\bip\b`
# e `client|indirizz`, cioè PAROLE: una query che porta l'indirizzo e non la
# parola non attivava nulla. E i 6 esempi filter_ip del dataset contengono IP
# letterali (172.30.169.1, 10.156.7.250, …), quindi il modello era esposto a
# ottetti specifici invece che alla forma — la stessa non-generalizzazione che
# <LOGFILE> ha risolto per i nomi di log.
#
# Sta in testa a tutto perché un IP è una forma lessicale autonoma: normalizzarlo
# per primo evita che un'altra sezione ne consumi una parte.
#
# Non interferisce con IP_FILTER: param-extract.sh estrae l'indirizzo dalla query
# GREZZA (chatbot.sh:363 le passa "$query", non NORM_QUERY), quindi il valore
# reale resta disponibile ai tool.
if echo "$norm_query" | grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'; then
    norm_query=$(echo "$norm_query" | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<IP>/g')
fi

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
# Ordine esplicito (lunghezza decrescente, poi alfabetico) — "${!ARR[@]}" ha ordine
# hash bash non garantito tra versioni; con break-al-primo-match questo rendeva
# normalize-query.sh non deterministico rispetto alla propria config (tutte le
# chiavi di ENV_NODE_CODE hanno la stessa lunghezza, quindi senza tie-break
# alfabetico la scelta tra "test"/"prod"/... resterebbe indefinita).
_sorted_envs=$(for k in "${!ENV_NODE_CODE[@]}"; do printf '%d %s\n' "${#k}" "$k"; done \
               | sort -k1,1rn -k2,2 | awk '{print $2}')
for _env_name in $_sorted_envs; do
    if echo "$norm_query" | grep -qE "(^|[^a-z])${_env_name}([^a-z]|$)"; then
        DETECTED_ENV="$_env_name"
        norm_query=$(echo "$norm_query" | sed -E "s/(^|[^a-zA-Z])${_env_name}([^a-zA-Z]|$)/\1<ENV>\2/g")
        break
    fi
done

# 2b. Sinonimi italiani (da ENV_SYNONYMS in entities.conf) se non ancora trovato
# Stesso ordine deterministico della 2a.
if [[ -z "$DETECTED_ENV" ]] && declare -p ENV_SYNONYMS &>/dev/null; then
    _sorted_syns=$(for k in "${!ENV_SYNONYMS[@]}"; do printf '%d %s\n' "${#k}" "$k"; done \
                   | sort -k1,1rn -k2,2 | awk '{print $2}')
    for _syn in $_sorted_syns; do
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

# ─── 3-bis. Normalizzazione "tutti i nodi" ───────────────────────────────────
# Framework, non profilo (criterio NLP-1): "tutti i nodi"/"tutte le
# macchine"/"tutta la farm" sono lingua naturale italiana, non un alias del
# cliente — a differenza di NODE_PATTERNS (sezione 3 sotto), che vive in
# entities.conf perché "worker1" è un nome che dipende dall'installazione.
#
# Sostituita con <NODE> e non lasciata intatta: "tutt[ie]" (nlp/unigrams.txt)
# è già una feature addestrata sull'asse SORGENTI ("in tutti i log"), non
# sull'asse NODI. Misurato con lib/infer-dry.sh (2026-08-31): lasciare "tutti"
# nel testo sposta filter_errors da 69,0% a 58,0% e search_all_logs da 65,6% a
# 81,1% — la parola tira l'intent verso "tutte le sorgenti" anche quando
# l'utente intende "tutti i nodi". Sostituendo con <NODE> (come "nodo 4") la
# query torna identica alla forma senza scope esplicito nel testo, che è
# l'intent giusto.
#
# DETECTED_NODE resta vuoto: è DETECTED_NODE_ALL il segnale che porta "vuoto
# perché richiesto", non "vuoto perché non nominato". chatbot.sh lo usa per la
# stessa regola di allargamento dello scope che vale per un ambiente nominato
# di nuovo (principio 6, una sola politica).
_ALL_NODES_PATTERN='tutti[[:space:]]+i[[:space:]]+nodi|tutte[[:space:]]+le[[:space:]]+macchine|tutta[[:space:]]+la[[:space:]]+farm'
if [[ -z "$DETECTED_NODE" ]] && echo "$norm_query" | grep -qiE "$_ALL_NODES_PATTERN"; then
    DETECTED_NODE_ALL=1
    norm_query=$(echo "$norm_query" | sed -E "s/${_ALL_NODES_PATTERN}/<NODE>/g")
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

# ─── SRCH-5: ripristino della regione quotata ─────────────────────────────────
# Le entità sono state rilevate (sezioni 1-3) senza poter leggere dentro le
# virgolette. Da qui in avanti il contenuto quotato serve DAVVERO — la sezione 3.5
# deve distinguere un glob, un nome di log di sistema e una stringa di ricerca —
# quindi si rimette esattamente com'era.
#
# Ripristino in ORDINE e con espansione di parametro (vedi utils-quoted.sh): il
# testo è dell'utente e non va reinterpretato né come regex né come rimpiazzo sed.
if [[ "${#_nq_spans[@]}" -gt 0 ]]; then
    norm_query="$(unmask_quoted "$norm_query" "${_nq_spans[@]}")"
fi

# ─── 3.5 Normalizzazione LOGFILE ──────────────────────────────────────────────
# Sostituisce i nomi di file di log con <LOGFILE>, così il classificatore impara
# la *forma* "c'è un nome di logfile qui" e non l'elenco dei nomi. Un nome nel
# vocabolario legherebbe il modello a un singolo deployment: es. jgroups esiste
# solo per app con cache distribuita.
#
# Posizione vincolata su entrambi i lati:
#  - DOPO la sezione 1 (APP longest-match): un nome app completo vince sempre,
#    così "claimcenter.log" resta gestito come app.
#  - PRIMA della sezione 4: `grep -qE '\bcc\b'` matcha dentro "cc.log" (il "." è
#    word boundary), quindi se la sezione 4 agisse prima otterremmo "<APP>.log" —
#    il pattern che questa sezione elimina.
#
# I log di infrastruttura (ACCESS_LOG_BASE/SERVER_LOG_BASE/GC_LOG_BASE da
# system.conf) NON vengono toccati: hanno tool dedicati (filter_errors, tail_log
# via LOG_TYPE) e generalizzarli li farebbe collassare sulla classe named-log.

# La sostituzione è per FORMA, non per whitelist: qualsiasi <token>.log diventa
# <LOGFILE>. Una whitelist qui limiterebbe la generalizzazione ai soli nomi noti —
# sul nodo di produzione ci sono 28 log distinti e APP_LOG_NAMES ne elenca 16,
# quindi i restanti resterebbero senza segnale per il classificatore.
# Si esclude solo ciò che ha già un tool dedicato (vedi sotto).

# a) Glob quotato: "*-cc.log" / '*-cc.log' → <LOGFILE> (virgolette incluse).
#    Ha priorità: un pattern è già una scelta esplicita dell'utente.
#    Non imposta DETECTED_APP — un glob arbitrario non identifica un'applicazione.
_logfile_done=0
if echo "$norm_query" | grep -qE '"[^"]*\*[^"]*\.log"'; then
    norm_query=$(echo "$norm_query" | sed -E 's/"[^"]*\*[^"]*\.log"/<LOGFILE>/g')
    _logfile_done=1
elif echo "$norm_query" | grep -qE "'[^']*\*[^']*\.log'"; then
    norm_query=$(echo "$norm_query" | sed -E "s/'[^']*\*[^']*\.log'/<LOGFILE>/g")
    _logfile_done=1
fi

# a-ter) SRCH-4 — nome di log di SISTEMA fra virgolette, senza wildcard: le
#    virgolette si RIMUOVONO e il nome resta LETTERALE, non diventa <PATTERN>.
#
#    Il gap (segnalato dall'utente il 2026-08-19, test manuale in produzione):
#      trova "No HeadersTranscoder provided" nel "server.log" di oggi
#    → entrambe le stringhe quotate diventavano <PATTERN> in (a-bis), perché
#    "server.log" senza '*' non è glob-like per la (a). Il bigramma che discrimina
#    SRCH-2 (nlp/bigrams.txt) matcha la sottostringa LETTERALE
#    server.log|gc.log|access.log: sostituita da <PATTERN> non si attivava, e la
#    query cadeva su search_all_logs (87%) invece di grep_named_log.
#
#    Perché letterale e non <LOGFILE>: la (b) sotto esclude deliberatamente i log
#    di sistema dalla generalizzazione a <LOGFILE> (hanno tool dedicati), quindi
#    emettere <LOGFILE> qui contraddirebbe quella scelta a due passi di distanza.
#    Lasciandolo letterale la query diventa identica alla forma SENZA virgolette,
#    che già instrada correttamente — nessuna nuova feature, nessun nuovo confine
#    da insegnare alla rete: si riusa quello che funziona già.
#
#    Deve girare DOPO la (a) — un glob quotato resta <LOGFILE> — e PRIMA della
#    (a-bis), che altrimenti assorbirebbe la stringa in <PATTERN>.
#    Il riconoscimento passa da system_log_kind_of() (utils-logfiles.sh), unica
#    fonte di verità sui sinonimi dei log di sistema: nessun secondo rilevatore
#    parallelo che possa divergere (principio 8).
if [[ "$_logfile_done" -eq 0 ]]; then
    for _quo in '"' "'"; do
        while IFS= read -r _span; do
            [[ -z "$_span" ]] && continue
            if [[ -n "$(system_log_kind_of "${_span%.log}" 2>/dev/null)" ]]; then
                # Sostituzione via parameter expansion e non sed: il contenuto è
                # testo arbitrario dell'utente e non va reinterpretato come regex.
                norm_query="${norm_query//${_quo}${_span}${_quo}/${_span}}"
            fi
        done < <(echo "$norm_query" | grep -oE "${_quo}[^${_quo}]*${_quo}" \
                     | sed -e "s/^${_quo}//" -e "s/${_quo}\$//")
    done
fi

# a-bis) Qualsiasi stringa quotata RESTANTE (non glob-like, gestita sopra) →
#    <PATTERN>. Simmetrico a <LOGFILE>: le virgolette sono un segnale esplicito
#    dell'utente — o nome (parziale) di log, o stringa di ricerca — e senza
#    questo placeholder il classificatore non può imparare il confine, perché
#    il contenuto letterale (es. "NullPointerException") non è nel vocabolario.
#    Deve girare DOPO la (a): glob-like vince sempre, quindi
#    'cerca "*errore*.log"' diventa <LOGFILE> e non anche <PATTERN>.
#
#    APOSTROFO (corretto 2026-08-24, SRCH-5): il ramo con gli apici singoli usava
#    `'[^']*'` senza delimitatori, e in italiano l'apostrofo è graficamente lo
#    stesso carattere della virgoletta singola. Esito misurato su una frase
#    ordinaria:
#      «errori nell'ultima ora dell'app» → «errori nell<PATTERN>app»
#    cioè l'espressione temporale spariva dal vettore di feature. Misurato sul
#    classificatore: la confidenza scendeva da 66,2% a 56,8% e `search_all_logs`
#    compariva al 13,3% — perché <PATTERN> è per costruzione il segnale «qui c'è
#    una stringa da cercare», che in quella frase nessuno aveva chiesto.
#
#    Sopravvissuto a lungo perché ZERO delle 1171 query etichettate contiene un
#    apostrofo: il dataset non rappresentava la forma più naturale dell'italiano,
#    quindi nessun test poteva inciampare nel difetto.
#
#    La regola corretta vive in utils-quoted.sh (una coppia di apici è una
#    citazione solo se DELIMITATA da spazi o dagli estremi): questo ramo era un
#    chiamante non migrato, il caso letterale del principio 8. Si usa `mask_quoted`
#    per individuare gli span e poi si sostituisce il segnaposto, così esiste una
#    sola definizione di "regione quotata" in tutto il progetto.
if echo "$norm_query" | grep -qE '"[^"]*"'; then
    norm_query=$(echo "$norm_query" | sed -E 's/"[^"]*"/<PATTERN>/g')
else
    # mask_quoted marca gli span con la sentinella applicando la regola dei
    # delimitatori; qui la sentinella diventa <PATTERN>. Se non ci sono span
    # (apostrofi di elisione) la stringa torna identica e nulla cambia.
    _nq_masked="$(mask_quoted "$norm_query")"
    if [[ "$_nq_masked" != "$norm_query" ]]; then
        norm_query="${_nq_masked//"$_Q_SENTINEL"/<PATTERN>}"
    fi
fi

# b) Qualsiasi nome di logfile: "<token>.log" → <LOGFILE>.
#    Sostituisce nome+estensione insieme, così non resta un token "cc" isolato che
#    la sezione 4 trasformerebbe in <APP>.
#    Esclusi i log di infrastruttura, via _is_system_log_base() (utils-logfiles.sh,
#    condivisa con param-extract.sh e dispatch.sh): hanno tool dedicati
#    (filter_errors, tail_log via LOG_TYPE) e generalizzarli li farebbe collassare
#    sulla classe named-log. Riconosce sia il basename esatto (ACCESS_LOG_BASE) sia
#    i sinonimi in SYSTEM_LOG_SYNONYMS (system.conf) — "access.log" deve escludersi
#    anche se il file su disco si chiama undertow_access_log.log.
if [[ "$_logfile_done" -eq 0 ]]; then
    _cand_log=$(echo "$norm_query" | grep -oiE "[a-z0-9_.-]+\.log" | head -1)
    if [[ -n "$_cand_log" ]]; then
        _cand_base="${_cand_log%.log}"
        if ! _is_system_log_base "$_cand_base"; then
            # c) Preserva DETECTED_APP quando il nome del log è anche uno short-alias
            #    di app (cc→claimcenter, cm→contactmanager): serve a resolve-logs.sh
            #    per costruire la directory dei log custom giusta. Data-driven.
            if [[ -z "$DETECTED_APP" ]] && declare -p APP_SHORT_ALIASES &>/dev/null; then
                _alias_target="${APP_SHORT_ALIASES[${_cand_base,,}]:-}"
                [[ -n "$_alias_target" ]] && DETECTED_APP="$_alias_target"
            fi
            norm_query=$(echo "$norm_query" \
                | sed -E "s/(^|[^a-zA-Z0-9_.-])${_cand_log}([^a-zA-Z0-9]|$)/\1<LOGFILE>\2/gI")
        fi
    fi
fi

# ─── 4. Normalizzazione APP: abbreviazioni brevi da APP_SHORT_ALIASES ────────
# Dopo ENV/NODE per evitare collisioni con codici ambiente (es. "ce" = cert).
# APP_SHORT_ALIASES e APP_ALIAS_REGEX sono definiti in entities.conf.
if [[ -z "$DETECTED_APP" ]] && declare -p APP_SHORT_ALIASES &>/dev/null; then
    for _abbr in "${!APP_SHORT_ALIASES[@]}"; do
        _target="${APP_SHORT_ALIASES[$_abbr]}"
        # Verifica che l'app target sia disponibile nel profilo (AVAILABLE_APPS)
        _canonical="${APP_CANONICAL[$_target]:-}"
        _found=0
        for _av in "${AVAILABLE_APPS[@]}"; do
            [[ "${_av,,}" == "${_canonical,,}" || "${_av,,}" == "$_target" ]] && _found=1 && break
        done
        [[ "$_found" -eq 0 ]] && continue
        # Controlla abbreviazione breve
        if echo "$norm_query" | grep -qE "\b${_abbr}\b"; then
            DETECTED_APP="$_target"
            norm_query=$(echo "$norm_query" | sed -E "s/\b${_abbr}\b/<APP>/g")
            break
        fi
        # Controlla regex multi-parola se definita
        _rx="${APP_ALIAS_REGEX[$_target]:-}"
        if [[ -n "$_rx" ]] && echo "$norm_query" | grep -qE "$_rx"; then
            DETECTED_APP="$_target"
            norm_query=$(echo "$norm_query" | sed -E "s/${_rx}/<APP>/g")
            break
        fi
    done
fi

# ─── Output ───────────────────────────────────────────────────────────────────
printf "NORM_QUERY=%q\n"        "$norm_query"
printf "DETECTED_APP=%q\n"      "$DETECTED_APP"
printf "DETECTED_ENV=%q\n"      "$DETECTED_ENV"
printf "DETECTED_NODE=%q\n"     "$DETECTED_NODE"
printf "DETECTED_NODE_ALL=%q\n" "$DETECTED_NODE_ALL"
