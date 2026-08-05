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
    printf "\n  \033[33mNessuna stringa di ricerca specificata.\033[0m\n"
    printf "  Racchiudi la stringa tra virgolette doppie o singole:\n"
    printf "  \033[2mes: cerca \"NullPointerException\" in prod\033[0m\n"
    printf "  \033[2mes: trova 'claim 1-8101-2026-0473954' nel nodo 5\033[0m\n\n"
    exit 0
fi
if [[ "$sp" == "__MISSING__" ]]; then
    printf "\n  \033[33mNon ho trovato la stringa da cercare.\033[0m\n"
    printf "  Racchiudi la stringa tra virgolette doppie o singole:\n"
    printf "  \033[2mes: cerca \"NullPointerException\" in prod\033[0m\n"
    printf "  \033[2mes: trova 'claim 1-8101-2026-0473954' nel nodo 5\033[0m\n\n"
    exit 0
fi

jobs="${SEARCH_PARALLEL_JOBS:-4}"
tmp_dir=$(mktemp -d)

_R="\033[31m" _Y="\033[33m" _G="\033[32m"
_B="\033[1m"  _D="\033[2m"  _X="\033[0m"

# Limiti di confronto per il filtro temporale riga per riga (sotto). Formato
# "YYYY-MM-DD HH:MM:SS" — stesso formato normalizzato prodotto dall'estrazione
# timestamp, così il confronto è una semplice comparazione di stringhe (nessuna
# chiamata a `date`, coerente con l'ottimizzazione già fatta altrove nel
# progetto per evitare subprocess in loop stretti). TIME_FROM/TIME_TO non
# hanno i secondi: :00/:59 rendono i confronti inclusivi sul minuto.
tf_cmp="" tt_cmp=""
[[ -n "${TIME_FROM:-}" ]] && tf_cmp="${TIME_FROM/T/ }:00"
[[ -n "${TIME_TO:-}"   ]] && tt_cmp="${TIME_TO/T/ }:59"
declare -A _SAL_MONTHS=([Jan]=01 [Feb]=02 [Mar]=03 [Apr]=04 [May]=05 [Jun]=06
                        [Jul]=07 [Aug]=08 [Sep]=09 [Oct]=10 [Nov]=11 [Dec]=12)

