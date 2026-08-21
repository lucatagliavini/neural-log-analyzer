#!/bin/bash
#
# Risolve i path dei file di log data la tupla (base_dir, env, nodo, app).
# Emette variabili shell: ACCESS_LOG, ACCESS_LOG_DIR, ACCESS_LOG_BASE,
#                         SERVER_LOG, GC_LOG, GC_LOG_DIR, GC_LOG_BASE,
#                         CUSTOM_LOG_DIR, LOG_SEARCH_ROOT
#
# LOG_SEARCH_ROOT è la directory del nodo: il contratto del profilo si ferma
# lì, sotto la struttura è ignota e va scoperta ricorsivamente (vedi
# CLAUDE.md, "Principi di progettazione").
#
# La selezione temporale dei file di rotazione è delegata a utils-logfiles.sh
# (chiamata in open_logs() dentro dispatch.sh ad ogni query).
#
# Uso: eval "$(./lib/resolve-logs.sh <base_dir> <env> <nodo_num> [<app>])"
#
# Struttura attesa:
#   <base_dir>/<env>/<NODE_NAME_TEMPLATE>/     ← il contratto si ferma QUI
#
# Sotto la directory del nodo la struttura è IGNOTA per contratto e i log di
# sistema vengono SCOPERTI ricorsivamente da resolve_system_log_dir()
# (utils-logfiles.sh), non costruiti da APP_SUBPATH. Prima di LOGDISC-4 questo
# script calcolava APP_DIR="$NODE_DIR/$(eval echo "$APP_SUBPATH")" e cercava i
# tre log lì dentro: erano l'ultima area a violare il principio 6, dopo che
# LOGDISC-1 (named log) e LOGDISC-2 (search_all_logs) avevano già rimosso la
# stessa assunzione.
#
# NODE_NAME_TEMPLATE, CUSTOM_LOG_SUBPATH e i tre *_LOG_BASE sono definiti in
# system.conf — niente hardcoded qui (ARCH-6, "nessun default implicito nel
# codice", consolidato 2026-08-06 rimuovendo la duplicazione
# 'undertow_access_log'/'server'/'gc' che c'era prima in questo file).
#
# Gli errori qui sotto si emettono in CHIARO su stderr, non nella forma
# eval-able `echo "echo '...' >&2" >&2` che usa normalize-query.sh — e la
# differenza NON è stilistica, sta nel contratto del chiamante:
#   normalize-query.sh  →  `source <(script)`   stdout eseguito SEMPRE, anche
#                                               dopo `exit 1`: la forma
#                                               eval-able è l'unico modo per
#                                               far arrivare il messaggio.
#   resolve-logs.sh     →  `res=$(script) || {` stdout SCARTATO se rc≠0
#                                               (chatbot.sh:242): `eval` non
#                                               viene mai raggiunto, quindi la
#                                               forma eval-able è codice morto e
#                                               all'utente arriva la stringa
#                                               letterale su stderr — che è il
#                                               bug corretto il 2026-08-21.
# Non "uniformare" i due file: cambiare forma qui richiede prima cambiare il
# modo in cui chatbot.sh invoca questo script.

# Carica sistema e dominio dal profilo attivo
if [[ -z "${PROFILE_DIR:-}" ]]; then
    echo "[ERROR] resolve-logs: PROFILE_DIR non impostata" >&2
    exit 1
fi
source "$PROFILE_DIR/system.conf"
source "$(dirname "${BASH_SOURCE[0]}")/utils-nodes.sh"
# utils-logfiles.sh per resolve_system_log_dir(). Verificato che il sourcing non
# scriva NULLA su stdout: questo script comunica col chiamante emettendo
# assegnazioni che chatbot.sh passa a `eval` (resolve_session_logs), quindi un
# byte di troppo su stdout diventerebbe codice eseguito.
source "$(dirname "${BASH_SOURCE[0]}")/utils-logfiles.sh"

BASE_DIR="${1:-$LOG_BASE_DIR}"
ENV_NAME="${2:-}"
NODE_NUM="${3:-01}"
APP="${4:-$DEFAULT_APP}"

