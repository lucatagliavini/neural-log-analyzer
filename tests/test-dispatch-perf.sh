#!/bin/bash
#
# test-dispatch-perf.sh — unit test per le metriche di selezione in
# lib/dispatch.sh (OBS-3).
#
# Copertura prima assente: open_current_log_for(), open_glob_logs() e la
# catena find di tail_named_log/grep_named_log (ora centralizzata in
# resolve_named_log_path()) non emettevano MAI selezione/file/byte su
# _PERF_SELECT_FILE — dispatch_tool() aggregava quel file per popolare le
# colonne 8-13 del query log (vedi log_query() in chatbot.sh), quindi queste
# tre vie restituivano sempre PERF_SELECT_MS=0 e PERF_BYTES=0 per query
# che leggevano un file reale: un fallimento silenzioso (perf-report.sh non
# segnala nulla, mostra solo dati muti).
#
# Il contratto verificato qui è quello INTERNO fra open_*()/resolve_*() e
# _PERF_SELECT_FILE, non l'intera pipeline chatbot.sh (già coperta a un
# livello più alto da test-search-all-logs.sh per search_all_logs.sh, che ha
# un canale diverso — BOT_PERF_FILE diretto).
#
# Uso: bash tests/test-dispatch-perf.sh

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

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

source "$LIB/dispatch.sh"

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# _sel_metrics FN ARGS... → "sel_ms nf nb" accumulati da una chiamata a FN,
# leggendo _PERF_SELECT_FILE come farebbe dispatch_tool() dopo open_logs_for.
_sel_metrics() {
    local fn="$1"; shift
    local out
    out=$(mktemp)
    _PERF_SELECT_FILE="$out" "$fn" "$@" > /dev/null
    local sel=0 nf=0 nb=0
    if [[ -s "$out" ]]; then
        read -r sel nf nb < <(awk '{s+=$1; f+=$2; b+=$3} END{print s+0, f+0, b+0}' "$out")
    fi
    rm -f "$out"
    echo "$sel $nf $nb"
}

# Ogni sezione ha la propria sottodirectory: resolve_log_glob (dietro
# open_glob_logs/resolve_named_log_path) ora cerca ricorsivamente, quindi una
# fixture condivisa fra sezioni farebbe leggere a una sezione i file creati
# per un'altra — isolamento necessario dopo LOGDISC-1, non solo per igiene.

# ─── open_current_log_for: bypassa select_log_files ma deve riportare volume ──
section "open_current_log_for (tail_log, TIME_EXPLICIT=0)"

mkdir -p "$_FIX/sec1"
echo "riga di log di prova" > "$_FIX/sec1/current.log"
read -r _sel _nf _nb <<< "$(_sel_metrics open_current_log_for "$_FIX/sec1" current)"
assert_true "file trovato: PERF_FILES=1" "$([[ "$_nf" -eq 1 ]] && echo 1 || echo 0)"
assert_true "byte riportati > 0" "$([[ "$_nb" -gt 0 ]] && echo 1 || echo 0)"

read -r _sel _nf _nb <<< "$(_sel_metrics open_current_log_for "$_FIX/sec1" assente)"
assert_true "file assente: PERF_FILES=0 (non un errore, un fatto)" "$([[ "$_nf" -eq 0 ]] && echo 1 || echo 0)"

# ─── open_glob_logs: escape hatch glob di tail_named_log/grep_named_log ───────
section "open_glob_logs (escape hatch glob)"

mkdir -p "$_FIX/sec2"
echo "riga cc" > "$_FIX/sec2/prod1-cc.log"
read -r _sel _nf _nb <<< "$(_sel_metrics open_glob_logs "$_FIX/sec2" '*-cc.log')"
assert_true "glob risolto: PERF_FILES>=1" "$([[ "$_nf" -ge 1 ]] && echo 1 || echo 0)"
assert_true "glob risolto: PERF_BYTES>0" "$([[ "$_nb" -gt 0 ]] && echo 1 || echo 0)"

read -r _sel _nf _nb <<< "$(_sel_metrics open_glob_logs "$_FIX/sec2" '*-nomatch.log')"
assert_true "glob senza match: nessuna riga PERF spuria (file=0)" "$([[ "$_nf" -eq 0 ]] && echo 1 || echo 0)"

# ─── resolve_named_log_path: sostituisce le due catene find duplicate ────────
section "resolve_named_log_path (tail_named_log/grep_named_log senza glob)"

mkdir -p "$_FIX/sec3/named"
echo "riga api" > "$_FIX/sec3/named/srv01-api.log"
read -r _sel _nf _nb <<< "$(_sel_metrics resolve_named_log_path "$_FIX/sec3/named" api)"
assert_true "match esatto *-<nome>.log: PERF_FILES=1" "$([[ "$_nf" -eq 1 ]] && echo 1 || echo 0)"
assert_true "match esatto *-<nome>.log: PERF_BYTES>0" "$([[ "$_nb" -gt 0 ]] && echo 1 || echo 0)"

