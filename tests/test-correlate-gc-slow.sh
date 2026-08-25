#!/bin/bash
#
# test-correlate-gc-slow.sh — unit test per lib/tools/correlate_gc_slow.awk.
#
# Copertura prima assente: il tool era coperto solo da smoke-tools.sh, che
# richiede log reali sul server e verifica solo "non è andato in errore".
#
# Copre la logica di correlazione (una richiesta lenta è correlata se cade
# entro ±gc_margin_s da una pausa GC) sui casi di confine, e l'equivalenza
# fra l'indice per secondo (`gc_at`, 2026-08-06) e la scansione lineare che
# sostituisce.
#
# GCCORR-1 (2026-08-25): il verdetto è passato da due esiti a quattro — «non
# discriminabile», «GC pervasivo», «probabile causa», «contribuisce», «non è
# la causa» (cinque stringhe, quattro STATI: NODISC compare per due motivi
# distinti, vedi sotto) — basati sul LIFT rispetto a un gruppo di controllo
# (le richieste veloci), non sulla sola percentuale grezza di correlazione.
# Il rischio specifico che questi test esistono per intercettare: che i due
# esiti "positivi" (NODISC, PERVASIVE — dicono cosa manca o cosa domina, non
# accusano né assolvono) collassino su NONCAUSE o l'uno sull'altro. È successo
# una volta durante lo sviluppo — la copertura PERVASIVE era annidata dentro
# il ramo raggiungibile solo se il campione minimo passava, e il campione
# minimo fallisce matematicamente proprio quando le pause sono pervasive
# (pct_fast → 100%, exp2 → 0) — quindi ogni test di verdetto qui asserisce
# anche l'ASSENZA degli altri quattro token, non solo la presenza del proprio.
#
# Uso: bash tests/test-correlate-gc-slow.sh
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
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso: '%s'\n        avuto:  '%s'\n" \
            "$desc" "$expected" "$actual"
        fail=$(( fail + 1 ))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        atteso di trovare: '%s'\n        in:\n%s\n" \
            "$desc" "$needle" "$haystack"
        fail=$(( fail + 1 ))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
        pass=$(( pass + 1 ))
    else
        printf "  ${RED}${BOLD}FAIL${RESET}  %s\n        NON doveva contenere: '%s'\n" \
            "$desc" "$needle"
        fail=$(( fail + 1 ))
    fi
}

section() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "────────────────────────────"; }

# Deve rispecchiare esattamente i -f che dispatch.sh passa in produzione per
# questo tool (lib/dispatch.sh: common_f, fmt=jboss, afmt=undertow per
# profiles/liquido) — l'omissione di utils-logline.awk qui aveva reso il test
# meno fedele alla produzione di quanto sembrasse.
_UTILS="-f $LIB/utils-time.awk -f $LIB/utils-logline.awk -f $LIB/utils-colors.awk -f $LIB/utils-jboss.awk -f $LIB/utils-access-undertow.awk -f $LIB/utils-dedup.awk"
_TOOL="$LIB/tools/correlate_gc_slow.awk"
_strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# _run GC_FILE ACCESS_FILE THRESHOLD → "lente/totali correlate"
_run() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$3" "$1" "$2" 2>/dev/null | _strip | \
        awk '/Richieste lente/ { split($NF, a, "/"); slow=a[1]; tot=a[2] }
             /Di cui correlate/ { corr=$(NF-1) }
             END { printf "%s/%s %s", slow+0, tot+0, corr+0 }'
}

# _full GC_FILE ACCESS_FILE THRESHOLD [MAX_ROWS] → output completo, colori rimossi
_full() {
    local mr="${4:-20}"
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$3" -v max_rows="$mr" "$1" "$2" 2>/dev/null | _strip
}

# _verdict GC_FILE ACCESS_FILE THRESHOLD → uno dei 5 token di verdetto
_verdict() {
    _full "$1" "$2" "$3" | \
        grep -oE "NON DISCRIMINABILE|PERVASIVO|PROBABILE CAUSA|CONTRIBUISCE|NON e' la causa principale" | head -1
}

