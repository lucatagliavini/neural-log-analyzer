#!/bin/bash
#
# test-node-resolve.sh — canonicalizzazione del numero di nodo e dichiarazione
# della sostituzione quando il nodo richiesto non esiste.
#
# Regressione coperta (bug trovato in produzione il 2026-08-27): i nodi 08 e 09
# rispondevano coi dati del nodo 01, in silenzio. `printf "%02d" 09` fallisce
# come ottale non valido DOPO aver scritto "00" su stdout, e la vecchia forma
#   NODE_NUM=$(printf "%02d" "$NODE_NUM" 2>/dev/null || echo "$NODE_NUM")
# non sostituiva il valore ma lo appendeva all'output parziale: "0009". Da lì
# NODE_NAME=lxprjbliq0009, directory inesistente, fallback muto sul primo nodo.
#
# I due test che contano davvero, e perché:
#
#   1. IDEMPOTENZA. È ciò che rendeva il bug intermittente e quindi difficile da
#      attribuire: chatbot.sh canonicalizza a "09" (correttamente), e se la query
#      contiene una finestra temporale scatta ctx_changed=1 → una SECONDA
#      risoluzione, che riceveva il "09" già impaginato — il solo valore su cui
#      si rompeva. Query senza finestra temporale: funzionava. Con: nodo 01.
#      Una funzione non idempotente qui è un bug a comparsa condizionata.
#
#   2. LA SOSTITUZIONE VA DICHIARATA. Il fallback su un altro nodo restituisce
#      dati autentici, solo del nodo sbagliato: indistinguibile da una risposta
#      corretta. È il motivo per cui il difetto è passato inosservato, quindi il
#      silenzio è parte del bug e va testato come tale.
#
# Uso: bash tests/test-node-resolve.sh
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

export BOT_LOG_LEVEL="off"

# ─── Fixture: albero con i nodi 01, 07, 08, 09, 12 ────────────────────────────
# 07 è il controllo che isola l'ottale: unico vicino di 08 che è cifra ottale
# valida, quindi funzionava anche prima del fix. Se un giorno 07 passa e 08 no,
# la causa è di nuovo la base numerica e non la scoperta su filesystem.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
for n in 01 07 08 09 12; do mkdir -p "$FIX/prod/lxprjbliq$n/ClaimCenter/Guidewire"; done

export PROFILE_DIR="$ROOT_DIR/profiles/liquido"
# LOG_BASE_DIR e non solo il primo argomento: il fallback di resolve-logs.sh
# scopre i nodi con list_env_node_dirs(), che legge LOG_BASE_DIR — mentre il
# percorso principale usa l'argomento $1. Senza questo export il fallback
# cercherebbe nell'albero di produzione e il test non potrebbe esercitarlo.
export LOG_BASE_DIR="$FIX"

# node_num_canonical() non richiede configurazione: si sorgia utils-nodes.sh da
# solo, senza dispatch.sh, così un fallimento qui accusa questa funzione e non
# l'intera catena di sourcing.
source "$LIB/utils-nodes.sh"

_canon() { node_num_canonical "$1" 2>/dev/null || echo "<rifiutato>"; }

section "node_num_canonical: forma a due cifre"
assert_eq "cifra nuda 9 → 09"                  "09" "$(_canon 9)"
assert_eq "cifra nuda 8 → 08"                  "08" "$(_canon 8)"
assert_eq "già impaginato 09 → 09 (non 0009)"   "09" "$(_canon 09)"
assert_eq "già impaginato 08 → 08 (non 0008)"   "08" "$(_canon 08)"
assert_eq "07 resta 07 (controllo ottale)"      "07" "$(_canon 07)"
assert_eq "due cifre 12 → 12"                  "12" "$(_canon 12)"
assert_eq "spazi ignorati"                      "09" "$(_canon ' 9 ')"

section "node_num_canonical: input non validi rifiutati, non inventati"
assert_eq "non numerico → rifiutato"     "<rifiutato>" "$(_canon abc)"
assert_eq "vuoto → rifiutato"            "<rifiutato>" "$(_canon '')"
assert_eq "misto → rifiutato"            "<rifiutato>" "$(_canon 9x)"

section "node_num_canonical: idempotenza (il bug era alla SECONDA risoluzione)"
for n in 1 7 8 9 12; do
    once=$(_canon "$n"); twice=$(_canon "$once")
    assert_eq "canon(canon($n)) == canon($n)" "$once" "$twice"
