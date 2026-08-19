#!/bin/bash
#
# search_all_logs.sh — cerca un pattern testuale in tutti i log disponibili.
#
# Riceve il contesto via variabili d'ambiente (impostate da chatbot.sh / dispatch.sh):
#   SEARCH_PATTERN, TIME_FROM, TIME_TO,
#   ACTIVE_ENV, ACTIVE_NODE, ACTIVE_APP,
#   DETECTED_NODE,
#   LOG_SEARCH_ROOT (directory del nodo — vedi sotto),
#   SEARCH_PARALLEL_JOBS,
#   LIB_DIR (per utils-logfiles.sh e utils-nodes.sh)
#
# Il contratto si ferma a LOG_SEARCH_ROOT (principio 6 di CLAUDE.md): sotto la
# directory del nodo le directory dei log vengono SCOPERTE via
# discover_log_dirs() (utils-logfiles.sh), non enumerate. Prima (fino a
# LOGDISC-2) questo tool costruiva 4 path fissi da APP_SUBPATH e
# CUSTOM_LOG_SUBPATH, quindi un log in una directory arbitraria era nominabile
# con "ultime righe di X.log" ma invisibile a "in quali log c'è X" — l'ultima
# asimmetria rimasta dopo LOGDISC-1.
#
# Cerca in TUTTE le app presenti sotto il nodo, non solo in ACTIVE_APP
# (decisione utente 2026-08-17): il tool si chiama search_ALL_logs e il suo
# TOOL_DESC promette "tutti i log del nodo". La provenienza non è mescolata in
# silenzio — la colonna APP la dichiara quando i match vengono da più di una app
# (principio 6: mai mescolare dati di app diverse SENZA DIRLO; il vincolo è la
# trasparenza, non l'esclusione).
#

