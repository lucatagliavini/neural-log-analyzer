#!/bin/bash
#
# test-vocab-format.sh — il formato del vocabolario e ciò che può esprimere (VOCFMT-1)
#
# Perché esiste. Fino al 2026-08-24 `query-to-features.sh` normalizzava il
# riempimento delle colonne con `${pattern// /}`, che cancellava OGNI spazio del
# pattern e non solo quello di allineamento. Le conseguenze erano due, opposte, ed
# entrambe SILENZIOSE:
#
#   scritto        caricato       effetto
#   ────────────   ───────────    ─────────────────────────────────────────────────
#   `(^| )ultim`   `(^|)ultim`    un ramo VUOTO nell'alternanza matcha la stringa
#                                 vuota in qualsiasi posizione: il vincolo di
#                                 confine SPARISCE, il pattern equivale a `ultim`
#   `ultima ora`   `ultimaora`    non può matchare NULLA: feature MORTA, sempre 0,
#                                 e continua a contare in NUM_FEATURES
#
# La seconda è la peggiore: un input permanentemente a zero nel modello, senza alcun
# errore, e chi ha scritto il pattern crede che funzioni.
#
# La normalizzazione vive ora in `nlp/tools.conf`, applicata una volta per file al
# `mapfile`, e tocca solo gli spazi ADIACENTI a `::` — che sono il riempimento e
# nient'altro.
#
# Il test usa un PROFILO TEMPORANEO con un vocabolario proprio, non quello reale:
# `nlp_resolve_paths()` sceglie il vocabolario del profilo se presente, e un
# vocabolario di tre pattern rende leggibile l'asserzione. Toccare quello reale
# cambierebbe NUM_FEATURES e richiederebbe un retrain.
#
# Uso: bash tests/test-vocab-format.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Profilo temporaneo con vocabolario proprio ────────────────────────────────
_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT
_PROF="$_FIX/profilo"
mkdir -p "$_PROF"
# I .conf del profilo reale servono perché domain.conf li sourcia; il vocabolario no.
cp "$ROOT_DIR/profiles/liquido/system.conf"   "$_PROF/"
cp "$ROOT_DIR/profiles/liquido/entities.conf" "$_PROF/"
cp "$ROOT_DIR/profiles/liquido/domain.conf"   "$_PROF/"

cat > "$_PROF/unigrams.txt" <<'EOF'
# Vocabolario di prova (VOCFMT-1). Tre pattern, uno per ciascun comportamento.
errore|errori             :: 2
(^| )ultim                :: 3
ultima ora                :: 5
EOF
cat > "$_PROF/bigrams.txt" <<'EOF'
# Un bigramma con uno spazio VOLUTO nel secondo lato: verifica che il trim del
# riempimento non lo mangi (il campo dopo `::` ha spazi iniziali di allineamento).
errore|errori             :: ultima ora                :: 7
EOF

# Vettore per una query, con il profilo di prova.
_vec() {
    ( export PROFILE_DIR="$_PROF"
      source "$ROOT_DIR/lib/nlp-paths.sh"
      nlp_resolve_paths "$PROFILE_DIR" >/dev/null 2>&1
      export NORM_QUERY="$1"
      "$ROOT_DIR/lib/query-to-features.sh" "$1" 2>/dev/null )
}

# ─── Guardia: il vettore deve esistere ────────────────────────────────────────
# Senza, ogni asserzione sotto confronterebbe due stringhe vuote e sarebbe verde per
# una verifica mai avvenuta — il difetto di GAPREP-1, e un errore già commesso una
# volta scrivendo i test di APOSTR-1.
section "Guardia anti-confronto-vacuo"
_probe="$(_vec "errori nell ultima ora")"
assert_eq "il vocabolario di prova produce un vettore" "si" \
    "$([[ -n "$_probe" ]] && echo si || echo no)"
assert_eq "  con 4 valori (3 unigrammi + 1 bigramma)" "4" \
    "$(wc -w <<< "$_probe")"

# ─── Spazio come CONFINE dentro un gruppo ─────────────────────────────────────
section "Uno spazio dentro un gruppo resta un confine"

# `(^| )ultim` deve distinguere l'elisione dallo spazio. Prima del fix il pattern
# diventava `(^|)ultim` e matchava entrambe, cioè il confine era inesistente.
assert_eq "con apostrofo: il confine ESCLUDE (feature 2 = 0)" "0" \
    "$(_vec "errori nell'ultima ora" | awk '{print $2}')"
assert_eq "con spazio: il confine AMMETTE (feature 2 = 3)" "3" \
    "$(_vec "errori nell ultima ora" | awk '{print $2}')"

# ─── Spazio INTERNO in un pattern ─────────────────────────────────────────────
section "Uno spazio interno non rende la feature morta"

# `ultima ora` deve matchare la frase con lo spazio. Prima del fix diventava
# `ultimaora` e la feature era MORTA: sempre 0, per qualsiasi query.
assert_eq "la frase con spazio matcha (feature 3 = 5)" "5" \
    "$(_vec "errori ultima ora" | awk '{print $3}')"
assert_eq "e non matcha quando la frase non c'è (feature 3 = 0)" "0" \
    "$(_vec "errori di ieri" | awk '{print $3}')"

# Il bigramma ha uno spazio voluto nel LATO DESTRO, dove il riempimento produce anche
# spazi INIZIALI: verifica che il trim tolga il riempimento e non l'altro.
assert_eq "bigramma con spazio voluto nel lato destro (feature 4 = 7)" "7" \
    "$(_vec "errore nella ultima ora" | awk '{print $4}')"
assert_eq "  e resta 0 se manca il secondo lato" "0" \
    "$(_vec "errore generico" | awk '{print $4}')"

# ─── Il riempimento delle colonne viene comunque rimosso ──────────────────────
section "Il riempimento di allineamento è rimosso (era lo scopo originale)"

# Se il riempimento NON fosse rimosso, `errore|errori             ` conterrebbe spazi
# finali e il peso ` 2` non sarebbe un numero: la prima feature non matcherebbe e il
# peso sarebbe vuoto. È il caso che la vecchia implementazione gestiva, e che non deve
# regredire.
assert_eq "il pattern allineato matcha (feature 1 = 2)" "2" \
    "$(_vec "errori nell ultima ora" | awk '{print $1}')"
assert_eq "il peso è un numero pulito, non ' 2'" "2" \
    "$(_vec "errore singolo" | awk '{print $1}')"

# ─── Riepilogo ─────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" \
    "$pass" "$fail" "$(( pass + fail ))"
printf "═══════════════════════════════════════════════════\n"
echo ""

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
