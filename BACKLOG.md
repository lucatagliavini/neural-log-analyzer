# Backlog — neural-log-analyzer

Aggiornato: 2026-07-31 (sessione 04)

---

## NORM — Entity Normalization (Step 1)

Obiettivo: disaccoppiare il classificatore dai nomi applicativi concreti.
Le query vengono normalizzate prima della vectorizzazione: `"errori jboss"` → `"errori <APP>"`.
Aggiungere una nuova applicazione richiede solo una riga in `entities.conf`, non un retrain.

| ID | Descrizione | Stato |
|----|-------------|-------|
| NORM-1 | `profiles/liquido/entities.conf` — mappa alias APP/ENV/NODE, sinonimi, risoluzione inversa | **Fatto** |
| NORM-2 | `lib/normalize-query.sh` — unica fonte di verità per `DETECTED_APP/ENV/NODE` + `NORM_QUERY` | **Fatto** |
| NORM-3 | `tests/test-normalize-query.sh` — 35 test unitari (APP, ENV, NODE, hostname, combo, abbreviazioni) | **Fatto** |
| NORM-4 | `lib/param-extract.sh` — emette `DETECTED_*` in pass-through dall'ambiente | **Fatto** |
| NORM-5 | `lib/query-to-features.sh` — usa `NORM_QUERY` se disponibile, fallback su `$1` | **Fatto** |
| NORM-6 | `build-dataset.sh` — normalizza ogni esempio prima della vectorizzazione | **Fatto** |
| NORM-7 | `unigrams.txt` — rimosso `\bguidewire\b` (ora normalizzato a `<APP>`) | **Fatto** |
| NORM-8 | `chatbot.sh` — sostituisce `context-extract.sh` con `normalize-query.sh`; sourca `entities.conf` | **Fatto** |
| NORM-9 | **Retrain** — rebuild dataset → linter → train con placeholder | **Fatto** (2026-07-31) |

---

## P — Performance

| ID | Descrizione | Stima | Priorità |
|----|-------------|-------|----------|
| P1 | **`search_all_logs` parallelo** — ogni `_search_one` con `&` + tmpfile + `wait` + stampa ordinata in `dispatch.sh`. Speedup stimato 5-6× su nodi con molti log Guidewire (I/O-bound) | ~15 righe | **Fatto** |

---

## ARCH — Architettura / Refactoring

> Obiettivo: eliminare la duplicazione senza riscrivere i tool. Pattern: utility AWK
> caricati con `-f` multipli da `dispatch.sh` (già usato da `utils-time.awk`).
> Ogni tool resta un file singolo testabile isolatamente.

| ID | Descrizione | Impatto | Complessità |
|----|-------------|---------|-------------|
| ARCH-1 | **`utils-colors.awk`** — definisce `RED`, `YELLOW`, `GREEN`, `CYAN`, `BOLD`, `DIM`, `RESET` in `BEGIN{}`. Rimuovere le definizioni duplicate da tutti i 14 tool. Aggiungere `-f utils-colors.awk` come secondo `-f` fisso in `dispatch.sh`. | 14 file, ~14 righe rimosse | **Fatto** (già implementato, nessun tool ridefinisce colori) |
| ARCH-2 | **`utils-jboss.awk`** — sposta `parse_jboss()` e `is_frame()` da `filter_errors.awk`. Rende `filter_app_errors.awk` aggiornabile senza riscrivere il parsing. | 2 tool, funzionalità critica | **Fatto** |
| ARCH-3 | **`utils-dedup.awk`** — `dedup_add(dk, level, msg, ts, log)` + `dedup_sort()` + `dedup_print(max_rows)`. Consolida tre implementazioni semi-diverse in `filter_errors`, `grep_named_log`, `filter_app_errors`. | 3 tool, ~60 righe fattorizzate | **Fatto** |

**Ordine consigliato:** ARCH-1 (zero rischio, impatto alto) → ARCH-2 → ARCH-3.

---

## ARCH — Architettura / Robustezza (nuovi)

| ID | Descrizione | Priorità |
|----|-------------|----------|
| ARCH-4 | **Verifica coerenza topologia in `train.sh`** — prima di avviare il training, confrontare `NUM_FEATURES` (da `vocab.sh`) con `cols(layer1.txt) - 1` (bias escluso). Se divergono: stampare un warning chiaro con il suggerimento `./setup.sh --profile <dir>` per reinizializzare i layer file con la topologia corretta, poi uscire con errore. Evita il caso silenzioso "vettori a 97 feature, modello a 90 input" che produce un modello corrotto senza alcun messaggio. | **Fatto** |