# _stderr_of GC_FILE ACCESS_FILE THRESHOLD → solo stderr (per verificare exit 0 e nessun warning nascosto)
_stderr_of() {
    gawk $_UTILS -f "$_TOOL" -v threshold_ms="$3" "$1" "$2" 2>&1 1>/dev/null
}

_FIX="$(mktemp -d)"
trap 'rm -rf "$_FIX"' EXIT

# ─── Fixture: pausa GC alle 10:00:10, richieste a distanze diverse ────────────
# gc_margin_s = 2 → correlate solo quelle entro ±2s (10:00:08 … 10:00:12).
cat > "$_FIX/gc.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF

# 7 richieste lente (1500ms), a offset -3, -2, -1, 0, +1, +2, +3 secondi
cat > "$_FIX/access.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:07 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:08 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:09 +0200] "GET /c HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /d HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:11 +0200] "GET /e HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:12 +0200] "GET /f HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:13 +0200] "GET /g HTTP/1.1" 200 100 1500 - UA
EOF

section "Finestra di correlazione (±2s dalla pausa GC)"

# 7 lente su 7 totali; correlate solo le 5 dentro ±2s (08,09,10,11,12)
assert_eq "7 richieste lente, 5 correlate entro ±2s" \
    "7/7 5" "$(_run "$_FIX/gc.log" "$_FIX/access.log" 500)"

section "Soglia di lentezza (threshold_ms)"

# Soglia sopra i 1500ms: nessuna richiesta è lenta, nessuna correlazione
assert_eq "soglia 2000ms: nessuna richiesta lenta" \
    "0/7 0" "$(_run "$_FIX/gc.log" "$_FIX/access.log" 2000)"

# Richieste con tempi misti: solo quelle sopra soglia contano
cat > "$_FIX/access_mixed.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /slow HTTP/1.1" 200 100 3000 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /fast HTTP/1.1" 200 100 50 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /mid HTTP/1.1" 200 100 800 - UA
EOF
assert_eq "soglia 500ms: 2 lente su 3, entrambe correlate" \
    "2/3 2" "$(_run "$_FIX/gc.log" "$_FIX/access_mixed.log" 500)"
assert_eq "soglia 1000ms: 1 lenta su 3, correlata" \
    "1/3 1" "$(_run "$_FIX/gc.log" "$_FIX/access_mixed.log" 1000)"

section "Nessuna pausa GC / nessuna correlazione"

: > "$_FIX/gc_empty.log"
assert_eq "gc.log vuoto: richieste lente contate, zero correlate" \
    "7/7 0" "$(_run "$_FIX/gc_empty.log" "$_FIX/access.log" 500)"

# Pausa GC lontana nel tempo (un'ora dopo): nessuna correlazione
cat > "$_FIX/gc_far.log" <<'EOF'
[2026-08-06T11:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
assert_eq "pausa GC un'ora dopo: nessuna correlazione" \
    "7/7 0" "$(_run "$_FIX/gc_far.log" "$_FIX/access.log" 500)"

section "Pause GC multiple (indice per secondo, 2026-08-06)"

# Due pause distinte: ognuna correla le proprie richieste vicine.
cat > "$_FIX/gc_multi.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:00:30.000+0200] GC(2) Pause Full (System.gc()) 400M->90M(512M) 890.456ms
EOF
cat > "$_FIX/access_multi.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:20 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:30 +0200] "GET /c HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:31 +0200] "GET /d HTTP/1.1" 200 100 1500 - UA
EOF
# a→pausa1, c e d→pausa2, b (10:00:20) è a 10s da entrambe: non correlata
assert_eq "2 pause: 3 correlate su 4 lente (quella a metà no)" \
    "4/4 3" "$(_run "$_FIX/gc_multi.log" "$_FIX/access_multi.log" 500)"

