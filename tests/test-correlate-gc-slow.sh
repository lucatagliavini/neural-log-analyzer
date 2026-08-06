#!/bin/bash
#
# test-correlate-gc-slow.sh — unit test per lib/tools/correlate_gc_slow.awk.
#
# Copertura prima assente: il tool era coperto solo da smoke-tools.sh, che
# richiede log reali sul server e verifica solo "non è andato in errore".
#
# Copre la logica di correlazione (una richiesta lenta è correlata se cade
# entro ±gc_margin_s da una pausa GC) sui casi di confine, e l'equivalenza
# fra l'indice per secondo (`gc_at`, 2026-08-06) e la scansione lineare che
# sostituisce: l'ottimizzazione è O(1) invece di O(pause_GC) per richiesta
# lenta, ma un errore nella correlazione cambierebbe il VERDETTO del tool
# ("GC è probabile causa" vs "GC non è la causa"), non solo i tempi.
#
# Uso: bash tests/test-correlate-gc-slow.sh
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

_UTILS="-f $LIB/utils-time.awk -f $LIB/utils-colors.awk -f $LIB/utils-jboss.awk -f $LIB/utils-dedup.awk"
_TOOL="$LIB/tools/correlate_gc_slow.awk"
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# _run GC_FILE ACCESS_FILE THRESHOLD → "lente/totali correlate"
_run() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$3" "$1" "$2" 2>/dev/null | _strip | \
        awk '/Richieste lente/ { split($NF, a, "/"); slow=a[1]; tot=a[2] }
             /Di cui correlate/ { corr=$(NF-1) }
             END { printf "%s/%s %s", slow+0, tot+0, corr+0 }'
}

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# ─── Fixture: pausa GC alle 10:00:10, richieste a distanze diverse ────────────
# gc_margin_s = 2 → correlate solo quelle entro ±2s (10:00:08 … 10:00:12).
cat > "$_FIX/gc.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF

# 7 richieste lente (1500ms), a offset -3, -2, -1, 0, +1, +2, +3 secondi
cat > "$_FIX/access.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:07 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:08 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:09 +0200] "GET /c HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /d HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:11 +0200] "GET /e HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:12 +0200] "GET /f HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:13 +0200] "GET /g HTTP/1.1" 200 100 1500 - UA
EOF

section "Finestra di correlazione (±2s dalla pausa GC)"

# 7 lente su 7 totali; correlate solo le 5 dentro ±2s (08,09,10,11,12)
assert_eq "7 richieste lente, 5 correlate entro ±2s" \
    "7/7 5" "$(_run "$_FIX/gc.log" "$_FIX/access.log" 500)"

section "Soglia di lentezza (threshold_ms)"

# Soglia sopra i 1500ms: nessuna richiesta è lenta, nessuna correlazione
assert_eq "soglia 2000ms: nessuna richiesta lenta" \
    "0/7 0" "$(_run "$_FIX/gc.log" "$_FIX/access.log" 2000)"

# Richieste con tempi misti: solo quelle sopra soglia contano
cat > "$_FIX/access_mixed.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /slow HTTP/1.1" 200 100 3000 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /fast HTTP/1.1" 200 100 50 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /mid HTTP/1.1" 200 100 800 - UA
EOF
assert_eq "soglia 500ms: 2 lente su 3, entrambe correlate" \
    "2/3 2" "$(_run "$_FIX/gc.log" "$_FIX/access_mixed.log" 500)"
assert_eq "soglia 1000ms: 1 lenta su 3, correlata" \
    "1/3 1" "$(_run "$_FIX/gc.log" "$_FIX/access_mixed.log" 1000)"

section "Nessuna pausa GC / nessuna correlazione"

: > "$_FIX/gc_empty.log"
assert_eq "gc.log vuoto: richieste lente contate, zero correlate" \
    "7/7 0" "$(_run "$_FIX/gc_empty.log" "$_FIX/access.log" 500)"

# Pausa GC lontana nel tempo (un'ora dopo): nessuna correlazione
cat > "$_FIX/gc_far.log" <<'EOF'
[2026-08-06T11:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
assert_eq "pausa GC un'ora dopo: nessuna correlazione" \
    "7/7 0" "$(_run "$_FIX/gc_far.log" "$_FIX/access.log" 500)"

section "Pause GC multiple (indice per secondo, 2026-08-06)"

# Due pause distinte: ognuna correla le proprie richieste vicine.
cat > "$_FIX/gc_multi.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:00:30.000+0200] GC(2) Pause Full (System.gc()) 400M->90M(512M) 890.456ms
EOF
cat > "$_FIX/access_multi.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:20 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:30 +0200] "GET /c HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:31 +0200] "GET /d HTTP/1.1" 200 100 1500 - UA
EOF
# a→pausa1, c e d→pausa2, b (10:00:20) è a 10s da entrambe: non correlata
assert_eq "2 pause: 3 correlate su 4 lente (quella a metà no)" \
    "4/4 3" "$(_run "$_FIX/gc_multi.log" "$_FIX/access_multi.log" 500)"

# Due pause NELLO STESSO secondo: l'indice tiene l'ultima, ma la domanda
# "esiste una pausa vicina?" resta corretta — il conteggio non cambia.
cat > "$_FIX/gc_same_sec.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:00:10.000+0200] GC(2) Pause Young (Normal) 130M->50M(512M) 55.456ms
EOF
assert_eq "2 pause nello stesso secondo: correlazione invariata" \
    "7/7 5" "$(_run "$_FIX/gc_same_sec.log" "$_FIX/access.log" 500)"

section "Verdetto finale (percentuale di correlazione)"

_verdict() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$3" "$1" "$2" 2>/dev/null | _strip | \
        grep -oE "GC (E' PROBABILE CAUSA|CONTRIBUISCE|NON e' la causa)" | head -1
}
# 5/7 = 71% ≥ 30% → probabile causa
assert_eq "71% correlato: 'GC E' PROBABILE CAUSA'" \
    "GC E' PROBABILE CAUSA" "$(_verdict "$_FIX/gc.log" "$_FIX/access.log" 500)"
# 0% → non è la causa
assert_eq "0% correlato: 'GC NON e' la causa'" \
    "GC NON e' la causa" "$(_verdict "$_FIX/gc_empty.log" "$_FIX/access.log" 500)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
