#!/bin/bash
#
# test-access-format.sh — FORMAT-1: il timestamp dell'access log si riconosce per
# FORMA, non per posizione.
#
# Prima di FORMAT-1 gli 8 tool che leggono l'access log scrivevano
# `parse_access($2)`, cablando l'assunzione che il timestamp sia il secondo campo.
# Vero per il formato Undertow osservato (`IP [ts] "req" status ...`, verificato su
# prod/cert/test di lxprworkerlana01), ma il formato *combined* di Apache/WebSphere
# (`%h %l %u %t`) lo mette in $4 — e il fallimento era SILENZIOSO: parse_access()
# restituiva 0, il codice tratta 0 come "ignoto" e per il principio 5 include la
# riga, quindi il filtro temporale smetteva di filtrare. Misurato: su un log
# combined con 2 righe e una finestra che ne copre 1, il vecchio codice rispondeva
# "Nessuna richiesta trovata nel periodo selezionato" — un falso negativo pieno.
#
# Uso: bash tests/test-access-format.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"
TOOLS="$LIB/tools"

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

# Undertow: il formato reale di questo profilo — IP [ts] "req" status bytes time
cat > "$_FIX/undertow.log" <<'EOF'
172.30.85.133 [17/Aug/2026:10:00:04 +0200] "GET /ping HTTP/1.1" 200 1 0 - -
172.30.85.133 [17/Aug/2026:10:30:00 +0200] "GET /ping HTTP/1.1" 500 1 0 - -
172.30.85.133 [17/Aug/2026:14:00:04 +0200] "GET /ping HTTP/1.1" 200 1 0 - -
EOF

# Combined (Apache/WebSphere): %h %l %u %t → il timestamp è il QUARTO campo
cat > "$_FIX/combined.log" <<'EOF'
172.30.85.133 - frank [17/Aug/2026:10:00:04 +0200] "GET /ping HTTP/1.1" 200 1 0 - -
172.30.85.133 - frank [17/Aug/2026:10:30:00 +0200] "GET /ping HTTP/1.1" 500 1 0 - -
172.30.85.133 - frank [17/Aug/2026:14:00:04 +0200] "GET /ping HTTP/1.1" 200 1 0 - -
EOF

# Timestamp in prima posizione: nessun campo prima. Verifica che la scansione non
# assuma un minimo di campi a sinistra.
cat > "$_FIX/tsfirst.log" <<'EOF'
[17/Aug/2026:10:00:04 +0200] 172.30.85.133 "GET /ping HTTP/1.1" 200 1 0 - -
[17/Aug/2026:14:00:04 +0200] 172.30.85.133 "GET /ping HTTP/1.1" 200 1 0 - -
EOF

_count() {
    local file="$1" tf="$2" tt="$3"
    gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
         -f "$TOOLS/count_status.awk" \
         -v time_from="$tf" -v time_to="$tt" "$file" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | awk '/^TOTALE/{print $2}'
}

# ─── Il filtro temporale funziona indipendentemente dalla posizione ──────────
section "Il timestamp si trova per forma, non per posizione"

# Finestra 09:00-11:00: copre le righe delle 10:00 e 10:30, esclude quella delle 14:00.
for _fmt in undertow combined tsfirst; do
    _exp=2
    [[ "$_fmt" == "tsfirst" ]] && _exp=1   # tsfirst.log ha solo 1 riga nella finestra
    assert_eq "$_fmt: il filtro temporale seleziona le righe giuste" \
        "$_exp" "$(_count "$_FIX/$_fmt.log" "2026-08-17T09:00" "2026-08-17T11:00")"
done

# Senza finestra: tutte le righe, in ogni formato.
assert_eq "combined: senza finestra conta tutte le righe" \
    "3" "$(_count "$_FIX/combined.log" "" "")"

# ─── Il conteggio è identico fra i due formati ───────────────────────────────
section "Formati diversi, stesso risultato"

