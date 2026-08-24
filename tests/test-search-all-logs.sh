#!/bin/bash
#
# test-search-all-logs.sh — unit test per lib/tools/search_all_logs.sh.
#
# Copre l'allineamento della tabella nodo/log, che era rotto in due modi
# indipendenti (bug reale, 2026-08-05):
#   1. Nodo singolo: la colonna "NODO" non era prevista dall'header (guardava
#      DETECTED_NODE) ma le righe la stampavano comunque (guardavano "$_n non
#      vuoto" — sempre vero, perché ACTIVE_NODE ha un default in chatbot.sh).
#   2. Multi-nodo: l'header usava una larghezza fissa (9 char) che si sarebbe
#      disallineata con numeri di nodo a 3+ cifre.
# Il fix introduce _multi_node come unica fonte di verità e una larghezza
# colonna calcolata dai dati reali — questi test verificano che le due
# proprietà (colonna assente in nodo singolo, larghezza coerente in multi-nodo)
# valgano sull'output effettivo del tool, non sulla sua implementazione interna.
#
# Copre anche il filtro temporale riga per riga (bug reale, 2026-08-05):
# select_log_files() filtra solo a livello di FILE (include un file se il suo
# intervallo si sovrappone al range richiesto), non riga per riga. Un
# server.log non ruotato copre l'intera giornata, quindi "ultime 2 ore"
# restituiva anche match fuori da quella finestra. Verificato scartando le
# righe il cui timestamp non rientra in [TIME_FROM, TIME_TO].
#
# Uso: bash tests/test-search-all-logs.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Fixture: struttura minima LOG_BASE_DIR/env/nodo/env/app + Guidewire ──────
_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

_mk_node() {
    local node_num="$1"
    local node_dir="$_FIX/prod/lxprjbliq${node_num}"
    mkdir -p "$node_dir/prod/ClaimCenter" "$node_dir/ClaimCenter/Guidewire"
    echo "2026-08-05T10:00:00 INFO searchhub call" > "$node_dir/prod/ClaimCenter/server.log"
    echo "2026-08-05T10:00:00 searchHub in cc" > "$node_dir/ClaimCenter/Guidewire/cc.log"
}
_mk_node "04"
_mk_node "12"

export LOG_BASE_DIR="$_FIX"
export SEARCH_PATTERN="searchhub"
export SEARCH_PARALLEL_JOBS=2
export ACCESS_LOG_BASE="undertow_access_log" SERVER_LOG_BASE="server" GC_LOG_BASE="gc"
export CUSTOM_LOG_SUBPATH='$APP/Guidewire'
# APP_SUBPATH non è più esportata: dopo LOGDISC-2 il tool scopre le directory
# sotto il nodo e non costruisce path da template. Tenerla qui darebbe
# l'impressione che serva ancora al contratto (CLEAN-1).
export NODE_NAME_TEMPLATE='lx${ENV_CODE}jbliq${NODE_NUM}'
export ACTIVE_ENV="prod" ACTIVE_APP="ClaimCenter"
export PROFILE_DIR="$ROOT_DIR/profiles/liquido"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Nodo singolo: nessuna colonna nodo, nessun DIM permanente ────────────────
section "Nodo singolo (DETECTED_NODE impostato)"

unset DETECTED_NODE
export DETECTED_NODE="04" ACTIVE_NODE="04"
# LOG_SEARCH_ROOT deve puntare al NODO, non a $_FIX: da LOGDISC-2 la scoperta è
# ricorsiva, e $_FIX contiene ANCHE il nodo 12 (fixture condivisa con la sezione
# multi-nodo) — puntarlo lì farebbe leakage fra le due sezioni, lo stesso
# problema già risolto isolando le fixture di test-dispatch-perf.sh.
export LOG_SEARCH_ROOT="$_FIX/prod/lxprjbliq04"

_out_single=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)

_has_nodo_header=0
echo "$_out_single" | grep -qE '^\s*NODO\s+LOG' && _has_nodo_header=1
assert_true "nodo singolo: header non mostra colonna NODO" "$(( 1 - _has_nodo_header ))"

_has_nodo_prefix=0
echo "$_out_single" | grep -qE '^\s*nodo [0-9]' && _has_nodo_prefix=1
assert_true "nodo singolo: righe non hanno prefisso 'nodo NN'" "$(( 1 - _has_nodo_prefix ))"

# LOG deve essere la prima parola non-spazio della riga header (colonna 0, non 9)
_log_col_ok=0
echo "$_out_single" | grep -qE '^\s*LOG\s+MATCH' && _log_col_ok=1
assert_true "nodo singolo: 'LOG' è la prima colonna dell'header" "$_log_col_ok"

# ─── Multi-nodo: colonna NODO presente e allineata alle righe ─────────────────
section "Multi-nodo (DETECTED_NODE vuoto, ACTIVE_ENV noto)"

# In multi-nodo la scoperta parte da ogni NODE_DIR trovato da list_env_node_dirs,
# quindi LOG_SEARCH_ROOT (che è del nodo attivo) non serve e va rimossa.
unset DETECTED_NODE ACTIVE_NODE LOG_SEARCH_ROOT

_out_multi=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)

_hdr_line=$(echo "$_out_multi" | grep -E '^\s*NODO\s+LOG' | head -1)
_row_line=$(echo "$_out_multi" | grep -E '^\s*nodo [0-9]+' | head -1)

assert_true "multi-nodo: header mostra colonna NODO" "$([[ -n "$_hdr_line" ]] && echo 1 || echo 0)"
assert_true "multi-nodo: almeno una riga con prefisso 'nodo NN'" "$([[ -n "$_row_line" ]] && echo 1 || echo 0)"

