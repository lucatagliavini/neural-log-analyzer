#!/bin/bash
#
# search_all_logs.sh — cerca un pattern testuale in tutti i log disponibili.
#
# Riceve il contesto via variabili d'ambiente (impostate da chatbot.sh / dispatch.sh):
#   SEARCH_PATTERN, TIME_FROM, TIME_TO,
#   ACTIVE_ENV, ACTIVE_NODE, ACTIVE_APP,
#   DETECTED_NODE,
#   ACCESS_LOG, ACCESS_LOG_DIR, ACCESS_LOG_BASE,
#   SERVER_LOG, SERVER_LOG_DIR, SERVER_LOG_BASE,
#   GC_LOG, GC_LOG_DIR, GC_LOG_BASE,
#   GUIDEWIRE_LOG_DIR, GUIDEWIRE_SUBPATH,
#   APP_SUBPATH, SEARCH_PARALLEL_JOBS,
#   LIB_DIR (per utils-logfiles.sh e utils-nodes.sh)
#

source "$(dirname "${BASH_SOURCE[0]}")/../utils-logfiles.sh"
# system.conf: ENV_NODE_CODE e altri array associativi non sono esportabili via env
source "$PROFILE_DIR/system.conf"
source "$(dirname "${BASH_SOURCE[0]}")/../utils-nodes.sh"

sp="${SEARCH_PATTERN:-}"
if [[ -z "$sp" ]]; then
    echo "[SKIP] Nessun pattern di ricerca specificato nella query"
    exit 0
fi

jobs="${SEARCH_PARALLEL_JOBS:-4}"
tmp_dir=$(mktemp -d)

_R="\033[31m" _Y="\033[33m" _G="\033[32m"
_B="\033[1m"  _D="\033[2m"  _X="\033[0m"

# Arrays paralleli: un elemento per file trovato
all_labels=() all_paths=() all_nodes=()

