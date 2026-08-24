#!/bin/bash
#
# test-logfile-name-perf.sh — caratterizzazione di logfile_logical_name (SALPERF-1)
#
# È un test di CARATTERIZZAZIONE, non di regressione: deve passare sia PRIMA sia
# DOPO la riscrittura, perché il comportamento non deve cambiare — solo il costo.
#
# Perché esiste. `logfile_logical_name()` è il motore condiviso che raggruppa un file
# di log col suo nome logico, usato da select_log_files_grouped (cioè da TUTTI i tool)
# e da dispatch.sh. Misurato in produzione il 2026-08-24: **4,7 ms per chiamata**,
# perché la funzione invocava due `sed` — due sottoprocessi — e i chiamanti la
# invocavano in `$( )`, cioè con una subshell in più. Su un multi-nodo con 4600 file
# candidati sono **21,8 s** su una fase di selezione misurata 25 s.
#
# Le forme di nome file coperte sono quelle REALI: i casi qui sotto sono estratti dai
# 12704 nomi distinti presenti su produzione (liquido + usnext), incluso
# `${gw.cc.serverid}-messaging.log` — un placeholder di proprietà mai espanso, che è
# il genere di input che una riscrittura "ragionevole" romperebbe.
#
# Uso: bash tests/test-logfile-name-perf.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_eq() {
    local desc="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"
        printf "        atteso  : '%s'\n" "$expected"
        printf "        ottenuto: '%s'\n" "$got"
        fail=$(( fail + 1 ))
    fi
}
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "──────────────────────"; }

source "$ROOT_DIR/lib/utils-logfiles.sh" 2>/dev/null

# ─── Le forme reali, con l'esito atteso ───────────────────────────────────────
section "Nomi logici: le forme osservate in produzione"

# nome_file <TAB> nome_logico_atteso — golden master ridotto ai casi distinti per
# FORMA. I 12704 nomi reali si riducono a queste sette forme.
while IFS='|' read -r inp exp; do
    [[ -z "$inp" ]] && continue
    assert_eq "$inp → $exp" "$exp" "$(logfile_logical_name "$inp")"
done <<'EOF'
audit.log|audit
backupgc.log.0|backupgc
backupgc.log.1|backupgc
backupgc.log-2026-08-14-1786658401.gz|backupgc
undertow_access_log.2026-06-03.log|undertow_access_log
undertow_access_log.2026-08-22.log-2026-08-24-1787522401.gz|undertow_access_log
prod1nssd-cc.log|prod1nssd-cc
prod1nssd-cc.log-2026-08-21-1787263201.gz|prod1nssd-cc
prod1nssd-KPI_METADATI_TRACKING.log|prod1nssd-KPI_METADATI_TRACKING
${gw.cc.serverid}-messaging.log|${gw.cc.serverid}-messaging
/percorso/assoluto/prod2nssd-cm.log-2026-08-19-1787090401.gz|prod2nssd-cm
gc.log.4|gc
console.log-2026-08-24-1787548501.gz|console
EOF

# ─── Il percorso assoluto viene ridotto al basename ───────────────────────────
section "Invarianti che la riscrittura non deve rompere"

assert_eq "un path assoluto dà lo stesso nome logico del basename" \
    "$(logfile_logical_name "prod1nssd-cc.log")" \
    "$(logfile_logical_name "/a/b/c/prod1nssd-cc.log")"
assert_eq "il .gz non cambia il nome logico" \
    "$(logfile_logical_name "server.log-2026-08-24-1787522401")" \
    "$(logfile_logical_name "server.log-2026-08-24-1787522401.gz")"
# Rotazioni diverse dello STESSO log devono collassare sullo stesso nome logico:
# è la proprietà per cui la funzione esiste (bug reale del 2026-08-07, dove 19
# rotazioni giornaliere producevano 19 nomi distinti).
_a="$(logfile_logical_name "undertow_access_log.log")"
_b="$(logfile_logical_name "undertow_access_log.2026-06-03.log")"
_c="$(logfile_logical_name "undertow_access_log.log-2026-08-20-1787231401.gz")"
assert_eq "tre rotazioni dello stesso log collassano su un nome unico" \
    "$_a|$_a" "$_b|$_c"

# Un nome senza `.log` non deve essere mutilato: la funzione tocca solo i suffissi
# di rotazione noti.
assert_eq "un nome senza .log resta invariato" "qualcosa.txt" \
    "$(logfile_logical_name "qualcosa.txt")"
assert_eq "un nome vuoto non fa esplodere la funzione" "" \
    "$(logfile_logical_name "")"

# ─── Riepilogo ─────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" \
    "$pass" "$fail" "$(( pass + fail ))"
printf "═══════════════════════════════════════════════════\n"
echo ""

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
