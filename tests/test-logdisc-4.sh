#!/bin/bash
#
# test-logdisc-4.sh — LOGDISC-4: scoperta ricorsiva dei log di SISTEMA
# (access/server/gc) e validazione per-tool.
#
# Prima di LOGDISC-4 i log di sistema erano gli ultimi risolti da un template di
# layout: APP_DIR="$NODE_DIR/$(eval echo "$APP_SUBPATH")" in resolve-logs.sh.
# Ora sono scoperti sotto LOG_SEARCH_ROOT come già i named log (LOGDISC-1) e
# search_all_logs (LOGDISC-2) — il contratto si ferma al nodo (principio 6).
#
# LA MOLTEPLICITÀ RICHIEDE UNA SCELTA, NON UN'ETICHETTA. Su un nodo reale ogni
# log di sistema esiste in una copia per app (misurato sul nodo 4: access 55+55,
# server 22+22, gc 16+16): leggerne due significherebbe sommare le pause GC di
# due JVM distinte o mescolare stack trace di due applicazioni. Per questo la
# scoperta usa il tie-break di resolve_log_glob (ACTIVE_APP prima) e il vincolo
# require_app, a differenza di search_all_logs che aggrega e dichiara la
# provenienza con la colonna APP.
#
# Uso: bash tests/test-logdisc-4.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"; fail=$(( fail + 1 ))
    fi
}

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

# Colori inerti per le funzioni di dispatch.sh che li usano nei messaggi
C_WARN="" C_RESET="" C_LBL="" C_CRIT="" C_OK="" C_VAL="" C_ACCENT="" C_BOLD=""
export C_WARN C_RESET C_LBL C_CRIT C_OK C_VAL C_ACCENT C_BOLD

source "$LIB/utils-logfiles.sh"

ACCESS_LOG_BASE="undertow_access_log"
SERVER_LOG_BASE="server"
GC_LOG_BASE="gc"
AVAILABLE_APPS=("ClaimCenter" "ContactManager")

# ─── Fixture: il caso di produzione — due app con log di sistema OMONIMI ──────
_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

_NODE="$_FIX/prod/lxprjbliq04"
mkdir -p "$_NODE/prod/ClaimCenter" "$_NODE/prod/ContactManager"
for _app in ClaimCenter ContactManager; do
    for _b in undertow_access_log server gc; do
        echo "2026-08-17 10:00:00,000 ${_app}-${_b}" > "$_NODE/prod/${_app}/${_b}.log"
    done
done
# Rotazione sotto ClaimCenter: il tie-break deve preferire il file corrente
echo x | gzip -c > "$_NODE/prod/ClaimCenter/undertow_access_log.log-2026-08-01-1785000000.gz"

# ─── 1. resolve_system_log_dir: l'app di sessione decide ──────────────────────
section "resolve_system_log_dir: tie-break sull'app di sessione"

for _b in undertow_access_log server gc; do
    _r=$(ACTIVE_APP=ClaimCenter resolve_system_log_dir "$_NODE" "$_b" 1)
    assert_eq "'$_b' con ACTIVE_APP=ClaimCenter → directory di ClaimCenter" \
        "$_NODE/prod/ClaimCenter" "$_r"
    _r=$(ACTIVE_APP=ContactManager resolve_system_log_dir "$_NODE" "$_b" 1)
    assert_eq "'$_b' con ACTIVE_APP=ContactManager → directory di ContactManager" \
        "$_NODE/prod/ContactManager" "$_r"
done

# Il tie-break preferisce il file corrente alla rotazione: la directory è la
# stessa, ma se scegliesse la .gz il comportamento a valle cambierebbe.
_r=$(ACTIVE_APP=ClaimCenter resolve_log_glob "$_NODE" "undertow_access_log*" undertow_access_log 1)
assert_true "il tie-break preferisce il file corrente alla rotazione .gz" \
    "$([[ "$_r" == *"undertow_access_log.log" ]] && echo 1 || echo 0)"

# ─── 2. Cross-app: dirlo, non aprirlo in silenzio ─────────────────────────────
section "Cross-app: require_app rifiuta il log di un'altra app"

rm -f "$_NODE/prod/ContactManager/gc.log"

_r=$(ACTIVE_APP=ContactManager resolve_system_log_dir "$_NODE" gc 1) && _rc=0 || _rc=1
assert_eq "gc solo sotto ClaimCenter, sessione ContactManager: require_app=1 rifiuta" "1" "$_rc"
assert_eq "  e non emette nulla (niente path da aprire per errore)" "" "$_r"

