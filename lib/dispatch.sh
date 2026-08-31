#!/bin/bash
#
# dispatch.sh — invoca il tool AWK corretto in base al nome tool.
# Sourcato da chatbot.sh dopo che PROFILE_DIR, TOOLS_DIR e le variabili
# di contesto (ACCESS_LOG, SERVER_LOG, GC_LOG, CUSTOM_LOG_DIR) sono definite.
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
open_current_gc_logs()     { open_current_log_for "${GC_LOG_DIR:-$(dirname "$GC_LOG")}"         "$GC_LOG_BASE"; }

# Espande un glob nell'insieme di file da leggere, rispettando la finestra temporale.
#
# Il glob dell'utente ("*-cc.log") identifica il log corrente; da lì si deriva il
# basename logico e si delega a select_log_files, che è l'unico posto dove vive il
# filtro temporale: così "righe di ieri" seleziona la rotazione .gz giusta invece
# di leggere sempre il file corrente. Prima questo ramo faceva `find | head -1`,
# quindi ignorava sia il tempo sia i .gz.
#
# DIR è la radice di ricerca (ricorsiva, tramite resolve_log_glob): il file
# scelto può stare in una sottodirectory qualsiasi. Le rotazioni però si
# raggruppano sulla DIRECTORY DEL FILE SCELTO, non sulla root: select_log_files
# è flat per costruzione (le rotazioni di un log stanno sempre accanto al file
# corrente, non sparse sotto il nodo).
#
# Uso: logs_expr=$(open_glob_logs DIR GLOB)  → espressione per `eval gawk ...`
open_glob_logs() {
    local dir="$1" glob="$2"
    local _t0 _t1
    _t0=$(date +%s%3N 2>/dev/null || echo 0)
    local chosen
    # require_app=1: stessa politica del ramo named (resolve_named_log_path,
    # sopra) — se il glob esiste solo sotto un'altra app, non va aperto
    # senza dirlo (principio 6, una sola politica cross-app per il tool).
    # Condivisa da tail_named_log e grep_named_log: il fix vale per entrambi.
    chosen=$(resolve_log_glob "$dir" "$glob" "$glob" 1) || return 1
    [[ -z "$chosen" ]] && return 1

    local base
    base=$(logfile_logical_name "$chosen")

    # select_log_files (select_log_files_grouped) raggruppa per nome logico
    # ESATTO dentro il motore: "prod1nsse-cc" non tira più dentro
    # "prod1nsse-ccCanaliz.log". Prima questo era un post-filtro qui
    # (rimosso 2026-08-06, ridondante col motore generalizzato).
    local list expr="" f _nf=0 _nb=0
    list=$(select_log_files "$(dirname "$chosen")" "$base" "${TIME_FROM:-}" "${TIME_TO:-}")
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
# esatto "*-<nome>.log", poi "*<nome>.log(.gz)", poi "*<nome>*.log(.gz)" fuzzy.
# Unica fonte di verità per tail_named_log e grep_named_log (prima erano due
# copie identiche della stessa catena find, OBS-3 — principio 2 di CLAUDE.md).
# Non passa da select_log_files: qui si vuole UN file rappresentativo per
# nome, non le sue rotazioni.
#
# La ricerca è ricorsiva sotto SEARCH_ROOT (contratto fino al nodo, vedi
# CLAUDE.md) tramite resolve_log_glob, che applica la disambiguazione
# multi-app/multi-rotazione in un solo posto. Il filtro "esclude rotazioni con
# epoch a 10 cifre" del vecchio find non serve più: resolve_log_glob raggruppa
# già per nome logico e sceglie il non ruotato, quindi una rotazione non può
# mai vincere sul file corrente.
#
# Emette anche le metriche di volume su _PERF_SELECT_FILE (se impostato): un
# solo stat sul file scelto, stesso pattern di open_current_log_for. Prima
# questo ramo non passava da nessuna funzione open_*, quindi selezione/byte
# restavano sempre a 0 anche quando un file veniva letto per intero.
resolve_named_log_path() {
    local search_root="$1" named_log="$2"
    local _t0 _t1
    _t0=$(date +%s%3N 2>/dev/null || echo 0)
    local log_path=""
    # Feedback progressivo: come open_current_log_for, questo percorso bypassa
    # select_log_files_grouped (dove vive la chiamata a progress_show), quindi
    # tail_named_log e grep_named_log non mostravano nulla. Conta: dal log di
    # performance in produzione grep_named_log arriva a 3.7s, abbastanza da far
    # sembrare la shell ferma.
    progress_show "ricerca log ${named_log}..."
    if [[ -n "$search_root" ]]; then
        log_path=$(resolve_log_glob "$search_root" "*-${named_log}.log" "$named_log" 1) || true
        if [[ -z "$log_path" ]]; then
            log_path=$(resolve_log_glob "$search_root" "*${named_log}.log" "$named_log" 1) || true
        fi
        if [[ -z "$log_path" ]]; then
            log_path=$(resolve_log_glob "$search_root" "*${named_log}*.log" "$named_log" 1) || true
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

# Estrae i nomi logici dei log ".log" presenti sotto una directory (ricorsiva:
# il contratto del profilo si ferma al nodo, sotto si scopre — vedi CLAUDE.md),
# uno per riga su stdout. Scarta i nomi con caratteri non digitabili: sul nodo
# reale (profilo liquido) esiste "${gw.cc.serverid}-messaging.log", un
# placeholder Guidewire non risolto nella loro config — non è un log che
# qualcuno possa nominare, sarebbe solo rumore. Non filtra per basename di
# sistema (access/server/gc):
# quel filtro sta a valle, in list_available_logs, perché suggest_available_logs
# (l'altro chiamante) deve poter suggerire anche quei nomi su un tentativo errato.
# Condivisa da suggest_available_logs() (reattivo, su nome sbagliato) e
# list_available_logs() (su richiesta esplicita) — stessa fonte di verità.
_log_names_in_dir() {
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    local f
    find "$dir" \( -type f -o -type l \) -name "*.log" 2>/dev/null \
        | while IFS= read -r f; do logfile_display_name "$f"; done \
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

# Cerca named_log sotto SEARCH_ROOT senza il vincolo di app corrente (a
# differenza di resolve_named_log_path, che con require_app=1 lo impone) e,
# se lo trova, restituisce il nome dell'app sotto cui vive. Usata solo per il
# messaggio di skip: decisione utente 2026-08-07 — se il log esiste ma solo
# sotto un'altra app, non va aperto (mescolerebbe dati di app diverse senza
# dirlo), ma l'utente va indirizzato lì invece di un generico "non trovato".
_find_named_log_elsewhere() {
    local search_root="$1" named_log="$2"
    [[ -z "$search_root" ]] && return 1
    local found
    found=$(resolve_log_glob "$search_root" "*-${named_log}.log" "$named_log") || true
    [[ -z "$found" ]] && found=$(resolve_log_glob "$search_root" "*${named_log}.log" "$named_log") || true
    [[ -z "$found" ]] && found=$(resolve_log_glob "$search_root" "*${named_log}*.log" "$named_log") || true
    [[ -z "$found" ]] && return 1
    # resolve_app_from_path (utils-logfiles.sh) — prima questa iterazione su
    # AVAILABLE_APPS era inline qui; migrata alla funzione condivisa quando
    # search_all_logs ha avuto bisogno della stessa risoluzione (principio 8:
    # centralizzare significa migrare i chiamanti, non solo creare la funzione).
    resolve_app_from_path "$found"
}

# Messaggio di skip per named_log non trovato: distingue "non esiste sul nodo"
# da "esiste ma sotto un'altra app" (decisione utente 2026-08-07). Unica fonte
# di verità per tail_named_log e grep_named_log.
skip_named_log_not_found() {
    local search_root="$1" named_log="$2"
    local elsewhere
    elsewhere=$(_find_named_log_elsewhere "$search_root" "$named_log") || elsewhere=""
    if [[ -n "$elsewhere" && "$elsewhere" != "${ACTIVE_APP:-}" ]]; then
        skip_msg "Log '$named_log' non trovato sotto ${ACTIVE_APP:-app corrente} — esiste sotto ${elsewhere}"
    else
        skip_msg "Log '$named_log' non trovato in ${search_root:-<search_root non impostata>}"
        suggest_available_logs "$search_root" "$named_log"
    fi
}

# skip_system_log_not_found SEARCH_ROOT BASE LABEL
# Messaggio di skip per un log di SISTEMA (access/server/gc) non disponibile.
# Distingue "non esiste sul nodo" da "esiste ma sotto un'altra app", esattamente
# come skip_named_log_not_found fa per i log nominati: una politica sola per tutto
# il progetto, così l'utente sa sempre come si comporta il bot (indicazione utente
# 2026-08-17). Mai aprire il log di un'altra app in silenzio — la regola invariante
# del principio 6 è "mai dati di un'app diversa da quella attesa senza dirlo".
#
# LABEL è il termine con cui l'utente nomina il log ("access log", non
# "undertow_access_log"): il basename su disco è un dettaglio di configurazione,
# coerente con list_available_logs e con SYSTEM_LOG_SYNONYMS.
skip_system_log_not_found() {
    local search_root="$1" base="$2" label="$3"
    # Seconda ricerca SENZA require_app, per sapere se il log esiste altrove.
    # Costa una find in più solo qui, nel ramo di fallimento — già il caso raro.
    local elsewhere_dir elsewhere=""
    elsewhere_dir=$(resolve_system_log_dir "$search_root" "$base") || elsewhere_dir=""
    [[ -n "$elsewhere_dir" ]] && elsewhere=$(resolve_app_from_path "$elsewhere_dir/") || true
    if [[ -n "$elsewhere" && "$elsewhere" != "${ACTIVE_APP:-}" ]]; then
        skip_msg "${label} non trovato sotto ${ACTIVE_APP:-app corrente} — esiste sotto ${elsewhere}"
    else
        skip_msg "${label} non disponibile in ${search_root:-<search_root non impostata>}"
    fi
}

# require_system_log KIND TOOL
# Guard di disponibilità per un log di sistema, da chiamare nel ramo del tool che
# ne ha bisogno: emette il messaggio e ritorna 1 se quel log non è disponibile
# per l'app di sessione.
#
# Esiste perché da LOGDISC-4 la validazione è PER-TOOL e non più globale: prima
# resolve-logs.sh abortiva l'intera sessione se mancava l'access log, quindi
# nessun ramo doveva controllarlo (e infatti gli 8 tool che lo leggono non
# avevano guard). Rimosso quell'abort, senza questi controlli
# `open_logs_for "" BASE` cercherebbe nella directory corrente — in silenzio.
#
# Un helper invece di 9 blocchi ripetuti (principio 2): il messaggio e la
# decisione di cosa conta come "disponibile" vivono in un punto solo.
#
# Controlla la DIRECTORY, non il path del file corrente: una directory trovata
# con il solo file corrente già ruotato è un caso legittimo — i dati ci sono,
# select_log_files li seleziona. I guard preesistenti su server/gc controllavano
# il file, quindi saltavano un tool su un nodo appena ruotato pur avendo i dati:
# effetto collaterale positivo di questa centralizzazione, non un cambio voluto
# di semantica (principio 5, non escludere per ignoranza).
require_system_log() {
    local kind="$1" tool="$2"
    local dir base label
    case "$kind" in
        access) dir="${ACCESS_LOG_DIR:-}"; base="${ACCESS_LOG_BASE:-}"; label="access log" ;;
        server) dir="${SERVER_LOG_DIR:-}"; base="${SERVER_LOG_BASE:-}"; label="server log" ;;
        gc)     dir="${GC_LOG_DIR:-}";     base="${GC_LOG_BASE:-}";     label="gc log"     ;;
        *)      echo "[ERROR] require_system_log: kind sconosciuto '$kind'" >&2; return 1 ;;
    esac
    [[ -n "$dir" ]] && return 0
    # Non disponibile: distingue "non c'è sul nodo" da "c'è sotto un'altra app".
    # Il nome del tool nel messaggio dice PERCHÉ la query non ha prodotto nulla —
    # senza, "access log non trovato" su una query che ne usa due (correlate_gc_slow)
    # non direbbe quale sorgente manca.
    skip_system_log_not_found "${LOG_SEARCH_ROOT:-}" "$base" "${label} per ${tool}"
    return 1
}

