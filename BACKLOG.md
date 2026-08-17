# Backlog — neural-log-analyzer

Aggiornato: 2026-08-17

---

## ⏭ APERTI

| ID | Descrizione | Priorità |
|----|-------------|----------|
| CLEAN-1 | **`list_env_app_dirs()` (`utils-nodes.sh:50-58`) è codice morto**: zero chiamanti (verificato 2026-08-17), ed è l'ultimo consumatore di `APP_SUBPATH` dopo LOGDISC-4. Rimuoverla renderebbe `APP_SUBPATH` config non più usata da alcun percorso di risoluzione — da valutare se togliere anche quella da `system.conf` o tenerla come documentazione del layout tipico. Non fatto in LOGDISC-4 per non mescolare un cleanup con una modifica di comportamento | Da valutare |
| FORMAT-1 | **Il formato delle righe di access log è cablato nel codice, non in config**: `parse_access($2)` in **8 tool** assume che il timestamp sia il 2° campo. Un middleware con formato *combined* (`%h %l %u %t`, timestamp in `$4`) non darebbe errore — `parse_access` restituirebbe 0, e con `ts=0` il codice è conservativo, quindi **il filtro temporale smetterebbe di filtrare in silenzio**. I *nomi* dei log sono già in `system.conf` (ARCH-6), il *formato* no. Vedi sezione dedicata | Da valutare |
| PROF-1 | **`profiles/usnext` è nel repo ma non è utilizzabile**: non definisce `ACCESS_LOG_BASE`/`SERVER_LOG_BASE`/`GC_LOG_BASE` (0 occorrenze) né `SYSTEM_LOG_SYNONYMS`, quindi `resolve-logs.sh:81-86` aborta con `[ERROR] ACCESS_LOG_BASE non impostato`. Nulla lo segnala: sembra un profilo alternativo funzionante. Da decidere se **completarlo** (serve conoscere i nomi log reali di quel middleware — informazione che non è nel repo) o **rimuoverlo** per non lasciare codice morto che simula una generalizzazione non verificata. Trovato durante l'audit di LOGDISC-4 | Da valutare |
| DEPLOY-1 | **`deploy.sh` non ha `--delete`, e non può averlo senza una verifica di identità della directory target** (deciso 2026-08-17). Conseguenza attuale: i file rimossi in locale, o trasferiti per errore da un deploy passato, **restano** in produzione — oggi `CLAUDE.md` e `.claude/` copiati prima che le esclusioni esistessero (inerti, nessuno script del bot li legge). La rimozione manuale è stata **esplicitamente rifiutata dall'utente**: un `rsync --delete`, o un `rm` su `${HOST}:${DEST}`, cancella ricorsivamente qualunque directory gli venga passata — un `--dest` sbagliato, un `DEST` vuoto o un typo diventano una cancellazione in produzione, e il dry-run non protegge chi lancia il comando senza. Prerequisito per implementarlo: un **sentinel di identità** — `deploy.sh` verifica sul target la presenza di un marcatore noto (es. `chatbot.sh` + `profiles/`, o un file `.lana-bot-root` scritto dal deploy stesso) e rifiuta di procedere se manca, *prima* di qualsiasi operazione distruttiva. Finché non c'è, il deploy resta additivo per scelta: file residui sono rumore, una cancellazione sbagliata è un incidente | Da valutare |
**Chiuso il 2026-08-17**: LOGDISC-4 (log di sistema scoperti sotto il nodo, validazione
per-tool, bug `require_app` — vedi sezione dedicata), LOGDISC-2 (ricorsione in `search_all_logs` + colonna APP, vedi
sezione dedicata).

