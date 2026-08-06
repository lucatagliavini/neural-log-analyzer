#!/bin/bash
#
# test-utils-logfiles.sh — unit test per lib/utils-logfiles.sh.
#
# Copertura prima assente (fino al 2026-08-06): select_log_files_grouped /
# select_log_files non avevano NESSUN test end-to-end — solo funzioni vicine
# (logfile_logical_name, resolve_log_glob, _logfiles_read_first_ts) erano
# testate, in tests/test-param-extract.sh.
#
# Copre il motore di selezione generalizzato (walk backward con arresto
# anticipato): raggruppamento per nome logico, ordine di recenza derivato
# dal NOME (non da mtime — inaffidabile per log copiati/sincronizzati,
# confermato dall'utente), rotazioni numerate con ordinale invertito
# (.log.1 è più recente di .log.2 — un sort lessicografico sbaglierebbe),
# conservatività su timestamp ignoti, e il bug latente di select_log_files
# con filtro vuoto che emetteva la directory stessa.
#
# Uso: bash tests/test-utils-logfiles.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/utils-logfiles.sh"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"
        fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

_contains() {
    # _contains HAYSTACK NEEDLE — HAYSTACK è una lista |-separata
    [[ "|$1|" == *"|$2|"* ]] && echo 1 || echo 0
}

export BOT_LOG_LEVEL="off"

# ─── Fixture: directory flat con più nomi logici e rotazioni ──────────────────
_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Nome logico "policysearch": corrente + 3 rotazioni con epoch nel nome.
# Ogni rotazione parte alle 06:00 del suo giorno (non a mezzanotte): una
# finestra che chiede l'intera giornata "04/08" lascia scoperte le prime 6
# ore da quel file, quindi il walk deve conservativamente scendere anche
# alla rotazione precedente — comportamento corretto, non un bug.
echo "2026-08-05T06:00:00,000 INFO corrente" > "$_FIX/policysearch.log"
gzip -c <(echo "2026-08-04T06:00:00,000 INFO rotazione 1gg fa")  > "$_FIX/policysearch.log-2026-08-04-1785600000.gz"
gzip -c <(echo "2026-08-03T06:00:00,000 INFO rotazione 2gg fa")  > "$_FIX/policysearch.log-2026-08-03-1785500000.gz"
gzip -c <(echo "2026-08-02T06:00:00,000 INFO rotazione 3gg fa")  > "$_FIX/policysearch.log-2026-08-02-1785400000.gz"

# Nome logico "cc": un solo file (nessuna rotazione)
echo "2026-08-05T09:00:00,000 INFO cc singolo" > "$_FIX/cc.log"

# Nome logico "srv": rotazione NUMERATA — la trappola lessicografica.
# .1 è la più recente, .10 e .11 sono le più vecchie (ordinale invertito).
echo "2026-08-05T20:00:00,000 INFO srv corrente"     > "$_FIX/srv.log"
gzip -c <(echo "2026-08-05T15:00:00,000 INFO srv .1") > "$_FIX/srv.log.1.gz"
gzip -c <(echo "2026-08-05T10:00:00,000 INFO srv .2") > "$_FIX/srv.log.2.gz"
gzip -c <(echo "2026-08-01T10:00:00,000 INFO srv .10")  > "$_FIX/srv.log.10.gz"
gzip -c <(echo "2026-07-31T10:00:00,000 INFO srv .11")  > "$_FIX/srv.log.11.gz"

# File vuoto (deve essere scartato, come nel motore storico)
touch "$_FIX/empty.log"

# File senza timestamp parsabile: deve essere SEMPRE incluso (conservativo)
echo "riga senza alcun timestamp riconoscibile" > "$_FIX/noise.log"

# ─── Raggruppamento e walk backward: rotazioni con epoch nel nome ─────────────
section "Raggruppamento per nome logico e rotazioni con epoch"

_all_policysearch=$(select_log_files_grouped "$_FIX" "" "" "policysearch*")
assert_true "policysearch: tutte le 4 rotazioni raggiungibili senza filtro temporale" \
    "$([[ "$(grep -o '|' <<< "$_all_policysearch" | wc -l)" -eq 3 ]] && echo 1 || echo 0)"

# Finestra INTERAMENTE dentro l'intervallo coperto dalla rotazione "1gg fa"
# (06:00-18:00 di quel giorno, con margine sia dal proprio inizio sia dalla
# rotazione successiva): il walk deve fermarsi lì con un solo file.
_win_policysearch=$(select_log_files_grouped "$_FIX" "2026-08-04T10:00" "2026-08-04T18:00" "policysearch*")
_win_count=$(( $(grep -o '|' <<< "$_win_policysearch" | wc -l) + 1 ))
[[ -z "$_win_policysearch" ]] && _win_count=0
assert_true "policysearch: finestra interamente dentro 'ieri' seleziona solo quella rotazione" \
    "$([[ "$_win_count" -eq 1 ]] && echo 1 || echo 0)"
assert_true "policysearch: non scende alla rotazione di 2gg fa" \
    "$(( 1 - $(_contains "$_win_policysearch" "$_FIX/policysearch.log-2026-08-03-1785500000.gz") ))"

# ─── File singolo (nessuna rotazione) ──────────────────────────────────────────
section "Gruppo a file singolo"

_cc=$(select_log_files_grouped "$_FIX" "" "" "cc*")
assert_true "cc: file singolo selezionato" "$([[ "$_cc" == "$_FIX/cc.log" ]] && echo 1 || echo 0)"