# _sal_line_ts LINE — timestamp normalizzato "YYYY-MM-DD HH:MM:SS" di una riga
# di log, o stringa vuota se non riconoscibile (es. continuazione di stack
# trace). Equivalente bash-nativo di log_ts_from_line() (utils-logfiles.sh),
# reimplementato con [[ =~ ]] invece di echo|grep per evitare un fork per
# riga — stesso motivo per cui commit 2ebfa2f ha rimpiazzato echo|grep con
# [[ =~ ]] nativo in query-to-features.sh (112ms → 9ms). Qui il volume di
# righe da controllare (una per match, fino a ~2000 per file) rende la
# differenza analoga.
_sal_line_ts() {
    local _line="$1"
    if [[ "$_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})[T\ ]([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return
    fi
    if [[ "$_line" =~ \[([0-9]{2})/([A-Za-z]{3})/([0-9]{4}):([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local _mnum="${_SAL_MONTHS[${BASH_REMATCH[2]}]:-}"
        [[ -n "$_mnum" ]] && echo "${BASH_REMATCH[3]}-${_mnum}-${BASH_REMATCH[1]} ${BASH_REMATCH[4]}"
    fi
}

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
# _multi_node: unica fonte di verità per "la tabella mostra la colonna nodo" —
# riusata sotto per header, separatore, righe e alternanza colore. Prima erano
# decisioni ripetute con criteri diversi (l'header guardava DETECTED_NODE, le
# righe guardavano "$_n non vuoto") e potevano disallinearsi: bug reale
# (2026-08-05) — in nodo singolo $_n è SEMPRE popolato (ACTIVE_NODE ha default
# "01" in chatbot.sh), quindi le righe mostravano comunque "nodo NN  " mentre
# l'header, guardando DETECTED_NODE, non riservava quello spazio.
if [[ -z "${DETECTED_NODE:-}" && -n "${ACTIVE_ENV:-}" ]]; then
    _multi_node=1
    _scope_label="${ACTIVE_ENV} (tutti i nodi)"
    ENV_NAME="$ACTIVE_ENV" APP="${ACTIVE_APP:-}"
    while IFS= read -r _node_dir; do
        _nnum=$(node_num_from_dir "$_node_dir")
        _app_dir="${_node_dir}/$(eval echo "$APP_SUBPATH")"
        [[ -d "$_app_dir" ]] || continue
        _sal_add "$_app_dir" "$ACCESS_LOG_BASE" "$_nnum"
        _sal_add "$_app_dir" "$SERVER_LOG_BASE" "$_nnum"
        _sal_add "$_app_dir" "$GC_LOG_BASE"     "$_nnum"
        if [[ -n "${GUIDEWIRE_SUBPATH:-}" ]]; then
            _sal_add "${_node_dir}/$(eval echo "$GUIDEWIRE_SUBPATH")" "" "$_nnum"
        fi
    done < <(list_env_node_dirs "${ACTIVE_ENV}")
else
    _multi_node=0
    _scope_label="nodo ${ACTIVE_NODE:-?}"
    access="${ACCESS_LOG:-}"
    server="${SERVER_LOG:-}"
    gc="${GC_LOG:-}"
    [[ -n "$access" ]] && _sal_add "${ACCESS_LOG_DIR:-$(dirname "$access")}" "$ACCESS_LOG_BASE" "${ACTIVE_NODE:-}"
    [[ -n "$server" ]] && _sal_add "${SERVER_LOG_DIR:-$(dirname "$server")}" "$SERVER_LOG_BASE" "${ACTIVE_NODE:-}"
    [[ -n "$gc"     ]] && _sal_add "${GC_LOG_DIR:-$(dirname "$gc")}"         "$GC_LOG_BASE"     "${ACTIVE_NODE:-}"
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
# Ogni subshell scrive "label|hits|first_ts|last_ts|node" in $tmp_dir/NNNNN
pids=()
for (( i=0; i<total_files; i++ )); do
    (
        lbl="${all_labels[$i]}"
        pth="${all_paths[$i]}"
        nod="${all_nodes[$i]}"
        hits=0 first_ts="" last_ts=""

        if [[ "$pth" == *.gz ]]; then
            _matches=$(gunzip -c "$pth" 2>/dev/null | grep -iE "$sp" 2>/dev/null || true)
        else
            _matches=$(grep -iE "$sp" "$pth" 2>/dev/null || true)
        fi

        # Filtro temporale riga per riga — select_log_files() (sopra) filtra solo
        # a livello di FILE (include il file se il suo intervallo si sovrappone
        # al range), non riga per riga. Un log corrente non ruotato copre l'intera
        # giornata: senza questo filtro "ultime 2 ore" restituiva anche match delle
        # 10:10 o delle 06:21 — bug reale (2026-08-05). Stessa logica di in_range()
        # in utils-time.awk (usata da filter_errors.awk), qui in bash perché questo
        # tool non gira su AWK. Righe senza timestamp riconoscibile (continuazioni
        # di stack trace) sono mantenute: scartarle butterebbe via contesto utile
        # e non sono comunque il bersaglio primario del filtro temporale.
        if [[ -n "$tf_cmp" || -n "$tt_cmp" ]]; then
            _filtered=""
            while IFS= read -r _line; do
                [[ -z "$_line" ]] && continue
                _lts=$(_sal_line_ts "$_line")
                if [[ -n "$_lts" ]]; then
                    [[ -n "$tf_cmp" && "$_lts" < "$tf_cmp" ]] && continue
                    [[ -n "$tt_cmp" && "$_lts" > "$tt_cmp" ]] && continue
                fi
                _filtered+="${_line}"$'\n'
            done <<< "$_matches"
            _matches="${_filtered%$'\n'}"
        fi

        hits=$(echo "$_matches" | grep -c '' 2>/dev/null || true)
        # grep -c '' conta 1 anche su stringa vuota — correggiamo
        [[ -z "$_matches" ]] && hits=0
        if [[ "$hits" -gt 0 ]]; then
            # Filtra solo le righe con timestamp riconoscibile (evita righe di stack trace)
            _ts_lines=$(echo "$_matches" | grep -E \
                '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}|\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:' \
                2>/dev/null || true)
            first_ts=$(log_ts_from_line "$(echo "$_ts_lines" | head -1)")
            last_ts=$(log_ts_from_line "$(echo "$_ts_lines" | tail -1)")
        fi

        printf "%s|%s|%s|%s|%s\n" "$lbl" "${hits:-0}" "${first_ts:-}" "${last_ts:-}" "${nod:-}" \
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
res_labels=() res_hits=() res_ts=() res_last=() res_nodes=()
max_hits=0 max_lbl=8 total_hits=0 matched_files=0

for (( i=0; i<total_files; i++ )); do
    _f="$tmp_dir/$(printf '%05d' "$i")"
    if [[ -f "$_f" ]]; then
        IFS='|' read -r rl rh rt rlast rn < "$_f"
    else
        rl="${all_labels[$i]}" rh=0 rt="" rlast="" rn="${all_nodes[$i]:-}"
    fi
    res_labels+=("${rl:-?}")
    res_hits+=("${rh:-0}")
    res_ts+=("${rt:-}")
    res_last+=("${rlast:-}")
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

# ── Tabella: nodo · filename · barra · conteggio · primo match · ultimo match ─
bar_max=12 best_hits=0 best_node=""
_prev_node="" _row_dim=0

# Larghezza colonna nodo calcolata dalla lunghezza reale dei numeri di nodo
# raccolti (non una costante scritta a mano): "nodo " (5) + cifre + 2 spazi.
# Così un nodo a 3 cifre (es. "100") non disallinea più header/separatore/righe
# come con la larghezza fissa 9 di prima.
_node_w=0
if [[ "$_multi_node" -eq 1 ]]; then
    for _rn in "${res_nodes[@]}"; do
        [[ "${#_rn}" -gt "$_node_w" ]] && _node_w="${#_rn}"
    done
fi
_node_col_w=0
[[ "$_multi_node" -eq 1 ]] && _node_col_w=$(( 5 + _node_w + 2 ))

# Header — colonna nodo presente solo in modalità multi-nodo, stessa larghezza
# usata sotto per le righe dati (_node_col_w), non più duplicata a mano.
# I separatori │ precedono le colonne timestamp sia nell'header che nei dati.
_node_hdr_str=""
[[ "$_node_col_w" -gt 0 ]] && _node_hdr_str=$(printf "${_D}%-${_node_col_w}s${_X}" "NODO")
printf "  %s${_D}%-${max_lbl}s  %-12s  %6s  │  %-19s  │  %-19s${_X}\n" \
    "$_node_hdr_str" "LOG" "" "MATCH" "PRIMO MATCH" "ULTIMO MATCH"
# Larghezza separatore = colonna nodo (0 se nodo singolo)
#   + max_lbl + 2 + 12 + 2 + 6 + (2+│+2) + 19 + (2+│+2) + 19 = max_lbl + 70
_sep_w=$(( max_lbl + 70 + _node_col_w ))
printf "  ${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 "$_sep_w"))"

for (( i=0; i<total_files; i++ )); do
    _h="${res_hits[$i]:-0}"
    [[ "$_h" -gt 0 ]] || continue

    _l="${res_labels[$i]}"
    _t="${res_ts[$i]}"
    _tlast="${res_last[$i]:-}"
    _n="${res_nodes[$i]:-}"

    # Alternanza colore per gruppo nodo: solo in modalità multi-nodo, altrimenti
    # $_n è costante su tutte le righe (nodo singolo) e la prima riga flipperebbe
    # _row_dim a DIM per il resto della tabella senza motivo — bug reale (2026-08-05).
    if [[ "$_multi_node" -eq 1 && "$_n" != "$_prev_node" ]]; then
        _prev_node="$_n"
        (( _row_dim = 1 - _row_dim ))
    fi
    # _RL: sfondo alternato per gruppo nodo, non solo testo attenuato — DIM (solo
    # riduzione di luminosità del foreground) era troppo poco visibile per essere
    # utile a distinguere i gruppi (segnalato dall'utente, 2026-08-05). \033[100m
    # è sfondo grigio scuro (SGR bright-black, estensione aixterm ampiamente
    # supportata, stesso registro esteso già usato per \033[97m bianco intenso).
    # _RR ("reset riga") sostituisce ogni \033[0m INTERNO alla riga: un reset pieno
    # cancellerebbe anche il background appena impostato, spegnendolo a metà riga.
    # Solo l'ultimo \033[0m di fine riga resta un reset pieno (niente da preservare
    # dopo). Il numero nodo resta sempre bold+white per garantire contrasto su
    # entrambi gli sfondi.
    _RL="\033[0m"
    _RR="\033[0m"
    if [[ "$_row_dim" -eq 1 ]]; then
        _RL="\033[100m"
        _RR="\033[0m\033[100m"
    fi

    bar_len=$(( _h * bar_max / max_hits ))
    [[ "$bar_len" -lt 1 ]] && bar_len=1
    bar="" b=0
    for (( b=0; b<bar_len; b++ )); do bar+="█"; done
    bar_pad=""
    for (( b=bar_len; b<bar_max; b++ )); do bar_pad+=" "; done

    bc="$_G"
    [[ "$_h" -gt $(( max_hits / 3 ))     ]] && bc="$_Y"
    [[ "$_h" -gt $(( max_hits * 2 / 3 )) ]] && bc="$_R"

    # "nodo" in DIM, numero sempre bold+white, filename nella tonalità della riga.
    # Il numero è pad-dato a _node_w cifre così la colonna resta allineata
    # all'header anche quando i nodi hanno lunghezze diverse (es. "4" e "12").
    # Usa _RR (non _X) per non spegnere il background a metà riga.
    node_col=""
    if [[ "$_multi_node" -eq 1 ]]; then
        node_col=$(printf "${_D}nodo ${_RR}\033[1m\033[97m%${_node_w}s${_RR}  " "$_n")
    fi

    printf "  ${_RL}${node_col}%-${max_lbl}s${_RR}  ${bc}%s${_RR}%s  %6d" \
        "$_l" "$bar" "$bar_pad" "$_h"
    printf "  ${_D}│${_RR}  %-19s" "${_t:--}"
    printf "  ${_D}│${_RR}  %-19s${_X}\n" "${_tlast:--}"

    if [[ "$_h" -gt "$best_hits" ]]; then
        best_hits="$_h"; best_node="$_n"
    fi
done

printf "  ${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 "$_sep_w"))"

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
