#!/bin/bash
#
# Interfaccia conversazionale per l'analisi dei log.
#
# Uso con profilo (consigliato):
#   ./chatbot.sh --profile profiles/liquido [--env coll] [--node 2] [--app ClaimCenter]
#
# Uso con path espliciti (compatibilità legacy):
#   ./chatbot.sh --profile profiles/liquido --access-log path/access.log [--server-log ...] [--gc-log ...]
#
# Modalità non interattiva (--env obbligatorio):
#   ./chatbot.sh --profile profiles/liquido --env coll --query "errori 500 delle ultime 3 ore"
#   echo "..." | ./chatbot.sh --profile profiles/liquido --env prod
#
# In modalità interattiva --env è opzionale: il bot lo deduce dalla prima query
# che menziona l'ambiente (es: "errori 500 in coll nodo 2").
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ─── Parsing CLI ─────────────────────────────────────────────────────────────
PROFILE_DIR=""
ACTIVE_ENV=""
ACTIVE_NODE="01"
ACTIVE_APP=""
BASE_DIR_OVERRIDE=""
ACCESS_LOG=""
SERVER_LOG=""
GC_LOG=""
INTERACTIVE=1
QUERY=""
DRY_RUN=0
RESOLVED_DATE_FILTER=""
ACTIVE_NAMED_LOG=""
# Tema colore. Vuoto qui = non specificato da CLI: la risoluzione avviene dopo
# il caricamento di system.conf (che può impostare BOT_THEME), con default
# "mono" — nessun colore, perché il bot è usato anche da servizi che
# consumano l'output come testo e con redirect su file le sequenze ANSI
# sporcherebbero il contenuto.
THEME_CLI=""
# Default temporale: oggi (00:00→23:59). L'utente può sovrascrivere con query esplicita.
ACTIVE_TIME_FROM="$(date +%Y-%m-%dT00:00)"
ACTIVE_TIME_TO="$(date +%Y-%m-%dT23:59)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)    PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --env)        ACTIVE_ENV="$2";          shift 2 ;;
        --node)       ACTIVE_NODE="$2";         shift 2 ;;
        --app)        ACTIVE_APP="$2";          shift 2 ;;
        --base-dir)   BASE_DIR_OVERRIDE="$2";   shift 2 ;;
        --access-log) ACCESS_LOG="$2";          shift 2 ;;
        --server-log) SERVER_LOG="$2";          shift 2 ;;
        --gc-log)     GC_LOG="$2";              shift 2 ;;
        --query)      QUERY="$2"; INTERACTIVE=0; shift 2 ;;
        --theme)      THEME_CLI="$2";           shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --list-themes)
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/utils-theme.sh"
            echo "Temi disponibili (--theme <nome>, o BOT_THEME in system.conf):"
            theme_list | sed 's/^/  /'
            echo ""
            echo "Default: mono (nessun colore — output pulito per servizi e file)."
            exit 0
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!" | head -16 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

# ─── Validazione profilo ─────────────────────────────────────────────────────
if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: --profile profiles/liquido" >&2
    exit 1
fi
if [[ ! -f "$PROFILE_DIR/system.conf" || ! -f "$PROFILE_DIR/domain.conf" ]]; then
    echo "[ERROR] Profilo non valido: $PROFILE_DIR (mancano system.conf o domain.conf)" >&2
    exit 1
fi

# Esporta PROFILE_DIR per tutti i lib (infer, normalize-query, query-to-features, resolve-logs)
export PROFILE_DIR

# ─── File obbligatori del profilo ────────────────────────────────────────────
# Verificati PRIMA di sourciarli, così un file mancante produce un messaggio che
# dice quale e a cosa serve, invece dell'errore del primo consumatore che ci
# inciampa.
#
# entities.conf era trattato in tre modi diversi (ENTCONF-1, 2026-08-17):
# obbligatorio in normalize-query.sh (`source` senza guardia), opzionale qui e in
# param-extract.sh (`[[ -f ]] &&`). Su un profilo che non lo aveva, la query
# moriva con "No such file or directory" dal punto di vista di normalize-query —
# un messaggio che non dice cosa fare. È obbligatorio: senza di esso non esistono
# né la mappa APP/ENV/NODE né i pattern dei nodi, quindi la normalizzazione delle
# entità (il passo che rende il modello indipendente dai nomi del cliente) non può
# funzionare.
declare -A _PROFILE_FILES=(
    [system.conf]="path dei log, ambienti, basename dei log di sistema"
    [domain.conf]="tool disponibili, soglia di confidenza, topologia della rete"
    [entities.conf]="mappa APP/ENV/NODE per la normalizzazione delle entità"
)
_missing_files=()
for _f in "${!_PROFILE_FILES[@]}"; do
    [[ -f "$PROFILE_DIR/$_f" ]] || _missing_files+=("$_f — ${_PROFILE_FILES[$_f]}")
