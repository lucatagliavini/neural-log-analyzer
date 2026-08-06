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

# ─── Feedback progressivo: copertura su TUTTI i tool ──────────────────────────
section "Feedback progressivo (⋯) presente in ogni tool che legge log"

# Il marcatore ⋯ compare solo con stderr su TTY (per design: sotto `$(...)` e in
# --query resta silenzioso), quindi serve `script` per simulare un terminale.
#
# Perché questo test esiste: la copertura del progresso si è rotta DUE VOLTE
# per la stessa ragione — progress_show vive nel motore
# select_log_files_grouped, e i percorsi che lo bypassano
# (open_current_log_for per tail_log a riposo, resolve_named_log_path per
# tail_named_log/grep_named_log) non lo chiamavano. Un percorso nuovo
# ripeterebbe l'omissione senza alcun segnale: il progresso mancante non è un
# errore, è solo assenza.
if command -v script >/dev/null 2>&1; then
    _has_progress() {
        local q="$1" out
        out=$(script -qec "QUERY_LOG_DIR= bash '$ROOT_DIR/chatbot.sh' --profile '$ROOT_DIR/profiles/liquido' --base-dir '$_FIX' --env prod --node 4 --query '$q'" /dev/null 2>&1)
        grep -q '⋯' <<< "$out" && echo 1 || echo 0
    }
    # Una query per ciascun percorso di risoluzione file:
    #   motore (select_log_files_grouped) · open_current_log_for ·
    #   resolve_named_log_path · pool di search_all_logs
    assert_eq "count_status (motore di selezione)"            "1" "$(_has_progress 'quanti errori 500 oggi')"
    assert_eq "filter_errors (motore, server.log)"            "1" "$(_has_progress 'errori nel server log')"
    assert_eq "tail_log (open_current_log_for)"               "1" "$(_has_progress 'ultime righe del log')"
    assert_eq "tail_named_log (resolve_named_log_path)"       "1" "$(_has_progress 'ultime righe del cc.log')"
    assert_eq "grep_named_log (resolve_named_log_path)"       "1" "$(_has_progress 'errori nel cc.log')"
    assert_eq "search_all_logs (pool di worker)"              "1" "$(_has_progress 'cerca \"errore\" nel nodo 4')"

    # Il progresso non deve lasciare residui: ogni riga emessa va cancellata
    # con \r\033[K prima dell'output vero, altrimenti si attacca ad esso (la
    # riga di progresso non ha newline).
    _out_tty=$(script -qec "QUERY_LOG_DIR= bash '$ROOT_DIR/chatbot.sh' --profile '$ROOT_DIR/profiles/liquido' --base-dir '$_FIX' --env prod --node 4 --query 'errori nel cc.log'" /dev/null 2>&1)
    _n_show=$(grep -o '⋯' <<< "$_out_tty" | wc -l)
    _n_clear=$(grep -oP '\r\x1b\[K' <<< "$_out_tty" | wc -l)
    assert_true "ogni riga di progresso è seguita da una pulizia (show=$_n_show clear=$_n_clear)" \
        "$([[ "$_n_clear" -ge "$_n_show" ]] && echo 1 || echo 0)"
else
    printf "  ${DIM}SKIP  copertura progresso: 'script' non disponibile${RESET}\n"
fi

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

# ─── UI-13: soglie di severità configurabili ───────────────────────────────────
section "Soglie di severità da domain.conf (UI-13)"

# Le soglie che decidono quando un valore diventa giallo o rosso erano hardcoded
# negli .awk: tararle su un ambiente richiedeva di editare il codice. Ora sono in
# domain.conf e arrivano ai tool con -v da dispatch.sh.
#
# Il test verifica la PROPRIETÀ (alzando le soglie, i colori di severità
# scompaiono) e non valori specifici: legarlo a "250ms è giallo" lo renderebbe
# fragile a un cambio dei default, che è proprio ciò che UI-13 rende facile.
_GCFIX="$(mktemp -d)"
_gn="$_GCFIX/prod/lxprjbliq04"
mkdir -p "$_gn/prod/ClaimCenter" "$_gn/ClaimCenter/Guidewire"
echo "2026-08-06 10:00:00,000 ERROR x" > "$_gn/prod/ClaimCenter/server.log"
echo '10.0.0.1 [06/Aug/2026:10:00:00 +0200] "GET /a HTTP/1.1" 200 100 100 - UA' \
    > "$_gn/prod/ClaimCenter/undertow_access_log.log"
