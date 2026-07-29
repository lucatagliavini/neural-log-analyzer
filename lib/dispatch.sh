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
open_logs()        { open_logs_for "${ACCESS_LOG_DIR:-$(dirname "$ACCESS_LOG")}" "${ACCESS_LOG_BASE:-undertow_access_log}"; }
open_gc_logs()     { open_logs_for "${GC_LOG_DIR:-$(dirname "$GC_LOG")}"         "${GC_LOG_BASE:-gc}"; }
open_server_logs() { open_logs_for "${SERVER_LOG_DIR:-$(dirname "$SERVER_LOG")}" "${SERVER_LOG_BASE:-server}"; }

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

    # Utility AWK caricati come -f fissi in ogni invocazione gawk.
    # SERVER_LOG_FORMAT seleziona il parser del log applicativo (default: jboss).
    # Per aggiungere WebSphere creare utils-websphere.awk con le stesse funzioni
    # parse_server_log() e is_stack_frame(), e impostare SERVER_LOG_FORMAT=websphere.
    local fmt="${SERVER_LOG_FORMAT:-jboss}"
    local common_f="-f '$LIB_DIR/utils-time.awk' -f '$LIB_DIR/utils-colors.awk' -f '$LIB_DIR/utils-jboss.awk' -f '$LIB_DIR/utils-dedup.awk'"
    # Sostituisce il parser del server log se il formato è diverso da jboss
    if [[ "$fmt" != "jboss" ]]; then
        common_f="-f '$LIB_DIR/utils-time.awk' -f '$LIB_DIR/utils-colors.awk' -f '$LIB_DIR/utils-${fmt}.awk' -f '$LIB_DIR/utils-dedup.awk'"
    fi
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
            eval gawk -f "'$LIB_DIR/utils-colors.awk'" \
                -f "$TOOLS_DIR/tail_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_logs)"
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
            local sp="${SEARCH_PATTERN:-}"
            if [[ -z "$sp" ]]; then
                echo "[SKIP] Nessun pattern di ricerca specificato nella query"
                return
            fi

            local jobs="${SEARCH_PARALLEL_JOBS:-4}"
            local tmp_dir
            tmp_dir=$(mktemp -d)

            local _R="\033[31m" _Y="\033[33m" _G="\033[32m"
            local _B="\033[1m"  _D="\033[2m"  _X="\033[0m"

            # ── Raccoglie lista log (con selezione temporale via select_log_files) ──
            local -a all_labels=() all_paths=()

            # Aggiunge tutti i file selezionati per un tipo di log
            _sal_add() {
                local dir="$1" base="$2"
                [[ -z "$dir" ]] && return
                local list
                list=$(select_log_files "$dir" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
                [[ -z "$list" ]] && return
                IFS='|' read -ra _flist <<< "$list"
                for _f in "${_flist[@]}"; do
                    [[ -z "$_f" || ! -f "$_f" ]] && continue
                    all_labels+=("$(basename "$_f")")
                    all_paths+=("$_f")
                done
            }

            [[ -n "$access" ]] && _sal_add "${ACCESS_LOG_DIR:-$(dirname "$access")}" "${ACCESS_LOG_BASE:-undertow_access_log}"
            [[ -n "$server" ]] && _sal_add "${SERVER_LOG_DIR:-$(dirname "$server")}" "${SERVER_LOG_BASE:-server}"
            [[ -n "$gc"     ]] && _sal_add "${GC_LOG_DIR:-$(dirname "$gc")}"         "${GC_LOG_BASE:-gc}"
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            if [[ -n "$gw_dir" && -d "$gw_dir" ]]; then
                while IFS= read -r gw_file; do
                    all_labels+=("$(basename "$gw_file")")
                    all_paths+=("$gw_file")
                done < <(find "$gw_dir" -maxdepth 1 \
                    \( -name "*.log" -o -name "*.log.gz" \) \
                    2>/dev/null | grep -v "[0-9]\{10\}" | sort)
            fi

            local total_files="${#all_paths[@]}"
            if [[ "$total_files" -eq 0 ]]; then
                echo "Nessun log disponibile da cercare."
                rm -rf "$tmp_dir"
                return
            fi

            local tw_label=""
            [[ -n "${TIME_FROM:-}" || -n "${TIME_TO:-}" ]] && \
                tw_label="${TIME_FROM:-*}→${TIME_TO:-*}  "
            printf "\n${_B}Ricerca:${_X} ${_Y}%s${_X}  ${_D}%s(%d file, %d worker)${_X}\n\n" \
                "$sp" "$tw_label" "$total_files" "$jobs"

            # ── Ricerca parallela con pool di $jobs worker ────────────────
            # Ogni subshell scrive "label|hits|first_ts|size_kb" in $tmp_dir/NNNNN
            local -a pids=()
            for (( i=0; i<total_files; i++ )); do
                (
                    local lbl="${all_labels[$i]}"
                    local pth="${all_paths[$i]}"
                    local hits=0 first_ts="" kb=0

                    local sb
                    sb=$(stat -c%s "$pth" 2>/dev/null || echo 0)
                    kb=$(( ${sb:-0} / 1024 ))

                    if [[ "$pth" == *.gz ]]; then
                        hits=$(gunzip -c "$pth" 2>/dev/null | grep -cE "$sp" 2>/dev/null || true)
                        hits="${hits:-0}"
                        if [[ "$hits" -gt 0 ]]; then
                            first_ts=$(gunzip -c "$pth" 2>/dev/null | grep -m 1 -E "$sp" 2>/dev/null \
                                | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
                                | head -1)
                        fi
                    else
                        hits=$(grep -cE "$sp" "$pth" 2>/dev/null || true)
                        hits="${hits:-0}"
                        if [[ "$hits" -gt 0 ]]; then
                            first_ts=$(grep -m 1 -E "$sp" "$pth" 2>/dev/null \
                                | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
                                | head -1)
                        fi
                    fi

                    printf "%s|%s|%s|%s\n" "$lbl" "${hits:-0}" "${first_ts:-}" "${kb:-0}" \
                        > "$tmp_dir/$(printf '%05d' "$i")"
                ) &
                pids+=($!)
                if [[ "${#pids[@]}" -ge "$jobs" ]]; then
                    wait "${pids[0]}" 2>/dev/null
                    pids=("${pids[@]:1}")
                fi
            done
            for _p in "${pids[@]}"; do wait "$_p" 2>/dev/null; done

            # ── Raccoglie e analizza risultati ────────────────────────────
            local -a res_labels=() res_hits=() res_ts=() res_kb=()
            local max_hits=0 max_lbl=8 total_hits=0 matched_files=0

            for (( i=0; i<total_files; i++ )); do
                local _f="$tmp_dir/$(printf '%05d' "$i")"
                local rl rh rt rk
                if [[ -f "$_f" ]]; then
                    IFS='|' read -r rl rh rt rk < "$_f"
                else
                    rl="${all_labels[$i]}" rh=0 rt="" rk=0
                fi
                res_labels+=("${rl:-?}")
                res_hits+=("${rh:-0}")
                res_ts+=("${rt:-}")
                res_kb+=("${rk:-0}")
                [[ "${rh:-0}" -gt "$max_hits" ]] && max_hits="${rh:-0}"
                [[ "${#rl}"   -gt "$max_lbl"  ]] && max_lbl="${#rl}"
                total_hits=$(( total_hits + ${rh:-0} ))
                [[ "${rh:-0}" -gt 0 ]] && matched_files=$(( matched_files + 1 ))
            done

            if [[ "$matched_files" -eq 0 ]]; then
                printf "${_D}Nessuna occorrenza di ${_X}${_B}%s${_X}${_D} trovata in %d log.${_X}\n\n" \
                    "$sp" "$total_files"
                rm -rf "$tmp_dir"
                return
            fi

            # ── Tabella: barre proporzionali, timestamp, dimensione ───────
            local bar_max=12 best_label="" best_hits=0

            for (( i=0; i<total_files; i++ )); do
                local _h="${res_hits[$i]:-0}"
                [[ "$_h" -gt 0 ]] || continue

                local _l="${res_labels[$i]}"
                local _t="${res_ts[$i]}"
                local _k="${res_kb[$i]:-0}"

                local size_str
                [[ "$_k" -ge 1024 ]] \
                    && size_str=$(awk "BEGIN{printf \"%d MB\",int($_k/1024)}") \
                    || size_str="${_k} KB"

                local bar_len=$(( _h * bar_max / max_hits ))
                [[ "$bar_len" -lt 1 ]] && bar_len=1
                local bar="" b
                for (( b=0; b<bar_len; b++ )); do bar+="█"; done

                local bc="$_G"
                [[ "$_h" -gt $(( max_hits / 3 ))     ]] && bc="$_Y"
                [[ "$_h" -gt $(( max_hits * 2 / 3 )) ]] && bc="$_R"

                printf "  %-${max_lbl}s  ${bc}%-${bar_max}s${_X}  %6d" "$_l" "$bar" "$_h"
                [[ -n "$_t" ]] && printf "  ${_D}│  %-19s${_X}" "$_t"
                printf "  ${_D}│  %s${_X}\n" "$size_str"

                if [[ "$_h" -gt "$best_hits" ]]; then
                    best_hits="$_h"; best_label="$_l"
                fi
            done

            printf "  ──────────────────────────────────────────────────────────────\n"

            local skipped=$(( total_files - matched_files ))
            printf "  ${_B}Totale:${_X} %d occorrenze in %d log" "$total_hits" "$matched_files"
            [[ "$skipped" -gt 0 ]] && printf "${_D}  (%d senza match)${_X}" "$skipped"
            printf "\n"

            # Suggerimento dettaglio solo per log Guidewire
            if [[ -n "$best_label" ]]; then
                local suggest="${best_label%.log.gz}"
                suggest="${suggest%.log}"
                suggest="${suggest##*-}"
                if [[ "$suggest" != "access" && "$suggest" != "server" && "$suggest" != "gc" ]]; then
                    printf "  ${_D}→ Per dettaglio: \"cerca %s nel %s.log\"${_X}\n" "$sp" "$suggest"
                fi
            fi
            echo ""

            rm -rf "$tmp_dir"
            ;;

        show_help)
            print_help
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}