# È il cuore di FORMAT-1: due log con gli stessi eventi in formati diversi devono
# produrre lo stesso conteggio. Prima il combined dava "Nessuna richiesta trovata".
_u=$(_count "$_FIX/undertow.log" "2026-08-17T09:00" "2026-08-17T11:00")
_c=$(_count "$_FIX/combined.log" "2026-08-17T09:00" "2026-08-17T11:00")
assert_eq "undertow e combined danno lo stesso conteggio sugli stessi eventi" "$_u" "$_c"

# ─── Righe senza timestamp riconoscibile ─────────────────────────────────────
section "Righe malformate: pruning conservativo, non crash"

# Una riga senza timestamp non deve fare crashare né azzerare il conteggio delle
# altre (principio 5: in dubbio includere, e comunque non perdere le righe buone).
cat > "$_FIX/mixed.log" <<'EOF'
172.30.85.133 [17/Aug/2026:10:00:04 +0200] "GET /ping HTTP/1.1" 200 1 0 - -
questa riga non ha nessun timestamp riconoscibile
172.30.85.133 [17/Aug/2026:10:30:00 +0200] "GET /ping HTTP/1.1" 500 1 0 - -
EOF
assert_eq "riga senza timestamp: le altre due restano contate" \
    "2" "$(_count "$_FIX/mixed.log" "2026-08-17T09:00" "2026-08-17T11:00")"

# ─── Più file nella stessa invocazione: il campo si ricalcola per file ───────
section "Multi-file: il campo del timestamp è per file, non per esecuzione"

# I tool ricevono corrente + rotazioni insieme (select_log_files). Se il campo
# individuato nel primo file "contaminasse" i successivi, un file di formato
# diverso verrebbe filtrato male. Qui: primo file undertow ($2), secondo combined
# ($4) — entrambe le righe nella finestra devono essere contate.
cat > "$_FIX/a.log" <<'EOF'
172.30.85.133 [17/Aug/2026:10:00:04 +0200] "GET /a HTTP/1.1" 200 1 0 - -
EOF
cat > "$_FIX/b.log" <<'EOF'
172.30.85.133 - frank [17/Aug/2026:10:30:00 +0200] "GET /b HTTP/1.1" 200 1 0 - -
EOF
_multi=$(gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
     -f "$TOOLS/count_status.awk" \
     -v time_from="2026-08-17T09:00" -v time_to="2026-08-17T11:00" \
     "$_FIX/a.log" "$_FIX/b.log" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | awk '/^TOTALE/{print $2}')
assert_eq "due file di formato diverso: entrambe le righe contate" "2" "$_multi"

# ─── Gli altri tool che leggono l'access log ─────────────────────────────────
section "La migrazione copre tutti i tool, non solo count_status"

# slow_requests: soglia 0 così ogni riga con tempo misurabile è "lenta".
# Si asserisce sul totale dichiarato dal tool, non sul contenuto delle righe: la
# tabella separa metodo e URL in colonne, quindi un grep su "GET /ping" non
# matcherebbe — la prima stesura di questo test sbagliava proprio così, e sembrava
# un bug del codice mentre era un'assunzione errata dell'asserzione.
_slow=$(gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
     -f "$TOOLS/slow_requests.awk" -v threshold_ms=0 \
     -v time_from="2026-08-17T09:00" -v time_to="2026-08-17T11:00" \
     "$_FIX/combined.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/^Totale richieste lente:/{print $4}')
assert_eq "slow_requests su combined: vede le 2 righe in finestra" "2" "$_slow"

# traffic_volume: aggrega per fascia di 10 minuti (la colonna FASCIA è "HH:MM",
# non una data completa), quindi il timestamp è essenziale al raggruppamento.
_traffic=$(gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
     -f "$TOOLS/traffic_volume.awk" \
     -v time_from="2026-08-17T09:00" -v time_to="2026-08-17T11:00" \
     "$_FIX/combined.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/^Totale richieste:/{print $3}')
assert_eq "traffic_volume su combined: conta le 2 richieste in finestra" "2" "$_traffic"

# ─── Riepilogo ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
