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
export APP_SUBPATH='$ENV_NAME/$APP'
export NODE_NAME_TEMPLATE='lx${ENV_CODE}jbliq${NODE_NUM}'
export ACTIVE_ENV="prod" ACTIVE_APP="ClaimCenter"
export PROFILE_DIR="$ROOT_DIR/profiles/liquido"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Nodo singolo: nessuna colonna nodo, nessun DIM permanente ────────────────
section "Nodo singolo (DETECTED_NODE impostato)"

unset DETECTED_NODE
export DETECTED_NODE="04" ACTIVE_NODE="04"
export SERVER_LOG_DIR="$_FIX/prod/lxprjbliq04/prod/ClaimCenter"
export SERVER_LOG="$SERVER_LOG_DIR/server.log"
export ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_FIX/prod/lxprjbliq04/ClaimCenter/Guidewire"

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

unset DETECTED_NODE ACTIVE_NODE SERVER_LOG_DIR SERVER_LOG ACCESS_LOG_DIR ACCESS_LOG GC_LOG_DIR GC_LOG CUSTOM_LOG_DIR

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
export SERVER_LOG_DIR="$_node2_dir/prod/ClaimCenter"
export SERVER_LOG="$SERVER_LOG_DIR/server.log"
export ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_node2_dir/ClaimCenter/Guidewire"
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
export SERVER_LOG_DIR="" SERVER_LOG=""
export ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_node3_dir/ClaimCenter/Guidewire"
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
export SERVER_LOG_DIR="" SERVER_LOG=""
export ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_node4_dir/ClaimCenter/Guidewire"
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
export SERVER_LOG_DIR="" SERVER_LOG="" ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_node6_dir/ClaimCenter/Guidewire"
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
_TF="2026-08-05 16:00:00"; _TT="2026-08-05 16:59:59"
_EXPECT="3|2026-08-05 16:30:00|2026-08-05 16:30:00"

_r_gated=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -v gated=1 -f "$_AWKT" "$_FIX7/t.log")
_r_2pass=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -f "$_AWKT" "$_FIX7/t.log" "$_FIX7/t.log")
_r_gz_gated=$(gzip -dc "$_FIX7/t.log.gz" | gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -v gated=1 -f "$_AWKT")
_r_gz_2pass=$(gawk -v pat="searchHub" -v tf="$_TF" -v tt="$_TT" -f "$_AWKT" <(gzip -dc "$_FIX7/t.log.gz") <(gzip -dc "$_FIX7/t.log.gz"))
rm -rf "$_FIX7"

assert_true "gated=1 (plain): eredità stack trace corretta ($_r_gated)" \
    "$([[ "$_r_gated" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "due passate (plain): stesso risultato di gated=1" \
    "$([[ "$_r_2pass" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "gated=1 (.gz): eredità stack trace corretta" \
    "$([[ "$_r_gz_gated" == "$_EXPECT" ]] && echo 1 || echo 0)"
assert_true "due passate (.gz): stesso risultato di gated=1" \
    "$([[ "$_r_gz_2pass" == "$_EXPECT" ]] && echo 1 || echo 0)"

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
export SERVER_LOG_DIR="" SERVER_LOG="" ACCESS_LOG_DIR="" ACCESS_LOG=""
export GC_LOG_DIR="" GC_LOG=""
export CUSTOM_LOG_DIR="$_node5_dir/ClaimCenter/Guidewire"
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
