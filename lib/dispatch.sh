#!/bin/bash
#
# dispatch.sh — invoca il tool AWK corretto in base al nome tool.
# Sourcato da chatbot.sh dopo che PROFILE_DIR, TOOLS_DIR e le variabili
# di contesto (ACCESS_LOG, SERVER_LOG, GC_LOG, GUIDEWIRE_LOG_DIR) sono definite.
#
# Variabili di parametro lette dal chiamante (impostate da param-extract.sh):
#   TIME_WINDOW, STATUS_CODE, THRESHOLD_MS, IP_FILTER, TAIL_N, NAMED_LOG
#

source "$(dirname "${BASH_SOURCE[0]}")/utils-logfiles.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils-nodes.sh"

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

# Seleziona e apre tutti i file di log per un tipo (access o gc),
# filtrando per range temporale tramite utils-logfiles.sh.
# Uso: eval gawk ... $(open_logs_for DIR BASE)
open_logs_for() {
    local dir="$1" base="$2"
    local list
    list=$(select_log_files "$dir" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
    local out=""
    IFS='|' read -ra _files <<< "$list"
    for f in "${_files[@]}"; do
        [[ -z "$f" ]] && continue
        out+=" $(open_log "$f")"
    done
    # fallback se select_log_files non trova nulla (es. range fuori range disponibile)
    if [[ -z "$out" ]]; then
        local fallback="${dir}/${base}.log"
        [[ -f "$fallback" ]] && out=" $(open_log "$fallback")"
    fi
    echo "$out"
}

# Shorthand per access log e gc log usando le variabili di contesto sessione
open_logs()        { open_logs_for "${ACCESS_LOG_DIR:-$(dirname "$ACCESS_LOG")}" "$ACCESS_LOG_BASE"; }
open_gc_logs()     { open_logs_for "${GC_LOG_DIR:-$(dirname "$GC_LOG")}"         "$GC_LOG_BASE"; }
open_server_logs() { open_logs_for "${SERVER_LOG_DIR:-$(dirname "$SERVER_LOG")}" "$SERVER_LOG_BASE"; }

# Apre solo il file di log corrente (non ruotato), ignorando TIME_FROM/TO e
# senza passare da select_log_files(). Usato da tail_log quando la query
# non nomina un tempo esplicito — vedi TIME_EXPLICIT in chatbot.sh.
open_current_log_for() {
    local dir="$1" base="$2"
    local f="${dir}/${base}.log"
    [[ -f "$f" ]] && open_log "$f"
}
open_current_logs()        { open_current_log_for "${ACCESS_LOG_DIR:-$(dirname "$ACCESS_LOG")}" "$ACCESS_LOG_BASE"; }
open_current_server_logs() { open_current_log_for "${SERVER_LOG_DIR:-$(dirname "$SERVER_LOG")}" "$SERVER_LOG_BASE"; }

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
    local logs_expr

    # Utility AWK caricati come -f fissi in ogni invocazione gawk.
    # SERVER_LOG_FORMAT seleziona il parser del log applicativo (da system.conf).
    # Per aggiungere WebSphere creare utils-websphere.awk con le stesse funzioni
    # parse_server_log() e is_stack_frame(), e impostare SERVER_LOG_FORMAT=websphere.
    if [[ -z "${SERVER_LOG_FORMAT:-}" ]]; then
        echo "[ERROR] SERVER_LOG_FORMAT non impostato in system.conf" >&2
        return 1
    fi
    local fmt="$SERVER_LOG_FORMAT"
    local common_f="-f '$LIB_DIR/utils-time.awk' -f '$LIB_DIR/utils-colors.awk' -f '$LIB_DIR/utils-${fmt}.awk' -f '$LIB_DIR/utils-dedup.awk'"
    local tw_args="$common_f -v time_from='${TIME_FROM:-}' -v time_to='${TIME_TO:-}'"

    case "$tool" in
        count_status)
            eval gawk "$tw_args" -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$(open_logs)"
            ;;
        distribute_status)
            eval gawk "$tw_args" -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$(open_logs)"
            ;;
        slow_requests)
            eval gawk "$tw_args" -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                "$(open_logs)"
            ;;
        traffic_volume)
            eval gawk "$tw_args" -f "$TOOLS_DIR/traffic_volume.awk" \
                "$(open_logs)"
            ;;
        filter_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_errors.awk" \
                "$(open_server_logs)"
            ;;
        service_times)
            eval gawk "$tw_args" -f "$TOOLS_DIR/service_times.awk" \
                "$(open_logs)"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per gc_stats"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/gc_stats.awk" \
                "$(open_gc_logs)"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per correlate_gc_slow"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$(open_gc_logs)" "$(open_logs)"
            ;;
        tail_log)
            # Se la query corrente non nomina un tempo esplicito, il tail ignora
            # TIME_FROM/TO ereditati dalla sessione e legge sempre il file corrente
            # (semantica intuitiva di "tail"). Se invece la query nomina un tempo
            # ("ultime righe di stamattina"), rispetta la finestra: sia nella scelta
            # dei file (select_log_files) sia riga per riga dentro tail_log.awk —
            # senza il filtro riga per riga, un file corrente con ts_start dentro la
            # finestra ma ts_end nel presente farebbe comunque tail delle righe più
            # recenti, fuori dalla finestra richiesta.
            if [[ "${LOG_TYPE:-}" == "server" ]]; then
                [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile"; return; }
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_server_logs)"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-${fmt}.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="server" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_server_logs)"
                    eval gawk -f "'$LIB_DIR/utils-colors.awk'" \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        "$logs_expr"
                fi
            else
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_logs)"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="access" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_logs)"
                    eval gawk -f "'$LIB_DIR/utils-colors.awk'" \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        "$logs_expr"
                fi
            fi
            ;;
        filter_ip)
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v top_n="${TAIL_N:-10}" \
                "$(open_logs)"
            ;;
        filter_app_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_app_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_app_errors.awk" \
                "$(open_server_logs)"
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
            eval gawk -f "'$LIB_DIR/utils-colors.awk'" \
                -f "$TOOLS_DIR/tail_named_log.awk" \
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
            export SEARCH_PATTERN TIME_FROM TIME_TO \
                   ACTIVE_ENV ACTIVE_NODE ACTIVE_APP DETECTED_NODE \
                   ACCESS_LOG ACCESS_LOG_DIR ACCESS_LOG_BASE \
                   SERVER_LOG SERVER_LOG_DIR SERVER_LOG_BASE \
                   GC_LOG GC_LOG_DIR GC_LOG_BASE \
                   GUIDEWIRE_LOG_DIR GUIDEWIRE_SUBPATH APP_SUBPATH \
                   SEARCH_PARALLEL_JOBS LOG_BASE_DIR NODE_NAME_TEMPLATE \
                   ACCESS_LOG_BASE SERVER_LOG_BASE GC_LOG_BASE
            bash "$TOOLS_DIR/search_all_logs.sh"
            ;;

        show_help)
            print_help
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}
