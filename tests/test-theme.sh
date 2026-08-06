#!/bin/bash
#
# test-theme.sh — unit test per il sistema di temi colore (lib/utils-theme.sh).
#
# Il requisito centrale, e la ragione per cui mono è il DEFAULT: l'output del
# bot è consumato anche da servizi che vogliono testo e da redirect su file,
# dove qualsiasi sequenza ANSI è sporcizia nel contenuto. Quel requisito è
# verificabile meccanicamente (zero byte ESC) e qui lo si asserisce, invece di
# fidarsi di un'ispezione visiva.
#
# Uso: bash tests/test-theme.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN="\033[32m"; RED="\033[31m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
pass=0; fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso: '%s'\n        avuto:  '%s'\n" \
            "$desc" "$expected" "$actual"
        fail=$(( fail + 1 ))
    fi
}
assert_true() {
    local desc="$1" cond="$2"
    if [[ "$cond" -eq 1 ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"; pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n" "$desc"; fail=$(( fail + 1 ))
    fi
}
section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

# ─── Fixture minima per eseguire query reali ──────────────────────────────────
_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT
_node="$_FIX/prod/lxprjbliq04"
mkdir -p "$_node/prod/ClaimCenter" "$_node/ClaimCenter/Guidewire"
echo "2026-08-06 10:00:00,000 ERROR errore di test" > "$_node/prod/ClaimCenter/server.log"
echo "2026-08-06T10:00:00 INFO gc pause" > "$_node/prod/ClaimCenter/gc.log"
for i in 1 2 3; do
    printf '10.0.0.1 - - [06/Aug/2026:10:0%d:00 +0200] "GET /a%d HTTP/1.1" 50%d 100 3000 - UA\n' \
        "$i" "$i" "$i" >> "$_node/prod/ClaimCenter/undertow_access_log.log"
done

# _run [TEMA] QUERY → output del bot (stdout+stderr)
_run() {
    local theme="$1" q="$2"
    QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$ROOT_DIR/profiles/liquido" \
        --base-dir "$_FIX" --env prod --node 4 ${theme:+--theme "$theme"} --query "$q" 2>&1
}
# _esc TESTO → numero di sequenze ANSI
_esc() { grep -oP '\x1b\[' <<< "$1" | wc -l; }

# ─── Il requisito centrale: mono è il default e non emette ANSI ───────────────
section "mono (default): zero sequenze ANSI"

_out_default=$(_run "" 'quanti errori 500 oggi')
assert_eq "senza --theme: nessuna sequenza ANSI (default = mono)" "0" "$(_esc "$_out_default")"

_out_mono=$(_run mono 'quanti errori 500 oggi')
assert_eq "--theme mono: nessuna sequenza ANSI" "0" "$(_esc "$_out_mono")"

# Il contenuto deve restare completo: mono toglie i colori, non l'informazione.
# Si asserisce sulla struttura della risposta (cornice, tool attivato) e non sui
# dati della tabella: quelli dipendono dalla fixture e dalla finestra temporale
# di default, che non è ciò che questo test verifica.
assert_true "mono conserva la struttura della risposta (cornice + tool)" \
    "$([[ "$_out_mono" == *"count_status"* && "$_out_mono" == *"┌─"* && "$_out_mono" == *"└─"* ]] && echo 1 || echo 0)"

# Anche i tool che girano come processo figlio (search_all_logs.sh) devono
# rispettare il tema: hanno una propria inizializzazione e potrebbero sfuggire.
_out_sal=$(_run "" 'cerca "errore" nel nodo 4')
assert_eq "mono: anche search_all_logs (processo figlio) senza ANSI" "0" "$(_esc "$_out_sal")"

# ─── I temi a colori emettono ANSI ────────────────────────────────────────────
section "Temi a colori: emettono sequenze ANSI"

for _t in dark light high-contrast plain; do
    _o=$(_run "$_t" 'quanti errori 500 oggi')
    _n=$(_esc "$_o")
    assert_true "--theme $_t: emette ANSI (trovate: $_n)" "$([[ "$_n" -gt 0 ]] && echo 1 || echo 0)"
done

# Il contenuto testuale deve essere IDENTICO fra i temi: cambia la resa, non
# l'informazione. Se divergesse, un tema starebbe nascondendo dati.
_strip() { sed 's/\x1b\[[0-9;]*m//g' <<< "$1"; }
_txt_mono=$(_strip "$_out_mono")
for _t in dark light high-contrast plain; do
    _txt=$(_strip "$(_run "$_t" 'quanti errori 500 oggi')")
    assert_eq "tema $_t: contenuto testuale identico a mono" "$_txt_mono" "$_txt"
done

# ─── NO_COLOR (convenzione no-color.org) ──────────────────────────────────────
section "NO_COLOR forza mono, anche con --theme esplicito"

_out_nc=$(NO_COLOR=1 QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" \
    --profile "$ROOT_DIR/profiles/liquido" --base-dir "$_FIX" --env prod --node 4 \
    --theme dark --query 'quanti errori 500 oggi' 2>&1)
assert_eq "NO_COLOR=1 con --theme dark: nessuna sequenza ANSI" "0" "$(_esc "$_out_nc")"

# ─── Precedenza e robustezza della selezione ──────────────────────────────────
section "Selezione del tema: precedenza e fallback"

# --theme batte BOT_THEME dall'ambiente
_o=$(BOT_THEME=dark QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" \
    --profile "$ROOT_DIR/profiles/liquido" --base-dir "$_FIX" --env prod --node 4 \
    --theme mono --query 'quanti errori 500 oggi' 2>&1)
assert_eq "--theme mono vince su BOT_THEME=dark" "0" "$(_esc "$_o")"

# BOT_THEME dall'ambiente attiva i colori quando --theme è assente
_o=$(BOT_THEME=dark QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" \
    --profile "$ROOT_DIR/profiles/liquido" --base-dir "$_FIX" --env prod --node 4 \
    --query 'quanti errori 500 oggi' 2>&1)
assert_true "BOT_THEME=dark senza --theme: emette ANSI" \
    "$([[ "$(_esc "$_o")" -gt 0 ]] && echo 1 || echo 0)"

# Tema inesistente: avviso su stderr e fallback su mono, senza interrompere
_o=$(_run inesistente-xyz 'quanti errori 500 oggi')
assert_true "tema inesistente: avvisa e non interrompe" \
    "$([[ "$_o" == *"non trovato"* && "$_o" == *"count_status"* ]] && echo 1 || echo 0)"

# ─── Completezza dei temi ─────────────────────────────────────────────────────
section "Ogni tema definisce tutti i 9 ruoli"

source "$ROOT_DIR/lib/utils-theme.sh"
_n_themes=0
while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    _n_themes=$(( _n_themes + 1 ))
    _missing=""
    for _v in C_CRIT C_WARN C_OK C_VAL C_LBL C_ACCENT C_ROW_ALT C_BOLD C_RESET; do
        grep -qE "^${_v}=" "$ROOT_DIR/themes/${_t}.conf" || _missing+="$_v "
    done
    assert_eq "tema '$_t': tutti i ruoli definiti" "" "$_missing"
done < <(theme_list)

assert_true "almeno 8 temi disponibili (trovati: $_n_themes)" \
    "$([[ "$_n_themes" -ge 8 ]] && echo 1 || echo 0)"

# mono deve avere TUTTE le variabili vuote — è ciò che lo rende adatto ai servizi
_mono_nonempty=$(grep -E '^C_[A-Z_]+="..' "$ROOT_DIR/themes/mono.conf" | wc -l)
assert_eq "mono: tutte le variabili vuote" "0" "$_mono_nonempty"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
