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

**Dipendenza da neural-bash:** questo repository dipende dal framework AWK in
`../neural-bash` (path relativo — le due cartelle devono restare sorelle). Gli script
`train.sh`, `setup.sh`, `lib/infer.sh`, `lib/infer-dry.sh` invocano
`../neural-bash/nnet-run.sh` / `../neural-bash/nnet-init.sh`. Separato da neural-bash il
2026-08-03 (storia preservata via `git subtree split`); remote `origin` su GitHub
(`lucatagliavini/neural-log-analyzer`).

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

# Report gap nel vocabolario/dataset per classe
./gap-report.sh --profile profiles/liquido

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
      │  train.sh  (adam, PyTorch wrapper, early stopping)
      ▼
  models/intent_classifier/  (97→48→15, sigmoid, Xavier)
      │  chatbot.sh
      ▼
  query → normalize-query.sh → query-to-features.sh → rete → tool attivati
```

### Backend Python (training accelerato)

- `lib/train.py` — wrapper PyTorch CPU-only per training. Warm-start, early stopping.
  Fallback su gawk se `.venv` assente. ~1900× più veloce di AWK.
- `lib/build_dataset.py` — rebuild dataset in-process, replica
  `normalize-query.sh` + `query-to-features.sh` in Python. Output bit-identico alla
  pipeline bash (verificato 968/968).
- `.venv/bin/python3` autodetect nei wrapper Bash corrispondenti.

### Componenti principali

| File | Responsabilità |
|------|---------------|
| `chatbot.sh` | REPL interattivo e modalità `--query` |
| `setup.sh` | Inizializza il modello per un profilo (chiama `nnet-init.sh`) |
| `train.sh` | Addestra il classificatore (chiama `nnet-run.sh` o `lib/train.py`) |
| `build-dataset.sh` | Genera il dataset di training dai labeled examples |
| `lib/infer.sh` | Feature vector → rete → nomi tool attivati |
| `lib/dispatch.sh` | Routing tool name → invocazione AWK |
| `lib/normalize-query.sh` | Normalizza entità (APP/ENV/NODE) → `NORM_QUERY` + `DETECTED_*`, unica fonte di verità |
| `lib/query-to-features.sh` | Query testuale (normalizzata) → vettore numerico |
| `lib/param-extract.sh` | Estrae `TIME_FROM`, `TIME_TO`, `STATUS_CODE`, `THRESHOLD_MS`, ecc. |
| `lib/utils-time.sh` / `lib/utils-time.awk` | Range temporale in linguaggio naturale italiano → epoch/ISO8601 |
| `lib/resolve-logs.sh` | `(env, nodo, app)` → path file di log |
| `lib/gen-examples.sh` | Genera esempi labeled via espansione sinonimi |
| `lib/utils-colors.awk`, `lib/utils-jboss.awk`, `lib/utils-dedup.awk` | Utility AWK condivise, caricate con `-f` multipli da `dispatch.sh` |
| `lib/tools/` | 14 tool AWK di analisi log (vedi README per la lista completa) |

### Struttura profilo (`profiles/<nome>/`)

- **`system.conf`** — path log, timezone, ambienti disponibili. Modificabile senza
  riaddestrare.
- **`domain.conf`** — `TOOL_THRESHOLD`, `MODEL_TOPOLOGY` (auto-calcolato da
  `NUM_FEATURES`), `TOOL_NAMES`/`TOOL_DESC`. Modifiche richiedono `./train.sh`.
- **`entities.conf`** — mappa alias APP/ENV/NODE, sinonimi, risoluzione inversa.
  Aggiungere una nuova applicazione richiede solo una riga qui, non un retrain.
- **`vocab.sh`** — `UNIGRAMS`/`BIGRAMS` con peso, `NUM_FEATURES`. Modifiche richiedono
  `./build-dataset.sh` + `./train.sh`.
- **`examples.sh`** — generatori di esempi specifici del profilo.
- **`dataset/`** — `queries_labeled.txt` → `queries.txt` (generato).

## Convenzioni critiche

- **Entity normalization**: le query passano sempre da `normalize-query.sh` prima della
  vectorizzazione (`"errori jboss"` → `"errori <APP>"`). Il classificatore non deve mai
  vedere nomi applicativi concreti nel training set.
- **Verifica coerenza topologia**: `train.sh` confronta `NUM_FEATURES` (da `vocab.sh`)
  con le colonne di `layer1.txt` prima di addestrare — se divergono, errore esplicito
  con suggerimento di reinizializzare via `setup.sh`. Evita modelli corrotti silenziosi.
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
   si raggruppano dalla directory del file scelto, non dalla root. Quando più
   app coesistono sotto lo stesso nodo con file omonimi, l'app della sessione
   corrente (`ACTIVE_APP`) vince nel tie-break; se il log esiste solo sotto
   un'altra app, non va aperto silenziosamente — va detto "non trovato" e
   suggerita l'app dove si trova (mai mescolare dati di app diverse senza
   dirlo). `search_all_logs.sh` è ancora enumerativo (asimmetria nota, vedi
   BACKLOG.md).
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

## Dependencies

- `gawk` — richiesto (usato da tutti i tool AWK e dal framework neurale)
- `bash` ≥ 4
- `gunzip` — per lettura trasparente di log `.gz`
- Python 3 + `.venv` (opzionale ma raccomandato) — `pip install -r requirements.txt
  --index-url https://download.pytorch.org/whl/cpu` per il training accelerato via
  PyTorch CPU-only
- `../neural-bash` — framework AWK, cartella sorella richiesta
