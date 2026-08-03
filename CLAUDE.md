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
2026-08-03 (storia preservata via `git subtree split`); nessun remote GitHub configurato
per ora, solo locale.

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

## Dependencies

- `gawk` — richiesto (usato da tutti i tool AWK e dal framework neurale)
- `bash` ≥ 4
- `gunzip` — per lettura trasparente di log `.gz`
- Python 3 + `.venv` (opzionale ma raccomandato) — `pip install -r requirements.txt
  --index-url https://download.pytorch.org/whl/cpu` per il training accelerato via
  PyTorch CPU-only
- `../neural-bash` — framework AWK, cartella sorella richiesta