# Due pause NELLO STESSO secondo: l'indice tiene l'ultima, ma la domanda
# "esiste una pausa vicina?" resta corretta — il conteggio non cambia.
cat > "$_FIX/gc_same_sec.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:00:10.000+0200] GC(2) Pause Young (Normal) 130M->50M(512M) 55.456ms
EOF
assert_eq "2 pause nello stesso secondo: correlazione invariata" \
    "7/7 5" "$(_run "$_FIX/gc_same_sec.log" "$_FIX/access.log" 500)"

# ═══════════════════════════════════════════════════════════════════════════
# Verdetto a quattro stati (GCCORR-1)
# ═══════════════════════════════════════════════════════════════════════════

section "Verdetto — non discriminabile per assenza di controllo"

# La fixture di apertura: 7 richieste, TUTTE lente (nessuna veloce) → nessun
# gruppo di controllo possibile. L'invariante da proteggere: questo esito è
# distinto da "non è la causa" — non è un'assoluzione, è un "non lo so".
v="$(_verdict "$_FIX/gc.log" "$_FIX/access.log" 500)"
assert_eq "senza richieste veloci: 'NON DISCRIMINABILE'" "NON DISCRIMINABILE" "$v"
full="$(_full "$_FIX/gc.log" "$_FIX/access.log" 500)"
assert_not_contains "non contiene 'NON e' la causa principale'" "NON e' la causa principale" "$full"
assert_not_contains "non contiene 'PROBABILE CAUSA'" "PROBABILE CAUSA" "$full"
assert_not_contains "non contiene 'CONTRIBUISCE'" "CONTRIBUISCE" "$full"
assert_not_contains "non contiene 'PERVASIVO'" "PERVASIVO" "$full"
assert_not_contains "senza controllo, 'Gruppo di controllo' non compare (total_fast=0)" \
    "Gruppo di controllo" "$full"

section "Verdetto — non discriminabile per campione minimo insufficiente"

# Qui un gruppo di controllo ESISTE (total_fast>0), ma è troppo piccolo per
# il criterio da tabella di contingenza (attesa ≥5 su entrambe le celle):
# con total_slow=6, exp1+exp2=6<10 per costruzione — nessun pct_fast può
# soddisfare il guard. Distinto dal caso precedente: qui la riga "Gruppo di
# controllo" DEVE comparire (total_fast>0), ma "Lift:" NON deve comparire
# (min_sample_ok=false) — sono due segnali indipendenti nello stesso stato.
cat > "$_FIX/gc_minsample.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
cat > "$_FIX/access_minsample.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /c HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /d HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /e HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /f HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /g HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /h HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /i HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:00 +0200] "GET /j HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:01 +0200] "GET /k HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:02 +0200] "GET /l HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:03 +0200] "GET /m HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:04 +0200] "GET /n HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:05 +0200] "GET /o HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:05:06 +0200] "GET /p HTTP/1.1" 200 100 100 - UA
EOF
v="$(_verdict "$_FIX/gc_minsample.log" "$_FIX/access_minsample.log" 500)"
assert_eq "campione minimo insufficiente: 'NON DISCRIMINABILE'" "NON DISCRIMINABILE" "$v"
full="$(_full "$_FIX/gc_minsample.log" "$_FIX/access_minsample.log" 500)"
assert_contains "'Gruppo di controllo' compare (total_fast=10>0)" \
    "Gruppo di controllo (richieste veloci): 3/10 (30%)" "$full"
assert_not_contains "'Lift:' NON compare (campione insufficiente)" "Lift:" "$full"

section "Verdetto — probabile causa (CRIT)"