# Senza require_app deve invece trovarlo: è così che skip_system_log_not_found
# sa dire "esiste sotto ClaimCenter" invece di un generico "non trovato".
_r=$(ACTIVE_APP=ContactManager resolve_system_log_dir "$_NODE" gc)
assert_eq "  senza require_app lo trova (serve al messaggio 'esiste sotto X')" \
    "$_NODE/prod/ClaimCenter" "$_r"

# ─── 3. Log che non appartiene a NESSUNA app ─────────────────────────────────
section "require_app: nessuna app ≠ app sbagliata (bug trovato 2026-08-17)"

# Bug preesistente da LOGDISC-1: require_app confrontava "il path contiene
# /ACTIVE_APP/" invece di "il file appartiene a un'altra app". Un log in una
# directory che non nomina alcuna app veniva RIFIUTATO, pur non essendoci nessun
# dato di un'altra app da cui proteggersi — falso negativo, cioè un bug di
# correttezza (principio 5). Rendeva irraggiungibili con tail_named_log proprio i
# log in posizione arbitraria che LOGDISC-1 aveva reso scopribili.
_ORPH="$_FIX/orfano"
mkdir -p "$_ORPH/weird/deep/nested"
echo "2026-08-17 10:00:00,000 orfano" > "$_ORPH/weird/deep/nested/server.log"
echo "2026-08-17 10:00:00,000 orfano" > "$_ORPH/weird/deep/nested/custom_app.log"

_r=$(ACTIVE_APP=ClaimCenter resolve_system_log_dir "$_ORPH" server 1)
assert_eq "log di sistema in directory senza app: ACCETTATO con require_app=1" \
    "$_ORPH/weird/deep/nested" "$_r"

# Lo stesso vale per i named log, che usano require_app=1 in tutta la cascata:
# è il percorso dove il bug era attivo in produzione.
_r=$(ACTIVE_APP=ClaimCenter resolve_log_glob "$_ORPH" "*custom_app*.log" custom_app 1)
assert_true "named log in directory senza app: ACCETTATO (era rifiutato)" \
    "$([[ -n "$_r" ]] && echo 1 || echo 0)"

# La protezione cross-app NON deve essere stata indebolita dal fix.
_r=$(ACTIVE_APP=ContactManager resolve_log_glob "$_NODE" "gc.log" gc 1) && _rc=0 || _rc=1
assert_eq "il rifiuto cross-app resta attivo dopo il fix" "1" "$_rc"

# ─── 4. Cascata a due livelli: solo rotazioni, nessun corrente ───────────────
section "Cascata: una directory con sole rotazioni va scoperta"

# Escluderla darebbe "non disponibile" su un nodo che HA i dati, solo già
# ruotati — falso negativo (principio 5).
_ROT="$_FIX/soloRotazioni"
mkdir -p "$_ROT/prod/ClaimCenter"
echo x | gzip -c > "$_ROT/prod/ClaimCenter/server.log-2026-08-01-1785000000.gz"
_r=$(ACTIVE_APP=ClaimCenter resolve_system_log_dir "$_ROT" server 1)
assert_eq "directory con sole rotazioni .gz: scoperta dal 2° livello" \
    "$_ROT/prod/ClaimCenter" "$_r"

# ─── 5. Casi degeneri ────────────────────────────────────────────────────────
section "Casi degeneri: nessun output spurio"

# Il chiamante itera su stdout: una riga di troppo diventerebbe un path.
assert_eq "root inesistente → nessun output" "" \
    "$(resolve_system_log_dir "$_FIX/non_esiste" server 1 2>/dev/null || true)"
assert_eq "base vuoto → nessun output (non cerca '.log*')" "" \
    "$(resolve_system_log_dir "$_NODE" "" 1 2>/dev/null || true)"
assert_eq "search_root vuoto → nessun output" "" \
    "$(resolve_system_log_dir "" server 1 2>/dev/null || true)"

# ─── 6. resolve-logs.sh end-to-end: il contratto reale (subprocess + eval) ───
section "resolve-logs.sh: scoperta per app, via subprocess"

# Il contratto vero è `eval "$(resolve-logs.sh ...)"` (chatbot.sh:163-170), non
# la funzione in isolamento: solo così si verifica anche che il nuovo sourcing di
# utils-logfiles.sh non scriva nulla su stdout — un byte di troppo diventerebbe
# codice eseguito dal chiamante.
_rl_out=$(PROFILE_DIR="$ROOT_DIR/profiles/liquido" \
    "$LIB/resolve-logs.sh" "$_FIX" prod 4 ClaimCenter 2>/dev/null) && _rc=0 || _rc=1
