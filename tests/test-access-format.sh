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

# ─── service_times / access_url_root: bug#1 (query string → falso servizio) ──
section "access_url_root: query string e matrix parameter collassano sullo stesso servizio"

# Prima della correzione (2026-08-18): la classe negata non escludeva
# "?"/"&"/"="/";", quindi ogni variante di query string sullo stesso path
# diventava un "servizio" distinto — su usnext, ~1064 righe fantasma in
# service_times per un solo access log.
cat > "$_FIX/svc.log" <<'EOF'
172.30.85.133 [17/Aug/2026:10:00:00 +0200] "GET /portal/api/rest/anag?id=1 HTTP/1.1" 200 1 50 - -
172.30.85.133 [17/Aug/2026:10:00:01 +0200] "GET /portal/api/rest/anag?id=2&x=y HTTP/1.1" 200 1 60 - -
172.30.85.133 [17/Aug/2026:10:00:02 +0200] "GET /portal/api/rest/anag;jsessionid=ABC HTTP/1.1" 200 1 70 - -
172.30.85.133 [17/Aug/2026:10:00:03 +0200] "GET / HTTP/1.1" 200 1 10 - -
EOF

_svc_out=$(gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
    -f "$TOOLS/service_times.awk" "$_FIX/svc.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

_svc_calls=$(echo "$_svc_out" | awk '$1=="portal"{print $2}')
assert_eq "tre query string diverse sullo stesso path → un solo servizio 'portal' con 3 CALLS" \
    "3" "${_svc_calls:-0}"

_svc_root_calls=$(echo "$_svc_out" | awk '$1=="/"{print $2}')
assert_eq "richiesta alla radice (GET /) → servizio '/' con 1 CALLS, non escluso in silenzio" \
    "1" "${_svc_root_calls:-0}"

_svc_rows=$(echo "$_svc_out" | grep -cE '^\S+\s+[0-9]+\s+')
assert_eq "solo 2 servizi distinti in output (portal, /), non 4 come prima della correzione" \
    "2" "$_svc_rows"

# ─── access_url_service: la profondità è una coordinata (SVCGRAN-1) ─────────
section "access_url_service: profondità configurabile, e l'avviso quando degenera"

# Riproduce la struttura di liquido, dove il difetto è stato trovato in
# produzione: tutti gli URL sotto UN unico contesto webapp. A profondità 1 il
# raggruppamento collassa a un solo "servizio" e la tabella diventa l'access log
# intero con dei percentili addosso; a profondità 3 separa i servizi veri.
cat > "$_FIX/svcdepth.log" <<'EOF'
10.0.0.1 [17/Aug/2026:10:00:00 +0200] "GET /app/rest/anagrafica/v1/get HTTP/1.1" 200 1 10 - -
10.0.0.1 [17/Aug/2026:10:00:01 +0200] "GET /app/rest/anagrafica/v1/list HTTP/1.1" 200 1 20 - -
10.0.0.1 [17/Aug/2026:10:00:02 +0200] "GET /app/rest/sinistri/v1/get HTTP/1.1" 200 1 30 - -
10.0.0.1 [17/Aug/2026:10:00:03 +0200] "POST /app/ws/Fatturazione/soap11 HTTP/1.1" 200 1 40 - -
EOF

_svc_at() {
    gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
        -f "$TOOLS/service_times.awk" -v svc_depth="$1" "$_FIX/svcdepth.log" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g'
}
_rows_at() { _svc_at "$1" | grep -cE '^\S+\s+[0-9]+\s+[0-9]'; }

assert_eq "profondità 1 → 1 solo gruppo (è il difetto trovato su liquido)"  "1" "$(_rows_at 1)"
assert_eq "profondità 2 → 2 gruppi (app/rest, app/ws)"                     "2" "$(_rows_at 2)"
assert_eq "profondità 3 → 3 gruppi (anagrafica, sinistri, Fatturazione)"    "3" "$(_rows_at 3)"

# Il nome mostrato deve essere il prefisso completo, non solo il segmento finale:
# "rest" da solo non direbbe sotto quale applicazione.
assert_eq "a profondità 3 il nome è il path completo, non il solo segmento" "1" \
    "$(_svc_at 3 | grep -qE '^app/rest/anagrafica[[:space:]]' && echo 1 || echo 0)"

# L'avviso è la rete di sicurezza: senza, un raggruppamento degenere è
# indistinguibile da una risposta sensata — ed è per questo che il difetto è
# rimasto invisibile fino a un test sui log di produzione.
assert_eq "profondità 1: il tool AVVERTE di aver trovato un solo servizio" "1" \
    "$(_svc_at 1 | grep -qi "un solo servizio" && echo 1 || echo 0)"
assert_eq "  l'avviso nomina SERVICE_PATH_DEPTH, cioè cosa cambiare" "1" \
    "$(_svc_at 1 | grep -q "SERVICE_PATH_DEPTH" && echo 1 || echo 0)"
assert_eq "profondità 3: nessun avviso (il raggruppamento discrimina)" "1" \
    "$(_svc_at 3 | grep -qi "un solo servizio" && echo 0 || echo 1)"

# Retrocompatibilità: depth=1 deve dare esattamente ciò che dava access_url_root(),
# altrimenti il cambio avrebbe alterato in silenzio il profilo usnext, che usa 1.
assert_eq "profondità 1 equivale ad access_url_root (usnext non cambia)" "1" \
    "$(_svc_at 1 | grep -qE '^app[[:space:]]+4[[:space:]]' && echo 1 || echo 0)"

# ─── SVCGRAN-2: prefissi trasparenti ────────────────────────────────────────
section "access_url_service: sequenze trasparenti saltate nel conteggio profondità"

# Riproduce la struttura reale di liquido: i SOAP hanno quattro componenti di
# package Java prima del nome del servizio, i REST no, e c'è un `service` al primo
# livello che NON deve essere toccato.
cat > "$_FIX/svctrans.log" <<'EOF'
10.0.0.1 [17/Aug/2026:10:00:00 +0200] "POST /app/ws/it/unipol/sx/webservice/fiduciari/WsUtility/soap11 HTTP/1.1" 200 1 10 - -
10.0.0.1 [17/Aug/2026:10:00:01 +0200] "POST /app/ws/it/unipol/sx/webservice/ivr/CliIdentify HTTP/1.1" 200 1 20 - -
10.0.0.1 [17/Aug/2026:10:00:02 +0200] "POST /app/ws/it/unipol/sx/service/verbatel/VerbatelAPI/soap11 HTTP/1.1" 200 1 30 - -
10.0.0.1 [17/Aug/2026:10:00:03 +0200] "GET /app/rest/anagrafica/v1/get HTTP/1.1" 200 1 40 - -
10.0.0.1 [17/Aug/2026:10:00:04 +0200] "GET /app/service/ccfeireceiverequest HTTP/1.1" 200 1 50 - -
EOF

_T="it/unipol/sx/webservice|it/unipol/sx/service"
_svct() {
    gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
        -f "$TOOLS/service_times.awk" -v svc_depth="$1" -v svc_transparent="${2:-}" \
        "$_FIX/svctrans.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
_has() { _svct "$1" "$2" | grep -qE "^$3[[:space:]]" && echo 1 || echo 0; }

# Fail-before: SENZA le sequenze trasparenti i tre SOAP collassano su un gruppo.
assert_eq "senza trasparenti, i SOAP collassano in 'app/ws/it'" "1" "$(_has 4 "" 'app/ws/it/unipol')"

# Con le sequenze: ogni SOAP diventa il proprio servizio, col nome vero.
assert_eq "con trasparenti, 'app/ws/fiduciari/WsUtility' esiste"  "1" "$(_has 4 "$_T" 'app/ws/fiduciari/WsUtility')"
assert_eq "con trasparenti, 'app/ws/ivr/CliIdentify' esiste"      "1" "$(_has 4 "$_T" 'app/ws/ivr/CliIdentify')"
# La seconda sequenza (…/sx/service/) deve funzionare come la prima.
assert_eq "con trasparenti, 'app/ws/verbatel/VerbatelAPI' esiste" "1" "$(_has 4 "$_T" 'app/ws/verbatel/VerbatelAPI')"
assert_eq "  e 'app/ws/it/unipol' NON esiste più"                "0" "$(_has 4 "$_T" 'app/ws/it/unipol')"

# LA riga che protegge il motivo per cui sono SEQUENZE e non segmenti: `service` al
# primo livello è un endpoint vero, e un filtro per-segmento lo distruggerebbe.
assert_eq "'app/service/ccfeireceiverequest' sopravvive (service NON è un segmento filtrato)" \
    "1" "$(_has 4 "$_T" 'app/service/ccfeireceiverequest')"

# I REST non devono essere toccati dalle sequenze SOAP.
assert_eq "i REST restano invariati con le sequenze attive" "1" "$(_has 4 "$_T" 'app/rest/anagrafica/v1')"

# L'ordine di dichiarazione non deve contare: la sequenza più lunga vince sempre.
# Con la corta prima, un filtro naïve lascerebbe 'webservice' orfano nel nome.
_T_rev="it/unipol/sx|it/unipol/sx/webservice"
assert_eq "ordine invertito nella lista: stesso risultato (più lunga prima)" "1" \
    "$(_has 4 "$_T_rev" 'app/ws/fiduciari/WsUtility')"

# Lista vuota = comportamento identico a prima del 2026-08-21 (usnext).
assert_eq "lista vuota: nessuna differenza rispetto alla sola profondità" \
    "$(_svct 4 "" | md5sum)" "$(_svct 4 | md5sum)"

# ─── distribute_status / access_url_endpoint: granularità per-endpoint ───────
section "access_url_endpoint: query string/matrix param tagliati, ID e UUID templatizzati"

# USNEXT-2: distribute_status aveva la sola normalizzazione URL del repo scritta
# inline (query string + ID + UUID), senza test dedicati — lo stesso gap che
# service_times/access_url_root() aveva prima della correzione qui sopra.
# Estratta in access_url_endpoint() (utils-access-undertow.awk): stessa logica,
# ora condivisa e testata. Granularità diversa da access_url_root(): qui si
# preserva il path intero, non solo il primo segmento.
cat > "$_FIX/endpoint.log" <<'EOF'
172.30.85.133 [17/Aug/2026:10:00:00 +0200] "GET /rest/claims/998877?type=auto HTTP/1.1" 500 1 50 - -
172.30.85.133 [17/Aug/2026:10:00:01 +0200] "GET /rest/claims/123456 HTTP/1.1" 500 1 60 - -
172.30.85.133 [17/Aug/2026:10:00:02 +0200] "GET /rest/claims/42 HTTP/1.1" 500 1 40 - -
172.30.85.133 [17/Aug/2026:10:00:03 +0200] "GET /rest/claims;jsessionid=XYZ HTTP/1.1" 500 1 45 - -
172.30.85.133 [17/Aug/2026:10:00:04 +0200] "GET /rest/claims/550e8400-e29b-41d4-a716-446655440000 HTTP/1.1" 500 1 55 - -
172.30.85.133 [17/Aug/2026:10:00:05 +0200] "GET /health HTTP/1.1" 500 1 5 - -
EOF

_ep_out=$(gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-colors.awk" -f "$LIB/utils-access-undertow.awk" \
    -f "$TOOLS/distribute_status.awk" "$_FIX/endpoint.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

_ep_id=$(echo "$_ep_out" | awk '$1=="/rest/claims/{id}"{print $NF}')
assert_eq "due ID numerici >=5 cifre diversi collassano su '/rest/claims/{id}' con COUNT 2" \
    "2" "${_ep_id:-0}"

_ep_short=$(echo "$_ep_out" | awk '$1=="/rest/claims/42"{print $NF}')
assert_eq "ID corto (2 cifre, <5) NON templatizzato: resta '/rest/claims/42'" \
    "1" "${_ep_short:-0}"

_ep_matrix=$(echo "$_ep_out" | awk '$1=="/rest/claims"{print $NF}')
assert_eq "matrix parameter (;jsessionid=...) tagliato: resta '/rest/claims'" \
    "1" "${_ep_matrix:-0}"

_ep_uuid=$(echo "$_ep_out" | awk '$1=="/rest/claims/{uuid}"{print $NF}')
assert_eq "UUID templatizzato: '/rest/claims/{uuid}'" \
    "1" "${_ep_uuid:-0}"

_ep_health=$(echo "$_ep_out" | awk '$1=="/health"{print $NF}')
assert_eq "path senza nulla da normalizzare: passa invariato" \
    "1" "${_ep_health:-0}"

# ─── Riepilogo ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