# Espande la dichiarazione di TOOL_SOURCES (nlp/tools.conf, HELP-1) nei kind di
# sistema effettivi per questo tool, uno per riga. È la sola lettura di quella
# tabella lato guard: print_help() la legge separatamente per l'help.
#
# "|" (OR runtime, es. "access|server" di tail_log) risolve al $selector se
# combacia con una delle alternative, altrimenti alla PRIMA — che riproduce il
# ramo "else → access" preesistente prima di questa tabella. Uno spazio (AND,
# es. "gc access" di correlate_gc_slow) resta più kind, tutti richiesti.
# I kind non di sistema (named/all/none) non producono righe: nessun tool con
# quei valori chiama require_system_log.
tool_source_kinds() {
    local tool="$1" selector="${2:-}"
    local spec="${TOOL_SOURCES[$tool]:-}"
    [[ -z "$spec" ]] && return 0
    local group
    for group in $spec; do
        local kind="$group"
        if [[ "$group" == *"|"* ]]; then
            local -a alts=()
            IFS='|' read -ra alts <<< "$group"
            kind="${alts[0]}"
            local alt
            for alt in "${alts[@]}"; do
                [[ "$alt" == "$selector" ]] && { kind="$alt"; break; }
            done
        fi
        case "$kind" in
            named|all|none) ;;
            *) echo "$kind" ;;
        esac
    done
}