assert_eq "esce con 0 su fixture valida" "0" "$_rc"

# Nessuna riga fuori dal formato VAR='valore': è ciò che rende l'eval sicuro.
_bad=$(echo "$_rl_out" | grep -cvE "^[A-Z_]+='.*'$" || true)
assert_eq "ogni riga di output è un'assegnazione (eval-safe)" "0" "$_bad"

( eval "$_rl_out"
  [[ "$ACCESS_LOG_DIR" == "$_NODE/prod/ClaimCenter" ]] ) && _ok=1 || _ok=0
assert_true "app=ClaimCenter → ACCESS_LOG_DIR sotto ClaimCenter" "$_ok"

_rl_out2=$(PROFILE_DIR="$ROOT_DIR/profiles/liquido" \
    "$LIB/resolve-logs.sh" "$_FIX" prod 4 ContactManager 2>/dev/null)
( eval "$_rl_out2"
  [[ "$SERVER_LOG_DIR" == "$_NODE/prod/ContactManager" ]] ) && _ok=1 || _ok=0
assert_true "app=ContactManager → SERVER_LOG_DIR sotto ContactManager" "$_ok"

# gc.log è stato rimosso da ContactManager nella sezione 2: la variabile deve
# restare VUOTA (require_app), non puntare a quella di ClaimCenter.
( eval "$_rl_out2"; [[ -z "$GC_LOG_DIR" ]] ) && _ok=1 || _ok=0
assert_true "gc assente sotto l'app di sessione → GC_LOG_DIR vuota, non cross-app" "$_ok"

# ─── 7. Il difetto collaterale: access mancante non uccide la sessione ───────
section "Validazione per-tool: access mancante non aborta la sessione"

# Prima di LOGDISC-4, resolve-logs.sh faceva `exit 1` se non trovava un access
# log — quindi un nodo la cui app non espone HTTP rendeva il bot inutilizzabile
# per QUALSIASI query, anche su server.log o gc.log. Incontrato scrivendo il test
# e2e di LOGDISC-2.
_NOACC="$_FIX/senzaAccess"
mkdir -p "$_NOACC/prod/lxprjbliq04/prod/ClaimCenter"
echo "2026-08-17 10:00:00,000 solo server" > "$_NOACC/prod/lxprjbliq04/prod/ClaimCenter/server.log"

_rl_out3=$(PROFILE_DIR="$ROOT_DIR/profiles/liquido" \
    "$LIB/resolve-logs.sh" "$_NOACC" prod 4 ClaimCenter 2>/dev/null) && _rc=0 || _rc=1
assert_eq "nodo senza access log: esce con 0 (prima: exit 1)" "0" "$_rc"

( eval "$_rl_out3"; [[ -z "$ACCESS_LOG_DIR" ]] ) && _ok=1 || _ok=0
assert_true "  ACCESS_LOG_DIR vuota, non un path inventato" "$_ok"
( eval "$_rl_out3"; [[ -n "$SERVER_LOG_DIR" ]] ) && _ok=1 || _ok=0
assert_true "  SERVER_LOG_DIR risolta: i tool che non usano access funzionano" "$_ok"

# ─── 8. I messaggi: distinguere 'assente' da 'sotto un'altra app' ───────────
section "skip_system_log_not_found: messaggi distinti"

# dispatch.sh non è sourciabile in isolamento (dipende dal contesto di sessione):
# si estraggono le due funzioni sotto test, come fa test-log-discovery.sh per
# altre. skip_msg è sostituita da una versione minimale senza colori.
skip_msg() { printf "[SKIP] %s\n" "$1"; }
eval "$(sed -n '/^skip_system_log_not_found() {/,/^}/p' "$LIB/dispatch.sh")"

_m=$(ACTIVE_APP=ContactManager skip_system_log_not_found "$_NODE" gc "gc log per gc_stats")
assert_true "log sotto un'altra app: il messaggio suggerisce ClaimCenter" \
    "$([[ "$_m" == *"esiste sotto ClaimCenter"* ]] && echo 1 || echo 0)"
assert_true "  e nomina il tool che ne aveva bisogno" \
    "$([[ "$_m" == *"gc_stats"* ]] && echo 1 || echo 0)"

_m=$(ACTIVE_APP=ClaimCenter skip_system_log_not_found "$_NODE" inesistente "log X per un_tool")
assert_true "log assente ovunque: messaggio generico, nessuna app suggerita" \
    "$([[ "$_m" != *"esiste sotto"* ]] && echo 1 || echo 0)"

# ─── Riepilogo ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
