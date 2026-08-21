# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Approach
- Think before acting. Read existing files before writing code.
- Be concise in output but thorough in reasoning.
- Prefer editing over rewriting whole files.
- Do not re-read files you have already read unless the file may have changed.
- Test your code before declaring done.
- No sycophantic openers or closing fluff.
- Keep solutions simple and direct. No over-engineering.
- If unsure: say so. Never guess or invent file paths.
- User instructions always override this file.

## Session log

All'inizio di ogni sessione, leggere l'ultima sessione in `docs/sessions/` (file più
recente per data e progressivo) per recuperare lo stato del progetto, i pendenti e le
decisioni prese.

Al termine di ogni sessione, creare un nuovo file in `docs/sessions/` con nome
`YYYY-MM-DD-NN.md` (data odierna + progressivo a due cifre, es. `2026-08-03-01.md`) che
documenti: lavoro svolto, stato finale del modello, pendenti per la sessione successiva.

`BACKLOG.md` è la fonte di verità per il backlog — i pendenti nei session log vi fanno
riferimento, non lo duplicano.

## Project Overview

Chatbot a riga di comando che risponde a query in linguaggio naturale sui log
JBoss/Undertow/Guidewire. Classifica l'intent della query con una rete neurale e
dispatcha il tool di analisi AWK corretto.

**Dipendenza da neural-c:** questo repository dipende dal framework neurale in C
`../neural-c` (path relativo — le due cartelle devono restare sorelle). Gli script
`setup.sh`, `train.sh`, `lib/infer.sh`, `lib/infer-dry.sh` invocano
`../neural-c/neural-c.sh` (via `lib/nc-common.sh`) per `init`/`train`/`predict`. Unico
motore neurale del progetto (training e inferenza, x86_64 e ppc64le) — sostituisce
`neural-bash` e il backend PyTorch (`lib/train.py`), rimossi il 2026-08-18. Separato da
neural-bash il 2026-08-03 (storia preservata via `git subtree split`); remote `origin` su
GitHub (`lucatagliavini/neural-log-analyzer`).

## Common Commands

```bash
# Inizializza il modello per un profilo (una volta sola)
./setup.sh --profile profiles/liquido

# Genera/rigenera il dataset di training dai labeled examples
./build-dataset.sh --profile profiles/liquido

# Addestra il classificatore di intent
./train.sh --profile profiles/liquido

# Avvia il chatbot (modalità interattiva)
./chatbot.sh --profile profiles/liquido --env coll

# Modalità non interattiva
./chatbot.sh --profile profiles/liquido --env prod --query "errori 500 delle ultime 3 ore"

# Test suite
bash tests/run-tests.sh

# Gap nel vocabolario: lista unica ordinata per forza del candidato (poche classi
# prima, poi più esempi). Misura sul testo NORMALIZZATO, come le feature (GAPREP-1).
./gap-report.sh --profile profiles/liquido
./gap-report.sh --profile profiles/liquido --top 0     # tutti i candidati
./vocab-gap.sh  --profile profiles/liquido --porcelain # TSV per uso da script

# Analisi offline dei tempi di risposta (richiede QUERY_LOG_DIR impostato)
./perf-report.sh --profile profiles/liquido
./perf-report.sh --tool search_all_logs --slowest 20

# Deploy
./deploy.sh
```

**Opzioni chatbot.sh:** `--profile <dir>` (obbligatorio), `--env`, `--node`, `--app`,
`--query`, `--base-dir`.

## Architecture

### Flusso train → uso

```
queries_labeled.txt
      │  build-dataset.sh
      ▼
  queries.txt  (97 feature × 968 esempi)
      │  train.sh  (adam, neural-c, early stopping opzionale)
      ▼
  models/intent_classifier/  (97→48→15, sigmoid, Xavier)
      │  chatbot.sh
      ▼
  query → normalize-query.sh → query-to-features.sh → rete → tool attivati
```

### Backend Python (generazione dataset accelerata)

Solo per `build-dataset.sh`, non per il training — quello è interamente `neural-c` (vedi
sopra). `lib/train.py` (wrapper PyTorch) è stato **rimosso il 2026-08-18**: `neural-c` è
l'unico motore neurale, su tutte le architetture, incluso il server di produzione
ppc64le dove PyTorch non è disponibile.

- `lib/build_dataset.py` — rebuild dataset in-process, replica
  `normalize-query.sh` + `query-to-features.sh` in Python. Output bit-identico alla
  pipeline bash (verificato 968/968). Opzionale: senza `.venv`, `build-dataset.sh` cade
  sul ramo bash (più lento, stesso risultato).
