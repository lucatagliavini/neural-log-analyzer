#!/bin/bash
#
# test-level-count.sh — conteggio dei livelli di log (LVLCNT-1)
#
# Perché esiste. Trovato durante lo sweep dei 16 tool in produzione del 2026-08-24,
# confrontando i totali di `filter_errors` con una verità `grep` indipendente: il tool
# dichiarava **46 WARN** su un server.log che nella finestra richiesta ne conteneva
# **2**. La causa erano due strati che si sommavano, e in entrambi l'innesco è
# l'italiano:
#
#   1. il selettore di record era `/ERROR|WARN/`, cioè una SOTTOSTRINGA. La riga
#      italiana `INFO [stdout] [(1) ERRORI AGENZIA - …]` contiene «ERROR» dentro
#      «ERRORI» — il plurale di «errore» — quindi entrava nel filtro;
#   2. la classificazione era BINARIA: `if (level == "ERROR") nerror++; else nwarn++`.
#      Una riga di livello INFO finiva quindi nei WARN.
#
# Misurato: 44 righe INFO catturate, tutte per la parola «ERRORI». E non era solo un
# numero sbagliato — la riga INFO veniva STAMPATA in un report intitolato «Righe
# ERROR/WARN dal server.log».
#
# Lo stesso conteggio era scritto in TRE copie, e due erano corrette: `tail_log.awk` e
# `tail_named_log.awk` usavano `else if (_ll_level == "WARN")`, quindi un livello
# estraneo non veniva conteggiato. La copia sbagliata era quella che nessuno aveva
# riletto. Ora la logica vive in `logline_count_level()` (utils-logline.awk), che è il
# modulo che già possiede `_ll_level`.
#
# Uso: bash tests/test-level-count.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/lib"

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

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# ─── Fixture: un server.log JBoss con la trappola italiana ────────────────────
# Righe REALI ridotte, prese dal nodo 4 di produzione. La riga «ERRORI AGENZIA» è
# quella che ha rivelato il difetto: livello INFO, contenuto che nomina gli errori.
cat > "$_FIX/server.log" <<'EOF'
2026-08-24 09:26:49,261 WARN  [io.undertow.request] (worker I/O-95) UT005072: Thread bloccato da 300410 ms
2026-08-24 09:32:08,762 WARN  [io.undertow.request] (worker I/O-95) UT005073: Thread sbloccato
2026-08-24 11:22:26,409 ERROR [stderr] (pool-93-thread-10350) java.lang.Exception: Failure invoking EssigAnagrafeService
2026-08-24 11:22:26,410 ERROR [stderr] (pool-93-thread-10350) 	at it.unipol.sx.ServiceOutputWrapper.defaultExitOnFailure(X.java:1)
2026-08-24 11:22:26,410 ERROR [stderr] (pool-93-thread-10350) 	at it.unipol.sx.EssigAnagrafeHelper.callFindAnagrafe(Y.java:2)
2026-08-24 08:57:05,235 INFO  [stdout] (worker task-1) [(1) ERRORI AGENZIA - Perdite pecuniarie - MARTA PUCCIO]
2026-08-24 08:57:05,236 INFO  [stdout] (worker task-1) [(2) ERRORI AGENZIA - Perdite pecuniarie - MARIO ROSSI]
2026-08-24 08:57:06,100 INFO  [stdout] (worker task-2) Elaborazione completata senza anomalie
EOF