source "$(dirname "${BASH_SOURCE[0]}")/../utils-logfiles.sh"
# Tema colore: le C_* arrivano esportate da chatbot.sh (theme_load). Se questo
# script è invocato direttamente (test, debug), non ci sono: si carica il tema
# indicato da BOT_THEME, default mono — nessun colore, come il resto del
# progetto. Senza questo, con `set -u` a monte le C_* non definite sarebbero un
# errore fatale invece di un output senza colori.
if [[ -z "${C_RESET+x}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../utils-theme.sh"
    theme_load "${BOT_THEME:-mono}"
fi
# system.conf: ENV_NODE_CODE e altri array associativi non sono esportabili via env
source "$PROFILE_DIR/system.conf"
source "$(dirname "${BASH_SOURCE[0]}")/../utils-nodes.sh"

sp="${SEARCH_PATTERN:-}"
if [[ -z "$sp" ]]; then
    printf "\n  ${C_WARN}Nessuna stringa di ricerca specificata.${C_RESET}\n"
    printf "  Racchiudi la stringa tra virgolette doppie o singole:\n"
    printf "  ${C_LBL}es: cerca \"NullPointerException\" in prod${C_RESET}\n"
    printf "  ${C_LBL}es: trova 'claim 1-8101-2026-0473954' nel nodo 5${C_RESET}\n\n"
    exit 0
fi
if [[ "$sp" == "__MISSING__" ]]; then
    printf "\n  ${C_WARN}Non ho trovato la stringa da cercare.${C_RESET}\n"
    printf "  Racchiudi la stringa tra virgolette doppie o singole:\n"
    printf "  ${C_LBL}es: cerca \"NullPointerException\" in prod${C_RESET}\n"
    printf "  ${C_LBL}es: trova 'claim 1-8101-2026-0473954' nel nodo 5${C_RESET}\n\n"
    exit 0
fi

jobs="${SEARCH_PARALLEL_JOBS:-4}"
tmp_dir=$(mktemp -d)
_AWK_TOOL="$(dirname "${BASH_SOURCE[0]}")/search_all_logs.awk"
# Il riconoscimento del timestamp è delegato a logline_parse() (utils-logline.awk,
# che a sua volta richiede utils-time.awk per l'epoch) — non più regex proprie.
_TIME_AWK="$(dirname "${BASH_SOURCE[0]}")/../utils-time.awk"
_LOGLINE_AWK="$(dirname "${BASH_SOURCE[0]}")/../utils-logline.awk"

_R="${C_CRIT}" _Y="${C_WARN}" _G="${C_OK}"
_B="${C_BOLD}"  _D="${C_LBL}"  _X="${C_RESET}"

# Feedback progressivo: progress_show/progress_clear vivono in utils-log.sh
# (sourcato via utils-logfiles.sh), non qui — la fase "selezione log" avviene
# nel motore condiviso e vale per tutti i tool, non solo per questo
# (principio 2+4 di CLAUDE.md). Restano specifici di search_all_logs solo i
# messaggi della fase di RICERCA: è l'unico tool che itera su una lista di
# file con un pool di worker, mentre gli altri passano l'intera lista a un
# solo gawk in una volta.

# Limiti di confronto per il filtro temporale (passati a search_all_logs.awk).
# Formato "YYYY-MM-DD HH:MM:SS", stesso formato prodotto dall'estrazione
# timestamp: il confronto è una semplice comparazione di stringhe. TIME_FROM/
# TIME_TO non hanno i secondi: :00/:59 rendono i confronti inclusivi sul minuto.
tf_cmp="" tt_cmp=""
[[ -n "${TIME_FROM:-}" ]] && tf_cmp="${TIME_FROM/T/ }:00"
[[ -n "${TIME_TO:-}"   ]] && tt_cmp="${TIME_TO/T/ }:59"

# Arrays paralleli: un elemento per file trovato
all_labels=() all_paths=() all_nodes=() all_apps=()

# _sal_add DIR BASE NODE_NUM
# Aggiunge a all_* i file di log trovati in DIR, con pre-selezione per
# range temporale via select_log_files_grouped (walk backward, motore
# generalizzato in utils-logfiles.sh).
# BASE non vuoto → select_log_files_grouped ristretto a quel nome logico.
# BASE vuoto     → select_log_files_grouped su TUTTI i nomi logici trovati
#                  in DIR (es. log applicativi custom in una cartella flat
#                  senza basename uniforme) — prima (2026-08-05) un find diretto
#                  con `grep -v "[0-9]\{10\}"` escludeva ogni rotazione con
#                  epoch nel nome, quindi una ricerca "ieri" non poteva mai
#                  vedere lo storico: bug di correttezza silenzioso, non un
#                  problema di performance.
_sal_add() {
    local dir="$1" base="$2" node_num="${3:-}"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    local list
    if [[ -n "$base" ]]; then
        list=$(select_log_files_grouped "$dir" "${TIME_FROM:-}" "${TIME_TO:-}" "${base}*")
    else
        list=$(select_log_files_grouped "$dir" "${TIME_FROM:-}" "${TIME_TO:-}" "")
    fi
    [[ -z "$list" ]] && return
    local -a _flist=()
    IFS='|' read -ra _flist <<< "$list"
    for _f in "${_flist[@]}"; do
        [[ -z "$_f" || ! -f "$_f" ]] && continue
        all_labels+=("$(basename "$_f")")
        all_paths+=("$_f")
        all_nodes+=("${node_num:-}")
        # App di provenienza: vuota se il path non nomina nessuna delle
        # AVAILABLE_APPS. Il file resta comunque nei risultati (principio 5) e
        # a stampa l'etichetta diventa "-", come per i timestamp assenti.
        all_apps+=("$(resolve_app_from_path "$_f" || true)")
    done
}

# _sal_scan_root ROOT [NODE_NUM]
# Scopre ricorsivamente le directory con log sotto ROOT e le passa a _sal_add.
# BASE vuoto sempre: dopo la scoperta non sappiamo cosa contiene una directory,
# quindi si seleziona ogni nome logico presente — è il ramo che già serviva i
# log applicativi custom in cartella flat.
_sal_scan_root() {
    local root="$1" node_num="${2:-}"
    local _d
    while IFS= read -r _d; do
        [[ -n "$_d" ]] && _sal_add "$_d" "" "$node_num"
    done < <(discover_log_dirs "$root")
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
# Timing delle due fasi, per il log di performance (vedi log_query in
# chatbot.sh): la selezione e la ricerca hanno costi di natura diversa
# (I/O sui primi byte di molti file vs CPU su pochi file grandi) e vanno
# misurate separatamente, altrimenti un rallentamento non è attribuibile.
_t_select_start=$(date +%s%3N 2>/dev/null || echo 0)
progress_show "selezione log..."
if [[ -z "${DETECTED_NODE:-}" && -n "${ACTIVE_ENV:-}" ]]; then
    _multi_node=1
    _scope_label="${ACTIVE_ENV} (tutti i nodi)"
    # _node_dir da list_env_node_dirs È la directory del nodo — lo stesso
    # oggetto che resolve-logs.sh esporta come LOG_SEARCH_ROOT per il nodo
    # attivo. Quindi la scoperta parte da lì, senza APP_SUBPATH.
    while IFS= read -r _node_dir; do
        _nnum=$(node_num_from_dir "$_node_dir")
        progress_show "selezione log: nodo ${_nnum}..."
        _sal_scan_root "$_node_dir" "$_nnum"
    done < <(list_env_node_dirs "${ACTIVE_ENV}")
else
    _multi_node=0
    _scope_label="nodo ${ACTIVE_NODE:-?}"
    _sal_scan_root "${LOG_SEARCH_ROOT:-}" "${ACTIVE_NODE:-}"
fi

progress_clear
_t_select_ms=$(( $(date +%s%3N 2>/dev/null || echo 0) - _t_select_start ))
total_files="${#all_paths[@]}"
if [[ "$total_files" -eq 0 ]]; then
    # Dire DOVE si è cercato: con la scoperta ricorsiva un LOG_SEARCH_ROOT vuoto
    # o inesistente produce zero file, e senza il path il messaggio sarebbe
    # indistinguibile da "il nodo esiste ma non ha log" — lo stesso falso
    # negativo silenzioso corretto in LOGSEL-1.
    if [[ "$_multi_node" -eq 1 ]]; then
        echo "Nessun log disponibile da cercare in ${ACTIVE_ENV} (nessun nodo con log)."
    else
        echo "Nessun log disponibile da cercare sotto ${LOG_SEARCH_ROOT:-<LOG_SEARCH_ROOT non impostata>}."
    fi
    rm -rf "$tmp_dir"
    exit 0
fi

# ── Pre-gate letterale ────────────────────────────────────────────────────────
# `grep -qiF` esce al primo match e tratta il pattern come STRINGA LETTERALE.
# Misurato su file reali di produzione senza match (il caso dominante: 258 su
# 319 nella query multi-nodo): plain 62MB 0.47-0.64s → 0.18-0.36s, gz 2MB
# 0.92-1.39s → 0.58-0.70s, cioè ~2× sulla fase che pesa l'84% del totale.
#
# Perché -F e non -E: i dialetti ERE di gawk e grep divergono su casi come
# `a\.b` o `{brace`, quindi un gate con motore regex diverso da quello di
# analisi rischia di scartare match REALI — falso negativo silenzioso. Con -F
# non c'è interpretazione, quindi non c'è divergenza possibile. Ma vale solo
# se il pattern è davvero letterale: se contiene metacaratteri ERE, l'utente
# intende una regex e il gate va SALTATO (si va diretti a gawk, come prima).
# In caso di dubbio si salta: un file letto inutilmente costa tempo, un match
# perso è un bug.
_use_gate=0
if [[ ! "$sp" =~ [][{}()*+?.^\$\\\|] ]]; then
    _use_gate=1
fi
log_debug "pre-gate letterale: $([[ "$_use_gate" -eq 1 ]] && echo attivo || echo "saltato (pattern con metacaratteri ERE)")"

# Decompressore: GZ_CAT viene da utils-log.sh (pigz -dc se disponibile, 3-4×
# più veloce di gunzip — sui .gz la decompressione è ~90% del costo).
#
# Perché non `zgrep` per il pre-gate: è uno script sh che fa esattamente
# `gzip -cd | grep` (vedi la sua riga 217), con due processi in più — misurato
# PIÙ LENTO di `gunzip -c | grep` sia con pattern assente (0.94-1.43s vs
# 0.88-1.06s) sia con early exit (0.12-0.16s vs 0.02-0.05s, dove l'overhead
# di shell domina il lavoro utile).
log_debug "decompressore .gz: $GZ_CAT"

tw_label=""
[[ -n "${TIME_FROM:-}" || -n "${TIME_TO:-}" ]] && \
    tw_label="${TIME_FROM:-*}→${TIME_TO:-*}  "
printf "\n${_B}Ricerca:${_X} ${_Y}%s${_X}  ${_D}%s%s  (%d file, %d worker)${_X}\n\n" \
    "$sp" "$tw_label" "$_scope_label" "$total_files" "$jobs"

# ── Ricerca parallela con pool di $jobs worker ────────────────────────────────
# Ogni subshell scrive "label|hits|first_ts|last_ts|node|app|partial" in $tmp_dir/NNNNN
_running=0
_t_search_start=$(date +%s%3N 2>/dev/null || echo 0)
for (( i=0; i<total_files; i++ )); do
    # Progresso con risultati PARZIALI: conta i file già completati e le
    # occorrenze trovate fin qui leggendo i file di risultato dei worker.
    # La tabella finale non può essere stampata incrementalmente (serve
    # max_hits per scalare le barre e max_lbl per allineare le colonne, noti
    # solo a fine ricerca), ma l'utente vede che il lavoro procede e con
    # quanti risultati — su una query da 2 minuti è la differenza fra una
    # shell che sembra ferma e una che informa.
    _done=$(find "$tmp_dir" -type f 2>/dev/null | wc -l)
    _found=$(cat "$tmp_dir"/* 2>/dev/null | awk -F'|' '{s+=$2} END{print s+0}')
    progress_show "ricerca: ${_done}/${total_files} file · ${_found} occorrenze · ${all_labels[$i]}"
    (
        lbl="${all_labels[$i]}"
        pth="${all_paths[$i]}"
        nod="${all_nodes[$i]}"
        apl="${all_apps[$i]:-}"
        hits=0 first_ts="" last_ts="" partial=0

        # Due passate gawk sullo STESSO file (search_all_logs.awk: FNR==NR):
        # la prima testa solo il pattern, la seconda — eseguita solo se
        # esiste un candidato — fa il lavoro costoso (timestamp + eredità
        # per le righe di stack trace senza timestamp proprio, necessaria
        # perché una riga come "at ...SearchHubExtApi..." matcha "searchHub"
        # per puro caso testuale — bug reale 2026-08-05). Con la maggioranza
        # dei file senza match (caso comune) questo evita quasi del tutto il
        # costo per-riga del timestamp — misurato 0.27s → 0.03s (2026-08-06).
        # select_log_files() (sopra) filtra solo a livello di FILE (il file è
        # incluso se il suo intervallo si sovrappone al range): un log corrente
        # non ruotato copre l'intera giornata, quindi il filtro riga-per-riga
        # qui resta necessario.
        # Pre-gate: se il pattern è letterale e grep non lo trova, il file non
        # può contenere match e si salta l'intera analisi gawk. `grep -qiF`
        # esce al primo match, quindi sul file CON match costa quasi nulla.
        _skip=0
        if [[ "$_use_gate" -eq 1 ]]; then
            if [[ "$pth" == *.gz ]]; then
                $GZ_CAT "$pth" 2>/dev/null | grep -qiF -- "$sp" || _skip=1
            else
                grep -qiF -- "$sp" "$pth" 2>/dev/null || _skip=1
            fi
        fi

        if [[ "$_skip" -eq 0 ]]; then
            if [[ "$_use_gate" -eq 1 ]]; then
                # Il gate ha già confermato che il pattern c'è: gawk riceve il
                # file UNA volta sola con gated=1, saltando la passata di
                # rilevamento (che sarebbe lavoro duplicato). Sui .gz questo
                # elimina una decompressione su tre — e la decompressione è
                # ~90% del costo di un .gz.
                if [[ "$pth" == *.gz ]]; then
                    _result=$($GZ_CAT "$pth" 2>/dev/null | gawk -v pat="$sp" -v tf="$tf_cmp" -v tt="$tt_cmp" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWK_TOOL" 2>/dev/null)
                else
                    _result=$(gawk -v pat="$sp" -v tf="$tf_cmp" -v tt="$tt_cmp" -v gated=1 -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWK_TOOL" "$pth" 2>/dev/null)
                fi
            elif [[ "$pth" == *.gz ]]; then
                # Senza gate (pattern con metacaratteri ERE) servono due
                # passate. Lo stream .gz non è rigiocabile: due process
                # substitution indipendenti forniscono due decompressioni
                # distinte. Se la prima passata non trova candidati, gawk esce
                # prima di leggere la seconda: il secondo decompressore riceve
                # SIGPIPE e termina subito, senza completare la decompressione.
                _result=$(gawk -v pat="$sp" -v tf="$tf_cmp" -v tt="$tt_cmp" -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWK_TOOL" \
                    <($GZ_CAT "$pth" 2>/dev/null) <($GZ_CAT "$pth" 2>/dev/null) 2>/dev/null)
            else
                _result=$(gawk -v pat="$sp" -v tf="$tf_cmp" -v tt="$tt_cmp" -f "$_TIME_AWK" -f "$_LOGLINE_AWK" -f "$_AWK_TOOL" "$pth" "$pth" 2>/dev/null)
            fi
            IFS='|' read -r hits first_ts last_ts partial <<< "$_result"
        fi

        printf "%s|%s|%s|%s|%s|%s|%s\n" "$lbl" "${hits:-0}" "${first_ts:-}" "${last_ts:-}" "${nod:-}" "${apl:-}" "${partial:-0}" \
            > "$tmp_dir/$(printf '%05d' "$i")"
    ) &
    _running=$(( _running + 1 ))
    # `wait -n` attende il PRIMO worker che finisce, quale che sia. Prima era
    # `wait "${pids[0]}"`, che attendeva il worker più VECCHIO: con file di
    # dimensioni molto diverse (su un nodo reale: 77 vuoti, 65 <100KB, 111
    # <5MB, 36 >5MB) uno slot restava bloccato dietro a un file grande mentre
    # decine di file vuoti aspettavano il loro turno — head-of-line blocking.
    # Misurato su 120 file reali di produzione, a parità di 4 worker:
    # 104.2s → 39.7s (2.6×). Richiede bash ≥ 4.3 (il server ha 5.1).
    if [[ "$_running" -ge "$jobs" ]]; then
        wait -n 2>/dev/null || true
        _running=$(( _running - 1 ))
    fi
done
wait
progress_clear
_t_search_ms=$(( $(date +%s%3N 2>/dev/null || echo 0) - _t_search_start ))

# ── Raccoglie e analizza risultati ────────────────────────────────────────────
res_labels=() res_hits=() res_ts=() res_last=() res_nodes=() res_apps=() res_partial=()
max_hits=0 max_lbl=8 total_hits=0 matched_files=0

for (( i=0; i<total_files; i++ )); do
    _f="$tmp_dir/$(printf '%05d' "$i")"
    if [[ -f "$_f" ]]; then
        IFS='|' read -r rl rh rt rlast rn ra rp < "$_f"
    else
        rl="${all_labels[$i]}" rh=0 rt="" rlast="" rn="${all_nodes[$i]:-}" ra="${all_apps[$i]:-}" rp=0
    fi
    res_labels+=("${rl:-?}")
    res_hits+=("${rh:-0}")
    res_ts+=("${rt:-}")
    res_last+=("${rlast:-}")
    res_nodes+=("${rn:-}")
    res_apps+=("${ra:-}")
    res_partial+=("${rp:-0}")
    [[ "${rh:-0}" -gt "$max_hits" ]] && max_hits="${rh:-0}"
    [[ "${#rl}"   -gt "$max_lbl"  ]] && max_lbl="${#rl}"
    total_hits=$(( total_hits + ${rh:-0} ))
    [[ "${rh:-0}" -gt 0 ]] && matched_files=$(( matched_files + 1 ))
done

# Metriche di performance per l'analisi offline. Scritte su BOT_PERF_FILE (un
# path che chatbot.sh passa via env) perché questo tool gira in un processo
# figlio: le variabili non risalgono al padre. Formato `chiave=valore` per
# riga, così il padre lo sourcia senza parsing.
_perf_bytes=0
for _p in "${all_paths[@]}"; do
    _perf_bytes=$(( _perf_bytes + $(stat -c %s "$_p" 2>/dev/null || echo 0) ))
done
if [[ -n "${BOT_PERF_FILE:-}" ]]; then
    {
        echo "PERF_TOOL=search_all_logs"
        echo "PERF_SELECT_MS=${_t_select_ms:-0}"
        echo "PERF_SEARCH_MS=${_t_search_ms:-0}"
        echo "PERF_FILES=${total_files}"
        echo "PERF_FILES_MATCHED=${matched_files}"
        echo "PERF_BYTES=${_perf_bytes}"
        echo "PERF_JOBS=${jobs}"
        echo "PERF_HITS=${total_hits}"
    } > "$BOT_PERF_FILE" 2>/dev/null || true
fi
log_debug "perf: select=${_t_select_ms}ms search=${_t_search_ms}ms files=${total_files} matched=${matched_files} bytes=${_perf_bytes} jobs=${jobs}"

if [[ "$matched_files" -eq 0 ]]; then
    printf "${_D}Nessuna occorrenza di ${_X}${_B}%s${_X}${_D} trovata in %d log (%s).${_X}\n\n" \
        "$sp" "$total_files" "$_scope_label"
    rm -rf "$tmp_dir"
    exit 0
fi

# ── Tabella: nodo · filename · barra · conteggio · primo match · ultimo match ─
bar_max=12 best_hits=0 best_node=""
_prev_node="" _row_dim=0 _any_partial=0

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

# Colonna APP: presente solo se i match provengono da più di una applicazione,
# stesso criterio condizionale di _multi_node. Se tutti i risultati sono della
# stessa app non c'è nulla da disambiguare, e una colonna col medesimo valore su
# ogni riga sarebbe solo rumore — la ragione per cui _node_col_w è 0 in nodo
# singolo. Calcolato sui match EFFETTIVI (res_apps delle righe con hits > 0),
# non sulla lunghezza di AVAILABLE_APPS: un nodo può avere due app configurate
# ma match in una sola.
# _multi_app è l'unica fonte di verità per header, separatore e righe — nel 2026-08-05
# un criterio duplicato con logiche diverse fra header e righe ha prodotto un
# disallineamento reale su questa stessa tabella.
_multi_app=0 _first_app="" _app_w=0
for (( i=0; i<total_files; i++ )); do
    [[ "${res_hits[$i]:-0}" -gt 0 ]] || continue
    _ra="${res_apps[$i]:-}"
    [[ "${#_ra}" -gt "$_app_w" ]] && _app_w="${#_ra}"
    if [[ -z "$_first_app" ]]; then
        _first_app="$_ra"
    elif [[ "$_ra" != "$_first_app" ]]; then
        _multi_app=1
    fi
done
# Il placeholder "-" per un path non attribuibile occupa 1 carattere: se è il
# valore più lungo (tutte le app ignote) la colonna resta larga 1.
[[ "$_app_w" -lt 1 ]] && _app_w=1
_app_col_w=0
# A differenza del nodo non serve un prefisso testuale: "ClaimCenter" si spiega
# da sé, "04" no (da cui "nodo 04"). Quindi solo il gutter di 2 spazi.
[[ "$_multi_app" -eq 1 ]] && _app_col_w=$(( _app_w + 2 ))
log_debug "tabella: multi_node=$_multi_node multi_app=$_multi_app app_col_w=$_app_col_w"

# Header — colonna nodo presente solo in modalità multi-nodo, stessa larghezza
# usata sotto per le righe dati (_node_col_w), non più duplicata a mano.
# I separatori │ precedono le colonne timestamp sia nell'header che nei dati.
_node_hdr_str=""
[[ "$_node_col_w" -gt 0 ]] && _node_hdr_str=$(printf "${_D}%-${_node_col_w}s${_X}" "NODO")
_app_hdr_str=""
[[ "$_app_col_w" -gt 0 ]] && _app_hdr_str=$(printf "${_D}%-${_app_col_w}s${_X}" "APP")
printf "  %s%s${_D}%-${max_lbl}s  %-12s  %6s  │  %-19s  │  %-19s${_X}\n" \
    "$_node_hdr_str" "$_app_hdr_str" "LOG" "" "MATCH" "PRIMO MATCH" "ULTIMO MATCH"
# Larghezza separatore = colonna nodo (0 se nodo singolo) + colonna app (0 se
# una sola app nei match)
#   + max_lbl + 2 + 12 + 2 + 6 + (2+│+2) + 19 + (2+│+2) + 19 = max_lbl + 70
_sep_w=$(( max_lbl + 70 + _node_col_w + _app_col_w ))
printf "  ${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 "$_sep_w"))"

for (( i=0; i<total_files; i++ )); do
    _h="${res_hits[$i]:-0}"
    [[ "$_h" -gt 0 ]] || continue

    _l="${res_labels[$i]}"
    _t="${res_ts[$i]}"
    _tlast="${res_last[$i]:-}"
    _n="${res_nodes[$i]:-}"
    _a="${res_apps[$i]:-}"
    _p="${res_partial[$i]:-0}"
    [[ "$_p" -eq 1 ]] && _any_partial=1

    # Alternanza colore per gruppo nodo: solo in modalità multi-nodo, altrimenti
    # $_n è costante su tutte le righe (nodo singolo) e la prima riga flipperebbe
    # _row_dim a DIM per il resto della tabella senza motivo — bug reale (2026-08-05).
    if [[ "$_multi_node" -eq 1 && "$_n" != "$_prev_node" ]]; then
        _prev_node="$_n"
        (( _row_dim = 1 - _row_dim ))
    fi
    # _RL: sfondo alternato per gruppo nodo, non solo testo attenuato — DIM (solo
    # riduzione di luminosità del foreground) era troppo poco visibile per essere
    # utile a distinguere i gruppi (segnalato dall'utente, 2026-08-05). ${C_ROW_ALT}
    # è sfondo grigio scuro (SGR bright-black, estensione aixterm ampiamente
    # supportata, stesso registro esteso già usato per ${C_VAL} bianco intenso).
    # _RR ("reset riga") sostituisce ogni ${C_RESET} INTERNO alla riga: un reset pieno
    # cancellerebbe anche il background appena impostato, spegnendolo a metà riga.
    # Solo l'ultimo ${C_RESET} di fine riga resta un reset pieno (niente da preservare
    # dopo). Il numero nodo resta sempre bold+white per garantire contrasto su
    # entrambi gli sfondi.
    _RL="${C_RESET}"
    _RR="${C_RESET}"
    # _FG: colore del testo secondario sulla riga. Fuori dallo sfondo è C_LBL
    # (dim, corretto per un'etichetta); SULLO sfondo alternato dim avvicina il
    # testo al fondo — per costruzione, non per scelta di palette — quindi si usa
    # C_ROW_ALT_FG, che ogni tema definisce per garantire il contrasto sulla
    # propria riga colorata. Segnalato dall'utente sul tema dark (2026-08-06):
    # il nome del nodo e del log erano poco leggibili.
    # Fallback su C_LBL se il tema non definisce il ruolo: comportamento di prima.
    _FG="${_D}"
    if [[ "$_row_dim" -eq 1 ]]; then
        _RL="${C_ROW_ALT}"
        _RR="${C_RESET}${C_ROW_ALT}"
        [[ -n "${C_ROW_ALT_FG:-}" ]] && _FG="${C_ROW_ALT_FG}"
    fi

    bar_len=$(( _h * bar_max / max_hits ))
    [[ "$bar_len" -lt 1 ]] && bar_len=1
    bar="" b=0
    for (( b=0; b<bar_len; b++ )); do bar+="█"; done
    bar_pad=""
    for (( b=bar_len; b<bar_max; b++ )); do bar_pad+=" "; done

    # Gradiente del tema (C_BAR_1..5) invece di verde/giallo/rosso: la barra
    # rappresenta una QUANTITÀ, e verde/giallo/rosso è una scala di giudizio —
    # qui le occorrenze sono di solito errori, quindi "poche" non significa
    # "va bene". Stesse soglie ai quinti di bar_color() in utils-colors.awk,
    # replicate qui perché questo tool è bash e non passa dagli .awk condivisi.
    # Se il tema non definisce la scala, bc resta vuoto: colore di default.
    if   [[ "$max_hits" -le 0 ]];                       then bc="${C_BAR_1:-}"
    elif [[ $(( _h * 100 / max_hits )) -ge 80 ]];        then bc="${C_BAR_5:-}"
    elif [[ $(( _h * 100 / max_hits )) -ge 60 ]];        then bc="${C_BAR_4:-}"
    elif [[ $(( _h * 100 / max_hits )) -ge 40 ]];        then bc="${C_BAR_3:-}"
    elif [[ $(( _h * 100 / max_hits )) -ge 20 ]];        then bc="${C_BAR_2:-}"
    else                                                     bc="${C_BAR_1:-}"
    fi

    # "nodo" in DIM, numero sempre bold+white, filename nella tonalità della riga.
    # Il numero è pad-dato a _node_w cifre così la colonna resta allineata
    # all'header anche quando i nodi hanno lunghezze diverse (es. "4" e "12").
    # Usa _RR (non _X) per non spegnere il background a metà riga.
    node_col=""
    if [[ "$_multi_node" -eq 1 ]]; then
        node_col=$(printf "${_FG}nodo ${_RR}${C_BOLD}${C_VAL}%${_node_w}s${_RR}  " "$_n")
    fi

    # Colonna app: stessa larghezza (_app_w) usata nell'header via _app_col_w,
    # così "LOG" resta allineato fra header e righe per costruzione. "-" quando
    # il path non è attribuibile a nessuna AVAILABLE_APPS — il file è comunque
    # nei risultati (principio 5), non si finge di sapere da dove viene.
    # _RR e non _X: un reset pieno spegnerebbe lo sfondo alternato a metà riga.
    app_col=""
    if [[ "$_multi_app" -eq 1 ]]; then
        app_col=$(printf "${_FG}%-${_app_w}s${_RR}  " "${_a:--}")
    fi

    # Il nome del log usa _FG: sulla riga con sfondo è il foreground del tema,
    # altrove è vuoto (colore di default del terminale), come prima.
    _l_fg=""
    [[ "$_row_dim" -eq 1 && -n "${C_ROW_ALT_FG:-}" ]] && _l_fg="${C_ROW_ALT_FG}"
    printf "  ${_RL}${node_col}${app_col}${_l_fg}%-${max_lbl}s${_RR}  ${bc}%s${_RR}%s  %6d" \
        "$_l" "$bar" "$bar_pad" "$_h"

    # Timestamp parziale (solo-ora, nessuna data nel file — Intervento 3):
    # ruolo tema C_PARTIAL + marcatore testuale "*", quest'ultimo perché il
    # solo colore sparisce nei temi senza ANSI (mono) e la nota a fondo
    # tabella (sotto) deve poter puntare a qualcosa di visibile anche lì.
    _ts_fg="${_l_fg}"
    _t_disp="${_t:--}"; _tlast_disp="${_tlast:--}"
    if [[ "$_p" -eq 1 ]]; then
        _ts_fg="${C_PARTIAL}"
        [[ "$_t_disp"     != "-" ]] && _t_disp="${_t_disp} *"
        [[ "$_tlast_disp" != "-" ]] && _tlast_disp="${_tlast_disp} *"
    fi
    printf "  ${_FG}│${_RR}  ${_ts_fg}%-19s" "$_t_disp"
    printf "  ${_FG}│${_RR}  ${_ts_fg}%-19s${_X}\n" "$_tlast_disp"

    if [[ "$_h" -gt "$best_hits" ]]; then
        best_hits="$_h"; best_node="$_n"
    fi
done

printf "  ${_D}%s${_X}\n" "$(printf '─%.0s' $(seq 1 "$_sep_w"))"

skipped=$(( total_files - matched_files ))
printf "  ${_B}Totale:${_X} %d occorrenze in %d log" "$total_hits" "$matched_files"
[[ "$skipped" -gt 0 ]] && printf "${_D}  (%d senza match)${_X}" "$skipped"
printf "\n"

# "*" = il file non registra una data (es. console.log logga solo l'ora): il
# min/max è sul solo orario, quindi su un file che attraversa la mezzanotte
# non è garantito essere il primo/ultimo evento cronologico — limite del log,
# non del tool.
if [[ "$_any_partial" -eq 1 ]]; then
    printf "  ${C_PARTIAL}* PRIMO/ULTIMO MATCH solo orario: il file non registra la data.${_X}\n"
fi

if [[ -z "${DETECTED_NODE:-}" && -n "$best_node" ]]; then
    printf "  ${_D}→ Nodo con più occorrenze: nodo %s — es: \"errori sul nodo %s\"${_X}\n" \
        "$best_node" "$best_node"
fi
echo ""

rm -rf "$tmp_dir"
