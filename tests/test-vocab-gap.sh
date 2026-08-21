#!/bin/bash
#
# test-vocab-gap.sh — copertura di vocab-gap.sh e del ramo "gap vocabolario" di
# gap-report.sh. Prima del 2026-08-21 (GAPREP-1) era ZERO: nessun test in tests/
# toccava questi due script, ed è una delle ragioni per cui il report ha potuto
# restare inutilizzabile a lungo senza che nulla lo segnalasse.
#
# Cosa protegge, in ordine di importanza:
#
#   1. LO STADIO DELLA MISURA. I token vanno contati sul testo NORMALIZZATO, non
#      sul labeled grezzo: altrimenti il report dichiara "non coperti" i nomi di
#      log/app/nodo, che unigrams.txt VIETA per contratto (LOGF-3). È il difetto
#      originale, e un test che non lo copre lo lascerebbe rientrare.
#   2. IL CONTEGGIO CLASSI SU TUTTE LE ETICHETTE. Il dataset è multi-label: usare
#      solo la primaria sottostima la diffusione proprio sui token ambigui.
#   3. LA DEGRADAZIONE ONESTA. Senza python3 il report NON deve dichiarare
#      "nessun gap": deve dire che non ha misurato. Un falso verde è peggio di un
#      errore, perché nessuno va a controllare.
#
# Uso: bash tests/test-vocab-gap.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s ${DIM}(atteso '%s', ottenuto '%s')${RESET}\n" \
            "$desc" "$want" "$got"; fail=$(( fail + 1 ))
    fi
}
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "──────────────────"; }

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# Le sezioni 1-6 misurano l'output di vocab-gap.sh, che ha BISOGNO di un
# interprete Python (GAPREP-1). Su una macchina che non ne ha nessuno questo
# harness non può misurare — e "non misurabile" non è "fallito": senza questa
# guardia si vedrebbero sei FAIL che accusano il codice per una mancanza
# d'ambiente. È la stessa distinzione che gap-report.sh e test-normalize-parity.sh
# fanno con exit 2 (VENVGATE-1).
#
# Esce 2 e NON 0: uscire 0 lo farebbe contare fra i PASS da run-tests.sh, cioè un
# verde per un test che non è stato eseguito — precisamente il difetto corretto in
# GAPREP-1, reintrodotto dal test che lo protegge. Il chiamante distingue i tre
# esiti (0 PASS, 2 SKIP, altro FAIL).
source "$ROOT_DIR/lib/utils-python.sh"
if ! resolve_python >/dev/null 2>&1; then
    printf "\n${DIM}test-vocab-gap.sh: NON eseguito — nessun python3 disponibile.${RESET}\n"
    printf "${DIM}  Non è un fallimento: vocab-gap.sh richiede Python per normalizzare${RESET}\n"
    printf "${DIM}  il dataset allo stesso stadio delle feature (vedi GAPREP-1).${RESET}\n\n"
    exit 2
fi

# ─── Fixture ──────────────────────────────────────────────────────────────────
# system.conf/entities.conf REALI da liquido: servono gli alias veri (claimcenter,
# database.log) perché la normalizzazione è ciò che si sta testando — una fixture
# con entità inventate non proverebbe nulla sul comportamento vero.
# Gli artefatti NLP invece sono sintetici e minimi: nlp_resolve_paths() risolve
# PER SINGOLO ARTEFATTO con precedenza profilo → framework, quindi il profilo
# temporaneo può avere vocabolario, dataset e stopword propri.
_P="$_FIX/prof"
mkdir -p "$_P/dataset"
cp "$ROOT_DIR/profiles/liquido/system.conf"   "$_P/"
cp "$ROOT_DIR/profiles/liquido/entities.conf" "$_P/"
cp "$ROOT_DIR/profiles/liquido/domain.conf"   "$_P/"

# Vocabolario minimo: `errori` e `pause` sono COPERTI, tutto il resto no.
cat > "$_P/unigrams.txt" <<'EOF'
# fixture
errori                    :: 2
pause                     :: 1
EOF
cat > "$_P/bigrams.txt" <<'EOF'
# fixture
errori                       :: pause
EOF

cat > "$_P/report-stopwords.txt" <<'EOF'
# fixture
della
cosa
fare
EOF

# Dataset costruito perché ogni riga serva a una asserzione precisa.
#   claimcenter  → <APP>      (coordinata, deve sparire per normalizzazione)
#   database.log → <LOGFILE>  (idem)
#   impattano    → SOLO nella riga multi-label: classi=2 con la logica nuova,
#                  classi=1 con la vecchia (solo etichetta primaria)
#   della        → stopword, deve sparire pur superando la soglia
#   fallimenti   → content word, deve COMPARIRE (2 esempi)
printf '%s\n' \
'count_status	quanti errori su claimcenter' \
'count_status,filter_errors	errori che impattano molto' \
'filter_errors	segnala fallimenti della applicazione' \
'filter_errors	fallimenti gravi ripetuti' \
'show_help	cosa sai fare' \
'gc_stats	pause nel database.log' \
'gc_stats	pause del database.log ripetuti' \
> "$_P/dataset/queries_labeled.txt"

