#!/bin/bash
#
# test-python-resolve.sh — copertura di lib/utils-python.sh e dei suoi tre
# chiamanti (VENVGATE-1, 2026-08-21).
#
# Cosa protegge. Fino al 2026-08-21 tre script cercavano Python in tre modi
# diversi, e due erano sbagliati:
#
#   build-dataset.sh                 [[ -x .venv/bin/python3 ]] → ramo bash
#   tests/test-normalize-parity.sh   idem, ma `exit 1`
#   vocab-gap.sh                     command -v python3          (corretto)
#
# Il gate su `.venv` era **vestigiale**: il venv esisteva per PyTorch, rimosso il
# 2026-08-18 insieme a lib/train.py, e `lib/build_dataset.py` importa solo stdlib.
# Conseguenza misurata: in produzione c'è python3 e non c'è `.venv`, quindi
# build-dataset.sh prendeva il ramo bash — 0,2 s contro ≥110 s — e la parità
# riportava un FAIL per una ragione puramente ambientale.
#
# L'asserzione centrale è quindi: **il backend Python funziona con un interprete
# che NON è quello del venv**. Se qualcuno reintroducesse un test su `.venv`,
# quella riga cade.
#
# Uso: bash tests/test-python-resolve.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0
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

# ─── 1. Precedenza ────────────────────────────────────────────────────────────
section "resolve_python: precedenza NLA_PYTHON → venv → sistema"

_sys_py="$(command -v python3 || true)"
if [[ -z "$_sys_py" ]]; then
    printf "  ${DIM}(salto: nessun python3 su questa macchina)${RESET}\n"
else
    _r() { ( unset NLA_PYTHON; source "$ROOT_DIR/lib/utils-python.sh"; resolve_python ); }
    _got="$(_r)"
    if [[ -x "$ROOT_DIR/.venv/bin/python3" ]]; then
        assert_eq "col venv presente, resolve_python lo preferisce" \
            "$_got" "$ROOT_DIR/.venv/bin/python3"
        assert_eq "  python_origin lo etichetta 'venv'" \
            "$( source "$ROOT_DIR/lib/utils-python.sh"; python_origin "$_got" )" "venv"
    else
        assert_eq "senza venv, resolve_python usa il python3 di sistema" "$_got" "$_sys_py"
    fi

    # NLA_PYTHON vince su tutto: è l'override per-installazione.
    _got_ovr="$( NLA_PYTHON="$_sys_py"; export NLA_PYTHON; \
                 source "$ROOT_DIR/lib/utils-python.sh"; resolve_python )"
    assert_eq "NLA_PYTHON vince sul venv" "$_got_ovr" "$_sys_py"

    # Impostato ma inesistente → FALLISCE, non ricade in silenzio: chi ha pinnato
    # un interprete ha espresso una scelta, e scavalcarla nasconderebbe un errore
    # di configurazione (ARCH-6).
    _ovr_rc=0
    ( NLA_PYTHON="$_FIX/non-esiste"; export NLA_PYTHON; \
      source "$ROOT_DIR/lib/utils-python.sh"; resolve_python >/dev/null 2>&1 ) || _ovr_rc=$?
    assert_eq "NLA_PYTHON inesistente: fallisce, non ricade su venv/sistema" "$_ovr_rc" "1"
fi

# ─── 2. L'asserzione centrale di VENVGATE-1 ──────────────────────────────────
section "build_dataset.py funziona con un interprete NON del venv"

if [[ -z "$_sys_py" ]]; then
    printf "  ${DIM}(salto: nessun python3 di sistema)${RESET}\n"
else
    # Il dataset generato dal python di SISTEMA deve essere bit-identico a quello
    # committato (prodotto dal venv). È ciò che rende sicuro rimuovere il gate: se
    # i due interpreti divergessero, la produzione otterrebbe un dataset diverso
    # dal locale e il modello sarebbe addestrato su input non riproducibili.
    _ds="$ROOT_DIR/nlp/dataset/queries.txt"
    _md5_before="$(md5sum "$_ds" | cut -d' ' -f1)"
    "$_sys_py" "$ROOT_DIR/lib/build_dataset.py" --profile "$ROOT_DIR/profiles/liquido" >/dev/null 2>&1
    _md5_sys="$(md5sum "$_ds" | cut -d' ' -f1)"
    assert_eq "dataset dal python di sistema: bit-identico al committato" "$_md5_sys" "$_md5_before"

    # E build-dataset.sh deve DIRE quale interprete ha usato: quando i tempi non
    # tornano, è la prima cosa che si vuole sapere.
    _bd_out="$(NLA_PYTHON="$_sys_py" bash "$ROOT_DIR/build-dataset.sh" \
               --profile "$ROOT_DIR/profiles/liquido" 2>&1 || true)"
    assert_eq "build-dataset.sh annuncia il backend Python, non il ramo bash" "1" \
        "$(grep -q "Backend: Python" <<< "$_bd_out" && echo 1 || echo 0)"
    assert_eq "  e dichiara l'origine dell'interprete" "1" \
        "$(grep -qE "Backend: Python .*\((NLA_PYTHON|venv|sistema)\)" <<< "$_bd_out" && echo 1 || echo 0)"
fi

# ─── 3. Degradazione: nessun python → «non misurato», non «fallito» ──────────
section "Senza interprete: exit 2 (non misurabile), non exit 1 (fallito)"

export NLA_PYTHON="$_FIX/non-esiste"

_par_rc=0
bash "$ROOT_DIR/tests/test-normalize-parity.sh" >/dev/null 2>&1 || _par_rc=$?
assert_eq "test-normalize-parity.sh esce 2, non 1" "$_par_rc" "2"

_par_out="$(bash "$ROOT_DIR/tests/test-normalize-parity.sh" 2>&1 || true)"
assert_eq "  il messaggio distingue 'non misurata' da 'divergenza'" "1" \
    "$(grep -qi "non misurata" <<< "$_par_out" && echo 1 || echo 0)"
# Il messaggio vecchio suggeriva `pip install -r requirements.txt`, che oggi è
# fuorviante: non serve alcun pacchetto di terze parti.
assert_eq "  non suggerisce più di installare requirements.txt" "1" \
    "$(grep -q "requirements.txt" <<< "$_par_out" && echo 0 || echo 1)"

_vg_rc=0
bash "$ROOT_DIR/vocab-gap.sh" --profile "$ROOT_DIR/profiles/liquido" >/dev/null 2>&1 || _vg_rc=$?
assert_eq "vocab-gap.sh esce 2 (stesso codice, stesso significato)" "$_vg_rc" "2"

unset NLA_PYTHON

# ─── Riepilogo ────────────────────────────────────────────────────────────────
printf "\n${DIM}%s${RESET}\n" "────────────────────────────────────────────────────────"
if [[ "$fail" -eq 0 ]]; then
    printf "${BOLD}test-python-resolve.sh${RESET}  ${GREEN}%d PASS${RESET}  ${GREEN}0 FAIL${RESET}\n" "$pass"
else
    printf "${BOLD}test-python-resolve.sh${RESET}  ${GREEN}%d PASS${RESET}  ${RED}${BOLD}%d FAIL${RESET}\n" "$pass" "$fail"
fi
[[ "$fail" -eq 0 ]]