# Guard table-driven: sostituisce le chiamate dirette a require_system_log nel
# case sottostante con un'unica dichiarazione per tool (TOOL_SOURCES). Ferma
# al primo kind mancante, così il messaggio di skip nomina il kind giusto.
require_tool_sources() {
    local tool="$1" selector="${2:-}"
    local kind
    while IFS= read -r kind; do
        [[ -z "$kind" ]] && continue
        require_system_log "$kind" "$tool" || return 1
    done < <(tool_source_kinds "$tool" "$selector")
    return 0
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
# Due sezioni perché le due famiglie si nominano con sintassi diversa: i log
# applicativi custom via NAMED_LOG ("<nome>.log"), access/server/gc via
# LOG_TYPE ("access log", ecc.) — mescolarli suggerirebbe una sintassi che per
# i secondi non funziona.
list_available_logs() {
    local _D="${C_LBL}" _B="${C_BOLD}" _X="${C_RESET}"

    printf "  ${_B}Log del nodo${_X}\n"
    local -a custom_names=()
    local -a _raw_names=()
    while IFS= read -r n; do [[ -n "$n" ]] && _raw_names+=("$n"); done \
        < <(_log_names_in_dir "${LOG_SEARCH_ROOT:-${CUSTOM_LOG_DIR:-}}")
    local n
    for n in "${_raw_names[@]}"; do
        _is_system_log_base "$n" || custom_names+=("$n")
    done
    if [[ "${#custom_names[@]}" -eq 0 ]]; then
        printf "  ${_D}Nessun log applicativo trovato sul nodo.${_X}\n"
    else
        printf "  ${_D}%d log, si nominano con l'estensione (es: «ultime righe del %s.log»):${_X}\n" \
            "${#custom_names[@]}" "${custom_names[0]}"
        _print_names_in_columns "${custom_names[@]}"
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

# Dimensione in byte -> stringa leggibile (B/K/M/G), scala automatica.
_format_size() {
    awk -v b="$1" 'BEGIN {
        if      (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576)    printf "%.1fM", b/1048576
        else if (b >= 1024)       printf "%.1fK", b/1024
        else                      printf "%dB", b
    }'
}

# Epoch -> "N fa", stessa scala e stesso vocabolario (secondi/minuti/ore/giorni)
# usato in senso inverso da utils-time.sh per interpretare il linguaggio
# naturale dell'utente ("2 ore fa") — qui è l'output, lì l'input.
_format_time_ago() {
    local mtime="$1" now diff
    now=$(date +%s)
    diff=$(( now - mtime ))
    (( diff < 0 )) && diff=0
    if   (( diff < 90 ));     then printf '%ds fa' "$diff"
    elif (( diff < 5400 ));   then printf '%dm fa' $(( diff / 60 ))
    elif (( diff < 129600 )); then printf '%dh fa' $(( diff / 3600 ))
    else                           printf '%dg fa' $(( diff / 86400 ))
    fi
}

# Dimensione totale e mtime più recente di un elenco di path (uno per riga in
# $1). Con più file la dimensione è la somma e il "fa" è quello del file PIÙ
# RECENTE — è il file "vivo" che riceve ancora scritture, quindi è quello che
# risponde alla domanda implicita dell'utente ("questo dato è aggiornato?").
# $2 (opzionale) è un'etichetta appesa alla sola dimensione (es. " totali"),
# per non finire in coda al "fa" dov'è semanticamente sbagliata (qualifica la
# dimensione, non il tempo). Silenzioso se un file non è (più) raggiungibile:
# è un'annotazione, non deve far fallire la stampa del risultato principale
# (principio 5, in spirito).
_log_file_info() {
    local size_label="${2:-}"
    local sizes=0 newest=0 f sz mt
    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        read -r sz mt < <(stat -c '%s %Y' "$f" 2>/dev/null) || continue
        sizes=$(( sizes + sz ))
        (( mt > newest )) && newest=$mt
    done <<< "$1"
    [[ "$newest" -eq 0 ]] && return
    printf '%s%s, %s' "$(_format_size "$sizes")" "$size_label" "$(_format_time_ago "$newest")"
}

# Stampa quale file (o quali) il tool sta effettivamente leggendo.
# tail_named_log/grep_named_log lo facevano già; tail_log no, e questo rendeva
# indistinguibile il caso "ho chiesto un log applicativo e mi è stato dato
# l'access log di Undertow" — l'utente vedeva righe plausibili e nessun indizio.
# Prende l'espressione prodotta da open_*() (che contiene path quotati e
# possibili <(gunzip -c '...')) e ne estrae i path per la sola visualizzazione.
# $2 (opzionale) è una riga di annotazione aggiuntiva (es. "(glob: ...)",
# "(level=ERROR)") stampata subito dopo, prima della riga vuota di distacco —
# unico punto che decide la spaziatura verso il resto della risposta, così
# tutti i chiamanti restano coerenti senza doverlo replicare (SEV-2).
print_log_source() {
    local logs_expr="$1" suffix="${2:-}"
    local paths
    paths=$(grep -oE "'[^']+'" <<< "$logs_expr" | tr -d "'" | paste -sd' ' -)
    [[ -z "$paths" ]] && return
    local count
    count=$(wc -w <<< "$paths")
    local info
    if [[ "$count" -eq 1 ]]; then
        info=$(_log_file_info "$paths")
        printf "${C_ACCENT}Log: %s${C_RESET}" "$paths"
        [[ -n "$info" ]] && printf " ${C_LBL}[%s]${C_RESET}" "$info"
        printf '\n'
    else
        # Più file (rotazione): l'utente deve capire su quale insieme è calcolato
        # il risultato, ma con 11 rotazioni la riga diventa illeggibile (misurato
        # in produzione). Si mostrano la directory una volta sola e i soli nomi,
        # troncati.
        local dir first
        first=$(awk '{print $1}' <<< "$paths")
        dir=$(dirname "$first")
        local names
        names=$(tr ' ' '\n' <<< "$paths" | xargs -r -n1 basename | paste -sd' ' -)
        info=$(_log_file_info "$(tr ' ' '\n' <<< "$paths")" " totali")
        printf "${C_ACCENT}Log: %s file in %s${C_RESET}" "$count" "$dir"
        [[ -n "$info" ]] && printf " ${C_LBL}[%s]${C_RESET}" "$info"
        printf '\n'
        if [[ "$count" -le 4 ]]; then
            printf "     ${C_LBL}%s${C_RESET}\n" "$names"
        else
            local head_n tail_n
            head_n=$(tr ' ' '\n' <<< "$names" | head -2 | paste -sd' ' -)
            tail_n=$(tr ' ' '\n' <<< "$names" | tail -1)
            printf "     ${C_LBL}%s … %s${C_RESET}\n" "$head_n" "$tail_n"
        fi
    fi
    [[ -n "$suffix" ]] && printf "${C_LBL}%s${C_RESET}\n" "$suffix"
    # RETENT-1: dichiara se $paths (i file EFFETTIVAMENTE letti, non la
    # selezione teorica — vedi logfiles_coverage_note) non copre TIME_FROM per
    # retention, o se non è verificabile. Qui e non nel motore perché
    # open_logs_for/open_glob_logs hanno un fallback che sostituisce la
    # selezione quando la finestra non produce candidati.
    logfiles_coverage_note "$paths" "${TIME_FROM:-}"
    printf '\n'
}

# Unisce le stringhe passate con $1 come separatore letterale. Serve perché
# "${arr[*]}" con IFS multi-carattere usa solo il primo carattere di IFS, non
# la stringa intera — non basta impostare IFS=" + " per ottenere " + " come join.
_tool_sources_join() {
    local sep="$1"; shift
    local out="" first=true x
    for x in "$@"; do
        if [[ "$first" == true ]]; then out="$x"; first=false
        else out="$out$sep$x"; fi
    done
    printf '%s' "$out"
}

# Categoria derivata per print_help (HELP-1): non più TOOL_CATEGORY scritta a mano,
# ma la conseguenza di TOOL_SOURCES (nlp/tools.conf). Kind "none" → nessuna categoria
# (show_help resta fuori dall'help, come oggi); kind "all" → ACTIVITY_CATEGORY, il
# tool è raggruppato per attività e non per sorgente (decisione utente: search_all_logs
# e list_logs restano su due voci distinte, non su una categoria "sorgente" comune);
# altrimenti SOURCE_CATEGORY del primo kind dichiarato — per un OR (es. "access|server"
# di tail_log) la prima alternativa, stessa regola di tool_source_kinds senza selettore.
tool_help_category() {
    local tool="$1"
    local spec="${TOOL_SOURCES[$tool]:-}"
    [[ -z "$spec" ]] && return
    local -a groups=($spec)
    local first="${groups[0]}"
    [[ "$first" == *"|"* ]] && first="${first%%|*}"
    case "$first" in
        none) return 0 ;;
        all)  printf '%s' "${ACTIVITY_CATEGORY[$tool]:-}" ;;
        *)    printf '%s' "${SOURCE_CATEGORY[$first]:-}" ;;
    esac
}