_VG="$ROOT_DIR/vocab-gap.sh"
_porcelain() { "$_VG" --profile "$_P" --min-count "${1:-1}" --top 0 --porcelain 2>/dev/null; }
_tok()       { _porcelain "${2:-1}" | awk -F'\t' -v t="$1" '$1==t {print; found=1} END{if(!found) print ""}'; }

# ─── 1. Lo stadio della misura: le coordinate spariscono ─────────────────────
section "Stadio normalizzato: le coordinate non sono candidati"

_out=$(_porcelain 1)
assert_true "'claimcenter' assente (normalizzato in <APP>)" \
    "$(awk -F'\t' '$1=="claimcenter"{f=1} END{print (f?0:1)}' <<< "$_out")"
assert_true "'database' assente (normalizzato in <LOGFILE>)" \
    "$(awk -F'\t' '$1=="database"{f=1} END{print (f?0:1)}' <<< "$_out")"
# Il placeholder spezzato sarebbe il falso gap più frequente in assoluto.
assert_true "'logfile' assente (il placeholder resta atomico, non si spezza)" \
    "$(awk -F'\t' '$1=="logfile"{f=1} END{print (f?0:1)}' <<< "$_out")"
assert_true "'<app>' assente (placeholder strutturale, mai nel vocabolario)" \
    "$(awk -F'\t' '$1=="<app>"{f=1} END{print (f?0:1)}' <<< "$_out")"

# ─── 2. Filtro parole funzionali ─────────────────────────────────────────────
section "Filtro stopword"

assert_true "'della' assente (in report-stopwords.txt del profilo)" \
    "$(awk -F'\t' '$1=="della"{f=1} END{print (f?0:1)}' <<< "$_out")"
assert_true "'cosa' assente (idem)" \
    "$(awk -F'\t' '$1=="cosa"{f=1} END{print (f?0:1)}' <<< "$_out")"

# ─── 3. Un content word non coperto DEVE comparire ───────────────────────────
section "Il candidato vero non viene perso"

assert_true "'fallimenti' presente (2 esempi, non coperto, non stopword)" \
    "$(awk -F'\t' '$1=="fallimenti"{f=1} END{print (f?1:0)}' <<< "$_out")"
assert_true "'errori' assente (coperto dal vocabolario della fixture)" \
    "$(awk -F'\t' '$1=="errori"{f=1} END{print (f?0:1)}' <<< "$_out")"

# ─── 4. Conteggio classi su TUTTE le etichette, non solo la primaria ─────────
section "Conteggio classi: multi-label"

# `impattano` vive SOLO in 'count_status,filter_errors'. Con la logica precedente
# (class = labels[1]) sarebbe 1 classe: è la mutazione che questo test intercetta.
_cls=$(awk -F'\t' '$1=="impattano"{print $2}' <<< "$_out")
assert_eq "'impattano' conta 2 classi (era 1 con la sola etichetta primaria)" "$_cls" "2"
_ex=$(awk -F'\t' '$1=="impattano"{print $3}' <<< "$_out")
assert_eq "'impattano' conta 1 esempio (una riga, due etichette)" "$_ex" "1"

# `ripetuti` compare in 2 righe con etichette diverse (filter_errors, gc_stats)
_cls2=$(awk -F'\t' '$1=="ripetuti"{print $2}' <<< "$_out")
assert_eq "'ripetuti' conta 2 classi su 2 righe distinte" "$_cls2" "2"
_ex2=$(awk -F'\t' '$1=="ripetuti"{print $3}' <<< "$_out")
assert_eq "'ripetuti' conta 2 esempi" "$_ex2" "2"

# ─── 5. Ordinamento per forza del candidato ──────────────────────────────────
section "Ordinamento: poche classi prima, poi piu esempi"

# La prima riga deve avere il minimo numero di classi presente nella lista.
_first_cls=$(head -1 <<< "$_out" | cut -f2)
_min_cls=$(cut -f2 <<< "$_out" | LC_ALL=C sort -n | head -1)
assert_eq "la prima riga ha il minimo numero di classi" "$_first_cls" "$_min_cls"

# Monotonia non decrescente della colonna classi su tutta la lista.
assert_true "la colonna CLASSI non decresce mai scorrendo la lista" \
    "$(cut -f2 <<< "$_out" | awk 'NR>1 && $1 < prev {bad=1} {prev=$1} END{print (bad?0:1)}')"

