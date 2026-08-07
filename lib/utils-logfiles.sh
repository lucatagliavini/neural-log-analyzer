#!/bin/bash
#
# utils-logfiles.sh — selezione file di log per range temporale.
#
# Funzioni principali:
#   select_log_files DIR BASENAME [TIME_FROM] [TIME_TO]
#       Wrapper storico: BASENAME è il nome logico esatto da selezionare
#       (es. "undertow_access_log", "gc") — non un prefisso.
#   select_log_files_grouped DIR [TIME_FROM] [TIME_TO] [LOGICAL_NAME]
#       Motore generalizzato: LOGICAL_NAME vuoto seleziona TUTTI i nomi
#       logici trovati in DIR (caso log applicativi custom — cartella flat
#       senza basename uniforme), raggruppando ogni log e le sue rotazioni.
#
#   DIR      : directory dove cercare i file
#   TIME_FROM: "YYYY-MM-DDTHH:MM" (vuoto = nessun limite inferiore)
#   TIME_TO  : "YYYY-MM-DDTHH:MM" (vuoto = nessun limite superiore)
#
# Restituisce (stdout) la lista |-separata di file candidati, ordinata per
# ts_start crescente, che si sovrappongono al range [TIME_FROM, TIME_TO].
#
# Strategia (walk backward con arresto anticipato, 2026-08-06): per ogni
# gruppo (stesso nome logico) si parte dal file più RECENTE — nell'ordine
# dato dal NOME, non da mtime: i log sono copiati/sincronizzati, quindi
# mtime non riflette l'ultima scrittura reale (confermato dall'utente) — e
# si scende alle rotazioni più vecchie SOLO se la finestra richiesta non è
# ancora coperta. Le rotazioni di uno stesso log sono contigue nel tempo,
# quindi il ts_end di un file è ≈ ts_start del successivo: non va MAI letto.
# Ci si ferma al primo file con ts_start <= TIME_FROM (la finestra è
# coperta, tutto ciò che è più vecchio non serve). Per una finestra breve
# ("ultime 2 ore") si legge solo la prima riga del file corrente e si
# ferma: zero letture sulle rotazioni.
#
# Conservativo per costruzione: un file con ts_start non riconoscibile non
# ferma mai il walk ed è SEMPRE incluso (non si esclude per ignoranza). Un
# file con ts_start più recente di TIME_TO viene escluso (è interamente
# dopo la finestra) ma il walk continua sui più vecchi — un falso negativo
# nel pruning sarebbe un bug di correttezza, un falso positivo è solo
# lentezza.
#
# Gestisce qualsiasi naming di rotazione:
#   - BASENAME.log           (log corrente)
#   - BASENAME.log.0 / .1   (rotazione JVM numerata)
#   - BASENAME.log-DATE-EPOCH.gz  (rotazione per dimensione Undertow)
#   - BASENAME.DATE.log / .gz     (rotazione giornaliera)
#   - BASENAME.log-DATE-EPOCH.gz  (rotazione giornaliera compressa)
#

source "$(dirname "${BASH_SOURCE[0]}")/utils-log.sh"