# La colonna "LOG" nell'header e il filename nelle righe devono iniziare alla
# stessa posizione di colonna — è esattamente il bug: header calcolava una
# larghezza fissa (9), le righe una diversa (lunghezza reale di "nodo NN  ").
if [[ -n "$_hdr_line" && -n "$_row_line" ]]; then
    _hdr_log_pos=$(echo "$_hdr_line" | grep -boE 'LOG' | head -1 | cut -d: -f1)
    # Nelle righe dati, il filename inizia subito dopo "nodo NN  " (dim/colore
    # già stripped) — trova la posizione del primo carattere alfanumerico dopo
    # il numero di nodo e gli spazi di padding.
    _row_log_pos=$(echo "$_row_line" | grep -boE '[A-Za-z0-9._-]+\.log' | head -1 | cut -d: -f1)
    assert_true "multi-nodo: colonna LOG allineata fra header e righe (hdr=$_hdr_log_pos riga=$_row_log_pos)" \
        "$([[ "$_hdr_log_pos" -eq "$_row_log_pos" ]] && echo 1 || echo 0)"
else
    assert_true "multi-nodo: colonna LOG allineata (righe non trovate, salto)" 0
fi

# ─── LOGDISC-2: scoperta ricorsiva e colonna APP ──────────────────────────────
section "Ricorsione sotto il nodo + colonna APP (LOGDISC-2)"

# Prima di LOGDISC-2 il tool costruiva 4 path fissi da APP_SUBPATH/CUSTOM_LOG_SUBPATH,
# quindi: (a) un log in una directory arbitraria era invisibile pur essendo
# nominabile con tail_named_log — l'ultima asimmetria dopo LOGDISC-1; (b) cercava
# solo nell'app di sessione, mentre il tool si chiama search_ALL_logs.
_FIX8="$(mktemp -d)"
_node8_dir="$_FIX8/prod/lxprjbliq04"
mkdir -p "$_node8_dir/prod/ClaimCenter" "$_node8_dir/ClaimCenter/Guidewire" \
         "$_node8_dir/prod/ContactManager" "$_node8_dir/weird/deep/nested" \
         "$_node8_dir/archive.log" "$_node8_dir/senza_log"
echo "2026-08-05T10:00:00,000 INFO searchhub in claimcenter" > "$_node8_dir/prod/ClaimCenter/server.log"
echo "2026-08-05T10:00:00,000 INFO searchhub in guidewire"   > "$_node8_dir/ClaimCenter/Guidewire/cc.log"
echo "2026-08-05T10:00:00,000 INFO searchhub in contactmanager" > "$_node8_dir/prod/ContactManager/server.log"
echo "2026-08-05T10:00:00,000 INFO searchhub in posto arbitrario" > "$_node8_dir/weird/deep/nested/custom_app.log"
# Trappole: una directory che SEMBRA un file .log, e una senza log.
echo "non sono un log" > "$_node8_dir/archive.log/non_e_un_file.txt"
echo "irrilevante" > "$_node8_dir/senza_log/readme.txt"

export LOG_BASE_DIR="$_FIX8"
export DETECTED_NODE="04" ACTIVE_NODE="04" ACTIVE_APP="ClaimCenter"
export LOG_SEARCH_ROOT="$_node8_dir"
export SEARCH_PATTERN="searchhub"
unset TIME_FROM TIME_TO

_out_rec=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)

# (a) il gap di LOGDISC-2: il log in directory arbitraria è cercato
_has_arbitrary=0
echo "$_out_rec" | grep -qE '^\s.*custom_app\.log' && _has_arbitrary=1
assert_true "ricorsione: log in directory arbitraria (weird/deep/nested) è cercato" "$_has_arbitrary"