- Interprete risolto da `lib/utils-python.sh` → `resolve_python()`, unico punto per tutto
  il repo: `NLA_PYTHON` → `.venv` → `python3` di sistema (VENVGATE-1). Il `.venv` è un
  override, non un requisito: `build_dataset.py` importa solo stdlib.

### Componenti principali

| File | Responsabilità |
|------|---------------|
| `chatbot.sh` | REPL interattivo e modalità `--query` |
| `setup.sh` | Inizializza il modello per un profilo (chiama `neural-c init`) |
| `train.sh` | Addestra il classificatore (chiama `neural-c train`) |
| `build-dataset.sh` | Genera il dataset di training dai labeled examples |
| `lib/nc-common.sh` | Wrapper condivisi verso `neural-c.sh` (`nc_predict`, gestione `project.conf`, init) |
| `lib/infer.sh` | Feature vector → rete (`neural-c predict`) → nomi tool attivati |
| `lib/dispatch.sh` | Routing tool name → invocazione AWK |
| `lib/normalize-query.sh` | Normalizza entità (APP/ENV/NODE) → `NORM_QUERY` + `DETECTED_*`, unica fonte di verità |
| `lib/query-to-features.sh` | Query testuale (normalizzata) → vettore numerico |
| `lib/param-extract.sh` | Estrae `TIME_FROM`, `TIME_TO`, `STATUS_CODE`, `THRESHOLD_MS`, ecc. |
| `lib/utils-time.sh` / `lib/utils-time.awk` | Range temporale in linguaggio naturale italiano → epoch/ISO8601 |
| `lib/resolve-logs.sh` | `(env, nodo, app)` → path file di log |
| `lib/gen-examples.sh` | Genera esempi labeled via espansione sinonimi |
| `lib/utils-colors.awk`, `lib/utils-jboss.awk`, `lib/utils-dedup.awk` | Utility AWK condivise, caricate con `-f` multipli da `dispatch.sh` |
| `lib/tools/` | 14 tool AWK di analisi log (vedi README per la lista completa) |

### Capacità nel framework, coordinate nel profilo

**Il criterio** (NLP-1, 2026-08-17): il profilo contiene **coordinate** — dove sono i
log, come si chiamano le cose, quale tecnologia — non **capacità**. Vocabolario,
dataset e modello descrivono come parla un utente italiano e cosa il bot sa fare:
non dipendono dal cliente, quindi vivono nel framework.

La prova che la collocazione precedente era sbagliata: montare il secondo profilo
(`usnext`) aveva richiesto tre symlink verso `liquido`.

#### `nlp/` — condiviso da tutti i profili

- **`unigrams.txt`/`bigrams.txt`** — vocabolario, pattern con peso. **Zero nomi
  concreti**: solo linguaggio naturale e i placeholder `<APP>`/`<LOGFILE>`/`<ENV>`/
  `<NODE>` (LOGF-3). Modifiche richiedono `./build-dataset.sh` + `./train.sh`.
- **`tools.conf`** — `NUM_TOOLS`, `TOOL_THRESHOLD`, `MODEL_TOPOLOGY` (auto-calcolata da
  `NUM_FEATURES`) e `TOOL_NAMES`. **L'ordine di `TOOL_NAMES` è il contratto**: è
  l'indice del neurone di output nei pesi condivisi, quindi sta qui e non nel profilo —
  duplicarlo significa che una divergenza produce misrouting **silenzioso**.
- **`dataset/`** — `queries_labeled.txt` → `queries.txt` (generato).
- **`report-stopwords.txt`** — parole funzionali italiane escluse dal **gap report**.
  **Non è vocabolario**: non tocca le feature, non influenza i pesi, e modificarlo non
  richiede `build-dataset.sh` né `train.sh`. Sta in `nlp/` perché è lingua italiana
  (stesso criterio del vocabolario), ma è l'unico artefatto qui che **non** entra nel
  calcolo di `NLP_CUSTOM`: un profilo che lo sovrascrive non ottiene pesi propri, perché
  non ha cambiato un input del modello (GAPREP-1).
- **`models/intent_classifier/`** — i pesi. Sono la **conseguenza deterministica** di
  vocabolario + dataset + iperparametri: se gli input sono condivisi, il modello lo è
  per costruzione (prova: i pesi dei due profili avevano md5 identico già prima di
  questo lavoro).

#### `profiles/<nome>/` — per cliente

- **`system.conf`** — path log, timezone, ambienti, basename dei log di sistema, quale
  tecnologia (`SERVER_LOG_FORMAT`, `ACCESS_LOG_FORMAT`). Modificabile senza riaddestrare.
