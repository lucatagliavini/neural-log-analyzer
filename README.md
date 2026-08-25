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
| `--time-from <ISO>` | Inizio finestra temporale (`YYYY-MM-DDTHH:MM`, senza secondi) |
| `--time-to <ISO>` | Fine finestra temporale (stesso formato) |
| `--named-log <nome>` | Log nominato attivo (senza estensione `.log`) |

In modalità interattiva `--env` è opzionale: il bot lo deduce dalla query
se viene menzionato l'ambiente (es: *"errori in produzione"*).

In modalità `--query`, un tempo o un log nominati nel testo della query hanno
precedenza sui flag. Il contesto risolto viene stampato su stdout come riga
`CONTEXT env=... node=... app=... named_log=... time_from=... time_to=...`
(greppabile su `^CONTEXT`): uno strumento esterno può leggerla e ricostruire
i flag per la chiamata successiva, così il contesto sopravvive fra
un'invocazione e l'altra — cosa che `--query` da sola non fa (CTX-4).

## Tool disponibili

Il modello classifica la query e attiva uno o più dei seguenti tool:

| Tool | Cosa fa |
|---|---|
| `count_status` | Conta richieste HTTP per codice di stato |
| `distribute_status` | Distribuisce errori per endpoint, IP o fascia oraria |
| `slow_requests` | Richieste con tempo di risposta sopra soglia |
| `traffic_volume` | Volume di traffico per finestra temporale |
| `filter_errors` | Righe ERROR/WARN dal server.log con classe e messaggio |
| `service_times` | Tempi di esecuzione servizi SOA per nome servizio, dall'access log |
| `gc_stats` | Statistiche GC: pause, heap usage, frequenza |
| `correlate_gc_slow` | Correlazione tra pause GC e richieste lente |
| `tail_log` | Ultime N righe di un file di log |
| `filter_ip` | Traffico filtrato per IP (o top-clients se IP non specificato) |
| `filter_app_errors` | Errori applicativi nel server.log (status 5xx e exception come INFO) |
| `tail_named_log` | Ultime N righe di un log applicativo custom specifico (cc.log, api.log, …) |
| `grep_named_log` | Filtra un log applicativo custom per livello ERROR/WARN/INFO o pattern testuale |
| `show_help` | Lista degli strumenti disponibili con esempi di utilizzo |
| `search_all_logs` | Cerca un pattern in tutti i log del nodo, di tutte le app presenti (con colonna APP) |
| `list_logs` | Elenca i log realmente presenti sul nodo attivo |

## Struttura del progetto

```
neural-log-analyzer/
├── chatbot.sh          # Punto d'ingresso — REPL interattivo e modalità --query
├── setup.sh            # Inizializza il modello per un profilo
├── train.sh            # Addestra il classificatore di intent
├── build-dataset.sh    # Genera il dataset di training dai labeled examples
├── nlp/                    # Capacità del bot, condivise da tutti i profili
│   ├── unigrams.txt        # Vocabolario: pattern con peso (zero nomi concreti)
│   ├── bigrams.txt         # Vocabolario: coppie di co-presenza
│   ├── tools.conf          # NUM_TOOLS, soglia, topologia, TOOL_NAMES
│   ├── dataset/            # queries_labeled.txt → queries.txt (generato)
│   └── models/             # Pesi della rete addestrata
├── profiles/               # Coordinate per cliente
│   └── liquido/
│       ├── system.conf     # Path log, ambienti, nodi, tecnologia
│       ├── entities.conf   # Alias APP/ENV/NODE (obbligatorio)
│       ├── domain.conf     # Descrizioni, esempi, soglie di severità
│       └── examples.sh     # Generatori di esempi (opzionale)
├── lib/
│   ├── infer.sh            # Feature vector → rete → nomi tool attivati
│   ├── dispatch.sh         # Tool name → invocazione AWK
│   ├── param-extract.sh    # Estrae TIME_FROM/TO, STATUS_CODE, THRESHOLD_MS, …
│   ├── query-to-features.sh# Query testuale → vettore numerico
│   ├── normalize-query.sh  # Normalizza entità (APP/ENV/NODE) → NORM_QUERY + DETECTED_*
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
- `NODE_PATTERN`, `APP_SUBPATH`, `CUSTOM_LOG_SUBPATH`

**`entities.conf`** — obbligatorio, non richiede riaddestramento:
- `ENTITY_APP`, `APP_CANONICAL` — alias delle applicazioni → `<APP>`
- `APP_LOG_NAMES` — nomi dei log applicativi custom
- `NODE_PATTERNS` — come l'utente nomina i nodi

**`domain.conf`** — solo ciò che nomina cose reali del cliente:
- `TOOL_DESC`, `TOOL_EXAMPLE`, `HELP_CATEGORIES` — le stringhe che l'utente legge
- soglie di severità (`GC_PAUSE_*`, `SVC_TIME_*`, …) — tarabili per ambiente

**`nlp/tools.conf`** (framework) — modifiche richiedono `./setup.sh` + `./train.sh`:
- `TOOL_THRESHOLD` — soglia confidenza per attivare un tool (default: 0.25)
- `MODEL_TOPOLOGY` — dimensioni rete, auto-calcolata da `NUM_FEATURES`
- `TOOL_NAMES` — l'ordine **è** l'indice del neurone di output nei pesi

**`nlp/unigrams.txt`/`nlp/bigrams.txt`** (framework) — modifiche richiedono
`./build-dataset.sh` + `./train.sh`:
- unigram: pattern regex con peso (es: `"errore :: 2"`)
- bigram: coppie di co-presenza (es: `"exception :: ultim"`)

Il vocabolario non contiene nomi di applicazioni o di log: il classificatore
riconosce la *forma* `<nome>.log` tramite i placeholder, non i nomi concreti —
così lo stesso modello vale per profili diversi.
- `NUM_FEATURES` — totale feature (deve essere coerente con `MODEL_TOPOLOGY`)

## Dipendenze

- `gawk` — richiesto (usato da tutti i tool AWK e dalla rete neurale)
- `bash` ≥ 4
- `gunzip` — per lettura trasparente di log `.gz`