# _sal_add DIR BASE NODE_NUM
# Aggiunge a all_* i file di log trovati in DIR.
# BASE non vuoto → select_log_files per quel basename (con filtro temporale).
# BASE vuoto     → tutti i *.log/*.log.gz della directory (es. log Guidewire
#                  in una cartella flat senza basename uniforme).
_sal_add() {
    local dir="$1" base="$2" node_num="${3:-}"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    local -a _flist=()
    if [[ -n "$base" ]]; then
        local list
        list=$(select_log_files "$dir" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
        [[ -z "$list" ]] && return
        IFS='|' read -ra _flist <<< "$list"
    else
        while IFS= read -r _f; do
            _flist+=("$_f")
        done < <(find "$dir" -maxdepth 1 \
            \( -name "*.log" -o -name "*.log.gz" \) \
            2>/dev/null | grep -v "[0-9]\{10\}" | sort)
    fi
    for _f in "${_flist[@]}"; do
        [[ -z "$_f" || ! -f "$_f" ]] && continue
        all_labels+=("$(basename "$_f")")
        all_paths+=("$_f")
        all_nodes+=("${node_num:-}")
    done
}

# ── Costruisce la lista log ───────────────────────────────────────────────────
# Multi-nodo: se la query non specifica un nodo esplicito (DETECTED_NODE vuoto)
# e l'ambiente è noto, itera su tutti i nodi trovati su disco via
# list_env_node_dirs() (utils-nodes.sh).
# Nodo singolo: usa le variabili di contesto già risolte dalla sessione.
if [[ -z "${DETECTED_NODE:-}" && -n "${ACTIVE_ENV:-}" ]]; then
    _scope_label="${ACTIVE_ENV} (tutti i nodi)"
    ENV_NAME="$ACTIVE_ENV" APP="${ACTIVE_APP:-}"
    while IFS= read -r _node_dir; do
        _nnum=$(node_num_from_dir "$_node_dir")
        _app_dir="${_node_dir}/$(eval echo "$APP_SUBPATH")"
        [[ -d "$_app_dir" ]] || continue
        _sal_add "$_app_dir" "${ACCESS_LOG_BASE:-undertow_access_log}" "$_nnum"
        _sal_add "$_app_dir" "${SERVER_LOG_BASE:-server}"              "$_nnum"
        _sal_add "$_app_dir" "${GC_LOG_BASE:-gc}"                      "$_nnum"
        if [[ -n "${GUIDEWIRE_SUBPATH:-}" ]]; then
            _sal_add "${_node_dir}/$(eval echo "$GUIDEWIRE_SUBPATH")" "" "$_nnum"
        fi
    done < <(list_env_node_dirs "${ACTIVE_ENV}")
else
    _scope_label="nodo ${ACTIVE_NODE:-?}"
    access="${ACCESS_LOG:-}"
    server="${SERVER_LOG:-}"
    gc="${GC_LOG:-}"
    [[ -n "$access" ]] && _sal_add "${ACCESS_LOG_DIR:-$(dirname "$access")}" "${ACCESS_LOG_BASE:-undertow_access_log}" "${ACTIVE_NODE:-}"
    [[ -n "$server" ]] && _sal_add "${SERVER_LOG_DIR:-$(dirname "$server")}" "${SERVER_LOG_BASE:-server}"              "${ACTIVE_NODE:-}"
    [[ -n "$gc"     ]] && _sal_add "${GC_LOG_DIR:-$(dirname "$gc")}"         "${GC_LOG_BASE:-gc}"                      "${ACTIVE_NODE:-}"
    _sal_add "${GUIDEWIRE_LOG_DIR:-}" "" "${ACTIVE_NODE:-}"
fi

total_files="${#all_paths[@]}"
if [[ "$total_files" -eq 0 ]]; then
    echo "Nessun log disponibile da cercare."
    rm -rf "$tmp_dir"
    exit 0
fi

tw_label=""
[[ -n "${TIME_FROM:-}" || -n "${TIME_TO:-}" ]] && \
    tw_label="${TIME_FROM:-*}→${TIME_TO:-*}  "
printf "\n${_B}Ricerca:${_X} ${_Y}%s${_X}  ${_D}%s%s  (%d file, %d worker)${_X}\n\n" \
    "$sp" "$tw_label" "$_scope_label" "$total_files" "$jobs"

# ── Ricerca parallela con pool di $jobs worker ────────────────────────────────
# Ogni subshell scrive "label|hits|first_ts|size_kb|node" in $tmp_dir/NNNNN
pids=()
for (( i=0; i<total_files; i++ )); do
    (
        lbl="${all_labels[$i]}"
        pth="${all_paths[$i]}"
        nod="${all_nodes[$i]}"
        hits=0 first_ts="" kb=0

        sb=$(stat -c%s "$pth" 2>/dev/null || echo 0)
        kb=$(( ${sb:-0} / 1024 ))

        if [[ "$pth" == *.gz ]]; then
            hits=$(gunzip -c "$pth" 2>/dev/null | grep -ciE "$sp" 2>/dev/null || true)
            hits="${hits:-0}"
            if [[ "$hits" -gt 0 ]]; then
                _fline=$(gunzip -c "$pth" 2>/dev/null | grep -m 1 -iE "$sp" 2>/dev/null || true)
                first_ts=$(log_ts_from_line "$_fline")
            fi
        else
            hits=$(grep -ciE "$sp" "$pth" 2>/dev/null || true)
            hits="${hits:-0}"
            if [[ "$hits" -gt 0 ]]; then
                _fline=$(grep -m 1 -iE "$sp" "$pth" 2>/dev/null || true)
                first_ts=$(log_ts_from_line "$_fline")
            fi
        fi

        printf "%s|%s|%s|%s|%s\n" "$lbl" "${hits:-0}" "${first_ts:-}" "${kb:-0}" "${nod:-}" \
            > "$tmp_dir/$(printf '%05d' "$i")"
    ) &
    pids+=($!)
    if [[ "${#pids[@]}" -ge "$jobs" ]]; then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}")
    fi
done
for _p in "${pids[@]}"; do wait "$_p" 2>/dev/null || true; done

# ── Raccoglie e analizza risultati ────────────────────────────────────────────
res_labels=() res_hits=() res_ts=() res_kb=() res_nodes=()
max_hits=0 max_lbl=8 total_hits=0 matched_files=0

