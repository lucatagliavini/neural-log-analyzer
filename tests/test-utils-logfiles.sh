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

# assert_eq mostra atteso/avuto quando falliscono: su un confronto di epoch o di
# conteggi, "FAIL" da solo non dice se il valore era 0, sbagliato di un'ora o di
# un anno. assert_true resta per le condizioni booleane.
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

# ─── Rotazione giornaliera: data PRIMA di .log (BASENAME.DATE.log) ───────────
# Bug reale in produzione (2026-08-07): logfile_logical_name() e
# _logfiles_sort_key() gestivano solo un suffisso di rotazione DOPO ".log"
# (.log.N, .log-DATE-EPOCH.gz), non uno PRIMA (undertow_access_log.2026-07-14.log)
# — nonostante l'header del file dichiarasse questo schema come supportato.
# 19 rotazioni giornaliere producevano 19 nomi logici distinti invece di 1.
section "Rotazione giornaliera BASENAME.DATE.log (data prima di .log)"

assert_true "logfile_logical_name: BASENAME.DATE.log -> BASENAME (non BASENAME.DATE)" \
    "$([[ "$(logfile_logical_name "undertow_access_log.2026-07-14.log")" == "undertow_access_log" ]] && echo 1 || echo 0)"
assert_true "logfile_logical_name: BASENAME.DATE.log.gz -> BASENAME" \
    "$([[ "$(logfile_logical_name "undertow_access_log.2026-07-14.log.gz")" == "undertow_access_log" ]] && echo 1 || echo 0)"

echo "2026-08-05T12:00:00,000 INFO corrente"        > "$_FIX/undertow_access_log.log"
echo "2026-08-04T12:00:00,000 INFO rotazione ieri"   > "$_FIX/undertow_access_log.2026-08-04.log"
echo "2026-08-03T12:00:00,000 INFO rotazione 2gg fa" > "$_FIX/undertow_access_log.2026-08-03.log"

_access_all=$(select_log_files_grouped "$_FIX" "" "" "undertow_access_log*")
_access_count=$(( $(grep -o '|' <<< "$_access_all" | wc -l) + 1 ))
assert_true "undertow_access_log: le 3 rotazioni giornaliere si raggruppano in UN nome logico" \
    "$([[ "$_access_count" -eq 3 ]] && echo 1 || echo 0)"

# Finestra interamente DOPO il ts_start del file corrente (12:00): deve
# fermarsi lì senza scendere alla rotazione di ieri. Una finestra che inizia
# a mezzanotte non sarebbe un caso valido — il file corrente non la coprirebbe
# per intero e il walk scenderebbe correttamente (principio 5, conservativo).
_access_win=$(select_log_files_grouped "$_FIX" "2026-08-05T13:00" "2026-08-05T23:59" "undertow_access_log*")
_access_win_count=$(( $(grep -o '|' <<< "$_access_win" | wc -l) + 1 ))
[[ -z "$_access_win" ]] && _access_win_count=0
assert_true "undertow_access_log: finestra dopo l'inizio del corrente non scende alla rotazione di ieri" \
    "$([[ "$_access_win_count" -eq 1 ]] && echo 1 || echo 0)"

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

# ─── Feedback progressivo: visibile con TTY, assente senza, mai su stdout ─────
section "Feedback progressivo (progress_show, utils-log.sh)"

# Questa è la superficie che nessun altro test può vedere: tutte le asserzioni
# altrove catturano sotto $(...), dove stderr NON è un TTY e progress_show
# ritorna subito. Qui si simula un terminale con `script -qec` per verificare
# che il feedback esista davvero quando l'utente è interattivo.
_PROG_FIX="$(mktemp -d)"
echo "2026-08-05T10:00:00,000 INFO riga" > "$_PROG_FIX/app.log"
gzip -c <(echo "2026-08-04T10:00:00,000 INFO rotazione") > "$_PROG_FIX/app.log-2026-08-04-1785800000.gz"

# Senza TTY (cattura normale): nessun carattere di progresso.
_no_tty=$(select_log_files_grouped "$_PROG_FIX" "" "" "app*" 2>&1 >/dev/null)
assert_true "senza TTY: nessun output di progresso su stderr" \
    "$([[ -z "$_no_tty" ]] && echo 1 || echo 0)"

