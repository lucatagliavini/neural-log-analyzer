#!/bin/bash
#
# Converte una query testuale in un vettore binario di 50 feature.
# Uscita: una riga di 50 valori 0/1 separati da spazio.
#
# Uso: ./lib/query-to-features.sh "mostrami gli errori 500"
#

query="${1,,}"  # lowercase

# Ogni entry è un pattern grep (ERE) che matcha la keyword e le sue varianti morfologiche.
# Gruppi tematici: status, tempo, distribuzione, performance, server, gc, endpoint, ip, visuale, misc.
VOCAB=(
    # [0-9]  Status HTTP
    "errore|errori"         # 0
    "errore|errori"         # 1  (duplicato intenzionale — peso doppio per errore/errori)
    "500"                   # 2
    "400"                   # 3
    "404"                   # 4
    "503"                   # 5
    "5xx"                   # 6
    "4xx"                   # 7
    "status|stato"          # 8
    "http"                  # 9
    # [10-19] Tempo / finestre temporali
    "ora |ore |ora$"        # 10
    "ora |ore |ora$"        # 11 (peso doppio)
    "minut"                 # 12
    "minut"                 # 13
    "giorn"                 # 14
    "ieri"                  # 15
    "oggi"                  # 16
    "ultim"                 # 17
    "ultim"                 # 18 (peso doppio — molto discriminante)
    "dall[ea]"              # 19
    # [20-29] Distribuzione / aggregazione
    "distribuzion"          # 20
    "quant[eo]|quanti"      # 21
    "conta|contami"         # 22
    "total[ei]"             # 23
    "raggrupp"              # 24
    "frequen"               # 25
    "per "                  # 26
    "list[ae]"              # 27
    "tutt[ie]"              # 28
    "numero|numer"          # 29
    # [30-34] Performance / latenza
    "lent[oaie]|slow"       # 30
    "lent[oaie]|slow"       # 31 (peso doppio)
    "latenz"                # 32
    "\bms\b|millisec"       # 33
    "prestazion|performanc" # 34
    # [35-39] Server log
    "warn"                  # 35
    "exception|eccezione"   # 36
    "stack.trace|stacktrace" # 37
    "crash|fatal"            # 38
    "log.applicat|server.log" # 39
    # [40-42] GC / JVM
    "gc|garbage"            # 40
    "heap"                  # 41
    "memori[ae]|jvm"        # 42
    # [43-45] Endpoint / URL
    "endpoint"              # 43
    "url|path"              # 44
    "api"                   # 45
    # [46-47] IP / client
    "\bip\b"                # 46
    "client|indirizz"       # 47
    # [48-49] Visualizzazione
    "mostr|visualizz|dammi" # 48
    "recent|ultim"          # 49
    # [50-53] Errori applicativi (filter_app_errors)
    "applicat"              # 50
    "nascost|intern"        # 51
    "root.cause|business"   # 52
    "loggat|loggati"        # 53
    # [54-57] Discriminatori aggiuntivi
    "servizi|servizio"      # 54  service_times vs slow_requests
    "soa\b"                 # 55  service_times (peso doppio per SOA)
    "rig[ah]|tail\b"        # 56  tail_log (righe di log, non volume)
    "volum|picco|andament"  # 57  traffic_volume vs tail_log
)

features=()
for pattern in "${VOCAB[@]}"; do
    if echo "$query" | grep -qE "$pattern" 2>/dev/null; then
        features+=("1")
    else
        features+=("0")
    fi
done

echo "${features[*]}"
