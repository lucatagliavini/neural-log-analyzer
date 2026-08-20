#!/bin/bash
#
# Estrae parametri strutturati da una query in linguaggio naturale.
# Emette variabili shell: TIME_FROM, TIME_TO, DATE_FILTER,
#                         STATUS_CODE, THRESHOLD_MS, IP_FILTER, TAIL_N, LOG_ORDER,
#                         NAMED_LOG
#
# Uso: eval "$(./lib/param-extract.sh "errori 500 delle ultime 3 ore")"
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils-time.sh"
# Solo per _is_system_log_base (esclusione basename di sistema dal fallback
# NAMED_LOG, sotto) — unica fonte di verità condivisa con dispatch.sh.
source "$SCRIPT_DIR/utils-log.sh"
source "$SCRIPT_DIR/utils-logfiles.sh"

# Carica gli ambienti del profilo per costruire il pattern di stop-word dinamico
if [[ -n "${PROFILE_DIR:-}" && -f "$PROFILE_DIR/system.conf" ]]; then
    source "$PROFILE_DIR/system.conf"
fi

query="${1,,}"

# Finestra temporale — delegata a utils-time.sh
eval "$(resolve_time_range "$query")"

# Codice HTTP specifico: 200, 404, 500, 503, 4xx, 5xx ...
#
# Un numero di tre cifre che inizia per 4 o 5 non è per forza uno status HTTP: nella
# stessa posizione può essere un CONTEGGIO ("ultime 500 righe") o una SOGLIA
# ("sopra i 500 ms", "ultimi 450 minuti"). La regex nuda `\b[45][0-9]{2}\b` non
# distingue i ruoli, quindi assegnava STATUS_CODE=500 a tutte e tre le frasi.
#
# Oggi il difetto è latente — nei casi misurati si attiva un solo tool e non legge
# STATUS_CODE — ma è una trappola: basta che un tool multi-label che lo consuma
# superi TOOL_THRESHOLD sulla stessa query e l'utente riceve un conteggio di
# errori 500 che non ha chiesto, senza che nulla lo segnali.
#
# Si disambigua per RUOLO invece che con un lookahead (non disponibile in grep -E,
# e `grep -P` non è garantito sul server ppc64le): dalla query si rimuovono prima
# le occorrenze in cui il numero è legato a un quantificatore o a un'unità di
# misura, poi si cerca lo status in ciò che resta. Uno stesso numero non può avere
# due ruoli nella stessa frase.
_sq_status=$(echo "$query" | sed -E '
    s/(ultim|prim)[aeio]+ +[0-9]+//g;
    s/[0-9]+ *(ms|millisecond[oi]?|secondi?|sec\b|minut[oi]|or[ae]|giorn[oi]|rig[ah]|record|linee|lin\b)//g')
STATUS_CODE=""
if   echo "$_sq_status" | grep -qE "\b[45][0-9]{2}\b"; then
    STATUS_CODE=$(echo "$_sq_status" | grep -oE "\b[45][0-9]{2}\b" | head -1)
elif echo "$_sq_status" | grep -qE "\b[2][0-9]{2}\b"; then
    STATUS_CODE=$(echo "$_sq_status" | grep -oE "\b[2][0-9]{2}\b" | head -1)
elif echo "$query" | grep -qE "5xx"; then
    STATUS_CODE="5xx"
elif echo "$query" | grep -qE "4xx"; then
    STATUS_CODE="4xx"
fi

# Soglia latenza in ms: "più lente di N ms" / "sopra i N ms" / "oltre N ms"
THRESHOLD_MS=""
if echo "$query" | grep -qE "[0-9]+ ms"; then
    THRESHOLD_MS=$(echo "$query" | grep -oE "[0-9]+ ms" | grep -oE "[0-9]+" | head -1)
elif echo "$query" | grep -qE "lent"; then
    THRESHOLD_MS="1000"  # default: > 1 secondo
fi

# IP sorgente
IP_FILTER=""
if echo "$query" | grep -qE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"; then
    IP_FILTER=$(echo "$query" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
fi

# Numero di righe per tail — richiede "ultime/ultimi/prime/primi N righe/record/log"
# per non confliggere con "ultime 2 ore" / "ultimi 30 minuti"
TAIL_N="50"
if echo "$query" | grep -qE "(ultim|prim)[ei] [0-9]+ *(rig[ah]|record|log|linee|lin)"; then
    TAIL_N=$(echo "$query" | grep -oE "(ultim|prim)[ei] [0-9]+" | grep -oE "[0-9]+" | head -1)
elif echo "$query" | grep -qE "(mostra|dammi|visualizza) [0-9]+ *(rig[ah]|record|log|linee)"; then
    TAIL_N=$(echo "$query" | grep -oE "[0-9]+" | head -1)
fi

# Direzione di lettura per tail_log/tail_named_log: "prime/iniziali/all'inizio"
# → head, altrimenti tail (default). Stesso schema di TAIL_N: un parametro, non
# una nuova classe — "prime" vs "ultime" è la direzione, non il tipo di analisi.
# `prim[aeio]` e non `prim[ei]`: "prima riga" e "primo record" — le due forme
# singolari più naturali in italiano — non matchavano, quindi LOG_ORDER restava
# "tail" e il bot mostrava l'ULTIMA riga a chi aveva chiesto la prima. Silenzioso
# per definizione: l'output è ben formato, solo preso dal capo sbagliato del file.
# Trovato il 2026-08-20 con una passata sistematica sulle classi di caratteri
# flesse, dopo che lo stesso difetto era emerso due volte nella stessa sessione
# (`ultim[aei]` in utils-time.sh, `applicativ[oa]?` qui sotto): non è un caso
# isolato ma una forma ricorrente, e va cercata invece che attesa.
#
# "primavera" resta escluso dal `\b` finale (dopo la 'a' segue 'v', nessun
# confine) — il falso positivo era già presidiato da un test.
#
# Il ramo negativo esiste perché in italiano "prima" è anche TEMPORALE ("prima di
# mezzogiorno"), non posizionale: senza, una finestra temporale espressa con
# "prima di" farebbe leggere il file dal capo sbagliato.
LOG_ORDER="tail"
if echo "$query" | grep -qE "\biniziali\b|all.inizio"; then
    LOG_ORDER="head"
elif echo "$query" | grep -qE "\bprim[aeio]\b" \
     && ! echo "$query" | grep -qE "\bprima (di|del|dell|delle|dei|degli|che)\b"; then
    LOG_ORDER="head"
fi

# Livello log per grep_named_log: "problemi/anomalie" → WARN+ (ERROR+WARN),
# "errori/error" → ERROR, "warning/warn" → WARN, "info" → INFO, "tutti/all" → ALL
#
# LEVEL_EXPLICIT distingue "l'utente ha chiesto un livello" da "ho applicato il
# default": senza questo flag i due casi sono indistinguibili, perché entrambi
# arrivano a dispatch.sh come LOG_LEVEL='ERROR'. Serve a SRCH-1 (ricerca
# testuale in un log nominato): quando la query porta un pattern e NON nomina un
# livello, l'intento è cercare in tutto il file, non solo fra gli errori.
# Stesso pattern di TIME_EXPLICIT e LOG_EXPLICIT in chatbot.sh — non
# persistente, si ricalcola a ogni query.
LOG_LEVEL="ERROR"
LEVEL_EXPLICIT=0
if   echo "$query" | grep -qE "\bwarn(ing)?\b|\bavviso\b"; then
    LOG_LEVEL="WARN"; LEVEL_EXPLICIT=1
elif echo "$query" | grep -qE "\binfo\b|\binformazioni\b"; then
    LOG_LEVEL="INFO"; LEVEL_EXPLICIT=1
elif echo "$query" | grep -qE "\btutti?\b.*livell|\ball\b.*level|ogni.livell"; then
    LOG_LEVEL="ALL"; LEVEL_EXPLICIT=1
elif echo "$query" | grep -qE "\bprobl[ei]|anomal|cosa.non.va|non.va\b|incident|stran"; then
    LOG_LEVEL="WARN+"; LEVEL_EXPLICIT=1
elif echo "$query" | grep -qE "\berror[ei]?\b|\bERROR\b"; then
    # "errori nel cc.log" — il livello ERROR è chiesto, non ereditato dal
    # default: senza questo ramo una query esplicita sugli errori con anche un
    # pattern verrebbe allargata a tutti i livelli.
    LEVEL_EXPLICIT=1
fi

# Nome log applicativo specifico — la lista viene dal profilo (entities.conf: APP_LOG_NAMES).
#
# La guardia `-f` resta, ma NON perché il file sia opzionale: è obbligatorio e i
# due chiamanti a monte lo verificano con un messaggio parlante (chatbot.sh sui
# file del profilo, normalize-query.sh in testa). Qui il test evita solo che
# un'invocazione diretta senza PROFILE_DIR — come fanno alcuni test unitari —
# fallisca su `source` invece di procedere con APP_LOG_NAMES vuoto, che per questo
# script è un degrado accettabile (nessun NAMED_LOG risolto, non un errore).
# Prima questa guardia era la ragione per cui il file *sembrava* opzionale in due
# punti su tre (ENTCONF-1).
NAMED_LOG=""
if [[ -n "${PROFILE_DIR:-}" && -f "$PROFILE_DIR/entities.conf" ]]; then
    source "$PROFILE_DIR/entities.conf"
fi
# Longest-match: ordina per lunghezza decrescente prima di iterare, come fa
# normalize-query.sh per gli alias APP. Senza questo "ccJBatch.log" veniva risolto
# come "cc" (il pattern è `\bcc` senza ancora finale, e "cc" viene prima nel file):
# il classificatore instradava correttamente su tail_named_log ma dispatch.sh
# apriva cc.log invece di ccJBatch.log. Colpiva ccJBatch e ccCanaliz.
_sorted_log_names=$(for _n in "${APP_LOG_NAMES[@]:-}"; do
                        [[ -n "$_n" ]] && printf '%d %s\n' "${#_n}" "$_n"
                    done | sort -k1,1rn -k2,2 | awk '{print $2}')
for _log_name in $_sorted_log_names; do
    [[ -z "$_log_name" ]] && continue
    if echo "$query" | grep -qiE "\b${_log_name}"; then
        NAMED_LOG="$_log_name"
        break
    fi
done

# Fallback: la query nomina un "<token>.log" che non è nella whitelist.
# APP_LOG_NAMES è una lista di ALIAS noti (scorciatoie che l'utente può usare senza
# estensione, es. "errori nel cc"), non di log AMMESSI: sul nodo di produzione i log
# sono 28 e la whitelist ne elenca 16, quindi limitarsi ad essa renderebbe
# irraggiungibili 12 log reali — fra cui concurrentDataChangeExceptionLog,
# inbound_mq_messages, controllo_pagamenti. La risoluzione del path la fa `find` in
# dispatch.sh, che sa già cosa c'è sul disco.
#
# Si usa il case ORIGINALE ($1, non $query lowercase): i nomi reali contengono
# maiuscole (ccJBatch, JF4U_TRACKING, concurrentDataChangeExceptionLog) e finiscono
# in `find -name`, che è case-sensitive.
#
# Esclusi i log di infrastruttura (basename da system.conf): hanno tool dedicati.
if [[ -z "$NAMED_LOG" ]]; then
    _fb=$(grep -oE "[A-Za-z0-9_.-]+\.log\b" <<< "$1" | head -1)
    if [[ -n "$_fb" ]]; then
        _fb_base="${_fb%.log}"
        _fb_ok=1
        # Il valore finisce in `find -name`: whitelist obbligatoria, non difensiva.
        [[ "$_fb_base" == *".."* ]] && _fb_ok=0
        [[ ! "$_fb_base" =~ ^[A-Za-z0-9_.-]+$ ]] && _fb_ok=0
        # Serve almeno un alfanumerico: "..log" passerebbe la whitelist con base "."
        # e "-.log" con base "-", che non sono nomi di log. Innocui per `find -name`
        # (che tratta il valore come pattern di nome, non come path) ma privi di senso.
        [[ ! "$_fb_base" =~ [A-Za-z0-9] ]] && _fb_ok=0
        _is_system_log_base "$_fb_base" && _fb_ok=0
        [[ "$_fb_ok" -eq 1 ]] && NAMED_LOG="$_fb_base"
    fi
fi

# Rilevatore tri-valore del log di sistema nominato (server/access/gc), un solo
# punto (principio 8 di CLAUDE.md): LOG_TYPE e SYSLOG_KIND sono entrambi derivati
# da qui, non due regex indipendenti che potrebbero divergere.
#
# Bug reale (2026-08-05, solo LOG_TYPE): la regex copriva solo l'ordine "log
# <parola>" (log applicativo, log jboss, log di sistema), mai l'ordine inverso
# "<parola> log" (server log, server.log) — nonostante il dataset di training
# labeled contenga entrambi gli ordini. Vale per tutti e tre i kind, non solo
# server: la stessa struttura di regex si applica a ciascuno.
# SERVER_LOG_BASE/ACCESS_LOG_BASE/GC_LOG_BASE vengono da system.conf — sono i
# nomi con cui gli utenti chiamano il file, non SERVER_LOG_FORMAT ("jboss"),
# che è la tecnologia sottostante e non un sinonimo digitato dall'utente.
# `applicativ[oaie]?` e non `applicativ[oa]?`: il plurale "log applicativi" — e il
# femminile "applicative" — non matchavano, quindi SYSLOG_KIND restava vuoto e con
# esso LOG_TYPE. Conseguenza: un tool che decide la sorgente da LOG_TYPE cadeva sul
# fallback access log pur avendo l'utente nominato il log applicativo. È la stessa
# classe di LOGSEL-1 (leggere il file sbagliato senza dirlo) e la stessa forma del
# difetto `ultim[aei]` in utils-time.sh: una classe di caratteri incompleta che
# copre alcune flessioni della parola e non altre.
_srv_words="server|applicativ[oaie]?|dell.applicaz\\w*|${SERVER_LOG_FORMAT:-server}"
_acc_words="access|accesso"
_gc_words="gc|garbage.collector|garbage.collection"
SYSLOG_KIND=""
if echo "$query" | grep -qiE "\blog[[:space:]]+(${_srv_words}|di[[:space:]]+sistema)\b|\b(${_srv_words})[.[:space:]]+log\b"; then
    SYSLOG_KIND="server"
elif echo "$query" | grep -qiE "\blog[[:space:]]+(${_acc_words})\b|\b(${_acc_words})[.[:space:]]+log\b"; then
    SYSLOG_KIND="access"
elif echo "$query" | grep -qiE "\blog[[:space:]]+(${_gc_words})\b|\b(${_gc_words})[.[:space:]]+log\b"; then
    SYSLOG_KIND="gc"
fi
# LOG_TYPE resta il binario storico per tail_log (TOOL_SOURCES[tail_log]="access|server",
# non include gc): server se il kind è server, altrimenti vuoto (fallback access,
# gestito da dispatch.sh). Derivato da SYSLOG_KIND, non un secondo rilevatore.
LOG_TYPE=""
[[ "$SYSLOG_KIND" == "server" ]] && LOG_TYPE="server"

_sq="${1,,}"  # query originale in minuscolo

# ─── Estrattore unico delle stringhe quotate, assegnate per FORMA ────────────
# Sostituisce due `sed` greedy-last indipendenti (bug reale: `.*` prende
# l'ULTIMA stringa quotata, non la prima — su `cerca "X" nel "*server*.log"`
# SEARCH_PATTERN diventava '*server*.log', cioè cercava il glob nel contenuto
# del file). Un solo estrattore raccoglie TUTTE le stringhe quotate nell'ordine
# in cui appaiono, poi assegna la prima glob-like a NAMED_LOG_GLOB e la prima
# non-glob-like a SEARCH_PATTERN — stessa regola di disambiguazione per forma
# di normalize-query.sh (<LOGFILE> vs <PATTERN>, QUOTE-1). Mutuamente esclusive:
# su `cerca "*errore*.log"` (un solo span, glob-like) NAMED_LOG_GLOB lo prende e
# SEARCH_PATTERN resta vuoto — prima entrambe si popolavano con lo stesso testo,
# e dispatch.sh finiva per cercare il testo del glob dentro il file (bug
# collaterale, corretto come effetto di questa unificazione).
_quoted_spans=()
while IFS= read -r _span; do
    [[ -n "$_span" ]] && _quoted_spans+=("$_span")
done < <(echo "$1" | grep -oE '"[^"]*"' | sed -e 's/^"//' -e 's/"$//')
if [[ ${#_quoted_spans[@]} -eq 0 ]]; then
    while IFS= read -r _span; do
        [[ -n "$_span" ]] && _quoted_spans+=("$_span")
    done < <(echo "$1" | grep -oE "'[^']*'" | sed -e "s/^'//" -e "s/'$//")
fi

# Escape hatch per log fuori da APP_LOG_NAMES: glob tra virgolette.
#   ultime 10 righe di "*c1nssprod*.log"
# Discriminato dalla *forma* del contenuto: deve contenere '*' e terminare in
# '.log' (anche di file ruotati: sul nodo la rotazione produce
# `prod1nsse-cc.log-2026-07-26-1785016801.gz`, dove ".log" sta IN MEZZO — la
# forma canonica resta `"*-cc.log"`, dispatch.sh la espande alle rotazioni via
# select_log_files). Il valore finisce in `find -name` (dispatch.sh): è input
# non fidato, quindi la whitelist di caratteri è obbligatoria, non difensiva.
# '/' e '..' permetterebbero di uscire dalla directory dei log nonostante
# -maxdepth 1.
NAMED_LOG_GLOB=""
for _span in "${_quoted_spans[@]}"; do
    if [[ -n "$NAMED_LOG_GLOB" ]]; then break; fi
    if [[ "$_span" == *'*'* && "$_span" =~ \.log([-.][A-Za-z0-9_.*-]*)?$ ]]; then
        if [[ "$_span" == *".."* ]]; then
            echo "[WARN] param-extract: glob rifiutato (contiene '..'): $_span" >&2
        elif [[ ! "$_span" =~ ^[A-Za-z0-9_.*-]+$ ]]; then
            echo "[WARN] param-extract: glob rifiutato (caratteri non ammessi, consentiti [A-Za-z0-9_.*-]): $_span" >&2
        else
            NAMED_LOG_GLOB="$_span"
        fi
    fi
done

# Pattern di ricerca per search_all_logs/grep_named_log.
# La stringa da cercare deve essere tra virgolette doppie o singole:
#   cerca "NullPointerException" in produzione
#   trova 'claim 1-8101-2026-0473954' nel nodo 5
# Solo se il trigger è presente (a differenza di NAMED_LOG_GLOB, che è un
# escape hatch indipendente dall'intento di ricerca). Trigger presente ma
# nessuno span non-glob-like → __MISSING__ (messaggio nei tool).
SEARCH_PATTERN=""
if echo "$_sq" | grep -qiE "\bcerca\b|\btrova\b|\bdove.appare\b|\bdove.si.trova\b|in.quali.log|cerca.ovunque|cerca.in.tutti"; then
    for _span in "${_quoted_spans[@]}"; do
        if [[ -n "$SEARCH_PATTERN" ]]; then break; fi
        if [[ "$_span" != *'*'* || ! "$_span" =~ \.log([-.][A-Za-z0-9_.*-]*)?$ ]]; then
            SEARCH_PATTERN="$_span"
        fi
    done
    [[ -z "$SEARCH_PATTERN" ]] && SEARCH_PATTERN="__MISSING__"
fi

# UNRESOLVED_LOG rimosso (2026-08-04): segnalava un ".log" che non riuscivamo a
# risolvere, per avvisare l'utente prima che il tool leggesse un altro file. Da quando
# NAMED_LOG risolve QUALSIASI "<token>.log" (vedi il fallback sopra) restava vuoto in
# ogni caso reale — e il suo lavoro lo fa meglio suggest_available_logs() in
# dispatch.sh, che elenca i log effettivamente presenti sul nodo invece degli alias
# di entities.conf: informazione più accurata, perché la whitelist può divergere dal
# disco ("plugin" in configurazione contro "plugins" reale).

echo "TIME_FROM='${TIME_FROM}'"
echo "TIME_TO='${TIME_TO}'"
echo "DATE_FILTER='${DATE_FILTER}'"
echo "TIME_ONLY_QUERY='${TIME_ONLY_QUERY:-0}'"
echo "STATUS_CODE='${STATUS_CODE}'"
echo "THRESHOLD_MS='${THRESHOLD_MS}'"
echo "IP_FILTER='${IP_FILTER}'"
echo "TAIL_N='${TAIL_N}'"
echo "LOG_ORDER='${LOG_ORDER}'"
echo "NAMED_LOG='${NAMED_LOG}'"
echo "LOG_LEVEL='${LOG_LEVEL}'"
echo "LEVEL_EXPLICIT='${LEVEL_EXPLICIT}'"
echo "LOG_TYPE='${LOG_TYPE}'"
echo "SYSLOG_KIND='${SYSLOG_KIND}'"
echo "SEARCH_PATTERN='${SEARCH_PATTERN}'"
echo "NAMED_LOG_GLOB='${NAMED_LOG_GLOB}'"
# Entità normalizzate — arrivano da normalize-query.sh (unica fonte di verità).
# param-extract le riemette invariate così il chiamante può fare un unico eval.
echo "DETECTED_APP='${DETECTED_APP:-}'"
echo "DETECTED_ENV='${DETECTED_ENV:-}'"
echo "DETECTED_NODE='${DETECTED_NODE:-}'"