# ─── Validazione ─────────────────────────────────────────────────────────────
if [[ -z "$ENV_NAME" ]]; then
    echo "[ERROR] resolve-logs: ambiente non specificato" >&2
    exit 1
fi

ENV_CODE="${ENV_NODE_CODE[$ENV_NAME]:-}"
if [[ -z "$ENV_CODE" ]]; then
    echo "[ERROR] resolve-logs: ambiente sconosciuto: $ENV_NAME" >&2
    exit 1
fi

# ─── Risoluzione nodo ─────────────────────────────────────────────────────────
NODE_NUM=$(printf "%02d" "$NODE_NUM" 2>/dev/null || echo "$NODE_NUM")
# NODE_NAME_TEMPLATE è definito in system.conf (es: 'lx${ENV_CODE}jbliq${NODE_NUM}')
NODE_NAME=$(eval echo "${NODE_NAME_TEMPLATE}")
NODE_DIR="$BASE_DIR/$ENV_NAME/$NODE_NAME"

if [[ ! -d "$NODE_DIR" ]]; then
    # Fallback: scoperta dinamica tramite utils-nodes.sh (unica fonte di verità)
    NODE_DIR=$(list_env_node_dirs "$ENV_NAME" | head -1)
    if [[ -z "$NODE_DIR" ]]; then
        echo "[ERROR] resolve-logs: nodo non trovato in $BASE_DIR/$ENV_NAME" >&2
        exit 1
    fi
    NODE_NUM=$(node_num_from_dir "$NODE_DIR")
fi

# ─── Validazione *_LOG_BASE ────────────────────────────────────────────────────
# Nessun default implicito (ARCH-6): un profilo che non li definisce deve
# fallire qui in modo esplicito, non cercare un glob con basename vuoto (".log*",
# che matcherebbe qualunque cosa). Stesso pattern di guard di SERVER_LOG_FORMAT in
# dispatch.sh.
for _b in ACCESS_LOG_BASE SERVER_LOG_BASE GC_LOG_BASE; do
    if [[ -z "${!_b:-}" ]]; then
        echo "[ERROR] resolve-logs: $_b non impostato in system.conf" >&2
        exit 1
    fi
done

# ─── Scoperta delle directory dei log di sistema ─────────────────────────────
# ACTIVE_APP deve essere impostata PRIMA delle chiamate: resolve_log_glob, che
# resolve_system_log_dir usa internamente, legge ACTIVE_APP per il tie-break e
# per il vincolo require_app. Qui l'app della sessione si chiama $APP (parametro
# posizionale $4) — senza questa riga il vincolo sarebbe un NO-OP SILENZIOSO
# (la sua condizione richiede `-n "${ACTIVE_APP:-}"`) e su un nodo con più app la
# scelta cadrebbe sui criteri successivi: "ContactManager" vincerebbe
# alfabeticamente su "ClaimCenter", facendo leggere a ogni tool i log dell'app
# sbagliata con un path plausibile e dati coerenti. È il rischio principale di
# questo percorso, da cui il test dedicato in tests/test-logdisc-4.sh.
ACTIVE_APP="$APP"

# require_app=1 su tutte e tre: se il log esiste solo sotto un'altra app la
# variabile resta VUOTA e il tool che ne ha bisogno lo dice via
# skip_system_log_not_found (dispatch.sh) — mai aprire cross-app in silenzio
# (principio 6, politica unica del progetto).
ACCESS_LOG_DIR=$(resolve_system_log_dir "$NODE_DIR" "$ACCESS_LOG_BASE" 1) || ACCESS_LOG_DIR=""
SERVER_LOG_DIR=$(resolve_system_log_dir "$NODE_DIR" "$SERVER_LOG_BASE" 1) || SERVER_LOG_DIR=""
GC_LOG_DIR=$(resolve_system_log_dir "$NODE_DIR" "$GC_LOG_BASE" 1)         || GC_LOG_DIR=""

# ─── File di log ─────────────────────────────────────────────────────────────
resolve_log_file() {
    local base_path="$1"
    if   [[ -f "${base_path}" ]];    then echo "${base_path}"
    elif [[ -f "${base_path}.gz" ]]; then echo "${base_path}.gz"
    else echo ""
    fi
}

