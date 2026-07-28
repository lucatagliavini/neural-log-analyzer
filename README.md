# neural-log-analyzer

Chatbot a riga di comando che risponde a query in linguaggio naturale sui log
JBoss/Undertow/Guidewire. Classifica l'intent della query con una rete neurale
(implementata in AWK) e dispatcha il tool di analisi corretto.

```
$ ./chatbot.sh --profile profiles/liquido --env coll
> quanti errori 500 nelle ultime 2 ore?
> mostrami i servizi più lenti di stamattina
> ultime 30 righe del cc.log
```

## Avvio rapido

```bash
# 1. Inizializza il modello (una volta sola)
./setup.sh --profile profiles/liquido

# 2. Addestra il classificatore
./train.sh --profile profiles/liquido

# 3. Avvia il chatbot (modalità interattiva)
./chatbot.sh --profile profiles/liquido --env coll

# Oppure in modalità non interattiva
./chatbot.sh --profile profiles/liquido --env prod --query "errori 500 delle ultime 3 ore"
```

## Opzioni chatbot.sh

| Opzione | Descrizione |
|---|---|
| `--profile <dir>` | Profilo configurazione (obbligatorio). Es: `profiles/liquido` |
| `--env <nome>` | Ambiente log: `test`, `euro`, `coll`, `inte`, `cert`, `prod` |
| `--node <n>` | Numero nodo (default: `01`) |
| `--app <nome>` | Applicazione: `ClaimCenter`, `ContactManager` (default da profilo) |
| `--query <testo>` | Modalità non interattiva: esegue la query e termina |
| `--base-dir <path>` | Override path base log (default da `system.conf`) |

In modalità interattiva `--env` è opzionale: il bot lo deduce dalla query
se viene menzionato l'ambiente (es: *"errori in produzione"*).

## Tool disponibili

Il modello classifica la query e attiva uno o più dei seguenti tool:

| Tool | Cosa fa |
|---|---|
| `count_status` | Conta richieste HTTP per codice di stato |
| `distribute_status` | Distribuisce errori per endpoint, IP o fascia oraria |
| `slow_requests` | Richieste con tempo di risposta sopra soglia |
| `traffic_volume` | Volume di traffico per finestra temporale |
| `filter_errors` | Righe ERROR/WARN dal server.log con classe e messaggio |
| `service_times` | Tempi di esecuzione servizi SOA dal server.log |
| `gc_stats` | Statistiche GC: pause, heap usage, frequenza |
| `correlate_gc_slow` | Correlazione tra pause GC e richieste lente |
| `tail_log` | Ultime N righe di un file di log |
| `filter_ip` | Traffico filtrato per IP (o top-clients se IP non specificato) |
| `filter_app_errors` | Errori applicativi nel server.log (status 5xx e exception come INFO) |
| `tail_named_log` | Ultime N righe di un log Guidewire specifico (cc.log, api.log, …) |
| `grep_named_log` | Filtra un log Guidewire per livello ERROR/WARN/INFO o pattern testuale |

## Struttura del progetto

```
neural-log-analyzer/
├── chatbot.sh          # Punto d'ingresso — REPL interattivo e modalità --query
├── setup.sh            # Inizializza il modello per un profilo
├── train.sh            # Addestra il classificatore di intent
├── build-dataset.sh    # Genera il dataset di training dai labeled examples
├── profiles/
│   └── liquido/
│       ├── system.conf     # Path log, timezone, ambienti disponibili
│       ├── domain.conf     # Tool, topologia rete, soglia confidenza
│       ├── vocab.sh        # Vocabolario NLP (unigram + bigram)
│       ├── examples.sh     # Generatori di esempi specifici del profilo
│       └── dataset/        # queries_labeled.txt → queries.txt (generato)
├── lib/
│   ├── infer.sh            # Feature vector → rete → nomi tool attivati
│   ├── dispatch.sh         # Tool name → invocazione AWK
│   ├── param-extract.sh    # Estrae TIME_FROM/TO, STATUS_CODE, THRESHOLD_MS, …
│   ├── query-to-features.sh# Query testuale → vettore numerico
│   ├── context-extract.sh  # Estrae env/nodo/app dalla query
│   ├── resolve-logs.sh     # (env, nodo, app) → path file di log
│   ├── utils-time.sh       # NL temporale italiano → range ISO8601
│   ├── gen-examples.sh     # Genera esempi labeled via espansione sinonimi
│   └── tools/              # 13 tool AWK di analisi log
└── example-logs/           # Log di esempio per test (non inclusi nel repo)
```

## Flusso train → uso

```
queries_labeled.txt
      │
      ▼  build-dataset.sh
  queries.txt  (74 feature × N esempi)
      │
      ▼  train.sh  (adam, LR=0.01, patience=100)
  models/intent_classifier/
      │
      ▼  chatbot.sh
  query → feature vector → inferenza → tool → output
```

## Aggiungere esempi al dataset

```bash
# Genera esempi bilanciati per tutti i tool (stampa su stdout)
./lib/gen-examples.sh all --target 60 --profile profiles/liquido

# Applica direttamente al dataset
./lib/gen-examples.sh all --target 60 --apply --profile profiles/liquido

# Solo per un tool specifico
./lib/gen-examples.sh filter_errors --target 60 --apply --profile profiles/liquido

# Dopo aver modificato il dataset, rigenera e riaddestra
./build-dataset.sh --profile profiles/liquido
./train.sh --profile profiles/liquido
```

## Configurazione profilo

**`system.conf`** — modificabile senza riaddestrare:
- `LOG_BASE_DIR` — path root dei log
- `LOG_TZ` — timezone server log (es: `Europe/Rome`)
- `DEFAULT_APP`, `AVAILABLE_APPS`
- `NODE_PATTERN`, `APP_SUBPATH`, `GUIDEWIRE_SUBPATH`

**`domain.conf`** — modifiche richiedono `./train.sh`:
- `TOOL_THRESHOLD` — soglia confidenza per attivare un tool (default: 0.25)
- `MODEL_TOPOLOGY` — dimensioni rete (es: `74,48,13`)
- `TOOL_NAMES`, `TOOL_DESC`

**`vocab.sh`** — modifiche richiedono `./build-dataset.sh` + `./train.sh`:
- `UNIGRAMS` — pattern regex con peso (es: `"errore :: 2"`)
- `BIGRAMS` — coppie co-presenza (es: `"exception :: ultim"`)
- `NUM_FEATURES` — totale feature (deve essere coerente con `MODEL_TOPOLOGY`)

## Dipendenze

- `gawk` — richiesto (usato da tutti i tool AWK e dalla rete neurale)
- `bash` ≥ 4
- `gunzip` — per lettura trasparente di log `.gz`