for (( i=0; i<total_files; i++ )); do
    _f="$tmp_dir/$(printf '%05d' "$i")"
    if [[ -f "$_f" ]]; then
        IFS='|' read -r rl rh rt rk rn < "$_f"
    else
        rl="${all_labels[$i]}" rh=0 rt="" rk=0 rn="${all_nodes[$i]:-}"
    fi
    res_labels+=("${rl:-?}")
    res_hits+=("${rh:-0}")
    res_ts+=("${rt:-}")
    res_kb+=("${rk:-0}")
    res_nodes+=("${rn:-}")
    [[ "${rh:-0}" -gt "$max_hits" ]] && max_hits="${rh:-0}"
    [[ "${#rl}"   -gt "$max_lbl"  ]] && max_lbl="${#rl}"
    total_hits=$(( total_hits + ${rh:-0} ))
    [[ "${rh:-0}" -gt 0 ]] && matched_files=$(( matched_files + 1 ))
done

if [[ "$matched_files" -eq 0 ]]; then
    printf "${_D}Nessuna occorrenza di ${_X}${_B}%s${_X}${_D} trovata in %d log (%s).${_X}\n\n" \
        "$sp" "$total_files" "$_scope_label"
    rm -rf "$tmp_dir"
    exit 0
fi

# ── Tabella: nodo · barra proporzionale · conteggio · timestamp · dimensione ──
bar_max=12 best_hits=0 best_node=""
_prev_node="" _row_dim=0

for (( i=0; i<total_files; i++ )); do
    _h="${res_hits[$i]:-0}"
    [[ "$_h" -gt 0 ]] || continue

    _l="${res_labels[$i]}"
    _t="${res_ts[$i]}"
    _k="${res_kb[$i]:-0}"
    _n="${res_nodes[$i]:-}"

    if [[ "$_n" != "$_prev_node" ]]; then
        _prev_node="$_n"
        (( _row_dim = 1 - _row_dim ))
    fi
    # _RL: colore riga per "nodo XX  filename" — alterna normale/DIM per gruppo nodo.
    # Il numero nodo è sempre bold+white per garantire contrasto su entrambi gli sfondi.
    # Barra, conteggio, timestamp e dimensione sono sempre a colori pieni (non DIMmati).
    _RL="\033[0m"
    [[ "$_row_dim" -eq 1 ]] && _RL="\033[2m"

    size_str=""
    [[ "$_k" -ge 1024 ]] \
        && size_str=$(awk "BEGIN{printf \"%d MB\",int($_k/1024)}") \
        || size_str="${_k} KB"

    bar_len=$(( _h * bar_max / max_hits ))
    [[ "$bar_len" -lt 1 ]] && bar_len=1
    bar="" b=0
    for (( b=0; b<bar_len; b++ )); do bar+="█"; done
    bar_pad=""
    for (( b=bar_len; b<bar_max; b++ )); do bar_pad+=" "; done

    bc="$_G"
    [[ "$_h" -gt $(( max_hits / 3 ))     ]] && bc="$_Y"
    [[ "$_h" -gt $(( max_hits * 2 / 3 )) ]] && bc="$_R"

    # "nodo" in DIM, numero sempre bold+white, filename nella tonalità della riga
    node_col=""
    [[ -n "$_n" ]] && node_col="${_D}nodo ${_X}\033[1m\033[97m${_n}${_X}  "

    printf "  ${node_col}${_RL}%-${max_lbl}s${_X}  ${bc}%s${_X}%s  %6d" \
        "$_l" "$bar" "$bar_pad" "$_h"
    [[ -n "$_t" ]] && printf "  ${_D}│  %-19s${_X}" "$_t"
    printf "  ${_D}│  %s${_X}\n" "$size_str"

    if [[ "$_h" -gt "$best_hits" ]]; then
        best_hits="$_h"; best_node="$_n"
    fi
done

printf "  ──────────────────────────────────────────────────────────────\n"

skipped=$(( total_files - matched_files ))
printf "  ${_B}Totale:${_X} %d occorrenze in %d log" "$total_hits" "$matched_files"
[[ "$skipped" -gt 0 ]] && printf "${_D}  (%d senza match)${_X}" "$skipped"
printf "\n"

if [[ -z "${DETECTED_NODE:-}" && -n "$best_node" ]]; then
    printf "  ${_D}→ Nodo con più occorrenze: nodo %s — es: \"errori sul nodo %s\"${_X}\n" \
        "$best_node" "$best_node"
fi
echo ""

rm -rf "$tmp_dir"
