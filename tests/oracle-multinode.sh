#!/bin/bash
#
# oracle-multinode.sh — conteggio ESAUSTIVO per nodo, indipendente dal bot.
#
# Serve a rispondere a una sola domanda: "il numero che il bot mostra per il
# nodo N è quello giusto?". Per poterlo fare deve essere in grado di
# CONTRADDIRE il bot, quindi:
#
#   NON sorgia nulla da lib/.
#
# Non è una svista né pigrizia: se l'oracolo usasse select_log_files_grouped,
# resolve_system_log_dir o node_num_canonical, un difetto in una di quelle
# funzioni si presenterebbe IDENTICO nei due conteggi e la verifica darebbe
# verde su un bug. È lo stesso motivo per cui il pre-gate di search_all_logs usa
# `-F` e non un motore regex diverso da quello di analisi: due strumenti che
# condividono l'assunzione sbagliata concordano sempre.
#
# Qui si usano solo `find`, `stat` e `gawk`, e la logica è la più stupida
# possibile: leggi TUTTO, filtra dopo. Nessun pruning temporale sui file —
# il pruning è l'ottimizzazione sotto esame, e un oracolo che la replica non la
# può smentire. Costa molto più del bot: è previsto, è il prezzo dell'indipendenza.
#
# SOLA LETTURA: nessuna scrittura fuori da stdout. Non tocca l'albero dei log.
#
# ─── Uso ──────────────────────────────────────────────────────────────────────
#
#   tests/oracle-multinode.sh \
#       --base-dir /unipol/logs/farmlog/liquido \
#       --env prod \
#       --node-glob 'lxprjbliq*' \
#       --log-base server \
#       --pattern ERROR \
#       --from 2026-08-27T09:00 --to 2026-08-27T10:00
#
# Il glob del nodo si passa LETTERALE e non si ricava da NODE_NAME_TEMPLATE:
# quel template è l'input della funzione sotto esame (è la riga che ha prodotto
# `lxprjbliq0009` in NODE-1). Un oracolo che lo espande da sé ripeterebbe
# l'errore che deve scoprire.
#
# --app SEGMENTO restringe ai path che contengono /SEGMENTO/ (attribuzione
# dell'app). Assente = nessun filtro, e i path completi restano visibili con
# --verbose per ispezionare a mano la provenienza.
#
# ─── La finestra deve essere STATICA ─────────────────────────────────────────
#
# Confrontare bot e oracolo su una finestra che comprende ADESSO è tempo perso:
# fra le due esecuzioni il log cresce e le rotazioni possono sparire. SALPERF-1
# ha misurato 72.940 occorrenze alle 16:00 e 56.676 alle 17:15 sulla STESSA
# domanda, perché le rotazioni del giorno prima erano state cancellate
# (retention di cc.log ~11 ore). Su finestra viva una differenza fra i due
# conteggi è INDISTINGUIBILE da un difetto di concorrenza. Lo script avvisa se
# --to cade nell'ora corrente, ma non rifiuta: decidere è di chi misura.
#
# ─── Tre stati per nodo, non due ─────────────────────────────────────────────
#
# Un nodo senza file leggibili produce `n/d` con il motivo, MAI 0. È la
# distinzione che questo progetto ha già dovuto imparare quattro volte (NODE-1,
# LOGSEL-1, RETENT-1, LVLCNT-1): uno zero e un'assenza di misura si leggono
# allo stesso modo in una tabella, e su 13 nodi lo zero plausibile è la
# risposta sbagliata più facile da credere.
#
# Le righe senza timestamp riconoscibile finiscono in un TERZO secchio
# (`undated`), non incluse né escluse dal conteggio filtrato. Il bot le include
# per prudenza (principio 5) e lo dichiara col marcatore `!`; l'oracolo le tiene
# separate, così il confronto resta leggibile: se i due numeri divergono
# esattamente di `undated`, la causa è quella e non un difetto di selezione.

set -uo pipefail

BASE_DIR="" ENV_NAME="" NODE_GLOB="" LOG_BASE="" PATTERN=""
FROM="" TO="" APP_SEG="" VERBOSE=0

die() { echo "[ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-dir)  BASE_DIR="$2";  shift 2 ;;
        --env)       ENV_NAME="$2";  shift 2 ;;
        --node-glob) NODE_GLOB="$2"; shift 2 ;;
        --log-base)  LOG_BASE="$2";  shift 2 ;;
        --pattern)   PATTERN="$2";   shift 2 ;;
        --from)      FROM="$2";      shift 2 ;;
        --to)        TO="$2";        shift 2 ;;
        --app)       APP_SEG="$2";   shift 2 ;;
        --verbose)   VERBOSE=1;      shift   ;;
        -h|--help)   sed -n '2,90p' "$0"; exit 0 ;;
        *)           die "opzione sconosciuta: $1" ;;
    esac