- **`entities.conf`** — mappa alias APP/ENV/NODE, sinonimi, risoluzione inversa.
  Aggiungere un'applicazione richiede una riga qui, non un retrain. **Obbligatorio**:
  senza, non esiste la normalizzazione delle entità (ENTCONF-1).
- **`domain.conf`** — solo le stringhe che l'utente legge (`TOOL_DESC`,
  `TOOL_EXAMPLE`, `HELP_CATEGORIES`, `SOURCE_CATEGORY`/`SOURCE_LABEL`/
  `ACTIVITY_CATEGORY`) e le soglie di severità (UI-13, tarabili per ambiente). Sourcia
  `nlp/tools.conf` via `$TOOLS_CONF_FILE`, da cui viene anche `TOOL_SOURCES` — la
  partizione tool→sorgente di log, unica fonte di verità condivisa da guard e help
  (HELP-1, 2026-08-19). Gli esempi devono restare **concreti e copiabili** (nomi di log
  reali, nodi che esistono).
- **`examples.sh`** — generatori di esempi per `gen-examples.sh` (opzionale).
- **`system.local.conf`** — override per-installazione, non deployato (opzionale).

#### Override e risoluzione

`lib/nlp-paths.sh` → `nlp_resolve_paths()` è il **punto unico** che risolve i path, con
precedenza **profilo → framework per singolo artefatto**: un profilo può avere un
proprio `unigrams.txt` e usare il dataset condiviso. Va chiamata **prima** di sourciare
`domain.conf`, che ha bisogno di `TOOLS_CONF_FILE`.

Non può stare in `domain.conf` (che si auto-localizzava con `_DOMAIN_DIR`): i test
creano profili in `mktemp -d`, fuori dall'albero del repo, e un file copiato là non può
sapere dove sta `nlp/`.

`MODEL_DIR` è **derivato**, non configurato: un profilo che sovrascrive vocabolario,
topologia o dataset ottiene automaticamente pesi propri, perché il modello condiviso è
addestrato su input diversi dai suoi. Renderlo un flag separato permetterebbe di
configurare quell'incoerenza.

## Convenzioni critiche

- **Entity normalization**: le query passano sempre da `normalize-query.sh` prima della
  vectorizzazione (`"errori jboss"` → `"errori <APP>"`). Il classificatore non deve mai
  vedere nomi applicativi concreti nel training set.
- **Verifica coerenza topologia** (ARCH-4): `train.sh` confronta `NUM_FEATURES` (da
  `domain.conf`, calcolato da `unigrams.txt`/`bigrams.txt`) con la riga `input N` di
  `model.txt` prima di addestrare — se divergono, errore esplicito con suggerimento di
  reinizializzare via `setup.sh`. Evita modelli corrotti silenziosi.
- **Nessun default hardcoded**: valori come `SERVER_LOG_FORMAT`, nomi log, alias app
  vengono sempre letti da `system.conf`/`entities.conf`, mai da fallback impliciti nel
  codice (rifattorizzato in ARCH-6, vedi BACKLOG.md).

## Principi di progettazione

Stabiliti 2026-08-06, durante la generalizzazione della selezione file di log
(PERF-SAL). Valgono per tutto il progetto, non solo per un intervento
specifico:

1. **Generalizzazione**: i tool sono funzioni generalizzate applicabili a più
   contesti. Solo la parte *finale* di analisi è specifica della tecnologia.
   La selezione dei file di log, comprensiva delle rotazioni, funziona per
   qualsiasi log indipendentemente dal `BASE` — JBoss, log applicativi custom
   (es. Guidewire), e in altri profili applicativi o webserver
   (`select_log_files_grouped`, `lib/utils-logfiles.sh`).
2. **Logica centralizzata**: un solo punto di verità per ogni comportamento,
   per semplificare il debug ed evitare difetti divergenti negli stessi
   percorsi. Prima di aggiungere un ramo condizionale a un tool, valutare se
   la logica appartiene a una funzione condivisa.
3. **Logging DEBUG configurabile**: le fasi non visibili all'utente
   (selezione file, decisioni di pruning) vanno tracciate su un log a
   livello configurabile (`BOT_LOG_LEVEL`/`BOT_LOG_FILE` in `system.conf`,
   `lib/utils-log.sh`), mai su stdout — che è l'output formattato su cui
   asseriscono i test.
