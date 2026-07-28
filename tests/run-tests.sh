#!/bin/bash
#
# Test suite neural-log-analyzer.
#
# Uso:
#   bash tests/run-tests.sh [--level1] [--level2 --env <env> --node <node>] [--profile <dir>]
#
# --level1          esegue solo i test di intent (locale, nessun log)
# --level2          esegue anche i test di output (richiede --env e --node)
# --env <env>       ambiente target per level2 (es: prod, coll)
# --node <node>     nodo target per level2 (es: 5, 12)
# --profile <dir>   profilo da usare (default: profiles/liquido)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"

PROFILE_DIR="$ROOT_DIR/profiles/liquido"
RUN_L1=1; RUN_L2=0
L2_ENV=""; L2_NODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --level1)  RUN_L1=1; shift ;;
        --level2)  RUN_L2=1; shift ;;
        --env)     L2_ENV="$2";  shift 2 ;;
        --node)    L2_NODE="$2"; shift 2 ;;
        --profile) PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

export PROFILE_DIR

source "$PROFILE_DIR/domain.conf"

# ─── Colori ──────────────────────────────────────────────────────────────────
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"
BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"

pass=0; fail=0; warn=0

# ─── Helpers ─────────────────────────────────────────────────────────────────
print_header() {
    printf "\n${BOLD}%s${RESET}\n" "$1"
    printf "%s\n" "────────────────────────────────────────────────────────────────────"
}

result_line() {
    local status="$1" label="$2" tool="$3" query="$4" detail="$5"
    case "$status" in
        PASS) printf "${GREEN}PASS${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              pass=$(( pass + 1 )) ;;
        FAIL) printf "${RED}${BOLD}FAIL${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              fail=$(( fail + 1 )) ;;
        WARN) printf "${YELLOW}WARN${RESET}  %-18s  %-45s  %s\n" "$tool" "\"$query\"" "$detail"
              warn=$(( warn + 1 )) ;;
    esac
}

# ─── LEVEL 1: intent test ─────────────────────────────────────────────────────
# Formato: "expected_tool|query"
# Se expected_tool è "NONE" verifica che infer.sh non produca output (sotto soglia)
# Prefisso "!" = verifica che expected_tool NON sia il top-1
INTENT_TESTS=(
    # count_status
    "count_status|quanti errori 500 ci sono stati stamattina"
    "count_status|numero di 4xx nell'ultima ora"
    "!count_status|distribuzione degli errori per endpoint"

    # distribute_status
    "distribute_status|distribuzione degli errori per endpoint in produzione nodo 5"
    "distribute_status|quali api hanno più fallimenti"
    "distribute_status|distribuzione degli errori 400 per endpoint in produzione"

    # slow_requests
    "slow_requests|dammi le chiamate lente in produzione nodo 5"
    "slow_requests|chiamate lente di stamattina"
    "slow_requests|richieste con latenza alta stamattina"
    "!show_help|dammi le chiamate lente in produzione nodo 5"
    "!show_help|chiamate lente di stamattina"

    # traffic_volume
    "traffic_volume|mostrami il volume di traffico di stamattina"
    "traffic_volume|andamento delle richieste per fascia oraria"
    "!show_help|mostrami il volume di traffico di stamattina sul nodo 3"

    # filter_errors
    "filter_errors|errori nel server log del nodo 3"
    "filter_errors|righe di errore nel server.log"

    # service_times
    "service_times|tempi dei servizi backend di stamattina"
    "service_times|latenza dei servizi SOA"

    # gc_stats
    "gc_stats|statistiche GC del nodo 5"
    "gc_stats|pause garbage collector stamattina"

    # correlate_gc_slow
    "correlate_gc_slow|il GC sta causando lentezza sul nodo 6"
    "correlate_gc_slow|correlazione tra pause GC e richieste lente"

    # tail_log
    "tail_log|ultime righe del log"
    "tail_log|ultime 100 righe"

    # filter_ip
    "filter_ip|traffico per indirizzo ip sul nodo 2"
    "filter_ip|traffico dall'ip 10.0.0.1"

    # filter_app_errors
    "filter_app_errors|errori applicativi nascosti sul nodo 8"
    "filter_app_errors|exception loggati come INFO"

    # tail_named_log
    "tail_named_log|ultime righe del cc.log"
    "tail_named_log|dammi la coda del api.log"
    "!grep_named_log|ultime righe del cc.log"

    # grep_named_log — fix backlog
    "grep_named_log|problemi sul cc.log del nodo 12 di produzione"
    "grep_named_log|anomalie nel api.log"
    "grep_named_log|errori nel cc.log"
    "!tail_named_log|problemi sul cc.log del nodo 12"
    "!tail_named_log|anomalie nel api.log"

    # show_help — C14
    "show_help|aiuto"
    "show_help|cosa puoi fare"
    "show_help|help"
    "show_help|che strumenti hai"
)