# A parità di classi, più esempi prima.
assert_true "a parita di classi, gli esempi non crescono" \
    "$(awk -F'\t' 'NR>1 && $2==pc && $3>pe {bad=1} {pc=$2; pe=$3} END{print (bad?0:1)}' <<< "$_out")"

# ─── 6. --top tronca la vista, non il porcelain ──────────────────────────────
section "--top e il contratto del porcelain"

_all_n=$(_porcelain 1 | grep -c . || true)
_top1=$("$_VG" --profile "$_P" --min-count 1 --top 1 --porcelain 2>/dev/null | grep -c . || true)
assert_eq "--porcelain IGNORA --top ed emette tutto" "$_top1" "$_all_n"

# Nella vista umana invece --top tronca, e il footer dichiara il totale: senza,
# l'utente crede che i candidati siano quelli mostrati.
_human=$("$_VG" --profile "$_P" --min-count 1 --top 2 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_true "la vista umana tronca a --top 2" \
    "$(grep -qE "Mostrati 2 di $_all_n candidati" <<< "$_human" && echo 1 || echo 0)"

# ─── 7. Degradazione senza python3: mai un falso verde ───────────────────────
section "Senza python3: dichiara di NON aver misurato"

# NLA_PYTHON verso un path inesistente, non un PATH svuotato.
#
# Lo svuotamento del PATH ha smesso di funzionare con VENVGATE-1 (2026-08-21):
# resolve_python() trova `.venv/bin/python3` per path ASSOLUTO, quindi il PATH non
# c'entra più — e infatti quel test dava exit 127 (un altro comando mancante nella
# fakebin), cioè verificava un guasto diverso da quello che credeva. L'override è
# deterministico e non dipende da quali binari la fixture ricorda di collegare.
export NLA_PYTHON="$_FIX/python3-che-non-esiste"
assert_true "con NLA_PYTHON inesistente, resolve_python non trova interpreti" \
    "$( (source "$ROOT_DIR/lib/utils-python.sh"; resolve_python >/dev/null 2>&1) && echo 0 || echo 1)"

_np_out=$("$_VG" --profile "$_P" 2>&1); _np_rc=$?
assert_eq "vocab-gap.sh esce 2 (non misurabile), non 0 ne 1" "$_np_rc" "2"
assert_true "il messaggio dice esplicitamente che la misura NON e stata eseguita" \
    "$(grep -qiE "NON . stata eseguita|non misur" <<< "$_np_out" && echo 1 || echo 0)"

_gr_out=$("$ROOT_DIR/gap-report.sh" --profile "$_P" --compact 2>&1 \
          | sed 's/\x1b\[[0-9;]*m//g'); _gr_rc=$?
assert_eq "gap-report.sh esce 0 (non deve abortire train.sh)" "$_gr_rc" "0"
assert_true "gap-report.sh dice 'NON misurato'" \
    "$(grep -qi "NON misurato" <<< "$_gr_out" && echo 1 || echo 0)"
# L'asserzione centrale del difetto: nessun verde per una misura mai avvenuta.
assert_true "gap-report.sh NON dichiara 'nessun gap/candidato'" \
    "$(grep -qiE "nessun (gap|candidato)" <<< "$_gr_out" && echo 0 || echo 1)"

# ─── 8. Stopword assenti o vuote: si degrada dicendolo ───────────────────────
# L'override va rimosso qui: da qui in poi Python serve davvero, e lasciarlo
# impostato farebbe fallire le asserzioni sotto per la ragione sbagliata.
unset NLA_PYTHON

section "report-stopwords.txt vuoto: filtro disattivato, dichiarato"

printf '# solo commenti\n\n' > "$_P/report-stopwords.txt"
_nosw=$("$_VG" --profile "$_P" --min-count 1 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_true "il report avverte che il filtro e DISATTIVATO" \
    "$(grep -qi "DISATTIVATO" <<< "$_nosw" && echo 1 || echo 0)"
assert_true "senza filtro 'della' torna a comparire (prova che filtrava lui)" \
    "$("$_VG" --profile "$_P" --min-count 1 --top 0 --porcelain 2>/dev/null \
       | awk -F'\t' '$1=="della"{f=1} END{print (f?1:0)}')"

# ─── Riepilogo ────────────────────────────────────────────────────────────────
printf "\n${DIM}%s${RESET}\n" "────────────────────────────────────────────────────────"
if [[ "$fail" -eq 0 ]]; then
    printf "${BOLD}test-vocab-gap.sh${RESET}  ${GREEN}%d PASS${RESET}  ${GREEN}0 FAIL${RESET}\n" "$pass"
else
    printf "${BOLD}test-vocab-gap.sh${RESET}  ${GREEN}%d PASS${RESET}  ${RED}${BOLD}%d FAIL${RESET}\n" "$pass" "$fail"
fi
[[ "$fail" -eq 0 ]]