done
if [[ "${#_missing_files[@]}" -gt 0 ]]; then
    echo "[ERROR] Profilo incompleto: $PROFILE_DIR" >&2
    echo "        File obbligatori mancanti:" >&2
    printf '          %s\n' "${_missing_files[@]}" >&2
    echo "        Confronta con profiles/liquido/, che è il profilo di riferimento." >&2
    exit 1
fi
unset _PROFILE_FILES _missing_files _f

# Carica configurazione di sistema e dominio
source "$PROFILE_DIR/system.conf"
# Override locale (non deployato) — per variabili specifiche dell'ambiente di produzione
[[ -f "$PROFILE_DIR/system.local.conf" ]] && source "$PROFILE_DIR/system.local.conf"
source "$PROFILE_DIR/domain.conf"
# Dizionario entità (APP alias, ENV synonyms, NODE patterns) per normalize-query.sh
source "$PROFILE_DIR/entities.conf"

# ─── Completezza del profilo ─────────────────────────────────────────────────
# Un profilo incompleto è un errore di CONFIGURAZIONE, e va detto all'avvio con
# l'elenco di cosa manca — non scoperto alla prima query, dove emergerebbe come
# un messaggio parziale da resolve-logs.sh su una sola variabile per volta.
#
# Trovato con PROF-1 (2026-08-17): profiles/usnext esisteva nel repo definendo
# AVAILABLE_APPS, APP_SUBPATH e 11 TOOL_DESC — quindi SEMBRAVA completo — ma senza
# i tre *_LOG_BASE, quindi ogni query moriva su `[ERROR] ACCESS_LOG_BASE non
# impostato`. Un profilo scheletro indistinguibile da uno funzionante suggerisce
# una generalizzazione dichiarata e non verificata.
_missing_cfg=()
for _req in LOG_BASE_DIR ACCESS_LOG_BASE SERVER_LOG_BASE GC_LOG_BASE \
            SERVER_LOG_FORMAT NODE_NAME_TEMPLATE DEFAULT_APP; do
    [[ -z "${!_req:-}" ]] && _missing_cfg+=("$_req")
done
# Gli array associativi/indicizzati non si testano con -z: si verifica che siano
# dichiarati e non vuoti.
declare -p ENV_NODE_CODE &>/dev/null || _missing_cfg+=("ENV_NODE_CODE")
[[ "$(declare -p AVAILABLE_APPS 2>/dev/null)" == *"("*")"* ]] || _missing_cfg+=("AVAILABLE_APPS")
if [[ "${#_missing_cfg[@]}" -gt 0 ]]; then
    echo "[ERROR] Profilo incompleto: $PROFILE_DIR" >&2
    echo "        Mancano in system.conf: ${_missing_cfg[*]}" >&2
    echo "        Confronta con profiles/liquido/system.conf, che è il riferimento." >&2
    exit 1
fi
unset _missing_cfg _req

# ─── Tema colore ─────────────────────────────────────────────────────────────
# Precedenza: --theme > BOT_THEME dall'ambiente > BOT_THEME da system.conf /
# system.local.conf > "mono".
# NO_COLOR (convenzione https://no-color.org) forza mono: è rispettata da
# molti strumenti a riga di comando e chi la imposta non vuole ANSI da nessuno.
source "$LIB_DIR/utils-theme.sh"
_theme_want="${THEME_CLI:-${BOT_THEME:-mono}}"
[[ -n "${NO_COLOR:-}" ]] && _theme_want="mono"
theme_load "$_theme_want"
# Esportato per i tool che girano come processi figli (search_all_logs.sh) e
# per dispatch.sh, che lo passa a gawk con theme_awk_args.
export BOT_THEME="$BOT_THEME_ACTIVE"

# Allinea TZ di sistema con quella dei log del server (tutti i sottoprocessi la ereditano)
[[ -n "${LOG_TZ:-}" ]] && export TZ="$LOG_TZ"

