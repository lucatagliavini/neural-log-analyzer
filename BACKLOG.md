# Backlog — neural-log-analyzer

Aggiornato: 2026-08-06

---

## ⏭ APERTI, in ordine di priorità

| # | Voce | Sezione | Nota |
|---|------|---------|------|
| 1 | **SRCH-1** — ricerca testuale in un log nominato | SRCH | L'unica voce che aggiunge *funzionalità* e non velocità. Aperta dal 2026-08-05 |
| 2 | **P7** — `grep_named_log` (3390ms di mediana, mai analizzato) | P | Candidato performance residuo più promettente |
| 3 | **UI-12** — migrare i 13 tool ai nomi semantici dei colori | UI | Incrementale; corregge anche `RED` usato per "soglia" invece di "errore" |
| 4 | **UI-13** — soglie in `domain.conf` | UI | `SLOW_MS` definito due volte con valori diversi; le rende tarabili per ambiente |

**Chiusi il 2026-08-06**: OBS-3 (copertura logging sui 14 tool), UI-11 (sistema di temi
colore, default `mono` a zero ANSI).

**Non si fa ora**: `PERF-NNET` (overhead fisso della pipeline di inferenza) — l'utente ha in
mente una modifica major su quella parte, vedi sezione P.

---

## SRCH — Ricerca testuale in un log nominato (gap trovato in validazione produzione 2026-08-05)

Trovato durante la validazione manuale di `search_all_logs`: non esiste un modo per cercare
una stringa testuale in **un log specifico nominato dall'utente** (es. "cerca X nel cc.log").
Oggi ci sono due metà di funzionalità che non si toccano:

- `grep_named_log` filtra un log nominato solo per **livello** (ERROR/WARN/INFO), non accetta
  un pattern testuale libero — `dispatch.sh:466-513` passa all'AWK solo `level` e `tail_n`,
  nessun canale per un pattern testuale.
- `search_all_logs` accetta un pattern testuale libero (`SEARCH_PATTERN`) ma cerca sempre su
  **tutti** i log del nodo, mai su uno nominato dall'utente.

| ID | Descrizione | Priorità |
|----|-------------|----------|
| SRCH-1 | Colmare il gap: o (a) `grep_named_log` accetta un pattern testuale oltre al livello, o (b) `search_all_logs` restringe la ricerca a `NAMED_LOG` quando la query lo specifica. Decidere l'approccio con l'utente prima di implementare (impatto su vocabolario/dataset da valutare: nuova combinazione di parametri, non necessariamente nuova classe) | **Alta** |

---

## MIGR — Migrazione a Python (nuovo progetto)

Valutata la conversione dell'orchestrazione (chatbot.sh, dispatch.sh, normalize-query.sh,
param-extract.sh, query-to-features.sh — NON i 14 tool AWK, che restano tali) verso Python,
per manutenibilità: doppia implementazione bash/Python già causa di bug reali (NLOG-2),
array paralleli in domain.conf senza validazione automatica (gap ARCH-4), quoting bash come
minefield documentato (P2). Piano di migrazione concreto in un **repository separato**,
`../neural-log-lanalyzer` (stesso pattern di separazione già usato per `neural-bash`):
`../neural-log-lanalyzer/docs/MIGRATION-PLAN.md`. Questo repository resta lo stato di
riferimento comportamentale finché la migrazione non è completa — fix e feature continuano
qui, non nel nuovo progetto, così il piano parte da un comportamento verificato e non da
difetti noti da correggere due volte.

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
| P2 | **`query-to-features.sh`: da `echo \| grep -qE` a `[[ =~ ]]` nativo** — vedi analisi sotto | ~10 righe | **Fatto** (2026-08-04) |
| P2-bis | **Stesso refactoring in `param-extract.sh` e `normalize-query.sh`** — valutato e scartato, vedi sotto | ~30 righe | **Chiuso: non si fa** (2026-08-04) |
| P3 | **`wait -n` nel pool di `search_all_logs`** — `wait "${pids[0]}"` attendeva il worker più vecchio (head-of-line blocking). Misurato 104.2s → 39.7s a parità di worker | 3 righe | **Fatto** (2026-08-06) |
| P4 | **Pre-gate `grep -qiF` + `pigz` + `gated=1`** in `search_all_logs` — vedi PERF-SAL nel session log 2026-08-06. Query reale 144s → 83s (-42%) | ~40 righe | **Fatto** (2026-08-06) |
| P5 | **Indice per secondo in `correlate_gc_slow`** — il loop scandiva tutte le pause GC per ogni richiesta lenta (18665 × 543 ≈ 10M iterazioni). Mediana 8.37s → 5.68s | ~15 righe | **Fatto** (2026-08-06) |
| P6 | **Memoizzazione `parse_access()` + inversione filtri `slow_requests`** — 18.4 righe per secondo distinto, cache evita ~95% delle `mktime()`. `count_status` 3.64s → 1.23s, `slow_requests` 6.78s → 4.00s | ~20 righe | **Fatto** (2026-08-06) |
| P7 | **`grep_named_log`** — emerso a 3390ms di mediana nel log di performance, mai analizzato. Candidato residuo più promettente | ? | Media |
| PERF-NNET | **Overhead fisso per query (~574ms)**: classificazione neurale (`infer.sh`) + `normalize-query.sh` + `param-extract.sh` + fork di `resolve-logs.sh`. Vedi sotto | — | **Non si fa ora — l'utente ha in mente una modifica major** |