# 5 pause, 60s apart. 45/50 lente correlate (90%), 50/250 veloci correlate
# (20%) → lift = 0.90/0.20 = 4.5×, ben sopra LIFT_CRIT (3.0) e CORR_CRIT
# (30%). Copertura temporale bassa (poche pause su una finestra ampia): non
# è un caso di densità, è lift genuinamente alto.
cat > "$_FIX/gc_5pause.log" <<'EOF'
[2026-08-06T10:00:00.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:01:00.000+0200] GC(2) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:02:00.000+0200] GC(3) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:03:00.000+0200] GC(4) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T10:04:00.000+0200] GC(5) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
: > "$_FIX/access_crit.log"
for m in 00 01 02 03 04; do
    for _ in 1 2 3 4 5 6 7 8 9; do
        echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /slow HTTP/1.1\" 200 100 1500 - UA" >> "$_FIX/access_crit.log"
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /fast HTTP/1.1\" 200 100 100 - UA" >> "$_FIX/access_crit.log"
    done
done
for s in 00 01 02 03 04; do
    echo "10.0.0.1 [06/Aug/2026:10:09:${s} +0200] \"GET /slowfar HTTP/1.1\" 200 100 1500 - UA" >> "$_FIX/access_crit.log"
done
for i in $(seq 0 199); do
    sec=$(( 20 + i )); mm=$(( 10 + sec/60 )); ss=$(( sec%60 ))
    printf "10.0.0.1 [06/Aug/2026:10:%02d:%02d +0200] \"GET /fastfar HTTP/1.1\" 200 100 100 - UA\n" "$mm" "$ss" >> "$_FIX/access_crit.log"
done
v="$(_verdict "$_FIX/gc_5pause.log" "$_FIX/access_crit.log" 500)"
assert_eq "90% correlato, lift 4.5×: 'PROBABILE CAUSA'" "PROBABILE CAUSA" "$v"
full="$(_full "$_FIX/gc_5pause.log" "$_FIX/access_crit.log" 500)"
assert_contains "45/50 lente correlate (90%)" "Di cui correlate a pausa GC (±2s): 45 (90%)" "$full"
assert_contains "gruppo di controllo 50/250 (20%)" "Gruppo di controllo (richieste veloci): 50/250 (20%)" "$full"
assert_contains "lift 4.5×" "Lift: 4.5" "$full"
assert_not_contains "non è pervasivo (copertura bassa)" "PERVASIVO" "$full"

section "Verdetto — contribuisce (WARN)"

# Stesse 5 pause. 15/75 lente correlate (20%), 20/200 veloci correlate
# (10%) → lift = 0.20/0.10 = 2.0×. pct_corr sotto CORR_CRIT (30%): non basta
# la sola percentuale a farlo salire a "probabile causa".
: > "$_FIX/access_warn.log"
for m in 00 01 02 03 04; do
    for _ in 1 2 3; do
        echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /slow HTTP/1.1\" 200 100 1500 - UA" >> "$_FIX/access_warn.log"
    done
    for _ in 1 2 3 4; do
        echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /fast HTTP/1.1\" 200 100 100 - UA" >> "$_FIX/access_warn.log"
    done
done
for i in $(seq 0 59); do
    sec=$(( 20 + i )); mm=$(( 10 + sec/60 )); ss=$(( sec%60 ))
    printf "10.0.0.1 [06/Aug/2026:10:%02d:%02d +0200] \"GET /slowfar HTTP/1.1\" 200 100 1500 - UA\n" "$mm" "$ss" >> "$_FIX/access_warn.log"
done
for i in $(seq 0 179); do
    sec=$(( 100 + i )); mm=$(( 10 + sec/60 )); ss=$(( sec%60 ))
    printf "10.0.0.1 [06/Aug/2026:10:%02d:%02d +0200] \"GET /fastfar HTTP/1.1\" 200 100 100 - UA\n" "$mm" "$ss" >> "$_FIX/access_warn.log"
done
v="$(_verdict "$_FIX/gc_5pause.log" "$_FIX/access_warn.log" 500)"
assert_eq "20% correlato, lift 2.0×: 'CONTRIBUISCE'" "CONTRIBUISCE" "$v"
full="$(_full "$_FIX/gc_5pause.log" "$_FIX/access_warn.log" 500)"
assert_contains "15/75 lente correlate (20%)" "Di cui correlate a pausa GC (±2s): 15 (20%)" "$full"
assert_contains "lift 2.0×" "Lift: 2.0" "$full"
assert_not_contains "non è 'probabile causa' (pct_corr sotto CRIT)" "PROBABILE CAUSA" "$full"