_logfiles_read_first_ts() {
    local f="$1"
    local line=""
    if [[ "$f" == *.gz ]]; then
        # GZ_CAT (utils-log.sh): pigz -dc se disponibile. Qui il guadagno è
        # minimo — si leggono solo i primi 4KB e il decompressore riceve
        # SIGPIPE subito — ma resta l'unica fonte di verità sul decompressore.
        line=$($GZ_CAT "$f" 2>/dev/null | head -c 4096 | grep -m1 '')
    else
        line=$(head -1 "$f" 2>/dev/null)
    fi
    # Prova i tre formati timestamp noti:
    # access log:  [DD/Mon/YYYY:HH:MM:SS
    # gc.log:      [YYYY-MM-DDTHH:MM:SS
    # server.log:  YYYY-MM-DD HH:MM:SS,mmm
    local ts=""
    if [[ "$line" =~ \[([0-9]{2}/[A-Za-z]{3}/[0-9]{4}):([0-9]{2}):([0-9]{2}) ]]; then
        # Undertow: [29/Jul/2026:06:00:07
        local day="${BASH_REMATCH[1]%%/*}"
        local rest="${BASH_REMATCH[1]#*/}"
        local mon="${rest%%/*}"
        local yr="${rest#*/}"
        local hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
        declare -A _M=([Jan]=01 [Feb]=02 [Mar]=03 [Apr]=04 [May]=05 [Jun]=06
                       [Jul]=07 [Aug]=08 [Sep]=09 [Oct]=10 [Nov]=11 [Dec]=12)
        local mnum="${_M[$mon]:-01}"
        ts=$(date -d "${yr}-${mnum}-${day} ${hh}:${mm}:00" +%s 2>/dev/null || echo "")
    elif [[ "$line" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}) ]]; then
        # GC log: [2026-07-29T11:51:37
        ts=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null || echo "")
    elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}):([0-9]{2}) ]]; then
        # Server log (JBoss): 2026-07-29 08:01:23,456
        ts=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null || echo "")
    elif [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}) ]]; then
        # Log applicativo custom (es. Guidewire nel profilo liquido):
        # [thread] USER 2026-08-04T15:50:01,443 INFO messaggio
        # Timestamp ISO8601 in posizione variabile, NON fra parentesi quadre e non
        # a inizio riga — nessuno dei tre pattern sopra lo catturava, quindi questi
        # log davano ts_start=0 e il filtro temporale di select_log_files non
        # poteva discriminarli. Difetto preesistente, emerso testando il glob
        # sulle rotazioni (2026-08-04). Va ULTIMO: il ramo GC sopra è più specifico
        # (richiede la parentesi quadra) e deve avere precedenza.
        ts=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null || echo "")
    fi
    echo "${ts:-0}"
}