### PERF-NNET — overhead fisso della pipeline di inferenza

Misurato col log di performance (2026-08-06): **~574ms costanti per query**, indipendenti dal
volume dei log. Composizione da scomporre (non ancora fatto): `infer.sh` (rete neurale),
`normalize-query.sh`, `param-extract.sh`, il fork di `resolve-logs.sh`, il rendering.

**Peso reale, e perché non è la priorità:** dipende interamente dalla scala della query, e le
due misure sembrano contraddirsi solo se si ignora questo:

| fase | fixture locali (KB) | produzione (34 MB/query) |
|---|---|---|
| analisi AWK | 12ms (4.1%) | **3498ms (82.6%)** |
| overhead fisso | 261ms (**84.7%**) | 574ms (13.6%) |

L'overhead è **costante**, l'analisi è **proporzionale**. Su query piccole domina l'overhead,
su query reali domina l'analisi — quindi ottimizzarlo migliorerebbe le query che già rispondono
in 300ms, lasciando intatte quelle da 8 secondi. Stesso ragionamento che chiuse P2-bis.

**Decisione (utente, 2026-08-06): non si tocca ora.** L'utente ha in mente una **modifica
major** su questa parte (inferenza), quindi qualsiasi micro-ottimizzazione qui rischia di
essere lavoro buttato. Da riprendere solo dopo che quella modifica è definita — e in quel
momento questi numeri sono la baseline di confronto.

### P2-bis — perché non si fa

Valutato dopo P2, con le verifiche di compatibilità già fatte (**48.672 confronti** su tutti i
pattern reali × 1014 query: 0 divergenze, `[[:space:]]` incluso). Tecnicamente fattibile, ma
il rapporto costo/beneficio non regge:

**1. Il guadagno è invisibile.** Una query reale in produzione impiega **2146 ms** end-to-end:
il 96% è lettura e parsing AWK dei file di log (su `cc.log` sono ~500.000 righe), irriducibile.
La latenza del classificatore è 86 ms, il **4%** del totale. Portarla a ~50 ms significa
2146 → 2110 ms: **1,7%**, sotto la soglia di percezione.

**2. La composizione è diversa da P2.** In `query-to-features.sh` tutti i `grep` erano test
booleani dentro un loop di 108 iterazioni — un fork eliminato valeva ×108. Qui ciascun `grep`
gira **una volta sola** per query: ~1,5 ms a testa. E dei 35 punti, solo 25 sono `grep -q`
convertibili; 11 sono `grep -o` (estrazioni, richiederebbero `BASH_REMATCH`) e **10 sono
`sed -E`**, irriducibili con questa tecnica: `[[ =~ ]]` testa, non sostituisce, e
`${var//pattern/}` supporta solo glob, non regex. Servirebbe riscrivere la logica, non
rifattorizzarla.