**Chiuso il 2026-08-07**: LOGDISC-1 (ricerca ricorsiva log sotto il nodo, vedi sezione dedicata),
LOGDISC-3 (bug collegati a LOGDISC-1, vedi sezione dedicata), LOGSEL-1 (misrouting +
falso positivo silenzioso sugli errori nell'access log, vedi sezione dedicata).

**Chiuse il 2026-08-06**: OBS-3 (copertura logging), OBS-5 (feedback progressivo nei 3 tool
mancanti), UI-11 (sistema di temi colore, default `mono` a zero ANSI), SRCH-1 (ricerca
testuale in un log nominato), P3/P4/P5/P6/P8 (performance applicate), P7 e P9 (chiusi: nessuna
ottimizzazione applicabile / peggiorativa), O6 (medie sulle righe misurabili), UI-13 (soglie
dei colori configurabili), UI-12 (ruoli semantici nei tool).

**La performance non è più un tema aperto.** Tutti i tool sopra il secondo sono stati
analizzati; di quelli restanti si sa *perché* costano — 77% del tempo è parsing AWK
proporzionale al volume, throughput 15.4 MB/s su 57 MB medi per query. Nessun difetto
strutturale residuo, solo lavoro irriducibile. Il logging (`OBS-1`) continua ad accumulare
dati: se un tool risalisse in classifica con più campioni, si riapre allora — con la
metodologia di `OBS-4` (snapshot statico, round interlacciati, mediana su ≥5 campioni).

**NON si fa qui**: `MIGR` — migrazione dell'orchestrazione a Python. **Un agent separato ci
sta già lavorando** (2026-08-06) in `../neural-log-lanalyzer`. Non aprire lavoro di
migrazione in questo repository: qui si continua a correggere e migliorare il comportamento,
che è il riferimento da cui quel progetto parte.

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
| SRCH-1 | Scelta la via (a): `grep_named_log` riceve `SEARCH_PATTERN` da `dispatch.sh`. Si è rivelato **molto più piccolo del previsto** — il canale esisteva già ai due estremi ma non era collegato: il tool AWK accettava già `-v pattern` (sua riga 5), `param-extract.sh` estraeva già `SEARCH_PATTERN`, il classificatore instradava già al 96.7%, e `TOOL_DESC` diceva già "o pattern testuale". **Nessun retrain, nessuna nuova classe.** Semantica: pattern senza livello nominato → `level=ALL` (l'intento è trovare quel testo); livello nominato → vince quello. Ha richiesto `LEVEL_EXPLICIT` in `param-extract.sh` per distinguere "livello chiesto" da "default applicato" — stesso pattern di `TIME_EXPLICIT`/`LOG_EXPLICIT`. 15 test in `tests/test-srch-named-log.sh` | **Fatto** (2026-08-06) |

---

## LOGDISC — Ricerca ricorsiva sotto il nodo (bug segnalato in produzione, 2026-08-07)

Bug reale: con contesto su prod/nodo 3, «ultime 50 righe del access.log» rispondeva «non
trovato», suggerendo `cc.log`. Causa: `tail_named_log`/`grep_named_log` in `dispatch.sh`
passavano **solo** `GUIDEWIRE_LOG_DIR` a `resolve_named_log_path()`/`open_glob_logs()`, mentre
`undertow_access_log.log` vive in `ACCESS_LOG_DIR`, una directory sorella sotto lo stesso nodo.

**Decisione architetturale (utente)**: il profilo garantisce la risoluzione solo **fino alla
directory del nodo** (`LOG_SEARCH_ROOT`); sotto, la struttura è ignota per contratto e va
**scoperta** ricorsivamente, non enumerata — un nuovo profilo può non avere Guidewire, o
organizzare i log diversamente. Documentato come principio 6 in CLAUDE.md.

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGDISC-1 | **`resolve_log_glob()` (`utils-logfiles.sh`) diventa ricorsivo** (rimosso `-maxdepth 1`, aggiunto `\( -type f -o -type l \)` per escludere directory-trappola come `archive.log/`). Tie-break deterministico: app di sessione (`ACTIVE_APP`) > file non ruotato > path più corto > alfabetico. `resolve_named_log_path()` (`dispatch.sh`) sostituisce le 3 catene `find -maxdepth 1` duplicate con 3 chiamate in cascata a `resolve_log_glob`, centralizzando la policy di disambiguazione. `open_glob_logs()` raggruppa le rotazioni dalla `dirname` del file scelto (flat), non dalla root — **ricorsione per la scoperta, flat per le rotazioni**. `resolve-logs.sh` esporta `LOG_SEARCH_ROOT` (= `NODE_DIR`). Nessun cross-app silenzioso: se un log esiste solo sotto un'altra app, `skip_named_log_not_found()` dice "non trovato" e suggerisce quell'app, invece di aprirlo o di restare muto. `_log_names_in_dir()` diventa ricorsiva e non filtrante; il filtro dei basename di sistema (access/server/gc) si sposta a valle in `list_available_logs()`, tramite il nuovo helper condiviso `_is_system_log_base()` (anche in `param-extract.sh`, eliminando una duplicazione preesistente). 17 test in `tests/test-log-discovery.sh` + 1 nuovo in `tests/test-dispatch-perf.sh` (ricerca multi-livello); fixture di `test-dispatch-perf.sh` isolate per sezione (la ricorsione avrebbe fatto leakage tra sezioni condivise) | **Fatto** (2026-08-07) |

**Asimmetria chiusa il 2026-08-17**: vedi la sezione LOGDISC-2 qui sotto — `search_all_logs.sh`
era rimasto enumerativo, quindi trovava per nome log che non cercava per contenuto.

---

## LOGDISC-2 — Ricorsione in `search_all_logs` + colonna APP (2026-08-17)

Ultimo tool a violare il **principio 6**: enumerava 4 directory fisse costruite da
`APP_SUBPATH`/`CUSTOM_LOG_SUBPATH`, quindi un log in una directory arbitraria
(`weird/deep/nested/custom.log`) era **nominabile** con `tail_named_log` ma invisibile a
"in quali log c'è X".

**La misura che ha sbloccato la decisione** (nodo `lxprjbliq04`, in produzione — non stimata):
8 directory sotto il nodo, profondità max 3, `find` ricorsivo **0.01 s** su 3 round. Il costo
di scoperta è irrilevante contro i ~83 s di una query reale (P4).

**Errore di valutazione corretto durante l'analisi** (vale come lezione di metodo): una prima
valutazione concludeva che la ricorsione fosse neutra, perché scopre "le stesse 4 directory che
l'enumerazione già visita". Falso: confrontava la **cardinalità** degli insiemi, non la loro
**identità**. Le 4 directory sono 2 di ClaimCenter (185 MB) e 2 di ContactManager (118 MB) —
con `ACTIVE_APP=ClaimCenter` l'enumerazione visitava solo le prime due. Stesso errore di UI-12
("dedotto contando gli usi senza leggere le condizioni") e di P9. Il volume scansionato
**raddoppia** (185 → 303 MB): conseguenza accettata della decisione sotto, non effetto
imprevisto.

**Decisione utente**: cercare in **tutte** le app del nodo, con una **colonna APP** che
dichiara la provenienza — non filtrare per app di sessione. Il tool si chiama
`search_ALL_logs` e il suo `TOOL_DESC` promette "tutti i log del nodo". Il principio 6 vieta
di mescolare app **senza dirlo**: il vincolo è la trasparenza, non l'esclusione.

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGDISC-2a | **`discover_log_dirs ROOT`** in `utils-logfiles.sh`: emette le directory che *contengono* log sotto ROOT, a qualsiasi profondità, deduplicate. `-iname '*.log*'` (non `*.log`) perché una directory con sole rotazioni compresse va scoperta comunque (principio 5); `\( -type f -o -type l \)` prima del match esclude le directory-trappola tipo `archive.log/`. **`select_log_files_grouped` resta flat** (`-maxdepth 1`): ricorsione per la scoperta, flat per le rotazioni — la regola di LOGDISC-1, non toccata. Funzione sorella di `_log_names_in_dir()` (emette nomi logici invece di directory) | **Fatto** |
| LOGDISC-2b | **`resolve_app_from_path PATH`** in `utils-logfiles.sh`, data-driven da `AVAILABLE_APPS` (liquido 2 app, usnext 3 diverse — nessun nome nel codice, principio 7). **La logica esisteva già inline** in `_find_named_log_elsewhere` (`dispatch.sh`), che ora la chiama: centralizzata *migrando* il chiamante, non creando una seconda copia (principio 8 — l'errore che ha prodotto i 4 bug di LOGDISC-3). Match sul **segmento** `/app/`, quindi `ClaimCenterX` non matcha `ClaimCenter` | **Fatto** |
| LOGDISC-2c | **I due rami di `search_all_logs.sh`** (nodo singolo e multi-nodo) si riducono a iterare `discover_log_dirs` + `_sal_add "$dir" "" "$nodo"` — `base` sempre vuoto, il ramo che già serviva i log custom in cartella flat. Helper locale `_sal_scan_root` per il ciclo comune. **Contratto ridotto**: `LOG_SEARCH_ROOT` sostituisce `ACCESS_LOG*`/`SERVER_LOG*`/`GC_LOG*`/`CUSTOM_LOG_DIR`/`CUSTOM_LOG_SUBPATH`/`APP_SUBPATH` negli export di `dispatch.sh` — quelle variabili nominavano directory note, l'assunzione che questo lavoro rimuove. Il messaggio "nessun log disponibile" ora dice **dove** ha cercato: un `LOG_SEARCH_ROOT` vuoto produrrebbe altrimenti un silenzio indistinguibile da "il nodo non ha log" (stesso falso negativo di LOGSEL-1) | **Fatto** |
| LOGDISC-2d | **Colonna APP condizionale**, stesso criterio di `_multi_node`: appare solo se i match provengono da più di una app, calcolata sui match **effettivi** (non sulla lunghezza di `AVAILABLE_APPS`). Due ragioni: (1) una colonna col medesimo valore su ogni riga è rumore — la stessa ragione per cui `_node_col_w` è 0 in nodo singolo; (2) `test-search-all-logs.sh` asserisce che `LOG` sia la prima colonna quando non c'è NODO, e una colonna sempre presente romperebbe l'invariante anche nel caso comune. Larghezza `_app_w + 2` (solo gutter, senza prefisso testuale: `ClaimCenter` si spiega da sé, `04` no). Path non attribuibile → `-`, e il file **resta** nei risultati (principio 5) | **Fatto** |

**Verifica**: `bash tests/run-tests.sh` → **86 PASS / 0 FAIL** (invariato). 15 asserzioni nuove
(`test-search-all-logs.sh` 32→41, `test-utils-logfiles.sh` +9 su `discover_log_dirs` e
`resolve_app_from_path`). **Fail-before/pass-after verificato** via `git stash` sul solo codice
di produzione: 27 FAIL + 3 FAIL senza il fix, 0 con — i test misurano il cambiamento, non
passano per costruzione. `--parity` non necessario (`normalize-query.sh` non toccato).

**Fixture isolate**: la sezione "nodo singolo" di `test-search-all-logs.sh` ora punta
`LOG_SEARCH_ROOT` al **nodo specifico**, non a `$_FIX` che contiene anche il nodo 12 — con la
ricorsione avrebbe letto i file dell'altra sezione (stesso leakage già risolto in
`test-dispatch-perf.sh` durante LOGDISC-1).

### Verifica in produzione (nodo 4, 2026-08-17) — il gap era più grande del previsto

Query `cerca "NullPointerException" nel nodo 4`, misurata dal query log (colonne
7-12: totale/select/search/file/matched/bytes):

| | prima (baseline) | dopo |
|---|---|---|
| file selezionati | 31 | **51** (+65%) |
| occorrenze trovate | — | **2205 in 5 log** |
| totale end-to-end | — | 21.7 s (select 6.5 s, search 13.1 s) |
| volume | — | 212 MB |

**Il difetto era più grave di quanto il backlog stimasse.** L'analisi prevedeva "log in
directory arbitraria non cercabile" come caso di scuola; in realtà su questo nodo la ricerca
enumerativa **non vedeva `prod1nssd-cc.log` né la sua rotazione del giorno**, dove stanno
**2199 delle 2205 occorrenze** (il 99.7%). Prima di questo fix, la stessa query rispondeva su
un sottoinsieme che escludeva quasi tutti i risultati reali — senza dirlo. La colonna APP
mostra anche che 6 occorrenze vengono da ContactManager (`prod2nssd-cm.log`, `console.log`,
`server.log`): dati di un'altra app, ora dichiarati invece che invisibili.

Il costo misurato è coerente con l'atteso (volume ~2×, +20 file), e i 6.5 s di `select` sono
il walk temporale su 51 file, non la scoperta (0.01 s). Nessuna ottimizzazione applicata:
`perf-report.sh` continua ad accumulare dati, si riapre se il tempo diventa scomodo.

---

## LOGDISC-3 — Bug collegati alla centralizzazione di LOGDISC-1 (2026-08-07)

Richiesta esplicita dell'utente dopo LOGDISC-1: *"correggi i bug intanto, mi aspetto che ci
siano altri bug collegati perché stiamo 'centralizzando' le logiche"*. 4 bug reali trovati e
corretti, tutti riconducibili a centralizzazione incompleta o assunzioni duplicate sullo
stesso formato — vedi principio 8 in CLAUDE.md.

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGDISC-3a | `logfile_logical_name()` (`utils-logfiles.sh`) non gestiva la rotazione giornaliera `BASENAME.DATE.log` (data prima di `.log`, es. `undertow_access_log.2026-07-14.log`), nonostante lo schema fosse già dichiarato supportato nell'header. 19 rotazioni giornaliere producevano 19 nomi logici invece di 1. Nuovo ramo `sed` dedicato. | **Fatto** |
| LOGDISC-3b | `_logfiles_sort_key()` aveva lo stesso gap di 3a — assunzione indipendente sugli schemi di rotazione, mai aggiornata insieme. Nuovo ramo che converte la data in epoch reale, comparabile con le rotazioni con epoch esplicito. | **Fatto** |
| LOGDISC-3c | `access.log` (sinonimo digitato dagli utenti) non coincideva col basename esatto `undertow_access_log` (`ACCESS_LOG_BASE`): la query collassava sul fallback generico `<LOGFILE>`/`NAMED_LOG` invece che sul tool dedicato. Inoltre `normalize-query.sh` aveva una copia inline indipendente dello stesso confronto già centralizzato in `_is_system_log_base()` (introdotta in LOGDISC-1), mai migrata. Nuovo dizionario data-driven `SYSTEM_LOG_SYNONYMS` in `system.conf`; `_is_system_log_base()` estesa a consultarlo; `normalize-query.sh` migrato alla funzione condivisa. | **Fatto** |
| LOGDISC-3d | `lib/build_dataset.py` (replica Python di `normalize-query.sh`) non rifletteva né la sinonimia né la migrazione — parità bash/Python a rischio di rottura silenziosa. Aggiunta `system_log_synonyms` in `load_profile()`, usata in `normalize_query()`. | **Fatto** |

**Verifica**: `bash tests/run-tests.sh --parity` → 85 PASS / 0 FAIL, parità confermata su 1070
query (111 feature). 6 nuove asserzioni (`test-utils-logfiles.sh` ×4, `test-normalize-query.sh`
×1, `test-param-extract.sh` ×1), più il caso end-to-end sulla query originale del bug. Dettaglio
completo in `docs/sessions/2026-08-07-02.md`.

---

## LOGSEL-1 — Errori nell'access log: misrouting + falso positivo silenzioso (bug prod, 2026-08-07)

Bug reale: «errori nel access.log di produzione stamattina del nodo 4» rispondeva con righe
prese dal **server.log**, senza alcun avviso. **Non un regresso di LOGDISC-1/3** — quel lavoro
(scoperta file, sinonimia `access` → `undertow_access_log`) funzionava correttamente;
`normalize-query.sh` manteneva già `access.log` letterale. Il difetto era a monte
(classificazione) e a valle (trasparenza), due difetti indipendenti che si sommavano.

**D1 — misrouting.** `access.log` è escluso dalla generalizzazione `<LOGFILE>` (scelta
corretta: ha un tool dedicato), ma questo significa che i due bigram `<logfile>` — i
discriminatori named-log — non si attivano mai su di esso. Restavano solo unigram deboli
(`errore\|errori`, `access\b`, tempo), identici a quelli di `filter_errors` sul server log.
Zero esempi nel dataset per la firma «errore + access log senza status code»: la rete
instradava sull'unica firma nota, strutturalmente identica a meno del nome del log.

**D2 — falso positivo silenzioso (il più grave dei due).** Il ramo `filter_errors` trovava il
server.log, funzionava, e non emetteva alcun indizio: nessun `[SKIP]`, nessun
`print_log_source`. L'utente riceveva dati plausibili dal file sbagliato senza saperlo.
`print_log_source()` esisteva già (creato per `tail_log`) ma non era stato migrato ai tool di
sistema — stesso pattern del principio 8 di `CLAUDE.md` (centralizzare significa migrare
tutti i chiamanti).

**Vincolo dell'utente**: nessuna regola ad hoc per tipo di log («errori = 4xx/5xx» cablato per
l'access log violerebbe il principio di generalizzazione). Se un log non ha il concetto
cercato, il bot lo dice e chiede una stringa da cercare — non una semantica specifica del
formato.

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGSEL-1a | **`print_log_source()` su tutti i tool di sistema** (`dispatch.sh`): prima solo `tail_log`. Estesa a `count_status`, `distribute_status`, `slow_requests`, `traffic_volume`, `filter_errors`, `service_times`, `gc_stats`, `filter_ip`, `filter_app_errors`, `correlate_gc_slow` (due sorgenti, gc+access, entrambe passate in un'unica chiamata). Chiude D2: qualunque misrouting residuo diventa visibile, non silenzioso | **Fatto** |
| LOGSEL-1b | **Firma mancante nel dataset** (D1): 16 esempi multi-label `count_status,distribute_status` per «errore/eccezione/anomalia + access log/log http/log delle richieste + senza status code», in `queries_labeled.txt`. Nessun cambio di vocabolario/topologia (111→48→16 invariata) — solo dataset (1070→1086) e retrain. Routing scelto con l'utente: multi-label, non una nuova classe — conteggio e distribuzione per endpoint sono entrambi risposte valide, e leggono davvero l'access log | **Fatto** |
| LOGSEL-1c | **`grep_named_log.awk`: formato non riconosciuto distinto da "nessuna riga col livello"** — il gate `GW_RE` (timestamp ISO + livello) scartava ogni riga di un log con formato diverso (es. access log Undertow) e stampava `Nessuna riga trovata (level=X)`, indistinguibile da "letto correttamente, nessun errore". Falso negativo silenzioso verificato: il 500 c'era, il messaggio diceva il contrario. Fix generico (nessuna conoscenza del tipo di log): contatore `matched_format` separato da `count`; se `NR > 0` ma `matched_format == 0`, messaggio dedicato con conteggio righe lette e suggerimento di cercare una stringa specifica | **Fatto** |

**Verifica**: `bash tests/run-tests.sh --parity` → 87 PASS / 0 FAIL, parità confermata su 1086
query (111 feature). 2 nuovi casi di routing in `run-tests.sh` (positivo `count_status`,
negativo `!filter_errors`), 2 nuovi in `test-srch-named-log.sh` (fixture con formato non
Guidewire → messaggio distinto + conteggio righe). Cinque confini adiacenti (server.log via
`filter_errors`, access.log via `tail_log`, `cc.log` via `grep_named_log`) riverificati senza
regressione: 0.96-0.9998 di confidenza, invariati rispetto a prima del retrain. Dettaglio
completo in `docs/sessions/2026-08-07-03.md`.

**Perché non è la stessa cosa di LOGDISC-1/3**: quel lavoro garantiva che il file giusto fosse
*trovabile* sotto il nodo; qui il file era trovabile ma la rete sceglieva il tool sbagliato
(D1) e, anche a scelta corretta di un tool diverso dall'atteso, nessuno lo segnalava (D2).
Due livelli diversi della stessa pipeline: risoluzione file vs. classificazione intent vs.
trasparenza dell'output.

---

## LOGDISC-4 — I tool di sistema al contratto "fino al nodo" — **FATTO** (2026-08-17)

| ID | Descrizione | Stato |
|----|-------------|-------|
| LOGDISC-4a | **`resolve_system_log_dir SEARCH_ROOT BASE [REQUIRE_APP]`** (`utils-logfiles.sh`): scopre ricorsivamente la directory del log di sistema, riusando `resolve_log_glob` per ricorsione e tie-break. Cascata a **due** livelli (`${BASE}.log`, poi `${BASE}*`) e non tre come i named log: qui il nome viene da `system.conf` ed è esatto per contratto, un livello fuzzy aggiungerebbe solo falsi positivi. Il 2° livello copre la directory con **sole rotazioni** — escluderla darebbe "non disponibile" su un nodo che ha i dati (principio 5). Emette la directory, non il file: è ciò che i tre `*_LOG_DIR` significano | **Fatto** |
| LOGDISC-4b | **`resolve-logs.sh` riscritta**: `APP_DIR` da template sparisce, con l'abort "app dir non trovata". ⚠️ `ACTIVE_APP="$APP"` **prima** delle chiamate — nello script l'app si chiama `APP`, `resolve_log_glob` legge `ACTIVE_APP`: senza, il vincolo sarebbe un **no-op silenzioso** e `ContactManager` vincerebbe alfabeticamente su `ClaimCenter`, facendo leggere a ogni tool i log dell'app sbagliata con dati coerenti. Sourcia `utils-logfiles.sh` — verificato che non scriva **nulla** su stdout, che è il canale passato a `eval` da `chatbot.sh` | **Fatto** |
| LOGDISC-4c | **Validazione per-tool** (`require_system_log KIND TOOL` in `dispatch.sh`): rimosso l'abort di sessione su access log mancante. Un helper invece di 9 guard ripetuti (principio 2); ha sostituito anche i 5 guard preesistenti su server/gc, che controllavano il **path del file** invece della **directory** — quindi saltavano un tool su un nodo appena ruotato pur avendo i dati. Rimosse le locali `access`/`server`/`gc` in `_dispatch_tool_run`, diventate una seconda fonte di verità (e quella sbagliata) sulla disponibilità | **Fatto** |
| LOGDISC-4d | **`skip_system_log_not_found`**: distingue "non c'è sul nodo" da "esiste sotto un'altra app", come già `skip_named_log_not_found` per i named log — una politica sola, scritta come corollario del principio 6 in `CLAUDE.md` | **Fatto** |
| LOGDISC-4e | **Bug preesistente in `require_app` (da LOGDISC-1) corretto**: confrontava "il path contiene `/$ACTIVE_APP/`" invece di "il file appartiene a un'altra app", quindi **rifiutava un log che non appartiene a nessuna app**. Falso negativo (principio 5) che rendeva irraggiungibili con `tail_named_log`/`grep_named_log` proprio i log in posizione arbitraria che LOGDISC-1 aveva reso scopribili. Ora usa `resolve_app_from_path`: app di sessione → ok, nessuna app → **ok**, altra app → rifiuta | **Fatto** |

**Perché il test di LOGDISC-1 non aveva colto 4e**: la fixture `weird/deep/nested/custom_app.log`
esisteva già, ma le asserzioni che la usavano chiamavano `resolve_log_glob` **senza**
`require_app`. Il parametro era stato aggiunto per il caso cross-app e testato su quello; la
**combinazione** dei due — path senza app *attraverso* `require_app` — non era mai stata
esercitata. È la firma di un test che verifica la feature nuova invece dell'interazione fra
le feature.

**Verifica**: `bash tests/run-tests.sh` → **87 PASS / 0 FAIL** (86 + il nuovo file).
28 asserzioni in `tests/test-logdisc-4.sh`, con **fail-before/pass-after** via `git stash` sul
solo codice di produzione: **16 FAIL** senza il fix, 0 con.

**Verifica in produzione** (nodo 4, che ha davvero due app) — la prova che il difetto era
reale, non teorico:

| | ClaimCenter | ContactManager |
|---|---|---|
| `filter_errors` (server log) | 1 ERROR, 2 WARN | **9 ERROR, 963 WARN** |
| `gc_stats` | 127 eventi GC | **141 eventi GC** |

Ogni app legge il proprio log, dichiarato da `print_log_source`. I numeri sono
clamorosamente diversi: mescolarli avrebbe prodotto una media di pause GC su due JVM
distinte e un conteggio errori che non corrisponde a nessuna delle due applicazioni.

**Il contesto originale (2026-08-17, prima dell'implementazione)**

Ultima area che viola il **principio 6**. Dopo LOGDISC-1 (named log) e LOGDISC-2
(`search_all_logs`), gli 11 tool che leggono i log di **sistema** (access/server/gc)
ricevono ancora path calcolati da un template di layout invece di scoprirli.

**Da fare PRIMA dell'integrazione del framework C in `../neural-c`** (decisione utente
2026-08-17): quel lavoro è grosso ma affidabile, questo tocca il percorso di risoluzione
file su cui il C non incide — meglio non sovrapporli.

### Audit (2026-08-17, verificato non stimato)

L'assunzione ha **un solo punto di origine** e converge in **3 helper**:

- `resolve-logs.sh:69` — `APP_DIR="$NODE_DIR/$(eval echo "$APP_SUBPATH")"`
- `resolve-logs.sh:124-131` — emette `ACCESS_LOG_DIR`, `SERVER_LOG_DIR`, `GC_LOG_DIR`
  **tutti e tre uguali a `APP_DIR`**
- `dispatch.sh:69-71` — `open_logs()`, `open_gc_logs()`, `open_server_logs()` leggono
  quelle tre variabili
- `dispatch.sh:104-105` — `open_current_logs()`, `open_current_server_logs()` (il ramo
  "log corrente" di `tail_log`, che bypassa il filtro temporale)

**15 call site in 11 tool**: `count_status`, `distribute_status`, `slow_requests`,
`traffic_volume`, `service_times`, `filter_ip` (via `open_logs`); `filter_errors`,
`filter_app_errors` (via `open_server_logs`); `gc_stats` (via `open_gc_logs`);
`correlate_gc_slow` (due sorgenti); `tail_log` (4 rami). Nessun tool costruisce path da
sé — **tutto passa dai 3 helper**, quindi la superficie di modifica è piccola.

### Il vincolo che rende questo caso DIVERSO dai due precedenti

Misurato sul nodo 4 di produzione — **ogni log di sistema esiste in due copie omonime**,
una per app:

| basename | `prod/ClaimCenter` | `prod/ContactManager` |
|---|---|---|
| `undertow_access_log*` | 55 file | 55 file |
| `server*` | 22 | 22 |
| `gc*` | 16 | 16 |

Quindi **una scoperta ricorsiva ingenua sarebbe un bug, non un miglioramento**: `gc_stats`
sommerebbe le pause GC di due JVM diverse in un'unica statistica, `filter_errors`
mescolerebbe stack trace di due applicazioni. È l'opposto di `search_all_logs`, dove
"cerca in tutte le app" è la semantica voluta e la colonna APP basta a dichiararla: qui il
tool deve leggere **un** log, e la molteplicità richiede una **scelta**, non un'etichetta.

**La policy esiste già e non va inventata**: il tie-break di `resolve_log_glob()`
(`utils-logfiles.sh`) — app di sessione (`ACTIVE_APP`) > file non ruotato > path più corto
> alfabetico — più `require_app` per rifiutare un match che esiste solo sotto un'altra app
(`skip_named_log_not_found`, LOGDISC-1). La strada è **riusare quella**, non aggiungere un
ramo condizionale nei 3 helper (principio 2).

### Difetto collaterale trovato durante l'audit

`resolve-logs.sh:101-108` **aborta l'intera sessione** se non trova un access log in
`APP_DIR`, anche per query che non lo leggono. Incontrato in prima persona il 2026-08-17
scrivendo il test end-to-end di LOGDISC-2: la fixture non aveva
`undertow_access_log.log`, e `chatbot.sh` è morto su una query di `search_all_logs`, che
l'access log non lo usa nemmeno come sorgente privilegiata. Un nodo reale senza access log
(app che non espone HTTP) rende il bot **completamente** inutilizzabile su quel nodo.
Da valutare insieme: la validazione dovrebbe essere **per-tool** (chi legge l'access log
fallisce se manca) invece che globale in fase di risoluzione sessione.

### L'obiettivo vero: una pipeline sola (indicazione utente, 2026-08-17)

> *"Tutto il funzionamento dei tool deve seguire la stessa pipeline, che deve essere unica
> e funzionante perfettamente, così abbiamo un comportamento atteso riproducibile."*

**Stato dopo LOGDISC-4** — la scoperta è unificata, la selezione resta a tre politiche
*dichiarate*:

| percorso | usato da | scoperta | selezione rotazioni |
|---|---|---|---|
| `open_logs_for` | 11 tool di sistema | ✅ `resolve_system_log_dir` | ✅ walk temporale |
| `open_current_log_for` | `tail_log` a riposo | ✅ (dalla dir scoperta) | ⚙️ solo corrente (voluto) |
| `resolve_named_log_path` | `tail_named_log`, `grep_named_log` | ✅ ricorsiva | ✅ walk temporale |
| `discover_log_dirs` | `search_all_logs` | ✅ ricorsiva | ⚙️ tutte le rotazioni |

**Perché la selezione non è unificata, e non deve esserlo.** Verificato:
`select_log_files` senza finestra temporale restituisce **tutte** le rotazioni (principio 5,
"nessun vincolo = nessuna esclusione"). `tail_log` a riposo chiede "cosa succede *ora*", non
"leggi il periodo X" — passarlo dal walk gli farebbe leggere ~500k righe per file per
scartarle. Forzare un'unica politica di selezione sarebbe un **regresso**, non
un'unificazione. Quello che conta è che le tre politiche siano **esplicite e dichiarate**
(la colonna ⚙️ sopra) invece di essere un dettaglio implementativo che ogni percorso decide
per conto suo — che era la vera causa dei bug.

**Stato precedente, per memoria** — 4 percorsi, 3 comportamenti, causa strutturale di
LOGDISC-1/3, LOGSEL-1 e LOGDISC-2, tutti della forma "un percorso corretto e un altro no":

| percorso | scoperta | selezione |
|---|---|---|
| `open_logs_for` | ❌ path da template | ✅ |
| `open_current_log_for` | ❌ path da template | ❌ bypassa |
| `resolve_named_log_path` | ✅ | ✅ |
| `discover_log_dirs` | ✅ | ✅ |

**Questa tabella è la causa strutturale dei bug della settimana**: LOGDISC-1, LOGDISC-3,
LOGSEL-1 e LOGDISC-2 sono tutti della forma "un percorso è stato corretto, un altro no".
Il principio 8 lo dice già, ma come regola di *processo* (ricordarsi di migrare i
chiamanti). L'obiettivo qui è renderlo una proprietà **strutturale**: un motore solo,
attraversato da tutti, così il quinto bug della famiglia non può esistere.

Non è quindi "porta 11 tool alla ricorsione", è **unifica i 4 percorsi in 1**.

### Le due fasi sono distinte e hanno bisogni diversi (chiarito con l'utente)

| fase | cosa fa | serve `TIME_FROM`/`TIME_TO`? | costo misurato |
|---|---|---|---|
| **scoperta** | trova le directory che contengono log | **no** — è topologia del filesystem | 0.01 s |
| **selezione** | scegle quali rotazioni leggere | **sì** — è il walk temporale | 6.5 s su 51 file |

Conseguenza: **la scoperta non ha bisogno del filtro temporale**, quindi può stare in
`resolve-logs.sh` (una volta per sessione). La selezione resta per-query dov'è già. La
domanda "dove metterla" era mal posta: presupponeva che le due fasi dovessero convivere.

**Il prefiltro sulla prima riga esiste già** e non va reinventato:
`_logfiles_read_first_ts()` legge `head -1` (o i primi 4 KB per i `.gz`, con SIGPIPE al
decompressore) e riconosce 4 formati di timestamp. È esattamente la strategia
"estrai i percorsi, poi prefiltra con la prima riga" — leggere 4 KB invece di decomprimere
60 MB. Indicazione utente: **pragmatico prima che ottimizzato** — i numeri lo confermano,
ottimizzare la scoperta (0.01 s) è irrilevante contro la selezione (6.5 s).

### Cross-app: una politica sola, formulata una volta (indicazione utente)

L'utente chiede che il comportamento sia **prevedibile**: una politica, non due. La regola
invariante è **mai dati di un'app diversa da quella attesa senza dirlo** (principio 6), e
si declina secondo la natura del tool:

- un tool che analizza **una sorgente** (`gc_stats`, `filter_errors`, `count_status`…) usa
  l'app di sessione; se il log esiste solo sotto un'altra app **lo dice e si ferma**, come
  già fa `skip_named_log_not_found` per i named log
- un tool che **aggrega su più sorgenti** (`search_all_logs`) le include tutte e **dichiara
  la provenienza** (colonna APP, LOGDISC-2)

Non sono due politiche ma la stessa regola con esito diverso, e la ragione è misurabile:
una media di pause GC su due JVM distinte è priva di senso, un elenco di occorrenze su due
app è una risposta legittima. **Da scrivere come principio in CLAUDE.md** durante
l'implementazione, così è consultabile e non va ridedotta.

### Le due domande aperte in fase di design, risolte

1. **`open_current_log_for` va diviso in due** — confermato: acquisisce la scoperta
   (riceve la directory scoperta, non più da template) e **mantiene** il bypass della
   selezione (OBS-3). La funzione non è stata toccata affatto: riceve già la directory
   dalla variabile di sessione, quindi il cambio in `resolve-logs.sh` la raggiunge senza
   modifiche. Zero righe cambiate per il beneficio pieno.
2. **La validazione per-tool è stata fatta nello stesso intervento** (LOGDISC-4c): la
   scoperta riscriveva comunque quel blocco, e separarla avrebbe richiesto di toccare
   `resolve-logs.sh` due volte.

---

## FORMAT-1 — Il formato delle righe è cablato, non configurato (aperta 2026-08-17)

Sollevato dall'utente durante la revisione di LOGDISC-4: *"I nomi log, come li determiniamo?
Sono hardcoded? In questo caso avremmo `undertow_access_log`, ma per un websphere potrebbero
essere `access_log` o anche `combined_log`."*

**I nomi sono a posto.** Vivono in `system.conf` (`ACCESS_LOG_BASE`, `SERVER_LOG_BASE`,
`GC_LOG_BASE`, `SERVER_LOG_FORMAT`), `resolve-logs.sh` valida la loro presenza e aborta se
mancano (ARCH-6, nessun default implicito). Un WebSphere con `access_log`/`SystemOut`/
`native_stderr` si supporta cambiando **tre righe di config**, senza toccare codice.

**Il formato no.** L'audit (2026-08-17) trova l'assunzione posizionale in **8 tool**:

```awk
if ((time_from != "" || time_to != "") && !in_range(parse_access($2))) next
```

`count_status:12`, `distribute_status:11`, `slow_requests:35`, `traffic_volume:9`,
`service_times:19`, `filter_ip:24`, `tail_log:50`, `correlate_gc_slow:64` — tutti assumono
che il timestamp sia il **secondo campo** nel formato `[DD/Mon/YYYY:HH:MM:SS`. Il formato
*combined* di Apache/WebSphere (`%h %l %u %t ...`) ha tre campi prima del timestamp, quindi
lo mette in `$4`.

**Perché è più grave di un errore di config.** Con formato combined, `parse_access($2)`
riceve un campo che non è un timestamp e restituisce 0. Il codice tratta `ts=0` come
"ignoto" e per il **principio 5** (pruning conservativo) *include* la riga — quindi il
filtro temporale **smette silenziosamente di filtrare** invece di dare errore. Stessa
famiglia di LOGSEL-1: dati plausibili, domanda diversa da quella posta. E `match(line, /"
([0-9]{3}) /)` per lo status HTTP dipende dalle virgolette della request line, altra
assunzione di formato.

**Distinzione da tenere presente**: cambiare un *nome* fallisce rumorosamente (file non
trovato); cambiare un *formato* fallisce in silenzio. Il primo è configurazione vera, il
secondo è un'assunzione mascherata da configurazione.

**Direzione da valutare** (non decisa): portare gli indici di campo in `system.conf` — es.
`ACCESS_TS_FIELD=2` con `parse_access($(ACCESS_TS_FIELD))` — oppure un riconoscimento del
formato dalla prima riga, come già fa `_logfiles_read_first_ts()` per i timestamp (4 formati
riconosciuti, nessuno configurato). La seconda strada è più robusta ma più invasiva.
`parse_access()` è già centralizzata in `utils-time.awk` (principio 2): il problema non è
la funzione, sono gli **8 indici `$2` nei chiamanti**.

**Priorità**: dopo LOGDISC-4 (decisione utente). Sono assi ortogonali — LOGDISC-4 riguarda
*dove sono i file* (3 helper bash), FORMAT-1 *come si leggono le righe* (8 tool AWK).
Nessun cliente WebSphere reale oggi, quindi non è urgente; ma è la prossima cosa che si
rompe se il progetto cambia middleware, e va saputo **prima** di prometterlo a un cliente.

---

## PROF-1 — `profiles/usnext` non è utilizzabile (trovata 2026-08-17)

Trovata durante l'audit di FORMAT-1, verificando se un secondo profilo confermasse la
generalità del contratto. **Non la conferma: quel profilo non funziona.**

`profiles/usnext/system.conf` ha **0 occorrenze** di `ACCESS_LOG_BASE`, `SERVER_LOG_BASE`,
`GC_LOG_BASE` e **0** di `SYSTEM_LOG_SYNONYMS`. Poiché `resolve-logs.sh:81-86` valida la
presenza dei tre basename e aborta se mancano (ARCH-6), qualunque query su quel profilo
muore con `[ERROR] resolve-logs: ACCESS_LOG_BASE non impostato in system.conf`.

Definisce `AVAILABLE_APPS` (3 app), `APP_SUBPATH`, `CUSTOM_LOG_SUBPATH=''` e un `TOOL_DESC`
con 11 tool (senza `search_all_logs`) — quindi **sembra** un profilo alternativo completo, e
nulla segnala che non lo sia. È il rischio: un profilo scheletro indistinguibile da uno
funzionante suggerisce una generalizzazione **dichiarata ma non verificata**.

**Da decidere** (serve contesto che non è nel repo):
- **completarlo** — richiede i nomi log reali di quel middleware, e sarebbe la prova più
  forte che il contratto non è liquido-specifico: oggi la generalità è argomentata
  leggendo il codice, non dimostrata eseguendolo
- **rimuoverlo** — se è solo uno scheletro dimostrativo, tenerlo costa manutenzione (ogni
  modifica al contratto dovrebbe aggiornarlo) e dà una falsa sicurezza

Nel frattempo vale la pena un **guard esplicito**: `chatbot.sh` o `setup.sh` che verifica la
completezza di un profilo e dice cosa manca, invece di far scoprire il problema alla prima
query. Un profilo incompleto è un errore di configurazione, non un incidente di runtime.

---

## MIGR — Migrazione a Python (nuovo progetto)

> **NON è lavoro di questo backlog.** Un agent separato sta procedendo in
> `../neural-log-lanalyzer` (dal 2026-08-06). Questa sezione resta solo come contesto: la
> regola è che fix e feature continuano QUI, così quel progetto parte da un comportamento
> verificato e non da difetti noti da correggere due volte.

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
| P7 | **`grep_named_log`** — mediana reale **1317ms** (il 3390 in backlog era il p95 su 3 sole misure), il più veloce dei tool lenti. Entrambe le leve ipotizzate si sono rivelate problematiche, vedi nota | ? | **Chiuso: nessuna ottimizzazione applicabile** (2026-08-06) |
| P8 | **`filter_ip`: estrazione unica di status/tempo + codice morto rimosso** — la regex dello status girava 3× per riga, quella del tempo 2×, e un blocco calcolava colori mai usati. Mediana 7.50s → 5.90s su 326k righe (vince 9 round su 11; media peggiore per outlier del server — misura non pulita, ma la modifica è difendibile per natura) | ~20 righe | **Fatto** (2026-08-06) |
| P9 | **Inversione filtri in `distribute_status`, `service_times`, `traffic_volume`** — tentata e **ANNULLATA**: 4-6× più LENTA. Vedi nota sotto, è la lezione più utile di questo giro | — | **Chiuso: non si fa** (2026-08-06) |

### P9 — perché invertire i filtri su questi tool NON funziona

Tentativo del 2026-08-06: spostare il filtro temporale DOPO quelli sul contenuto
(status, soglia), sul principio "filtro selettivo prima di quello costoso" che aveva
funzionato su `slow_requests` (P6, -21%). Risultato misurato su 5 round interlacciati:

| tool | prima | dopo | esito |
|---|---|---|---|
| `distribute_status` | 0.06s | 0.23s | **4× più lento** |
| `service_times` | 0.05s | 0.25s | **5× più lento** |
| `traffic_volume` | 0.05s | 0.31-0.96s | **6× più lento** |

**Causa: l'assunzione sulla selettività era sbagliata.** Misurata su dati reali:

| filtro | scarta |
|---|---|
| **temporale** (finestra di 2 ore) | **fino al 100%** |
| status 4xx/5xx | 99.98% |
| soglia >= 1000ms | 90.2% |

Il filtro temporale è **il più selettivo**, perché il log corrente contiene solo poche
ore e la finestra richiesta può caderne fuori del tutto. Era già al posto giusto:
`parse_access()` è memoizzata (P6) e con 18 righe per secondo distinto costa poco.
Invertendo si esegue una regex su ogni riga *prima* del filtro che le scarterebbe tutte.

**Perché su `slow_requests` aveva funzionato:** quella misura girava su un file da 200k
righe **non ruotato**, dove la finestra copriva una porzione ampia. La conclusione
dipendeva dallo **stato del file**, non dalla struttura del codice — e fu generalizzata
senza verificarlo.

**Regola che ne deriva:** su questi tool le ottimizzazioni "per riordino" non pagano,
perché dipendono da un'assunzione sui dati che cambia con la rotazione dei log. Pagano
quelle che **eliminano lavoro** in ogni scenario (P8: una regex invece di tre) o che
cambiano la **struttura dati** (P5: indice per secondo invece di scansione lineare).
| PERF-NNET | **Overhead fisso per query (~574ms)**: classificazione neurale (`infer.sh`) + `normalize-query.sh` + `param-extract.sh` + fork di `resolve-logs.sh`. Vedi sotto | — | **Non si fa ora — l'utente ha in mente una modifica major** |

### P7 — chiuso: nessuna ottimizzazione applicabile

**Decisione (utente, 2026-08-06):** non si fa. Preferibile testare più estesamente con l'uso
reale che applicare un'ottimizzazione dal margine incerto. Se i dati accumulati in `logs/`
rimettessero `grep_named_log` in cima alla classifica, si riapre — la sezione resta come
analisi già fatta, da cui ripartire invece di rifarla.

**Perché le due leve ipotizzate non convincono**

Verificato il codice il 2026-08-06 (P7 **non** è stato toccato dagli interventi di quel giorno
su `grep_named_log`, che erano di osservabilità (OBS-3), usabilità (OBS-5) e funzionalità
(SRCH-1) — non di performance):

**Leva 1 — spostare il filtro sul livello prima della regex.** È esattamente l'inversione
annullata in P9 su altri tre tool, dove era 4-6× più lenta. Qui in più non è nemmeno
direttamente applicabile: `GW_RE` estrae timestamp, livello e messaggio in un solo `match()`,
quindi il livello non è disponibile *prima* di quella regex. Si potrebbe anticipare un test
economico (`index($0, " ERROR ")`) ma sarebbe fragile e legato al formato esatto — e il
formato Guidewire ha già mostrato varianti (spaziatura del livello, millisecondi).

**Leva 2 — usare `parse_access()` memoizzata invece di `mktime()` a mano.** Non applicabile:
`parse_access()` parsa il formato access log (`[06/Aug/2026:10:00:00`), mentre qui il timestamp
è ISO Guidewire (`2026-08-06T10:00:00,443`). Servirebbe una memoizzazione separata per il
formato ISO — fattibile, ma il beneficio è limitato dal fatto che `mktime` viene chiamato
**solo** sulle righe che hanno già superato il filtro livello, quindi su una minoranza.

**Conclusione:** il margine reale è piccolo e il rischio di regressione non trascurabile. Da
riconsiderare solo se `grep_named_log` risalisse nella classifica con più dati accumulati.

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
| O6 | **RISOLTO** — `filter_ip`: latenza media sottostimata con righe malformate — divide il tempo totale per il numero di RICHIESTE, non per quelle di cui si è potuto misurare il tempo. Su una riga senza campo tempo estraibile il contributo è 0 ma il denominatore cresce comunque: es. 100ms su 2 richieste (una malformata) dà 50ms invece di 100ms. Difetto **preesistente**, trovato il 2026-08-06 scrivendo `tests/test-filter-ip.sh` (dove il comportamento attuale è documentato in un assert, non nascosto). Verificato identico prima dell'ottimizzazione P8, quindi non introdotto da essa. Fix: contare separatamente le righe con tempo misurabile. **Verificati tutti i 6 tool che calcolano medie: `filter_ip` era l'unico col difetto.** `slow_requests`, `service_times` e `gc_stats` arrivano al contatore solo dopo `match(...) || next`, quindi ogni riga contata è già validata (in `gc_stats` la protezione viene dal pattern di riga: verificato su 17.296 righe reali, 0 casi). In `count_status` e `correlate_gc_slow` il denominatore su TUTTE le righe è **voluto** — è il tasso sul traffico totale, correggerlo sarebbe un bug. Il tool ora dichiara anche quante righe erano senza tempo misurabile, invece di presentare una media parziale come completa | **Fatto** (2026-08-06) |

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
| UI-12 | **RISOLTO** — i 13 tool usano i ruoli semantici (228 sostituzioni). **Non era solo cosmetico**, contro la valutazione iniziale: la migrazione ha scoperto che il metodo HTTP `GET` usava `C_OK`, quindi era colorato come uno status 2xx — in una tabella di richieste LENTE il verde suggeriva "va bene" mentre indicava solo il verbo. Aggiunti due ruoli mancanti: `C_INFO` (livello neutro di una scala — status 3xx) e `C_TAG` (categoria, non gravità — metodo HTTP, contatori), con fallback su `C_ACCENT` per i temi che non li definiscono. Trovato e corretto anche un bug in `theme_load`: non azzerava le variabili, quindi un tema **ereditava** i ruoli non definiti dal tema caricato prima — invisibile nel bot (un solo load per esecuzione) ma `theme-preview.sh` mostrava colori inesistenti. Output verificato identico su 7 tool col tema dark, tranne la correzione voluta su `GET` | **Fatto** (2026-08-06) |
| UI-13 | **RISOLTO** — soglie in `domain.conf` — `SLOW_MS` è definito **due volte con valori diversi** (200 in `gc_stats.awk:7`, 2000 in `service_times.awk:12`): corretto nel merito, ma il nome identico suggerisce una costante condivisa che non esiste. Altre soglie inline e senza nome: `>=1000` (`filter_ip`), `>=5000` (`slow_requests`), `>=85`/`>=70` (`gc_stats`), `>=30`/`>=10` (`correlate_gc_slow`). Portate in `domain.conf` con nomi espliciti (`GC_PAUSE_WARN_MS`, `SVC_TIME_WARN_MS`, `REQ_TIME_*`, `HEAP_USED_*`, `GC_CORR_*`), passate ai tool con `-v` da `dispatch.sh` in una variabile riusabile (`thr_v`, come `theme_v`). Ogni tool ha un fallback identico nel `BEGIN`, quindi un'invocazione diretta si comporta come prima. Usano `${VAR:-default}` come il resto del progetto, così l'ambiente le sovrascrive — con l'assegnazione secca della prima stesura non erano configurabili, ed è un test a rilevarlo. `slow_requests` non ne ha: colora per status HTTP, non per soglia di tempo | **Fatto** (2026-08-06) |


### UI-12 — rettifica: la semantica dei colori è già corretta

La descrizione iniziale (2026-08-06) diceva che `RED` significava "soglia superata" in alcuni
tool e "errore" in altri, dedotto **contando gli usi** per tool senza leggere le condizioni.
Verificato il codice, il pattern reale è sempre una scala di gravità a due livelli:

```awk
(valore >= VERYSLOW_MS) ? RED : (valore >= SLOW_MS) ? YELLOW : ""   # gc_stats, service_times
(pct_corr >= 30)        ? RED : (pct_corr >= 10)    ? YELLOW : ""   # correlate_gc_slow
(substr(status,1,1) == "5") ? RED : YELLOW                          # slow_requests, count_status
```

Rosso = livello più grave, giallo = attenzione: mappa esattamente su `C_CRIT`/`C_WARN`. La
differenza fra "status 5xx" e "tempo oltre soglia" è nel **dominio** del dato, non nella
semantica del colore. Quindi la migrazione ai nomi semantici migliora la leggibilità del
codice ma non corregge nulla di visibile all'utente — priorità abbassata a cosmetica.
---

## OBS — Osservabilità (logging di performance, 2026-08-06)

| ID | Descrizione | Stato |
|----|-------------|-------|
| OBS-1 | **Log di query e performance** — `log_query()` in `chatbot.sh` scrive 13 colonne TSV (query, tool, tempi per fase, volumi, worker) in `QUERY_LOG_DIR`, default `<dir chatbot.sh>/logs`. `perf-report.sh` aggrega per tool (mediana/p95), scompone le fasi, elenca le query più lente, mostra il tempo per MB. | **Fatto** (2026-08-06) |
| OBS-2 | **Metriche di fase per tutti i tool** — `dispatch_tool` è un wrapper che misura e delega a `_dispatch_tool_run`; `open_logs_for` emette le proprie metriche via file (gira in subshell). | **Fatto** (2026-08-06) |
| OBS-3 | **Copertura verificata su tutti i tool** — confermati i 3 percorsi che riportavano metriche a 0 pur leggendo file reali (`open_current_log_for` per `tail_log` a riposo, la catena `find` di `tail_named_log`/`grep_named_log`, `open_glob_logs`). Corretti; `show_help`/`list_logs` restano a 0 ed è corretto (non leggono log). Effetto collaterale: la catena `find` era **duplicata identica** nei due rami named-log, centralizzata in `resolve_named_log_path()`. 10 test in `tests/test-dispatch-perf.sh` | **Fatto** (2026-08-06) |
| OBS-5 | **Feedback progressivo mancante in 3 tool** (segnalato dall'utente) — `tail_log`, `tail_named_log`, `grep_named_log` bypassavano `select_log_files_grouped`, dove vive `progress_show`. Stesso difetto strutturale di OBS-3, sintomo diverso. `grep_named_log` arriva a 3.7s, quindi non era cosmetico. 7 test con TTY simulato in `tests/test-theme.sh` | **Fatto** (2026-08-06) |
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
