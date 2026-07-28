#!/bin/bash
#
# dispatch.sh — invoca il tool AWK corretto in base al nome tool.
# Sourcato da chatbot.sh dopo che PROFILE_DIR, TOOLS_DIR e le variabili
# di contesto (ACCESS_LOG, SERVER_LOG, GC_LOG, GUIDEWIRE_LOG_DIR) sono definite.
#
# Variabili di parametro lette dal chiamante (impostate da param-extract.sh):
#   TIME_WINDOW, STATUS_CODE, THRESHOLD_MS, IP_FILTER, TAIL_N, NAMED_LOG
#

# Apre un log plain o .gz in modo trasparente per gawk.
# Restituisce un'espressione da usare con eval gawk ... $(open_log "$f")
open_log() {
    local f="$1"
    [[ -z "$f" ]] && return
    if [[ "$f" == *.gz ]]; then
        echo "<(gunzip -c '$f')"
    else
        echo "'$f'"
    fi
}

print_help() {
    local BOLD="\033[1m"
    local CYAN="\033[36m"
    local YELLOW="\033[33m"
    local DIM="\033[2m"
    local RESET="\033[0m"

    printf "\n${BOLD}Cosa so analizzare${RESET}\n\n"

    printf "  ${CYAN}${BOLD}Log HTTP (access log)${RESET}\n"
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "chiamate lente"       "Le N richieste HTTP più lente, ordinate per tempo di risposta"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"chiamate lente di stamattina sul nodo 4 di prod\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "distribuzione errori"  "Quali endpoint generano più errori 4xx/5xx"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"distribuzione errori sul nodo 10\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "conteggio status"      "Quante richieste per codice HTTP (200, 404, 500…)"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"quanti errori 500 ci sono stati stamattina\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "volume traffico"       "Andamento delle richieste per fasce di 10 minuti"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"volume traffico del nodo 7 in mattinata\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "traffico per IP"       "Chi ha fatto più richieste, o dettaglio per un IP specifico"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"chi ha fatto più richieste sul nodo 2\""
    printf "\n"

    printf "  ${CYAN}${BOLD}Server log JBoss${RESET}\n"
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "errori e warning"      "Righe ERROR e WARN con classe, thread e messaggio"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"errori nel server log del nodo 3\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "errori applicativi"    "Errori 5xx e exception raggruppati per root cause"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"errori applicativi nascosti sul nodo 8\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "tempi servizi SOA"     "Statistiche di latenza per ogni servizio SOA (avg/min/max)"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"tempi dei servizi backend di stamattina\""
    printf "\n"

    printf "  ${CYAN}${BOLD}GC / JVM${RESET}\n"
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "statistiche GC"        "Pause GC: frequenza, durata, memoria liberata"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"statistiche GC del nodo 5\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "GC e lentezza"         "Correlazione tra pause GC e richieste HTTP lente"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"il GC sta causando lentezza sul nodo 6?\""
    printf "\n"

    printf "  ${CYAN}${BOLD}Log Guidewire (cc.log, api.log, database.log…)${RESET}\n"
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "errori nel log"        "Filtra ERROR o WARN in un log Guidewire specifico"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"errori nel cc.log del nodo 12\""
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "ultime righe"          "Le ultime N righe di un log Guidewire"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"ultime 100 righe del api.log sul nodo 9\""
    printf "\n"

    printf "  ${CYAN}${BOLD}Ricerca cross-log${RESET}\n"
    printf "  ${BOLD}%-20s${RESET}  %s\n"  "cerca ovunque"        "Cerca un pattern in tutti i log del nodo (access, server, GC, Guidewire)"
    printf "  ${DIM}%-20s${RESET}  ${DIM}%s${RESET}\n" "" "es: \"cerca NullPointerException nei log del nodo 5\""
    printf "\n"

    printf "  ${DIM}Specifica sempre env e nodo nella query (es: \"in prod nodo 4\") o all'avvio con --env / --node.${RESET}\n"
    printf "  ${DIM}Digita ${RESET}${BOLD}aiuto${RESET}${DIM} in qualsiasi momento per rivedere questa lista.${RESET}\n\n"
}

