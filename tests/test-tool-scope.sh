#!/bin/bash
#
# test-tool-scope.sh — copertura di nlp/tools.conf:TOOL_SCOPE (SCOPE-1 passo 4).
#
# TOOL_SOURCES aveva già la stessa classe di rischio (una tabella tool→proprietà
# nel framework, letta dal guard di dispatch.sh) e la stessa protezione: se una
# voce manca o slitta di categoria, il misrouting è SILENZIOSO — la rete attiva
# un tool, il guard applica la regola sbagliata, e nessun errore lo segnala. Qui
# vale lo stesso per TOOL_SCOPE: un tool classificato "single" per errore torna
# a essere skippato senza nodo (regressione del passo 3); uno classificato
# "multi" per errore quando dovrebbe essere "native" (search_all_logs/list_logs)
# farebbe annidare il parallelismo — il rischio che il piano SCOPE-1 passo 4
# chiama "R7"/annidamento.
#
# Due livelli di verifica:
#   A. STATICO — la tabella stessa: completezza (una voce per tool), esclusività
#      per nome (single/native/none sui soli tool dichiarati dal piano).
#   B. COMPORTAMENTALE — l'asse aggr si vede solo nel rendering: un tool "nosum"
#      non deve MAI emettere la riga Σ, un tool "sum" la emette sempre quando gira
#      su più nodi. Non basta leggere la tabella: la riga Σ dipende da
#      _render_multinode_result (dispatch.sh), un secondo punto che potrebbe
#      divergere dalla tabella anche se la tabella stessa è corretta.
#
# Uso: bash tests/test-tool-scope.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$ROOT_DIR/profiles/liquido"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

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

# ─── A. Statico: sourcia SOLO nlp/tools.conf, come gap-report.sh/vocab-gap.sh ──
# Non serve dispatch.sh né chatbot.sh per verificare la tabella stessa: lo
# stesso pattern minimo dei due script già in produzione (PROFILE_DIR →
# nlp-paths.sh → nlp_resolve_paths → TOOLS_CONF_FILE).
export PROFILE_DIR
source "$ROOT_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || { echo "[ERROR] nlp_resolve_paths fallita" >&2; exit 1; }
source "$TOOLS_CONF_FILE"

section "TOOL_SCOPE: completezza — una voce per ogni tool di TOOL_NAMES"
_missing=""
for _t in "${TOOL_NAMES[@]}"; do
    [[ -z "${TOOL_SCOPE[$_t]:-}" ]] && _missing="$_missing $_t"
done
assert_eq "nessun tool senza voce in TOOL_SCOPE" "" "$_missing"

section "TOOL_SCOPE: nessuna voce orfana (chiave senza corrispondente in TOOL_NAMES)"
_orphan=""
for _k in "${!TOOL_SCOPE[@]}"; do
    _found=0
    for _t in "${TOOL_NAMES[@]}"; do [[ "$_t" == "$_k" ]] && { _found=1; break; }; done
    [[ "$_found" -eq 0 ]] && _orphan="$_orphan $_k"
done
assert_eq "nessuna chiave TOOL_SCOPE fuori da TOOL_NAMES" "" "$_orphan"

# Esclusività per nome: scope "single"/"native"/"none" solo sui tool che il
# piano SCOPE-1 passo 4 dichiara esplicitamente — qualsiasi altro tool con
# quello scope è una classificazione slittata, non una scelta.
_scope_of() { echo "${TOOL_SCOPE[$1]%% *}"; }

section "TOOL_SCOPE: single vale SOLO per tail_log/tail_named_log"
_single_found=""
for _t in "${TOOL_NAMES[@]}"; do
    [[ "$(_scope_of "$_t")" == "single" ]] && _single_found="$_single_found $_t"
done
assert_eq "insieme esatto dei tool single" " tail_log tail_named_log" "$_single_found"

section "TOOL_SCOPE: native vale SOLO per search_all_logs/list_logs"
_native_found=""
for _t in "${TOOL_NAMES[@]}"; do
    [[ "$(_scope_of "$_t")" == "native" ]] && _native_found="$_native_found $_t"
