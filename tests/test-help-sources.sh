#!/bin/bash
#
# test-help-sources.sh — HELP-1: la sorgente di log di un tool è dichiarata in un
# punto solo (TOOL_SOURCES, nlp/tools.conf) e l'help ne è una conseguenza derivata,
# non più una descrizione parallela scritta a mano (TOOL_CATEGORY, rimossa).
#
# Non è più un test di COERENZA fra due tabelle — quella divergenza non può più
# esistere, perché una delle due tabelle non c'è. È il test della DERIVAZIONE, che
# ora è il solo meccanismo: completezza di TOOL_SOURCES, chiusura delle etichette che
# la traducono in prosa, e rendering corretto di print_help per entrambi i profili.
#
# Uso: bash tests/test-help-sources.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

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

assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"; fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

export BOT_LOG_LEVEL="off"

# Carica il framework + un profilo nella shell corrente: ogni `declare -A NAME=(...)`
# in domain.conf ridefinisce l'array per intero, quindi caricare due profili in
# sequenza nella stessa shell non lascia residui del precedente.
#
# NON una funzione: `source` dentro una funzione bash esegue il contenuto sourciato
# nello scope della funzione stessa (source non apre un proprio scope), quindi
# `declare -A TOOL_SOURCES=(...)` in tools.conf diventerebbe locale a quella
# funzione e sparirebbe non appena ritorna — esattamente il comportamento di
# produzione (chatbot.sh sourcia allo stesso modo a top-level, mai da una funzione).

source "$LIB/dispatch.sh"

PROFILE_DIR="$(cd "$ROOT_DIR/profiles/liquido" && pwd)"
export PROFILE_DIR
source "$LIB/nlp-paths.sh"
nlp_resolve_paths
source "$TOOLS_CONF_FILE"
source "$ROOT_DIR/profiles/liquido/domain.conf"

# ─── Completezza: ogni tool dichiara una sorgente ────────────────────────────
section "Completezza: TOOL_SOURCES copre tutti i tool"

_missing=0
for _t in "${TOOL_NAMES[@]}"; do
    [[ -z "${TOOL_SOURCES[$_t]:-}" ]] && _missing=$(( _missing + 1 ))
done
assert_eq "ogni voce di TOOL_NAMES ha una voce in TOOL_SOURCES" "0" "$_missing"

# ─── Chiusura: ogni kind citato ha un'etichetta ──────────────────────────────
section "Chiusura: ogni kind di TOOL_SOURCES ha un'etichetta (liquido)"

_unlabeled=0
for _t in "${TOOL_NAMES[@]}"; do
    _spec="${TOOL_SOURCES[$_t]:-}"
    for _group in $_spec; do
        _alts="$_group"
        [[ "$_group" == *"|"* ]] && _alts="${_group//|/ }"
        for _kind in $_alts; do
            case "$_kind" in
                all)
                    [[ -z "${ACTIVITY_CATEGORY[$_t]:-}" ]] && _unlabeled=$(( _unlabeled + 1 ))
                    ;;
                none) ;;
                *)
                    [[ -z "${SOURCE_CATEGORY[$_kind]:-}" ]] && _unlabeled=$(( _unlabeled + 1 ))
                    [[ -z "${SOURCE_LABEL[$_kind]:-}" ]] && _unlabeled=$(( _unlabeled + 1 ))
                    ;;
            esac
        done
    done
done
assert_eq "ogni kind concreto/all ha SOURCE_CATEGORY+SOURCE_LABEL o ACTIVITY_CATEGORY" "0" "$_unlabeled"

# ─── La trappola dello scarto silenzioso ─────────────────────────────────────
section "Nessuna categoria derivata sparisce per un carattere diverso da HELP_CATEGORIES"