# Due pause: 250ms (oltre GC_PAUSE_WARN_MS=200) e 600ms (oltre CRIT=500)
cat > "$_gn/prod/ClaimCenter/gc.log" <<'GCEOF'
[2026-08-06T10:00:00.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 250.500ms
[2026-08-06T10:01:00.000+0200] GC(2) Pause Young (Normal) 130M->50M(512M) 600.100ms
GCEOF

# _sev [ENV_ASSIGNMENTS] → quanti colori di severità (giallo 33 / rosso 31) usati
_sev() {
    env "$@" QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$ROOT_DIR/profiles/liquido" \
        --base-dir "$_GCFIX" --env prod --node 4 --theme dark --query 'statistiche GC' 2>&1 |
        grep -oE $'\033\[3[13]m' | wc -l
}

_n_default=$(_sev)
assert_true "con le soglie di default i valori oltre soglia sono colorati (trovati: $_n_default)" \
    "$([[ "$_n_default" -gt 0 ]] && echo 1 || echo 0)"

_n_alte=$(_sev GC_PAUSE_WARN_MS=9000 GC_PAUSE_CRIT_MS=9999)
assert_eq "alzando le soglie oltre i valori reali: nessun colore di severità" "0" "$_n_alte"

_n_basse=$(_sev GC_PAUSE_WARN_MS=1 GC_PAUSE_CRIT_MS=2)
assert_true "abbassandole a 1ms: tutto colorato (trovati: $_n_basse)" \
    "$([[ "$_n_basse" -ge "$_n_default" ]] && echo 1 || echo 0)"

# Le soglie devono rispettare l'ambiente: domain.conf usa ${VAR:-default}, come
# il resto del progetto. Un'assegnazione secca le sovrascriverebbe, rendendo
# UI-13 inutile — ed è l'errore commesso alla prima stesura.
_secche=$(grep -cE '^(GC_PAUSE|SVC_TIME|REQ_TIME|HEAP_USED|GC_CORR)[A-Z_]*=[0-9]' \
    "$ROOT_DIR/profiles/liquido/domain.conf" || true)
assert_eq "domain.conf: nessuna soglia con assegnazione secca" "0" "$_secche"

# Il contenuto non cambia: le soglie governano la resa, non cosa il tool trova
_txt_def=$(env QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$ROOT_DIR/profiles/liquido" \
    --base-dir "$_GCFIX" --env prod --node 4 --query 'statistiche GC' 2>&1)
_txt_alt=$(env GC_PAUSE_WARN_MS=9000 GC_PAUSE_CRIT_MS=9999 QUERY_LOG_DIR= \
    bash "$ROOT_DIR/chatbot.sh" --profile "$ROOT_DIR/profiles/liquido" \
    --base-dir "$_GCFIX" --env prod --node 4 --query 'statistiche GC' 2>&1)
assert_eq "cambiare le soglie non cambia i dati riportati (solo la resa)" "$_txt_def" "$_txt_alt"
rm -rf "$_GCFIX"

# ─── UI-12: ruoli semantici distinti ──────────────────────────────────────────
section "Ruoli semantici: categoria ≠ severità (UI-12)"

# I 13 tool usano i ruoli semantici (C_CRIT, C_WARN, C_TAG…) invece delle
# costanti storiche. La migrazione ha corretto una collisione reale: il metodo
# HTTP GET usava C_OK, quindi era colorato come uno status 2xx — in una tabella
# di richieste LENTE il verde suggeriva "va bene", mentre indicava solo il verbo.
# Ora usa C_TAG, che un tema può distinguere dalle severità.
_UIFIX="$(mktemp -d)"
_un="$_UIFIX/prod/lxprjbliq04"
mkdir -p "$_un/prod/ClaimCenter" "$_un/ClaimCenter/Guidewire"
echo "2026-08-06 10:00:00,000 ERROR x" > "$_un/prod/ClaimCenter/server.log"
echo "2026-08-06T10:00:00 INFO gc" > "$_un/prod/ClaimCenter/gc.log"
# Una richiesta GET lenta con status 200: il metodo e lo status NON devono avere
# lo stesso colore, altrimenti il verbo HTTP sembra un giudizio sull'esito.
echo '10.0.0.1 [06/Aug/2026:10:00:00 +0200] "GET /lenta HTTP/1.1" 200 100 9000 - UA' \
    > "$_un/prod/ClaimCenter/undertow_access_log.log"

# In un tema dove C_TAG e C_OK differiscono (light: magenta vs verde), il metodo
# non deve usare il colore di "esito positivo".
_out_ui=$(env QUERY_LOG_DIR= bash "$ROOT_DIR/chatbot.sh" --profile "$ROOT_DIR/profiles/liquido" \
    --base-dir "$_UIFIX" --env prod --node 4 --theme light --query 'chiamate lente' 2>&1)
source "$ROOT_DIR/lib/utils-theme.sh"
theme_load light 2>/dev/null
# Il tema light ha C_OK verde e C_TAG magenta: distinti per costruzione
assert_true "il tema light distingue C_TAG da C_OK" \
    "$([[ "$C_TAG" != "$C_OK" ]] && echo 1 || echo 0)"
# E il metodo GET nell'output usa C_TAG, non C_OK
_meth_line=$(grep -E 'GET' <<< "$_out_ui" | head -1)
assert_true "il metodo GET non usa il colore di esito positivo (C_OK)" \
    "$([[ -n "$_meth_line" && "$_meth_line" != *"$C_OK"* ]] && echo 1 || echo 0)"

# Nessuna costante storica residua nei tool: se ne ricomparisse una, il tema non
# la governerebbe attraverso i ruoli e la semantica tornerebbe implicita.
_hist=$(grep -ohE '\b(RED|YELLOW|GREEN|CYAN|WHT)\b' "$ROOT_DIR"/lib/tools/*.awk 2>/dev/null | wc -l)
assert_eq "nessuna costante colore storica residua nei tool" "0" "$_hist"

# Ogni tema deve caricare i SUOI valori, senza ereditare dal precedente: bug
# reale trovato in UI-12 (theme_load non azzerava le variabili, quindi
# theme-preview.sh mostrava colori che il tema non ha).
theme_load high-contrast 2>/dev/null; _hc_tag="$C_TAG"
theme_load light-soft 2>/dev/null;    _ls_tag="$C_TAG"
assert_true "theme_load non fa ereditare i ruoli dal tema precedente" \
    "$([[ "$_hc_tag" != "$_ls_tag" ]] && echo 1 || echo 0)"
rm -rf "$_UIFIX"

# ─── Contrasto sulla riga con sfondo alternato ────────────────────────────────
section "C_ROW_ALT_FG: contrasto garantito sulla riga colorata"

# Problema segnalato dall'utente (2026-08-06) sul tema dark: sulla riga con
# sfondo alternato il nome del nodo e del log erano poco leggibili. Causa
# duplice — lo sfondo era `\033[100m` (bright-black, un grigio CHIARO e non
# standardizzato fra terminali) e sopra ci andavano C_LBL (dim) e C_ACCENT
# (tinta normale), entrambi a bassa intensità.
#
# La correzione strutturale è C_ROW_ALT_FG: dim su uno sfondo colorato avvicina
# il testo al fondo PER COSTRUZIONE, quindi serve un ruolo dedicato al testo
# sulla riga colorata — un tema non può altrimenti garantire il contrasto,
# perché non sa cosa il tool ci scriverà sopra.
source "$ROOT_DIR/lib/utils-theme.sh"

# INVARIANTE: un tema con sfondo alternato deve definire anche il foreground.
# Senza questo un tema nuovo ripeterebbe il difetto senza alcun segnale.
_missing=""
while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    theme_load "$_t" 2>/dev/null
    [[ -n "$C_ROW_ALT" && -z "$C_ROW_ALT_FG" ]] && _missing+="$_t "
done < <(theme_list)
assert_eq "ogni tema con C_ROW_ALT definisce anche C_ROW_ALT_FG" "" "$_missing"

# Il foreground non deve essere dim: è esattamente ciò che rendeva illeggibile
# la riga. `\033[2m` è la sequenza di dim.
_dim=""
while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    theme_load "$_t" 2>/dev/null
    [[ "$C_ROW_ALT_FG" == *$'\033[2m'* ]] && _dim+="$_t "
done < <(theme_list)
assert_eq "nessun tema usa dim come testo sulla riga con sfondo" "" "$_dim"

# Il tema dark non deve più usare \033[100m (bright-black): è il codice la cui
# resa varia fra terminali e che ha causato la segnalazione.
# Cerca nella sola ASSEGNAZIONE, non in tutto il file: il commento che spiega
# perché 100m non si usa più contiene quella stringa, e un grep sul file intero
# la conterebbe come difetto (falso positivo che questo test ha prodotto alla
# prima stesura).
_brightblack=$(grep -cE '^C_ROW_ALT=.*100m' "$ROOT_DIR/themes/dark.conf" || true)
assert_eq "dark non usa più bright-black (100m) come sfondo" "0" "$_brightblack"

# E il foreground deve DIFFERIRE da C_LBL nei temi con sfondo: se coincidesse,
# la correzione sarebbe cosmetica e il contrasto resterebbe quello di prima.
theme_load dark 2>/dev/null
assert_true "dark: il testo sulla riga con sfondo differisce da C_LBL" \
    "$([[ "$C_ROW_ALT_FG" != "$C_LBL" ]] && echo 1 || echo 0)"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