# QUERY_LOG_DIR: default a <dir di chatbot.sh>/logs se il profilo non lo
# imposta. Il default vive QUI e non in system.conf perché SCRIPT_DIR non è
# ancora noto quando quel file viene sourciato — e un path relativo funziona
# in qualsiasi installazione senza configurazione per-host (in produzione:
# /product/lana-bot/neural-log-analyzer/logs).
# `logs/` è escluso da deploy.sh e da .gitignore, quindi i log accumulati non
# vengono né sovrascritti dai deploy né committati.
# Resta sovrascrivibile da system.conf, system.local.conf o dall'ambiente:
# `QUERY_LOG_DIR= ./chatbot.sh ...` (vuoto) disattiva il logging.
QUERY_LOG_DIR="${QUERY_LOG_DIR:-$SCRIPT_DIR/logs}"

# Override base dir se passato esplicitamente
[[ -n "$BASE_DIR_OVERRIDE" ]] && LOG_BASE_DIR="$BASE_DIR_OVERRIDE"

# App di default dal profilo se non specificata
[[ -z "$ACTIVE_APP" ]] && ACTIVE_APP="$DEFAULT_APP"

# Path del modello addestrato
MODEL_DIR="$PROFILE_DIR/models/intent_classifier"
TOOLS_DIR="$SCRIPT_DIR/lib/tools"

# Carica dispatch (open_log + dispatch_tool)
source "$LIB_DIR/dispatch.sh"

# ─── Modalità non interattiva: deduzione contesto dalla query ────────────────
if [[ "$INTERACTIVE" -eq 0 && -z "$ACCESS_LOG" ]]; then
    if [[ -n "$QUERY" ]]; then
        source <("$LIB_DIR/normalize-query.sh" "$QUERY")
        export NORM_QUERY
        [[ -n "$DETECTED_ENV"  && "$DETECTED_ENV"  != "$ACTIVE_ENV"  ]] && ACTIVE_ENV="$DETECTED_ENV"
        [[ -n "$DETECTED_NODE" && "$DETECTED_NODE" != "$ACTIVE_NODE" ]] && ACTIVE_NODE="$DETECTED_NODE"
        if [[ -n "$DETECTED_APP" && -z "$ACTIVE_APP" ]]; then
            ACTIVE_APP="${APP_CANONICAL[$DETECTED_APP]:-$DETECTED_APP}"
        fi
    fi
    if [[ -z "$ACTIVE_ENV" ]]; then
        echo "[ERROR] --query richiede --env (o --access-log), oppure menziona l'ambiente nella query (es: \"errori in coll\")" >&2
        exit 1
    fi
fi

# ─── Validazione modello ─────────────────────────────────────────────────────
if [[ ! -d "$MODEL_DIR" ]]; then
    echo "[ERROR] Modello non trovato: $MODEL_DIR" >&2
    echo "        Esegui prima: ./setup.sh --profile $PROFILE_DIR && ./train.sh --profile $PROFILE_DIR" >&2
    exit 1
fi

# ─── Risoluzione log da env/nodo/app ─────────────────────────────────────────
resolve_session_logs() {
    local resolved
    resolved=$(DATE_FILTER="${DATE_FILTER:-}" "$LIB_DIR/resolve-logs.sh" "$LOG_BASE_DIR" "$ACTIVE_ENV" "$ACTIVE_NODE" "$ACTIVE_APP") || {
        echo "[ERROR] Impossibile risolvere i log per: env=$ACTIVE_ENV node=$ACTIVE_NODE app=$ACTIVE_APP" >&2
        return 1
    }
    eval "$resolved"
}

# Risoluzione iniziale solo se --env è stato passato o se --access-log è esplicito
# (in dry-run non servono i log — skip)
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -n "$ACTIVE_ENV" && -z "$ACCESS_LOG" ]]; then
        resolve_session_logs || exit 1
    elif [[ -n "$ACCESS_LOG" && ! -f "$ACCESS_LOG" ]]; then
        echo "[ERROR] File non trovato: $ACCESS_LOG" >&2
        exit 1
    fi
fi

# ─── Query logging ───────────────────────────────────────────────────────────
_QUERY_LOG_FILE=""