_orphan=0
for _t in "${TOOL_NAMES[@]}"; do
    [[ -z "${TOOL_DESC[$_t]:-}" ]] && continue
    _cat="$(tool_help_category "$_t")"
    [[ -z "$_cat" ]] && continue   # show_help: nessuna categoria per contratto
    _found=0
    for _hc in "${HELP_CATEGORIES[@]}"; do
        [[ "$_hc" == "$_cat" ]] && { _found=1; break; }
    done
    [[ "$_found" -eq 0 ]] && { _orphan=$(( _orphan + 1 )); echo "    categoria orfana per '$_t': '$_cat'" >&2; }
done
assert_eq "ogni categoria derivata compare in HELP_CATEGORIES" "0" "$_orphan"

# ─── Rendering: un tool, una riga, la categoria giusta ───────────────────────
section "Rendering (liquido): ogni tool con descrizione compare esattamente una volta"

_HELP_OUT="$(print_help | sed 's/\x1b\[[0-9;]*m//g')"

_dup=0
for _t in "${TOOL_NAMES[@]}"; do
    _desc="${TOOL_DESC[$_t]:-}"
    [[ -z "$_desc" ]] && continue
    [[ -z "$(tool_help_category "$_t")" ]] && continue   # show_help: kind "none", niente da mostrare
    _n=$(grep -Fc -- "$_desc" <<< "$_HELP_OUT")
    [[ "$_n" -ne 1 ]] && { _dup=$(( _dup + 1 )); echo "    '$_t' compare $_n volte" >&2; }
done
assert_eq "nessun tool ripetuto o assente" "0" "$_dup"

assert_true "show_help non compare nel proprio help" \
    "$([[ -z "$(grep -F -- "${TOOL_DESC[show_help]}" <<< "$_HELP_OUT")" ]] && echo 1 || echo 0)"