# Con TTY simulato: il marcatore ⋯ deve comparire.
if command -v script >/dev/null 2>&1; then
    _tty_out=$(script -qec "bash -c '
        source \"$ROOT_DIR/lib/utils-logfiles.sh\"
        select_log_files_grouped \"$_PROG_FIX\" \"\" \"\" \"app*\" > /dev/null
    '" /dev/null 2>&1)
    assert_true "con TTY: il marcatore di progresso '⋯' compare" \
        "$([[ "$_tty_out" == *"⋯"* ]] && echo 1 || echo 0)"
    assert_true "con TTY: il progresso nomina il file in selezione" \
        "$([[ "$_tty_out" == *"selezione log"* ]] && echo 1 || echo 0)"

    # Il progresso non deve MAI finire su stdout: è la superficie su cui
    # asseriscono i test dei tool (principio 3 di CLAUDE.md).
    _tty_stdout=$(script -qec "bash -c '
        source \"$ROOT_DIR/lib/utils-logfiles.sh\"
        select_log_files_grouped \"$_PROG_FIX\" \"\" \"\" \"app*\" 2>/dev/null
    '" /dev/null)
    assert_true "con TTY: nessun marcatore di progresso su stdout" \
        "$([[ "$_tty_stdout" != *"⋯"* ]] && echo 1 || echo 0)"

    # BOT_PROGRESS=off deve silenziare anche con TTY.
    _tty_off=$(script -qec "bash -c '
        export BOT_PROGRESS=off
        source \"$ROOT_DIR/lib/utils-logfiles.sh\"
        select_log_files_grouped \"$_PROG_FIX\" \"\" \"\" \"app*\" > /dev/null
    '" /dev/null 2>&1)
    assert_true "BOT_PROGRESS=off: nessun progresso anche con TTY" \
        "$([[ "$_tty_off" != *"⋯"* ]] && echo 1 || echo 0)"
else
    printf "  ${DIM}SKIP  test con TTY simulato: 'script' non disponibile${RESET}\n"
fi
rm -rf "$_PROG_FIX"

# ─── _logfiles_read_first_ts: i formati timestamp riconosciuti ───────────────
section "_logfiles_read_first_ts: 5 formati (TS-1, 2026-08-17)"

# Il timestamp del primo record decide se un file rientra nella finestra
# temporale: un formato non riconosciuto dà ts=0, e il pruning conservativo
# (principio 5) include TUTTE le rotazioni — nessun dato perso, ma nessun filtro.
# Trovato montando usnext, dove Pass.log usa la data europea DD-MM-YYYY.
_TS_FIX="$(mktemp -d)"
printf '172.30.85.133 [17/Aug/2026:10:00:00 +0200] "GET / HTTP/1.1" 200 1 0 - -\n' > "$_TS_FIX/access.log"
printf '[2026-08-17T10:00:00.527+0200][1486515.012s][info][gc,start] GC(1) Pause\n'  > "$_TS_FIX/gc.log"
printf '2026-08-17 10:00:00,303 INFO  [classe] messaggio\n'                          > "$_TS_FIX/server.log"
printf '[thread] USER 2026-08-17T10:00:00,443 INFO messaggio\n'                      > "$_TS_FIX/custom_iso.log"
printf '17-08-2026 10:00:00.071 INFO  HttpRestClient chiamata\n'                     > "$_TS_FIX/custom_eu.log"

# Tutti e cinque descrivono lo STESSO istante: se un formato è riconosciuto
# correttamente l'epoch deve coincidere, non solo essere diverso da zero.
_expect_ts=$(date -d "2026-08-17 10:00:00" +%s)
for _f in access gc server custom_iso custom_eu; do
    assert_eq "$_f.log → epoch del 2026-08-17 10:00" \
        "$_expect_ts" "$(_logfiles_read_first_ts "$_TS_FIX/$_f.log")"
done

# Una data DD-MM-YYYY a METÀ riga non è il timestamp del record: in un log
# assicurativo è più probabilmente un dato applicativo (scadenza polizza, data
# sinistro). L'ancora ^ nel pattern lo garantisce — senza, la selezione dei file
# verrebbe falsata da un campo di business.
printf 'INFO polizza con scadenza 31-12-2027 rinnovata\n' > "$_TS_FIX/business.log"
assert_eq "data DD-MM-YYYY a metà riga ignorata (non è il timestamp del record)" \
    "0" "$(_logfiles_read_first_ts "$_TS_FIX/business.log")"

# Formato del tutto sconosciuto → 0, e il chiamante includerà il file per
# prudenza invece di escluderlo (principio 5).
printf 'nessun timestamp qui\n' > "$_TS_FIX/ignoto.log"
assert_eq "formato ignoto → 0 (il chiamante include per prudenza)" \
    "0" "$(_logfiles_read_first_ts "$_TS_FIX/ignoto.log")"

# Il pruning ora discrimina: con una finestra interamente coperta dal file
# corrente, la rotazione non va aperta. Prima del 5° pattern ne selezionava 2.
printf '17-08-2026 10:00:00.000 riga di oggi\n' > "$_TS_FIX/Pass.log"
printf '01-08-2026 10:00:00.000 riga vecchia\n' | gzip -c > "$_TS_FIX/Pass.log-2026-08-01-1785000000.gz"
_sel=$(select_log_files_grouped "$_TS_FIX" "2026-08-17T10:30" "2026-08-17T11:00" "Pass*")
assert_eq "finestra coperta dal corrente: la rotazione non viene aperta" \
    "1" "$(echo "$_sel" | tr '|' '\n' | grep -c . )"

rm -rf "$_TS_FIX"

# ─── discover_log_dirs: scoperta ricorsiva delle directory con log ────────────
section "discover_log_dirs (LOGDISC-2)"

# Emette DIRECTORY, non file: chi la chiama passa ognuna a
# select_log_files_grouped, che resta flat perché le rotazioni stanno accanto al
# file che ruotano — ricorsione per la scoperta, flat per le rotazioni.
_DL_FIX="$(mktemp -d)"
mkdir -p "$_DL_FIX/prod/ClaimCenter" "$_DL_FIX/ClaimCenter/Guidewire" \
         "$_DL_FIX/weird/deep/nested" "$_DL_FIX/archive.log" "$_DL_FIX/senza_log" \
         "$_DL_FIX/solo_rotazioni"
# Directory con 3 file dello stesso log: deve comparire UNA volta sola.
echo x > "$_DL_FIX/prod/ClaimCenter/server.log"
echo x > "$_DL_FIX/prod/ClaimCenter/server.log-2026-08-01-1785000000.gz"
echo x > "$_DL_FIX/prod/ClaimCenter/undertow_access_log.2026-07-14.log"
echo x > "$_DL_FIX/ClaimCenter/Guidewire/cc.log"
echo x > "$_DL_FIX/weird/deep/nested/custom_app.log"
# Trappola: directory il cui NOME finisce per .log, ma non è un file.
echo x > "$_DL_FIX/archive.log/non_e_un_file.txt"
# Directory senza alcun log: non va emessa.
echo x > "$_DL_FIX/senza_log/readme.txt"
# Solo rotazioni compresse, nessun .log corrente: va scoperta comunque
# (principio 5 — escluderla sarebbe un falso negativo silenzioso).
echo x > "$_DL_FIX/solo_rotazioni/vecchio.log-2026-07-01-1780000000.gz"

_dl_out=$(discover_log_dirs "$_DL_FIX")
_dl_n=$(echo "$_dl_out" | grep -c .)

assert_eq "discover_log_dirs: 4 directory con log (dedup su più rotazioni)" "4" "$_dl_n"

assert_true "discover_log_dirs: directory profonda arbitraria scoperta" \
    "$([[ "$_dl_out" == *"weird/deep/nested"* ]] && echo 1 || echo 0)"

assert_true "discover_log_dirs: directory con SOLE rotazioni .gz scoperta" \
    "$([[ "$_dl_out" == *"solo_rotazioni"* ]] && echo 1 || echo 0)"

assert_true "discover_log_dirs: 'archive.log/' (directory, non file) non scoperta" \
    "$([[ "$_dl_out" != *"archive.log"* ]] && echo 1 || echo 0)"

assert_true "discover_log_dirs: directory senza log non scoperta" \
    "$([[ "$_dl_out" != *"senza_log"* ]] && echo 1 || echo 0)"

# La directory con 3 file dello stesso log compare una volta, non tre.
_dl_cc=$(echo "$_dl_out" | grep -c "prod/ClaimCenter$")
assert_eq "discover_log_dirs: directory con 3 file emessa una sola volta" "1" "$_dl_cc"

# Casi limite: root inesistente o argomento vuoto non devono produrre output
# né errori (il chiamante itera su stdout, una riga spuria diventerebbe un path).
assert_eq "discover_log_dirs: root inesistente → nessun output" "0" \
    "$(discover_log_dirs "$_DL_FIX/non_esiste" | grep -c . || true)"
assert_eq "discover_log_dirs: argomento vuoto → nessun output" "0" \
    "$(discover_log_dirs "" | grep -c . || true)"

rm -rf "$_DL_FIX"

# ─── resolve_app_from_path: attribuzione dell'app dal path ────────────────────
section "resolve_app_from_path (LOGDISC-2)"

# Data-driven da AVAILABLE_APPS: nessun nome di app nel codice (principio 7).
# Centralizzata da una copia inline che viveva in _find_named_log_elsewhere
# (dispatch.sh), ora migrata a chiamarla (principio 8).
AVAILABLE_APPS=("ClaimCenter" "ContactManager")

assert_eq "resolve_app_from_path: app riconosciuta nel path" "ClaimCenter" \
    "$(resolve_app_from_path "/logs/nodo/prod/ClaimCenter/server.log")"
assert_eq "resolve_app_from_path: seconda app riconosciuta" "ContactManager" \
    "$(resolve_app_from_path "/logs/nodo/prod/ContactManager/server.log")"
assert_eq "resolve_app_from_path: riconosce l'app anche a metà path" "ClaimCenter" \
    "$(resolve_app_from_path "/logs/nodo/ClaimCenter/Guidewire/cc.log")"

# Path non attribuibile: nessun output e return 1 — il chiamante lo etichetta
# come ignoto ma NON esclude il file (principio 5).
_ra_out=$(resolve_app_from_path "/logs/nodo/weird/deep/nested/custom.log" && echo "MATCHED")
assert_eq "resolve_app_from_path: path non attribuibile → vuoto" "" "$_ra_out"

# Match sul SEGMENTO, non sulla sottostringa: "ClaimCenterX" non è "ClaimCenter".
assert_eq "resolve_app_from_path: match sul segmento, non sul prefisso" "" \
    "$(resolve_app_from_path "/logs/nodo/ClaimCenterX/server.log" || true)"

assert_eq "resolve_app_from_path: path vuoto → vuoto" "" \
    "$(resolve_app_from_path "" || true)"

# ─── logfiles_coverage_note (RETENT-1) ────────────────────────────────────────
section "logfiles_coverage_note: finestra non coperta / non verificabile"

# Finestra ben PRIMA della rotazione più vecchia disponibile (2026-08-02T06:00):
# il walk backward esaurisce tutte le rotazioni di "policysearch" senza mai
# trovare un ts_start <= TIME_FROM — è esattamente il caso che RETENT-1 apre
# (il for si esaurisce senza break, e prima non ne restava traccia).
_rc_uncovered=$(select_log_files_grouped "$_FIX" "2026-08-01T00:00" "" "policysearch*")
_rc_note=$(logfiles_coverage_note "$_rc_uncovered" "2026-08-01T00:00")
assert_true "finestra non coperta: la nota compare" \
    "$([[ -n "$_rc_note" ]] && echo 1 || echo 0)"
assert_true "finestra non coperta: nomina l'ora da cui i dati sono disponibili" \
    "$([[ "$_rc_note" == *"dati disponibili solo da 2026-08-02 06:00"* ]] && echo 1 || echo 0)"
assert_true "finestra non coperta: usa il marcatore '~', non '?'" \
    "$([[ "$_rc_note" == *"  ~ "* && "$_rc_note" != *"?"* ]] && echo 1 || echo 0)"

# Finestra interamente coperta (già usata sopra per il test sul walk): nessuna
# riga da stampare — un dato completo non va dichiarato incompleto.
_rc_covered_note=$(logfiles_coverage_note "$_win_policysearch" "2026-08-04T10:00")
assert_eq "finestra coperta: nessuna nota" "" "$_rc_covered_note"

# Senza TIME_FROM non c'è una finestra da confrontare: nessuna nota, anche con
# una selezione che potrebbe apparire incompleta.
_rc_no_tf=$(logfiles_coverage_note "$_all_policysearch" "")
assert_eq "TIME_FROM vuoto: nessuna nota" "" "$_rc_no_tf"

# File senza timestamp riconoscibile (noise.log, ts_start=0): non si può
# affermare né "coperta" né "non coperta" (principio 5) — si dichiara il
# terzo esito, distinto dal precedente.
_rc_unverif=$(logfiles_coverage_note "$_FIX/noise.log" "2026-08-01T00:00")
assert_true "timestamp non riconoscibile: la nota compare" \
    "$([[ -n "$_rc_unverif" ]] && echo 1 || echo 0)"
assert_true "timestamp non riconoscibile: usa il marcatore '?', non '~'" \
    "$([[ "$_rc_unverif" == *"  ? "* && "$_rc_unverif" != *"~"* ]] && echo 1 || echo 0)"
assert_true "timestamp non riconoscibile: nomina il file" \
    "$([[ "$_rc_unverif" == *"noise.log"* ]] && echo 1 || echo 0)"

# Due gruppi, un solo esito: solo il gruppo NON coperto va dichiarato, quello
# coperto resta silenzioso nella stessa nota.
_rc_mixed=$(logfiles_coverage_note "$_FIX/cc.log $_FIX/srv.log" "2026-08-05T10:00")
assert_true "gruppi misti: dichiara solo il gruppo scoperto (srv, 20:00)" \
    "$([[ "$_rc_mixed" == *"dati disponibili solo da 2026-08-05 20:00"* ]] && echo 1 || echo 0)"
assert_true "gruppi misti: non nomina cc.log (coperto)" \
    "$([[ "$_rc_mixed" != *"cc.log"* ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
