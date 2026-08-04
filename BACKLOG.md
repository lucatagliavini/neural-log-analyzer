# Backlog — neural-log-analyzer

Aggiornato: 2026-08-04

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
| P2 | **`query-to-features.sh`: da `echo \| grep -qE` a `[[ =~ ]]` nativo** — vedi analisi sotto | ~10 righe | Media |

### P2 — Eliminare i fork per-pattern nella vectorizzazione

**Problema.** `query-to-features.sh` esegue `echo "$query" | grep -qE "$pattern"` una volta
per pattern del vocabolario: 107 unigram × 2 processi + 7 bigram × fino a 4 =
**~242 processi per singola query**. Bash ha `[[ =~ ]]` nativo, che non forka.

**Misure** (2026-08-04, questa macchina, 114 feature):

| Operazione | Tempo |
|---|---|
| `query-to-features.sh` (1 query) | 134 ms |
| `normalize-query.sh` (1 query) | 32 ms |
| catena `normalize + infer` (1 query) | 200 ms |
| `build_dataset.py` in-process, **1008 query** | 94 ms |
| 107 pattern con `echo \| grep -qE` | 315 ms |
| 107 pattern con `[[ =~ ]]` | **1 ms** (315×) |

Il backend Python processa l'intero dataset in meno tempo di quanto bash impieghi per una
singola query: la differenza non è il linguaggio, è il fork-per-pattern.

**Compatibilità verificata.** 21.400 confronti (107 pattern × 200 query reali del dataset):
**0 divergenze** tra `grep -E` e `[[ =~ ]]`, incluse le `\b` (estensione GNU, non ERE POSIX).

**Punti di attenzione.**
1. Il pattern va passato **non quotato** (`[[ $q =~ $p ]]`) — comportamento idiomatico di
   `=~`, ma un linter o un refactoring "che sistema il quoting" lo romperebbe in silenzio
   trasformando ~100 regex in stringhe letterali. Vale un commento nel codice.
2. `\b` funziona perché bash e grep condividono la regex GNU su glibc. Con musl (Alpine) o
   BSD la garanzia decade: la dipendenza si sposta da `grep` al runtime bash.

**Come validarlo.** `tests/test-normalize-parity.sh` confronta i 114 valori di feature tra
bash e Python su tutte le query: deve restare 1008/1008 dopo la modifica. È la ragione per
cui questo lavoro è stato rinviato a dopo NLOG (test di parità prima, refactoring poi).

**Estensione.** Stesso pattern in `param-extract.sh` (22 occorrenze) e `normalize-query.sh`
(9) — loop più corti, guadagno minore, stessa tecnica.

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

Piano completo in `/home/uga04128/.claude/plans/hazy-enchanting-moler.md`. Eseguito il
2026-08-04 (fasi 1-6); riprendere la validazione produzione da #17 dopo il deploy.