4. **Feedback progressivo**: durante le fasi che durano più di qualche
   decimo di secondo, il bot comunica cosa sta facendo —
   `progress_show`/`progress_clear` in `lib/utils-log.sh` (su stderr,
   condizionato a `[[ -t 2 ]]`, prefisso `⋯ ` per non collidere con le
   asserzioni dei test sulla prima colonna, disattivabile con
   `BOT_PROGRESS=off`). L'utente non deve trovarsi davanti a una shell
   apparentemente ferma. La fase di selezione file è strumentata nel motore
   condiviso (`select_log_files_grouped`), quindi vale per **tutti** i tool;
   solo i messaggi di fasi specifiche di un tool vivono in quel tool.
5. **Pruning conservativo**: escludere un file per errore è un bug di
   correttezza; includerlo per errore è solo lentezza. In caso di dubbio
   (timestamp non riconoscibile, formato inatteso), includere sempre.
6. **Il contratto di risoluzione si ferma al nodo** (deciso 2026-08-07,
   LOGDISC-1): il profilo garantisce di risolvere `(env, nodo, app)` fino alla
   directory del nodo (`LOG_SEARCH_ROOT`, emessa da `lib/resolve-logs.sh`).
   Sotto quella directory, la struttura è **ignota per contratto** e va
   **scoperta**, non enumerata: un profilo può non avere log applicativi
   custom, o organizzare i log diversamente dal nodo in giù. Per questo
   `resolve_log_glob()` (`lib/utils-logfiles.sh`) cerca ricorsivamente sotto
   `LOG_SEARCH_ROOT` invece di elencare sottodirectory fisse — è il punto che
   ha corretto il bug per cui `access.log` non veniva trovato perché viveva
   fuori da `CUSTOM_LOG_DIR`, l'unica directory che i tool interrogavano.
   Non violare questo principio aggiungendo una nuova directory nota
   (`APP_SUBPATH`, `CUSTOM_LOG_SUBPATH`, ...) a un tool: se un log può stare
   ovunque sotto il nodo, il tool deve cercarlo ovunque sotto il nodo.
   Ricorsione per la *scoperta*, selezione flat (`select_log_files_grouped`)
   per le *rotazioni* — che stanno sempre accanto al file che ruotano, quindi
   si raggruppano dalla directory del file scelto, non dalla root.
   Dal 2026-08-17 il contratto vale per **tutti** i percorsi: named log
   (LOGDISC-1), `search_all_logs` (LOGDISC-2) e i log di sistema
   access/server/gc (LOGDISC-4, `resolve_system_log_dir`). Nessun tool
   costruisce più path da `APP_SUBPATH`.

   **Politica cross-app: una sola, formulata una volta** (indicazione utente
   2026-08-17 — «conviene avere una politica sola, in modo che l'utente sappia
   sempre come si comporta il programma»). La regola invariante è **mai dati di
   un'app diversa da quella attesa senza dirlo**, e si declina secondo cosa fa
   il tool:
   - un tool che analizza **una sorgente** (`gc_stats`, `filter_errors`,
     `count_status`, …) usa l'app di sessione (`ACTIVE_APP` vince nel
     tie-break); se il log esiste **solo** sotto un'altra app **lo dice e si
     ferma** — `skip_named_log_not_found` per i named log,
     `skip_system_log_not_found` per quelli di sistema;
   - un tool che **aggrega su più sorgenti** (`search_all_logs`) le include
     tutte e **dichiara la provenienza** (colonna APP).

   Non sono due politiche ma la stessa con esito diverso, e la ragione è
   misurabile: una media di pause GC su due JVM distinte è priva di senso
   (misurato sul nodo 4: 127 eventi per un'app, 141 per l'altra), un elenco di
   occorrenze su due app è una risposta legittima. Quindi **la molteplicità
   richiede una scelta quando il tool analizza, un'etichetta quando aggrega**.

   Corollario sul vincolo `require_app` (bug corretto il 2026-08-17): «non
   appartiene a nessuna app» **non** è «appartiene all'app sbagliata». Un log in
   una directory che non nomina alcuna app va **accettato** — non c'è nulla da cui
   proteggersi, e rifiutarlo è un falso negativo (principio 5). Il confronto si fa
   con `resolve_app_from_path`, non verificando se il path contiene `/$ACTIVE_APP/`.