_run() {
    gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-logline.awk" \
         -f "$LIB/utils-colors.awk" -f "$LIB/utils-jboss.awk" \
         -f "$LIB/utils-dedup.awk" -f "$ROOT_DIR/lib/tools/filter_errors.awk" \
         -v time_from="2026-08-24T00:00" -v time_to="2026-08-24T23:59" \
         "$_FIX/server.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

_OUT="$(_run)"

# ─── Guardia: l'invocazione deve produrre output ───────────────────────────────
# Senza, tutte le asserzioni sotto passerebbero confrontando stringhe vuote — il
# difetto di GAPREP-1, già commesso due volte oggi.
section "Guardia anti-confronto-vacuo"
assert_eq "l'invocazione produce output" "si" \
    "$([[ -n "$_OUT" ]] && echo si || echo no)"
assert_eq "  e contiene la riga di totale" "si" \
    "$(grep -q "^Totale:" <<< "$_OUT" && echo si || echo no)"

# ─── Il totale dei livelli ────────────────────────────────────────────────────
section "Una riga INFO non è un WARN, nemmeno se parla di «ERRORI»"

# 1 evento ERROR (l'eccezione, con i suoi 2 frame raggruppati) e 2 WARN distinti.
# Le 2 righe «ERRORI AGENZIA» e quella ordinaria sono INFO: NON vanno conteggiate.
# Prima del fix questo totale diceva «1 ERROR, 4 WARN» — i 2 WARN veri più le 2
# righe INFO italiane.
assert_eq "totale corretto: 1 ERROR, 2 WARN" "1 ERROR, 2 WARN" \
    "$(grep -oE '[0-9]+ ERROR, [0-9]+ WARN' <<< "$_OUT" | head -1)"

# ─── La riga INFO non deve nemmeno comparire ───────────────────────────────────
section "La riga INFO non compare nel report"

# Il numero sbagliato era metà del difetto: l'altra metà è che la riga veniva
# STAMPATA fra gli errori, etichettata INFO, in un report di ERROR/WARN.
assert_eq "«ERRORI AGENZIA» non è nell'output" "assente" \
    "$(grep -q "ERRORI AGENZIA" <<< "$_OUT" && echo presente || echo assente)"
assert_eq "nessuna riga etichettata INFO nel report" "assente" \
    "$(grep -qE '\bINFO\b' <<< "$_OUT" && echo presente || echo assente)"

# ─── Non-regressione: ciò che DEVE comparire ──────────────────────────────────
section "Non-regressione: gli errori e i warning veri restano"

assert_eq "l'eccezione ERROR è nel report" "presente" \
    "$(grep -q "java.lang.Exception" <<< "$_OUT" && echo presente || echo assente)"
assert_eq "i frame di stack trace sono raggruppati sotto l'eccezione" "presente" \
    "$(grep -q "ServiceOutputWrapper" <<< "$_OUT" && echo presente || echo assente)"
assert_eq "il WARN UT005072 è nel report" "presente" \
    "$(grep -q "UT005072" <<< "$_OUT" && echo presente || echo assente)"
assert_eq "il WARN UT005073 è nel report" "presente" \
    "$(grep -q "UT005073" <<< "$_OUT" && echo presente || echo assente)"

# ─── La funzione condivisa: un livello ignoto non finisce da nessuna parte ─────
section "logline_count_level(): i livelli ignoti non vengono conteggiati"

# È la proprietà che le due copie corrette avevano e la terza no. Verificata sulla
# funzione condivisa, così vale per tutti e tre i chiamanti insieme.
_probe() {
    gawk -f "$LIB/utils-time.awk" -f "$LIB/utils-logline.awk" -e '
        BEGIN {
            logline_count_level("ERROR"); logline_count_level("ERROR")
            logline_count_level("WARN")
            logline_count_level("INFO")
            logline_count_level("DEBUG")     # noto ma non tracciato
            logline_count_level("")          # riga non riconosciuta
            logline_count_level("ERRORI")    # la trappola italiana
            printf "%d %d %d", nerror+0, nwarn+0, ninfo+0
        }' </dev/null
}
assert_eq "ERROR=2 WARN=1 INFO=1, e ERRORI/DEBUG/vuoto ignorati" "2 1 1" "$(_probe)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" \
    "$pass" "$fail" "$(( pass + fail ))"
printf "═══════════════════════════════════════════════════\n"
echo ""

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