section "Verdetto — non è la causa principale (NONCAUSE genuino)"

# Stesse 5 pause, ma solo 4/50 lente correlate (8%, sotto CORR_WARN=10%) e
# 20/200 veloci correlate (10%) → lift 0.8×, sotto 1: le lente sono MENO
# correlate delle veloci sullo stesso traffico. Campione sufficiente
# (exp1=5, exp2=45): non è "non discriminabile", è genuinamente non causale.
: > "$_FIX/access_noncause.log"
for _ in 1 2 3 4; do
    echo "10.0.0.1 [06/Aug/2026:10:00:00 +0200] \"GET /slow HTTP/1.1\" 200 100 1500 - UA" >> "$_FIX/access_noncause.log"
done
for i in $(seq 0 45); do
    sec=$(( 20 + i )); mm=$(( 10 + sec/60 )); ss=$(( sec%60 ))
    printf "10.0.0.1 [06/Aug/2026:10:%02d:%02d +0200] \"GET /slowfar HTTP/1.1\" 200 100 1500 - UA\n" "$mm" "$ss" >> "$_FIX/access_noncause.log"
done
for m in 00 01 02 03 04; do
    for _ in 1 2 3 4; do
        echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /fast HTTP/1.1\" 200 100 100 - UA" >> "$_FIX/access_noncause.log"
    done
done
for i in $(seq 0 179); do
    sec=$(( 100 + i )); mm=$(( 10 + sec/60 )); ss=$(( sec%60 ))
    printf "10.0.0.1 [06/Aug/2026:10:%02d:%02d +0200] \"GET /fastfar HTTP/1.1\" 200 100 100 - UA\n" "$mm" "$ss" >> "$_FIX/access_noncause.log"
done
v="$(_verdict "$_FIX/gc_5pause.log" "$_FIX/access_noncause.log" 500)"
assert_eq "8% correlato, lift 0.8×: 'NON e' la causa principale'" "NON e' la causa principale" "$v"
full="$(_full "$_FIX/gc_5pause.log" "$_FIX/access_noncause.log" 500)"
assert_contains "4/50 lente correlate (8%)" "Di cui correlate a pausa GC (±2s): 4 (8%)" "$full"
assert_not_contains "non è 'non discriminabile' (campione sufficiente)" "NON DISCRIMINABILE" "$full"
assert_not_contains "non è pervasivo" "PERVASIVO" "$full"

section "Verdetto — GC pervasivo (PERVASIVE)"

# 10 pause ogni 3s: gli intervalli ±2s si sovrappongono (5s di margine su 3s
# di passo) e si fondono in un blocco continuo — la vicinanza a una pausa
# non discrimina più nulla, a prescindere dal campione. Deve prevalere
# SUL campione minimo, non dopo di esso (il bug che questo test blocca): con
# pause così dense pct_fast tende al 100%, che farebbe fallire il guard e
# darebbe "non discriminabile" invece di "pervasivo" se l'ordine fosse
# sbagliato.
cat > "$_FIX/gc_pervasive.log" <<'EOF'
[2026-08-06T10:00:00.000+0200] GC(1) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:03.000+0200] GC(2) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:06.000+0200] GC(3) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:09.000+0200] GC(4) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:12.000+0200] GC(5) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:15.000+0200] GC(6) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:18.000+0200] GC(7) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:21.000+0200] GC(8) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:24.000+0200] GC(9) Pause Young (Normal) 100M->40M(512M) 10.000ms
[2026-08-06T10:00:27.000+0200] GC(10) Pause Young (Normal) 100M->40M(512M) 10.000ms
EOF
cat > "$_FIX/access_pervasive.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:01 +0200] "GET /slow HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:07 +0200] "GET /slow HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:13 +0200] "GET /slow HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:19 +0200] "GET /slow HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:25 +0200] "GET /slow HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:02 +0200] "GET /fast HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:08 +0200] "GET /fast HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:14 +0200] "GET /fast HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:20 +0200] "GET /fast HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:26 +0200] "GET /fast HTTP/1.1" 200 100 100 - UA
EOF
v="$(_verdict "$_FIX/gc_pervasive.log" "$_FIX/access_pervasive.log" 500)"
assert_eq "pause ogni 3s, copertura satura: 'PERVASIVO'" "PERVASIVO" "$v"
full="$(_full "$_FIX/gc_pervasive.log" "$_FIX/access_pervasive.log" 500)"
assert_contains "copertura 100% della finestra" "100%" "$full"
assert_not_contains "non è 'non discriminabile' (la copertura vince sul campione)" "NON DISCRIMINABILE" "$full"
assert_not_contains "non è 'probabile causa'" "PROBABILE CAUSA" "$full"
assert_not_contains "non è 'non è la causa'" "NON e' la causa principale" "$full"
assert_contains "'Gruppo di controllo' resta corretto sotto PERVASIVE (5/5, 100%)" \
    "Gruppo di controllo (richieste veloci): 5/5 (100%)" "$full"