done

[[ -n "$BASE_DIR"  ]] || die "--base-dir obbligatorio"
[[ -n "$ENV_NAME"  ]] || die "--env obbligatorio"
[[ -n "$NODE_GLOB" ]] || die "--node-glob obbligatorio (letterale, es. 'lxprjbliq*')"
[[ -n "$LOG_BASE"  ]] || die "--log-base obbligatorio (es. server, undertow_access_log)"
[[ -n "$PATTERN"   ]] || die "--pattern obbligatorio"

ENV_ROOT="$BASE_DIR/$ENV_NAME"
[[ -d "$ENV_ROOT" ]] || die "ambiente non trovato: $ENV_ROOT"

# Avviso finestra viva. Il confronto va fatto su ore già chiuse (vedi testa file).
if [[ -n "$TO" ]]; then
    _now_h=$(date +%Y-%m-%dT%H)
    [[ "${TO:0:13}" == "$_now_h" ]] && \
        echo "[WARN] --to cade nell'ora corrente: il log cresce fra bot e oracolo, la differenza non sarà attribuibile." >&2
fi

# Limiti di confronto come STRINGHE "YYYY-MM-DD HH:MM:SS". Il confronto
# lessicografico su questo formato è equivalente a quello cronologico ed evita
# `date -d` per riga (1,1 ms l'una: su milioni di righe sarebbe l'intero costo
# della misura). :00/:59 rendono i limiti inclusivi sul minuto, come nel bot.
TF_CMP=""; TT_CMP=""
[[ -n "$FROM" ]] && TF_CMP="${FROM/T/ }:00"
[[ -n "$TO"   ]] && TT_CMP="${TO/T/ }:59"

# ─── Enumerazione dei nodi ────────────────────────────────────────────────────
# `find -maxdepth 1` sul glob letterale. Ordinato per nome: l'ordine deve essere
# deterministico perché il confronto col bot è riga per riga.
mapfile -t NODE_DIRS < <(find "$ENV_ROOT" -maxdepth 1 -type d -name "$NODE_GLOB" 2>/dev/null | sort)
[[ "${#NODE_DIRS[@]}" -gt 0 ]] && : || die "nessuna directory nodo per '$NODE_GLOB' in $ENV_ROOT"

printf '# oracolo esaustivo — env=%s log_base=%s pattern=%q finestra=%s→%s app=%s\n' \
    "$ENV_NAME" "$LOG_BASE" "$PATTERN" "${FROM:-*}" "${TO:-*}" "${APP_SEG:-<tutte>}"
printf '# nodi trovati: %d in %s\n' "${#NODE_DIRS[@]}" "$ENV_ROOT"
printf 'NODO\tSTATO\tFILE\tBYTE\tRIGHE_TOT\tMATCH\tMATCH_UNDATED\tMOTIVO\n'

TOT_MATCH=0 TOT_UNDATED=0 TOT_FILES=0 TOT_BYTES=0 N_MEASURED=0 N_UNAVAIL=0

