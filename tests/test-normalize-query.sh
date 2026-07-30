#!/bin/bash
#
# test-normalize-query.sh — unit test per lib/normalize-query.sh
#
# Uso: bash tests/test-normalize-query.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
export PROFILE_DIR="$PROJECT_DIR/profiles/liquido"

PASS=0
FAIL=0

# eval in funzione bash non propaga le variabili allo scope chiamante.
# Usiamo un file temporaneo per passare il risultato all'esterno.
_NORM_TMP=$(mktemp)
trap 'rm -f "$_NORM_TMP"' EXIT

_run() {
    local query="$1"
    "$LIB_DIR/normalize-query.sh" "$query" 2>/dev/null > "$_NORM_TMP"
    # Unset prima per evitare che un run precedente inquini il successivo
    unset NORM_QUERY DETECTED_APP DETECTED_ENV DETECTED_NODE
    source "$_NORM_TMP"
}

assert_eq() {
    local label="$1" got="$2" expected="$3"
    if [[ "$got" == "$expected" ]]; then
        printf "  \033[32mPASS\033[0m  %s\n" "$label"
        (( PASS++ ))
    else
        printf "  \033[31mFAIL\033[0m  %s\n        got:      '%s'\n        expected: '%s'\n" \
               "$label" "$got" "$expected"
        (( FAIL++ ))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  \033[32mPASS\033[0m  %s\n" "$label"
        (( PASS++ ))
    else
        printf "  \033[31mFAIL\033[0m  %s\n        '%s' non trovato in: '%s'\n" \
               "$label" "$needle" "$haystack"
        (( FAIL++ ))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── APP alias ────────────────────────────────────────────────────────────"

_run "errori jboss di stamattina"
assert_eq "jboss → DETECTED_APP" "$DETECTED_APP" "jboss"
assert_contains "jboss → NORM_QUERY contiene <APP>" "$NORM_QUERY" "<APP>"

_run "problemi su liquido in prod"
assert_eq "liquido → DETECTED_APP" "$DETECTED_APP" "liquido"

_run "anomalie guidewire sul nodo 5"
assert_eq "guidewire → DETECTED_APP" "$DETECTED_APP" "guidewire"

_run "log del claimcenter"
assert_eq "claimcenter → DETECTED_APP" "$DETECTED_APP" "claimcenter"

_run "errori contactmanager"
assert_eq "contactmanager → DETECTED_APP" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── ENV (nomi diretti) ───────────────────────────────────────────────────"

_run "errori in prod nodo 2"
assert_eq "prod → DETECTED_ENV" "$DETECTED_ENV" "prod"
assert_contains "prod → NORM_QUERY contiene <ENV>" "$NORM_QUERY" "<ENV>"

_run "statistiche su cert"
assert_eq "cert → DETECTED_ENV" "$DETECTED_ENV" "cert"

_run "GC su coll nodo 7"
assert_eq "coll → DETECTED_ENV" "$DETECTED_ENV" "coll"

_run "access log di euro"
assert_eq "euro → DETECTED_ENV" "$DETECTED_ENV" "euro"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── ENV (sinonimi italiani) ──────────────────────────────────────────────"

_run "errori in produzione"
assert_eq "produzione → DETECTED_ENV=prod" "$DETECTED_ENV" "prod"

_run "log di integrazione nodo 3"
assert_eq "integrazione → DETECTED_ENV=inte" "$DETECTED_ENV" "inte"

_run "anomalie in collaudo"
assert_eq "collaudo → DETECTED_ENV=coll" "$DETECTED_ENV" "coll"

_run "errori in certificazione"
assert_eq "certificazione → DETECTED_ENV=cert" "$DETECTED_ENV" "cert"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── NODE ─────────────────────────────────────────────────────────────────"

_run "errori nodo 3"
assert_eq "nodo 3 → DETECTED_NODE=3" "$DETECTED_NODE" "3"
assert_contains "nodo 3 → NORM_QUERY contiene <NODE>" "$NORM_QUERY" "<NODE>"

_run "GC su nodo3"
assert_eq "nodo3 → DETECTED_NODE=3" "$DETECTED_NODE" "3"

_run "lentezza worker1"
assert_eq "worker1 → DETECTED_NODE=1" "$DETECTED_NODE" "1"

_run "sul nodo numero 12"
assert_eq "nodo numero 12 → DETECTED_NODE=12" "$DETECTED_NODE" "12"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Hostname completo ────────────────────────────────────────────────────"

_run "errori su lxprworkerliq01"
assert_eq "hostname → DETECTED_ENV=prod" "$DETECTED_ENV" "prod"
assert_eq "hostname → DETECTED_NODE=1"   "$DETECTED_NODE" "1"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Combinazione APP + ENV + NODE ────────────────────────────────────────"

_run "errori jboss in prod nodo 3 stamattina"
assert_eq "combo → DETECTED_APP" "$DETECTED_APP" "jboss"
assert_eq "combo → DETECTED_ENV" "$DETECTED_ENV" "prod"
assert_eq "combo → DETECTED_NODE" "$DETECTED_NODE" "3"
assert_contains "combo → NORM_QUERY <APP>"  "$NORM_QUERY" "<APP>"
assert_contains "combo → NORM_QUERY <ENV>"  "$NORM_QUERY" "<ENV>"
assert_contains "combo → NORM_QUERY <NODE>" "$NORM_QUERY" "<NODE>"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Query senza entità ───────────────────────────────────────────────────"

_run "quanti errori 500 ci sono stati stamattina"
assert_eq "no-entity → DETECTED_APP vuoto"  "$DETECTED_APP"  ""
assert_eq "no-entity → DETECTED_ENV vuoto"  "$DETECTED_ENV"  ""
assert_eq "no-entity → DETECTED_NODE vuoto" "$DETECTED_NODE" ""

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Abbreviazioni (cc, cm) ───────────────────────────────────────────────"

_run "errori nel cc sul nodo 5"
assert_eq "cc → DETECTED_APP=claimcenter" "$DETECTED_APP" "claimcenter"

_run "log cm in cert"
assert_eq "cm → DETECTED_APP=contactmanager" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── Longest-match: contactmanager non matchato come 'contact' ────────────"

_run "log contactmanager in prod"
assert_eq "longest-match contactmanager" "$DETECTED_APP" "contactmanager"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── NORM_QUERY non contiene più i nomi concreti ──────────────────────────"

_run "errori jboss prod nodo 3"
# jboss, prod, nodo 3 devono essere rimpiazzati
if [[ "$NORM_QUERY" != *"jboss"* && "$NORM_QUERY" != *"prod"* && "$NORM_QUERY" != *"nodo"* ]]; then
    printf "  \033[32mPASS\033[0m  NORM_QUERY non contiene token concreti\n"
    (( PASS++ ))
else
    printf "  \033[31mFAIL\033[0m  NORM_QUERY contiene ancora token concreti: '%s'\n" "$NORM_QUERY"
    (( FAIL++ ))
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
printf "═══════════════════════════════════════════════════\n"
printf "  PASS: \033[32m%d\033[0m   FAIL: \033[31m%d\033[0m   TOTAL: %d\n" \
       "$PASS" "$FAIL" "$(( PASS + FAIL ))"
printf "═══════════════════════════════════════════════════\n"
echo ""
[[ "$FAIL" -eq 0 ]]
