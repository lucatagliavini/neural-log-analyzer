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

dispatch_tool() {
    local tool="$1"
    local access="$ACCESS_LOG"
    local server="${SERVER_LOG:-}"
    local gc="${GC_LOG:-}"

    case "$tool" in
        count_status)
            eval gawk -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        distribute_status)
            eval gawk -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        slow_requests)
            eval gawk -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        traffic_volume)
            eval gawk -f "$TOOLS_DIR/traffic_volume.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        filter_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_errors"; return; }
            eval gawk -f "$TOOLS_DIR/filter_errors.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$server")"
            ;;
        service_times)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per service_times"; return; }
            eval gawk -f "$TOOLS_DIR/service_times.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$server")"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per gc_stats"; return; }
            eval gawk -f "$TOOLS_DIR/gc_stats.awk" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$gc")"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { echo "[SKIP] gc.log non disponibile per correlate_gc_slow"; return; }
            eval gawk -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$(open_log "$gc")" "$(open_log "$access")"
            ;;
        tail_log)
            eval gawk -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$access")"
            ;;
        filter_ip)
            eval gawk -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v time_window="$TIME_WINDOW" \
                "$(open_log "$access")"
            ;;
        filter_app_errors)
            [[ -z "$server" ]] && { echo "[SKIP] server.log non disponibile per filter_app_errors"; return; }
            eval gawk -f "$TOOLS_DIR/filter_app_errors.awk" \
                -v time_window="$TIME_WINDOW" \
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
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}
