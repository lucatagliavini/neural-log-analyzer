#!/bin/bash
#
# test-logname-display.sh — Intervento 4: _log_names_in_dir() delega a
# logfile_display_name(), il prefisso host è una coordinata di profilo.
#
# Prima della correzione (2026-08-18), _log_names_in_dir() reimplementava
# inline sia la derivazione del nome logico (sed incompleta: non gestiva
# NAME.YYYY-MM-DD.log, bug#3 — 70 righe duplicate per undertow_access_log su
# usnext) sia lo strip del prefisso host (sed incondizionata: avrebbe
# trasformato "foo-bar.log" in "bar" anche su un profilo senza prefisso
# configurato). Questo test copre entrambi i difetti direttamente su
# _log_names_in_dir(), oggi coperta solo indirettamente da test-log-discovery.sh.
#
# Copre anche la coerenza fra logfile_display_name() (il nome che l'utente
# vede in un elenco) e resolve_log_glob() (il file che l'utente ottiene
# digitando quel nome) — le due funzioni divergevano prima di questo
# intervento (principio 8 di CLAUDE.md: sed al PRIMO trattino qui,
# ${_hint##*-} greedy in resolve_log_glob).
#
# Uso: bash tests/test-logname-display.sh
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
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

export BOT_LOG_LEVEL="off"
AVAILABLE_APPS=("ClaimCenter")

source "$LIB/dispatch.sh"

_ROOT="$(mktemp -d)"
trap 'rm -rf "$_ROOT"' EXIT

# ─── Caso trappola 1: 19 rotazioni giornaliere → 1 solo nome ─────────────────
section "Rotazioni NAME.YYYY-MM-DD.log: 19 file, 1 solo nome logico"

_rotdir="$_ROOT/rotazioni"
mkdir -p "$_rotdir"
for i in $(seq 1 19); do
    echo "riga $i" > "$_rotdir/undertow_access_log.2026-08-$(printf '%02d' "$i").log"
done

_names_rot="$(_log_names_in_dir "$_rotdir")"
assert_eq "19 rotazioni collassano su 1 nome logico" \
    "1" "$(wc -l <<< "$_names_rot" | tr -d ' ')"
assert_eq "il nome è undertow_access_log, non uno con la data incorporata" \
    "undertow_access_log" "$_names_rot"

# ─── Caso trappola 2: prefisso host CONFIGURATO → strippato ─────────────────
section "coll1nssa-cc.log con LOG_NAME_HOST_PREFIX_RE impostato → 'cc'"

_prefdir="$_ROOT/con_prefisso"
mkdir -p "$_prefdir"
echo "riga" > "$_prefdir/coll1nssa-cc.log"

LOG_NAME_HOST_PREFIX_RE='coll1nssa-'
assert_eq "prefisso configurato: il nome mostrato è 'cc'" \
    "cc" "$(_log_names_in_dir "$_prefdir")"

# ─── Caso trappola 3: prefisso NON configurato → nessuno strip ──────────────
# La regressione che la sed incondizionata di prima introdurrebbe: senza
# LOG_NAME_HOST_PREFIX_RE, "foo-bar.log" deve restare "foo-bar" per intero,
# non perdere il segmento prima del trattino.
section "foo-bar.log SENZA prefisso configurato → 'foo-bar' (non troncato)"

_noprefdir="$_ROOT/senza_prefisso"
mkdir -p "$_noprefdir"
echo "riga" > "$_noprefdir/foo-bar.log"

LOG_NAME_HOST_PREFIX_RE=''
assert_eq "prefisso NON configurato: il nome resta 'foo-bar' per intero" \
    "foo-bar" "$(_log_names_in_dir "$_noprefdir")"

# ─── Coerenza: logfile_display_name() e resolve_log_glob() concordano ───────
# Se l'utente vede "cc" nell'elenco e digita "cerca X nel cc.log", il file che
# resolve_log_glob() apre deve essere lo STESSO da cui è stato derivato quel
# nome — altrimenti l'elenco mostra un nome che poi non porta al file giusto.
section "Coerenza: il nome mostrato porta, via resolve_log_glob, allo stesso file"

_cohdir="$_ROOT/coerenza/ClaimCenter/Guidewire"
mkdir -p "$_cohdir"
echo "riga" > "$_cohdir/coll1nssa-cc.log"

LOG_NAME_HOST_PREFIX_RE='coll1nssa-'
_displayed="$(_log_names_in_dir "$_cohdir")"
_resolved="$(resolve_log_glob "$_ROOT/coerenza" "*-${_displayed}.log" "$_displayed" 2>/dev/null)"
assert_eq "resolve_log_glob su '*-cc.log' risolve al file da cui 'cc' è stato derivato" \
    "$_cohdir/coll1nssa-cc.log" "$_resolved"

LOG_NAME_HOST_PREFIX_RE=''

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
