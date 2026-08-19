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

# a-bis) Qualsiasi stringa quotata RESTANTE (non glob-like, gestita sopra) →
#    <PATTERN>. Simmetrico a <LOGFILE>: le virgolette sono un segnale esplicito
#    dell'utente — o nome (parziale) di log, o stringa di ricerca — e senza
#    questo placeholder il classificatore non può imparare il confine, perché
#    il contenuto letterale (es. "NullPointerException") non è nel vocabolario.
#    Deve girare DOPO la (a): glob-like vince sempre, quindi
#    'cerca "*errore*.log"' diventa <LOGFILE> e non anche <PATTERN>.
if echo "$norm_query" | grep -qE '"[^"]*"'; then
    norm_query=$(echo "$norm_query" | sed -E 's/"[^"]*"/<PATTERN>/g')
elif echo "$norm_query" | grep -qE "'[^']*'"; then
    norm_query=$(echo "$norm_query" | sed -E "s/'[^']*'/<PATTERN>/g")
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
printf "NORM_QUERY=%q\n"     "$norm_query"
printf "DETECTED_APP=%q\n"   "$DETECTED_APP"
printf "DETECTED_ENV=%q\n"   "$DETECTED_ENV"
printf "DETECTED_NODE=%q\n"  "$DETECTED_NODE"