done

section "node_num_from_dir: contratto invariato dopo la migrazione"
assert_eq "lxprjbliq09 → 09"        "09" "$(node_num_from_dir /logs/prod/lxprjbliq09)"
assert_eq "lxprjbliq08 → 08"        "08" "$(node_num_from_dir /logs/prod/lxprjbliq08)"
assert_eq "lxprjbliq5 → 05"         "05" "$(node_num_from_dir /logs/prod/lxprjbliq5)"
assert_eq "senza cifre → vuoto"     ""   "$(node_num_from_dir /logs/prod/nodo-senza-numero)"

# ─── list_env_nodes: l'appaiamento numero↔directory in un punto solo (SCOPE-1) ──
#
# Copre la funzione da cui passano ORA due consumatori — search_all_logs.sh e il
# motore multi-nodo di dispatch — dopo che l'appaiamento è stato togliuto dal
# tool. Senza queste asserzioni la suite passerebbe anche con la funzione rotta:
# gli altri test la esercitano solo di rimbalzo, attraverso il fallback di
# resolve-logs.sh, che guarda `| head -1` e quindi non noterebbe un numero
# sbagliato sulle righe successive — cioè proprio il difetto di NODE-1.
#
# `list_env_node_dirs` (e quindi `list_env_nodes`) legge ENV_NODE_CODE e
# NODE_NAME_TEMPLATE da system.conf. Sorgiarlo qui NON sovrascrive la fixture:
# il profilo scrive `LOG_BASE_DIR="${LOG_BASE_DIR:-…}"`, quindi rispetta il
# valore già esportato sopra — verificato, non assunto.
source "$PROFILE_DIR/system.conf"

section "list_env_nodes: coppie DIR<TAB>NUM appaiate correttamente"
_pairs=$(list_env_nodes prod)
assert_eq "una riga per nodo della fixture" "5" "$(wc -l <<< "$_pairs")"
# L'appaiamento, nodo per nodo: è il contratto che NODE-1 ha violato in silenzio.
while IFS= read -r _n; do
    assert_eq "nodo $_n appaiato alla propria directory" \
        "$FIX/prod/lxprjbliq$_n"$'\t'"$_n" \
        "$(grep -F "lxprjbliq$_n" <<< "$_pairs")"
done <<< $'01\n07\n08\n09\n12'
# Coerenza col produttore: stessa cardinalità di list_env_node_dirs, altrimenti
# la coppia sta perdendo o duplicando nodi.
assert_eq "cardinalità uguale a list_env_node_dirs" \
    "$(list_env_node_dirs prod | wc -l)" "$(wc -l <<< "$_pairs")"

section "list_env_nodes: un nodo senza numero è emesso, non scartato"
# Principio 5: escluderlo farebbe sparire i suoi log senza dirlo. Creata QUI e
# non nella fixture in testa al file, così le asserzioni precedenti restano
# esercitate sull'albero originale.
mkdir -p "$FIX/prod/lxprjbliqBIS/ClaimCenter"
_pairs2=$(list_env_nodes prod)
assert_eq "emesso con NUM vuoto" "$FIX/prod/lxprjbliqBIS"$'\t' \
    "$(grep -F "lxprjbliqBIS" <<< "$_pairs2")"
assert_eq "il conteggio cresce di uno" "6" "$(wc -l <<< "$_pairs2")"

# L'asserzione che cattura il difetto trovato al primo giro di questo test: con
# l'ordine NUM<TAB>DIR il TAB iniziale di un NUM vuoto viene scartato da `read`
# (TAB è IFS whitespace), il PATH finisce nel primo campo e il secondo resta
# vuoto — quindi il chiamante, che salta le righe senza directory, ignorava il
# nodo in SILENZIO. Qui si verifica la proprietà dal punto di vista di chi legge,
# non della stringa emessa: è l'unico modo di accorgersene.
_letto_dir="" _letto_num="sentinella"
while IFS=$'\t' read -r _d _n; do
    [[ "$_d" == *lxprjbliqBIS ]] && { _letto_dir="$_d"; _letto_num="$_n"; }
done < <(list_env_nodes prod)
assert_eq "chi legge riceve la directory nel primo campo" \
    "$FIX/prod/lxprjbliqBIS" "$_letto_dir"
