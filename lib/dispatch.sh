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
    local DIM="\033[2m"
    local RESET="\033[0m"

    printf "\n${BOLD}Cosa so analizzare${RESET}\n\n"

    local first_cat=true
    for cat in "${HELP_CATEGORIES[@]}"; do
        local printed_header=false
        for tool in "${TOOL_NAMES[@]}"; do
            [[ "${TOOL_CATEGORY[$tool]:-}" != "$cat" ]] && continue
            local desc="${TOOL_DESC[$tool]:-}"
            local ex="${TOOL_EXAMPLE[$tool]:-}"
            [[ -z "$desc" ]] && continue

            if [[ "$printed_header" == false ]]; then
                [[ "$first_cat" == false ]] && printf "\n"
                printf "  ${CYAN}${BOLD}%s${RESET}\n" "$cat"
                printed_header=true
                first_cat=false
            fi

            printf "  ${BOLD}%s${RESET}\n" "$desc"
            [[ -n "$ex" ]] && printf "  ${DIM}es: \"%s\"${RESET}\n" "$ex"
        done
    done

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
            eval gawk "$tw_args" -f "$TOOLS_DIR/service_times.awk" \
                "$(open_log "$access")"
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
            printf "\033[36mLog: %s\033[0m\n" "$log_path"
            eval gawk -f "$TOOLS_DIR/tail_named_log.awk" \
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
            printf "\033[36mLog: %s\033[0m  (level=%s)\n" "$log_path" "${LOG_LEVEL:-ERROR}"
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