# Annotazione inline per i tool multi-sorgente (decisione utente: elenco singolo,
# annotato — non una riga per categoria). " + " per un AND (entrambi richiesti
# incondizionatamente, es. correlate_gc_slow="gc access"), " o " per un OR (una delle
# alternative secondo un selettore a runtime, es. tail_log="access|server"). Vuota per
# i tool a sorgente singola: non c'è nulla da dichiarare oltre alla categoria.
tool_help_annotation() {
    local tool="$1"
    local spec="${TOOL_SOURCES[$tool]:-}"
    local -a groups=($spec)
    if [[ "${#groups[@]}" -gt 1 ]]; then
        local -a parts=() g
        for g in "${groups[@]}"; do parts+=("${SOURCE_LABEL[$g]:-$g}"); done
        _tool_sources_join " + " "${parts[@]}"
        return
    fi
    local only="${groups[0]:-}"
    if [[ "$only" == *"|"* ]]; then
        local -a alts=()
        IFS='|' read -ra alts <<< "$only"
        local -a parts=() a
        for a in "${alts[@]}"; do parts+=("${SOURCE_LABEL[$a]:-$a}"); done
        _tool_sources_join " o " "${parts[@]}"
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
            local tool_cat
            tool_cat="$(tool_help_category "$tool")"
            [[ -z "$tool_cat" || "$tool_cat" != "$cat" ]] && continue
            local desc="${TOOL_DESC[$tool]:-}"
            local ex="${TOOL_EXAMPLE[$tool]:-}"
            [[ -z "$desc" ]] && continue

            if [[ "$printed_header" == false ]]; then
                [[ "$first_cat" == false ]] && printf "\n"
                printf "  ${CYAN}${BOLD}%s${RESET}\n" "$cat"
                printed_header=true
                first_cat=false
            fi

            local annot
            annot="$(tool_help_annotation "$tool")"
            printf "  ${BOLD}%s${RESET}" "$desc"
            [[ -n "$annot" ]] && printf "  ${DIM}· %s${RESET}" "$annot"
            printf "\n"
            [[ -n "$ex" ]] && printf "  ${DIM}es: \"%s\"${RESET}\n" "$ex"
        done
    done

    printf "\n"
    printf "  ${DIM}Specifica sempre env e nodo nella query (es: \"in prod nodo 4\") o all'avvio con --env / --node.${RESET}\n"
    printf "  ${DIM}Digita ${RESET}${BOLD}aiuto${RESET}${DIM} in qualsiasi momento per rivedere questa lista.${RESET}\n\n"
}