run_intent_tests() {
    print_header "LEVEL 1 — Intent classification"
    printf "${DIM}%-4s  %-18s  %-45s  %s${RESET}\n" "ESIT" "TOOL ATTESO" "QUERY" "DETTAGLIO"
    echo ""

    for entry in "${INTENT_TESTS[@]}"; do
        negate=0
        expected="${entry%%|*}"
        query="${entry#*|}"
        if [[ "$expected" == "!"* ]]; then
            negate=1
            expected="${expected#!}"
        fi

        top_result=$(PROFILE_DIR="$PROFILE_DIR" bash "$LIB_DIR/infer.sh" "$query" 2>/dev/null | \
            awk '{ if ($2+0 > max) { max=$2+0; line=$0 } } END { print line }')
        top_tool="${top_result%% *}"
        top_prob="${top_result##* }"
        top_pct=$(awk -v p="${top_prob:-0}" 'BEGIN { printf "%.0f", p * 100 }')

        if [[ "$negate" -eq 1 ]]; then
            if [[ "$top_tool" == "$expected" ]]; then
                result_line FAIL "!$expected" "$top_tool" "$query" "→ ${top_pct}% (non doveva essere top-1)"
            else
                result_line PASS "!$expected" "${top_tool:-NONE}" "$query" "top-1=${top_tool} (${top_pct}%) ✓"
            fi
        else
            if [[ "$top_tool" == "$expected" ]]; then
                result_line PASS "$expected" "$top_tool" "$query" "→ ${top_pct}%"
            else
                result_line FAIL "$expected" "${top_tool:-NONE}" "$query" "→ ${top_tool:-NONE} (${top_pct}%) invece di $expected"
            fi
        fi
    done
}

# ─── LEVEL 2: output test ─────────────────────────────────────────────────────
# Formato: "expected_tool|query"
# SKIP_OK = se dispatch stampa [SKIP] è accettabile (log non disponibile per quel nodo)
OUTPUT_TESTS=(
    "slow_requests|chiamate lente"
    "distribute_status|distribuzione errori per endpoint"
    "count_status|quanti errori 500 stamattina"
    "traffic_volume|volume di traffico stamattina"
    "filter_errors|errori nel server log"
    "service_times|tempi dei servizi backend"
    "gc_stats|statistiche GC"
    "correlate_gc_slow|il GC sta causando lentezza"
    "tail_log|ultime 20 righe del log"
    "filter_ip|chi ha fatto più richieste"
    "filter_app_errors|errori applicativi nascosti"
    "grep_named_log|problemi sul cc.log"
    "tail_named_log|ultime righe del cc.log"
    "show_help|aiuto"
)

run_output_tests() {
    if [[ -z "$L2_ENV" || -z "$L2_NODE" ]]; then
        echo "[ERROR] --level2 richiede --env e --node" >&2
        exit 1
    fi

    print_header "LEVEL 2 — Output test (env=$L2_ENV  node=$L2_NODE)"
    printf "${DIM}%-4s  %-18s  %-45s  %s${RESET}\n" "ESIT" "TOOL" "QUERY" "DETTAGLIO"
    echo ""

    for entry in "${OUTPUT_TESTS[@]}"; do
        expected="${entry%%|*}"
        query="${entry#*|}"

        output=$(bash "$ROOT_DIR/chatbot.sh" \
            --profile "$PROFILE_DIR" \
            --env "$L2_ENV" --node "$L2_NODE" \
            --query "$query" 2>&1) || true

        parsed=$(printf '%s\n' "$output" | awk '
            /\[ERROR\]/          { sub(/.*\[ERROR\] /, ""); err=$0; next }
            /\[SKIP\]/           { skip=1; next }
            /Nessun tool attivato|Nessuna riga trovata/ { warn=$0; next }
            END {
                if (err  != "") { print "ERR:" err; exit }
                if (skip)       { print "SKIP:log non disponibile"; exit }
                if (warn != "")  { print "WARN:" warn; exit }
                print "OK:"
            }
        ')
        tag="${parsed%%:*}"
        detail="${parsed#*:}"
        case "$tag" in
            ERR)  result_line FAIL "$expected" "$expected" "$query" "[ERROR] ${detail:0:60}" ;;
            SKIP) result_line WARN "$expected" "$expected" "$query" "[SKIP] $detail" ;;
            WARN) result_line WARN "$expected" "$expected" "$query" "$detail" ;;
            OK)
                preview=$(printf '%s\n' "$output" | awk '
                    /^[│├└┌]/ || /^[[:space:]]*$/ || /^[[:space:]]*\[/ { next }
                    { gsub(/\033\[[0-9;]*m/, ""); sub(/^[[:space:]]+/, ""); print; exit }
                ')
                result_line PASS "$expected" "$expected" "$query" "${preview:0:60}"
                ;;
        esac
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
printf "${BOLD}Neural Log Analyzer — Test Suite${RESET}  profilo: $(basename "$PROFILE_DIR")\n"

[[ "$RUN_L1" -eq 1 ]] && run_intent_tests
[[ "$RUN_L2" -eq 1 ]] && run_output_tests

echo ""
printf "────────────────────────────────────────────────────────────────────\n"
printf "${BOLD}Risultato:${RESET}  "
printf "${GREEN}%d PASS${RESET}  " "$pass"
[[ "$warn" -gt 0 ]] && printf "${YELLOW}%d WARN${RESET}  " "$warn"
[[ "$fail" -gt 0 ]] && printf "${RED}${BOLD}%d FAIL${RESET}" "$fail" || printf "${GREEN}0 FAIL${RESET}"
echo ""

[[ "$fail" -gt 0 ]] && exit 1 || exit 0