# (b) cerca in TUTTE le app, non solo in ACTIVE_APP=ClaimCenter
_rec_total=$(echo "$_out_rec" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "ricorsione: match in tutte le app, non solo ACTIVE_APP (totale: ${_rec_total:-?}, atteso 4)" \
    "$([[ "${_rec_total:-0}" -eq 4 ]] && echo 1 || echo 0)"

_has_other_app=0
echo "$_out_rec" | grep -qE '^\s.*ContactManager' && _has_other_app=1
assert_true "ricorsione: i log di un'altra app compaiono (ACTIVE_APP non filtra)" "$_has_other_app"

# (c) la colonna APP dichiara la provenienza (principio 6: mai mescolare in silenzio)
_hdr_app=$(echo "$_out_rec" | grep -E '^\s*APP\s+LOG' | head -1)
assert_true "colonna APP: header presente quando i match sono di più app" \
    "$([[ -n "$_hdr_app" ]] && echo 1 || echo 0)"

# Allineamento con la stessa tecnica del test multi-nodo: byte-offset di LOG
# nell'header vs nome file nelle righe. Se _app_col_w divergesse fra header e
# righe, la tabella si disallineerebbe come nel bug del 2026-08-05.
_row_app=$(echo "$_out_rec" | grep -E '^\s+(ClaimCenter|ContactManager|-)\s' | head -1)
if [[ -n "$_hdr_app" && -n "$_row_app" ]]; then
    _h_pos=$(echo "$_hdr_app" | grep -boE 'LOG' | head -1 | cut -d: -f1)
    _r_pos=$(echo "$_row_app" | grep -boE '[A-Za-z0-9._-]+\.log' | head -1 | cut -d: -f1)
    assert_true "colonna APP: LOG allineato fra header e righe (hdr=$_h_pos riga=$_r_pos)" \
        "$([[ "$_h_pos" -eq "$_r_pos" ]] && echo 1 || echo 0)"
else
    assert_true "colonna APP: LOG allineato (righe non trovate, salto)" 0
fi

# (d) path non attribuibile: etichetta "-", MA il file resta nei risultati
# (principio 5 — escluderlo sarebbe un bug di correttezza, non si inventa un'app)
_has_dash_app=0
echo "$_out_rec" | grep -qE '^\s+-\s+custom_app\.log' && _has_dash_app=1
assert_true "colonna APP: path non attribuibile etichettato '-', non escluso" "$_has_dash_app"

# (e) le trappole non producono file da cercare: 4 file, non 5 o 6
_rec_files=$(echo "$_out_rec" | grep -oE '\([0-9]+ file' | grep -oE '[0-9]+' | head -1)
assert_true "ricorsione: 'archive.log/' (directory) e dir senza log ignorate (file: ${_rec_files:-?}, atteso 4)" \
    "$([[ "${_rec_files:-0}" -eq 4 ]] && echo 1 || echo 0)"

rm -rf "$_FIX8"

# ─── Colonna APP assente quando i match sono di una sola app ──────────────────
section "Colonna APP condizionale (una sola app nei match)"

# Stesso criterio di _multi_node: se non c'è nulla da disambiguare la colonna non
# appare, altrimenti sarebbe lo stesso valore ripetuto su ogni riga.
_FIX9="$(mktemp -d)"
_node9_dir="$_FIX9/prod/lxprjbliq04"
mkdir -p "$_node9_dir/prod/ClaimCenter"
echo "2026-08-05T10:00:00,000 INFO searchhub uno" > "$_node9_dir/prod/ClaimCenter/server.log"
echo "2026-08-05T10:00:00,000 INFO searchhub due" > "$_node9_dir/prod/ClaimCenter/gc.log"

export LOG_BASE_DIR="$_FIX9" LOG_SEARCH_ROOT="$_node9_dir"
export DETECTED_NODE="04" ACTIVE_NODE="04"
_out_oneapp=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
rm -rf "$_FIX9"

_has_app_hdr=0
echo "$_out_oneapp" | grep -qE '^\s*APP\s+LOG' && _has_app_hdr=1
assert_true "una sola app: header NON mostra la colonna APP" "$(( 1 - _has_app_hdr ))"

_log_first=0
echo "$_out_oneapp" | grep -qE '^\s*LOG\s+MATCH' && _log_first=1
assert_true "una sola app: 'LOG' resta la prima colonna dell'header" "$_log_first"

# ─── Intervallo dei match su log NON ordinato cronologicamente ───────────────
section "PRIMO/ULTIMO MATCH: minimo e massimo, non primo e ultimo incontrati"

# Segnalato dall'utente il 2026-08-17: sulla tabella di `cerca "exception" in
# produzione` alcune righe mostravano ULTIMO MATCH *precedente* a PRIMO MATCH —
# es. `Pass.log.2026-08-17.2` con 12:31:14 │ 10:55:59, impossibile per costruzione.
#
# Causa: il codice prendeva "il primo e l'ultimo timestamp INCONTRATI", assumendo
# righe in ordine cronologico. Vero per access log e server log (append-only
# sequenziali), NON per un log applicativo multi-thread come Pass.log di usnext,
# dove thread concorrenti scrivono nell'ordine in cui il buffer viene svuotato.
#
# Difetto latente da sempre: si è manifestato solo quando è stato montato il primo
# profilo con un log di quel tipo.
_FIX10="$(mktemp -d)"
_node10="$_FIX10/prod/lxprjbliq04"
mkdir -p "$_node10/prod/ClaimCenter"

# Righe deliberatamente FUORI ordine, come le scrive un logger multi-thread.
cat > "$_node10/prod/ClaimCenter/server.log" <<'EOF'
2026-08-17 12:31:14,000 ERROR exception tardiva scritta prima
2026-08-17 10:55:59,000 ERROR exception precoce scritta dopo
2026-08-17 11:20:00,000 ERROR exception intermedia
EOF

export LOG_BASE_DIR="$_FIX10" LOG_SEARCH_ROOT="$_node10"
export DETECTED_NODE="04" ACTIVE_NODE="04" ACTIVE_APP="ClaimCenter"
export SEARCH_PATTERN="exception"
unset TIME_FROM TIME_TO

_out_unord=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_row=$(echo "$_out_unord" | grep -E '^\s+server\.log' | head -1)

# Il PRIMO match deve essere il più ANTICO (10:55:59), non quello incontrato prima.
assert_true "log non ordinato: PRIMO MATCH è il timestamp minimo (10:55:59)" \
    "$([[ "$_row" == *"10:55:59"* ]] && echo 1 || echo 0)"

# E l'intervallo deve essere coerente: primo <= ultimo, sempre.
_first=$(echo "$_row" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
_last=$(echo "$_row"  | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1)
assert_true "log non ordinato: PRIMO MATCH <= ULTIMO MATCH ($_first <= $_last)" \
    "$([[ "$_first" < "$_last" || "$_first" == "$_last" ]] && echo 1 || echo 0)"
assert_true "  e l'ULTIMO è il massimo (12:31:14), non l'ultimo incontrato" \
    "$([[ "$_last" == *"12:31:14"* ]] && echo 1 || echo 0)"

# Su un log ORDINATO il risultato deve restare identico: il fix non cambia il caso
# comune (access log, server log), altrimenti sarebbe una regressione.
cat > "$_node10/prod/ClaimCenter/server.log" <<'EOF'
2026-08-17 09:00:00,000 ERROR exception A
2026-08-17 10:00:00,000 ERROR exception B
2026-08-17 11:00:00,000 ERROR exception C
EOF
_out_ord=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_row_ord=$(echo "$_out_ord" | grep -E '^\s+server\.log' | head -1)
assert_true "log ordinato: intervallo invariato (09:00:00 → 11:00:00)" \
    "$([[ "$_row_ord" == *"09:00:00"* && "$_row_ord" == *"11:00:00"* ]] && echo 1 || echo 0)"

rm -rf "$_FIX10"
unset LOG_SEARCH_ROOT
# Ripristina lo stato per le sezioni successive: questa ha cambiato
# SEARCH_PATTERN, e la prossima si aspetta ancora "searchhub" — il test seguente
# è fallito alla prima stesura proprio per questo (stato non isolato, lo stesso
# tipo di leakage già corretto nelle fixture di LOGDISC-1/2).
export SEARCH_PATTERN="searchhub"

# ─── Filtro temporale riga per riga ────────────────────────────────────────
section "Filtro temporale (TIME_FROM/TIME_TO applicato riga per riga)"

_FIX2="$(mktemp -d)"
_node2_dir="$_FIX2/prod/lxprjbliq04"
mkdir -p "$_node2_dir/prod/ClaimCenter" "$_node2_dir/ClaimCenter/Guidewire"
# 4 righe in server.log: 2 fuori dal range 16:00-16:59, 2 dentro.
cat > "$_node2_dir/prod/ClaimCenter/server.log" <<'EOF'
2026-08-05 06:21:38,000 INFO searchhub call fuori range
2026-08-05 10:10:30,000 INFO searchhub call fuori range
2026-08-05 16:00:00,000 INFO searchhub call dentro range
2026-08-05 16:30:00,000 INFO searchhub call dentro range
EOF

export LOG_BASE_DIR="$_FIX2"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node2_dir"
export TIME_FROM="2026-08-05T16:00" TIME_TO="2026-08-05T16:59"

_out_time=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
rm -rf "$_FIX2"
unset TIME_FROM TIME_TO

# La riga server.log deve riportare 2 MATCH (non 4): le due righe fuori range
# vanno scartate anche se il file, nel suo complesso, si sovrappone al range.
_match_count=$(echo "$_out_time" | grep -E '^\s*server\.log' | grep -oE '[0-9]+' | head -1)
assert_true "filtro temporale: solo 2 dei 4 match sono nel range (trovati: ${_match_count:-?})" \
    "$([[ "${_match_count:-0}" -eq 2 ]] && echo 1 || echo 0)"

# Nessuna riga fuori range deve comparire come PRIMO/ULTIMO MATCH.
_has_out_of_range_ts=0
echo "$_out_time" | grep -qE '06:21:38|10:10:30' && _has_out_of_range_ts=1
assert_true "filtro temporale: nessun timestamp fuori range nell'output" "$(( 1 - _has_out_of_range_ts ))"

# ─── Filtro temporale su righe senza timestamp proprio (stack trace) ─────────
section "Filtro temporale: righe di stack trace ereditano il timestamp dell'eccezione"

# Bug reale (2026-08-05): "cerca searchHub" matcha anche "at ...SearchHubExtApi..."
# nello stack trace per puro caso testuale (case-insensitive). Quella riga non ha
# un timestamp proprio: prima del fix veniva SEMPRE mantenuta, anche quando
# l'eccezione a cui appartiene (con il suo vero timestamp) è fuori dal range
# richiesto — risultato: MATCH>0 ma PRIMO/ULTIMO MATCH vuoti ("-").
_FIX3="$(mktemp -d)"
_node3_dir="$_FIX3/prod/lxprjbliq04"
mkdir -p "$_node3_dir/prod/ClaimCenter" "$_node3_dir/ClaimCenter/Guidewire"
cat > "$_node3_dir/ClaimCenter/Guidewire/policysearch.log" <<'EOF'
                2026-08-05T10:27:38,925 ERROR SEARCHHUB: fuori range
	at it.unipol.sx.bo.SearchHubExtApi.searchHubSxApi(SearchHubExtApi.gs:163)
	at it.unipol.sx.bo.SearchHubExtApi$block_0_.invoke(SearchHubExtApi.gs:196)
                2026-08-05T16:30:00,000 ERROR SEARCHHUB: dentro range
	at it.unipol.sx.bo.SearchHubExtApi.searchHubSxApi(SearchHubExtApi.gs:200)
	at it.unipol.sx.bo.SearchHubExtApi$block_0_.invoke(SearchHubExtApi.gs:210)
EOF

export LOG_BASE_DIR="$_FIX3"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node3_dir"
export SEARCH_PATTERN="searchHub"
export TIME_FROM="2026-08-05T16:00" TIME_TO="2026-08-05T16:59"

_out_stack=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
rm -rf "$_FIX3"
unset TIME_FROM TIME_TO

# 3 righe nel range (l'eccezione delle 16:30 + i suoi 2 frame): non 5 (tutte).
_match_count3=$(echo "$_out_stack" | grep -E '^\s*policysearch\.log' | grep -oE '[0-9]+' | head -1)
assert_true "stack trace: solo le 3 righe dell'eccezione in range sono contate (trovate: ${_match_count3:-?})" \
    "$([[ "${_match_count3:-0}" -eq 3 ]] && echo 1 || echo 0)"

# La riga fuori range (10:27) non deve comparire come timestamp nell'output.
_has_out_of_range3=0
echo "$_out_stack" | grep -q '10:27:38' && _has_out_of_range3=1
assert_true "stack trace: timestamp fuori range (10:27) non nell'output" "$(( 1 - _has_out_of_range3 ))"

# PRIMO/ULTIMO MATCH devono essere popolati (non "-"): i frame senza timestamp
# proprio devono ereditare quello dell'eccezione in range, non restare vuoti.
_has_dash_ts=0
echo "$_out_stack" | grep -E '^\s*policysearch\.log' | grep -qE '│\s+-\s+│' && _has_dash_ts=1
assert_true "stack trace: PRIMO/ULTIMO MATCH popolati (non '-')" "$(( 1 - _has_dash_ts ))"

# ─── Rotazioni .gz in directory flat (log applicativi custom) devono essere raggiungibili ─
section "Rotazioni .gz nella directory flat (bug: mai lette, 2026-08-06)"

# Bug reale: il ramo BASE="" di _sal_add (usato per i log applicativi custom, directory flat
# senza basename uniforme) filtra i candidati con `grep -v "[0-9]\{10\}"` per
# escludere le rotazioni con epoch nel nome (es. tenute fuori dalla lista dei
# "named log" ambigui) — ma quello stesso filtro scarta ANCHE le rotazioni con
# epoch usate da search_all_logs per la ricerca storica, quindi "cerca X ieri"
# non può mai vedere il contenuto delle rotazioni: silenziosamente incompleto,
# non un errore visibile. Qui: solo la rotazione .gz contiene un match dentro
# il range richiesto, il file corrente ne è privo.
_FIX4="$(mktemp -d)"
_node4_dir="$_FIX4/prod/lxprjbliq04"
mkdir -p "$_node4_dir/prod/ClaimCenter" "$_node4_dir/ClaimCenter/Guidewire"
echo "2026-08-05T18:00:00,000 INFO nessun match qui" > "$_node4_dir/ClaimCenter/Guidewire/policysearch.log"
_gz_src=$(mktemp)
echo "2026-08-04T12:00:00,000 ERROR searchHub in rotazione storica" > "$_gz_src"
gzip -c "$_gz_src" > "$_node4_dir/ClaimCenter/Guidewire/policysearch.log-2026-08-04-1785000000.gz"
rm -f "$_gz_src"

export LOG_BASE_DIR="$_FIX4"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node4_dir"
export SEARCH_PATTERN="searchHub"
export TIME_FROM="2026-08-04T00:00" TIME_TO="2026-08-04T23:59"

_out_gzrot=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
rm -rf "$_FIX4"
unset TIME_FROM TIME_TO

_has_gzrot_file=0
echo "$_out_gzrot" | grep -qE '^\s*policysearch\.log-2026-08-04' && _has_gzrot_file=1
assert_true "rotazione .gz: il file compare nella tabella dei log cercati" "$_has_gzrot_file"

_gzrot_total=$(echo "$_out_gzrot" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "rotazione .gz: il match nella rotazione storica è trovato (totale: ${_gzrot_total:-?})" \
    "$([[ "${_gzrot_total:-0}" -eq 1 ]] && echo 1 || echo 0)"

# ─── Pre-gate letterale: non deve perdere match con pattern regex ─────────────
section "Pre-gate grep -qiF (ottimizzazione I/O, 2026-08-06)"

# Il gate salta l'analisi gawk sui file dove grep -qiF non trova il pattern
# letterale. È corretto SOLO per pattern letterali: con metacaratteri ERE
# l'utente intende una regex, e `grep -F` la cercherebbe alla lettera —
# scartando file che contengono match reali. Il guard deve rilevarli e
# saltare il gate. Un falso negativo qui è invisibile all'utente (MATCH=0
# senza errori), quindi va asserito su entrambi i rami.
_FIX6="$(mktemp -d)"
_node6_dir="$_FIX6/prod/lxprjbliq04"
mkdir -p "$_node6_dir/prod/ClaimCenter" "$_node6_dir/ClaimCenter/Guidewire"
cat > "$_node6_dir/ClaimCenter/Guidewire/app.log" <<'EOF'
2026-08-06T10:00:00,000 INFO codice ABC123 elaborato
2026-08-06T10:01:00,000 INFO codice XYZ789 elaborato
2026-08-06T10:02:00,000 ERROR timeout su servizio
EOF

export LOG_BASE_DIR="$_FIX6"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node6_dir"
unset TIME_FROM TIME_TO

# (a) pattern letterale presente → gate attivo, match trovato
SEARCH_PATTERN="ABC123" _out_lit=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_lit_n=$(echo "$_out_lit" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "pattern letterale: match trovato con gate attivo (trovati: ${_lit_n:-0})" \
    "$([[ "${_lit_n:-0}" -eq 1 ]] && echo 1 || echo 0)"

# (b) pattern letterale assente → gate scarta il file, 0 match (nessun falso positivo)
SEARCH_PATTERN="QQQNONESISTE" _out_none=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
assert_true "pattern letterale assente: nessun match (gate non inventa risultati)" \
    "$([[ "$_out_none" == *"Nessuna occorrenza"* ]] && echo 1 || echo 0)"

# (c) REGEX con metacaratteri → il gate va SALTATO, i match devono essere trovati.
# "ABC[0-9]+" come stringa letterale non esiste nel file: se il gate non
# venisse saltato, grep -F non lo troverebbe e il file sarebbe scartato →
# 0 match invece di 1. Questo è il test che protegge dal falso negativo.
SEARCH_PATTERN="ABC[0-9]+" _out_re=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_re_n=$(echo "$_out_re" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "pattern regex 'ABC[0-9]+': match trovato (gate saltato correttamente)" \
    "$([[ "${_re_n:-0}" -eq 1 ]] && echo 1 || echo 0)"

# (d) regex con alternanza: due match su righe diverse
SEARCH_PATTERN="ABC123|XYZ789" _out_alt=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_alt_n=$(echo "$_out_alt" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "pattern regex con alternanza: entrambi i match trovati (trovati: ${_alt_n:-0})" \
    "$([[ "${_alt_n:-0}" -eq 2 ]] && echo 1 || echo 0)"

# (e) il gate è case-insensitive come gawk (IGNORECASE=1): non deve divergere
SEARCH_PATTERN="abc123" _out_ci=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>&1 | _strip_ansi)
_ci_n=$(echo "$_out_ci" | grep -oE 'Totale:\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_true "pattern letterale minuscolo su testo maiuscolo: match trovato (gate case-insensitive)" \
    "$([[ "${_ci_n:-0}" -eq 1 ]] && echo 1 || echo 0)"

rm -rf "$_FIX6"
export SEARCH_PATTERN="searchHub"

# (f) EQUIVALENZA dei due percorsi sull'eredità del timestamp. Con gate attivo
# gawk riceve il file UNA volta con gated=1 (salta la passata di rilevamento,
# già fatta da grep); senza gate ne riceve due. I due percorsi DEVONO dare lo
# stesso risultato, incluso il caso dello stack trace del 2026-08-05: le righe
# senza timestamp proprio ereditano quello dell'eccezione, e l'eccezione fuori
# range va scartata coi suoi frame. Se divergessero, il fix di ieri sarebbe
# regredito solo sul percorso ottimizzato — invisibile senza questo confronto.
_FIX7="$(mktemp -d)"
cat > "$_FIX7/t.log" <<'EOF'
                2026-08-05T10:27:38,925 ERROR SEARCHHUB: fuori range
	at it.unipol.sx.bo.SearchHubExtApi.searchHubSxApi(SearchHubExtApi.gs:163)
	at it.unipol.sx.bo.SearchHubExtApi$block_0_.invoke(SearchHubExtApi.gs:196)
                2026-08-05T16:30:00,000 ERROR SEARCHHUB: dentro range
	at it.unipol.sx.bo.SearchHubExtApi.searchHubSxApi(SearchHubExtApi.gs:200)
	at it.unipol.sx.bo.SearchHubExtApi$block_0_.invoke(SearchHubExtApi.gs:210)
EOF
gzip -c "$_FIX7/t.log" > "$_FIX7/t.log.gz"
_AWKT="$ROOT_DIR/lib/tools/search_all_logs.awk"
_TIME_AWK="$ROOT_DIR/lib/utils-time.awk"
_LOGLINE_AWK="$ROOT_DIR/lib/utils-logline.awk"
_TF="2026-08-05 16:00:00"; _TT="2026-08-05 16:59:59"
# 5° campo = unfiltered (SRCH-5). Qui un filtro È attivo (_TF/_TT sopra) e il log
# ha timestamp riconoscibili su tutte le righe: quindi 0 è un'asserzione con un
# contenuto, non un riempitivo — dice che nulla è sfuggito al filtro.
_EXPECT="3|2026-08-05 16:30:00|2026-08-05 16:30:00|0|0"

_r_gated=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX7/t.log")
_r_2pass=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX7/t.log" "$_FIX7/t.log")
_r_gz_gated=$(gzip -dc "$_FIX7/t.log.gz" | gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT")
_r_gz_2pass=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" <(gzip -dc "$_FIX7/t.log.gz") <(gzip -dc "$_FIX7/t.log.gz"))
rm -rf "$_FIX7"

assert_true "gated=1 (plain): eredità stack trace corretta ($_r_gated)" \
    "$([[ "$_r_gated" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "due passate (plain): stesso risultato di gated=1" \
    "$([[ "$_r_2pass" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "gated=1 (.gz): eredità stack trace corretta" \
    "$([[ "$_r_gz_gated" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "due passate (.gz): stesso risultato di gated=1" \
    "$([[ "$_r_gz_2pass" == "$_EXPECT" ]] && echo 1 || echo 0)"

# ─── Intervento 3: timestamp parziale (solo-ora) ───────────────────────────────
section "PRIMO/ULTIMO MATCH con timestamp parziale (console.log, TS-1/LOGDISC-4)"

# File interamente solo-ora (console.log del profilo usnext: nessuna riga porta
# una data). Il min/max deve cadere sull'orario e il 4° campo deve marcarlo
# "parziale" (1) — prima di Intervento 3 questo file dava "-|-" muto pur avendo
# MATCH > 0 (bug #4).
_FIX8="$(mktemp -d)"
cat > "$_FIX8/console.log" <<'EOF'
01:00:00,000 INFO  searchHub avvio
10:03:37,273 ERROR searchHub timeout
23:51:02,500 WARN  searchHub lento
EOF

_r_time=$(gawk -v pat="searchHub" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX8/console.log")
assert_true "file solo-ora: min/max sull'orario, partial=1 ($_r_time)" \
    "$([[ "$_r_time" == "3|01:00:00|23:51:02|1|0" ]] && echo 1 || echo 0)"

# File MISTO (righe datate + righe solo-ora, es. una riga di continuazione senza
# timestamp proprio che eredita comunque "solo ora" da un file diverso da quello
# della fixture (f)). Il datato deve vincere per intero: partial=0, e il minimo
# NON deve cadere sulla riga solo-ora anche se "23:51:02" ordinerebbe DOPO
# "14:30:29" per stringa — i due binari (dated/solo-ora) restano separati anche
# quando convivono nello stesso file, non solo fra file diversi come in (f) sopra.
cat > "$_FIX8/mixed.log" <<'EOF'
01:00:00,000 INFO  searchHub avvio solo ora
2026-08-18 09:15:00,000 ERROR searchHub datato
2026-08-18 14:30:29,000 WARN  searchHub datato2
23:51:02,500 WARN  searchHub lento solo ora
EOF

_r_mixed=$(gawk -v pat="searchHub" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX8/mixed.log")
assert_true "file misto: il datato vince e non si mescola col solo-ora ($_r_mixed)" \
    "$([[ "$_r_mixed" == "4|2026-08-18 09:15:00|2026-08-18 14:30:29|0|0" ]] && echo 1 || echo 0)"

rm -rf "$_FIX8"

# ─── SRCH-5: occorrenze incluse ma NON filtrabili per data ────────────────────
section "SRCH-5: filtro temporale su log JSON e dichiarazione del non filtrabile"

# Il difetto: una riga il cui timestamp non è riconoscibile viene INCLUSA
# (principio 5) ma il filtro non la valuta — e prima veniva contata in silenzio.
# Misurato in produzione il 2026-08-24: 61 occorrenze riportate contro 4
# corrette su una query filtrata per oggi, cioè 15,25×.
_FIX9="$(mktemp -d)"
_AWKT="$ROOT_DIR/lib/tools/search_all_logs.awk"
_TIME_AWK="$ROOT_DIR/lib/utils-time.awk"
_LOGLINE_AWK="$ROOT_DIR/lib/utils-logline.awk"

# (a) Log JSON su due giorni: ora che la grammatica lo riconosce (SRCH-5), il
#     filtro deve ESCLUDERE la riga fuori finestra. È la riproduzione minima del
#     difetto da 15,25×: prima entrambe le righe venivano contate.
cat > "$_FIX9/kpi.log" <<'EOF'
{"UpdateTime":"2026-08-15 10:00:00.352","DocUID":"VECCHIA","EventType":"MOVE_TO_QUEUE"}
{"UpdateTime":"2026-08-24 11:00:00.352","DocUID":"OGGI","EventType":"MOVE_TO_QUEUE"}
EOF
_r_json=$(gawk -v pat="MOVE_TO_QUEUE" -v tf="2026-08-24 00:00:00" -v tt="2026-08-24 23:59:59" \
    -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX9/kpi.log")
assert_true "JSON: la riga fuori finestra è esclusa, unfiltered=0 ($_r_json)" \
    "$([[ "$_r_json" == "1|2026-08-24 11:00:00|2026-08-24 11:00:00|0|0" ]] && echo 1 || echo 0)"

# (b) Log SENZA alcun timestamp riconoscibile + filtro attivo: le righe restano
#     incluse (principio 5) ma vanno DICHIARATE.
cat > "$_FIX9/nots.log" <<'EOF'
riga senza timestamp con MOVE_TO_QUEUE dentro
altra riga con MOVE_TO_QUEUE
EOF
_r_nots=$(gawk -v pat="MOVE_TO_QUEUE" -v tf="2026-08-24 00:00:00" -v tt="2026-08-24 23:59:59" \
    -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX9/nots.log")
assert_true "senza timestamp + filtro: incluse (2) e dichiarate (unfiltered=2) ($_r_nots)" \
    "$([[ "$_r_nots" == "2|||0|2" ]] && echo 1 || echo 0)"

# (c) Lo STESSO file senza filtro: unfiltered=0. Non c'è nulla da dichiarare se
#     non è stata chiesta una finestra — altrimenti la nota sarebbe rumore su
#     ogni ricerca non filtrata.
_r_nofilter=$(gawk -v pat="MOVE_TO_QUEUE" -v gated=1 \
    -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX9/nots.log")
assert_true "senza filtro: unfiltered=0, niente da dichiarare ($_r_nofilter)" \
    "$([[ "$_r_nofilter" == "2|||0|0" ]] && echo 1 || echo 0)"

# (d) File MISTO. Attenzione, e la distinzione NON è accademica: "senza data" non
#     significa "non filtrabile". Una riga priva di timestamp EREDITA quello
#     dell'ultima riga datata vista (il meccanismo che tiene insieme una stack
#     trace con la sua eccezione, bug reale del 2026-08-05), quindi se una riga
#     datata la precede la riga È filtrabile e NON va dichiarata.
#     Non filtrabile è solo la riga che non ha nulla da cui ereditare: qui la
#     prima del file. Le due asserzioni sotto verificano entrambi gli ordini —
#     senza la seconda, il test misurerebbe l'eredità credendo di misurare il
#     contatore.
cat > "$_FIX9/misto_pre.log" <<'EOF'
riga senza timestamp con MOVE_TO_QUEUE, nulla da cui ereditare
2026-08-24 11:00:00,123 INFO  [c] MOVE_TO_QUEUE datata e in finestra
EOF
_r_pre=$(gawk -v pat="MOVE_TO_QUEUE" -v tf="2026-08-24 00:00:00" -v tt="2026-08-24 23:59:59" \
    -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX9/misto_pre.log")
assert_true "misto, non datata PRIMA: unfiltered=1 (nulla da ereditare) ($_r_pre)" \
    "$([[ "$_r_pre" == "2|2026-08-24 11:00:00|2026-08-24 11:00:00|0|1" ]] && echo 1 || echo 0)"

cat > "$_FIX9/misto_post.log" <<'EOF'
2026-08-24 11:00:00,123 INFO  [c] MOVE_TO_QUEUE datata e in finestra
	at qualcosa.MOVE_TO_QUEUE(File.java:1)
EOF
_r_post=$(gawk -v pat="MOVE_TO_QUEUE" -v tf="2026-08-24 00:00:00" -v tt="2026-08-24 23:59:59" \
    -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWKT" "$_FIX9/misto_post.log")
assert_true "misto, continuazione DOPO: unfiltered=0 (eredita, quindi filtrabile) ($_r_post)" \
    "$([[ "$_r_post" == "2|2026-08-24 11:00:00|2026-08-24 11:00:00|0|0" ]] && echo 1 || echo 0)"

rm -rf "$_FIX9"

# (e) Resa a schermo: marcatore "!" e nota. Senza questi il contatore esisterebbe
#     nel contratto e non raggiungerebbe l'utente — cioè il difetto resterebbe
#     silenzioso, che è esattamente ciò che si sta correggendo.
_FIX10="$(mktemp -d)"
_node10_dir="$_FIX10/prod/lxprjbliq04"
mkdir -p "$_node10_dir/ClaimCenter/Guidewire"
printf 'riga senza timestamp con searchHub dentro\n' \
    > "$_node10_dir/ClaimCenter/Guidewire/senzats.log"

export LOG_BASE_DIR="$_FIX10"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node10_dir"
export SEARCH_PATTERN="searchHub"
export TIME_FROM="2026-08-24T00:00" TIME_TO="2026-08-24T23:59"

_out10=$(bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>/dev/null | _strip_ansi)
unset TIME_FROM TIME_TO
rm -rf "$_FIX10"

# Radice "NON filtrat" per non dipendere dalla concordanza, che è verificata a
# parte dalle due asserzioni sotto.
assert_true "output: la nota '!' dichiara le occorrenze non filtrate" \
    "$([[ "$_out10" == *"NON filtrat"*"per data"* ]] && echo 1 || echo 0)"
# Concordanza al singolare: con UNA sola occorrenza la nota deve essere in
# italiano corretto ("1 occorrenza NON filtrata"), non "1 occorrenze NON filtrate".
assert_true "output: la nota nomina il numero e concorda al singolare" \
    "$([[ "$_out10" == *"! 1 occorrenza NON filtrata"* ]] && echo 1 || echo 0)"
assert_true "output: al singolare anche il resto della frase concorda" \
    "$([[ "$_out10" == *"è inclusa per prudenza e può cadere"* ]] && echo 1 || echo 0)"
assert_true "output: la riga porta il marcatore '!'" \
    "$(grep -qE 'senzats\.log.* 1 *!' <<< "$_out10" && echo 1 || echo 0)"
# La nota "!" e la nota "*" dicono cose diverse e non devono essere confuse: qui
# non c'è alcun timestamp, quindi la nota del solo-orario NON deve comparire.
assert_true "output: la nota '*' (solo orario) non compare quando non c'entra" \
    "$([[ "$_out10" != *"solo orario"* ]] && echo 1 || echo 0)"

# ─── Metriche di performance: contratto BOT_PERF_FILE ─────────────────────────
section "Metriche di performance (BOT_PERF_FILE)"

# Il tool scrive le proprie metriche di fase su BOT_PERF_FILE, che chatbot.sh
# sourcia per comporre le colonne 8-13 del query log. È un contratto fra due
# processi: se il tool smette di emettere una chiave, chatbot.sh logga 0 e
# l'analisi offline (perf-report.sh) mostra dati muti senza errori — un
# fallimento silenzioso, quindi va asserito.
_FIX5="$(mktemp -d)"
_node5_dir="$_FIX5/prod/lxprjbliq04"
mkdir -p "$_node5_dir/prod/ClaimCenter" "$_node5_dir/ClaimCenter/Guidewire"
echo "2026-08-06T10:00:00,000 INFO searchHub presente" > "$_node5_dir/ClaimCenter/Guidewire/cc.log"

export LOG_BASE_DIR="$_FIX5"
export DETECTED_NODE="04" ACTIVE_NODE="04"
export LOG_SEARCH_ROOT="$_node5_dir"
export SEARCH_PATTERN="searchHub"
_PERF_OUT="$(mktemp)"
export BOT_PERF_FILE="$_PERF_OUT"

bash "$ROOT_DIR/lib/tools/search_all_logs.sh" > /dev/null 2>&1
_perf_content=$(cat "$_PERF_OUT" 2>/dev/null)
unset BOT_PERF_FILE
rm -rf "$_FIX5"

for _k in PERF_TOOL PERF_SELECT_MS PERF_SEARCH_MS PERF_FILES PERF_FILES_MATCHED PERF_BYTES PERF_JOBS PERF_HITS; do
    assert_true "BOT_PERF_FILE contiene $_k" \
        "$([[ "$_perf_content" == *"${_k}="* ]] && echo 1 || echo 0)"
done

# I valori devono essere sensati, non solo presenti: un file con 1 match.
( eval "$_perf_content" 2>/dev/null
  [[ "${PERF_FILES:-0}" -ge 1 && "${PERF_HITS:-0}" -ge 1 && "${PERF_BYTES:-0}" -gt 0 ]] ) \
    && _perf_sane=1 || _perf_sane=0
assert_true "le metriche riportano valori plausibili (file>=1, hits>=1, bytes>0)" "$_perf_sane"

# Il file di metriche non deve MAI inquinare stdout (il tool ci scrive la tabella).
_perf_stdout=$(
    export LOG_BASE_DIR="$_FIX5" BOT_PERF_FILE="$_PERF_OUT"
    bash "$ROOT_DIR/lib/tools/search_all_logs.sh" 2>/dev/null
)
assert_true "nessuna riga PERF_* finisce su stdout" \
    "$([[ "$_perf_stdout" != *"PERF_"* ]] && echo 1 || echo 0)"
rm -f "$_PERF_OUT"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