# _require_node_scope TOOL
# Guard che dichiara il limite dei tool single-source quando lo scope di sessione
# è "tutti i nodi" (ACTIVE_NODE vuoto — SCOPE-1 passo 3, 2026-08-31): questi 14
# tool leggono da variabili di sessione risolte per UN nodo, quindi con lo scope
# allargato non hanno un log da apire. La scelta è dichiarare il limite
# (skip_msg), mai scegliere un nodo in silenzio — è esattamente il default nudo
# su "01" che questo passo rimuove, misurato al 3,1% degli errori di una
# finestra reale mentre il nodo con più errori (61%) non veniva mai mostrato.
# La capacità di girare su N nodi arriva al passo 4 (TOOL_SCOPE); qui si ferma.
#
# Esenzioni:
#   - TOOL_SOURCES[$tool]="none" (show_help): per DATO, non legge alcun log.
#   - search_all_logs: per NOME, non per dato — condivide la spec "all" con
#     list_logs, che invece va fermato (elenca i log DI UN nodo, non aggrega).
#     Non è quindi derivabile da TOOL_SOURCES senza fermare anche list_logs;
#     il nome in chiaro è lo stopgap di questo passo, il passo 4 lo sostituirà
#     con una tabella dichiarata (TOOL_SCOPE).
#
# Chiamata da dispatch_tool(), non nel case di _dispatch_tool_run: un punto
# comune invece di 14 copie (principio 2). Non chiama require_system_log
# direttamente — usa solo skip_msg, come richiesto dal test sulle chiamate
# dirette in tests/test-help-sources.sh.
_require_node_scope() {
    local tool="$1"
    [[ -n "${ACTIVE_NODE:-}" ]] && return 0
    [[ "${TOOL_SOURCES[$tool]:-}" == "none" ]] && return 0
    [[ "$tool" == "search_all_logs" ]] && return 0
    skip_msg "$tool richiede un nodo specifico — nomina un nodo (es. \"nodo 4\") o chiedi una ricerca su tutti i nodi (es. \"cerca ... in tutti i log\")"
    return 1
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

    _require_node_scope "$tool" || return 1

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

# _require_awk_parser FILE VAR VALORE FUNZIONI_RICHIESTE
# Verifica che il parser AWK selezionato da una variabile di formato esista, prima
# di passarlo a gawk. Con un valore non supportato l'utente vedeva
# `gawk: fatal: cannot open source file` a metà risposta, dopo l'header e il path
# del log (verificato il 2026-08-17): è un errore di CONFIGURAZIONE e va detto
# come tale, elencando i formati realmente presenti invece di lasciarli dedurre.
#
# Un helper solo per SERVER_LOG_FORMAT e ACCESS_LOG_FORMAT (e per quelli che
# verranno): il messaggio e la logica di scoperta vivono in un punto (principio 2).
#
# L'elenco dei disponibili si ricava dai file su disco, non da una lista scritta a
# mano che divergerebbe: `utils-<prefisso>*.awk` meno le utility condivise, che non
# sono parser di formato.
_require_awk_parser() {
    local file="$1" var="$2" value="$3" funcs="$4"
    [[ -f "$LIB_DIR/$file" ]] && return 0
    # Il prefisso del glob è tutto ciò che precede il valore nel nome del file:
    # "utils-access-combined.awk" → "utils-access-", "utils-jboss.awk" → "utils-".
    local prefix="${file%"${value}.awk"}"
    local avail
    # Il filtro scarta le utility condivise (non sono parser di formato) e, per il
    # prefisso corto "utils-", anche i nomi che contengono un '-': appartengono a
    # una famiglia più specifica. Senza, l'elenco delle tecnologie del SERVER log
    # includeva "access-undertow", che è un parser di ACCESS log — un suggerimento
    # sbagliato in un messaggio d'errore, cioè peggio di nessun suggerimento.
    avail=$(find "$LIB_DIR" -maxdepth 1 -name "${prefix}*.awk" -printf '%f\n' 2>/dev/null \
            | sed -E "s/^${prefix}//; s/\.awk$//" \
            | grep -vxE 'time|colors|dedup|logfiles|access' \
            | { [[ "$prefix" == "utils-" ]] && grep -vE -- '-' || cat; } \
            | sort | tr '\n' ' ')
    echo "[ERROR] ${var}='${value}' non supportato: manca $LIB_DIR/$file" >&2
    echo "        Formati disponibili: ${avail:-nessuno}" >&2
    echo "        Per aggiungerne uno: creare $file con le funzioni" >&2
    echo "        ${funcs}." >&2
    return 1
}

_dispatch_tool_run() {
    local tool="$1"
    local logs_expr
    # Le locali access/server/gc (copie di ACCESS_LOG/SERVER_LOG/GC_LOG) sono state
    # rimosse con LOGDISC-4: erano lette solo dai guard `[[ -z "$x" ]]`, ora
    # centralizzati in require_system_log, che verifica la DIRECTORY scoperta.
    # Tenerle sarebbe una seconda fonte di verità sulla disponibilità di un log
    # (principio 2) — e quella sbagliata, perché il path del file corrente è vuoto
    # anche quando esistono solo rotazioni, cioè quando i dati ci sono.

    # Utility AWK caricati come -f fissi in ogni invocazione gawk.
    # SERVER_LOG_FORMAT seleziona il parser del log applicativo (da system.conf).
    # Per aggiungere WebSphere creare utils-websphere.awk con le stesse funzioni
    # parse_server_log() e is_stack_frame(), e impostare SERVER_LOG_FORMAT=websphere.
    if [[ -z "${SERVER_LOG_FORMAT:-}" ]]; then
        echo "[ERROR] SERVER_LOG_FORMAT non impostato in system.conf" >&2
        return 1
    fi
    local fmt="$SERVER_LOG_FORMAT"
    if ! _require_awk_parser "utils-${fmt}.awk" "SERVER_LOG_FORMAT" "$fmt" \
            "parse_server_log() e is_stack_frame() (vedi utils-jboss.awk)"; then
        return 1
    fi
    # Parser dell'access log, stesso meccanismo: ACCESS_LOG_FORMAT seleziona
    # utils-access-<formato>.awk. Default "undertow", il formato osservato su
    # entrambi i profili. Per un middleware con formato combined
    # (`%h %l %u %t "%r" %>s %b`, dove IP e timestamp sono in posizioni diverse)
    # si crea utils-access-combined.awk con le stesse funzioni — nessuna modifica
    # ai 6 tool, che dopo ACCESS-1 non contengono più regex di formato.
    local afmt="${ACCESS_LOG_FORMAT:-undertow}"
    if ! _require_awk_parser "utils-access-${afmt}.awk" "ACCESS_LOG_FORMAT" "$afmt" \
            "access_status(), access_time_ms(), access_method(), access_url(), access_url_root(), access_url_service(), access_ip() (vedi utils-access-undertow.awk)"; then
        return 1
    fi
    local common_f="-f '$LIB_DIR/utils-time.awk' -f '$LIB_DIR/utils-logline.awk' -f '$LIB_DIR/utils-colors.awk' -f '$LIB_DIR/utils-${fmt}.awk' -f '$LIB_DIR/utils-access-${afmt}.awk' -f '$LIB_DIR/utils-dedup.awk'"
    # Tema colore: i valori arrivano da lib/utils-theme.sh (già caricato da
    # chatbot.sh) e vengono passati a gawk come -v. utils-colors.awk li mappa
    # sulle costanti storiche (RED, YELLOW, …), così i tool non cambiano.
    # I -v vanno DOPO i -f e PRIMA dei file di input, come gli altri.
    local theme_v=""
    if declare -F theme_awk_args >/dev/null 2>&1; then
        theme_v="$(theme_awk_args)"
    fi
    # Soglie di severità per la colorazione (UI-13): da domain.conf, non più
    # hardcoded negli .awk — così tararle su un ambiente non richiede di
    # editare il codice. Una variabile sola invece di ripetere i -v in ogni
    # ramo del case (principio 2), come per $theme_v.
    # Ogni tool ha un fallback identico nel proprio BEGIN: se una soglia non
    # arriva (invocazione diretta, test), il comportamento non cambia.
    local thr_v="-v gc_pause_warn_ms='${GC_PAUSE_WARN_MS:-}' -v gc_pause_crit_ms='${GC_PAUSE_CRIT_MS:-}'"
    thr_v+=" -v svc_time_warn_ms='${SVC_TIME_WARN_MS:-}' -v svc_time_crit_ms='${SVC_TIME_CRIT_MS:-}'"
    thr_v+=" -v req_time_warn_ms='${REQ_TIME_WARN_MS:-}' -v req_time_crit_ms='${REQ_TIME_CRIT_MS:-}'"
    thr_v+=" -v heap_warn_pct='${HEAP_USED_WARN_PCT:-}' -v heap_crit_pct='${HEAP_USED_CRIT_PCT:-}'"
    thr_v+=" -v gc_corr_warn_pct='${GC_CORR_WARN_PCT:-}' -v gc_corr_crit_pct='${GC_CORR_CRIT_PCT:-}'"
    thr_v+=" -v gc_corr_lift_warn='${GC_CORR_LIFT_WARN:-}' -v gc_corr_lift_crit='${GC_CORR_LIFT_CRIT:-}'"
    thr_v+=" -v gc_corr_cover_sat_pct='${GC_CORR_COVER_SAT_PCT:-}'"
    # Canale DEBUG per il conteggio delle righe senza timestamp riconosciuto
    # (utils-time.awk, END). Serve a MISURARE in produzione quanto sia frequente il
    # caso su cui poggia in_range(epoch<=0)=1: una riga non databile viene inclusa
    # per il principio 5, e questo numero dice se è un'eventualità rara (atteso) o
    # un fenomeno di massa (allora il filtro sta filtrando meno di quanto sembri).
    # Passato solo a livello debug, e su file — mai su stdout, che è il canale su
    # cui asseriscono i test (principio 3).
    # Fallback a /dev/stderr quando BOT_LOG_FILE non è impostato, esattamente come
    # utils-log.sh ("vuoto = stderr"): altrimenti BOT_LOG_LEVEL=debug da solo non
    # produceva nulla e la misura sembrava dire "zero righe non databili" quando in
    # realtà non era stata scritta. Un canale diagnostico che tace quando è mal
    # configurato è indistinguibile da uno che dice "tutto bene" — lo stesso falso
    # verde dei test che non girano (NLP-1) e dei checksum mai verificati (c1951e3).
    local ats_dbg=""
    [[ "${BOT_LOG_LEVEL:-warn}" == "debug" ]] && ats_dbg="${BOT_LOG_FILE:-/dev/stderr}"
    local tw_args="$common_f $theme_v $thr_v -v time_from='${TIME_FROM:-}' -v time_to='${TIME_TO:-}'"
    tw_args+=" -v ats_debug_file='${ats_dbg}'"

    case "$tool" in
        count_status)
            require_tool_sources count_status || return
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/count_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$logs_expr"
            ;;
        distribute_status)
            require_tool_sources distribute_status || return
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/distribute_status.awk" \
                -v status_filter="$STATUS_CODE" \
                "$logs_expr"
            ;;
        slow_requests)
            require_tool_sources slow_requests || return
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/slow_requests.awk" \
                -v threshold_ms="${THRESHOLD_MS:-1000}" \
                "$logs_expr"
            ;;
        traffic_volume)
            require_tool_sources traffic_volume || return
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/traffic_volume.awk" \
                "$logs_expr"
            ;;
        filter_errors)
            require_tool_sources filter_errors || return
            logs_expr="$(open_server_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_errors.awk" \
                "$logs_expr"
            ;;
        service_times)
            # Il guard di CONFIGURAZIONE va prima di require_tool_sources, che è un
            # guard di DISPONIBILITÀ DATI: un profilo senza SERVICE_PATH_DEPTH
            # fallirà su ogni nodo e ogni giorno, mentre un log mancante è
            # specifico di questo nodo. Dire prima la cosa che non cambierà.
            #
            # ARCH-6: nessun default implicito. Quante componenti del path
            # identifichino un servizio dipende da come è montata l'applicazione —
            # una COORDINATA del profilo, non una capacità del tool (SVCGRAN-1,
            # principio 7). Misurato: profondità 1 dà 6 gruppi su usnext (giusto) e
            # UN SOLO gruppo su liquido, dove tutto vive sotto /essigSXCC/. Un
            # default qui nasconderebbe la scelta invece di richiederla.
            if [[ -z "${SERVICE_PATH_DEPTH:-}" ]]; then
                echo "[ERROR] SERVICE_PATH_DEPTH non impostato in system.conf del profilo." >&2
                echo "        Indica quante componenti del path URL identificano un servizio:" >&2
                echo "        1 se ogni servizio ha il proprio context root (/portal, /api, …)," >&2
                echo "        di più se convivono sotto un'unica webapp (/app/rest/servizio → 3)." >&2
                return 1
            fi
            require_tool_sources service_times || return
            # SERVICE_PATH_TRANSPARENT è OPZIONALE, a differenza della profondità, e
            # la differenza non è incoerenza: l'assenza di una profondità è
            # ambigua (quale numero avrebbe voluto il profilo?), l'assenza di
            # prefissi trasparenti ha un solo significato possibile — non c'è
            # nulla da saltare — e produce esattamente il comportamento di prima.
            # Pretendere una lista vuota scritta a mano sarebbe cerimonia senza
            # protezione (SVCGRAN-2).
            local _svc_transp=""
            if declare -p SERVICE_PATH_TRANSPARENT >/dev/null 2>&1; then
                _svc_transp="$(IFS='|'; printf '%s' "${SERVICE_PATH_TRANSPARENT[*]}")"
            fi
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            # svc_transparent va racchiuso in apici SINGOLI dentro la stringa: questo
            # gawk è invocato via `eval`, e il separatore della lista è `|` — senza
            # quoting eval lo interpreterebbe come una PIPE e spezzerebbe il comando.
            # Stesso motivo per cui tw_args scrive -v time_from='...'.
            eval gawk "$tw_args" -f "$TOOLS_DIR/service_times.awk" \
                -v svc_depth="$SERVICE_PATH_DEPTH" \
                -v svc_transparent="'$_svc_transp'" \
                "$logs_expr"
            ;;
        gc_stats)
            require_tool_sources gc_stats || return
            logs_expr="$(open_gc_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/gc_stats.awk" \
                "$logs_expr"
            ;;
        correlate_gc_slow)
            # Due sorgenti: entrambe necessarie (TOOL_SOURCES[correlate_gc_slow]
            # ="gc access"), e il messaggio dice quale manca — require_tool_sources
            # si ferma al primo kind assente.
            require_tool_sources correlate_gc_slow || return
            local gc_expr access_expr
            gc_expr="$(open_gc_logs)"
            access_expr="$(open_logs)"
            print_log_source "$gc_expr $access_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/correlate_gc_slow.awk" \
                -v threshold_ms="${THRESHOLD_MS:-500}" \
                "$gc_expr" "$access_expr"
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
            #
            # Un solo guard per entrambi i rami di LOG_TYPE, non uno per ramo:
            # TOOL_SOURCES[tail_log]="access|server" è un OR runtime, e LOG_TYPE
            # è il selettore che sceglie quale delle due alternative richiedere
            # (se non è "server" si richiede la prima, "access" — stesso esito
            # del preesistente if/else, ora dichiarato invece che duplicato).
            require_tool_sources tail_log "${LOG_TYPE:-}" || return
            if [[ "${LOG_TYPE:-}" == "server" ]]; then
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_server_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                        -f "'$LIB_DIR/utils-${fmt}.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="server" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_server_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                fi
            else
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    logs_expr="$(open_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" -v log_kind="access" \
                        -v time_from="${TIME_FROM:-}" -v time_to="${TIME_TO:-}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                else
                    logs_expr="$(open_current_logs)"
                    print_log_source "$logs_expr"
                    eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                        -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                        -f "$TOOLS_DIR/tail_log.awk" \
                        -v tail_n="${TAIL_N:-50}" \
                        -v order="${LOG_ORDER:-tail}" \
                        "$logs_expr"
                fi
            fi
            ;;
        filter_ip)
            require_tool_sources filter_ip || return
            logs_expr="$(open_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_ip.awk" \
                -v ip_filter="$IP_FILTER" \
                -v top_n="${TAIL_N:-10}" \
                "$logs_expr"
            ;;
        filter_app_errors)
            require_tool_sources filter_app_errors || return
            logs_expr="$(open_server_logs)"
            print_log_source "$logs_expr"
            eval gawk "$tw_args" -f "$TOOLS_DIR/filter_app_errors.awk" \
                "$logs_expr"
            ;;
        tail_named_log)
            local search_root="${LOG_SEARCH_ROOT:-${CUSTOM_LOG_DIR:-}}"
            local named_log="${NAMED_LOG:-}"
            local log_glob="${NAMED_LOG_GLOB:-}"
            # Escape hatch: glob esplicito tra virgolette (validato in param-extract.sh)
            # bypassa la whitelist APP_LOG_NAMES e la catena fuzzy. Percorso eccezionale,
            # non quello normale — serve per i log imprevisti del profilo.
            if [[ -n "$log_glob" ]]; then
                local glob_expr=""
                [[ -n "$search_root" ]] && glob_expr=$(open_glob_logs "$search_root" "$log_glob")
                if [[ -z "$glob_expr" ]]; then
                    skip_msg "Nessun log corrispondente a '$log_glob' in ${search_root:-<search_root non impostata>}"
                    return
                fi
                print_log_source "$glob_expr" "(glob: $log_glob)"
                eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                    -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                    -f "$TOOLS_DIR/tail_named_log.awk" \
                    -v tail_n="${TAIL_N:-50}" \
                    -v order="${LOG_ORDER:-tail}" \
                    "$glob_expr"
                return
            fi
            if [[ -z "$named_log" ]]; then
                skip_msg "Nessun log applicativo specificato nella query"
                return
            fi
            local log_path
            log_path=$(resolve_named_log_path "$search_root" "$named_log")
            if [[ -z "$log_path" ]]; then
                skip_named_log_not_found "$search_root" "$named_log"
                return
            fi
            print_log_source "$(open_log "$log_path")"
            eval gawk -f "'$LIB_DIR/utils-time.awk'" -f "'$LIB_DIR/utils-logline.awk'" \
                -f "'$LIB_DIR/utils-colors.awk'" $theme_v \
                -f "$TOOLS_DIR/tail_named_log.awk" \
                -v tail_n="${TAIL_N:-50}" \
                -v order="${LOG_ORDER:-tail}" \
                "$(open_log "$log_path")"
            ;;
        grep_named_log)
            # SRCH-2: TOOL_SOURCES[grep_named_log]="named|server|access|gc" — con
            # selettore vuoto (query su log named) tool_source_kinds cade su
            # alts[0]="named", che il case sotto scarta senza chiamare
            # require_system_log: no-op esatto per il comportamento preesistente.
            # Con selettore concreto (SYSLOG_KIND) verifica la disponibilità PRIMA
            # di entrare nei rami sotto, come già fa tail_log con LOG_TYPE.
            require_tool_sources grep_named_log "${SYSLOG_KIND:-}" || return
            local search_root="${LOG_SEARCH_ROOT:-${CUSTOM_LOG_DIR:-}}"
            local named_log="${NAMED_LOG:-}"
            local log_glob="${NAMED_LOG_GLOB:-}"
            # SRCH-1: ricerca testuale in un log nominato ("cerca X nel cc.log").
            #
            # Il canale esisteva già ai due estremi ma non era collegato:
            # grep_named_log.awk accetta `-v pattern` (sua riga 5 e 35),
            # param-extract.sh estrae già SEARCH_PATTERN dal testo fra
            # virgolette, e il classificatore instrada già qui (96.7%).
            # Mancava solo il passaggio del parametro — nessun retrain, nessuna
            # nuova classe: era un canale già scavato ai due capi.
            #
            # SEMANTICA (decisa con l'utente, 2026-08-06): se la query porta un
            # pattern esplicito fra virgolette, l'intento è trovare QUEL testo,
            # quindi si cerca in tutto il file (level=ALL) e non solo fra gli
            # ERROR. Senza pattern resta il filtro per livello di prima.
            # La regola è deducibile dalla query, quindi non serve una parola
            # nuova nel vocabolario per esprimerla.
            local _gnl_pattern="${SEARCH_PATTERN:-}"
            # __MISSING__ è il segnale di param-extract.sh per "l'utente voleva
            # cercare qualcosa ma non ho trovato la stringa": qui vale come
            # assenza di pattern, non come pattern letterale.
            [[ "$_gnl_pattern" == "__MISSING__" ]] && _gnl_pattern=""
            # Bug prod 2026-08-19: "$_gnl_pattern" dentro l'`eval gawk` sotto
            # perde le virgolette nella riparsing di eval (il primo giro le
            # consuma, il secondo giro dell'`eval` risplitta la stringa sulle
            # parole) — un pattern con spazi (es. "No HeadersTranscoder
            # provided.") arriva a gawk come argomenti separati, letti come
            # nomi di file. printf %q produce una forma già "auto-quotata"
            # che sopravvive al secondo giro invariata (stesso principio di
            # tw_args:844, ma generale: %q gestisce anche apici e backtick,
            # non solo gli spazi).
            local _gnl_pattern_q
            printf -v _gnl_pattern_q '%q' "$_gnl_pattern"
            local _gnl_level="${LOG_LEVEL:-ERROR}"
            # LEVEL_EXPLICIT (da param-extract.sh) distingue "livello chiesto
            # dall'utente" da "default applicato": senza quel flag i due casi
            # arrivano qui identici (LOG_LEVEL='ERROR') e la regola non
            # scatterebbe mai.
            if [[ -n "$_gnl_pattern" && "${LEVEL_EXPLICIT:-0}" -eq 0 ]]; then
                _gnl_level="ALL"
            fi
            # Etichetta per l'utente: mostra cosa si sta effettivamente facendo,
            # altrimenti "(level=ALL)" senza contesto sembrerebbe un errore.
            local _gnl_what="(level=${_gnl_level})"
            [[ -n "$_gnl_pattern" ]] && _gnl_what="(cerca \"${_gnl_pattern}\", level=${_gnl_level})"
            # Stesso escape hatch di tail_named_log — vedi commento sopra.
            if [[ -n "$log_glob" ]]; then
                local glob_expr=""
                [[ -n "$search_root" ]] && glob_expr=$(open_glob_logs "$search_root" "$log_glob")
                if [[ -z "$glob_expr" ]]; then
                    skip_msg "Nessun log corrispondente a '$log_glob' in ${search_root:-<search_root non impostata>}"
                    return
                fi
                print_log_source "$glob_expr" "(glob: $log_glob)  $_gnl_what"
                eval gawk "$tw_args" -f "$TOOLS_DIR/grep_named_log.awk" \
                    -v level="$_gnl_level" \
                    -v pattern=$_gnl_pattern_q \
                    -v tail_n="${TAIL_N:-50}" \
                    "$glob_expr"
                return
            fi
            # SRCH-2: log di sistema nominato ("cerca X nel server.log"/"nel gc
            # log"/"nell'access log"). Dopo il glob (precedenza dichiarata in
            # normalize-query.sh: glob-like vince sempre) e prima del named, che
            # resta il fallback storico su NAMED_LOG.
            #
            # Rotazioni: solo il file corrente per default, storico completo
            # solo con range temporale esplicito (decisione utente) — stessa
            # convenzione di tail_log (:924/:946, TIME_EXPLICIT da chatbot.sh).
            # Allineare il costo al ramo named, che apre un solo file.
            #
            # require_app è già applicato qui: ACCESS_LOG_DIR/SERVER_LOG_DIR/
            # GC_LOG_DIR sono risolte con REQUIRE_APP=1 in resolve-logs.sh
            # all'avvio sessione (LOGDISC-4) — nessun controllo aggiuntivo da
            # fare in questo ramo, a differenza del ramo glob sopra che risolve
            # ad ogni query e per questo necessitava del fix a open_glob_logs.
            if [[ -n "${SYSLOG_KIND:-}" ]]; then
                local logs_expr=""
                if [[ "${TIME_EXPLICIT:-0}" == "1" ]]; then
                    case "$SYSLOG_KIND" in
                        server) logs_expr="$(open_server_logs)" ;;
                        access) logs_expr="$(open_logs)" ;;
                        gc)     logs_expr="$(open_gc_logs)" ;;
                    esac
                else
                    case "$SYSLOG_KIND" in
                        server) logs_expr="$(open_current_server_logs)" ;;
                        access) logs_expr="$(open_current_logs)" ;;
                        gc)     logs_expr="$(open_current_gc_logs)" ;;
                    esac
                fi
                print_log_source "$logs_expr" "$_gnl_what"
                # kind: solo qui, mai sul ramo glob/named sotto — è il
                # discriminante che grep_named_log.awk usa per non trattare il
                # timestamp fra quadre di access/gc come fosse un thread (A4).
                eval gawk "$tw_args" -f "$TOOLS_DIR/grep_named_log.awk" \
                    -v level="$_gnl_level" \
                    -v pattern=$_gnl_pattern_q \
                    -v tail_n="${TAIL_N:-50}" \
                    -v kind="$SYSLOG_KIND" \
                    "$logs_expr"
                return
            fi
            if [[ -z "$named_log" ]]; then
                skip_msg "Nessun log applicativo specificato nella query"
                return
            fi
            local log_path
            log_path=$(resolve_named_log_path "$search_root" "$named_log")
            if [[ -z "$log_path" ]]; then
                skip_named_log_not_found "$search_root" "$named_log"
                return
            fi
            print_log_source "$(open_log "$log_path")" "$_gnl_what"
            eval gawk "$tw_args" -f "$TOOLS_DIR/grep_named_log.awk" \
                -v level="$_gnl_level" \
                -v pattern=$_gnl_pattern_q \
                -v tail_n="${TAIL_N:-50}" \
                "$(open_log "$log_path")"
            ;;
        search_all_logs)
            # Il contratto si ferma a LOG_SEARCH_ROOT (principio 6): sotto la
            # directory del nodo il tool SCOPRE le directory dei log via
            # discover_log_dirs, quindi non riceve più i path costruiti da
            # APP_SUBPATH/CUSTOM_LOG_SUBPATH né i *_LOG_DIR/*_LOG_BASE — che
            # nominavano directory note, l'assunzione che LOGDISC-2 rimuove.
            export SEARCH_PATTERN TIME_FROM TIME_TO \
                   ACTIVE_ENV ACTIVE_NODE ACTIVE_APP DETECTED_NODE \
                   LOG_SEARCH_ROOT \
                   SEARCH_PARALLEL_JOBS LOG_BASE_DIR NODE_NAME_TEMPLATE
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