_init_query_log() {
    [[ -z "${QUERY_LOG_DIR:-}" ]] && return
    mkdir -p "$QUERY_LOG_DIR" 2>/dev/null || return
    # g+w sulla directory: il bot può essere lanciato da utenti diversi (o da
    # root in una sessione di manutenzione) e chi crea la directory per primo
    # ne diventa proprietario — senza questo, l'utente successivo non potrebbe
    # più scrivere e il logging si spegnerebbe in silenzio (accaduto in
    # produzione 2026-08-06: directory creata da root, bot usato da uga04128).
    chmod g+w "$QUERY_LOG_DIR" 2>/dev/null || true
    _QUERY_LOG_FILE="${QUERY_LOG_DIR}/chatbot-$(date +%Y-%m-%d).log"
    # Se il file esiste ma non è scrivibile, il logging è inefficace: meglio
    # dirlo che accumulare query non registrate credendo di raccogliere dati.
    if [[ -e "$_QUERY_LOG_FILE" && ! -w "$_QUERY_LOG_FILE" ]]; then
        printf "  ${C_WARN}⚠ Log query non scrivibile: %s${C_RESET}\n" "$_QUERY_LOG_FILE" >&2
        printf "  ${C_LBL}Il logging di performance è disattivato per questa sessione.${C_RESET}\n" >&2
        _QUERY_LOG_FILE=""
        return
    fi
    # Nuovo file: g+w così un altro utente potrà appendervi domani.
    if [[ ! -e "$_QUERY_LOG_FILE" ]]; then
        : > "$_QUERY_LOG_FILE" 2>/dev/null && chmod g+w "$_QUERY_LOG_FILE" 2>/dev/null || true
    fi
}

# log_query QUERY TOOLS [TOTAL_MS]
#
# Colonne TSV (l'ordine è un contratto: gli script di analisi offline usano
# $N, aggiungere solo IN CODA):
#   1 timestamp  2 env  3 node  4 query  5 tools  6 profilo
#   7 durata totale ms  8 fase selezione ms  9 fase ricerca/analisi ms
#   10 file selezionati  11 file con match  12 byte processati  13 worker
#
# Le colonne 8-13 arrivano dal tool via BOT_PERF_FILE (sourcato in
# run_query): un tool che non le produce lascia 0, così una riga resta
# sempre confrontabile con le altre — nessun campo mancante da gestire in
# analisi. Con `awk -F'\t'` si aggregano per tool, per ora, per volume.
log_query() {
    [[ -z "$_QUERY_LOG_FILE" ]] && return
    local query="$1" tools="$2" total_ms="${3:-0}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" \
        "${ACTIVE_ENV:-?}" "${ACTIVE_NODE:-?}" \
        "$query" \
        "$tools" \
        "${profile_name:-}" \
        "$total_ms" \
        "${PERF_SELECT_MS:-0}" "${PERF_SEARCH_MS:-0}" \
        "${PERF_FILES:-0}" "${PERF_FILES_MATCHED:-0}" \
        "${PERF_BYTES:-0}" "${PERF_JOBS:-0}" \
        >> "$_QUERY_LOG_FILE" 2>/dev/null || true
}

_rotate_query_logs() {
    [[ -z "${QUERY_LOG_DIR:-}" ]] && return
    local days="${QUERY_LOG_RETENTION_DAYS:-15}"
    find "$QUERY_LOG_DIR" -maxdepth 1 -name 'chatbot-*.log' \
        -mtime "+${days}" -delete 2>/dev/null || true
}

trap '_rotate_query_logs' EXIT