assert_eq "chi legge riceve NUM vuoto, senza scivolamento" "" "$_letto_num"

section "list_env_nodes: il separatore TAB regge un path con spazi"
# Non è uno scenario realistico ma una PROPRIETÀ del contratto: il separatore non
# deve poter essere rotto dal contenuto. Con lo spazio come separatore questa
# riga si spezzerebbe in due campi e il path arriverebbe troncato al chiamante.
mkdir -p "$FIX/prod/lxprjbliq20 bis/ClaimCenter"
_dir_letto=""
while IFS=$'\t' read -r _d _n; do
    [[ "$_d" == *"20 bis" ]] && _dir_letto="$_d"
done < <(list_env_nodes prod)
assert_eq "path con spazio integro dopo la lettura" "$FIX/prod/lxprjbliq20 bis" "$_dir_letto"
rm -rf "$FIX/prod/lxprjbliqBIS" "$FIX/prod/lxprjbliq20 bis"

# ─── resolve-logs.sh end-to-end ───────────────────────────────────────────────
_resolve_field() {
    local node="$1" field="$2" out
    out=$("$LIB/resolve-logs.sh" "$FIX" prod "$node" ClaimCenter 2>/dev/null) || { echo "<errore>"; return; }
    grep "^${field}=" <<< "$out" | cut -d"'" -f2
}

section "resolve-logs.sh: il nodo richiesto è quello risolto"
for n in 01 07 08 09 12; do
    assert_eq "richiesto $n → risolto $n" "$n" "$(_resolve_field "$n" ACTIVE_NODE)"
done
assert_eq "richiesto 9 (nudo) → risolto 09"  "09" "$(_resolve_field 9 ACTIVE_NODE)"
assert_eq "richiesto 8 (nudo) → risolto 08"  "08" "$(_resolve_field 8 ACTIVE_NODE)"

section "resolve-logs.sh: LOG_SEARCH_ROOT punta al nodo giusto"
assert_eq "nodo 09 → directory lxprjbliq09" \
    "$FIX/prod/lxprjbliq09" "$(_resolve_field 09 LOG_SEARCH_ROOT)"
assert_eq "nodo 08 → directory lxprjbliq08" \
    "$FIX/prod/lxprjbliq08" "$(_resolve_field 08 LOG_SEARCH_ROOT)"

section "resolve-logs.sh: la sostituzione di nodo è dichiarata"
assert_eq "nodo esistente → nessun avviso"        ""     "$(_resolve_field 09 NODE_FALLBACK_FROM)"
assert_eq "nodo inesistente → avviso col valore"  "99"   "$(_resolve_field 99 NODE_FALLBACK_FROM)"
assert_eq "nodo inesistente → ripiega sul primo"  "01"   "$(_resolve_field 99 ACTIVE_NODE)"
assert_eq "non numerico → avviso col valore"      "abc"  "$(_resolve_field abc NODE_FALLBACK_FROM)"
assert_eq "non numerico → ripiega sul primo"      "01"   "$(_resolve_field abc ACTIVE_NODE)"

# L'avviso finisce in una stringa che chatbot.sh passa a `eval`: un apice
# singolo non sanitizzato romperebbe l'eval (o eseguirebbe codice).
section "resolve-logs.sh: il valore dell'avviso è sanitizzato per l'eval"
_inj="9';touch $FIX/PWNED;'"
_out=$("$LIB/resolve-logs.sh" "$FIX" prod "$_inj" ClaimCenter 2>/dev/null)
eval "$_out" >/dev/null 2>&1 || true
assert_eq "nessun apice nel valore emesso" "" \
    "$(grep "^NODE_FALLBACK_FROM=" <<< "$_out" | cut -d"'" -f2 | tr -cd "'")"
assert_eq "l'eval non ha eseguito nulla" "assente" \
    "$([[ -e "$FIX/PWNED" ]] && echo presente || echo assente)"

printf "\n${BOLD}Risultato:${RESET} ${GREEN}%d PASS${RESET}, " "$pass"
if [[ "$fail" -gt 0 ]]; then
    printf "${RED}${BOLD}%d FAIL${RESET}\n" "$fail"; exit 1
else
    printf "%d FAIL\n" "$fail"; exit 0
fi
