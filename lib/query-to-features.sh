#!/bin/bash
#
# Converte una query testuale in un vettore di feature numerico.
# Uscita: una riga di NUM_FEATURES valori separati da spazio.
#
# Uso: ./lib/query-to-features.sh "mostrami gli errori 500"
#
# Struttura del vettore:
#   [0..56]  Unigram — presenza/peso di keyword nel testo (0/1/2)
#            peso=2 per keyword molto discriminanti (valore 2 anziché 1)
#   [57..61] Bigram  — co-presenza di due pattern nella stessa query (0/1)
#            Ogni bigram disambigua una coppia di classi che condividono unigram

query="${1,,}"  # lowercase

# ─── UNIGRAM ─────────────────────────────────────────────────────────────────
# Ogni entry: "pattern ERE :: peso"
# peso=1 → feature singola; peso=2 → feature con doppio valore (più discriminante)
# Separatore :: non può apparire in un pattern ERE.
#
# Gruppi tematici: status, tempo, distribuzione, performance, server, gc,
#                  endpoint, ip, visuale, errori-app, discriminatori di classe,
#                  colloquiale/informale.

UNIGRAMS=(
    # [0-8]  Status HTTP
    "errore|errori             :: 2"   # 0  peso 2: keyword molto discriminante
    "500                       :: 1"   # 1
    "400                       :: 1"   # 2
    "404                       :: 1"   # 3
    "503                       :: 1"   # 4
    "5xx                       :: 1"   # 5
    "4xx                       :: 1"   # 6
    "status|stato              :: 1"   # 7
    "http                      :: 1"   # 8
    # [9-17] Tempo / finestre temporali esplicite
    "ora |ore |ora$            :: 2"   # 9  peso 2: forte segnale temporale
    "minut                     :: 2"   # 10 peso 2
    "giorn                     :: 1"   # 11
    "ieri                      :: 1"   # 12
    "oggi                      :: 1"   # 13
    "ultim                     :: 2"   # 14 peso 2: molto discriminante
    "dall[ea]                  :: 1"   # 15
    "recent                    :: 1"   # 16
    # [17-19] Tempo colloquiale — Leva B
    "stamatt|stanott           :: 1"   # 17  "stamattina", "stanotte"
    "questa.matt|questa.sera   :: 1"   # 18  "questa mattina/sera"
    "poco.fa|adesso\b          :: 1"   # 19  "poco fa", "adesso"
    # [20-28] Distribuzione / aggregazione
    "distribuzion              :: 1"   # 20
    "quant[eo]|quanti          :: 1"   # 21
    "conta|contami             :: 1"   # 22
    "total[ei]                 :: 1"   # 23
    "raggrupp                  :: 1"   # 24
    "frequen                   :: 1"   # 25
    "per                       :: 1"   # 26
    "list[ae]                  :: 1"   # 27
    "tutt[ie]                  :: 1"   # 28
    "numero|numer              :: 1"   # 29
    # [30-34] Performance / latenza
    "lent[oaie]|slow           :: 2"   # 30 peso 2
    "latenz                    :: 1"   # 31
    "\bms\b|millisec           :: 1"   # 32
    "prestazion|performanc     :: 1"   # 33
    # [34-38] Server log
    "warn                      :: 1"   # 34
    "exception|eccezion        :: 1"   # 35
    "stack.trace|stacktrace    :: 1"   # 36
    "crash|fatal               :: 1"   # 37
    "log.applicat|server.log   :: 1"   # 38
    # [39-41] GC / JVM
    "gc|garbage                :: 1"   # 39
    "heap                      :: 1"   # 40
    "memori[ae]|jvm            :: 1"   # 41
    # [42-44] Endpoint / URL
    "endpoint                  :: 1"   # 42
    "url|path                  :: 1"   # 43
    "api                       :: 1"   # 44
    # [45-46] IP / client
    "\bip\b                    :: 1"   # 45
    "client|indirizz           :: 1"   # 46
    # [47-48] Visualizzazione
    "mostr|visualizz|dammi     :: 1"   # 47
    "recent|ultim              :: 1"   # 48
    # [49-52] Errori applicativi — discriminano filter_app_errors
    "applicat                  :: 1"   # 49
    "nascost|intern            :: 1"   # 50
    "root.cause|business       :: 1"   # 51
    "loggat|loggati            :: 1"   # 52
    # [53-56] Discriminatori di classe
    "servizi|servizio|backend|web.?service :: 1"   # 53  service_times vs slow_requests
    "soa\b                     :: 1"   # 54  service_times (segnale forte esclusivo)
    "rig[ah]|tail\b            :: 1"   # 55  tail_log vs traffic_volume
    "volum|picco|andament      :: 1"   # 56  traffic_volume vs tail_log
    # [57-59] Colloquiale/informale — Leva A
    "rott[oa]|non.va\b|non.funz :: 1"  # 57  "ha rotto", "non va", "non funziona"
    "c.è.*problem|qualcosa.*stran :: 1" # 58  "c'è qualcosa di strano", "c'è un problema"
    "vediamo|un.occhiat         :: 1"  # 59  "vediamo i 500", "dammi un'occhiata"
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
# Formato: "patternA :: patternB"
# Valore 1 se ENTRAMBI i pattern matchano la query, 0 altrimenti.
# Ogni bigram disambigua una coppia di classi che condividono gli stessi unigram.

BIGRAMS=(
    # [60] exception + tempo → filter_errors (non traffic_volume o tail_log)
    "exception|eccezion|warn      :: ora |ore |ultim|recent|stamatt|stanott"
    # [61] lento + servizi/backend → service_times (non slow_requests) — Leva C
    "lent[oaie]|slow|latenz       :: servizi|servizio|soa\b|backend|web.?service"
    # [62] volume/andamento + tempo → traffic_volume (non tail_log)
    "volum|andament|picco         :: ora |ore |ultim|minut|giorn"
    # [63] righe/tail + recente → tail_log (non traffic_volume)
    "rig[ah]|tail\b               :: ultim|recent|recenti"
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