---

## T — Training / Modello

| ID | Descrizione | Stato |
|----|-------------|-------|
| T1 | **Vocab additions** — 20 nuovi pattern aggiunti a `unigrams.txt` (service, tempi, database, messaging, causa, durante, …). Topologia 97→117. | **Fatto** (2026-07-31) |
| T2 | **`slow_requests` vocab** — `sopra\b` e `tempi\b` aggiunti in T1. | **Fatto** (2026-07-31) |
| T3 | **Retrain unico** — eseguito post T1+T2: 968 esempi, 0 zero-vector, 117→48→15. | **Fatto** (2026-07-31) |
| T4 | **C7↔C8 confusion** — verificato: separazione già buona (service_times 96.9%, correlate_gc_slow 98.3%). Nessun intervento necessario. | Chiuso |

---

## O — Output / Fix strumenti

| ID | Descrizione | Stato |
|----|-------------|-------|
| O1 | Stack trace multiriga `filter_errors.awk` — state machine `parse_jboss` + `is_frame` + `flush_exception` | **Fatto** (commit 7c8e994) |
| O2 | `filter_app_errors`: truncate ROOT CAUSE a 80 char prima della chiave di grouping | **Fatto** |
| O3 | `grep_named_log`: dedup + sort rarest-first + footer distinti | **Fatto** |
| O4 | `service_times`: rewrite su access log (formato `RETURN(service)` non presente) | **Fatto** |
| O5 | `filter_ip`: separatore AVG MS allineato (8 char) | **Fatto** |

---

## UI — Grafica / Colori

| ID | Descrizione | Stato |
|----|-------------|-------|
| UI-1 | `correlate_gc_slow`: verdict block + soglie 10%/30% | **Fatto** |
| UI-2 | `gc_stats`: `print ""` prima del riepilogo | **Fatto** |
| UI-3 | `traffic_volume`: separatore sotto header ANDAMENTO | **Fatto** |
| UI-4 | `tail_log`: colorize 4xx/5xx access log | **Fatto** |
| UI-5 | `tail_named_log`: tool dedicato con colori Guidewire | **Fatto** |
| UI-6 | `dispatch.sh`: path log in CYAN per `tail_named_log` e `grep_named_log` | **Fatto** |
| UI-7 | `count_status`: percentuale, barra log, summary 2xx/3xx/4xx/5xx, tasso errore, periodo | **Fatto** |
| UI-8 | **Periodo temporale in tutti i tool** — funzione `_print_time_window()` in `dispatch.sh`; rimosso blocco duplicato da `count_status.awk`. Colori: DIM grigio etichetta, `\033[97m` bianco puro per i valori. | **Fatto** (2026-07-31) |
| UI-10 | **`search_all_logs`: righe alternate bianco/grigio per nodo** — nella tabella risultati, alternare DIM/normale tra i nodi per migliorare la leggibilità quando ci sono molte righe. | **Fatto** (2026-07-31) |
| UI-9 | **`search_all_logs`: ricerca su tutti i nodi** — se la query non specifica un nodo, il tool oggi cerca solo sul nodo attivo in sessione. Aggiungere un'iterazione su tutti i nodi dell'ambiente (da `NODE_NAME_TEMPLATE` + lista nodi in `system.conf`) e aggregare i risultati raggruppati per nodo. Rimuovere anche il suggerimento "→ Per dettaglio: …" che produce output errato (nome file invece di nome log leggibile). | **Fatto** (2026-07-31) |

---

## ARCH — Generalizzazione config (nuovi)

| ID | Descrizione | Priorità |
|----|-------------|----------|
| ARCH-5 | **`SERVER_LOG_FORMAT` in `system.conf`** — aggiunto; `param-extract.sh` usa `$SERVER_LOG_FORMAT` invece di `jboss` hardcoded per riconoscere keyword "log jboss/websphere/..." → `LOG_TYPE=server`. Ogni profilo dichiara la propria tecnologia. | **Fatto** (2026-07-31) |
| ARCH-6 | **Audit hardcoding in `param-extract.sh`** — verificare se esistono altri nomi di tecnologie o applicazioni hardcoded nei grep/regex che dovrebbero provenire da `system.conf` o `entities.conf`. | **Fatto** (2026-07-31) |

---

## C — Classificazione (dataset)

| ID | Descrizione | Stato |
|----|-------------|-------|
| C1 | 8 esempi `distribute_status` con "endpoint + errori 5xx" | **Fatto** (commit 7c8e994) |
| C2 | 9 esempi `filter_errors` con "server.log/jboss" | **Fatto** (commit 7c8e994) |

