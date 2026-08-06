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
        # GZ_CAT (utils-log.sh): pigz -dc se disponibile, 3-4× più veloce di
        # gunzip. Questo è il punto a maggior leva del progetto per i .gz —
        # ci passano TUTTI i tool che leggono log ruotati.
        echo "<($GZ_CAT '$f')"
    else
        echo "'$f'"
    fi
}

# Seleziona e apre tutti i file di log per un tipo (access o gc),
# filtrando per range temporale tramite utils-logfiles.sh.
# Uso: eval gawk ... $(open_logs_for DIR BASE)
open_logs_for() {
    local dir="$1" base="$2"
    local _t0 _t1
    _t0=$(date +%s%3N 2>/dev/null || echo 0)
    local list
    list=$(select_log_files "$dir" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
    local out="" _nf=0 _nb=0
    IFS='|' read -ra _files <<< "$list"
    for f in "${_files[@]}"; do
        [[ -z "$f" ]] && continue
        out+=" $(open_log "$f")"
        _nf=$(( _nf + 1 ))
        _nb=$(( _nb + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done
    # fallback se select_log_files non trova nulla (es. range fuori range disponibile)
    if [[ -z "$out" ]]; then
        local fallback="${dir}/${base}.log"
        if [[ -f "$fallback" ]]; then
            out=" $(open_log "$fallback")"
            _nf=1
            _nb=$(stat -c %s "$fallback" 2>/dev/null || echo 0)
        fi
    fi
    _t1=$(date +%s%3N 2>/dev/null || echo 0)
    # Metriche di fase per il log di performance. Questa funzione è invocata in
    # `$(...)`, quindi gira in una SUBSHELL: le variabili non risalgono al
    # chiamante e vanno passate via file (_PERF_SELECT_FILE, creato da
    # dispatch_tool). Senza questo passaggio le metriche di selezione
    # risulterebbero sempre 0 per i tool che passano da qui — cioè tutti
    # tranne search_all_logs.
    if [[ -n "${_PERF_SELECT_FILE:-}" ]]; then
        printf '%s %s %s\n' "$(( _t1 - _t0 ))" "$_nf" "$_nb" >> "$_PERF_SELECT_FILE" 2>/dev/null || true
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
#
# Il bypass di select_log_files è intenzionale (non toccarlo, OBS-3): qui si
# aggiungono SOLO le metriche di volume (file/byte), calcolabili con un
# singolo stat sul file scelto — senza le quali dispatch_tool riportava
# PERF_FILES=0/PERF_BYTES=0 per tail_log a riposo, pur leggendo un file reale.
open_current_log_for() {
    local dir="$1" base="$2"
    local f="${dir}/${base}.log"
    local out=""
    # Feedback progressivo anche qui: questo percorso bypassa
    # select_log_files_grouped (che chiama progress_show), quindi tail_log a
    # riposo non mostrava nulla mentre gawk leggeva il file.
    [[ -f "$f" ]] && progress_show "lettura $(basename "$f")..."
    [[ -f "$f" ]] && out=$(open_log "$f")
    if [[ -n "${_PERF_SELECT_FILE:-}" ]]; then
        local _nf=0 _nb=0
        if [[ -f "$f" ]]; then
            _nf=1
            _nb=$(stat -c %s "$f" 2>/dev/null || echo 0)
        fi
        printf '%s %s %s\n' 0 "$_nf" "$_nb" >> "$_PERF_SELECT_FILE" 2>/dev/null || true
    fi
    # Pulisce la riga di progresso prima che il tool stampi su stdout: la riga
    # non ha newline (usa \r), quindi l'output si attaccherebbe ad essa.
    progress_clear
    echo "$out"
}
open_current_logs()        { open_current_log_for "${ACCESS_LOG_DIR:-$(dirname "$ACCESS_LOG")}" "$ACCESS_LOG_BASE"; }
open_current_server_logs() { open_current_log_for "${SERVER_LOG_DIR:-$(dirname "$SERVER_LOG")}" "$SERVER_LOG_BASE"; }

# Espande un glob nell'insieme di file da leggere, rispettando la finestra temporale.
#
# Il glob dell'utente ("*-cc.log") identifica il log corrente; da lì si deriva il
# basename logico e si delega a select_log_files, che è l'unico posto dove vive il
# filtro temporale: così "righe di ieri" seleziona la rotazione .gz giusta invece
# di leggere sempre il file corrente. Prima questo ramo faceva `find | head -1`,
# quindi ignorava sia il tempo sia i .gz.
#
# Uso: logs_expr=$(open_glob_logs DIR GLOB)  → espressione per `eval gawk ...`
open_glob_logs() {
    local dir="$1" glob="$2"
    local _t0 _t1
    _t0=$(date +%s%3N 2>/dev/null || echo 0)
    local chosen
    chosen=$(resolve_log_glob "$dir" "$glob") || return 1
    [[ -z "$chosen" ]] && return 1

    local base
    base=$(logfile_logical_name "$chosen")

    # select_log_files (select_log_files_grouped) raggruppa per nome logico
    # ESATTO dentro il motore: "prod1nsse-cc" non tira più dentro
    # "prod1nsse-ccCanaliz.log". Prima questo era un post-filtro qui
    # (rimosso 2026-08-06, ridondante col motore generalizzato).
    local list expr="" f _nf=0 _nb=0
    list=$(select_log_files "$dir" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
    IFS='|' read -ra _cand <<< "$list"
    for f in "${_cand[@]}"; do
        [[ -z "$f" ]] && continue
        expr+=" $(open_log "$f")"
        _nf=$(( _nf + 1 ))
        _nb=$(( _nb + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done

    # Nessun candidato nella finestra temporale: ricade sul file scelto, così una
    # finestra troppo stretta non produce un output vuoto senza spiegazione.
    if [[ -z "$expr" ]]; then
        expr=" $(open_log "$chosen")"
        _nf=1
        _nb=$(stat -c %s "$chosen" 2>/dev/null || echo 0)
    fi
    _t1=$(date +%s%3N 2>/dev/null || echo 0)
    # Stessa strumentazione di open_logs_for (vedi commento lì): girando in
    # subshell via $(...), le metriche vanno passate per file. tail_named_log/
    # grep_named_log via escape hatch glob passavano prima da qui senza mai
    # emettere selezione/byte — OBS-3.
    if [[ -n "${_PERF_SELECT_FILE:-}" ]]; then
        printf '%s %s %s\n' "$(( _t1 - _t0 ))" "$_nf" "$_nb" >> "$_PERF_SELECT_FILE" 2>/dev/null || true
    fi
    echo "$expr"
}

# Risolve NAMED_LOG a un singolo path su disco, provando in ordine: match
# esatto "*-<nome>.log", poi "*<nome>.log(.gz)" senza rotazioni epoch, poi
# "*<nome>*.log(.gz)" fuzzy. Unica fonte di verità per tail_named_log e
# grep_named_log (prima erano due copie identiche della stessa catena find,
# OBS-3 — principio 2 di CLAUDE.md). Non passa da select_log_files: qui si
# vuole UN file rappresentativo per nome, non le sue rotazioni.
#
# Emette anche le metriche di volume su _PERF_SELECT_FILE (se impostato): un
# solo stat sul file scelto, stesso pattern di open_current_log_for. Prima
# questo ramo non passava da nessuna funzione open_*, quindi selezione/byte
# restavano sempre a 0 anche quando un file veniva letto per intero.
resolve_named_log_path() {
    local gw_dir="$1" named_log="$2"
    local _t0 _t1
    _t0=$(date +%s%3N 2>/dev/null || echo 0)
    local log_path=""
    # Feedback progressivo: come open_current_log_for, questo percorso bypassa
    # select_log_files_grouped (dove vive la chiamata a progress_show), quindi
    # tail_named_log e grep_named_log non mostravano nulla. Conta: dal log di
    # performance in produzione grep_named_log arriva a 3.7s, abbastanza da far
    # sembrare la shell ferma.
    progress_show "ricerca log ${named_log}..."
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
    _t1=$(date +%s%3N 2>/dev/null || echo 0)
    if [[ -n "${_PERF_SELECT_FILE:-}" ]]; then
        local _nf=0 _nb=0
        if [[ -n "$log_path" ]]; then
            _nf=1
            _nb=$(stat -c %s "$log_path" 2>/dev/null || echo 0)
        fi
        printf '%s %s %s\n' "$(( _t1 - _t0 ))" "$_nf" "$_nb" >> "$_PERF_SELECT_FILE" 2>/dev/null || true
    fi
    progress_clear
    echo "$log_path"
}

# Messaggio di skip: il tool non può produrre output (log assente, parametro mancante).
# In giallo perché è un WARNING, non un risultato: prima era testo bianco identico
# all'output normale e si perdeva fra le righe di log.
skip_msg() {
    printf "${C_WARN}[SKIP] %s${C_RESET}\n" "$1"
}

# Estrae i nomi logici dei log ".log" presenti in una directory (Guidewire), uno
# per riga su stdout. Scarta i nomi con caratteri non digitabili: sul nodo esiste
# "${gw.cc.serverid}-messaging.log", un placeholder Guidewire non risolto nella
# loro config — non è un log che qualcuno possa nominare, sarebbe solo rumore.
# Condivisa da suggest_available_logs() (reattivo, su nome sbagliato) e
# list_available_logs() (su richiesta esplicita) — stessa fonte di verità.
_log_names_in_dir() {
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    find "$dir" -maxdepth 1 -name "*.log" 2>/dev/null \
        | sed -E 's|.*/||; s/^[A-Za-z0-9]+-//; s/\.log$//' \
        | grep -E '^[A-Za-z0-9_.-]+$' | sort -u
}

# Stampa un elenco di nomi impaginato in colonne allineate (assume DIM/RESET già
# nell'ambiente chiamante). Su un nodo con 27 log una riga sola sono ~470 caratteri,
# che il terminale spezza dove capita — tagliando i nomi a metà (Card_ / denunce_...)
# e rendendo faticoso cercarne uno a vista.
_print_names_in_columns() {
    local -a names=("$@")
    [[ "${#names[@]}" -eq 0 ]] && return
    local _D="${C_LBL}" _X="${C_RESET}"
    local _w="${COLUMNS:-100}"
    [[ "$_w" -lt 40 ]] && _w=100
    local _line
    if command -v column >/dev/null 2>&1; then
        # `column -c N` impagina la lista in colonne, ma separa con TAB: l'allineamento
        # dipenderebbe dai tab-stop del terminale, e con nomi >8 caratteri le colonne
        # si disallineano. `expand` li converte in spazi. NON usare `-t`, che formatta
        # una tabella da input già colonnato e qui produrrebbe una sola colonna.
        while IFS= read -r _line; do
            printf "    ${_D}%s${_X}\n" "$_line"
        done < <(printf '%s\n' "${names[@]}" | column -c "$((_w - 6))" | expand -t 8)
    else
        # Fallback senza column: 3 per riga a larghezza fissa
        while IFS= read -r _line; do
            printf "    ${_D}%s${_X}\n" "$_line"
        done < <(printf '%s\n' "${names[@]}" | paste -d'\t' - - - \
                 | awk -F'\t' '{printf "%-34s %-34s %s\n", $1, $2, $3}')
    fi
}

# Quando un log richiesto non esiste, elenca quelli realmente presenti sul nodo.
# L'avviso di param-extract.sh mostra gli ALIAS noti da entities.conf, che possono
# divergere dal disco (es. "plugin" in whitelist contro "plugins" reale): qui si
# guarda cosa c'è davvero, che è l'informazione di cui l'utente ha bisogno.
# Se un nome simile esiste lo si mette in evidenza — l'errore tipico è un refuso.
suggest_available_logs() {
    local dir="$1" wanted="${2:-}"
    local -a names=()
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(_log_names_in_dir "$dir")
    [[ "${#names[@]}" -eq 0 ]] && return

    local _D="${C_LBL}" _B="${C_BOLD}" _X="${C_RESET}"
    # Match parziale case-insensitive: cattura i refusi e le differenze di plurale
    if [[ -n "$wanted" ]]; then
        local -a near=()
        local n
        for n in "${names[@]}"; do
            [[ "${n,,}" == *"${wanted,,}"* || "${wanted,,}" == *"${n,,}"* ]] && near+=("$n")
        done
        if [[ "${#near[@]}" -gt 0 ]]; then
            printf "  ${_D}Forse cercavi:${_X} ${_B}%s${_X}\n" "$(printf '%s.log ' "${near[@]}")"
            return
        fi
    fi

    printf "  ${_D}Log presenti su questo nodo (%d):${_X}\n" "${#names[@]}"
    _print_names_in_columns "${names[@]}"
}

# Elenco su richiesta esplicita (list_logs), non reattivo come suggest_available_logs().
# Due sezioni perché le due famiglie si nominano con sintassi diversa: i Guidewire
# via NAMED_LOG ("<nome>.log"), access/server/gc via LOG_TYPE ("access log", ecc.) —
# mescolarli suggerirebbe una sintassi che per i secondi non funziona.
list_available_logs() {
    local _D="${C_LBL}" _B="${C_BOLD}" _X="${C_RESET}"

    printf "  ${_B}Log applicativi${_X}\n"
    local -a gw_names=()
    while IFS= read -r n; do [[ -n "$n" ]] && gw_names+=("$n"); done < <(_log_names_in_dir "${GUIDEWIRE_LOG_DIR:-}")
    if [[ "${#gw_names[@]}" -eq 0 ]]; then
        printf "  ${_D}Nessun log applicativo trovato sul nodo.${_X}\n"
    else
        printf "  ${_D}%d log, si nominano con l'estensione (es: «ultime righe del %s.log»):${_X}\n" \
            "${#gw_names[@]}" "${gw_names[0]}"
        _print_names_in_columns "${gw_names[@]}"
    fi

    printf "\n  ${_B}Log di sistema${_X}\n"
    local found=0

    local access_dir="${ACCESS_LOG_DIR:-$(dirname "${ACCESS_LOG:-.}" 2>/dev/null)}"
    if [[ -n "${ACCESS_LOG_BASE:-}" ]] \
        && find "$access_dir" -maxdepth 1 -type f -name "${ACCESS_LOG_BASE}*" 2>/dev/null | grep -q .; then
        printf "  ${_D}presente — si chiede con: «access log»${_X}\n"
        found=1
    fi
    local server_dir="${SERVER_LOG_DIR:-$(dirname "${SERVER_LOG:-.}" 2>/dev/null)}"
    if [[ -n "${SERVER_LOG_BASE:-}" ]] \
        && find "$server_dir" -maxdepth 1 -type f -name "${SERVER_LOG_BASE}*" 2>/dev/null | grep -q .; then
        printf "  ${_D}presente — si chiede con: «server log»${_X}\n"
        found=1
    fi
    local gc_dir="${GC_LOG_DIR:-$(dirname "${GC_LOG:-.}" 2>/dev/null)}"
    if [[ -n "${GC_LOG_BASE:-}" ]] \
        && find "$gc_dir" -maxdepth 1 -type f -name "${GC_LOG_BASE}*" 2>/dev/null | grep -q .; then
        printf "  ${_D}presente — si chiede con: «statistiche gc»${_X}\n"
        found=1
    fi
    [[ "$found" -eq 0 ]] && printf "  ${_D}Nessuno trovato sul nodo.${_X}\n"
}

# Stampa quale file (o quali) il tool sta effettivamente leggendo.
# tail_named_log/grep_named_log lo facevano già; tail_log no, e questo rendeva
# indistinguibile il caso "ho chiesto un log Guidewire e mi è stato dato
# l'access log di Undertow" — l'utente vedeva righe plausibili e nessun indizio.
# Prende l'espressione prodotta da open_*() (che contiene path quotati e
# possibili <(gunzip -c '...')) e ne estrae i path per la sola visualizzazione.
print_log_source() {
    local logs_expr="$1"
    local paths
    paths=$(grep -oE "'[^']+'" <<< "$logs_expr" | tr -d "'" | paste -sd' ' -)
    [[ -z "$paths" ]] && return
    local count
    count=$(wc -w <<< "$paths")
    if [[ "$count" -eq 1 ]]; then
        printf "${C_ACCENT}Log: %s${C_RESET}\n" "$paths"
        return
    fi

    # Più file (rotazione): l'utente deve capire su quale insieme è calcolato il
    # risultato, ma con 11 rotazioni la riga diventa illeggibile (misurato in
    # produzione). Si mostrano la directory una volta sola e i soli nomi, troncati.
    local dir first
    first=$(awk '{print $1}' <<< "$paths")
    dir=$(dirname "$first")
    local names
    names=$(tr ' ' '\n' <<< "$paths" | xargs -r -n1 basename | paste -sd' ' -)
    printf "${C_ACCENT}Log: %s file in %s${C_RESET}\n" "$count" "$dir"
    if [[ "$count" -le 4 ]]; then
        printf "     ${C_LBL}%s${C_RESET}\n" "$names"
    else
        local head_n tail_n
        head_n=$(tr ' ' '\n' <<< "$names" | head -2 | paste -sd' ' -)
        tail_n=$(tr ' ' '\n' <<< "$names" | tail -1)
        printf "     ${C_LBL}%s … %s${C_RESET}\n" "$head_n" "$tail_n"
    fi
}

print_help() {
    local BOLD="${C_BOLD}"
    local CYAN="${C_ACCENT}"
    local DIM="${C_LBL}"
    local RESET="${C_RESET}"

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

# dispatch_tool TOOL — wrapper che misura le fasi e scrive le metriche su
# BOT_PERF_FILE, poi delega a _dispatch_tool_run per l'esecuzione vera.
#
# Vive QUI e non nei 13 rami del case: la selezione file e l'analisi AWK sono
# le stesse due fasi per ogni tool, quindi strumentarle una volta nel punto
# comune evita 13 copie della stessa logica (principio 2 di CLAUDE.md).
# search_all_logs si strumenta da sé — è uno script separato con un pool di
# worker e fasi proprie — e sovrascrive queste metriche con le sue, più
# dettagliate.
#
# La scomposizione è per differenza: `select_ms` è il tempo speso dentro
# open_logs/open_server_logs/open_gc_logs (accumulato dai wrapper in
# _PERF_SELECT_ACC), `search_ms` è tutto il resto dell'esecuzione del tool.
# Non serve strumentare ogni singolo .awk: la domanda a cui rispondere è
# "il tempo va nella scelta dei file o nell'analisi?".
dispatch_tool() {
    local tool="$1"
    local _t0 _t1 _rc
    _t0=$(date +%s%3N 2>/dev/null || echo 0)

    # File di raccolta per le metriche emesse dalle subshell di open_logs_for.
    # Solo se il logging è attivo: senza BOT_PERF_FILE non c'è destinazione e
    # non vale un mktemp per query.
    _PERF_SELECT_FILE=""
    if [[ -n "${BOT_PERF_FILE:-}" && "$tool" != "search_all_logs" ]]; then
        _PERF_SELECT_FILE=$(mktemp 2>/dev/null) || _PERF_SELECT_FILE=""
    fi

    _dispatch_tool_run "$@"
    _rc=$?

    _t1=$(date +%s%3N 2>/dev/null || echo 0)
    # search_all_logs scrive le proprie metriche (più dettagliate, con il
    # conteggio dei match e i worker): non sovrascriverle con queste.
    if [[ -n "$_PERF_SELECT_FILE" ]]; then
        local _sel=0 _nf=0 _nb=0
        if [[ -s "$_PERF_SELECT_FILE" ]]; then
            read -r _sel _nf _nb < <(awk '{s+=$1; f+=$2; b+=$3} END{print s+0, f+0, b+0}' "$_PERF_SELECT_FILE")
        fi
        local _tot=$(( _t1 - _t0 ))
        local _sea=$(( _tot - _sel ))
        [[ "$_sea" -lt 0 ]] && _sea=0
        {
            echo "PERF_TOOL=$tool"
            echo "PERF_SELECT_MS=${_sel:-0}"
            echo "PERF_SEARCH_MS=$_sea"
            echo "PERF_FILES=${_nf:-0}"
            echo "PERF_FILES_MATCHED=0"
            echo "PERF_BYTES=${_nb:-0}"
            echo "PERF_JOBS=1"
            echo "PERF_HITS=0"
        } > "$BOT_PERF_FILE" 2>/dev/null || true
        log_debug "dispatch_tool $tool: totale=${_tot}ms select=${_sel}ms analisi=${_sea}ms file=${_nf}"
        rm -f "$_PERF_SELECT_FILE"
    fi
    _PERF_SELECT_FILE=""
    return "$_rc"
}

_dispatch_tool_run() {
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
    # Tema colore: i valori arrivano da lib/utils-theme.sh (già caricato da
    # chatbot.sh) e vengono passati a gawk come -v. utils-colors.awk li mappa
    # sulle costanti storiche (RED, YELLOW, …), così i tool non cambiano.
    # I -v vanno DOPO i -f e PRIMA dei file di input, come gli altri.
    local theme_v=""
    if declare -F theme_awk_args >/dev/null 2>&1; then
        theme_v="$(theme_awk_args)"
    fi
    local tw_args="$common_f $theme_v -v time_from='${TIME_FROM:-}' -v time_to='${TIME_TO:-}'"

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
            [[ -z "$server" ]] && { skip_msg "server.log non disponibile per filter_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_errors.awk" \
                "$(open_server_logs)"
            ;;
        service_times)
            eval gawk "$tw_args" -f "$TOOLS_DIR/service_times.awk" \
                "$(open_logs)"
            ;;
        gc_stats)
            [[ -z "$gc" ]] && { skip_msg "gc.log non disponibile per gc_stats"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/gc_stats.awk" \
                "$(open_gc_logs)"
            ;;
        correlate_gc_slow)
            [[ -z "$gc" ]] && { skip_msg "gc.log non disponibile per correlate_gc_slow"; return; }
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
                [[ -z "$server" ]] && { skip_msg "server.log non disponibile"; return; }
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_server_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-${fmt}.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="server" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_server_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                fi
            else
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="access" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        -v order="${LOG_ORDER:-tail}" \
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
            [[ -z "$server" ]] && { skip_msg "server.log non disponibile per filter_app_errors"; return; }
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_app_errors.awk" \
                "$(open_server_logs)"
            ;;
        tail_named_log)
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            local named_log="${NAMED_LOG:-}"
            local log_glob="${NAMED_LOG_GLOB:-}"
            # Escape hatch: glob esplicito tra virgolette (validato in param-extract.sh)
            # bypassa la whitelist APP_LOG_NAMES e la catena fuzzy. Percorso eccezionale,
            # non quello normale — serve per i log imprevisti del profilo.
            if [[ -n "$log_glob" ]]; then
                local glob_expr=""
                [[ -n "$gw_dir" ]] && glob_expr=$(open_glob_logs "$gw_dir" "$log_glob")
                if [[ -z "$glob_expr" ]]; then
                    skip_msg "Nessun log corrispondente a '$log_glob' in ${gw_dir:-<gw_dir non impostata>}"
                    return
                fi
                print_log_source "$glob_expr"
                printf "${C_LBL}(glob: %s)${C_RESET}\n" "$log_glob"
                eval gawk -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                    -f "$TOOLS_DIR/tail_named_log.awk" \
                    -v tail_n="${TAIL_N:-50}" \
                    -v order="${LOG_ORDER:-tail}" \
                    "$glob_expr"
                return
            fi
            if [[ -z "$named_log" ]]; then
                skip_msg "Nessun log Guidewire specificato nella query"
                return
            fi
            local log_path
            log_path=$(resolve_named_log_path "$gw_dir" "$named_log")
            if [[ -z "$log_path" ]]; then
                skip_msg "Log '$named_log' non trovato in ${gw_dir:-<gw_dir non impostata>}"
                suggest_available_logs "$gw_dir" "$named_log"
                return
            fi
            printf "${C_ACCENT}Log: %s${C_RESET}\n" "$log_path"
            eval gawk -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                -f "$TOOLS_DIR/tail_named_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                -v order="${LOG_ORDER:-tail}" \
                "$(open_log "$log_path")"
            ;;
        grep_named_log)
            local gw_dir="${GUIDEWIRE_LOG_DIR:-}"
            local named_log="${NAMED_LOG:-}"
            local log_glob="${NAMED_LOG_GLOB:-}"
            # Stesso escape hatch di tail_named_log — vedi commento sopra.
            if [[ -n "$log_glob" ]]; then
                local glob_expr=""
                [[ -n "$gw_dir" ]] && glob_expr=$(open_glob_logs "$gw_dir" "$log_glob")
                if [[ -z "$glob_expr" ]]; then
                    skip_msg "Nessun log corrispondente a '$log_glob' in ${gw_dir:-<gw_dir non impostata>}"
                    return
                fi
                print_log_source "$glob_expr"
                printf "${C_LBL}(glob: %s)${C_RESET}  (level=%s)\n" "$log_glob" "${LOG_LEVEL:-ERROR}"
                eval gawk "$tw_args" -f "$TOOLS_DIR/grep_named_log.awk" \
                    -v level="${LOG_LEVEL:-ERROR}" \
                    -v tail_n="${TAIL_N:-50}" \
                    "$glob_expr"
                return
            fi
            if [[ -z "$named_log" ]]; then
                skip_msg "Nessun log Guidewire specificato nella query"
                return
            fi
            local log_path
            log_path=$(resolve_named_log_path "$gw_dir" "$named_log")
            if [[ -z "$log_path" ]]; then
                skip_msg "Log '$named_log' non trovato in ${gw_dir:-<gw_dir non impostata>}"
                suggest_available_logs "$gw_dir" "$named_log"
                return
            fi
            printf "${C_ACCENT}Log: %s${C_RESET}  (level=%s)\n" "$log_path" "${LOG_LEVEL:-ERROR}"
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
        list_logs)
            list_available_logs
            ;;
        *)
            echo "[WARN] Tool sconosciuto: $tool" >&2
            ;;
    esac
}