_svc_line="$(awk "/${TOOL_DESC[service_times]//\//\\/}/{print; exit}" <<< "$_HELP_OUT")"
assert_true "service_times NON è più annotato come server log (bug storico corretto)" \
    "$([[ "$_svc_line" != *"· server"* ]] && echo 1 || echo 0)"

_svc_section="$(awk -v d="${TOOL_DESC[service_times]}" -v cats="$(printf '%s\n' "${HELP_CATEGORIES[@]}")" '
    BEGIN { n = split(cats, arr, "\n"); for (i = 1; i <= n; i++) is_cat["  " arr[i]] = 1 }
    ($0 in is_cat) { cat = $0 }
    index($0, d) { print cat; exit }
' <<< "$_HELP_OUT")"
assert_eq "service_times è raggruppato sotto 'Log HTTP (access log)'" \
    "  Log HTTP (access log)" "$_svc_section"

assert_true "tail_log è annotato con entrambe le alternative (access o server)" \
    "$(grep -qF -- "· access o server" <<< "$_HELP_OUT" && echo 1 || echo 0)"

assert_true "correlate_gc_slow è annotato con entrambe le sorgenti richieste (gc + access)" \
    "$(grep -qF -- "· gc + access" <<< "$_HELP_OUT" && echo 1 || echo 0)"

assert_true "search_all_logs resta sotto 'Ricerca cross-log'" \
    "$(grep -qF -- "Ricerca cross-log" <<< "$_HELP_OUT" && echo 1 || echo 0)"
assert_true "list_logs resta sotto 'Esplora log del nodo'" \
    "$(grep -qF -- "Esplora log del nodo" <<< "$_HELP_OUT" && echo 1 || echo 0)"

# ─── Regressione: print_help sotto `set -e` (bug prod 2026-08-19) ────────────
# Questo file gira con `set -uo pipefail`, SENZA `-e` (necessario per lo scoping,
# vedi sopra) — ma chatbot.sh gira con `set -euo pipefail`. tool_help_category()
# aveva un `return` nudo nel ramo `none)`: senza valore esplicito, `return` eredita
# lo status dell'ultimo comando eseguito, cioè il test `[[ "$first" == *"|"* ]]`
# — falso per "none", quindi status 1. `tool_cat="$(tool_help_category ...)"` con
# quello status abortiva lo script sotto `set -e` non appena il loop arrivava a
# show_help (kind "none"), troncando l'help a metà con exit 1 — invisibile a
# questo file perché non ha `-e`, visibile solo eseguendo lo scenario reale in un
# subshell dedicato con `-e` attivo.
section "Regressione: print_help completa sotto set -e (come chatbot.sh)"

_set_e_out="$(bash -c '
    set -euo pipefail
    source "'"$LIB"'/dispatch.sh"
    PROFILE_DIR="'"$ROOT_DIR"'/profiles/liquido"
    export PROFILE_DIR
    source "'"$LIB"'/nlp-paths.sh"
    nlp_resolve_paths
    source "$TOOLS_CONF_FILE"
    source "$PROFILE_DIR/domain.conf"
    print_help
' 2>&1)"
_set_e_status=$?
assert_eq "print_help esce con status 0 sotto set -e" "0" "$_set_e_status"
assert_true "print_help sotto set -e arriva a 'Esplora log del nodo' (non tronca a show_help)" \
    "$(grep -qF -- "Esplora log del nodo" <<< "$_set_e_out" && echo 1 || echo 0)"

# ─── Secondo profilo: stessa partizione, etichette diverse ───────────────────
section "usnext: stessa partizione (framework), etichette del cliente (profilo)"

PROFILE_DIR="$(cd "$ROOT_DIR/profiles/usnext" && pwd)"
export PROFILE_DIR
source "$LIB/nlp-paths.sh"
nlp_resolve_paths
source "$TOOLS_CONF_FILE"
source "$ROOT_DIR/profiles/usnext/domain.conf"
_HELP_OUT_USNEXT="$(print_help | sed 's/\x1b\[[0-9;]*m//g')"

_dup=0
for _t in "${TOOL_NAMES[@]}"; do
    _desc="${TOOL_DESC[$_t]:-}"
    [[ -z "$_desc" ]] && continue
    [[ -z "$(tool_help_category "$_t")" ]] && continue   # show_help: kind "none", niente da mostrare
    _n=$(grep -Fc -- "$_desc" <<< "$_HELP_OUT_USNEXT")
    [[ "$_n" -ne 1 ]] && _dup=$(( _dup + 1 ))
done
assert_eq "usnext: nessun tool ripetuto o assente" "0" "$_dup"

assert_true "usnext: named-log category nomina i log del cliente (Pass.log)" \
    "$(grep -qF -- "Pass.log" <<< "$_HELP_OUT_USNEXT" && echo 1 || echo 0)"
assert_true "usnext: tail_log annotato come in liquido (la partizione è condivisa)" \
    "$(grep -qF -- "· access o server" <<< "$_HELP_OUT_USNEXT" && echo 1 || echo 0)"

# ─── Coerenza con il codice: nessuna chiamata diretta residua ────────────────
section "Coerenza col codice: il case di dispatch non chiama require_system_log a mano"

_case_body="$(awk '/^_dispatch_tool_run\(\)/,/^}/' "$LIB/dispatch.sh")"
_direct=$(grep -c '^\s*require_system_log ' <<< "$_case_body")
assert_eq "zero chiamate dirette a require_system_log nel case (solo require_tool_sources)" \
    "0" "$_direct"

# Tool a kind concreto (non named/all/none): count_status, distribute_status,
# slow_requests, traffic_volume, filter_errors, service_times, gc_stats,
# correlate_gc_slow, tail_log, filter_ip, filter_app_errors — 11 su 16.
_concrete=0
for _t in "${TOOL_NAMES[@]}"; do
    case "${TOOL_SOURCES[$_t]%%[ |]*}" in
        named|all|none) ;;
        *) _concrete=$(( _concrete + 1 )) ;;
    esac
done
_wrapper_calls=$(grep -c 'require_tool_sources ' <<< "$_case_body")
assert_eq "una chiamata a require_tool_sources per ciascun tool a kind concreto" \
    "$_concrete" "$_wrapper_calls"

# ─── Riepilogo ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