for node_dir in "${NODE_DIRS[@]}"; do
    node_name=$(basename "$node_dir")
    # Numero nodo estratto dalla CODA del nome, senza normalizzazione: qualunque
    # canonicalizzazione qui sarebbe una seconda implementazione di
    # node_num_canonical, cioè della funzione sotto esame.
    node_num="${node_name##*[!0-9]}"

    if [[ ! -r "$node_dir" ]]; then
        printf '%s\tn/d\t-\t-\t-\t-\t-\t%s\n' "$node_num" "directory nodo non leggibile"
        N_UNAVAIL=$(( N_UNAVAIL + 1 ))
        continue
    fi

    # Scoperta RICORSIVA e esaustiva: ogni file il cui nome comincia col basename
    # logico, in qualunque punto sotto il nodo. Copre il corrente, i `.gz` e le
    # rotazioni `BASENAME.DATE.log` senza conoscerne lo schema — non si elencano
    # directory note (il contratto del profilo si ferma al nodo) e non si
    # interpretano i nomi delle rotazioni.
    _find_args=( "$node_dir" -type f -name "${LOG_BASE}*" )
    mapfile -t files < <(find "${_find_args[@]}" 2>/dev/null | sort)

    # Filtro app come segmento di path, se richiesto.
    if [[ -n "$APP_SEG" ]]; then
        _keep=()
        for f in "${files[@]}"; do
            [[ "$f" == *"/$APP_SEG/"* ]] && _keep+=("$f")
        done
        files=("${_keep[@]}")
    fi

    if [[ "${#files[@]}" -eq 0 ]]; then
        _why="nessun file ${LOG_BASE}* sotto il nodo"
        [[ -n "$APP_SEG" ]] && _why+=" (con /$APP_SEG/ nel path)"
        printf '%s\tn/d\t0\t0\t-\t-\t-\t%s\n' "$node_num" "$_why"
        N_UNAVAIL=$(( N_UNAVAIL + 1 ))
        continue
    fi

    # Un file presente ma illeggibile è n/d per il NODO, non uno zero: contarlo
    # come 0 righe farebbe sparire dati esistenti dietro un numero credibile.
    _unreadable=""
    for f in "${files[@]}"; do
        [[ -r "$f" ]] || { _unreadable="$f"; break; }
    done
    if [[ -n "$_unreadable" ]]; then
        printf '%s\tn/d\t%d\t-\t-\t-\t-\t%s\n' "$node_num" "${#files[@]}" \
            "file non leggibile: $(basename "$_unreadable")"
        N_UNAVAIL=$(( N_UNAVAIL + 1 ))
        continue
    fi

    nbytes=0
    for f in "${files[@]}"; do
        nbytes=$(( nbytes + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done

    [[ "$VERBOSE" -eq 1 ]] && printf '#   nodo %s: %s\n' "$node_num" "$(printf '%s ' "${files[@]}")"

    # Lettura: i `.gz` decompressi uno per uno e concatenati sullo stesso stream.
    # `gunzip -c` e non `pigz`: l'oracolo non deve condividere col bot nemmeno la
    # scelta del decompressore — se `pigz` troncasse uno stream corrotto in modo
    # silenzioso, i due conteggi sbaglierebbero insieme.
    #
    # Il match è LETTERALE e case-insensitive, via index(tolower()): nessun
    # motore regex, quindi nessun dialetto da far divergere da quello del bot.
    # Un pattern con metacaratteri va inteso alla lettera anche qui.
    read -r nlines nmatch nundated < <(
        {
            for f in "${files[@]}"; do
                if [[ "$f" == *.gz ]]; then
                    gunzip -c -- "$f" 2>/dev/null
                else
                    cat -- "$f" 2>/dev/null
                fi
            done
        } | gawk -v pat="$PATTERN" -v tf="$TF_CMP" -v tt="$TT_CMP" '
            function ts_of(line,   t) {
                # Prima occorrenza di YYYY-MM-DD[ T]HH:MM:SS in qualunque punto
                # della riga: volutamente permissivo e volutamente unico. Il bot
                # ha sei grammatiche di timestamp (utils-logline.awk); riprodurle
                # renderebbe questo oracolo dipendente dalla stessa
                # interpretazione che deve verificare.
                # NB: nessun apostrofo nei commenti dentro questo blocco — il
                # programma AWK vive in una stringa a singoli apici, e un
                # apostrofo italiano la chiude a metà (difetto reale, trovato
                # alla prima esecuzione su fixture).
                if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                    t = substr(line, RSTART, 19)
                    sub(/T/, " ", t)
                    return t
                }
                return ""
            }
            BEGIN { lpat = tolower(pat); n = 0; m = 0; u = 0 }
            {
                n++
                if (index(tolower($0), lpat) == 0) next
                ts = ts_of($0)
                if (ts == "") { u++; next }        # terzo secchio, non incluso
                if (tf != "" && ts < tf) next
                if (tt != "" && ts > tt) next
                m++
            }
            END { print n+0, m+0, u+0 }
        '
    )

    printf '%s\tok\t%d\t%d\t%d\t%d\t%d\t-\n' \
        "$node_num" "${#files[@]}" "$nbytes" "${nlines:-0}" "${nmatch:-0}" "${nundated:-0}"

    TOT_MATCH=$(( TOT_MATCH + ${nmatch:-0} ))
    TOT_UNDATED=$(( TOT_UNDATED + ${nundated:-0} ))
    TOT_FILES=$(( TOT_FILES + ${#files[@]} ))
    TOT_BYTES=$(( TOT_BYTES + nbytes ))
    N_MEASURED=$(( N_MEASURED + 1 ))
done

printf '#\n'
printf '# SOMMA\tmatch=%d\tmatch_undated=%d\tfile=%d\tbyte=%d\n' \
    "$TOT_MATCH" "$TOT_UNDATED" "$TOT_FILES" "$TOT_BYTES"
printf '# misurati %d/%d nodi' "$N_MEASURED" "${#NODE_DIRS[@]}"
[[ "$N_UNAVAIL" -gt 0 ]] && printf ' (%d n/d, vedi colonna MOTIVO)' "$N_UNAVAIL"
printf '\n'
# L'invariante da confrontare col bot è SOMMA match, non le righe per nodo: le
# righe possono differire legittimamente se il bot deduplica o eredita i
# timestamp delle stack frame. La somma no — o legge gli stessi eventi o non li
# legge. Se differisce di esattamente match_undated, la causa è il trattamento
# delle righe non databili e non la selezione dei file.
