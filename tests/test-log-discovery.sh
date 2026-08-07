#!/bin/bash
#
# test-log-discovery.sh — LOGDISC-1: ricerca ricorsiva dei log sotto il nodo.
#
# Il contratto architetturale (deciso con l'utente, 2026-08-07): il profilo
# risolve fino alla DIRECTORY DEL NODO (LOG_SEARCH_ROOT); sotto, la struttura
# è ignota e va scoperta ricorsivamente — non ogni profilo avrà log applicativi
# custom, e un nuovo profilo potrebbe organizzare i log diversamente dal nodo in giù.
#
# Copre resolve_log_glob() (ricorsione + tie-break app corrente),
# resolve_named_log_path() e open_glob_logs() (dispatch.sh), e
# list_available_logs()/skip_named_log_not_found() (messaggi all'utente).
#
# Uso: bash tests/test-log-discovery.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"
        fail=$(( fail + 1 ))
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso: '%s'\n        avuto:  '%s'\n" \
            "$desc" "$expected" "$actual"; fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

export BOT_LOG_LEVEL="off"
AVAILABLE_APPS=("ClaimCenter" "ContactManager")

source "$LIB/dispatch.sh"

# ─── Fixture: replica il nodo reale con due app + trappole ────────────────────
# prod/ClaimCenter/{access, server, gc, rotazione}
# prod/ContactManager/access                        ← omonimo cross-app
# ClaimCenter/Guidewire/{cc, ccJBatch, rotazione}
# ContactManager/Guidewire/cc                        ← omonimo logico "cc"
# weird/deep/nested/custom_app.log                   ← profilo senza log applicativi custom
# archive.log/                                       ← trappola: dir che matcha *.log
_ROOT="$(mktemp -d)"
trap 'rm -rf "$_ROOT"' EXIT

mkdir -p "$_ROOT/prod/ClaimCenter" "$_ROOT/prod/ContactManager"
mkdir -p "$_ROOT/ClaimCenter/Guidewire" "$_ROOT/ContactManager/Guidewire"
mkdir -p "$_ROOT/weird/deep/nested"
mkdir -p "$_ROOT/archive.log"

echo "access CC" > "$_ROOT/prod/ClaimCenter/undertow_access_log.log"
echo "server CC" > "$_ROOT/prod/ClaimCenter/server.log"
echo "gc CC"     > "$_ROOT/prod/ClaimCenter/gc.log"
gzip -c <(echo "access CC rotazione") \
    > "$_ROOT/prod/ClaimCenter/undertow_access_log.log-2026-08-01-1785000000.gz"

echo "access CM" > "$_ROOT/prod/ContactManager/undertow_access_log.log"

echo "cc CC corrente" > "$_ROOT/ClaimCenter/Guidewire/prod1nsse-cc.log"
gzip -c <(echo "cc CC rotazione") \
    > "$_ROOT/ClaimCenter/Guidewire/prod1nsse-cc.log-2026-08-01-1785000000.gz"
echo "ccJBatch CC" > "$_ROOT/ClaimCenter/Guidewire/prod1nsse-ccJBatch.log"

echo "cc CM corrente" > "$_ROOT/ContactManager/Guidewire/prod1nssd-cc.log"

echo "custom log senza directory applicativa custom nota" > "$_ROOT/weird/deep/nested/custom_app.log"

# Trappola: una DIRECTORY che matcha "*.log" — non deve mai essere restituita.
touch "$_ROOT/archive.log/non_e_un_file.txt"

# ─── resolve_log_glob: scoperta ricorsiva + tie-break app corrente ────────────
section "resolve_log_glob: scoperta ricorsiva partendo dal nodo"

_found=$(ACTIVE_APP="ClaimCenter" resolve_log_glob "$_ROOT" "*access_log*.log")
assert_true "access.log trovato partendo dalla root del nodo (non dalla app dir)" \
    "$([[ "$_found" == "$_ROOT/prod/ClaimCenter/undertow_access_log.log" ]] && echo 1 || echo 0)"

_custom=$(ACTIVE_APP="ClaimCenter" resolve_log_glob "$_ROOT" "*custom_app.log")
assert_true "custom_app.log raggiungibile in una directory arbitraria e profonda" \
    "$([[ "$_custom" == "$_ROOT/weird/deep/nested/custom_app.log" ]] && echo 1 || echo 0)"

_trap=$(ACTIVE_APP="ClaimCenter" resolve_log_glob "$_ROOT" "archive.log")
assert_true "archive.log/ (directory) non viene mai restituita come match" \
    "$([[ -z "$_trap" ]] && echo 1 || echo 0)"

section "resolve_log_glob: omonimo cross-app (stesso basename, app diverse)"

_cc_claim=$(ACTIVE_APP="ClaimCenter" resolve_log_glob "$_ROOT" "*access_log*.log")
assert_true "con ACTIVE_APP=ClaimCenter, sceglie l'access log di ClaimCenter" \
    "$([[ "$_cc_claim" == *"/ClaimCenter/"* ]] && echo 1 || echo 0)"

_cc_contact=$(ACTIVE_APP="ContactManager" resolve_log_glob "$_ROOT" "*access_log*.log")
assert_true "con ACTIVE_APP=ContactManager, sceglie l'access log di ContactManager" \
    "$([[ "$_cc_contact" == *"/ContactManager/"* ]] && echo 1 || echo 0)"