| ID | Descrizione | Stato |
|----|-------------|-------|
| NLOG-1 | `normalize-query.sh` sostituisce lo short-alias `cc`→`<APP>` anche dentro `cc.log` (`.` è word boundary valido); la feature `cc\.log` in `unigrams.txt` non si attiva mai in produzione → query tipo "ultime righe del cc.log" instradano su `tail_log` invece di `tail_named_log` | **Fatto** (2026-08-04) — risolto lato vocabolario: il pattern include `<app>\.log`, così la feature scatta su entrambi i path. La normalizzazione `cc`→`<APP>` resta (è corretta per l'intento "app ClaimCenter") |
| NLOG-2 | `build_dataset.py:parse_simple_array` non legge `AVAILABLE_APPS=(...)` su riga singola → la sezione di risoluzione alias in Python è codice morto; il dataset non normalizza `cc`/`cm` mentre il runtime bash sì (train/serve skew) | **Fatto** (2026-08-04) — `shlex.split` sul blocco unito; `APP_SHORT_ALIASES`/`APP_ALIAS_REGEX`/`APP_CANONICAL` lette da `entities.conf` invece che hardcoded |
| NLOG-3 | Nessun test di parità tra `normalize-query.sh` (bash) e `build_dataset.normalize_query()` (Python) — la divergenza NLOG-2 non è mai stata intercettata | **Fatto** (2026-08-04) — `tests/test-normalize-parity.sh`: 1008 query, confronta `NORM_QUERY` **e** i 114 valori di feature. Verificato fail-before/pass-after via `git stash` (36 mismatch pre-fix) |
| NLOG-4 | `tests/run-tests.sh` chiama `infer.sh` senza esportare `NORM_QUERY` come fa `chatbot.sh` — 5/40 test level1 "PASS" instradano diversamente in produzione | **Fatto** (2026-08-04) — `run_intent_tests()` normalizza ed esporta `NORM_QUERY` in una subshell per query (isolamento tra test). Suite 40→**46** test: aggiunti `ccJBatch`/`arbitrato`/`claimnumgen`/`ccCanaliz` e le 2 query con glob quotato |
| NLOG-5 | Vocabolario named-log copre solo 9/15 nomi di `entities.conf` (`APP_LOG_NAMES`): `ccJBatch`, `ccCanaliz`, `claimnumgen`, `contactsearch`, `arbitrato` senza feature dedicata | **Fatto** (2026-08-04) — alternanza esplicita sui 15 nomi + `<app>.log` + ramo glob, in `unigrams.txt` e nei 2 bigram. Topologia 117→**114** feature, retrain eseguito |
| NLOG-6 | Nessun modo di nominare un log fuori dalla whitelist di `entities.conf` — proposta: glob tra virgolette (`"*c1nssprod*.log"`), sul modello di `SEARCH_PATTERN` già esistente in `param-extract.sh` | **Fatto** (2026-08-04) — `NAMED_LOG_GLOB` in `param-extract.sh` (validazione anti path-traversal: rifiuta `..` e caratteri fuori da `[A-Za-z0-9_.*-]`), usato in `dispatch.sh` per `tail_named_log`/`grep_named_log` bypassando la catena fuzzy |

**Nota sulla determinismo (emersa durante NLOG-2).** `normalize-query.sh` iterava
`"${!ENV_NODE_CODE[@]}"` — ordine hash bash, non garantito tra versioni. Con `break` al
primo match, la scelta tra chiavi di pari lunghezza era indefinita *rispetto alla propria
config*, non solo verso Python. Ordinamento esplicito (lunghezza decrescente, poi
alfabetico) applicato su entrambi i lati. Difetto latente preesistente, non introdotto da
questo lavoro.

**Retrain post-NLOG** (2026-08-04): 1008 esempi, 114→48→15, early stopping epoca 1641,
MSE 0.00132, exact_match 97.7%, F1 0.986, 0 zero-vector. Le 4 divergenze test-vs-produzione
della baseline sono chiuse (0 residue).

**Generalizzazione verificata.** `arbitrato` e `ccCanaliz` hanno **zero esempi** in
`queries_labeled.txt`, ma instradano correttamente (99% e 37%) grazie all'alternanza
esplicita: la feature non richiede che il nome sia stato visto in training. `ccCanaliz` al
37% è il caso più debole della famiglia — sopra `TOOL_THRESHOLD` (0.25) ma da monitorare se
si aggiungono classi concorrenti.

**Checksum di regressione rigenerati** in `tests/test-train-regression.sh`
(`16aeeea5…`/`3e895f05…`, topologia parametrizzata in `TOPOLOGY`).

**`test-train-regression.sh` era flaky** (difetto preesistente, trovato durante la fase 7 e
corretto). PyTorch parallelizza le op su CPU e l'ordine di riduzione floating-point non è
garantito: su 8 core, 3 run multi-thread hanno prodotto **2 checksum distinti**, mentre 3 run
con `OMP_NUM_THREADS=1` sono bit-identici. Il test passava per fortuna, non per costruzione —
un fallimento sarebbe sembrato una regressione di `train.py` senza esserlo. Ora forza
`OMP_NUM_THREADS=1 MKL_NUM_THREADS=1`; verificato su 4 run consecutivi. `train.sh` (produzione)
resta multi-thread: là conta la velocità, non la riproducibilità bit-per-bit.

---

## NLOG2 — Trasparenza sul log scelto (trovato in validazione produzione 2026-08-04)

Caso reale: `"ultime 10 righe del pc1nssprod.log del nodo 5 di produzione"` → il nome non è
in `APP_LOG_NAMES` e non è un glob, quindi `NAMED_LOG` resta vuoto, il classificatore
ripiega su `tail_log` (98%) e l'utente riceve **l'access log di Undertow** senza alcun
indizio del cambio di argomento. `tail_named_log` dichiarava già `Log: /path`, `tail_log` no:
l'asimmetria rendeva il fallback indistinguibile da un risultato corretto.

| ID | Descrizione | Stato |
|----|-------------|-------|
| NLOG2-1 | `tail_log` non dichiarava quale file leggeva (a differenza di `tail_named_log`) | **Fatto** (2026-08-04) — `print_log_source()` in `dispatch.sh`, chiamata nei 4 rami di `tail_log` (access/server × con/senza tempo). Gestisce file singolo, multi-file da rotazione e `.gz` (estrae il path da `<(gunzip -c '…')`) |
| NLOG2-2 | Nessun avviso quando la query nomina un `.log` non risolvibile | **Fatto** (2026-08-04) — `UNRESOLVED_LOG` in `param-extract.sh` (esclude access/server/gc legittimi, calcolato **dopo** `NAMED_LOG_GLOB` per non dare falsi avvisi sui glob validi); `chatbot.sh` elenca i log noti e suggerisce il glob corrispondente al nome digitato |
| NLOG2-3 | **`ccJBatch.log` e `ccCanaliz.log` risolti come `cc`** — il loop su `APP_LOG_NAMES` iterava nell'ordine del file e `\bcc` matcha il prefisso. Il classificatore instradava bene su `tail_named_log`, ma `dispatch.sh` apriva `cc.log`: file sbagliato, nessun errore | **Fatto** (2026-08-04) — longest-match con `sort -k1,1rn -k2,2`, stesso pattern di `normalize-query.sh`. Trovato dal nuovo `tests/test-param-extract.sh`, non a mano |
| NLOG2-6 | **`ccJBatch`/`ccCanaliz` scritti con le maiuscole nei pattern del vocabolario** — `normalize-query.sh` fa lowercase e `grep -qE` è case-sensitive, quindi `ccJBatch` nel pattern non matcha mai `ccjbatch` nella query normalizzata. `ccCanaliz.log` instradava su `tail_log` (98%, access log); `ccJBatch.log` passava i test al 92% **solo per via di `batch\b`**, non della feature named-log (che valeva 0) — un test verde per la ragione sbagliata | **Fatto** (2026-08-04) — pattern portati in minuscolo in `unigrams.txt` e nei 2 bigram. Dataset rigenerato **bit-identico** (nessun esempio labeled usa quella forma) → **nessun retrain**. Routing: `ccCanaliz.log` da `tail_log` a `tail_named_log` 99.1%, `ccJBatch.log` da 92% a 99.8%. Suite 46→48 test |
| NLOG2-4 | Mismatch semantico vocabolario ↔ whitelist: il pattern del classificatore matcha per **sottostringa** (`(cc\|api\|…)\.log` matcha `api.log` dentro `xyzapi.log` → `tail_named_log` 99%), `param-extract.sh` per **word boundary** (`\bapi` non matcha → `NAMED_LOG` vuoto → `[SKIP] Nessun log Guidewire specificato`, messaggio contraddittorio). Oggi mitigato da NLOG2-2 (l'utente riceve un avviso utile invece dello SKIP), ma la causa resta. Due opzioni: ancorare il pattern del vocabolario (**richiede retrain**) o allentare `param-extract.sh` (nessun retrain, ma `xyzapi.log` verrebbe risolto come `api.log` — probabilmente sbagliato) | **Da discutere** — riprendere insieme a NLOG2-5 |
| NLOG2-5 | **Tool "lista log" (proposta utente 2026-08-04)** — uno strumento che mostri all'utente quali log può nominare, invece di lasciarglielo scoprire per tentativi. Complemento naturale di NLOG2-2: quello dice "non conosco questo nome", questo direbbe "ecco cosa conosco". Da chiarire: nuova classe del classificatore o estensione di `show_help`? Lista statica da `APP_LOG_NAMES` o `find` sui file realmente presenti sul nodo (più utile ma dipende dal contesto env/nodo attivo)? Include anche access/server/gc? | **Da discutere** |

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
