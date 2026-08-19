#!/bin/bash
#
# test-logline.sh — unit test per lib/utils-logline.awk (Intervento 1).
#
# logline_parse() è il gemello lato AWK di _logfiles_read_first_ts()
# (lib/utils-logfiles.sh): due liste di grammatiche di riga che DEVONO
# restare in parità, perché non si può condividere codice fra bash e AWK.
# Senza un test che le confronta sulla STESSA fixture, una deriva fra le due
# (nuovo formato aggiunto a una e non all'altra) è silenziosa — esattamente
# il difetto #2/#4 di rosy-noodling-owl.md, nato perché il lato AWK conosceva
# solo 2 formati mentre il lato bash ne conosceva già 5.
#
# Uso: bash tests/test-logline.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

source "$LIB/utils-logfiles.sh"

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

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Driver AWK: per ogni riga di input stampa "ok|ts|has_date|epoch|level".
# Un -f separato (non inline nella riga di comando): gawk non accetta testo di
# programma dopo -f, va unito alla stessa catena di moduli della produzione.
cat > "$_FIX/driver.awk" <<'EOF'
{
    ok = logline_parse()
    printf "%d|%s|%d|%d|%s\n", ok, _ll_ts, _ll_has_date, _ll_epoch, _ll_level
}
EOF

_parse() {
    printf '%s' "$1" | gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-logline.awk" -f "$_FIX/driver.awk"
}

# ─── Le 5 grammatiche datate, stesse fixture del gemello bash (TS-1) ─────────
section "logline_parse: le 5 grammatiche datate riconosciute (parità con TS-1)"

_expect_ts=$(date -d "2026-08-17 10:00:00" +%s)

assert_eq "access Undertow: riconosciuta, has_date=1" \
    "1|2026-08-17 10:00:00|1|$_expect_ts" \
    "$(_parse '172.30.85.133 [17/Aug/2026:10:00:00 +0200] "GET / HTTP/1.1" 200 1 0 - -' | cut -d'|' -f1-4)"

assert_eq "gc log: riconosciuta, has_date=1" \
    "1|2026-08-17 10:00:00|1|$_expect_ts" \
    "$(_parse '[2026-08-17T10:00:00.527+0200][1486515.012s][info][gc,start] GC(1) Pause' | cut -d'|' -f1-4)"

assert_eq "server log JBoss: riconosciuta, livello INFO" \
    "1|2026-08-17 10:00:00|1|$_expect_ts|INFO" \
    "$(_parse '2026-08-17 10:00:00,303 INFO  [classe] messaggio')"

assert_eq "ISO custom (Guidewire, liquido): riconosciuta, livello INFO" \
    "1|2026-08-17 10:00:00|1|$_expect_ts|INFO" \
    "$(_parse '[thread] USER 2026-08-17T10:00:00,443 INFO messaggio')"

assert_eq "data europea (Pass.log, usnext): riconosciuta, livello INFO" \
    "1|2026-08-17 10:00:00|1|$_expect_ts|INFO" \
    "$(_parse '17-08-2026 10:00:00.071 INFO  HttpRestClient chiamata')"

# ─── La 6a grammatica: solo-ora, con byte ANSI reali ─────────────────────────
section "logline_parse: console.log solo-ora, con byte ANSI reali (bug#4)"

# ESC reale via printf %b, non il letterale "\033[0m": la fixture deve
# riprodurre esattamente ciò che console.log scrive, altrimenti il test non
# proverebbe lo strip ANSI che la correzione introduce.
_console_line="$(printf '\033[0m10:03:37,273 INFO  [logger] (thread) messaggio')"
assert_eq "console.log con reset ANSI: riconosciuta come solo-ora, epoch=-1" \
    "1|10:03:37|0|-1|INFO" \
    "$(_parse "$_console_line")"

# ─── Negativi: gli stessi due del gemello bash ───────────────────────────────
section "logline_parse: righe non riconosciute → 0 con valori neutri (principio 5)"

assert_eq "data DD-MM-YYYY a metà riga (dato di business, non timestamp) → non riconosciuta" \
    "0" \
    "$(_parse 'INFO polizza con scadenza 31-12-2027 rinnovata' | cut -d'|' -f1)"

_neg=$(_parse 'nessun timestamp qui')
assert_eq "riga senza timestamp: ok=0" "0" "$(cut -d'|' -f1 <<< "$_neg")"
assert_eq "riga senza timestamp: _ll_ts vuoto" "" "$(cut -d'|' -f2 <<< "$_neg")"
assert_eq "riga senza timestamp: _ll_epoch=-1" "-1" "$(cut -d'|' -f4 <<< "$_neg")"

# ─── Parità bash ↔ AWK sulla STESSA fixture (l'invariante che protegge da una
#     deriva futura fra i due gemelli) ────────────────────────────────────────
section "Parità _logfiles_read_first_ts() (bash) ↔ logline_parse() (awk)"

printf '172.30.85.133 [17/Aug/2026:10:00:00 +0200] "GET / HTTP/1.1" 200 1 0 - -\n' > "$_FIX/access.log"
printf '[2026-08-17T10:00:00.527+0200][1486515.012s][info][gc,start] GC(1) Pause\n'  > "$_FIX/gc.log"
printf '2026-08-17 10:00:00,303 INFO  [classe] messaggio\n'                          > "$_FIX/server.log"
printf '[thread] USER 2026-08-17T10:00:00,443 INFO messaggio\n'                      > "$_FIX/custom_iso.log"
printf '17-08-2026 10:00:00.071 INFO  HttpRestClient chiamata\n'                     > "$_FIX/custom_eu.log"

for _f in access gc server custom_iso custom_eu; do
    _bash_epoch="$(_logfiles_read_first_ts "$_FIX/$_f.log")"
    _awk_epoch="$(_parse "$(cat "$_FIX/$_f.log")" | cut -d'|' -f4)"
    assert_eq "$_f.log: bash e awk concordano sull'epoch" "$_bash_epoch" "$_awk_epoch"
done

# Stessi due negativi, sui due lati: se uno riconoscesse e l'altro no, la
# selezione file (bash) e l'estrazione riga (awk) divergerebbero su quale file
# è "dentro" la finestra temporale.
printf 'INFO polizza con scadenza 31-12-2027 rinnovata\n' > "$_FIX/business.log"
_bash_biz="$(_logfiles_read_first_ts "$_FIX/business.log")"
_awk_biz="$(_parse "$(cat "$_FIX/business.log")" | cut -d'|' -f1)"
assert_eq "business.log: bash dice 0 (non riconosciuto)" "0" "$_bash_biz"
assert_eq "business.log: awk dice ok=0 (non riconosciuto) — stesso esito" "0" "$_awk_biz"

printf 'nessun timestamp qui\n' > "$_FIX/ignoto.log"
_bash_ign="$(_logfiles_read_first_ts "$_FIX/ignoto.log")"
_awk_ign="$(_parse "$(cat "$_FIX/ignoto.log")" | cut -d'|' -f1)"
assert_eq "ignoto.log: bash e awk concordano (entrambi non riconoscono)" "1" \
    "$([[ "$_bash_ign" == "0" && "$_awk_ign" == "0" ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
