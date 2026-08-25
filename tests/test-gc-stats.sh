#!/bin/bash
#
# test-gc-stats.sh — unit test per lib/tools/gc_stats.awk.
#
# Copertura prima assente: il tool era coperto solo da smoke-tools.sh (routing
# dell'intent, log reali, nessuna asserzione sui numeri prodotti).
#
# Nucleo di questo file: la correzione GCCORR-1/parte D dell'attribuzione
# regioni. `GC(N)` non è univoco — riparte da 0 al restart JVM e fra le
# rotazioni concatenate da open_gc_logs — quindi senza un guard di prossimità
# temporale (`_pend_ts[gid]`, cancellato dopo il consumo) un GC(N) riusato ore
# dopo erediterebbe le regioni di un vecchio evento con lo stesso id.
#
# Uso: bash tests/test-gc-stats.sh
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
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso: '%s'\n        avuto:  '%s'\n" \
            "$desc" "$expected" "$actual"
        fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

_UTILS="-f $LIB/utils-time.awk -f $LIB/utils-colors.awk"
_TOOL="$LIB/tools/gc_stats.awk"
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# _run GC_FILE → output completo, colori rimossi
_run() { gawk $_UTILS -f "$_TOOL" "$1" 2>/dev/null | _strip; }

# _old_avg GC_FILE → media regioni Old ("── Regioni G1 (media dopo GC) ──")
_old_avg() { _run "$1" | awk '/^  Old:/ { gsub(/[^0-9]/, "", $2); print $2+0 }'; }

# _events GC_FILE → totale eventi (riga "Totale eventi:")
_events() { _run "$1" | awk '/Totale eventi:/ { print $NF+0 }'; }

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

section "Caso base: un evento con regioni proprie"

cat > "$_FIX/gc_basic.log" <<'EOF'
[2026-08-25T10:00:10.100+0200][info][gc,heap] GC(3) Eden regions: 24->0(25)
[2026-08-25T10:00:10.110+0200][info][gc,heap] GC(3) Old regions: 50->200
[2026-08-25T10:00:10.200+0200][info][gc] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 128M->64M(256M) 45.123ms
EOF
assert_eq "1 evento riconosciuto" "1" "$(_events "$_FIX/gc_basic.log")"
assert_eq "regioni Old attribuite al proprio evento" "200" "$(_old_avg "$_FIX/gc_basic.log")"

section "Attribuzione cross-rotazione/restart (GCCORR-1, parte D)"

# GC(3) compare due volte: la prima con regioni proprie (Old=200), la seconda
# un'ora dopo — un restart JVM plausibile — SENZA righe regione davanti. In
# mezzo un GC(4) con regioni proprie (Old=10), a scanso di equivoci sull'id.
# Senza il guard _pend_ts, il terzo evento erediterebbe Old=200 dal primo:
# media (200+10+200)/3 = 137. Con il guard, il terzo evento non ha regioni
# proprie ed è escluso dalla media: (200+10)/2 = 105.
cat > "$_FIX/gc_cross.log" <<'EOF'
[2026-08-25T10:00:10.100+0200][info][gc,heap] GC(3) Eden regions: 24->0(25)
[2026-08-25T10:00:10.110+0200][info][gc,heap] GC(3) Old regions: 50->200
[2026-08-25T10:00:10.200+0200][info][gc] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 128M->64M(256M) 45.123ms
[2026-08-25T10:05:00.100+0200][info][gc,heap] GC(4) Eden regions: 8->0(20)
[2026-08-25T10:05:00.110+0200][info][gc,heap] GC(4) Old regions: 5->10
[2026-08-25T10:05:00.200+0200][info][gc] GC(4) Pause Young (Normal) (G1 Evacuation Pause) 90M->40M(256M) 12.000ms
[2026-08-25T11:00:00.200+0200][info][gc] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 200M->150M(256M) 30.500ms
EOF
assert_eq "3 eventi riconosciuti" "3" "$(_events "$_FIX/gc_cross.log")"
assert_eq "GC(3) riusato un'ora dopo NON eredita le vecchie regioni (media 105, non 137)" \
    "105" "$(_old_avg "$_FIX/gc_cross.log")"

section "Regioni riviste entro la stessa pausa (nessun falso rifiuto)"

# Le righe regione arrivano frazioni di secondo prima della pausa: il guard
# (≤2s) deve accettarle, non solo rifiutare quelle vecchie.
cat > "$_FIX/gc_fresh.log" <<'EOF'
[2026-08-25T10:00:10.900+0200][info][gc,heap] GC(9) Eden regions: 10->0(15)
[2026-08-25T10:00:10.910+0200][info][gc,heap] GC(9) Old regions: 30->60
[2026-08-25T10:00:11.200+0200][info][gc] GC(9) Pause Young (Normal) (G1 Evacuation Pause) 128M->64M(256M) 20.000ms
EOF
assert_eq "regioni a <1s dalla pausa: accettate" "60" "$(_old_avg "$_FIX/gc_fresh.log")"

section "Caso degenere: nessun evento GC"

: > "$_FIX/gc_empty.log"
assert_eq "log vuoto: messaggio esplicito" \
    "Nessun evento GC trovato." "$(_run "$_FIX/gc_empty.log")"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
