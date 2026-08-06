#!/bin/bash
#
# test-slow-requests.sh — unit test per lib/tools/slow_requests.awk.
#
# Copertura prima assente: il tool era coperto solo da smoke-tools.sh, che
# richiede log reali sul server e verifica solo "non è andato in errore".
#
# Copre in particolare l'INTERAZIONE fra i due filtri (soglia sul tempo di
# risposta e finestra temporale), il cui ordine è stato invertito il
# 2026-08-06 per evitare mktime() sul 92% delle righe: un errore lì
# escluderebbe richieste lente legittime o includerebbe righe fuori finestra,
# in entrambi i casi senza alcun segnale d'errore.
#
# Uso: bash tests/test-slow-requests.sh
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
_TOOL="$LIB/tools/slow_requests.awk"
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# _count FILE THRESHOLD [TF] [TT] → numero di richieste lente riportate
_count() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$2" \
        -v time_from="${3:-}" -v time_to="${4:-}" "$1" 2>/dev/null | _strip | \
        awk '/Totale richieste lente/ { for (i=1;i<=NF;i++) if ($i+0 > 0 && $i !~ /ms/) { print $i+0; exit } }
             /Nessuna richiesta lenta/ { print 0; exit }'
}
# _urls FILE THRESHOLD [TF] [TT] → URL nelle righe della TABELLA, ordinate.
# Filtra sulle sole righe dati (che iniziano con lo status a 3 cifre): la
# stessa URL compare anche in "Risposta più lenta", e conteggiarla due volte
# renderebbe l'assert opaco.
_urls() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$2" \
        -v time_from="${3:-}" -v time_to="${4:-}" "$1" 2>/dev/null | _strip | \
        grep -E '^\s*[0-9]{3}\s' | grep -oE '/[a-z0-9?=-]+' | sort | tr '\n' ' ' | sed 's/ $//'
}

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Righe con tempi e orari diversi. Formato Undertow:
#   IP [DD/Mon/YYYY:HH:MM:SS +TZ] "METHOD URL PROTO" STATUS BYTES TIME_MS CHAIN UA
cat > "$_FIX/a.log" <<'EOF'
10.0.0.1 [06/Aug/2026:09:00:00 +0200] "GET /mattina-lenta HTTP/1.1" 200 100 5000 - UA
10.0.0.1 [06/Aug/2026:12:30:00 +0200] "GET /finestra-lenta HTTP/1.1" 200 100 3000 - UA
10.0.0.1 [06/Aug/2026:12:31:00 +0200] "GET /finestra-veloce HTTP/1.1" 200 100 50 - UA
10.0.0.1 [06/Aug/2026:12:32:00 +0200] "POST /finestra-media HTTP/1.1" 500 100 1500 - UA
10.0.0.1 [06/Aug/2026:18:00:00 +0200] "GET /sera-lenta HTTP/1.1" 500 100 9000 - UA
EOF

section "Soglia sul tempo di risposta (senza finestra temporale)"

assert_eq "soglia 1000ms: 4 righe sopra soglia su 5" "4" "$(_count "$_FIX/a.log" 1000)"
assert_eq "soglia 4000ms: solo le 2 più lente (5000, 9000)" "2" "$(_count "$_FIX/a.log" 4000)"
assert_eq "soglia 10000ms: nessuna" "0" "$(_count "$_FIX/a.log" 10000)"
assert_eq "soglia 1ms: tutte e 5" "5" "$(_count "$_FIX/a.log" 1)"

section "Interazione soglia × finestra temporale (ordine filtri invertito 2026-08-06)"

# Finestra 12:00-13:00 contiene 3 righe (3000, 50, 1500 ms).
# Con soglia 1000 → 2 (la 50ms è sotto soglia).
assert_eq "finestra 12-13 + soglia 1000ms: 2 richieste" \
    "2" "$(_count "$_FIX/a.log" 1000 "2026-08-06T12:00" "2026-08-06T13:00")"
assert_eq "finestra 12-13 + soglia 1000ms: solo le URL in finestra" \
    "/finestra-lenta /finestra-media" "$(_urls "$_FIX/a.log" 1000 "2026-08-06T12:00" "2026-08-06T13:00")"

# La riga più lenta in assoluto (9000ms alle 18:00) NON deve comparire se
# fuori finestra: è il caso che l'inversione dei filtri potrebbe rompere,
# perché la soglia la ammette e solo il filtro temporale la esclude.
assert_eq "la più lenta in assoluto, ma fuori finestra, è esclusa" \
    "2" "$(_count "$_FIX/a.log" 1000 "2026-08-06T12:00" "2026-08-06T13:00")"

# Finestra che contiene SOLO la riga più lenta
assert_eq "finestra 17-19: solo /sera-lenta" \
    "/sera-lenta" "$(_urls "$_FIX/a.log" 1000 "2026-08-06T17:00" "2026-08-06T19:00")"

# Finestra vuota di richieste lente: la veloce c'è ma è sotto soglia
assert_eq "finestra con sola richiesta veloce: nessuna lenta" \
    "0" "$(_count "$_FIX/a.log" 1000 "2026-08-06T12:31" "2026-08-06T12:31")"

# Solo limite inferiore / solo superiore (in_range gestisce i vuoti)
assert_eq "solo time_from (dalle 12): 3 lente" \
    "3" "$(_count "$_FIX/a.log" 1000 "2026-08-06T12:00" "")"
assert_eq "solo time_to (fino alle 12): 1 lenta (la mattina)" \
    "1" "$(_count "$_FIX/a.log" 1000 "" "2026-08-06T12:00")"

section "Statistiche riportate"

_stats() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$2" -v time_from="${3:-}" -v time_to="${4:-}" "$1" \
        2>/dev/null | _strip | grep -E "$5" | head -1
}
# Max e media calcolate solo sulle righe che passano ENTRAMBI i filtri
assert_eq "risposta più lenta in finestra è 3000ms (non 9000 fuori finestra)" \
    "Risposta più lenta: 3000 ms → /finestra-lenta" \
    "$(_stats "$_FIX/a.log" 1000 "2026-08-06T12:00" "2026-08-06T13:00" 'Risposta più lenta')"
# media di 3000 e 1500 = 2250
assert_eq "latenza media in finestra: 2250 ms" \
    "Latenza media (lente): 2250 ms" \
    "$(_stats "$_FIX/a.log" 1000 "2026-08-06T12:00" "2026-08-06T13:00" 'Latenza media')"

section "Top-K: buffer limitato a 30 righe"

# 40 richieste lente con tempi crescenti: devono comparire le 30 più lente,
# la più lenta per prima.
: > "$_FIX/many.log"
for i in $(seq 10 49); do
    printf '10.0.0.1 [06/Aug/2026:12:%02d:00 +0200] "GET /r%d HTTP/1.1" 200 100 %d000 - UA\n' \
        "$((i % 60))" "$i" "$i" >> "$_FIX/many.log"
done
assert_eq "40 righe lente: il totale riporta 40" "40" "$(_count "$_FIX/many.log" 1000)"
_rows=$(gawk $_UTILS -f "$_TOOL" -v threshold_ms=1000 "$_FIX/many.log" 2>/dev/null | _strip | grep -cE '^\s*[0-9]{3}\s')
assert_eq "ma ne stampa solo 30 (max_rows)" "30" "$_rows"
_first=$(gawk $_UTILS -f "$_TOOL" -v threshold_ms=1000 "$_FIX/many.log" 2>/dev/null | _strip | grep -oE '/r[0-9]+' | head -1)
assert_eq "la prima riga è la più lenta (/r49)" "/r49" "$_first"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