# ─── Rotazione numerata: ordinale invertito, non lessicografico ───────────────
section "Rotazione numerata (.log.1 più recente di .log.2, .10, .11)"

_srv_all=$(select_log_files_grouped "$_FIX" "" "" "srv*")
_srv_count=$(( $(grep -o '|' <<< "$_srv_all" | wc -l) + 1 ))
assert_true "srv: tutte le 5 rotazioni raggiungibili senza filtro" "$([[ "$_srv_count" -eq 5 ]] && echo 1 || echo 0)"

# Finestra interamente dopo l'inizio di srv.log.1 (15:00): il walk deve
# fermarsi lì, senza scendere a .2/.10/.11 nonostante ".2" sia
# lessicograficamente "vicino" a ".1".
_srv_win=$(select_log_files_grouped "$_FIX" "2026-08-05T16:00" "2026-08-05T23:59" "srv*")
_srv_win_count=$(( $(grep -o '|' <<< "$_srv_win" | wc -l) + 1 ))
[[ -z "$_srv_win" ]] && _srv_win_count=0
assert_true "srv: finestra breve seleziona solo corrente + .1 (non scende a .2/.10/.11)" \
    "$([[ "$_srv_win_count" -eq 2 ]] && echo 1 || echo 0)"
assert_true "srv: la rotazione .10 (più vecchia) non compare con finestra breve" \
    "$(( 1 - $(_contains "$_srv_win" "$_FIX/srv.log.10.gz") ))"

# ─── File vuoto scartato, file senza timestamp sempre incluso ──────────────────
section "File vuoto scartato, file senza timestamp sempre incluso (conservativo)"

_empty=$(select_log_files_grouped "$_FIX" "2026-08-05T00:00" "2026-08-05T23:59" "empty*")
assert_true "empty.log: scartato (file vuoto)" "$([[ -z "$_empty" ]] && echo 1 || echo 0)"

_noise=$(select_log_files_grouped "$_FIX" "2026-08-05T00:00" "2026-08-05T23:59" "noise*")
assert_true "noise.log: incluso anche con filtro temporale attivo (ts_start ignoto → conservativo)" \
    "$([[ "$_noise" == "$_FIX/noise.log" ]] && echo 1 || echo 0)"

# ─── Bug latente: select_log_files con filtro vuoto non deve emettere DIR ──────
section "select_log_files_grouped con filtro vuoto non emette la directory"

_all=$(select_log_files_grouped "$_FIX" "" "" "")
assert_true "nessun risultato è la directory stessa" \
    "$(( 1 - $(_contains "$_all" "$_FIX") ))"
assert_true "il motore con filtro vuoto trova tutti i nomi logici (policysearch, cc, srv, noise)" \
    "$([[ -n "$(_contains "$_all" "$_FIX/cc.log")" && $(_contains "$_all" "$_FIX/cc.log") -eq 1 \
        && $(_contains "$_all" "$_FIX/srv.log") -eq 1 \
        && $(_contains "$_all" "$_FIX/noise.log") -eq 1 ]] && echo 1 || echo 0)"

# ─── select_log_files (wrapper storico): nome logico esatto, non prefisso ─────
section "select_log_files: nome logico esatto (non un prefisso ambiguo)"

# "cc" non deve tirarsi dietro "ccJBatch" se esistesse — verifichiamo il caso
# reale già coperto da resolve_log_glob (test-param-extract.sh), qui solo che
# il wrapper deleghi correttamente al motore con lo stesso comportamento.
touch "$_FIX/ccJBatch.log"
echo "2026-08-05T09:00:00,000 INFO altro log" > "$_FIX/ccJBatch.log"
_wrap_cc=$(select_log_files "$_FIX" "cc" "" "")
assert_true "select_log_files('cc'): non include ccJBatch.log (nome logico diverso)" \
    "$(( 1 - $(_contains "$_wrap_cc" "$_FIX/ccJBatch.log") ))"
assert_true "select_log_files('cc'): include cc.log" \
    "$(_contains "$_wrap_cc" "$_FIX/cc.log")"

# ─── mtime falsato (scenario di sincronizzazione) non altera la selezione ─────
section "mtime falsato (log copiati/sincronizzati) non altera l'ordine di recenza"

_FIX2="$(mktemp -d)"
echo "2026-08-05T18:00:00,000 INFO corrente" > "$_FIX2/app.log"
gzip -c <(echo "2026-08-01T12:00:00,000 INFO rotazione vecchia") > "$_FIX2/app.log-2026-08-01-1785000000.gz"
# Falsa l'mtime: il file "vecchio" ha mtime più recente del corrente (rsync/cp).
touch -d "2026-08-06T00:00:00" "$_FIX2/app.log-2026-08-01-1785000000.gz"
touch -d "2026-08-01T00:00:00" "$_FIX2/app.log"

_sync_win=$(select_log_files_grouped "$_FIX2" "2026-08-05T20:00" "2026-08-05T23:59" "app*")
_sync_count=$(( $(grep -o '|' <<< "$_sync_win" | wc -l) + 1 ))
[[ -z "$_sync_win" ]] && _sync_count=0
assert_true "ordine di recenza dal NOME (non da mtime falsato): finestra 'oggi' non scende alla rotazione vecchia" \
    "$([[ "$_sync_count" -eq 1 ]] && echo 1 || echo 0)"
rm -rf "$_FIX2"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