---

## NLOG — Train/serve skew sui named log (trovato in validazione produzione #17)

Piano completo in `/home/uga04128/.claude/plans/hazy-enchanting-moler.md`. Da eseguire
come prima cosa nella prossima sessione, prima di riprendere la validazione da #17.

| ID | Descrizione | Stato |
|----|-------------|-------|
| NLOG-1 | `normalize-query.sh` sostituisce lo short-alias `cc`→`<APP>` anche dentro `cc.log` (`.` è word boundary valido); la feature `cc\.log` in `unigrams.txt` non si attiva mai in produzione → query tipo "ultime righe del cc.log" instradano su `tail_log` invece di `tail_named_log` | Da fare |
| NLOG-2 | `build_dataset.py:parse_simple_array` non legge `AVAILABLE_APPS=(...)` su riga singola → la sezione di risoluzione alias in Python è codice morto; il dataset non normalizza `cc`/`cm` mentre il runtime bash sì (train/serve skew) | Da fare |
| NLOG-3 | Nessun test di parità tra `normalize-query.sh` (bash) e `build_dataset.normalize_query()` (Python) — la divergenza NLOG-2 non è mai stata intercettata | Da fare |
| NLOG-4 | `tests/run-tests.sh` chiama `infer.sh` senza esportare `NORM_QUERY` come fa `chatbot.sh` — 5/40 test level1 "PASS" instradano diversamente in produzione | Da fare |
| NLOG-5 | Vocabolario named-log copre solo 9/15 nomi di `entities.conf` (`APP_LOG_NAMES`): `ccJBatch`, `ccCanaliz`, `claimnumgen`, `contactsearch`, `arbitrato` senza feature dedicata | Da fare |
| NLOG-6 | Nessun modo di nominare un log fuori dalla whitelist di `entities.conf` — proposta: glob tra virgolette (`"*c1nssprod*.log"`), sul modello di `SEARCH_PATTERN` già esistente in `param-extract.sh` | Da fare |

---

## CTX — Contesto conversazionale

> Obiettivo: rendere il chatbot "stateful" — ogni parametro estratto da una query
> persiste nella sessione fino a esplicita sostituzione, esattamente come già avviene
> per `ACTIVE_ENV`, `ACTIVE_NODE`, `ACTIVE_APP`, `ACTIVE_NAMED_LOG`.

| ID | Descrizione | Priorità |
|----|-------------|----------|
| CTX-1 | **Persistenza filtro temporale** — `ACTIVE_TIME_FROM` / `ACTIVE_TIME_TO` in `chatbot.sh`. Se la query specifica un tempo → aggiorna; se non → eredita. | **Fatto** (2026-07-31) |
| CTX-2 | **Header contesto ad ogni query** — `context_line()` in cima a ogni risposta. Formato: `[prod · nodo 03 · ClaimCenter · 10:00→13:00]` con DIM/bianco (UI-8). | **Fatto** (2026-07-31) |
| CTX-3 | **Frasi di set-context** — intercetta "considera nodo X", "lavoriamo in prod", "dalle 10 alle 14" prima del classificatore. Risposta: "Contesto aggiornato". No nuova classe ML. | **Fatto** (2026-07-31) |

---

## DEDUP — Normalizzazione chiave di deduplicazione

| ID | Descrizione | Stato |
|----|-------------|-------|
| DEDUP-1 | **Normalizzazione ID numerici in chiave dedup** — `WorkItemPeriodicWork_Ext:1778994` e `:1778995` sono deduplicati separatamente perché l'ID è parte del messaggio. Normalizzare la chiave rimuovendo numeri/UUID ridurrebbe il rumore ma nasconderebbe quanti WorkItem distinti sono bloccati (informazione utile per valutare la gravità). **Da discutere prima di implementare**: opzione configurabile? Soglia minima? Solo in modalità "summary"? | Da discutere |

---

## Note architetturali — cosa NON fare

- **No wrapper sh per ogni tool.** Aggiungere `filter_errors.sh` → `gawk -f ...` non porta valore: la composizione è già in `dispatch.sh` e si perderebbe la testabilità diretta del singolo `.awk`.
- **No mega-framework.** Tre utility file bastano per eliminare tutta la duplicazione identificata.
- **Preservare la testabilità diretta** di ogni tool: `gawk -f utils-time.awk -f filter_errors.awk server.log` deve continuare a funzionare.