dispatch_tool() {
    local tool="$1"
    local access="$ACCESS_LOG"
    local server="${SERVER_LOG:-}"
    local gc="${GC_LOG:-}"
    local tw_args="-f '$LIB_DIR/utils-time.awk' -v time_from='${TIME_FROM:-}' -v time_to='${TIME_TO:-}'"

    case "$tool" in
        count_status)
            eval gawk "$tw_args" -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$(open_log "$access")"
            ;;
        distribute_status)
            eval gawk "$tw_args" -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$(open_log "$access")"
            ;;
        slow_requests)
            eval gawk "$tw_args" -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                "$(open_log "$access")"
            ;;
        traffic_volume)
            eval gawk "$tw_args" -f "$TOOLS_DIR/traffic_volume.awk" \
                "$(open_log "$access")"
            ;;
        filter_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_errors.awk" \
                "$(open_log "$server")"
            ;;
        service_times)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per service_times"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/service_times.awk" \
                "$(open_log "$server")"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per gc_stats"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/gc_stats.awk" \
                "$(open_log "$gc")"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per correlate_gc_slow"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$(open_log "$gc")" "$(open_log "$access")"
            ;;
        tail_log)
            eval gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$access")"
            ;;
        filter_ip)
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v top_n="${TAIL_N:-10}" \
                "$(open_log "$access")"
            ;;
        filter_app_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_app_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_app_errors.awk" \
                "$(open_log "$server")"
            ;;
        tail_named_log)
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            local named_log="${NAMED_LOG:-}"
            if [[ -z "$named_log" ]]; then
                echo "[SKIP] Nessun log Guidewire specificato nella query"
                return
            fi
            local log_path=""
            if [[ -n "$gw_dir" ]]; then
                log_path=$(find "$gw_dir" -maxdepth 1 -name "*-${named_log}.log" 2>/dev/null | head -1)
                if [[ -z "$log_path" ]]; then
                    log_path=$(find "$gw_dir" -maxdepth 1 \
                        \( -name "*${named_log}.log" -o -name "*${named_log}.log.gz" \) \
                        2>/dev/null | grep -v "[0-9]\{10\}" | head -1)
                fi
                if [[ -z "$log_path" ]]; then
                    log_path=$(find "$gw_dir" -maxdepth 1 \
                        \( -name "*${named_log}*.log" -o -name "*${named_log}*.log.gz" \) \
                        2>/dev/null | grep -v "[0-9]\{10\}" | sort | head -1)
                fi
            fi
            if [[ -z "$log_path" ]]; then
                echo "[SKIP] Log '$named_log' non trovato in ${gw_dir:-<gw_dir non impostata>}"
                return
            fi
            echo "  Log: $log_path"
            eval gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$log_path")"
            ;;
        grep_named_log)
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            local named_log="${NAMED_LOG:-}"
            if [[ -z "$named_log" ]]; then
                echo "[SKIP] Nessun log Guidewire specificato nella query"
                return
            fi
            local log_path=""
            if [[ -n "$gw_dir" ]]; then
                log_path=$(find "$gw_dir" -maxdepth 1 -name "*-${named_log}.log" 2>/dev/null | head -1)
                if [[ -z "$log_path" ]]; then
                    log_path=$(find "$gw_dir" -maxdepth 1 \
                        \( -name "*${named_log}.log" -o -name "*${named_log}.log.gz" \) \
                        2>/dev/null | grep -v "[0-9]\{10\}" | head -1)
                fi
                if [[ -z "$log_path" ]]; then
                    log_path=$(find "$gw_dir" -maxdepth 1 \
                        \( -name "*${named_log}*.log" -o -name "*${named_log}*.log.gz" \) \
                        2>/dev/null | grep -v "[0-9]\{10\}" | sort | head -1)
                fi
            fi
            if [[ -z "$log_path" ]]; then
                echo "[SKIP] Log '$named_log' non trovato in ${gw_dir:-<gw_dir non impostata>}"
                return
            fi
            echo "  Log: $log_path  (level=${LOG_LEVEL:-ERROR})"
            eval gawk "$tw_args" -f "$TOOLS_DIR/grep_named_log.awk" \
                -v level="${LOG_LEVEL:-ERROR}" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$log_path")"
            ;;
        search_all_logs)
            local sp="${SEARCH_PATTERN:-}"
            if [[ -z "$sp" ]]; then
                echo "[SKIP] Nessun pattern di ricerca specificato nella query"
                return
            fi
            local total=0
            local searched=0

            # Funzione interna: esegue il tool su un singolo log e aggiorna totale
            _search_one() {
                local label="$1" path="$2"
                [[ -z "$path" ]] && return
                local out
                out=$(eval gawk \
                    -f "'$TOOLS_DIR/search_all_logs.awk'" \
                    -v pattern="'$sp'" \
                    -v log_label="'$label'" \
                    -v context_n=1 \
                    -v max_matches=20 \
                    "$(open_log "$path")" 2>/dev/null)
                searched=$(( searched + 1 ))
                local hits
                hits=$(printf '%s\n' "$out" | awk '/^__MATCHES__/ {print $3}')
                total=$(( total + ${hits:-0} ))
                # Stampa tutto tranne la riga __MATCHES__
                printf '%s\n' "$out" | grep -v "^__MATCHES__"
            }

            # Log HTTP
            [[ -n "$access" ]] && _search_one "access.log" "$access"
            # Log JBoss
            [[ -n "$server" ]] && _search_one "server.log" "$server"
            # Log GC
            [[ -n "$gc"     ]] && _search_one "gc.log"     "$gc"
            # Log Guidewire — tutti i .log nella directory
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            if [[ -n "$gw_dir" && -d "$gw_dir" ]]; then
                while IFS= read -r gw_file; do
                    local gw_label
                    gw_label=$(basename "$gw_file")
                    _search_one "$gw_label" "$gw_file"
                done < <(find "$gw_dir" -maxdepth 1 \
                    \( -name "*.log" -o -name "*.log.gz" \) \
                    2>/dev/null | grep -v "[0-9]\{10\}" | sort)
            fi

            echo ""
            if [[ "$total" -eq 0 ]]; then
                printf "Nessuna occorrenza di \033[1m%s\033[0m trovata in %d log.\n" "$sp" "$searched"
            else
                printf "\033[1mTotale:\033[0m %d occorrenze in %d log analizzati.\n" "$total" "$searched"
            fi
            ;;

        show_help)
            print_help
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}
