#!/bin/bash
#
# vocab.sh — vocabolario NLP per il profilo "usnext".
# Basato su liquido, rimuove le 8 feature Guidewire (60-67) e riduce
# NUM_FEATURES a 64 (60 unigram + 4 bigram).
#
# Modificare questo file RICHIEDE rebuild del dataset e riaddestramento.
#

NUM_FEATURES=64

# ─── UNIGRAM ─────────────────────────────────────────────────────────────────
UNIGRAMS=(
    # [0-8]  Status HTTP
    "errore|errori             :: 2"
    "500                       :: 1"
    "400                       :: 1"
    "404                       :: 1"
    "503                       :: 1"
    "5xx                       :: 1"
    "4xx                       :: 1"
    "status|stato              :: 1"
    "http                      :: 1"
    # [9-16] Tempo / finestre temporali
    "ora |ore |ora$            :: 2"
    "minut                     :: 2"
    "giorn                     :: 1"
    "ieri                      :: 1"
    "oggi                      :: 1"
    "ultim                     :: 2"
    "dall[ea]                  :: 1"
    "recent                    :: 1"
    # [17-19] Tempo colloquiale
    "stamatt|stanott           :: 1"
    "questa.matt|questa.sera   :: 1"
    "poco.fa|adesso\b          :: 1"
    # [20-29] Distribuzione / aggregazione
    "distribuzion              :: 1"
    "quant[eo]|quanti          :: 1"
    "conta|contami             :: 1"
    "total[ei]                 :: 1"
    "raggrupp                  :: 1"
    "frequen                   :: 1"
    "per                       :: 1"
    "list[ae]                  :: 1"
    "tutt[ie]                  :: 1"
    "numero|numer              :: 1"
    # [30-33] Performance / latenza
    "lent[oaie]|slow           :: 2"
    "latenz                    :: 1"
    "\bms\b|millisec           :: 1"
    "prestazion|performanc     :: 1"
    # [34-38] Server log
    "warn                      :: 1"
    "exception|eccezion        :: 1"
    "stack.trace|stacktrace    :: 1"
    "crash|fatal               :: 1"
    "log.applicat|server.log   :: 1"
    # [39-41] GC / JVM
    "gc|garbage                :: 1"
    "heap                      :: 1"
    "memori[ae]|jvm            :: 1"
    # [42-44] Endpoint / URL
    "endpoint                  :: 1"
    "url|path                  :: 1"
    "api                       :: 1"
    # [45-46] IP / client
    "\bip\b                    :: 1"
    "client|indirizz           :: 1"
    # [47-48] Visualizzazione
    "mostr|visualizz|dammi     :: 1"
    "recent|ultim              :: 1"
    # [49-52] Errori applicativi
    "applicat                  :: 1"
    "nascost|intern            :: 1"
    "root.cause|business       :: 1"
    "loggat|loggati            :: 1"
    # [53-56] Discriminatori di classe
    "servizi|servizio|backend|web.?service :: 1"
    "soa\b                     :: 1"
    "rig[ah]|tail\b            :: 1"
    "volum|picco|andament      :: 1"
    # [57-59] Colloquiale/informale
    "rott[oa]|non.va\b|non.funz :: 1"
    "c.è.*problem|qualcosa.*stran :: 1"
    "vediamo|un.occhiat         :: 1"
    # [60-63] Applicazioni Pass* specifiche di usnext — discriminano contexto app
    "passinsurance|pass.insur   :: 2"
    "passportal|portal.banca    :: 2"
    "passbe|beppe\b|ppevo       :: 2"
    "pass\b                     :: 1"
)

# ─── BIGRAM (co-presenza) ─────────────────────────────────────────────────────
BIGRAMS=(
    # [64] exception + tempo → filter_errors
    "exception|eccezion|warn      :: ora |ore |ultim|recent|stamatt|stanott"
    # [65] lento + servizi → service_times (non slow_requests)
    "lent[oaie]|slow|latenz       :: servizi|servizio|soa\b|backend|web.?service"
    # [66] volume + tempo → traffic_volume (non tail_log)
    "volum|andament|picco         :: ora |ore |ultim|minut|giorn"
    # [67] righe/tail + recente → tail_log (non traffic_volume)
    "rig[ah]|tail\b               :: ultim|recent|recenti"
)
