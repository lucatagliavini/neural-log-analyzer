#!/bin/bash
#
# Converte una query testuale in un vettore di feature numerico.
# Uscita: una riga di NUM_FEATURES valori separati da spazio.
#
# Uso: ./lib/query-to-features.sh "mostrami gli errori 500"
#
# Struttura del vettore:
#   [0..57]  Unigram — presenza di keyword nel testo (0/1), con pesi espliciti
#            per keyword molto discriminanti (valore 2 anziché 1)
#   [58..61] Bigram  — co-presenza di due pattern nella stessa query (0/1)
#            Ogni bigram disambigua una coppia di classi che condividono unigram

query="${1,,}"  # lowercase

# ─── UNIGRAM ─────────────────────────────────────────────────────────────────
# Ogni entry: "pattern ERE :: peso"
# peso=1 → feature singola; peso=2 → feature con doppio valore (più discriminante)
# Separatore :: non può apparire in un pattern ERE.
#
# Gruppi tematici: status, tempo, distribuzione, performance, server, gc,
#                  endpoint, ip, visuale, errori-app, discriminatori di classe.

UNIGRAMS=(
    # [0-9]  Status HTTP
    "errore|errori             :: 2"   # 0  peso 2: keyword molto discriminante
    "500                       :: 1"   # 1
    "400                       :: 1"   # 2
    "404                       :: 1"   # 3
    "503                       :: 1"   # 4
    "5xx                       :: 1"   # 5
    "4xx                       :: 1"   # 6
    "status|stato              :: 1"   # 7
    "http                      :: 1"   # 8
    # [9-17] Tempo / finestre temporali
    "ora |ore |ora$            :: 2"   # 9  peso 2: forte segnale temporale
    "minut                     :: 2"   # 10 peso 2
    "giorn                     :: 1"   # 11
    "ieri                      :: 1"   # 12
    "oggi                      :: 1"   # 13
    "ultim                     :: 2"   # 14 peso 2: molto discriminante
    "dall[ea]                  :: 1"   # 15
    "recent                    :: 1"   # 16
    # [17-25] Distribuzione / aggregazione
    "distribuzion              :: 1"   # 17
    "quant[eo]|quanti          :: 1"   # 18
    "conta|contami             :: 1"   # 19
    "total[ei]                 :: 1"   # 20
    "raggrupp                  :: 1"   # 21
    "frequen                   :: 1"   # 22
    "per                       :: 1"   # 23
    "list[ae]                  :: 1"   # 24
    "tutt[ie]                  :: 1"   # 25
    "numero|numer              :: 1"   # 26
    # [27-31] Performance / latenza
    "lent[oaie]|slow           :: 2"   # 27 peso 2
    "latenz                    :: 1"   # 28
    "\bms\b|millisec           :: 1"   # 29
    "prestazion|performanc     :: 1"   # 30
    # [31-35] Server log
    "warn                      :: 1"   # 31
    "exception|eccezion        :: 1"   # 32
    "stack.trace|stacktrace    :: 1"   # 33
    "crash|fatal               :: 1"   # 34
    "log.applicat|server.log   :: 1"   # 35
    # [36-38] GC / JVM
    "gc|garbage                :: 1"   # 36
    "heap                      :: 1"   # 37
    "memori[ae]|jvm            :: 1"   # 38
    # [39-41] Endpoint / URL
    "endpoint                  :: 1"   # 39
    "url|path                  :: 1"   # 40
    "api                       :: 1"   # 41
    # [42-43] IP / client
    "\bip\b                    :: 1"   # 42
    "client|indirizz           :: 1"   # 43
    # [44-45] Visualizzazione
    "mostr|visualizz|dammi     :: 1"   # 44
    "recent|ultim              :: 1"   # 45
    # [46-49] Errori applicativi — discriminano filter_app_errors
    "applicat                  :: 1"   # 46
    "nascost|intern            :: 1"   # 47
    "root.cause|business       :: 1"   # 48
    "loggat|loggati            :: 1"   # 49
    # [50-53] Discriminatori di classe — aggiunti per risolvere confusioni frequenti
    "servizi|servizio          :: 1"   # 50  service_times vs slow_requests
    "soa\b                     :: 1"   # 51  service_times (segnale forte esclusivo)
    "rig[ah]|tail\b            :: 1"   # 52  tail_log vs traffic_volume
    "volum|picco|andament      :: 1"   # 53  traffic_volume vs tail_log
)

features=()
for entry in "${UNIGRAMS[@]}"; do
    pattern="${entry%%::*}"
    weight="${entry##*::}"
    pattern="${pattern// /}"   # trim spazi
    weight="${weight// /}"
    if echo "$query" | grep -qE "$pattern" 2>/dev/null; then
        features+=("$weight")
    else
        features+=("0")
    fi
done

# ─── BIGRAM (co-presenza) ─────────────────────────────────────────────────────
# Formato: "patternA :: patternB :: commento"
# Valore 1 se ENTRAMBI i pattern matchano la query, 0 altrimenti.
# Ogni bigram disambigua una coppia di classi che condividono gli stessi unigram.

BIGRAMS=(
    # [54] exception + tempo → filter_errors (non traffic_volume o tail_log)
    "exception|eccezion|warn   :: ora |ore |ultim|recent"
    # [55] lento + servizi → service_times (non slow_requests)
    "lent[oaie]|slow|latenz    :: servizi|servizio|soa\b"
    # [56] volume/andamento + tempo → traffic_volume (non tail_log)
    "volum|andament|picco      :: ora |ore |ultim|minut|giorn"
    # [57] righe/tail + recente → tail_log (non traffic_volume)
    "rig[ah]|tail\b            :: ultim|recent|recenti"
)

for bigram in "${BIGRAMS[@]}"; do
    patA="${bigram%%::*}"
    patB="${bigram##*::}"
    patA="${patA// /}"
    patB="${patB// /}"
    if echo "$query" | grep -qE "$patA" 2>/dev/null && \
       echo "$query" | grep -qE "$patB" 2>/dev/null; then
        features+=("1")
    else
        features+=("0")
    fi
done

echo "${features[*]}"