done
assert_eq "insieme esatto dei tool native" " search_all_logs list_logs" "$_native_found"

section "TOOL_SCOPE: none vale SOLO per show_help"
_none_found=""
for _t in "${TOOL_NAMES[@]}"; do
    [[ "$(_scope_of "$_t")" == "none" ]] && _none_found="$_none_found $_t"
done
assert_eq "insieme esatto dei tool none" " show_help" "$_none_found"

section "TOOL_SCOPE: ogni valore di scope è uno dei quattro ammessi"
_bad_scope=""
for _t in "${TOOL_NAMES[@]}"; do
    case "$(_scope_of "$_t")" in
        multi|native|single|none) ;;
        *) _bad_scope="$_bad_scope $_t=$(_scope_of "$_t")" ;;
    esac
done
assert_eq "nessuno scope fuori da multi/native/single/none" "" "$_bad_scope"

section "TOOL_SCOPE: ogni tool multi ha un aggr dichiarato (sum o nosum)"
_bad_aggr=""
for _t in "${TOOL_NAMES[@]}"; do
    [[ "$(_scope_of "$_t")" == "multi" ]] || continue
    case "${TOOL_SCOPE[$_t]#* }" in
        sum|nosum) ;;
        *) _bad_aggr="$_bad_aggr $_t" ;;
    esac
done
assert_eq "nessun tool multi con aggr assente o non riconosciuto" "" "$_bad_aggr"

# ─── B. Comportamentale: la riga Σ dipende dal rendering, non solo dalla tabella ─
#
# Fixture minima a 2 nodi (03/04): un access log per un tool "nosum"
# (slow_requests) e un server log per un tool "sum" (filter_errors, già
# esercitato altrove — qui serve come controllo positivo: se Σ non comparisse
# MAI, un test che verifica solo "nosum → niente Σ" passerebbe anche con
# _render_multinode_result rotto).
section "Comportamentale: nosum non emette Σ, sum la emette (verificato entrambi)"

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT
_TA=$(date +%d/%b/%Y)
_TS=$(date +%Y-%m-%d)
for _n in 03 04; do
    _d="$_FIX/prod/lxprjbliq${_n}/ClaimCenter"
    mkdir -p "$_d"
    # Latenza ben sopra la soglia di default (1000 ms) di slow_requests.
    {
        printf '10.0.0.1 [%s:07:00:00 +0200] "GET /a HTTP/1.1" 200 100 100 - UA\n'  "$_TA"
        printf '10.0.0.1 [%s:07:00:01 +0200] "GET /b HTTP/1.1" 200 100 4500 - UA\n' "$_TA"
    } > "$_d/undertow_access_log.log"
    printf '%s 10:00:00,000 ERROR boom-%s\n' "$_TS" "$_n" > "$_d/server.log"
done

_run() {
    QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" \
        --profile "$PROFILE_DIR" --base-dir "$_FIX" --env prod \
        --query "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

_out_nosum=$(_run "chiamate lente")
assert_eq "slow_requests (nosum) attivato dal classificatore" "1" \
    "$(grep -c '▸ slow_requests' <<< "$_out_nosum")"
assert_eq "slow_requests (nosum): footer misurati presente" "1" \
    "$(grep -c 'misurati 2/2 nodi' <<< "$_out_nosum")"
assert_eq "slow_requests (nosum): NESSUNA riga Σ" "0" \
    "$(grep -cE '^Σ' <<< "$_out_nosum")"

_out_sum=$(_run "errori nel server log")
assert_eq "filter_errors (sum) attivato dal classificatore" "1" \
    "$(grep -c '▸ filter_errors' <<< "$_out_sum")"
assert_eq "filter_errors (sum): riga Σ presente" "1" \
    "$(grep -cE '^Σ' <<< "$_out_sum")"

printf "\n${BOLD}Risultato:${RESET} ${GREEN}%d PASS${RESET}, " "$pass"
if [[ "$fail" -gt 0 ]]; then
    printf "${RED}${BOLD}%d FAIL${RESET}\n" "$fail"; exit 1
else
    printf "%d FAIL\n" "$fail"; exit 0
fi