**3. Il rischio non è simmetrico al beneficio.** 36 ms su 2146 contro modificare 25 punti nel
cuore della normalizzazione. `test-normalize-parity.sh` protegge dalle divergenze bash/Python,
ma non da un errore che *entrambe* le implementazioni condividono — es. un `\b` scritto inline
invece che in variabile (bash consuma il backslash e il match falla silenziosamente: trappola
verificata durante questa valutazione, il primo test l'aveva mascherata).

**Quando riaprirlo.** Solo se la latenza del classificatore diventa dominante — ad esempio con
un profilo che legge log molto piccoli, o se il chatbot venisse usato in batch su migliaia di
query. In quel caso partire da `param-extract.sh` (16 `grep -q`, nessun `sed`, nessun vincolo
di parità) e non toccare `normalize-query.sh`.

**Lezione di metodo**: le stime di P2/P2-bis confrontavano il guadagno con la latenza del
*classificatore isolato*, non col tempo che l'utente percepisce. Misurare il totale
end-to-end prima di ottimizzare un componente evita di lavorare sul 4%.

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

**Compatibilità verificata.** Prima misura: 21.400 confronti (107 pattern × 200 query).
Riverificata prima di applicare, col vocabolario a 108 feature: **116.610 confronti**
(115 pattern — unigram + entrambi i lati dei bigram — × **tutte** le 1014 query reali),
**0 divergenze**, incluse le `\b` (estensione GNU, non ERE POSIX) e il pattern `<logfile>`
con parentesi angolari.

**Punti di attenzione.**
1. Il pattern va passato **non quotato** (`[[ $q =~ $p ]]`) — comportamento idiomatico di
   `=~`, ma un linter o un refactoring "che sistema il quoting" lo romperebbe in silenzio
   trasformando ~100 regex in stringhe letterali. Documentato nel codice.
2. `\b` funziona perché bash e grep condividono la regex GNU su glibc. Con musl (Alpine) o
   BSD la garanzia decade: la dipendenza si sposta da `grep` al runtime bash.

**Risultato (applicato 2026-08-04).** `query-to-features.sh` da **112 → 9 ms/query** (12×);
catena `normalize + infer` da ~200 a **86 ms**. `test-normalize-parity.sh` **1014/1014
identici** sui 108 valori di feature: il refactoring non ha cambiato un solo valore. Suite
completa invariata (57/43/48 PASS, checksum di regressione OK). Sul server 19 ms/query —
più lento in assoluto, stessa proporzione di miglioramento.

Il tempo residuo si è spostato: dei 86 ms della catena, **36 sono in `normalize-query.sh`** e
47 nel totale di `infer.sh` (che include la rete neurale in AWK). Vedi P2-bis.

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
| UI-11 | **Sistema di temi colore** — `themes/*.conf` letti da bash e awk, `lib/utils-theme.sh`, 7 ruoli semantici (`C_CRIT`/`C_WARN`/`C_OK`/`C_VAL`/`C_LBL`/`C_ACCENT`/`C_ROW_ALT`), 9 temi, `--theme`/`--list-themes`/`BOT_THEME`/`NO_COLOR`, `theme-preview.sh`. **Default `mono`: zero ANSI**, per servizi e redirect su file. Risolti i 132 ANSI hardcoded nei 6 file bash che sfuggivano a `utils-colors.awk`. | **Fatto** (2026-08-06) |
| UI-12 | **Migrare i 13 tool ai nomi semantici** — oggi usano ancora le costanti storiche (`RED`, `YELLOW`…) mappate sui ruoli in `utils-colors.awk`. La migrazione rende esplicito *perché* un elemento è colorato e corregge i casi dove `RED` significa "soglia superata" invece di "errore" (`slow_requests`, `service_times`, `gc_stats`, `correlate_gc_slow`). Incrementale, un tool per volta. | Media |
| UI-13 | **Soglie in `domain.conf`** — `SLOW_MS` è definito **due volte con valori diversi** (200 in `gc_stats.awk:7`, 2000 in `service_times.awk:12`): corretto nel merito, ma il nome identico suggerisce una costante condivisa che non esiste. Altre soglie inline e senza nome: `>=1000` (`filter_ip`), `>=5000` (`slow_requests`), `>=85`/`>=70` (`gc_stats`), `>=30`/`>=10` (`correlate_gc_slow`). Portarle in `domain.conf` con nomi espliciti (`GC_PAUSE_WARN_MS`, `SVC_TIME_WARN_MS`…) le rende anche tarabili per ambiente senza editare gli `.awk`. | Media |

---

## OBS — Osservabilità (logging di performance, 2026-08-06)

| ID | Descrizione | Stato |
|----|-------------|-------|
| OBS-1 | **Log di query e performance** — `log_query()` in `chatbot.sh` scrive 13 colonne TSV (query, tool, tempi per fase, volumi, worker) in `QUERY_LOG_DIR`, default `<dir chatbot.sh>/logs`. `perf-report.sh` aggrega per tool (mediana/p95), scompone le fasi, elenca le query più lente, mostra il tempo per MB. | **Fatto** (2026-08-06) |
| OBS-2 | **Metriche di fase per tutti i tool** — `dispatch_tool` è un wrapper che misura e delega a `_dispatch_tool_run`; `open_logs_for` emette le proprie metriche via file (gira in subshell). | **Fatto** (2026-08-06) |
| OBS-3 | **Verificare la copertura effettiva su tutti i 14 tool** (richiesta utente 2026-08-06) — alcuni rami del `case` in `dispatch.sh` non passano da `open_logs_for`: `tail_named_log`/`grep_named_log` nel ramo `find` diretto (`:442-452`, `:492-502`), `show_help`, `list_logs`. Potrebbero riportare `PERF_SELECT_MS=0` o metriche assenti, rendendo la scomposizione muta proprio dove servirebbe. Verifica tool per tool, poi fix se necessario. | **Alta — richiesta utente** |
| OBS-4 | **Metodologia di misura sul server** — il nodo di produzione ha varianza **4×** sulla stessa operazione (5s→20s, load average 3-8 variabile). Ogni misura richiede: snapshot statico dei log (sono in scrittura attiva), round **interlacciati** A/B/A/B, mediana su ≥5 campioni. Round singoli hanno prodotto conclusioni **invertite** 3 volte il 2026-08-06. | Nota permanente |

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
| NLOG2-4 | Mismatch semantico vocabolario ↔ whitelist: il classificatore instradava su `tail_named_log` per qualsiasi `<nome>.log`, ma `param-extract.sh` risolveva `NAMED_LOG` solo dai nomi in `APP_LOG_NAMES` → per i 12 log reali fuori whitelist (`policysearch`, `concurrentDataChangeExceptionLog`, `inbound_mq_messages`, …) l'utente riceveva `[SKIP]` e doveva ripiegare sul glob | **Fatto** (2026-08-04) — vedi LOGF-10/11 |
| NLOG2-5 | **Tool "lista log"** — spostato in NEXT-1 | **Fatto** (2026-08-05) |

---

## NEXT — Prossima sessione (pianificato 2026-08-04)

Due lavori concordati con l'utente, da fare insieme perché condividono il retrain e toccano
gli stessi file. Nessuno dei due richiede modifiche alla topologia della rete.

### NEXT-1 — Tool "lista log" — **Fatto** (2026-08-05)

**Obiettivo.** Mostrare all'utente quali log può nominare, invece di lasciarglielo scoprire per
tentativi. Complemento di LOGF-11: `suggest_available_logs()` dice "ecco cosa c'è" *quando hai
sbagliato*, questo lo direbbe *su richiesta* ("che log ci sono?", "quali log posso vedere").

**Decisioni prese con l'utente:**
1. **Nuova classe** `list_logs` (non estensione di `show_help`): "cosa so fare" (capacità
   statiche) e "cosa c'è su questo nodo" (stato del filesystem) sono due domande diverse.
   Topologia `108,48,15` → `111,48,16` (3 feature nuove + 1 classe nuova), retrain con pesi
   da zero.
2. **Include access/server/gc**, in **sezioni separate** perché si nominano con sintassi
   diversa (`LOG_TYPE`, non `NAMED_LOG`): elencarli insieme senza distinguere suggerirebbe una
   sintassi che per loro non funziona.
3. **Richiede il contesto env/nodo**: coerente col resto del chatbot.

**Il problema misurato**: le query naturali («che log ci sono») avevano **vettore zero** —
non classificabili — e due varianti collidevano con classi esistenti (`elenco dei log
disponibili` → `tail_log` 85%, `lista dei log` → `show_help` 98%). Indagando le due collisioni
attese la mappa reale era diversa da quella ipotizzata: `show_help` non richiedeva nessuna
modifica (`che.*analisi` richiede la sottostringa letterale "analisi", assente in tutte le
query candidate); la vera collisione con `search_all_logs` non era `in.quali.log` (innocuo) ma
`tutti.i.log`, che scattava a peso 2 su «elenca tutti i log del nodo». Fix a costo minimo:
`tutti.i.log` → `in.tutti.i.log`. Verificato ricalcolando la feature sull'intero dataset
normalizzato: **0 divergenze su 1026 query** esistenti — rischio zero, misurato non stimato.

**Implementazione:**
1. `unigrams.txt`/`bigrams.txt` — 2 unigram + 1 bigram nuovi in append (108 → 111 feature,
   indici esistenti invariati), tutti verificati a **0 falsi positivi sui 1026 esempi
   preesistenti** prima di scrivere il codice. Il bigram (patternA = forma interrogativa sul
   contenitore, patternB = predicato di esistenza) sfrutta che `ci.sono` non matcha `c'è`:
   la distinzione «quali log **ci sono**» (list_logs) vs «in quali log **c'è** X»
   (search_all_logs) è quasi tutta lì.
2. `queries_labeled.txt` — 34 esempi `list_logs` + **10 negativi di confine** (5 `show_help`,
   5 `search_all_logs`), di cui 3 deliberatamente ostili (attivano le nuove feature ma
   restano della classe corretta) per insegnare il confine alla rete invece di nasconderlo.
   3 esempi iniziali (`"che log sai leggere"`, `"quali tipi di log sai analizzare"`, `"quali
   log riesci ad analizzare"`) risultavano a **vettore zero** al primo `build-dataset.sh` —
   inutilizzabili per il training — e sono stati riformulati per aggrapparsi a pattern
   `show_help` esistenti (`cosa.sai`, `quali.log.sai`) mantenendo l'intento del confine.
3. `dispatch.sh` — estratto l'helper `_log_names_in_dir()` da `suggest_available_logs()`
   (che oggi aveva il `find | sed | grep | sort -u` inline), condiviso con la nuova
   `list_available_logs()` così l'elenco "su richiesta" e quello "hai sbagliato nome" non
   divergono. `list_available_logs()`: sezione Guidewire (nomi dal disco) + sezione log di
   sistema (verifica esistenza dei basename `ACCESS_LOG_BASE`/`SERVER_LOG_BASE`/`GC_LOG_BASE`
   da `system.conf`, indicando come si chiedono). **Bug trovato in fase di test**: `find -maxdepth
   1 -name "gc*"` matchava anche la *directory* stessa se il suo basename iniziava per `gc`
   (qui la fixture di test si chiamava `gc`), dando un falso "presente" — fix con `-type f`.
4. `domain.conf` — `NUM_TOOLS` 15→16, `list_logs` in coda a `TOOL_NAMES` (la posizione è
   l'indice del neurone di output), nuova categoria help "Esplora log del nodo".

**Retrain**: 1070 esempi (1026+44), topologia `111,48,16`, MSE 0.001033, exact_match 98.5%,
F1 0.990. Verificato con `--dry-run` su tutte le query di confine incluse le 2 ostili: tutte
instradano correttamente (95-100%), nessun bisogno del piano B (bigram di disambiguazione
già progettato ma non servito).

**Diff-check pre-training**: confrontando `queries.txt` prima/dopo, le righe preesistenti
dovevano differire solo per le 3 colonne nuove (a zero). Il primo controllo segnalava 298
righe diverse — falso allarme dovuto a un bug di indicizzazione nello script di verifica (il
bigram nuovo, appeso in coda a `bigrams.txt`, è all'indice 110 non 103): corretto lo script,
**0 righe realmente diverse**. Le regex erano corrette come da analisi statica preliminare.

Test: `run-tests.sh --level1` 61→**74 PASS**; `test-param-extract.sh` **49 PASS** (invariato,
verifica che il refactor di `suggest_available_logs()` non abbia introdotto regressioni);
`test-normalize-parity.sh` **1070/1070**; `test-train-regression.sh` checksum rigenerati
(`29ad3a62…`/`5415c807…`, topologia `111,48,16`), verificati bit-identici su 3 run.

### NEXT-2 — "Prime righe": direzione head/tail come parametro — **Fatto** (2026-08-05)

**Obiettivo.** Supportare `"prime 10 righe del cc.log"`, prima non gestito (zero esempi nel
dataset con "prime").

**Decisione presa: un parametro, NON nuovi tool.** Scartata l'ipotesi `head_log` /
`head_named_log`:
- il classificatore non deve imparare una distinzione che si estrae dal testo — `"prime"` vs
  `"ultime"` è la *direzione*, come `TAIL_N` è la *quantità*. Stesso ragionamento che ha
  portato a `<LOGFILE>`: non moltiplicare le classi per informazione parametrica;
- due classi in più avrebbero richiesto retrain di topologia e, in prospettiva, esplosione
  combinatoria (head+named, head+glob, …);
- il precedente nel progetto: `tail_log` già legge access **o** server log secondo `LOG_TYPE`,
  senza chiamarsi `access_or_server_tail_log`. Convenzione implicita: il nome dice il *tipo di
  analisi*, i parametri dicono le varianti.

**Decisione presa: nessuna rinomina.** Valutato `htail_log`/`htail_named_log` e scartato —
misurato il costo: **~24 file** e **134 righe di label nel dataset**, perché i nomi dei tool
sono le label di training e l'ordine dell'output layer in `domain.conf:TOOL_NAMES` (la
posizione determina quale neurone rappresenta quale classe). Beneficio puramente nominale.

**Implementazione:**
1. `param-extract.sh` — nuovo `LOG_ORDER` (`head` se la query dice `\bprim[ei]\b`/
   `iniziali`/`all.inizio`, altrimenti `tail`). Stesso schema di `TAIL_N`.
2. `lib/tools/tail_log.awk` e `tail_named_log.awk` — nuovo `-v order="head|tail"`. Con `head`
   si stampa non appena si raggiungono `tail_n` righe ed esce (`exit` nella regola principale),
   **senza** il buffer circolare `buf[count % n]`: niente lettura del resto del file (su
   `cc.log` sono ~500.000 righe).
3. `dispatch.sh` — `-v order="${LOG_ORDER:-tail}"` propagato in tutti e 6 i punti di invocazione
   dei due tool (4 rami di `tail_log`, 2 di `tail_named_log` inclusa la variante glob).
4. `TOOL_DESC` in `domain.conf` (profili `liquido` e `usnext`) — descrizione aggiornata con
   esempio "prime/ultime N righe", scopribile via `show_help`.
5. 12 esempi labeled con "prime N righe" per le classi esistenti (`tail_log`/`tail_named_log`,
   incluso un caso con glob quotato) → dataset 1014→1026, retrain ordinario, topologia invariata
   `108,48,15`. Modello migliorato rispetto al precedente: MSE 0.001223→0.000908, exact_match
   98.1%→98.4%, F1 0.988→0.990.

**Decisione presa in implementazione**: con `head`, il filtro temporale (quando presente) filtra
le righe *prima* del conteggio head — quindi seleziona le prime righe **dentro la finestra**,
non le prime del file, coerente con `tail`. Verificato in `tail_log.awk`: il check
`time_from/time_to` con `next` avviene prima del branch `head_mode`. `tail_named_log.awk` non ha
mai avuto filtro temporale (nessun cambiamento in merito).

**Gap noto, lasciato aperto di proposito**: `\bprim[ei]\b` copre solo il plurale ("prime
righe"). "Prima" singolare non è incluso — in italiano è ambiguo tra ordinale ("prima riga" →
head) e temporale ("successo prima" → before), e zero query nel dataset lo usano nel senso
ordinale. Documentato come test in `tests/test-param-extract.sh` per evitare regressioni
accidentali che lo aggiungano senza dati a supporto.

Suite: `run-tests.sh --level1` 57→**61 PASS**; `test-param-extract.sh` 43→**49 PASS**;
`test-normalize-parity.sh` **1026/1026**; `test-train-regression.sh` checksum rigenerati
(`c36f4a0e…`/`2aab4849…`, dataset cambiato) e riverificati bit-identici su 3 run.

---

## LOGF — Generalizzazione dei nomi di log (2026-08-04)

Il vocabolario conteneva l'alternanza esplicita dei 15 nomi di `APP_LOG_NAMES` più 7 feature
per-nome (`api`, `\bdatabase\b`, `jgroups`, …): il classificatore *conosceva* i log del
cliente. Come nota l'utente, `jgroups` esiste solo per applicazioni con cache distribuita —
inciderlo nei pesi lega il modello a un singolo deployment, mentre il modello deve
sopravvivere al cambio di cliente. Costo già misurabile: sul nodo di produzione i log sono
**28**, la whitelist ne copriva 16, di cui 2 con nome sbagliato (`performance_integr` vs
`performance_integrations`, `plugin` vs `plugins`); 15 log reali erano irraggiungibili. E un
nome nel vocabolario è fragile: `ccCanaliz` aveva smesso di funzionare per un problema di
maiuscole.

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGF-1 | **Placeholder `<LOGFILE>`** in `normalize-query.sh` (nuova sezione 3.5, fra NODE e APP_SHORT_ALIASES). Sostituisce **qualsiasi** `<token>.log` e i glob quotati — non una whitelist: una lista limiterebbe la generalizzazione ai soli nomi noti. Esclusi i 3 log di infrastruttura (`ACCESS_LOG_BASE`/`SERVER_LOG_BASE`/`GC_LOG_BASE` da `system.conf`), che hanno tool dedicati. Vincolo d'ordine: dopo la sezione 1 (un nome app completo vince), prima della 4 (`\bcc\b` matcha dentro `cc.log` e produrrebbe `<APP>.log`) | **Fatto** |
| LOGF-2 | **`DETECTED_APP` preservato** quando il nome del log è anche uno short-alias di app (`cc`→claimcenter, `cm`→contactmanager): serve a `resolve-logs.sh` per costruire la directory Guidewire. Data-driven da `APP_SHORT_ALIASES`, non hardcoded | **Fatto** |
| LOGF-3 | **Vocabolario**: 6 righe con nomi concreti rimosse, sostituite da **una** riga `<logfile> :: 2`; `patternA` dei 2 bigram → `<logfile>`. Con le parentesi angolari, non `\blogfile\b` (matcherebbe la parola digitata dall'utente). **114 → 108 feature** | **Fatto** |
| LOGF-4 | **Dataset**: 22 esempi riformulati con `.log` esplicito (`"database log"` → `"database.log"`, `"performance delle integrazioni nel log"` → `"…nel performance_integrations.log"`) perché senza le feature per-nome producevano un vettore identico a query `tail_log` di classe diversa. Aggiunti **6 esempi con glob quotato**, prima assenti: il ramo glob era testato ma non addestrato. Le 6 query anaforiche (`"warn nello stesso log"`) intatte — usano `ACTIVE_NAMED_LOG` | **Fatto** |
| LOGF-5 | **`cm` aggiunto a `APP_LOG_NAMES`**: `cm.log` esiste realmente (`prod2nssi-cm.log` in `*/ContactManager/Guidewire/`), non è solo un alias | **Fatto** |
| LOGF-6 | **Glob e rotazione**: la validazione richiedeva `.log` **finale**, ma i ruotati sono `…-cc.log-2026-07-26-<epoch>.gz` con `.log` in mezzo → il glob non raggiungeva alcuno storico. Ora la regex ancora `\.log([-.]…)?$`, che accetta le forme ruotate e rifiuta `.logico` | **Fatto** |
| LOGF-7 | **Finestra temporale nel ramo glob**: faceva `find \| head -1`, ignorando `TIME_FROM`/`TIME_TO`. Ora passa da `select_log_files()` (`utils-logfiles.sh`), l'unica implementazione del filtro temporale, così "righe di ieri" seleziona la rotazione giusta. Filtro per **nome logico esatto**: `select_log_files` cerca `BASE*`, quindi `prod1nsse-cc` matcherebbe anche `prod1nsse-ccCanaliz.log` | **Fatto** |
| LOGF-8 | **Disambiguazione multi-match**: `"*cc*.log"` matcha 4 log distinti e prima ne veniva scelto uno con `sort \| head -1` silenzioso. Ora `resolve_log_glob()` raggruppa per nome logico e, se i gruppi sono ≥2, stampa un elenco numerato in giallo con il pattern suggerito per restringere. Nessun prompt interattivo (romperebbe `--query` e i test); il tool procede col non-ruotato | **Fatto** |
| LOGF-9 | **`_logfiles_read_first_ts` non riconosceva il formato Guidewire** (`[thread] USER 2026-08-04T15:50:01,443 INFO`: ISO8601 non fra parentesi quadre e non a inizio riga) → **ts_start=0 per tutti i log Guidewire**, quindi il filtro temporale non poteva discriminarli, né per il glob né per i named log. Difetto preesistente, emerso testando le rotazioni. Aggiunto un quarto pattern, in coda perché il ramo GC è più specifico | **Fatto** |

| LOGF-10 | **`NAMED_LOG` risolve qualsiasi `<token>.log`**, non solo i nomi in `APP_LOG_NAMES`: quella è una lista di **alias** (scorciatoie usabili senza estensione, es. `"errori nel cc"`), non di log **ammessi**. Usa il case ORIGINALE (`$1`, non `$query` lowercase) perché i nomi reali hanno maiuscole (`ccJBatch`, `JF4U_TRACKING`, `concurrentDataChangeExceptionLog`) e finiscono in `find -name`, case-sensitive. Validazione anti-traversal e esclusione dei log di infrastruttura anche sul fallback. Chiude NLOG2-4 | **Fatto** |
| LOGF-11 | **`suggest_available_logs()`** in `dispatch.sh`: quando un log non esiste, elenca quelli **realmente presenti** sul nodo (l'avviso di `param-extract.sh` mostra gli alias di `entities.conf`, che divergono dal disco — `plugin` in whitelist contro `plugins` reale). Se un nome simile esiste lo evidenzia (`plugin` → `plugins.log`): l'errore tipico è un refuso. Scarta i nomi non digitabili — sul nodo esiste `${gw.cc.serverid}-messaging.log`, un placeholder Guidewire non risolto | **Fatto** |

| LOGF-12 | **Avviso di incoerenza `NAMED_LOG` ↔ tool**: se la query nomina un log ma nessuno dei tool attivati lo legge (`"errori di cluster nel jgroups log"` → `filter_errors`, che apre `server.log`), l'utente riceveva dati plausibili dal file sbagliato in silenzio. `chatbot.sh` ora avvisa e mostra la sintassi corretta. L'incoerenza è rilevabile **solo** in `chatbot.sh`, dove si conoscono sia `NAMED_LOG` sia i tool scelti. Introdotto `LOG_EXPLICIT` (non persistente, come `TIME_EXPLICIT`) per distinguere "nominato in questa query" da "ereditato da `ACTIVE_NAMED_LOG`": senza, dopo una query sul jgroups ogni query successiva avrebbe mostrato l'avviso | **Fatto** |
| LOGF-13 | **`[SKIP]` in giallo** (`skip_msg()` in `dispatch.sh`): erano testo bianco identico all'output normale e si perdevano fra le righe di log. 11 occorrenze convertite; un test verifica che non ne resti nessuna con `echo` diretto, così una futura aggiunta non sfugge alla colorazione | **Fatto** |

| LOGF-14 | **Elenco dei log in colonne**: `suggest_available_logs` stampava i 27 nomi su una riga sola (~470 caratteri), che il terminale spezzava dove capita tagliando i nomi a metà (`Card_` / `denunce_…`). Ora `column -c` + `expand` — **non** `column -t`, che formatta una tabella da input già colonnato e produce una sola colonna; e senza `expand` i TAB di `column` disallineano tutti i nomi oltre 8 caratteri. Fallback a 3 colonne fisse se `column` manca | **Fatto** |
| LOGF-15 | **`UNRESOLVED_LOG` rimosso** (3 punti in `param-extract.sh`, 4 in `chatbot.sh`, asserzioni nei test): da LOGF-10 restava vuoto in ogni caso reale, e `suggest_available_logs()` fa lo stesso lavoro guardando i **file del nodo** invece degli alias di `entities.conf` — informazione più accurata, perché la configurazione può divergere dal disco. Un test verifica che non venga più emesso, così un ripristino accidentale non passa inosservato | **Fatto** |
| LOGF-16 | **Validazione `NAMED_LOG`**: richiede almeno un carattere alfanumerico. `"..log"` produceva base `.` e `"-.log"` produceva `-`, che passavano la whitelist. Innocui per `find -name` (verificato: 0 risultati, il valore è un pattern di *nome*, non un path) ma privi di senso | **Fatto** |

**Feature `api` mantenuta.** Il piano la elencava fra i nomi da rimuovere, ma sta nella sezione
*Endpoint / URL* e significa *endpoint HTTP*: serve a 17 esempi `distribute_status` ed è
l'**unica feature attiva** di `"quali api hanno più fallimenti"`, che senza di essa resterebbe
a vettore zero. Classificata male perché coincide lessicalmente con `api.log`.

**Retrain**: 1014 esempi, 108→48→15, early stopping epoca 1263, MSE **0.001223**,
exact_match **98.1%**, F1 **0.988** — migliori del modello a 114 feature (0.001320 / 97.7% /
0.986): più snello e generalizza meglio. 0 zero-vector.

**Generalizzazione verificata** su log mai visti in training e assenti dalla whitelist:
`policysearch.log`, `concurrentDataChangeExceptionLog.log`, `inbound_mq_messages.log`,
`controllo_pagamenti.log`, `KPI_METADATI_TRACKING.log`, `pc1nssprod.log` → tutti
`tail_named_log`/`grep_named_log` al 97-99%.

**Conseguenza accettata (non un difetto).** Le query che nominano un log **senza** `.log`
(`"ultime righe del database log"`) sono ora indistinguibili da `"ultime righe del log"`:
sono entrambe sottospecificate, e il vettore identico rappresenta fedelmente quella vaghezza.
Chi vuole un log preciso lo identifica — `database.log` o `'*database*.log'`.

**Nota architetturale.** `infer.sh` non funziona più da solo sui named log: la feature si
attiva sul placeholder, che esiste solo dopo `normalize-query.sh`. È il prezzo — corretto — di
aver spostato conoscenza dal modello alla pipeline. `run-tests.sh` esporta già `NORM_QUERY`
(NLOG-4), quindi misura il path reale.

**`APP_LOG_NAMES` resta usata solo in `param-extract.sh`** per risolvere `NAMED_LOG` → file:
la conoscenza dei nomi è uscita dai *pesi* e resta nella *configurazione*, versionabile per
profilo senza retrain. Non abbiamo eliminato la whitelist: l'abbiamo tolta dai pesi.

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
| DEDUP-1 | **Normalizzazione ID numerici in chiave dedup** — `WorkItemPeriodicWork_Ext:1778994` e `:1778995` sono deduplicati separatamente perché l'ID è parte del messaggio. Normalizzare la chiave rimuovendo numeri/UUID ridurrebbe il rumore ma nasconderebbe quanti WorkItem distinti sono bloccati | **Chiuso: non si fa** (2026-08-04) |

**Perché non si fa.** Deciso di non implementarlo: aggiungerebbe confusione senza risolvere un
problema reale. Il conteggio degli ID distinti è **informazione diagnostica**, non rumore — è
il dato che dice se sono bloccati 2 WorkItem o 200, e la gravità dell'incidente dipende
proprio da quello. Le alternative valutate (opzione configurabile, soglia minima, solo in
modalità summary) aggiungerebbero un parametro in più da spiegare e ricordare, per nascondere
un dato che serve.

Se in futuro il rumore diventasse un problema concreto (es. un log con migliaia di ID distinti
in poche righe di output), la strada da valutare non è normalizzare la chiave ma **aggregare
nel footer** — "42 WorkItem distinti" invece di 42 righe — così il conteggio resta visibile e
l'output no. Riaprire solo con un caso reale in mano, non in astratto.

---

## Note architetturali — cosa NON fare

- **No wrapper sh per ogni tool.** Aggiungere `filter_errors.sh` → `gawk -f ...` non porta valore: la composizione è già in `dispatch.sh` e si perderebbe la testabilità diretta del singolo `.awk`.
- **No mega-framework.** Tre utility file bastano per eliminare tutta la duplicazione identificata.
- **Preservare la testabilità diretta** di ogni tool: `gawk -f utils-time.awk -f filter_errors.awk server.log` deve continuare a funzionare.