# Chiave di ordinamento "più recente per primo" per il walk backward, DERIVATA
# DAL NOME del file — mai da mtime, che è inaffidabile per log copiati/
# sincronizzati (confermato dall'utente, 2026-08-06). Fasce numeriche distinte
# per non far collidere schemi di rotazione diversi all'interno dello stesso
# confronto (un gruppo usa in pratica uno schema solo, ma le fasce restano
# comunque ordinate correttamente se mai si mescolassero):
#   corrente (nessun suffisso di rotazione)  -> sentinella massima
#   rotazione numerata .log.N(.gz)           -> fascia alta, N piccolo = più
#                                                recente (.1 è più nuovo di .2:
#                                                l'ordinale è INVERTITO — un
#                                                `sort` lessicografico su .1,
#                                                .10, .11, .2 sbaglierebbe)
#   rotazione con epoch nel nome              -> l'epoch stesso (fascia
#                                                "naturale", è già l'istante
#                                                di rotazione = ts_end del file)
#   pattern non riconosciuto                  -> mtime come ultima risorsa
_logfiles_sort_key() {
    local f="$1" logical="$2"
    local base="${f##*/}"
    local rest="${base#"$logical"}"
    rest="${rest%.gz}"
    if [[ "$rest" == ".log" || -z "$rest" ]]; then
        echo 9999999999
        return
    fi
    if [[ "$rest" =~ \.log-[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$rest" =~ \.log\.([0-9]+)$ ]]; then
        echo $(( 5000000000 - ${BASH_REMATCH[1]} ))
        return
    fi
    # Rotazione giornaliera (undertow_access_log.2026-07-14.log): la data
    # precede .log invece di seguirlo, stesso schema di logfile_logical_name().
    # Convertita in epoch reale così è comparabile con la rotazione con epoch.
    if [[ "$rest" =~ \.([0-9]{4}-[0-9]{2}-[0-9]{2})\.log$ ]]; then
        date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null && return
        echo 0
        return
    fi
    stat -c %Y "$f" 2>/dev/null || echo 0
}

# select_log_files_grouped DIR [TIME_FROM] [TIME_TO] [NAME_FILTER]
#
# Motore generalizzato: NAME_FILTER vuoto seleziona TUTTI i nomi logici
# trovati in DIR (cartella flat multi-log, es. i log applicativi custom di
# un profilo Guidewire); un NAME_FILTER
# tipo "${BASE}*" restringe ai file che iniziano per BASE, poi filtra al
# nome logico ESATTO — quindi "prod1nsse-cc" non si tira dietro
# "prod1nsse-ccCanaliz" (prima il post-filtro viveva nel chiamante,
# dispatch.sh:90; qui è nel motore, quindi vale per tutti i chiamanti).
#
# Per ogni gruppo (stesso nome logico) cammina dal file più recente al più
# vecchio (vedi header del file per la strategia) fermandosi non appena la
# finestra richiesta è coperta. Restituisce (stdout) i file selezionati,
# `|`-separati, ordinati per ts_start crescente — stesso contratto di
# select_log_files().
select_log_files_grouped() {
    local dir="$1" tf_raw="${2:-}" tt_raw="${3:-}" name_filter="${4:-}"

    local tf_epoch=0 tt_epoch=99999999999
    [[ -n "$tf_raw" ]] && tf_epoch=$(date -d "${tf_raw//T/ }" +%s 2>/dev/null || echo 0)
    [[ -n "$tt_raw" ]] && tt_epoch=$(date -d "${tt_raw//T/ }" +%s 2>/dev/null || echo 99999999999)
    local do_filter=0
    [[ -n "$tf_raw" || -n "$tt_raw" ]] && do_filter=1

    # -type f: senza, `find -name "*"` con NAME_FILTER vuoto matcha anche DIR
    # stessa (bug latente, 2026-08-06 — innocuo finché nessuno passava un
    # filtro vuoto, ma il caso dei log applicativi custom lo richiede esplicitamente).
    local -a candidates=()
    while IFS= read -r f; do
        [[ -s "$f" ]] && candidates+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "${name_filter:-*}" 2>/dev/null | sort)
    local wanted="${name_filter%\*}"

    # Raggruppa per nome logico
    local -A group_files=()
    local -a group_order=()
    local f logical
    for f in "${candidates[@]}"; do
        logical=$(logfile_logical_name "$f")
        [[ -n "$name_filter" && "$logical" != "$wanted" ]] && continue
        if [[ -z "${group_files[$logical]:-}" ]]; then
            group_order+=("$logical")
        fi
        group_files["$logical"]+="$f"$'\n'
    done

    local -a selected=()
    local -A ts_start_map=()

    for logical in "${group_order[@]}"; do
        local -a group_arr=()
        while IFS= read -r f; do [[ -n "$f" ]] && group_arr+=("$f"); done <<< "${group_files[$logical]}"

        # Ordina il gruppo dal più recente al più vecchio (walk backward)
        local -a keyed=()
        for f in "${group_arr[@]}"; do
            keyed+=("$(_logfiles_sort_key "$f" "$logical")"$'\t'"$f")
        done
        local -a ordered=()
        while IFS=$'\t' read -r _k f; do
            [[ -n "$f" ]] && ordered+=("$f")
        done < <(printf '%s\n' "${keyed[@]}" | sort -t$'\t' -k1,1nr)

        for f in "${ordered[@]}"; do
            local ts_start
            # Feedback progressivo: la lettura del primo timestamp costa un
            # head (o una decompressione parziale per i .gz) per file — su una
            # finestra ampia il walk può scendere su molte rotazioni, e senza
            # questo l'utente resta davanti a una shell ferma. Vive qui, nel
            # motore condiviso, così TUTTI i tool ne beneficiano e non solo
            # search_all_logs (principio 2+4 di CLAUDE.md, 2026-08-06).
            progress_show "selezione log: $(basename "$f")"
            ts_start=$(_logfiles_read_first_ts "$f")

            if [[ "$do_filter" -eq 1 && "$ts_start" -gt 0 && "$ts_start" -gt "$tt_epoch" ]]; then
                # Interamente dopo la finestra: escludi, ma continua a
                # scendere — un file più vecchio può comunque essere in range.
                log_debug "select_log_files_grouped: escluso $(basename "$f") (ts_start=$ts_start > tt=$tt_epoch)"
                continue
            fi

            ts_start_map["$f"]=$ts_start
            selected+=("$f")
            log_debug "select_log_files_grouped: incluso $(basename "$f") (ts_start=$ts_start)"

            [[ "$do_filter" -eq 0 ]] && continue
            if [[ "$ts_start" -gt 0 && "$ts_start" -le "$tf_epoch" ]]; then
                # La finestra è coperta: tutto ciò che è più vecchio non serve.
                log_debug "select_log_files_grouped: finestra coperta da $(basename "$f"), stop su gruppo '$logical'"
                break
            fi
            # ts_start ignoto (0): conservativo, non si ferma sull'ignoto.
        done
    done
    progress_clear
    log_debug "select_log_files_grouped: dir=$dir filtro='${name_filter:-*}' gruppi=${#group_order[@]} selezionati=${#selected[@]}"

    # Ordina TUTTI i selezionati per ts_start crescente (insertion sort)
    local n=${#selected[@]}
    for (( i=1; i<n; i++ )); do
        local key="${selected[$i]}"
        local key_ts="${ts_start_map[$key]}"
        local j=$(( i - 1 ))
        while (( j >= 0 )) && [[ "${ts_start_map[${selected[$j]}]}" -gt "$key_ts" ]]; do
            selected[$(( j+1 ))]="${selected[$j]}"
            (( j-- )) || true
        done
        selected[$(( j+1 ))]="$key"
    done

    local out=""
    for f in "${selected[@]}"; do
        out+="${f}|"
    done
    echo "${out%|}"
}

# select_log_files DIR BASENAME [TIME_FROM] [TIME_TO]
# Wrapper storico — firma e contratto di output invariati per i chiamanti
# esistenti (dispatch.sh, search_all_logs.sh). BASENAME è trattato come
# prefisso ("${BASENAME}*") e poi ristretto al nome logico esatto dal motore.
select_log_files() {
    local dir="$1" base="$2" tf_raw="${3:-}" tt_raw="${4:-}"
    select_log_files_grouped "$dir" "$tf_raw" "$tt_raw" "${base}*"
}

# Rimuove il suffisso di rotazione dal nome di un file di log, restituendo il
# "nome logico" — la chiave per capire se due file sono lo stesso log in momenti
# diversi o due log distinti.
#   prod1nsse-cc.log                        -> prod1nsse-cc
#   prod1nsse-cc.log-2026-07-26-17850.gz    -> prod1nsse-cc
#   prod1nsse-cc.log.3.gz                   -> prod1nsse-cc
#   undertow_access_log.2026-07-14.log      -> undertow_access_log
logfile_logical_name() {
    local base="${1##*/}"
    base="${base%.gz}"
    # -DATE-EPOCH oppure .N appesi dopo .log
    base=$(sed -E 's/\.log([-.].*)?$/.log/' <<< "$base")
    # Rotazione giornaliera: la data precede .log invece di seguirlo
    # (undertow_access_log.2026-07-14.log) — bug reale in produzione,
    # 19 rotazioni giornaliere producevano 19 nomi logici distinti invece di 1
    # (2026-08-07). Schema già dichiarato nell'header del file ma non gestito qui.
    base=$(sed -E 's/\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$/.log/' <<< "$base")
    echo "${base%.log}"
}

# Un nome logico è "di sistema" (access/server/gc) se coincide, case-insensitive,
# con uno dei tre *_LOG_BASE di system.conf, o con un sinonimo mappato su uno di
# essi via SYSTEM_LOG_SYNONYMS (es. "access" -> "undertow_access_log": il nome
# su disco non coincide con la parola naturale che gli utenti digitano).
# Questi log hanno tool e sintassi dedicati ("access log", non "<nome>.log"):
# condiviso da param-extract.sh (esclude il fallback NAMED_LOG),
# normalize-query.sh (sezione 3.5, esclude <LOGFILE>) e list_available_logs()
# in dispatch.sh (esclude la sezione "Log del nodo") — un solo punto di verità
# invece di più copie della stessa condizione (principio 2 di CLAUDE.md).
_is_system_log_base() {
    local name="${1,,}"
    if declare -p SYSTEM_LOG_SYNONYMS &>/dev/null; then
        local _mapped="${SYSTEM_LOG_SYNONYMS[$name]:-}"
        [[ -n "$_mapped" ]] && name="${_mapped,,}"
    fi
    local _sysb
    for _sysb in "${ACCESS_LOG_BASE:-}" "${SERVER_LOG_BASE:-}" "${GC_LOG_BASE:-}"; do
        [[ -n "$_sysb" && "$name" == "${_sysb,,}" ]] && return 0
    done
    return 1
}

# Risolve un glob in un singolo file "rappresentante", disambiguando quando il
# pattern matcha log logicamente diversi (es. "*cc*.log" → cc, ccJBatch, ccCanaliz).
#
# Distinzione necessaria: le ROTAZIONI dello stesso log vanno lette insieme (ci
# pensa select_log_files), mentre log DIVERSI richiedono una scelta. Senza questa
# distinzione un `sort | head -1` sceglierebbe silenziosamente, che è il difetto
# che questo progetto ha già pagato altrove.
#
# La ricerca è RICORSIVA sotto DIR (contratto: il profilo risolve fino al nodo,
# sotto la struttura si scopre — vedi CLAUDE.md). Questo introduce una seconda
# fonte di ambiguità oltre alle rotazioni: sotto un nodo possono coesistere più
# app con file omonimi (es. "undertow_access_log.log" identico sotto ClaimCenter
# e ContactManager) o con lo stesso <nome> richiesto ma serverid diverso (es.
# "prod1nsse-cc.log" vs "prod1nssd-cc.log"). In entrambi i casi la preferenza
# per l'app della sessione corrente (ACTIVE_APP) viene prima di qualunque altro
# criterio, sia nella scelta del rappresentante di un gruppo (stesso nome
# logico, dir diverse) sia nella scelta finale fra nomi logici diversi.
#
# Uso:  path=$(resolve_log_glob DIR GLOB [DISPLAY_LABEL] [REQUIRE_APP])
# DISPLAY_LABEL è quello che l'utente ha digitato (es. il <nome> della query);
# senza, l'avviso di disambiguazione mostrerebbe il pattern find interno.
# REQUIRE_APP=1 rifiuta silenziosamente (return 1, nessun output) un match
# trovato solo fuori dall'app di sessione (ACTIVE_APP): decisione utente
# 2026-08-07 — se il log chiesto esiste solo sotto un'altra app, non va
# aperto, va detto "non trovato" (il chiamante suggerisce l'app altrove, vedi
# dispatch.sh:_find_named_log_elsewhere). Senza REQUIRE_APP, ACTIVE_APP resta
# solo un criterio di preferenza nel tie-break, non un vincolo.
# Stampa su stdout il path scelto; l'elenco di disambiguazione va su stderr, così
# non inquina il valore di ritorno.
resolve_log_glob() {
    local dir="$1" glob="$2" display_label="${3:-$2}" require_app="${4:-}"
    [[ -z "$dir" || -z "$glob" ]] && return 1

    local -a matches=()
    while IFS= read -r f; do [[ -n "$f" ]] && matches+=("$f"); done \
        < <(find "$dir" \( -type f -o -type l \) -name "$glob" 2>/dev/null | sort)
    [[ "${#matches[@]}" -eq 0 ]] && return 1

    # I candidati toccano più di una directory? Serve per l'elenco: mostrare il
    # path relativo alla root invece del solo basename evita righe identiche
    # quando lo stesso nome esiste sotto app diverse.
    local multi_dir=0 _d0=""
    for f in "${matches[@]}"; do
        local _d="${f%/*}"
        if [[ -z "$_d0" ]]; then _d0="$_d"; elif [[ "$_d" != "$_d0" ]]; then multi_dir=1; break; fi
    done

    # Raggruppa per nome logico; per ogni gruppo scegli UN rappresentante con
    # priorità: app corrente > file non ruotato (.log esatto) > path più corto >
    # alfabetico. Un gruppo con candidati in directory diverse è una collisione
    # reale (stesso nome sotto app diverse), non una rotazione — la priorità
    # app-corrente decide, senza dipendere dall'ordine del filesystem.
    local -A rep=()
    local -a order=()
    local f lname
    for f in "${matches[@]}"; do
        lname=$(logfile_logical_name "$f")
        if [[ -z "${rep[$lname]:-}" ]]; then
            rep["$lname"]="$f"
            order+=("$lname")
            continue
        fi
        local cur="${rep[$lname]}"
        local cur_app=1 f_app=1
        [[ -n "${ACTIVE_APP:-}" && "$cur" == *"/${ACTIVE_APP}/"* ]] && cur_app=0
        [[ -n "${ACTIVE_APP:-}" && "$f"   == *"/${ACTIVE_APP}/"* ]] && f_app=0
        local cur_rot=1 f_rot=1
        [[ "$cur" == *.log ]] && cur_rot=0
        [[ "$f"   == *.log ]] && f_rot=0
        if [[ "$f_app" -lt "$cur_app" ]] \
            || { [[ "$f_app" -eq "$cur_app" ]] && [[ "$f_rot" -lt "$cur_rot" ]]; } \
            || { [[ "$f_app" -eq "$cur_app" && "$f_rot" -eq "$cur_rot" ]] && [[ "${#f}" -lt "${#cur}" ]]; } \
            || { [[ "$f_app" -eq "$cur_app" && "$f_rot" -eq "$cur_rot" && "${#f}" -eq "${#cur}" ]] && [[ "$f" < "$cur" ]]; }; then
            rep["$lname"]="$f"
        fi
    done

    # La SCELTA fra nomi logici diversi deve essere deterministica: `order[@]`
    # segue l'ordine di find, che varia con locale e filesystem — basarsi su
    # quello la renderebbe arbitraria (verificato: sul server "*cc*.log"
    # sceglieva ccCanaliz, in locale cc). Criterio: app corrente, poi nome
    # logico più corto (fra "cc", "ccCanaliz" e "ccJBatch" vince "cc" — il log
    # base, non una sua variante: l'interpretazione più probabile di "*cc*"),
    # poi alfabetico.
    local _by_pref
    _by_pref=$(for lname in "${order[@]}"; do
        local app_flag=1
        [[ -n "${ACTIVE_APP:-}" && "${rep[$lname]}" == *"/${ACTIVE_APP}/"* ]] && app_flag=0
        printf '%d %04d %s\n' "$app_flag" "${#lname}" "$lname"
    done | sort -k1,1n -k2,2n -k3,3)
    local chosen=""
    chosen="${rep[$(head -1 <<< "$_by_pref" | awk '{print $3}')]}"

    # Vincolo (non solo preferenza): il log scelto deve stare sotto l'app di
    # sessione. Se tutti i candidati sono altrove, non è "il migliore che ho
    # trovato" — è il log di un'altra app, e apre lo scenario che l'utente ha
    # chiesto di evitare (mescolare dati di app diverse senza dirlo).
    if [[ -n "$require_app" && -n "${ACTIVE_APP:-}" && "$chosen" != *"/${ACTIVE_APP}/"* ]]; then
        return 1
    fi

    # L'ELENCO invece si presenta in ordine alfabetico: è quello che l'utente si
    # aspetta scorrendo una lista di nomi.
    local _by_name
    _by_name=$(printf '%s\n' "${order[@]}" | sort)
    order=()
    while IFS= read -r lname; do [[ -n "$lname" ]] && order+=("$lname"); done <<< "$_by_name"

    if [[ "${#order[@]}" -gt 1 ]]; then
        local _Y="${C_WARN}" _D="${C_LBL}" _X="${C_RESET}"
        printf "${_Y}⚠ '%s' corrisponde a %d log diversi — mostrato il primo non ruotato:${_X}\n" \
            "$display_label" "${#order[@]}" >&2
        local i=1
        for lname in "${order[@]}"; do
            if [[ "$i" -gt 10 ]]; then
                printf "    ${_D}… e altri %d${_X}\n" "$(( ${#order[@]} - 10 ))" >&2
                break
            fi
            local tag="" label="${rep[$lname]##*/}"
            [[ "$multi_dir" -eq 1 ]] && label="${rep[$lname]#"$dir"/}"
            [[ "${rep[$lname]}" == "$chosen" ]] && tag="  (mostrato)"
            printf "    %d) %s%s\n" "$i" "$label" "$tag" >&2
            i=$(( i + 1 ))
        done
        # Suggerisce il pattern che avrebbe selezionato univocamente il file scelto:
        # dal nome logico si prende il segmento dopo l'ultimo '-' (il serverID che
        # precede è la parte che l'utente non ricorda).
        local _hint
        _hint=$(logfile_logical_name "$chosen")
        printf "  ${_D}Restringi il pattern per un match univoco, es: \"*-%s.log\"${_X}\n" \
            "${_hint##*-}" >&2
    fi

    echo "$chosen"
}