section "Segno del Δ (pausa prima/dopo la richiesta)"

# Pausa alle 10:00:10. Richiesta 2s PRIMA (10:00:08) → la pausa arriva DOPO:
# Δ positivo. Richiesta 2s DOPO (10:00:12) → la pausa è arrivata PRIMA:
# Δ negativo. Il segno non era osservabile prima di GCCORR-1 (i due rami
# erano uniti in un `||` che perdeva l'informazione).
full="$(_full "$_FIX/gc.log" "$_FIX/access.log" 500)"
assert_contains "richiesta 2s prima della pausa: Δ+2s (pausa dopo)" "Δ+2s" "$full"
assert_contains "richiesta 2s dopo la pausa: Δ-2s (pausa prima)" "Δ-2s" "$full"

section "Righe regione (Eden/Old) sulla pausa, senza inquinare i conteggi"

cat > "$_FIX/gc_noregion.log" <<'EOF'
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
cat > "$_FIX/gc_withregion.log" <<'EOF'
[2026-08-06T10:00:10.100+0200][info][gc,heap] GC(1) Eden regions: 24->0(25)
[2026-08-06T10:00:10.110+0200][info][gc,heap] GC(1) Old regions: 50->200
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
EOF
cat > "$_FIX/access_region.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:10:00:11 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
EOF
assert_eq "senza righe regione: conteggio base" \
    "2/2 2" "$(_run "$_FIX/gc_noregion.log" "$_FIX/access_region.log" 500)"
assert_eq "con righe regione: conteggio IDENTICO (nessuna pollution di total_requests)" \
    "2/2 2" "$(_run "$_FIX/gc_withregion.log" "$_FIX/access_region.log" 500)"
full="$(_full "$_FIX/gc_withregion.log" "$_FIX/access_region.log" 500)"
assert_contains "Eden e Old compaiono sulla riga della pausa" "Eden 0/25  Old 200" "$full"
full_noregion="$(_full "$_FIX/gc_noregion.log" "$_FIX/access_region.log" 500)"
assert_not_contains "senza righe regione: nessun 'Eden' spurio" "Eden" "$full_noregion"

section "Attribuzione regioni cross-rotazione (GC(N) non univoco, principio 8)"

