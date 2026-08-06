#!/bin/bash
#
# test-filter-ip.sh — unit test per lib/tools/filter_ip.awk.
#
# Copertura prima assente: il tool era coperto solo da smoke-tools.sh, che
# richiede log reali e verifica solo "non è andato in errore".
#
# Copre le due modalità (IP singolo e top-clients) e in particolare
# l'estrazione UNICA di status e tempo introdotta il 2026-08-06: prima la
# regex dello status girava fino a 3 volte sulla stessa riga e quella del tempo
# 2 volte, con un blocco che calcolava colori mai usati (codice morto). Un
# errore nella deduplicazione di quelle estrazioni si vedrebbe nei conteggi e
# nelle medie, non in un crash.
#
# Uso: bash tests/test-filter-ip.sh
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

_UTILS="-f $LIB/utils-time.awk -f $LIB/utils-colors.awk -f $LIB/utils-jboss.awk -f $LIB/utils-dedup.awk"
_TOOL="$LIB/tools/filter_ip.awk"
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }
_run() { gawk $_UTILS -f "$_TOOL" "$@" "$_FIX/a.log" 2>/dev/null | _strip; }

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Fixture: 3 IP con volumi, status e tempi diversi.
#   10.0.0.1 → 3 richieste (200, 404, 500), tempi 100/200/300 = media 200
#   10.0.0.2 → 2 richieste (200, 200), tempi 1000/3000       = media 2000
#   10.0.0.3 → 1 richiesta (200), tempo 50
# Formato REALE Undertow (verificato in produzione): la data è in $2, senza i
# due "- -" del Combined Log Format di Apache — parse_access($2) dipende da
# questa posizione.
cat > "$_FIX/a.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:00 +0200] "GET /a HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:01:00 +0200] "GET /b HTTP/1.1" 404 100 200 - UA
10.0.0.1 [06/Aug/2026:10:02:00 +0200] "POST /c HTTP/1.1" 500 100 300 - UA
10.0.0.2 [06/Aug/2026:10:03:00 +0200] "GET /d HTTP/1.1" 200 100 1000 - UA
10.0.0.2 [06/Aug/2026:10:04:00 +0200] "GET /e HTTP/1.1" 200 100 3000 - UA
10.0.0.3 [06/Aug/2026:11:00:00 +0200] "GET /f HTTP/1.1" 200 100 50 - UA
EOF

section "Modalità top-clients (ip_filter vuoto)"

_out=$(_run)
assert_eq "6 richieste, 3 IP distinti" "Top 3 di 3 IP distinti" \
    "$(grep -oE 'Top [0-9]+ di [0-9]+ IP distinti' <<< "$_out")"
# L'IP con più richieste è primo
assert_eq "primo IP per volume è 10.0.0.1 (3 richieste)" "10.0.0.1" \
    "$(grep -oE '^10\.0\.0\.[0-9]' <<< "$_out" | head -1)"
# La media dei tempi è calcolata sull'estrazione unica: 100+200+300=600/3=200
assert_eq "media di 10.0.0.1 = 200.00 ms" "200.00" \
    "$(grep -E '^10\.0\.0\.1' <<< "$_out" | awk '{print $NF}')"
assert_eq "media di 10.0.0.2 = 2000.00 ms" "2000.00" \
    "$(grep -E '^10\.0\.0\.2' <<< "$_out" | awk '{print $NF}')"
assert_eq "media di 10.0.0.3 = 50.00 ms" "50.00" \
    "$(grep -E '^10\.0\.0\.3' <<< "$_out" | awk '{print $NF}')"

# top_n limita le righe mostrate ma non il conteggio totale
_out_top=$(_run -v top_n=2)
assert_eq "top_n=2: mostra 2 di 3" "Top 2 di 3 IP distinti" \
    "$(grep -oE 'Top [0-9]+ di [0-9]+ IP distinti' <<< "$_out_top")"

section "Modalità IP singolo"

_out_ip=$(_run -v ip_filter=10.0.0.1)
assert_eq "3 richieste per 10.0.0.1" "Totale richieste: 3" \
    "$(grep -E '^Totale richieste' <<< "$_out_ip")"
assert_eq "latenza media 200 ms" "Latenza media:    200 ms" \
    "$(grep -E '^Latenza media' <<< "$_out_ip")"
# La distribuzione status viene dall'estrazione unica: 200, 404, 500 una volta ciascuno
assert_eq "distribuzione status: 3 codici distinti" "3" \
    "$(sed -n '/Distribuzione status/,$p' <<< "$_out_ip" | grep -cE '^\s+[0-9]{3}:')"
assert_eq "status 200 contato una volta" "  200: 1" \
    "$(grep -E '^\s+200:' <<< "$_out_ip")"
assert_eq "status 500 contato una volta" "  500: 1" \
    "$(grep -E '^\s+500:' <<< "$_out_ip")"

# IP inesistente: messaggio esplicito, non output vuoto
assert_eq "IP inesistente: messaggio chiaro" "Nessuna richiesta trovata per IP: 9.9.9.9" \
    "$(_run -v ip_filter=9.9.9.9)"

section "Filtro temporale"

# Finestra 10:00-10:02 → solo le 3 righe di 10.0.0.1 (10:00, 10:01, 10:02)
_out_tw=$(_run -v time_from=2026-08-06T10:00 -v time_to=2026-08-06T10:02)
assert_eq "finestra 10:00-10:02: 1 solo IP" "Top 1 di 1 IP distinti" \
    "$(grep -oE 'Top [0-9]+ di [0-9]+ IP distinti' <<< "$_out_tw")"

# Finestra che esclude tutto
assert_eq "finestra vuota: messaggio esplicito" "Nessuna richiesta trovata nel log." \
    "$(_run -v time_from=2026-08-07T00:00 -v time_to=2026-08-07T23:59)"

# Filtro temporale + IP: entrambi devono applicarsi
_out_both=$(_run -v ip_filter=10.0.0.1 -v time_from=2026-08-06T10:00 -v time_to=2026-08-06T10:01)
assert_eq "IP + finestra: 2 richieste su 3" "Totale richieste: 2" \
    "$(grep -E '^Totale richieste' <<< "$_out_both")"

section "Righe malformate (nessuno status o tempo estraibile)"

cat > "$_FIX/bad.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:00 +0200] "GET /a HTTP/1.1" 200 100 100 - UA
righe senza formato riconoscibile
10.0.0.1 [06/Aug/2026:10:01:00 +0200] malformata senza status
EOF
_out_bad=$(gawk $_UTILS -f "$_TOOL" -v ip_filter=10.0.0.1 "$_FIX/bad.log" 2>/dev/null | _strip)
# O6 CORRETTO (2026-08-06): la media divide per le richieste di cui si è potuto
# MISURARE il tempo, non per tutte. Qui una sola riga ha un tempo estraibile
# (100ms), quindi la media è 100 — prima era 50 (100/2), che sottostimava
# perché la riga malformata entrava nel denominatore con contributo 0.
assert_eq "righe malformate: media sulle sole righe misurabili (O6)" "Latenza media:    100 ms" \
    "$(grep -E '^Latenza media' <<< "$_out_bad")"
# E lo dichiara, invece di presentare una media parziale come completa: senza
# questa riga il numero è indistinguibile da uno calcolato su tutte le richieste.
assert_eq "e dichiara quante righe erano senza tempo misurabile" "1" \
    "$([[ "$_out_bad" == *"1 richieste con tempo misurabile, 1 senza"* ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