7. **Naming generico nel contratto, concreto solo nella prosa** (deciso
   2026-08-07): variabili, funzioni e directory che fanno parte del contratto
   generico del progetto non devono nominare un middleware o cliente
   specifico — dove prima si sarebbe scritto "Guidewire" si scrive
   "applicazione" o "custom" (es. `CUSTOM_LOG_SUBPATH`/`CUSTOM_LOG_DIR`, non
   `GUIDEWIRE_SUBPATH`/`GUIDEWIRE_LOG_DIR`). Un profilo diverso da `liquido`
   può non avere nulla a che fare con Guidewire, e il codice del contratto non
   deve presumerlo. Il vincolo si applica al **contratto** (nomi di variabili,
   funzioni, categorie di help, fixture di test), non alla **prosa che
   descrive un fatto reale e concreto** del profilo `liquido` — un formato di
   log realmente osservato, un sinonimo che gli utenti digitano davvero
   (`entities.conf`), un bug storico in un session log: lì "Guidewire" resta,
   perché è un dato di dominio, non un'assunzione del codice.
8. **Centralizzare significa migrare tutti i chiamanti, non solo crearne uno
   nuovo** (deciso 2026-08-07, dopo bug collegati a LOGDISC-1): introdurre una
   funzione condivisa (es. `_is_system_log_base()`) non elimina il difetto se
   un chiamante preesistente continua a usare una copia inline della stessa
   logica — succede quando la centralizzazione avviene mentre il codice
   esistente non viene riletto per intero. Prima di considerare chiusa una
   centralizzazione, cercare (`grep`) altre occorrenze della stessa condizione
   o assunzione altrove nel codice, non solo nel punto che ha originato il
   refactor. Lo stesso vale quando più funzioni fanno **assunzioni parallele
   sullo stesso formato** (es. schemi di rotazione dei nomi file in
   `logfile_logical_name()` e `_logfiles_sort_key()`): estendere una senza
   controllare le altre lascia un gap identico, solo più difficile da notare
   perché "sembra" già risolto altrove. Ogni modifica a `normalize-query.sh`
   richiede l'esecuzione di `bash tests/run-tests.sh --parity` (non incluso
   nella suite di default) per verificare che `lib/build_dataset.py`, la sua
   replica Python intenzionale, resti bit-identica — altrimenti la parità si
   rompe silenziosamente. Infine: un test che fallisce non implica
   automaticamente un bug nel codice — verificare sempre se è la fixture di
   test a violare un'invariante voluta (es. principio 5, pruning conservativo)
   prima di modificare la logica di produzione per farlo passare.

## Dependencies

- `gawk` — richiesto (usato da tutti i tool AWK di analisi log; non più dal motore
  neurale, che da 2026-08-18 è `neural-c`)
- `bash` ≥ 4
- `gunzip` — per lettura trasparente di log `.gz`
- `../neural-c` — framework neurale in C, cartella sorella richiesta. Unico motore di
  training/inferenza, su x86_64 e ppc64le (invocato via `neural-c.sh`, che seleziona il
  binario giusto per architettura — mai il binario direttamente).
- **Python 3** — mai per il training (quello è `neural-c`). Basta il `python3` di
  **sistema**: tutti gli script Python del progetto importano solo **stdlib**. Il `.venv`
  **non è un requisito**, è un override per-installazione (VENVGATE-1, 2026-08-21):
  conteneva l'albero di PyTorch per il vecchio `lib/train.py`, rimosso il 2026-08-18.
  - **Un solo punto di risoluzione**: `lib/utils-python.sh` → `resolve_python()`, con
    precedenza `NLA_PYTHON` (override esplicito) → `.venv` → `python3` di sistema. Prima
    tre script lo cercavano in tre modi diversi, e in produzione — dove `python3` c'è e
    il `.venv` no — `build-dataset.sh` prendeva il ramo bash: **0,2 s contro ≥110 s**.
  - `build-dataset.sh`: Python **opzionale**, solo velocità. Senza alcun interprete il
    ramo bash dà lo stesso risultato (verificato bit-identico) molto più lentamente.
  - `vocab-gap.sh`/`gap-report.sh`: **richiesto** (GAPREP-1). Usano `lib/dump_norm.py`
    per normalizzare il dataset allo stesso stadio delle feature — l'equivalente bash
    costa **54 s misurati** su 1171 query e girerebbe a ogni `train.sh`. Se manca, il
    report **si disattiva dichiarandolo** (`? gap NON misurato`, exit 2) e `train.sh`
    continua: non produce mai un falso «nessun gap».
  - **Tre esiti, non due, in tutta la suite**: `0` misurato, `2` **non misurabile**,
    altro = fallimento vero. `run-tests.sh` riporta il `2` come `SKIP` e non lo conta né
    fra i PASS né fra i FAIL. Su una macchina senza `python3` la suite dà quindi
    `184 PASS / 0 FAIL` con due SKIP espliciti, non sei FAIL che accusano il codice.