section "resolve_log_glob: omonimo logico 'cc' su serverid diversi per app"

_cc1=$(ACTIVE_APP="ClaimCenter" resolve_log_glob "$_ROOT" "*cc*.log" "cc" 2>/dev/null)
assert_true "'cc' con ACTIVE_APP=ClaimCenter risolve deterministicamente sotto ClaimCenter" \
    "$([[ "$_cc1" == *"/ClaimCenter/"* ]] && echo 1 || echo 0)"

_cc2=$(ACTIVE_APP="ContactManager" resolve_log_glob "$_ROOT" "*cc*.log" "cc" 2>/dev/null)
assert_true "'cc' con ACTIVE_APP=ContactManager risolve deterministicamente sotto ContactManager" \
    "$([[ "$_cc2" == *"/ContactManager/"* ]] && echo 1 || echo 0)"

# ─── open_glob_logs: rotazioni raggruppate dalla dirname del file scelto ──────
section "open_glob_logs: rotazioni dalla dirname del file scelto, non dalla root"

_expr=$(ACTIVE_APP="ClaimCenter" open_glob_logs "$_ROOT" "*-cc.log")
_n_files=$(grep -oE "'[^']+\.log[^']*'" <<< "$_expr" | wc -l)
assert_true "'*-cc.log': trova corrente + rotazione (2 file), non l'omonimo ContactManager" \
    "$([[ "$_n_files" -eq 2 ]] && echo 1 || echo 0)"
assert_true "nessun file di ContactManager nell'espressione risolta" \
    "$(( 1 - $([[ "$_expr" == *"ContactManager"* ]] && echo 1 || echo 0) ))"

# ─── resolve_named_log_path con require_app: niente cross-app silenzioso ──────
section "resolve_named_log_path: require_app rifiuta un match solo sull'altra app"

_ccjbatch=$(ACTIVE_APP="ClaimCenter" resolve_named_log_path "$_ROOT" ccJBatch)
assert_true "ccJBatch (solo sotto ClaimCenter) risolto quando la sessione è ClaimCenter" \
    "$([[ "$_ccjbatch" == "$_ROOT/ClaimCenter/Guidewire/prod1nsse-ccJBatch.log" ]] && echo 1 || echo 0)"

_ccjbatch_wrong=$(ACTIVE_APP="ContactManager" resolve_named_log_path "$_ROOT" ccJBatch)
assert_true "ccJBatch (solo sotto ClaimCenter) NON risolto quando la sessione è ContactManager" \
    "$([[ -z "$_ccjbatch_wrong" ]] && echo 1 || echo 0)"

# ─── skip_named_log_not_found: messaggio "non trovato" + suggerimento app ─────
section "skip_named_log_not_found: distingue 'assente' da 'esiste sotto un'altra app'"

_msg_elsewhere=$(ACTIVE_APP="ContactManager" skip_named_log_not_found "$_ROOT" ccJBatch 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g')
assert_true "log esistente solo sotto ClaimCenter: il messaggio suggerisce ClaimCenter" \
    "$([[ "$_msg_elsewhere" == *"non trovato"* && "$_msg_elsewhere" == *"ClaimCenter"* ]] && echo 1 || echo 0)"

_msg_absent=$(ACTIVE_APP="ClaimCenter" skip_named_log_not_found "$_ROOT" nomeinesistentexyz 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g')
assert_true "log assente ovunque: messaggio generico, nessuna app suggerita" \
    "$([[ "$_msg_absent" == *"non trovato"* && "$_msg_absent" != *"esiste sotto"* ]] && echo 1 || echo 0)"

# ─── list_available_logs: nessun duplicato access/server/gc nella sezione nodo ─
section "list_available_logs: 'Log del nodo' esclude i basename di sistema"

ACCESS_LOG_DIR="$_ROOT/prod/ClaimCenter"
SERVER_LOG_DIR="$_ROOT/prod/ClaimCenter"
GC_LOG_DIR="$_ROOT/prod/ClaimCenter"
ACCESS_LOG="$_ROOT/prod/ClaimCenter/undertow_access_log.log"
SERVER_LOG="$_ROOT/prod/ClaimCenter/server.log"
GC_LOG="$_ROOT/prod/ClaimCenter/gc.log"
ACCESS_LOG_BASE="undertow_access_log"
SERVER_LOG_BASE="server"
GC_LOG_BASE="gc"
LOG_SEARCH_ROOT="$_ROOT"
C_LBL=""; C_BOLD=""; C_RESET=""; C_WARN=""

_list_out=$(list_available_logs 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
assert_true "'Log del nodo' non elenca undertow_access_log come nome applicativo" \
    "$(( 1 - $([[ "$_list_out" == *"undertow_access_log"* ]] && echo 1 || echo 0) ))"
assert_true "'Log del nodo' non elenca server come nome applicativo" \
    "$([[ "$_list_out" =~ Log\ del\ nodo.*cc ]] && echo 1 || echo 0)"
assert_true "'Log di sistema' segnala comunque access log come presente" \
    "$([[ "$_list_out" == *"access log"* ]] && echo 1 || echo 0)"
assert_true "l'elenco include i nomi di log applicativi custom scoperti ricorsivamente (cc)" \
    "$([[ "$_list_out" == *" cc "* || "$_list_out" == *" cc"$'\n'* || "$_list_out" == *"cc "* ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