# GC(1) compare due volte: la prima con regioni proprie, la seconda un'ora
# dopo (restart JVM plausibile) SENZA righe regione davanti. Senza il guard
# _pend_ts (già corretto in gc_stats.awk, parte D di questo lavoro), il
# secondo evento erediterebbe Eden/Old dal primo.
cat > "$_FIX/gc_crossrot.log" <<'EOF'
[2026-08-06T10:00:10.100+0200][info][gc,heap] GC(1) Eden regions: 24->0(25)
[2026-08-06T10:00:10.110+0200][info][gc,heap] GC(1) Old regions: 50->200
[2026-08-06T10:00:10.000+0200] GC(1) Pause Young (Normal) 120M->40M(512M) 45.123ms
[2026-08-06T11:30:00.000+0200] GC(1) Pause Young (Normal) 90M->30M(512M) 12.000ms
EOF
cat > "$_FIX/access_crossrot.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 1500 - UA
10.0.0.1 [06/Aug/2026:11:30:01 +0200] "GET /b HTTP/1.1" 200 100 1500 - UA
EOF
full="$(_full "$_FIX/gc_crossrot.log" "$_FIX/access_crossrot.log" 500)"
riga_prima="$(echo "$full" | grep "10:00:10")"
riga_dopo="$(echo "$full" | grep "11:30:00")"
assert_contains "il primo GC(1) ha Δ medio +0.0s" "Δ medio +0.0s" "$riga_prima"
assert_contains "il primo GC(1) mostra le sue regioni (Eden/Old)" "Eden 0/25  Old 200" "$riga_prima"
assert_contains "il secondo GC(1), un'ora dopo, ha Δ medio -1.0s" "Δ medio -1.0s" "$riga_dopo"
assert_not_contains "il secondo GC(1) NON eredita Eden/Old" "Eden" "$riga_dopo"

section "Footer di troncamento (TRUNC-1)"

# 5 pause distinte, ognuna con una sola richiesta lenta attribuita:
# correlated_count=5, n_att=5. Con max_rows=3 entrambi i footer devono
# comparire (quello sulle righe CORRELATA e quello sulla tabella per pausa).
: > "$_FIX/access_trunc.log"
for m in 00 01 02 03 04; do
    echo "10.0.0.1 [06/Aug/2026:10:${m}:00 +0200] \"GET /slow HTTP/1.1\" 200 100 1500 - UA" >> "$_FIX/access_trunc.log"
done
full="$(_full "$_FIX/gc_5pause.log" "$_FIX/access_trunc.log" 500 3)"
assert_contains "footer righe correlate troncate" "(mostrate le prime 3 di 5 richieste correlate)" "$full"
assert_contains "footer tabella pause troncata" "(mostrate le prime 3 di 5, per richieste attribuite)" "$full"

section "Casi degeneri (nessun fatal, stderr pulito)"

: > "$_FIX/access_totally_empty.log"
out="$(_full "$_FIX/gc.log" "$_FIX/access_totally_empty.log" 500)"
assert_eq "access log vuoto: messaggio esplicito" "Nessuna richiesta access log trovata." "$out"
err="$(_stderr_of "$_FIX/gc.log" "$_FIX/access_totally_empty.log" 500)"
assert_eq "access log vuoto: stderr pulito" "" "$err"

err="$(_stderr_of "$_FIX/gc_empty.log" "$_FIX/access.log" 500)"
assert_eq "gc.log vuoto: stderr pulito" "" "$err"

cat > "$_FIX/access_allfast.log" <<'EOF'
10.0.0.1 [06/Aug/2026:10:00:10 +0200] "GET /a HTTP/1.1" 200 100 100 - UA
10.0.0.1 [06/Aug/2026:10:00:11 +0200] "GET /b HTTP/1.1" 200 100 100 - UA
EOF
err="$(_stderr_of "$_FIX/gc.log" "$_FIX/access_allfast.log" 500)"
assert_eq "zero richieste lente: stderr pulito" "" "$err"
full="$(_full "$_FIX/gc.log" "$_FIX/access_allfast.log" 500)"
assert_contains "zero lente, gruppo di controllo corretto (2/2, 100%, non 0%)" \
    "Gruppo di controllo (richieste veloci): 2/2 (100%)" "$full"

# ─── Riepilogo ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
printf "  PASS: ${GREEN}%d${RESET}   FAIL: ${RED}%d${RESET}   TOTAL: %d\n" "$pass" "$fail" "$(( pass + fail ))"
echo "═══════════════════════════════════════════════════"

[[ "$fail" -eq 0 ]]