# I tre path del file CORRENTE, derivati dalle directory appena scoperte. Sono
# usati per validare la disponibilità (i guard per-tool in dispatch.sh) e per
# mostrarli in context_line — non per leggere: i tool passano da
# open_logs_for DIR BASE, che ricostruisce l'insieme dei file con select_log_files.
#
# Un path VUOTO non è un errore ed è la differenza principale introdotta da
# LOGDISC-4: prima questo script abortiva l'INTERA sessione se non trovava un
# access log, anche per query che non lo leggono (un nodo la cui app non espone
# HTTP rendeva il bot inutilizzabile del tutto, e un test e2e di search_all_logs
# è morto per questo). Ora la sessione si risolve se il NODO esiste, e il singolo
# tool dice "non disponibile" solo se ha bisogno di quel log — validazione
# per-tool invece che globale.
#
# Nota: *_LOG_DIR non vuota non implica *_LOG_PATH non vuoto. La directory è stata
# scelta perché conteneva un file del gruppo, ma quel file può essere una rotazione
# (.gz, BASENAME.DATE.log) senza che esista il corrente. I consumatori lo gestiscono
# già: open_current_log_for verifica `-f`, open_logs_for passa da select_log_files.
ACCESS_LOG_PATH=""
SERVER_LOG_PATH=""
GC_LOG_PATH=""
[[ -n "$ACCESS_LOG_DIR" ]] && ACCESS_LOG_PATH=$(resolve_log_file "$ACCESS_LOG_DIR/${ACCESS_LOG_BASE}.log")
[[ -n "$SERVER_LOG_DIR" ]] && SERVER_LOG_PATH=$(resolve_log_file "$SERVER_LOG_DIR/${SERVER_LOG_BASE}.log")
[[ -n "$GC_LOG_DIR"     ]] && GC_LOG_PATH=$(resolve_log_file "$GC_LOG_DIR/${GC_LOG_BASE}.log")

# ─── Directory log applicativi custom (opzionale, vuota se CUSTOM_LOG_SUBPATH è vuoto) ─
# "Custom" = cartella flat, formato non standard JBoss (server/gc/access):
# nel profilo liquido è la cartella dei log Guidewire, ma il contratto non
# presume alcun middleware specifico (CLAUDE.md, "Principi di progettazione").
CUSTOM_LOG_DIR=""
if [[ -n "${CUSTOM_LOG_SUBPATH:-}" ]]; then
    CUSTOM_LOG_DIR="$NODE_DIR/$(eval echo "$CUSTOM_LOG_SUBPATH")"
fi

# ─── Output ──────────────────────────────────────────────────────────────────
# Le tre *_LOG_DIR conservano nome e semantica ("la directory che contiene quel
# tipo di log"): cambia solo COME sono calcolate — scoperte invece che dedotte da
# APP_SUBPATH. È ciò che permette a dispatch.sh di restare invariato, con i suoi
# 3 helper (open_logs/open_server_logs/open_gc_logs) e 15 call site intatti.
# Possono essere vuote: vedi la nota sulla validazione per-tool sopra.
echo "ACCESS_LOG='${ACCESS_LOG_PATH}'"
echo "ACCESS_LOG_DIR='${ACCESS_LOG_DIR}'"
echo "ACCESS_LOG_BASE='${ACCESS_LOG_BASE}'"
echo "SERVER_LOG='${SERVER_LOG_PATH}'"
echo "SERVER_LOG_DIR='${SERVER_LOG_DIR}'"
echo "SERVER_LOG_BASE='${SERVER_LOG_BASE}'"
echo "GC_LOG='${GC_LOG_PATH:-}'"
echo "GC_LOG_DIR='${GC_LOG_DIR}'"
echo "GC_LOG_BASE='${GC_LOG_BASE}'"
echo "ACTIVE_NODE='${NODE_NUM}'"
echo "ACTIVE_ENV='${ENV_NAME}'"
echo "ACTIVE_APP='${APP}'"
echo "CUSTOM_LOG_DIR='${CUSTOM_LOG_DIR}'"
echo "LOG_SEARCH_ROOT='${NODE_DIR}'"