# ─── Esecuzione query ────────────────────────────────────────────────────────
run_query() {
    local query="$1"
    local _t_query_start
    _t_query_start=$(date +%s%3N 2>/dev/null || echo 0)
    # Azzerate ad ogni query: sono popolate dal tool via BOT_PERF_FILE e, se
    # restassero dal giro precedente, una query senza metriche erediterebbe
    # quelle della precedente falsando l'analisi offline.
    PERF_SELECT_MS=0 PERF_SEARCH_MS=0 PERF_FILES=0
    PERF_FILES_MATCHED=0 PERF_BYTES=0 PERF_JOBS=0

    # Normalizza la query ed estrai entità (APP, ENV, NODE) — unica fonte di verità
    source <("$LIB_DIR/normalize-query.sh" "$query")
    export NORM_QUERY
    # Esportate perché param-extract.sh (sotto) gira in un sottoprocesso via
    # command substitution: senza export eredita queste variabili vuote e le
    # ri-emette invariate (vedi commento in param-extract.sh), azzerando qui
    # sotto quanto appena rilevato: bug reale (2026-08-05) — DETECTED_NODE
    # tornava vuoto dopo l'eval di param-extract.sh, facendo perdere il nodo
    # specificato in query a search_all_logs (unico tool che legge
    # DETECTED_NODE direttamente invece di ACTIVE_NODE già risolto sopra).
    export DETECTED_APP DETECTED_ENV DETECTED_NODE

    local ctx_changed=0
    [[ -n "$DETECTED_ENV"  && "$DETECTED_ENV"  != "$ACTIVE_ENV"  ]] && { ACTIVE_ENV="$DETECTED_ENV";  ctx_changed=1; }
    if [[ -n "$DETECTED_NODE" ]]; then
        local _norm_node; _norm_node=$(printf "%02d" "$((10#$DETECTED_NODE))" 2>/dev/null || echo "$DETECTED_NODE")
        [[ "$_norm_node" != "$ACTIVE_NODE" ]] && { ACTIVE_NODE="$_norm_node"; ctx_changed=1; }
    fi
    if [[ -n "$DETECTED_APP" ]]; then
        local _canonical="${APP_CANONICAL[$DETECTED_APP]:-$DETECTED_APP}"
        if [[ "$_canonical" != "$ACTIVE_APP" ]]; then
            ACTIVE_APP="$_canonical"
            ACTIVE_NAMED_LOG=""
            ctx_changed=1
        fi
    fi

    # Estrai parametri strutturati (TIME_FROM, TIME_TO, DATE_FILTER, ...) prima di resolve
    eval "$("$LIB_DIR/param-extract.sh" "$query")"

    # NAMED_LOG: aggiorna il contesto solo se la query specifica un log esplicito;
    # altrimenti riusa l'ultimo log menzionato in sessione (es. "stessa cosa" / "nello stesso log")
    # LOG_EXPLICIT: 1 se QUESTA query nomina un log, 0 se lo eredita dalla sessione.
    # Non persistente, come TIME_EXPLICIT: serve all'avviso di incoerenza più sotto, che
    # deve scattare solo su un log appena nominato — altrimenti dopo una query sul jgroups
    # ogni query successiva mostrerebbe l'avviso pur non avendo nominato nulla.
    LOG_EXPLICIT=0
    if [[ -n "$NAMED_LOG" ]]; then
        ACTIVE_NAMED_LOG="$NAMED_LOG"
        LOG_EXPLICIT=1
    else
        NAMED_LOG="$ACTIVE_NAMED_LOG"
    fi

    # TIME_EXPLICIT: 1 se QUESTA query (non la sessione) nomina un tempo — usato solo
    # da tail_log per decidere se ignorare la finestra ereditata (vedi dispatch.sh).
    # Non persistente: si ricalcola da zero ad ogni query, a differenza di ACTIVE_TIME_FROM/TO.
    TIME_EXPLICIT=0
    [[ -n "$TIME_FROM" || -n "$TIME_TO" ]] && TIME_EXPLICIT=1

    # CTX-1 — filtro temporale persistente.
    # Se la query specifica un tempo → aggiorna il contesto attivo.
    # Se non lo specifica → eredita da ACTIVE_TIME_FROM/TO (come già avviene per ACTIVE_NODE).
    if [[ -n "$TIME_FROM" || -n "$TIME_TO" ]]; then
        [[ "$TIME_FROM" != "$ACTIVE_TIME_FROM" || "$TIME_TO" != "$ACTIVE_TIME_TO" ]] && ctx_changed=1
        ACTIVE_TIME_FROM="$TIME_FROM"
        ACTIVE_TIME_TO="$TIME_TO"
    else
        TIME_FROM="$ACTIVE_TIME_FROM"
        TIME_TO="$ACTIVE_TIME_TO"
    fi

    # DATE_FILTER è una dimensione del contesto: se cambia → re-resolve
    [[ "${DATE_FILTER:-}" != "$RESOLVED_DATE_FILTER" ]] && { RESOLVED_DATE_FILTER="${DATE_FILTER:-}"; ctx_changed=1; }

    # CTX-3 — intercetta frasi di solo-contesto prima della lazy resolution e del classificatore.
    # Deve stare qui: "stamattina" senza env è un aggiornamento temporale valido anche senza log.
    # Usa NORM_QUERY (già normalizzata con placeholder <ENV>/<NODE>/<APP>) invece della query
    # originale: "sul nodo 4 di produzione" → "sul <NODE> di <ENV>" → residuo vuoto dopo strip.
    # Due casi:
    # A) ctx_changed=1 e il residuo di NORM_QUERY (senza placeholder e connettivi) è ≤4 char
    # B) TIME_ONLY_QUERY=1 — rilevato direttamente in utils-time.sh usando i suoi stessi pattern
    local _ctx_only=0
    local _ctx_query_stripped
    _ctx_query_stripped=$(echo "${NORM_QUERY:-$query}" | \
        sed -E 's/<(ENV|NODE|APP)>//gI' | \
        sed -E 's/\b(considera|lavoriamo|lavora|siamo|stiamo|parliamo|analizziamo|guardiam[oi]|fissa|imposta|usa|usiam[oi]|sul|sulla|sullo|sulle|sugli|nel|nella|nello|nelle|negli|del|della|dello|delle|degli|al|alla|allo|alle|agli|dal|dalla|dallo|dalle|dagli|col|nodo|in|su|di|da|per|il|la|lo|le|gli|un|una|e|a|o|con)\b//gI' | \
        sed -E 's/[[:space:]]+/ /g' | sed 's/^ *//; s/ *$//')
    [[ "$ctx_changed" -eq 1 && ${#_ctx_query_stripped} -le 4 ]] && _ctx_only=1
    [[ "${TIME_ONLY_QUERY:-0}" == "1" ]] && _ctx_only=1
    if [[ "$_ctx_only" -eq 1 ]]; then
        # Se env/nodo è cambiato, re-resolve i log prima di tornare — altrimenti
        # la query successiva usa ancora i log del nodo precedente.
        if [[ "$DRY_RUN" -eq 0 && "$ctx_changed" -eq 1 && -n "$ACTIVE_ENV" ]]; then
            resolve_session_logs || true
        fi
        printf "\n"
        context_line
        printf "  ${C_LBL}Contesto aggiornato.${C_RESET}\n\n"
        return
    fi

    # show_help non richiede contesto — intercetta prima della lazy resolution
    if echo "${query,,}" | grep -qiE "^(aiuto|help|\?|cosa (sai|puoi)[[:space:]]+(fare|fai)|cosa (fai|fare)|che (cosa )?(sai|puoi)[[:space:]]+(fare|fai)|strumenti|comandi)[[:space:]]*\?*$"; then
        printf "\n${C_BOLD}┌─${C_RESET} Query: %s\n" "$query"
        print_help
        printf "${C_BOLD}└──────────────────────────────────────────${C_RESET}\n"
        return
    fi

    # Lazy resolution: se ancora senza log, tenta ora che potremmo avere il contesto
    # (in dry-run non servono i log — skip)
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ -z "$ACCESS_LOG" ]]; then
            if [[ -z "$ACTIVE_ENV" ]]; then
                echo "  [INFO] Ambiente non impostato. Specifica env nella query (es: \"errori in coll\") oppure avvia con --env."
                return
            fi
            resolve_session_logs || return 1
        elif [[ "$ctx_changed" -eq 1 && -n "$ACTIVE_ENV" ]]; then
            resolve_session_logs || return 1
        fi
    fi

    printf "\n${C_BOLD}┌─${C_RESET} Query: %s\n" "$query"

    # Modalità dry-run: mostra ranking classificatore senza eseguire tool
    if [[ "$DRY_RUN" -eq 1 ]]; then
        "$LIB_DIR/infer-dry.sh" "$query"
        return
    fi

    local tools
    tools=$("$LIB_DIR/infer.sh" "$query" 2>/dev/null)

    if [[ -z "$tools" ]]; then
        log_query "$query" "none" \
            "$(( $(date +%s%3N 2>/dev/null || echo 0) - _t_query_start ))"
        printf "${C_BOLD}└─${C_RESET} ${C_LBL}[INFO] Nessun tool attivato con confidenza >= %s${C_RESET}\n" "$TOOL_THRESHOLD"
        printf "   Prova a riformulare la query. Digita ${C_BOLD}aiuto${C_RESET} per vedere cosa so fare.\n"
        return
    fi

    # Tool attivati come "tool1:pct,tool2:pct". Il log vero e proprio avviene
    # DOPO l'esecuzione (in fondo a questa funzione): solo lì si conosce la
    # durata, che è il dato per cui esiste il log di performance.
    local tools_log
    tools_log=$(awk '{printf "%s:%d%%,", $1, $2*100}' <<< "$tools" | sed 's/,$//')

    printf "${C_BOLD}│${C_RESET}  Tool attivati:\n"
    while IFS=' ' read -r tool prob; do
        pct=$(awk -v p="$prob" 'BEGIN { printf "%.0f", p * 100 }')
        printf "${C_BOLD}│${C_RESET}    ${C_BOLD}▸ %s${C_RESET} ${C_LBL}(%s%%)${C_RESET} — %s\n" \
            "$tool" "$pct" "${TOOL_DESC[$tool]:-}"
    done <<< "$tools"

    # L'avviso su UNRESOLVED_LOG è stato rimosso (2026-08-04): elencava gli alias di
    # entities.conf, che possono divergere dal disco. Ora se il log non esiste
    # ci pensa suggest_available_logs() in dispatch.sh, che guarda i file reali del
    # nodo ed evidenzia i nomi simili — il refuso è l'errore tipico.

    # La query nomina un log (NAMED_LOG risolto) ma nessuno dei tool attivati lo legge:
    # `tail_log`/`filter_errors` aprono access log e server.log ignorando NAMED_LOG,
    # quindi l'utente riceve dati plausibili dal file sbagliato senza accorgersene.
    # Caso tipico: "errori di cluster nel jgroups log" (senza il punto) → filter_errors.
    # L'incoerenza è rilevabile solo qui, dove si conoscono sia NAMED_LOG sia i tool
    # scelti — nessuno dei due componenti da solo ha entrambe le informazioni.
    if [[ -n "${NAMED_LOG:-}" && "${LOG_EXPLICIT:-0}" -eq 1 ]]; then
        local _reads_named=0
        while IFS=' ' read -r _t _; do
            [[ "$_t" == "tail_named_log" || "$_t" == "grep_named_log" ]] && _reads_named=1
        done <<< "$tools"
        if [[ "$_reads_named" -eq 0 ]]; then
            local _Y="${C_WARN}" _D="${C_LBL}" _B="${C_BOLD}" _X="${C_RESET}"
            printf "${C_BOLD}│${C_RESET}\n"
            printf "${C_BOLD}│${C_RESET}  ${_Y}⚠ Hai nominato il log \"%s\" ma nessuno degli strumenti attivati lo legge.${_X}\n" \
                "$NAMED_LOG"
            printf "${C_BOLD}│${C_RESET}    ${_D}Per leggere quel log, nominalo con l'estensione:${_X}\n"
            printf "${C_BOLD}│${C_RESET}    ${_D}es:${_X} ${_B}errori nel %s.log${_X}${_D}  ·  ${_X}${_B}ultime righe del %s.log${_X}\n" \
                "$NAMED_LOG" "$NAMED_LOG"
        fi
    fi

    printf "${C_BOLD}│${C_RESET}\n"

    # BOT_PERF_FILE: canale con cui i tool (processi figli) restituiscono le
    # proprie metriche di fase. Creato solo se il query log è attivo — senza
    # di esso le metriche non avrebbero destinazione.
    local _perf_file=""
    if [[ -n "$_QUERY_LOG_FILE" ]]; then
        _perf_file=$(mktemp 2>/dev/null) || _perf_file=""
        export BOT_PERF_FILE="$_perf_file"
    fi

    while IFS=' ' read -r tool _prob; do
        printf "${C_BOLD}├─── %s${C_RESET} ─────────────────────────────\n" "$tool"
        if [[ "$tool" == "search_all_logs" && -z "${DETECTED_NODE:-}" && -n "${ACTIVE_ENV:-}" ]]; then
            context_line "no_node"
        else
            context_line
        fi
        echo ""
        dispatch_tool "$tool" || true
        echo ""
        # Raccoglie le metriche di questo tool (se le ha prodotte) prima del
        # tool successivo, che sovrascriverebbe il file.
        if [[ -n "$_perf_file" && -s "$_perf_file" ]]; then
            source "$_perf_file" 2>/dev/null || true
            : > "$_perf_file"
        fi
    done <<< "$tools"

    [[ -n "$_perf_file" ]] && rm -f "$_perf_file"
    unset BOT_PERF_FILE

    log_query "$query" "$tools_log" \
        "$(( $(date +%s%3N 2>/dev/null || echo 0) - _t_query_start ))"

    printf "${C_BOLD}└──────────────────────────────────────────${C_RESET}\n"
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Stampa il contesto attivo su stderr in formato leggibile.
# Colori: DIM per le etichette, WHT (bianco puro) per i valori — coerente con UI-8.
# Viene chiamata in cima ad ogni risposta (CTX-2).
# context_line [no_node]
# Con argomento "no_node": omette il nodo dal contesto (es. ricerca multi-nodo).
context_line() {
    local _hide_node="${1:-}"
    local _D="${C_LBL}" _W="${C_VAL}" _B="${C_BOLD}" _X="${C_RESET}"
    local parts=()

    local _has_any=0
    [[ -n "$ACTIVE_ENV" || -n "$ACTIVE_TIME_FROM" || -n "$ACTIVE_TIME_TO" || -n "$ACCESS_LOG" ]] && _has_any=1

    if [[ "$_has_any" -eq 1 ]]; then
        if [[ -n "$ACCESS_LOG" && -z "$ACTIVE_ENV" ]]; then
            printf "  ${_D}[log: ${_X}${_W}%s${_X}${_D}]${_X}\n" "$ACCESS_LOG"
            return
        fi
        local _NA="${_D}N/A${_X}"
        parts+=("${_W}${ACTIVE_ENV:-${_NA}}${_X}")
        if [[ "$_hide_node" == "no_node" ]]; then
            parts+=("${_D}tutti i nodi${_X}")
        else
            parts+=("${_D}nodo${_X} ${_W}${ACTIVE_NODE:-${_NA}}${_X}")
        fi
        [[ -n "$ACTIVE_APP"       ]] && parts+=("${_W}${ACTIVE_APP}${_X}")
        [[ -n "$ACTIVE_NAMED_LOG" ]] && parts+=("${_D}log${_X} ${_W}${ACTIVE_NAMED_LOG}${_X}")
        if [[ -n "$ACTIVE_TIME_FROM" || -n "$ACTIVE_TIME_TO" ]]; then
            local tf="${ACTIVE_TIME_FROM:-inizio}" tt="${ACTIVE_TIME_TO:-fine}"
            tf="${tf/T/ }"; tt="${tt/T/ }"
            parts+=("${_W}${tf}${_X}${_D}→${_X}${_W}${tt}${_X}")
        fi
        local joined="" sep=""
        for _p in "${parts[@]}"; do
            joined="${joined}${sep}${_p}"
            sep="${_D} · ${_X}"
        done
        printf "  ${_D}[${_X}${joined}${_D}]${_X}\n"
    else
        printf "  ${_D}[contesto non impostato — es: \"errori in coll\"]${_X}\n"
    fi
}

profile_name=$(basename "$PROFILE_DIR")
_init_query_log

if [[ "$INTERACTIVE" -eq 0 ]]; then
    run_query "${QUERY:-}"
else
    printf "${C_BOLD}Neural Log Analyzer${C_RESET} — profilo: ${C_ACCENT}${profile_name}${C_RESET}\n"
    context_line
    [[ -n "${SERVER_LOG:-}" ]] && printf "     server.log: ${C_LBL}$SERVER_LOG${C_RESET}\n"
    [[ -n "${GC_LOG:-}"     ]] && printf "     gc.log:     ${C_LBL}$GC_LOG${C_RESET}\n"
    printf "${C_LBL}Digita la tua domanda (Ctrl+C per uscire) — ${C_RESET}${C_BOLD}aiuto${C_RESET}${C_LBL} per la lista degli strumenti${C_RESET}\n\n"

    while true; do
        printf "> "
        read -r query || break
        [[ -z "$query" ]] && continue
        [[ "$query" == "exit" || "$query" == "quit" ]] && break
        # Keyword detection help — intercetta prima del classificatore
        if echo "$query" | grep -qiE "^(aiuto|help|\?|cosa (sai|puoi)[[:space:]]+(fare|fai)|cosa (fai|fare)|che (cosa )?(sai|puoi)[[:space:]]+(fare|fai)|strumenti|comandi)[[:space:]]*\?*$"; then
            print_help
            continue
        fi
        run_query "$query"
    done
fi