_path=$(resolve_named_log_path "$_FIX/sec3/named" api)
assert_true "il path risolto è quello atteso" \
    "$([[ "$_path" == "$_FIX/sec3/named/srv01-api.log" ]] && echo 1 || echo 0)"

read -r _sel _nf _nb <<< "$(_sel_metrics resolve_named_log_path "$_FIX/sec3/named" assente)"
assert_true "nome non trovato: PERF_FILES=0, nessuna riga spuria" "$([[ "$_nf" -eq 0 ]] && echo 1 || echo 0)"

# ─── resolve_named_log_path: ricerca ricorsiva sotto una root con più livelli ──
# Il caso che LOGDISC-1 introduce: il file non è direttamente sotto la root
# passata, ma in una sottodirectory arbitraria (contratto "fino al nodo").
section "resolve_named_log_path (ricerca ricorsiva multi-livello)"

mkdir -p "$_FIX/sec4/App/Sub/Deep"
echo "riga profonda" > "$_FIX/sec4/App/Sub/Deep/prod2-deep.log"
_path=$(resolve_named_log_path "$_FIX/sec4" deep)
assert_true "trovato in sottodirectory annidata sotto la root" \
    "$([[ "$_path" == "$_FIX/sec4/App/Sub/Deep/prod2-deep.log" ]] && echo 1 || echo 0)"

# ─── SRCH-2: costo proporzionale al log scelto, non al nodo ──────────────────
# grep_named_log sul ramo di sistema (server/access/gc) apre solo il file
# corrente (open_current_log_for, già verificato sopra); search_all_logs
# scansiona invece ogni log scoperto sotto LOG_SEARCH_ROOT. Stesso pattern
# testuale, stesso nodo: il confronto deve mostrare che il primo costa quanto
# un file e il secondo quanto il nodo — altrimenti la promessa del piano
# SRCH-2 ("costo ≈ dimensione del log scelto, non del nodo") è solo prosa.
section "SRCH-2: grep_named_log (un file) vs search_all_logs (il nodo)"

_FIX9="$(mktemp -d)"
_node9="$_FIX9/prod/lxprjbliq04"
mkdir -p "$_node9/srvdir" "$_node9/ClaimCenter/Guidewire" "$_node9/ContactManager/Guidewire"
printf '%s\n' "riga 1 di server" "riga 2 di server searchHub qui" \
    > "$_node9/srvdir/server.log"
for i in 1 2 3 4 5; do
    printf '%s\n' "riga applicativa $i searchHub" "riga applicativa $i altro" \
        "riga applicativa $i ancora" "riga applicativa $i extra" \
        > "$_node9/ClaimCenter/Guidewire/app$i.log"
done
echo "riga cm searchHub" > "$_node9/ContactManager/Guidewire/cm.log"

read -r _sel9 _nf9 _nb9 <<< "$(_sel_metrics open_current_log_for "$_node9/srvdir" server)"
assert_true "grep_named_log (server.log): un solo file selezionato" \
    "$([[ "$_nf9" -eq 1 ]] && echo 1 || echo 0)"

export LOG_BASE_DIR="$_FIX9" DETECTED_NODE="04" ACTIVE_NODE="04" \
    LOG_SEARCH_ROOT="$_node9" SEARCH_PATTERN="searchHub"
_PERF_OUT9="$(mktemp)"
export BOT_PERF_FILE="$_PERF_OUT9"
bash "$ROOT_DIR/lib/tools/search_all_logs.sh" > /dev/null 2>&1
_perf9=$(cat "$_PERF_OUT9" 2>/dev/null)
unset BOT_PERF_FILE LOG_BASE_DIR DETECTED_NODE ACTIVE_NODE LOG_SEARCH_ROOT SEARCH_PATTERN
rm -f "$_PERF_OUT9"
eval "$_perf9" 2>/dev/null
_nf9_all="${PERF_FILES:-0}"
_nb9_all="${PERF_BYTES:-0}"

assert_true "search_all_logs: scansiona più file del solo server.log (il nodo, non un log)" \
    "$([[ "$_nf9_all" -gt "$_nf9" ]] && echo 1 || echo 0)"
assert_true "search_all_logs: byte scansionati > byte del solo server.log (costo sul nodo)" \
    "$([[ "$_nb9_all" -gt "$_nb9" ]] && echo 1 || echo 0)"

rm -rf "$_FIX9"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}%s${RESET}\n" "───────────────────────────────────────────"
if [[ "$fail" -eq 0 ]]; then
    printf "${GREEN}${BOLD}%d PASS${RESET}  ${DIM}0 FAIL${RESET}\n" "$pass"
else
    printf "${GREEN}%d PASS${RESET}  ${RED}${BOLD}%d FAIL${RESET}\n" "$pass" "$fail"
fi

exit "$fail"
