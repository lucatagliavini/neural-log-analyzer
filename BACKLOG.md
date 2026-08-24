# Backlog — neural-log-analyzer

Aggiornato: 2026-08-24

---

## ⏭ APERTI

| ID | Descrizione | Priorità |
|----|-------------|----------|
| SRCHQ-1 | **La regola sugli apici singoli è ora in un punto solo, ma resta un'euristica** — `lib/utils-quoted.sh` (SRCH-5/D3-D4) tratta una coppia di apici come citazione **solo se delimitata da spazi**, perché in italiano `'` è anche l'apostrofo. Conseguenza dichiarata e coperta da test: una citazione fra apici singoli **non può contenere un apostrofo** (`trova 'errore nell'app'` non è riconosciuta come citazione; con le virgolette doppie sì). È lo stesso vincolo del quoting di shell e il messaggio d'aiuto del bot documenta entrambe le forme, quindi l'utente ha già la via d'uscita. **Non c'è nulla da correggere adesso**: la voce esiste perché se un giorno arrivasse una segnalazione su una ricerca fra apici che «non funziona», la causa è questa e sta scritta, invece di essere ridiagnosticata da zero | Promemoria |
| FLEX-1 | **Passata sistematica sulle classi di caratteri flesse** — chiusa nella sostanza il 2026-08-20, resta come **promemoria** con il comando da rieseguire quando si aggiunge un pattern flesso nuovo. Vedi la sezione dedicata sotto | Promemoria |
| GCFMT-1 | **Un tool GC per tecnologia, non un parser astratto** (proposta utente 2026-08-17, adottata). `gc_stats.awk` ha 6 regole specifiche di G1 (`Eden regions`, `Survivor regions`, `Old regions`, `Humongous regions`, `Metaspace`, `Pause (Young\|Full\|Mixed)`). La strada del plugin di *funzioni* — quella usata per `SERVER_LOG_FORMAT` e `ACCESS_LOG_FORMAT` — **qui non si applica**: in quei due casi cambia l'estrazione ma l'analisi è la stessa (contare i 500 è identico in Undertow e in Apache), mentre l'analisi generazionale di G1 non ha senso in ZGC, che non ha Eden né Survivor. Astrarre ora significherebbe inventare un'interfaccia modellata su G1 e poi forzare ZGC a fingere di averla. La strada è **sostituire il tool intero**: `GC_LOG_FORMAT` seleziona `gc_stats.awk` (G1) o un futuro `gc_stats_zgc.awk` che parsa *e* analizza secondo i propri concetti. Precedente nel progetto: `dispatch.sh` ha già rami diversi per lo stesso tool (`tail_log` su access vs server secondo `LOG_TYPE`). **Da fare quando esiste un secondo formato GC reale da supportare**, non prima: con un solo caso l'interfaccia non è validabile | Quando serve |

### FLEX-1 — classi di caratteri flesse, e FLEX-1b — la parola senza feature (2026-08-20)

**Il difetto che la voce nomina**: una classe di caratteri che copre alcune desinenze
italiane e non altre. Emerso **quattro volte**, in tre file:

| pattern | mancava | conseguenza |
|---|---|---|
| `ultim[aei]` | `o` | `ultimo giorno` → nessun filtro temporale (`utils-time.sh`, T3) |
| `applicativ[oa]?` | `i` | `log applicativi` → `LOG_TYPE` vuoto → fallback access log (P2) |
| `prim[ei]` | `a`, `o` | `prima riga` → mostra l'**ultima** (`param-extract.sh`, LOG_ORDER) |
| `rott[oa]` | `i`, `e` | `richieste rotte` → nessun tool sopra soglia (`nlp/unigrams.txt`) |

Tratto comune: **nessuno dava errore**. Producevano un parametro vuoto o un default, cioè un
filtro che *si disattiva* invece di fallire.

**Il comando della passata** — la prima versione produceva falsi positivi sui **propri
commenti esplicativi** (quelli che citano il valore vecchio per spiegare il fix), obbligando a
ritriagiarli: esattamente l'attrito che la voce deve eliminare. Corretto:

```bash
grep -rnE '[a-z]{4,}\[[aeio]{2,3}\]\??' lib/ profiles/ nlp/ | grep -vE ':[[:space:]]*#'
```

Proprietà utile e non progettata: `[aeio]{2,3}` trova solo le classi **potenzialmente
incomplete**, quindi una già corretta a 4 vocali esce da sola dai risultati — la passata non
richiede di ricordare cosa è già stato sistemato.

**Triage delle 15 occorrenze di codice** (21 meno i 6 commenti): 12 complete per il loro uso
(`giorn[oi]`, `minut[oi]`, `rispost[ae]`, `total[ei]`, `memori[ae]`, …), 3 incomplete, tutte
misurate dal vivo:

| pattern | manca | esito misurato | azione |
|---|---|---|---|
| `rott[oa]` | `rotte`, `rotti` | `quali richieste sono rotte` → **nessun tool sopra soglia** | **corretto** → `rott[oaie]` |
| `tutt[ie]` | `tutto`, `tutta` | `cerca "NPE" in tutto il log` → `search_all_logs` **97%** | **non toccato** |
| `quant[eo]\|quanti` | `quanta` | `quanta memoria usa la jvm` → `gc_stats` **96%** | **non toccato** |

**Perché due su tre restano così**: sono misurati innocui — il segnale arriva da altre feature.
Estenderli per soddisfare una simmetria formale sarebbe churn con rischio di perturbare confini
funzionanti, a beneficio misurato zero. `quant[eo]|quanti` è anche la **prova che il problema si
era già presentato**: qualcuno l'aveva patchato con un'alternativa esplicita invece di estendere
la classe, cioè una correzione locale invece che sistematica. È la ragione per cui questa voce
resta come promemoria.

---

**FLEX-1b — la scoperta più grande, trovata indagando `rott[oa]`.** Il vicolo cieco non era
quello:

```
richieste rotte                  → NESSUN TOOL SOPRA SOGLIA
quali richieste hanno fallito    → NESSUN TOOL SOPRA SOGLIA
richieste fallite                → NESSUN TOOL SOPRA SOGLIA
```

**`richieste fallite` è letteralmente un esempio di training** (`count_status → totale richieste
fallite`) e da sola non attivava nulla, perché **non esisteva alcuna feature per
`fallit*`/`fallim*`** — pur essendo usata in **6 esempi labeled su 3 classi**. Quegli esempi
venivano appresi solo tramite gli altri token (`totale`, `raggruppa`, `api`).

**E `gap-report.sh` lo segnalava già**: `fallimenti — 3 esempi` fra i token non coperti,
stampato da `train.sh` a ogni addestramento, con la nota di NCLOCAL-1 «informativo, non
azionato in questo intervento». Non una scoperta nuova, un **report esistente non letto** —
stessa famiglia dei checksum obsoleti per 12 giorni (`c1951e3`) e dei test fuori dalla suite
(NLP-1): l'informazione c'era, il canale funzionava, nessuno l'aveva guardata.

**Fix**: nuovo unigramma `fallit|fallim|fallis :: 2` nella sezione Status HTTP (peso 2 come
`errore|errori`, perché in "richieste fallite" è l'unica parola che porta il segnale di errore),
più 6 esempi. `NUM_FEATURES` 114 → 115, `MODEL_TOPOLOGY` → `115,48,16`, reinizializzazione e
retrain (early stopping all'epoca 966, pesi dalla 866).

**Una politica sola su `rott*`, e l'etichetta sbagliata era la mia.** Due esempi erano stati
etichettati `distribute_status` per «quali richieste sono rotte», e il modello li instradava
comunque a `filter_errors` al 93% — perché `rott*` vive sulla riga colloquiale del vocabolario
che serve quel tool, e `cosa è rotto → filter_errors` è corretto. **Rimossi invece di
insistere**: forzarli avrebbe creato un confine imprevedibile (`rotto` verso gli errori
applicativi ma `richieste rotte` verso l'access log), contro la politica del progetto — una
sola, formulata una volta. La regola ora si scrive in due righe:

```
rott*    = "qualcosa è rotto"        → filter_errors (log applicativo)
fallit*  = "richieste HTTP fallite"  → count_status / distribute_status
```

`quali endpoint sono rotti` → `distribute_status` (59%) resta corretto perché `endpoint` è un
segnale HTTP esplicito, quindi non introduce alcun confine sottile.

**Verifica**: `fallit*` instrada `count_status`/`distribute_status` (49-99%, multi-label sulle
formulazioni ambigue — stesso schema di LOGSEL-1b: conteggio e distribuzione sono entrambe
risposte valide); `rott*` sempre `filter_errors` (96%); confini storici invariati
(`quanti errori 500 stamattina` 99.6%, `distribuzione errori per endpoint` 98.7%,
`errori nel server log` 98.2%). `gap-report.sh` non segnala più `fallimenti`. Checksum di
`test-train-regression.sh` rigenerato (`ad6861f5…`) con riproducibilità su 3 run bit-identici.

### TIME-D1b — **CHIUSA il 2026-08-20: misurata, zero righe non databili**

**Esito: `_ats_unmatched == 0`.** Misurato sul nodo 4 di produzione (`lxprjbliq04`, profilo
`liquido`) subito dopo il deploy, su quattro tool e tre formati di file diversi:

| tool | sorgente | volume | righe non databili |
|---|---|---|---|
| `count_status` | access log, 57.4 MB | **173.469 richieste** nella finestra 06:00→12:00 | **0** |
| `filter_errors` | server log | 2 WARN nel periodo | **0** |
| `slow_requests` | access log | 9.643 richieste lente | **0** |
| `filter_ip` | access log | — | **0** |

**Il silenzio è un dato, non un canale rotto** — distinzione essenziale qui, ed è verificabile:
nella stessa esecuzione sono arrivate le altre righe DEBUG (`select_log_files_grouped`,
`dispatch_tool count_status: totale=2165ms select=133ms analisi=2032ms`), quindi il canale
funzionava e l'assenza della riga `utils-time` significa davvero zero.

**Conseguenza**: la scelta di D2 (`in_range(epoch<=0)` include, principio 5) è **gratuita** su
questi log. Elimina la classe di falso negativo di FORMAT-1 senza allargare di una singola
riga i risultati reali. Il guard `access_ts_format_warning()` resta come rete per il caso di
mismatch totale, che su un profilo o una tecnologia diversa può presentarsi.

**Da rieseguire** se si monta un profilo nuovo o una tecnologia di log diversa: il numero
dipende dal formato del file, non dal codice. Istruzioni conservate sotto.

### TIME-D1b — istruzioni operative (conservate per profili/formati futuri)

**Il contesto in tre righe.** `in_range(epoch <= 0)` ora **include** la riga: un epoch 0
significa «istante ignoto», e non sapere quando è avvenuta una riga non è una ragione per
affermare che sia fuori dal periodo (principio 5). Prima veniva esclusa, ed è il «falso
negativo pieno» misurato in FORMAT-1: il bot diceva «nessuna richiesta nel periodo» quando in
realtà non aveva saputo leggere le date.

**I tre casi, di cui solo il terzo è aperto:**

| caso | comportamento | copertura |
|---|---|---|
| nessuna riga non databile | identico a prima | il caso normale |
| **tutte** le righe non databili | il tool lo dichiara | risolto — `access_ts_format_warning()` |
| **alcune** righe non databili | quelle righe passano il filtro **sempre**, senza avviso | **⚠️ da misurare** |

Il terzo caso non ha un avviso di proposito: scatterebbe su ogni riga malformata di un log da
200.000 righe, e il rumore costante fa ignorare gli avvisi veri.

**La domanda non è "è giusto includere?" ma "quanto pesa?"** — 2 righe su 200.000 è
irrilevante, 50.000 su 200.000 significa che un quarto del file scavalca sempre la finestra e
l'utente crede di guardare un'ora mentre ne guarda otto. Stessa modifica, giudizi opposti, e
la differenza è un numero non misurabile da locale (non ci sono log di produzione).

**Comando** — una query qualunque, su un tool che legge l'access log e uno che legge il
server log, perché il numero dipende dal formato del file e non dal tool:

```bash
BOT_LOG_LEVEL=debug ./chatbot.sh --profile profiles/liquido --env prod --node 4 \
    --query "quanti errori 500 stamattina" 2>&1 | grep utils-time
```

Nessun output = zero righe non databili, ed è l'esito migliore. Altrimenti:
`[DEBUG] utils-time: N righe su M senza timestamp riconosciuto (incluse per principio 5)`.

**Come leggere N/M:** sotto l'1% → chiudere la voce, modifica a costo zero; qualche punto
percentuale → accettabile, ma capire *quali* righe sono (probabilmente stack trace o righe di
continuazione); decine di punti → rivedere, e il rollback è togliere `if (epoch <= 0) return 1`
da `lib/utils-time.awk`, una riga.

⚠️ **Corretto il 2026-08-20 dopo una domanda dell'utente**: il canale richiedeva *anche*
`BOT_LOG_FILE`, quindi `BOT_LOG_LEVEL=debug` da solo non scriveva nulla — e una misura assente
sarebbe stata letta come «zero righe non databili». Ora il fallback è `/dev/stderr`, come
documenta `utils-log.sh` per tutto il resto del logging. Un canale diagnostico che tace quando
è mal configurato è indistinguibile da uno che dice «tutto bene»: è lo stesso falso verde dei
test che non girano (NLP-1) e dei checksum mai verificati (`c1951e3`).

---

**SRCH-4 chiusa il 2026-08-20** (sezione `SRCH` sotto), insieme a **11 difetti nuovi della
prima fase della pipeline**: 9 trovati costruendo tre harness di test che non esistevano
(sezione **FASE-1**, il lavoro principale della giornata), più 2 trovati *cercandoli* con una
passata sistematica invece di attenderli (sezione **FLEX-1/FLEX-1b**). **TIME-D1b aperta e
chiusa nella stessa giornata**, misurata in produzione.

GCFMT-1 resta aperta in attesa di un secondo formato GC reale da supportare: con un solo
caso l'interfaccia non è validabile — non è urgente nonostante il tono, tant'è che qui è
segnata "Quando serve". **USNEXT-2 e HELP-1 chiuse il 2026-08-19** (sotto, sezioni
dedicate). **NCLOCAL-1, l'unica voce che era ad alta priorità, è stata chiusa il
2026-08-19** (sotto, sezione USNEXT-1) — il deploy in produzione resta comunque una
decisione dell'utente, non ancora presa. **SRCH-2, QUOTE-1 e SRCH-3 chiuse il 2026-08-19**
(sezione `SRCH` sotto) — il gap emerso dal test manuale in produzione è stato implementato,
riaddestrato e verificato su entrambi i profili nella stessa sessione in cui è stato
segnalato. **SRCH-4 aperta lo stesso giorno**: secondo riscontro dal test manuale
(nome di log di sistema quotato senza `*`), diagnosticato e documentato ma non
implementato su richiesta esplicita dell'utente ("implementiamo domani").

## DEPLOYVER-1 — `deploy.sh` resta non versionato, per scelta — **CHIUSA** (2026-08-24)

Chiusa su decisione esplicita dell'utente: `deploy.sh` è un **file di lavoro** e non deve
entrare nel repo. La direzione che la voce proponeva — estrarre `HOST`/`DEST` in un
`deploy.local.conf` e versionare lo script — è **respinta**, non rimandata.

Resta vero il fatto che l'aveva aperta: lo script contiene logica reale, non solo coordinate,
e quella logica **non è rivedibile da nessuno** e si perde se il file viene ricreato. La
mitigazione a costo zero, e la ragione per cui questa voce non sparisce ma si chiude
**documentando**, è trascrivere qui l'invariante più importante — il **sentinel di identità** —
così è ricostruibile dal repo anche senza il file:

> **`rsync --delete` + sentinel `.lana-bot-root`.** `--delete` cancella ricorsivamente la
> directory che gli viene passata: un `--dest` sbagliato, un `DEST` vuoto o un typo diventano
> una cancellazione in produzione, e `--dry-run` non protegge chi lancia il comando senza.
> Perciò `--delete` **aborta** se nella dest non esiste il marcatore `.lana-bot-root`, scritto
> una volta con `--init`. Il marcatore identifica la **directory**, non il contenuto: funziona
> anche su una dest legittima ma vuota (primo deploy). Senza `--delete` il deploy è **additivo**
> (i file rimossi in locale restano nella dest) — ed è il default, perché un residuo è rumore
> mentre una cancellazione sbagliata è un incidente. È un'invariante che il **codice
> garantisce**, non una disciplina dell'operatore: stesso principio del controllo di topologia
> di `train.sh` (ARCH-4).

Corollario, già registrato il 2026-08-21 e ora **accettato come costo noto**: l'esclusione di
`.neural-c.lock` dal deploy vive solo sulla macchina di sviluppo e va riapplicata a mano se il
file viene ricreato. Con lo script non versionato per scelta, questo è il prezzo — reso
esplicito qui perché chi ricrea il file sappia cosa manca.

## VOCFMT-1 — Il vocabolario non poteva esprimere uno spazio — **FATTO** (2026-08-24)

Aperta e chiusa nella stessa sessione, su richiesta dell'utente («mi sembra grave e facile da
risolvere»). **Aveva ragione sulla gravità e io l'avevo classificata Media**: la voce, come
l'avevo scritta, sbagliava il meccanismo in due punti su tre.

### Che cosa avevo scritto di sbagliato

1. *«Il caricatore tronca gli spazi ai bordi, in silenzio»* — **falso come difetto**: il
   troncamento è **necessario**, perché il vocabolario allinea i pattern in colonne e ogni riga
   porta spazi di riempimento. Una guardia che lo rifiutasse avrebbe bocciato l'intero file
   (verificato: **tutte** le righe hanno spazi finali).
2. *«`(^| )ultim` non funziona da ancora perché `[[ =~ ]]` cerca in qualsiasi posizione»* —
   **falso**: misurato in isolamento, `(^| )ultim` in bash ERE si comporta correttamente, non
   matcha `nell'ultima` e matcha `nell ultima`. La semantica della regex non era il problema.
3. Il **fatto osservato** era vero: messo nel vocabolario, `(^| )ultim` non vincolava nulla.

### Il meccanismo vero

`query-to-features.sh` faceva `${pattern// /}` — sostituzione **globale**, non un trim. Quindi
cancellava anche gli spazi *voluti*, in due direzioni opposte ed entrambe silenziose:

| scritto | caricato | effetto |
|---------|----------|---------|
| `(^| )ultim` | `(^|)ultim` | un ramo **vuoto** nell'alternanza matcha la stringa vuota in qualsiasi posizione: il vincolo di confine **sparisce**, il pattern equivale a `ultim` nudo |
| `ultima ora` | `ultimaora` | non può matchare **nulla**: feature **morta**, sempre 0, e continua a contare in `NUM_FEATURES` |

La seconda è la ragione per cui l'utente aveva ragione a chiamarla grave: è un **input
permanentemente a zero** nel modello, senza alcun errore, e chi ha scritto il pattern crede
che funzioni. Un peso dichiarato nel vocabolario che non può mai essere applicato.

### Il fix, e perché è finito altrove rispetto a dove l'avevo messo

La normalizzazione è stata **spostata al punto di carico** (`nlp/tools.conf`), dove agisce una
volta per file e toglie solo gli spazi **adiacenti a `::`** — che sono il riempimento e
nient'altro. Il ciclo caldo di `query-to-features.sh` non tocca più il pattern.

Le due versioni intermedie correggevano il difetto **dentro** il ciclo — prima con una
funzione a nameref, poi inline — e **misuravano 1,8× più lento** (7,2 → 13,1 e 6,4 → 12,2 ms
per query). Non per i fork, che non c'erano, ma perché normalizzare 119 pattern a ogni query
è il posto sbagliato: con ~250 espansioni annidate per query il costo è reale, e il commento
di `query-to-features.sh` dichiara quel costo come una proprietà ingegnerizzata
(112 ms → 5 ms eliminando i fork). Averlo misurato invece di presumerlo ha cambiato la forma
del fix.

Nella versione finale una sola `sed` per file fa i tre lavori che prima erano due `grep`:
scarta i commenti, scarta le righe vuote, normalizza il riempimento. **Un processo per file
invece di due**, quindi il fix costa **meno** dello stato di partenza: misurato **5,5 ms
contro 6,7–8,9 ms** per query.

### Una dipendenza che ho quasi rotto

Il commento in `build_dataset.py` dichiarava che la forma `ora |ore |ora$` sfruttava lo strip
globale come **separatore visivo**. Se un pattern la usasse, il passaggio a trim ne cambierebbe
la semantica. La mia prima misura — «0 unigrammi con spazio interno» — cercava `[a-z] [a-z]` e
**non** avrebbe catturato `ora |ore`, che è lettera-spazio-**pipe**. Rimisurato correttamente
(trim del campo, poi ricerca di spazi residui): **zero pattern** in entrambi i file. Nulla
dipendeva da quel comportamento, e il commento è stato aggiornato perché non prometta più una
capacità rimossa.

### Verifica

`tests/test-vocab-format.sh`, 10 asserzioni su un **profilo temporaneo** con un vocabolario di
tre pattern — non quello reale, che cambierebbe `NUM_FEATURES` e richiederebbe un retrain.
Copre le due forme corrette **e** lo scopo originale (riempimento rimosso, peso numerico
pulito), più una guardia anti-confronto-vacuo in testa.

Validate con una reversione del fix: **3 FAIL mirati** — esattamente le asserzioni sui
comportamenti nuovi — mentre le 7 sullo scopo originale restano verdi, cioè la prova di non
aver rotto ciò che funzionava.

Vettore di feature **invariato** sul vocabolario reale (md5 `123be090d436`), `NUM_FEATURES`
119, dataset rigenerato bit-identico col backend Python, pesi `bef9198b…`, parità 1171/1171.
**Nessun retrain.**

## APOSTR-1 — L'apostrofo: una lacuna di TEST, non di training — **FATTO** (2026-08-24)

Aperta poche ore prima con una premessa **sbagliata**, e riformulata su richiesta
dell'utente, che non aveva creduto alla mia archiviazione come «non-problema» e ha
chiesto: *«alcune query si spaccano e danno risultati inattesi?»* — la risposta era **sì**.

### La premessa sbagliata, e la misura che l'ha corretta

Avevo scritto che «il classificatore non è mai stato *addestrato* su query con elisione,
quindi non si sa come si comporti», proponendo di aggiungere esempi al dataset con un
retrain. **Misurato: i vettori sono identici.** I pattern del vocabolario sono sottostringhe
**non ancorate** (`ultim`, non `\bultim\b`), e per i 40 pattern che usano `\b` l'apostrofo è
comunque un confine di parola. Su 12 query con elisione confrontate con la rispettiva forma
senza apostrofo: **0 divergenze**. Zero unigrammi contengono uno spazio interno, e i 10
bigrammi hanno i due lati valutati separatamente — quindi nulla può essere spezzato da
un'elisione.

Conseguenza: aggiungere esempi con apostrofo al dataset produrrebbe righe con vettori
**bit-identici** a quelle già presenti. Righe duplicate, non informazione. **Il retrain non
comprerebbe nulla.**

### Ma la lacuna era reale, su un altro asse

Zero query con apostrofo nel dataset significava anche **zero query con apostrofo in tutto
il repo**: nessuna asserzione, in nessun test, esercitava un'elisione. Non un problema di
*addestramento* ma di *copertura*, ed è la ragione per cui due stadi della pipeline erano
rotti e nessuno lo sapeva:

| stadio | l'apostrofo conta? | stato |
|--------|--------------------|-------|
| `normalize-query.sh` → `NORM_QUERY` | **sì** | era rotto — SRCH-5/D4, corretto |
| `query-to-features.sh` → vettore | no (misurato) | corretto per costruzione |
| `param-extract.sh` → parametri | **sì** | **era rotto — vedi sotto** |
| routing | derivato dai tre sopra | ok |

### Il sesto difetto: SEARCH_PATTERN fantasma

`param-extract.sh` estraeva gli span con una `grep -oE "'[^']*'"` **ingenua**, quindi due
elisioni consecutive diventavano una citazione:

    cerca l'eccezione nell'app dell'utente  →  SEARCH_PATTERN='eccezione nell'
    cerca nell'access log l'errore          →  SEARCH_PATTERN='access log l'

Misurato su 5 formulazioni italiane naturali: **5 fantasmi su 5**, quindi sistematico e non
un caso limite. E la conseguenza era una **risposta sbagliata silenziosa**: il classificatore
instradava correttamente su `search_all_logs` (96,7%), il tool cercava nei log la stringa
mutilata e rispondeva «nessuna occorrenza» a una domanda che il bot aveva capito benissimo.
Il caso peggiore, perché sembra funzionare.

Dopo il fix il valore è `__MISSING__`, e `search_all_logs.sh:51` chiede all'utente di
racchiudere la stringa fra virgolette: da «cerco un frammento e non trovo nulla» a «non ho
capito cosa cercare, dimmelo così» — un fallimento che si dichiara.

**Perché è sopravvissuto alla correzione di poche ore prima**, che aveva centralizzato questa
stessa regola: avevo deciso — correttamente — che `SEARCH_PATTERN` e `NAMED_LOG_GLOB` devono
leggere la query **grezza**, perché a loro lo span serve davvero. Da lì ho concluso —
erroneamente — che potessero tenere la **propria regex**. Sono due cose diverse: leggere il
testo grezzo *attraverso* la regola condivisa, non aggirandola. **Il principio 8 per la terza
volta nella stessa sessione**, e le prime due non hanno impedito la terza.

**Perché i test non l'avevano preso**: le asserzioni sull'apostrofo che avevo scritto
verificavano che il **filtro temporale** non si disattivasse. Passavano, ed erano vere. Non
guardavano `SEARCH_PATTERN`, perché stavo pensando all'apostrofo come minaccia al *tempo*. Un
parametro «coperto» non è coperto in tutte le sue forme — la lezione di THR-1 su un'altra
superficie.

### Il rimedio: copertura sui quattro stadi

Non esempi nel dataset ma **asserzioni lungo tutta la pipeline** (`test-normalize-query.sh`,
sezione APOSTR-1): `NORM_QUERY` intatta su 6 elisioni, vettore identico con e senza apostrofo
su 4, i parametri, e il routing confrontato col vincitore della forma senza apostrofo — non
con una confidenza assoluta, che cambierebbe a ogni retrain. Più 10 asserzioni sui fantasmi
in `test-param-extract.sh`. **Nessun retrain, checksum invariato.**

Passata di principio 8 su tutto il codice a caccia di altre regex ingenue sugli apici: due
falsi positivi certi (`dispatch.sh:558` opera su un'espressione costruita dal codice,
`build_dataset.py:65` parsa `VAR='valore'` da un file di configurazione) e il ramo glob
verificato **non** innescabile da un'elisione. Nessun altro chiamante da migrare.

### E una guardia contro il verde per nulla

Le quattro asserzioni sul vettore, nella prima stesura, erano **vacue**: l'helper non
chiamava `nlp_resolve_paths()`, quindi `query-to-features.sh` usciva con stdout vuoto e il
test confrontava `""` con `""`. Trovate verificando che gli helper producessero valori reali
invece di fidarsi del PASS. Aggiunta una guardia esplicita che asserisce che il vettore
esista e abbia feature attive **prima** dei confronti — lo stesso difetto di GAPREP-1, dove
un `|| true` faceva dichiarare «nessun gap» per una misura mai avvenuta.

Le asserzioni sono poi state **validate con una mutazione deliberata**: `[[:space:]]ultim` al
posto di `ultim` porta la feature da 2 a 0 sulla forma con apostrofo e produce **3 FAIL
mirati** — esattamente le tre query che contengono `ultim`, con la quarta correttamente
verde. I due tentativi di mutazione precedenti erano stati vanificati dal formato del
vocabolario, e da lì è nata **VOCFMT-1**.

## TOKEN-1 — Token GitHub in chiaro: rimosso e revocato — **FATTO** (2026-08-24)

Segnalato il 2026-08-20 e il 2026-08-21 **solo nei pendenti dei session log**, e per due
volte slittato. Chiuso su richiesta dell'utente. La prima lezione è quella: il backlog è la
fonte di verità, e una voce che non è qui non viene ripresa — per questo la voce è stata
creata *prima* di essere chiusa, invece di risolvere il problema in silenzio.

### Che cosa era esposto, misurato prima di agire

`.git/config` conteneva `https://lucatagliavini:<TOKEN>@github.com/…` con permessi **`644`**,
cioè leggibile da **qualsiasi utente della macchina**, dal 3 agosto: 21 giorni. Storia git,
server di produzione, `bash_history` e la trascrizione di chat salvata: **tutti puliti**.
Restavano 9 trascrizioni `~/.claude/projects/*.jsonl` (directory `700`).

### Quattro cose che l'accertamento ha cambiato rispetto alla descrizione del problema

**1. L'allarme peggiore era un falso allarme.** `git grep` ha trovato `ghp_` in un file
**versionato** (`docs/sessions/2026-08-17-01.md:331`) — che con un `origin` su GitHub
significherebbe un segreto **pubblicato**. Era la prosa che descriveva il difetto, con
un'ellissi: **zero caratteri** dopo il prefisso. Agire sull'allarme avrebbe voluto dire
riscrivere la storia git per nulla.

**2. Il token era ridondante, non necessario.** `gh auth setup-git` risultava **già
configurato** prima di eseguirlo: git era già istruito a chiedere le credenziali a `gh`, che
le tiene in un file **`600`**. Ma un URL con `user:token@` fa sì che git usi quelle
credenziali e **non consulti mai** il credential helper. Il segreto stava scavalcando un
meccanismo già presente e meglio protetto, quindi il fix consisteva nel **togliere**.

**3. Lo stesso token era condiviso con un secondo repository.** `neural-bash` — il
predecessore da cui questo è stato separato via `git subtree split` — aveva lo stesso segreto
nell'URL, verificato **per hash** e non per ispezione. La revoca, così com'era, avrebbe rotto
i push di quel repo senza una causa apparente. Bonificato anche quello.

**4. SSH è escluso dall'ambiente, non da una preferenza.** `github.com:22` va in timeout e
**anche `ssh.github.com:443`**: il firewall li blocca entrambi. Con SSH fuori gioco il
criterio diventa «quale segreto è protetto meglio», e `gh` vince per i permessi del file.

### Ordine di esecuzione, e perché conta

La **scrittura** è stata provata (`git push --dry-run`, exit 0) con l'URL privo di
credenziali **prima** di rimuovere il token: altrimenti si distruggerebbe l'unica copia del
segreto senza aver dimostrato che l'alternativa funziona. Stessa sequenza sui due repo.

### Esito, verificato dopo la revoca

- Nessun repository nella home ha credenziali in un URL (ricontrollato)
- I due `.git/config` da `644` a **`600`**
- `gh` ancora autenticato, scope `repo` intatto; `fetch` e `push --dry-run` **exit 0 su
  entrambi** i repository
- Token **revocato dall'utente** su GitHub: è il solo passo che rende il segreto inutile a
  chi lo ha già letto, e va distinto dal rimuoverlo dal disco — averli confusi è il motivo
  per cui una voce di sicurezza può *sembrare* chiusa restando aperta
- Le 9 trascrizioni sono state **lasciate come sono** su scelta dell'utente: a revoca
  avvenuta quelle stringhe sono inerti, e la directory è `700`

**Nota che evita un errore in futuro**: la credenziale di `gh` è un token **OAuth** (`gho_`)
che vive sotto *Authorized OAuth Apps*, pagina diversa dai Personal access token — revocare
un PAT non può rompere `gh`.

## SRCH-5 — `search_all_logs` provato in produzione: cinque difetti — **FATTO** (2026-08-24)

Il tool era **l'unico dei 16 mai eseguito sui log veri**, escluso dallo sweep del 2026-08-21
per durata, ed è quello con la superficie più ampia. La voce prevedeva che «la probabilità
che il tool con la superficie maggiore sia l'unico pulito è bassa». Eseguito sul nodo 4 di
`prod`: 353 file, 294 MB, 190 `.gz`, due app.

**Verificato funzionante**, e va detto perché è metà del risultato: politica cross-app con
colonna APP (principio 6), lettura `.gz` (39 dei 40 file con match sono compressi), tempo
di risposta 8,2–17,2 s su 49 file con 4 worker, estrazione del pattern quotato, marcatore
`*` con nota per i timestamp solo-ora.

**Cinque difetti**, di cui quattro trovati provando il tool e uno cercando la causa di un
conteggio che non tornava. Ognuno misurato contro una verità di riferimento `grep`
indipendente, mai dedotto dal codice.

### D1 — Il filtro temporale saltato sui log con timestamp non riconosciuto

Query `cerca "MOVE_TO_QUEUE"` con finestra **oggi**: **61 occorrenze** riportate contro **4**
corrette. **15,25×**, lo stesso ordine di THR-1. Prova isolata: una stringa presente solo
nella rotazione del 15 agosto (`cc-1786662052345-375622044`) veniva restituita da una query
su oggi.

Causa: 2 gruppi di log su 14 sono JSON-lines, col timestamp dentro un campo —
`{"UpdateTime":"2026-08-24 03:08:01.352"` e `{…"time":"2026-08-24T07:12:12.514CEST"`.
Nessuna grammatica li riconosceva, quindi `search_all_logs.awk` saltava il filtro riga
(richiede `eff_has_date`) e includeva tutto (principio 5).

**Due sotto-casi con sintomi opposti, e il secondo è il più insidioso:**
- **KPI** — nessuno dei due gemelli riconosceva → `ts_start=0`, il walk di
  `select_log_files_grouped` non si fermava mai e leggeva **tutte le 11 rotazioni**, cioè
  l'intera retention, per una query su oggi.
- **JF4U** — il gemello **bash** riconosceva (via il ramo ISO non ancorato), quello awk no.
  La selezione file sembrava corretta, quindi **niente suggeriva un problema**, e il filtro
  riga era saltato comunque. `utils-logline.awk:5` dichiara che le due liste vanno tenute in
  parità: era rotta, e in silenzio.

Corretto con **una** grammatica per entrambe le forme (`"chiave":"<data>[ T]<ora>"`),
aggiunta ai due gemelli. Ultima posizione, e la ragione è verificata ramo per ramo, non
presunta: nessuno dei 6 esistenti matcha una riga JSON (1-2 richiedono la quadra, 3/5/6 sono
ancorati a `^` e la riga apre con `{`, 4 richiede un `LEVEL`). Stare per ultimo **protegge**
anche il caso inverso — una riga di access log con un corpo JSON resta gestita dal ramo 1.

**La stessa grammatica mancante causava due difetti opposti in due tool**, e la simmetria è
la parte istruttiva: `search_all_logs` **contava tutto** (61 contro 4), `grep_named_log`
— che filtra col criterio opposto, `row_epoch <= 0 → next` — **non trovava nulla** (0 righe
contro 1 corretta, misurato). Un falso positivo clamoroso e un falso negativo silenzioso
dalla stessa radice.

### D2 — Le occorrenze non filtrabili contate in silenzio

Il difetto di D1 è rimasto invisibile perché una riga che il filtro non può valutare veniva
**inclusa** (principio 5, corretto) e **contata senza dirlo** (non corretto). Il principio 5
protegge dal falso negativo sulla *selezione file*; applicato al *conteggio* produce un
numero sbagliato presentato come giusto.

Aggiunto un **quinto campo** `unfiltered` al contratto di `search_all_logs.awk`, marcatore
`!` per riga e nota a piè di tabella. Un **conteggio** e non un flag per-file, perché un log
può essere misto. In coda a ogni salto, così `hits` resta in posizione 2 e la somma parziale
del progresso (`awk -F'|' '{s+=$2}'`) non va rinumerata.

La nota è tenuta **distinta** da quella del `*`: `*` riguarda la precisione del min/max
mostrato, `!` la validità del conteggio rispetto alla finestra chiesta. Confonderle farebbe
leggere un problema di visualizzazione dove c'è un problema di misura.

**Una distinzione che il test ha dovuto insegnare:** «senza data» non è «non filtrabile».
Una riga priva di timestamp **eredita** quello dell'ultima riga datata (il meccanismo che
tiene insieme una stack trace con la sua eccezione, 2026-08-05), quindi è filtrabile. Non
filtrabile è solo la riga che non ha nulla da cui ereditare. La prima fixture asseriva 1 e
otteneva 0: era la fixture a violare un'invariante voluta, non il codice — la quarta volta
in questo progetto.

### D3 — La stringa cercata decideva dove si cercava

`cerca "chiamata al nodo 7" nel nodo 4`, con `--node 4` **anche** sulla riga di comando:
il bot ha cercato sul **nodo 07**. Verificato end-to-end in produzione. Idem
`cerca "utente su ContactManager"` → `DETECTED_APP=contactmanager`, e
`cerca "api-gateway timeout"` → `NAMED_LOG='api'` con un avviso che accusava l'utente di
aver nominato un log che non aveva nominato.

Causa comune: la regione quotata — l'unico pezzo della query che **non** è linguaggio
naturale — non era sottratta agli estrattori. **Sette leak in più erano stati dedotti dal
codice e non misurati; provati poi tutti veri**, e il più insidioso è quello temporale:

| query | prima |
|-------|-------|
| `cerca "errori di ieri"` | `TIME_FROM` = ieri — **sposta la finestra** |
| `cerca "errore 500 interno"` | `STATUS_CODE=500` |
| `cerca "chiamata da 10.1.2.3 rifiutata"` | `IP_FILTER=10.1.2.3` |
| `cerca "riga di ERROR grave"` | `LEVEL_EXPLICIT=1` |

Corretto con `lib/utils-quoted.sh`, punto unico, e **due correzioni speculari** perché
`chatbot.sh` passa la query grezza a due pipeline indipendenti:
- `param-extract.sh` — maschera in **un solo punto** (`query="${1,,}"`), che copre tutti e
  nove gli estrattori invece di correggerne uno alla volta;
- `normalize-query.sh` — maschera prima del rilevamento entità e **ripristina** prima della
  sezione 3.5. Preferito allo spostamento della sezione: quel blocco ha un sotto-ramo
  (SRCH-4) che **rimuove** le virgolette lasciando il nome letterale, e spostarlo lo
  esporrebbe alle sezioni da cui lo si protegge — sposterebbe il difetto. È anche ciò che
  garantisce `NORM_QUERY` invariato e quindi **nessun retrain**.

**Una regressione che il fix ha causato e i test preesistenti hanno intercettato:** il
mascheramento indiscriminato ha rotto SRCH-4, perché un log **di sistema** citato
(`errori nel "server.log"`) è un log che l'utente sta **nominando**, non una stringa da
cercare. Avevo previsto la sottigliezza per una pipeline e l'avevo mancata per l'altra —
il principio 8 nella sua forma esatta. Corretta riusando `system_log_kind_of`, la fonte di
verità già condivisa.

**Un difetto nel rimedio, trovato prima di committarlo:** la prima versione di
`quoted_spans_of` emetteva prima tutte le doppie e poi le singole, mentre le sentinelle
stanno nella stringa in ordine **posizionale**: su `trova 'x' e "y" ora` il ripristino li
avrebbe **scambiati**. Corretto con una scansione unica ad alternanza.

### D4 — L'apostrofo italiano letto come citazione

Trovato **verificando la parità** su query fuori dataset. Il ramo `a-bis` usava `'[^']*'`
senza delimitatori, e in italiano l'apostrofo è graficamente la virgoletta singola:

    «errori nell'ultima ora dell'app»  →  «errori nell<PATTERN>app»

L'espressione temporale **spariva dal vettore di feature**. Misurato sul classificatore:
confidenza da **66,2% a 56,8%**, e `search_all_logs` compariva al **13,3%** — perché
`<PATTERN>` è per costruzione il segnale «qui c'è una stringa da cercare», che quella frase
non conteneva. Il vincitore teneva, ma su una query con margine minore girerebbe.

Sopravvissuto perché **zero delle 1171 query etichettate contiene un apostrofo**: il dataset
non rappresenta la forma più naturale dell'italiano, quindi nessun test poteva inciamparvi.
È anche la ragione per cui correggerlo non ha richiesto retrain.

Corretto migrando il ramo alla regola di `utils-quoted.sh` (una coppia di apici è citazione
solo se **delimitata** da spazi). Un chiamante non migrato, di nuovo il principio 8.

**Limite dichiarato e asserito**, non scoperto da un utente: una citazione fra apici singoli
non può contenere un apostrofo, perché nessuna regola locale distingue `'errore nell'app'`
da due elisioni. Stesso vincolo del quoting di shell, stesso rimedio: virgolette doppie.

### D5 — «ultimi N giorni» non interpretato

`TIME_FROM`/`TIME_TO` vuoti → fallback **silenzioso** a oggi: chi chiedeva sette giorni
riceveva oggi senza avviso. Asimmetria nella grammatica: esistevano
`ultim[aeio] [0-9]+ or[ae]` e `[0-9]+ minut`, per i giorni solo `ultim[aeio] giorn`, che il
numero interposto non fa matchare.

Aggiunto `_RE_LAST_N_DAYS` con semantica **calendario, oggi incluso** (scelta con l'utente):
`ultimi 7 giorni` = `2026-08-18T00:00 → 2026-08-24T23:59`. Coerente con `ieri`/`oggi`, e su
un log copre rotazioni **intere** invece di tagliarle a metà giornata — quindi la risposta
non cambia secondo l'ora in cui si pone la domanda. `date_filter` resta vuoto: la frase
nomina più rotazioni, e la selezione la guida il range.

Collocato **prima** di `_RE_LAST_DAY` anche se oggi non collidono, per non dipendere da
un'assenza di collisione che una modifica futura alla regex più generica rimuoverebbe in
silenzio.

### E un difetto nei test, trovato da un conteggio che non tornava

Aggiunte 5 asserzioni a `test-logline.sh` e il totale della suite **non si muoveva**. La
prima spiegazione era corretta — `run-tests.sh` conta i file esterni come un PASS ciascuno —
ed era anche quella che nascondeva il difetto: **`tests/test-normalize-query.sh`, 302 righe e
56 asserzioni, non era nella lista del runner**. Un file sano (56 PASS, exit 0),
semplicemente dimenticato, che non ha mai protetto nulla dalla suite — ed è il test del file
modificato per D3 e D4. Aggiunto alla lista, con l'intestazione della sezione allineata.

### Esito

- **186 PASS / 0 FAIL** su entrambi i profili, `--parity` **1171/1171** su entrambi
- **Nessun retrain**: `queries.txt` rigenerato bit-identico **col backend Python** (cioè col
  codice modificato), pesi `bef9198b…` invariati, `input 119`, training deterministico
- Ogni test nuovo eseguito **prima** del fix per vederlo fallire; il loop di parità dei
  gemelli validato con una **mutazione deliberata** (ramo rimosso da un solo lato → 5 FAIL
  mirati, fra cui entrambe le asserzioni di parità), file ripristinato bit-identico

## SVCGRAN-2 — Un prefisso fisso che consumava le componenti — **FATTO** (2026-08-21)

Chiusa poche ore dopo SVCGRAN-1, che l'aveva aperta: con `SERVICE_PATH_DEPTH=3` i REST si
separavano ma i **14 servizi SOAP** collassavano in una riga, `essigSXCC/ws/it`, **6.967
chiamate a 446 ms medi**.

### La misura che ha escluso la strada ovvia

| profondità | gruppi | esito |
|---|---|---|
| 3 (allora) | 37 | SOAP tutti in `ws/it` |
| 4 | 59 | SOAP in `ws/it/unipol` — peggio |
| 8 | **1337** | sfascia i REST, inutilizzabile |

Il difetto **non era «troppo poco profondo»**: era che un prefisso fisso e privo di
informazione — `it/unipol/sx/webservice`, cioè un **package Java** — consuma quattro
componenti prima che cominci il nome del servizio. Alzare il numero peggiora la cosa, perché
la stessa profondità serve due famiglie di URL con forme diverse.

### La soluzione: sequenze trasparenti

`SERVICE_PATH_TRANSPARENT` in `system.conf` — sequenze di componenti saltate nel conteggio
della profondità. Con `it/unipol/sx/webservice` e `it/unipol/sx/service` trasparenti e
profondità 4, misurato in produzione:

| | prima | dopo |
|---|---|---|
| SOAP | `ws/it` (6.967 chiamate, 446 ms) | `ws/ivr/CliIdentify` **1595 ms**, `ws/unitools/UploaderUnitools` **1869 ms**, `ws/verbatel/VerbatelAPI` 804 ms, `ws/fiduciari/WsUtility` 416 ms… |

**Sono SEQUENZE e non segmenti singoli, e la distinzione è necessaria, non estetica**:
`service` da solo è **significativo** in `/essigSXCC/service/ccfeireceiverequest` — 275
chiamate, MAX 147 s. Un filtro per-segmento ripulirebbe i SOAP distruggendo quell'endpoint.
C'è un'asserzione dedicata a proteggerlo.

Applicate dalla più lunga alla più corta indipendentemente dall'ordine in cui il profilo le
scrive: con la corta prima resterebbe un `webservice` orfano nel nome, e far dipendere il
risultato dall'ordine di scrittura sarebbe una trappola silenziosa. Confronto **letterale**
con `index()` e non `gsub()`: una sequenza è un pezzo di path, non una regex, e un `.` in un
nome di segmento diventerebbe un metacarattere — un difetto che si manifesta solo su certi
profili.

### Perché profondità 4 e non 3, deciso su misura

A 3 con le trasparenti attive i SOAP escono per **area**: `ws/ivr` a 936 ms. A 4 escono per
**servizio**, e si vede che dentro quell'area **`CliIdentify` sta a 1595 ms** e ne trascina
la media. Il costo sui REST è solo un'**etichetta più lunga** (`rest/caidigitale/v2.0`): il
gruppo contiene le stesse chiamate, non si perde nulla. Valutata e **scartata** anche la
variante con le versioni trasparenti (`v1`, `v2.0`): porterebbe i REST al livello di
**metodo** — utilissimo, ma il tool si chiama `service_times`, non `operation_times`, e
frammenterebbe un servizio con molti metodi in molte righe.

### Un avviso automatico che la misura ha bocciato

Volevo generalizzare l'avviso di degenerazione: «segnala un gruppo che nasconde troppa
struttura». **Non è fattibile**, e il dato è netto — per ogni gruppo a profondità 3, quanti
path distinti nasconde:

| gruppo | path nascosti | è un problema? |
|---|---|---|
| `essigSXCC/service/app` | **938** | no — URL per risorsa |
| `essigSXCC/resources/img` | **262** | no — immagini statiche |
| `essigSXCC/ws/it` | **14** | **sì** |

Il gruppo problematico nasconde **meno** struttura di due che vanno benissimo: la metrica non
distingue un gruppo che cela *servizi* da uno che cela *risorse*. Un'euristica su quel
segnale avrebbe gridato al lupo su `resources/img` a ogni query. L'avviso resta quindi a
**un** gruppo, e la degenerazione parziale si affronta con la configurazione. **Un'opzione
scartata su dati è più solida di una implementata su intuizione.**

### Limiti residui, visibili e non silenziosi

Tre aree hanno un `service` **annidato** e restano `ws/anagrafica/service`,
`ws/sinistri/service`, `ws/serviziagenzia/service`; e 2 chiamate su ~7.000 seguono un path
che non combacia con nessuna sequenza e restano `ws/it/unipol`. Entrambi compaiono
nell'output, quindi si vedono.

### Verificato in produzione PRIMA del commit

Su indicazione dell'utente, e il metodo vale la nota. La verifica è stata fatta su una copia
isolata in `/tmp` — non sull'albero deployato — eseguendo il `chatbot.sh` reale col profilo
modificato. Ha richiesto due correzioni di *metodo*, non di codice: la prima invocazione
leggeva il **solo file corrente** dell'access log, che alle 15:05 era appena ruotato e aveva
680 righe invece di 333.296 (`dispatch.sh` include le rotazioni via
`select_log_files_grouped`); la seconda moriva silenziosamente perché una copia in `/tmp`
rompe il layout a **cartelle sorelle** e `infer.sh` non trovava `../neural-c`. Entrambe
avrebbero prodotto conclusioni sbagliate se non le avessi diagnosticate. Copie temporanee
rimosse dal server a verifica conclusa.

## VENVGATE-1 — Un gate che proteggeva da una dipendenza rimossa — **FATTO** (2026-08-21)

**Il gate.** `build-dataset.sh` sceglieva il backend con `[[ -x .venv/bin/python3 ]]`. Il
venv esisteva per **PyTorch**, quando il training passava da `lib/train.py`; quel file è
stato rimosso il 2026-08-18 e il motore è `neural-c` (C, nessuna dipendenza Python). Il gate
è restato, e `lib/build_dataset.py` importa **solo stdlib** — il `python3` di sistema gli
basta. Verificato: in `.venv/…/site-packages` ci sono ancora `functorch`, `filelock`,
`fsspec`, `jinja2`.

**Il costo, misurato.** In produzione esiste `/usr/bin/python3` **3.9.25** e **non** esiste il
`.venv`. Ogni `build-dataset.sh` sul server prendeva quindi il ramo bash:

| ramo | tempo |
|---|---|
| Python | **0,2 s** |
| bash | **≥110 s** (54 s misurati per la sola normalizzazione di 1171 query, ×2 subprocess per riga) |

Il gate rinunciava all'unico backend veloce proprio sulla macchina che ne ha più bisogno,
per proteggere da una dipendenza che non esiste più.

**Tre chiamanti, non uno — e il terzo era il peggiore.** La passata di principio 8 ha
trovato che il criterio era scritto tre volte, in tre modi:

| dove | criterio | esito senza `.venv` |
|---|---|---|
| `build-dataset.sh` | `-x .venv/bin/python3` | ramo bash, 500× più lento |
| `tests/test-normalize-parity.sh` | idem, poi **`exit 1`** | `--parity` **FALLIVA** in produzione |
| `vocab-gap.sh` | `command -v python3` | corretto |

Il secondo è il più grave: su una macchina senza venv la suite riportava un **FAIL** senza
che nulla fosse rotto, e il messaggio suggeriva `pip install -r requirements.txt`, che oggi
non serve a niente. **E il quarto criterio l'ho aggiunto io lo stesso giorno con GAPREP-1**:
il difetto non era solo storico, si stava replicando.

**Il fix.** `lib/utils-python.sh` → `resolve_python()`, con precedenza `NLA_PYTHON` → `.venv`
→ sistema, e tutti i chiamanti migrati. Il `.venv` resta **preferito** quando c'è, perché è
un override per-installazione (chi lo crea di proposito vuole che venga usato, come
`system.local.conf` vince su `system.conf`); ciò che cambia è che la sua **assenza non è più
un errore**.

`NLA_PYTHON` non è un aggancio per i test: pinna un interprete senza creare un venv, e se è
impostato ma non eseguibile `resolve_python` **fallisce** invece di ricadere in silenzio —
chi ha pinnato ha espresso una scelta, e scavalcarla nasconderebbe un errore di
configurazione (ARCH-6).

**La verifica che rende sicuro rimuovere il gate**: il dataset generato dal `python3` di
**sistema** è **bit-identico** a quello committato (generato dal venv). Se i due interpreti
divergessero, la produzione otterrebbe un dataset diverso dal locale e il modello sarebbe
addestrato su input non riproducibili.

**E qui una mia affermazione era sbagliata, corretta dalla verifica in produzione.** Avevo
scritto che in produzione ci fosse **3.12.3** come in locale: non l'avevo verificato, avevo
letto solo il PATH dell'interprete. La versione reale è **3.9.25** — due minor release di
distanza, cioè esattamente la differenza che rende non ovvia la domanda. Verificato dal vivo
dopo il deploy, e l'esito è **più forte** di quello che avevo affermato: `build-dataset.sh` su
3.9.25 rigenera `queries.txt` con md5 identico a quello di 3.12.3, e `gap-report.sh` dà gli
stessi 74 candidati. L'output è stabile fra 3.9 e 3.12 **per misura**, non per presupposto.

Conseguenza operativa che prima non era scritta da nessuna parte: il codice Python del
progetto deve restare compatibile con **3.9**, non con la versione della macchina di
sviluppo. Niente `match`, niente `X | Y` negli annotamenti, niente novità 3.10+.

**Tre esiti invece di due, in tutta la suite.** Correggendo il `exit 1` è emersa la
domanda generale: come si riporta un test che *non può* misurare? Ora `0` = misurato,
`2` = **non misurabile**, altro = fallimento vero, e `run-tests.sh` stampa `SKIP` senza
contarlo né fra i PASS né fra i FAIL. Su una macchina senza `python3` la suite dà
**184 PASS / 0 FAIL con 2 SKIP espliciti** invece di sei FAIL che accusano il codice.

Un dettaglio che vale la lezione: la prima versione di quella guardia in
`test-vocab-gap.sh` usciva **0**, quindi `run-tests.sh` la contava fra i PASS — **un verde
per un test non eseguito**, cioè esattamente il difetto corretto in GAPREP-1, reintrodotto
dal test che lo protegge. Corretta in `exit 2`.

Effetto collaterale utile: l'asserzione «senza python3» di `test-vocab-gap.sh` usava un
`PATH` svuotato, che ha smesso di funzionare (il venv si trova per path **assoluto**) e
infatti dava `exit 127` — verificava un guasto diverso da quello che credeva. Ora usa
`NLA_PYTHON`, che è deterministico.

## SVCGRAN-1 — La granularità del "servizio" è una coordinata, non una costante — **FATTO** (2026-08-21)

`service_times` restituiva **una riga per 214.594 chiamate**: `essigSXCC`, cioè l'access log
intero sotto un'unica etichetta con dei percentili addosso. Raggruppava su
`access_url_root()`, il **primo segmento del path**.

**Non era codice rotto, e questo è il punto della voce.** La scelta era documentata
(`utils-access-undertow.awk`: "servizio macro", granularità deliberatamente diversa da
`access_url_endpoint()`), ed è **giusta** per un deployment dove ogni servizio ha il proprio
context root. La prova è nel secondo profilo, misurata sull'access log reale del nodo 3:

| profondità | `usnext` (24.086 righe) | `liquido` (295.743 righe) |
|---|---|---|
| 1 | **6 gruppi** — `portal`, `spd`, `api`, `integration`… ✓ | **1 gruppo** ✗ |
| 2 | 6 gruppi (nessun guadagno) | 13 gruppi |
| 3 | 17 gruppi (più fine del necessario) | **37 gruppi** ✓ |

Due deployment della **stessa tecnologia** con strutture URL diverse, che hanno bisogno di
valori diversi: è la definizione di una coordinata (principio 7). Quindi
`SERVICE_PATH_DEPTH` vive in `system.conf` — 1 per `usnext`, 3 per `liquido` — e **non ha un
default nel codice** (ARCH-6): `dispatch.sh` rifiuta di eseguire il tool se il profilo non lo
dichiara, con un messaggio che spiega *cosa significa* il numero, non solo che manca.

Nuova funzione condivisa `access_url_service(depth)`, che generalizza `access_url_root()` —
depth=1 le è equivalente, verificato da un'asserzione dedicata, così `usnext` non è cambiato
di una virgola. Applica le stesse sostituzioni di ID/UUID di `access_url_endpoint()`: a
profondità 1-3 raramente cambiano qualcosa, ma rendono stabile una profondità maggiore.

**L'avviso è la parte che conta più del parametro.** Il tool ora dice, quando trova un solo
gruppo, che la profondità configurata non distingue nulla e che i numeri sotto sono quelli
dell'access log intero. La soglia è **un** gruppo e non "pochi": due gruppi possono essere la
verità di un deployment con due servizi, uno solo non lo è mai — raggruppare per una chiave
costante non è raggruppare. Senza questo avviso il difetto era invisibile per costruzione, ed
è rimasto tale finché non si è guardato l'output sui log di produzione.

Tre dettagli di ordine, tutti con una ragione:

- il **guard di configurazione precede** `require_tool_sources`, che è un guard di
  disponibilità dati: un profilo senza la variabile fallisce su ogni nodo e ogni giorno, un
  log mancante solo su quel nodo. Va detta prima la cosa che non cambierà.
- il clamp `depth < 1 → 1` dentro la funzione è di **sanità, non un default**: evita che
  un'invocazione diretta di gawk (i test unitari) produca nomi vuoti. L'obbligo di dichiarare
  vive in `dispatch.sh`, e il commento lo dice per non farlo leggere come default nascosto.
- `access_url_service()` è stata aggiunta all'**elenco delle funzioni** che
  `_require_awk_parser` richiede a un parser di formato (`dispatch.sh`), e l'asserzione che lo
  verifica è passata da «le 6 funzioni» a «le 7». Senza, un futuro
  `utils-access-combined.awk` soddisferebbe il contratto e romperebbe `service_times`
  (principio 8: migrare anche il contratto, non solo il codice).

`access_url_root()` **non** è stata rimossa pur non avendo più chiamanti di produzione: è
parte dell'interfaccia dichiarata per i parser di formato ed è testata.

## TRUNC-1 — Il troncamento di display va dichiarato — **FATTO** (2026-08-21)

`grep_named_log` tagliava i messaggi a 100 caratteri **senza dirlo**, quindi
`13432524.cc-1787133862806-375841` — un ID di correlazione mutilato — era indistinguibile da
uno completo, e chi lo copiava in una ricerca cercava una stringa che non esiste. La
convenzione del progetto esisteva già **sullo stesso schermo**: `slow_requests` stampa
«(mostrate le 30 più lente di 14473)», `tail_log` «Ultimi 5 di 295229 righe totali».

**La passata di principio 8 ha triplicato l'ambito, e questo è il valore della voce.** Il
difetto era stato notato in un file; cercando la stessa forma (`substr(x, 1, N)`) ne sono
emersi altri, fra cui uno **condiviso**:

| dove | cosa |
|---|---|
| `utils-dedup.awk` | il **printer condiviso**, quindi il difetto valeva per tutti i suoi utenti |
| `grep_named_log.awk` | messaggio a 100, thread a 60 |
| `filter_app_errors.awk` | la colonna ROOT CAUSE |
| `filter_errors.awk` | i frame di stack trace |

Correggere solo il primo avrebbe lasciato tre gap identici, più difficili da notare perché
«sembra già risolto». Da qui `ellipsize(s, n)` in `utils-colors.awk`, che è caricato da **ogni**
invocazione gawk.

**La distinzione che rende la voce non meccanica: chiave contro display.** Tre dei `substr`
trovati **non** vanno toccati — `norm_key()` in `filter_errors`, `key_msg` in `grep_named_log`,
la chiave di `register_error` — perché là il taglio *è il meccanismo* che fa collassare
messaggi che differiscono solo nella coda, e un `…` le allungherebbe senza cambiare cosa
raggruppano. Ognuno ha ora un commento che lo dice, così la prossima passata non li
"corregge". Nemmeno l'allineamento delle tabelle si rompe: `filter_app_errors` calcola la
larghezza di colonna da `length(_dup_msg[k])`, quindi si allarga da sé.

Quattro asserzioni in `test-srch-named-log.sh`, incluse due che discriminano: che una riga
**corta** non guadagni un `…` inesistente, e che il prefisso resti riconoscibile. La fixture
sta in un **log proprio** e non appesa a `prod1nssd-cc.log`: là ci sono asserzioni che contano
le righe ERROR, e aggiungerne una le faceva fallire per una ragione estranea a ciò che
verificano (provato, 2 → 3). Una fixture condivisa accoppia test indipendenti.

## THR-1 — La soglia di latenza espressa in secondi veniva ignorata — **FATTO** (2026-08-21)

**Trovata alla prima esecuzione dei 16 tool sui log di produzione**, dopo che l'utente ha
chiesto se avessi testato davvero in produzione. Fino a quel momento avevo verificato tre
query in `--dry-run` e una reale: la differenza fra quella verifica e questa è tutto ciò
che serviva a far emergere il difetto.

**Il numero che lo riassume.** Stessa domanda, due formulazioni, contro lo stesso access
log da 88 MB:

| query | soglia usata | risultati |
|---|---|---|
| `chiamate lente sopra 5 secondi di stamattina` | **1000 ms** | **14.473** |
| `chiamate lente sopra 5000 ms di stamattina` | 5000 ms | **1.214** |

**12× di differenza secondo come la domanda è formulata.** E il difetto non è silenzioso
per metà: la soglia sbagliata è *stampata* («soglia: 1000 ms»), ma nessuno la rilegge come
una contraddizione di ciò che ha chiesto.

### Tre difetti in cinque righe di codice

`lib/param-extract.sh:59-65` riconosceva **solo `ms`**, e se non lo trovava cadeva sul
default 1000 quando la query conteneva `lent`, su nulla altrimenti:

| formulazione | prima | dopo |
|---|---|---|
| `sopra 5000 ms` | 5000 ✓ | 5000 |
| `sopra 5 secondi` | **1000** | 5000 |
| `sopra i 5 secondi` | **1000** | 5000 |
| `sopra 5000ms` (attaccato) | **1000** | 5000 |
| `oltre 3 secondi` | **vuoto** | 3000 |
| `che hanno superato i 10 secondi` | **vuoto** | 10000 |
| `sopra 2 sec` | **vuoto** | 2000 |
| `sopra 500 millisecondi` | **1000** | 500 |

Le due cause minori sono altrettanto istruttive: `[0-9]+ ms` pretendeva lo **spazio**, e
`millisecondi` per esteso non era previsto.

### Il fatto era già nel file, dodici righe sopra

`param-extract.sh:47` — la `sed` che disambigua `STATUS_CODE` sottraendo i numeri con
ruolo di unità di misura — **elencava già** `ms|millisecond[oi]?|secondi?|sec\b`. Cioè lo
stesso file sapeva che «5 secondi» è una latenza *per non confonderla con uno status
code*, e non lo sapeva quando doveva **leggerla**. Lo stesso fatto scritto due volte, una
completa e una no: principio 8 nella sua forma più pura.

Il fix quindi non aggiunge un secondo elenco ma ne **estrae uno solo** (`_U_MS`, `_U_SEC`,
`_U_OTHER`) usato da entrambi i punti. `STATUS_CODE` verificato non regredito su 11 casi,
compresi i tre che dipendono dalla sottrazione (`ultime 500 righe`, `sopra i 450 minuti`,
`sopra 500 ms` → nessuno status).

### Perché è sopravvissuto fino a un test in produzione

Le asserzioni su `THRESHOLD_MS` in `run-tests.sh` erano **quattro, tutte in
millisecondi** — cioè nell'unica unità che funzionava. Il parametro *era* coperto; era
coperto solo dove non si rompeva. Aggiunte 9 asserzioni: **8 falliscono senza il fix**
(la nona, `sopra 1 secondo` → 1000, passa anche prima perché il default coincide col
valore giusto — corretta ma non discriminante, e vale dirlo).

Una riga esiste solo per proteggere l'ordine dei rami: `millisecondi` **contiene**
`secondi`, quindi se i secondi venissero provati prima, `500 millisecondi` darebbe
500.000.

### Il difetto era stato reso raggiungibile il giorno prima

VOCFIX-1 (2026-08-20) ha aggiunto `secondi\b` e `superat|oltre\b` al vocabolario perché
«quali richieste hanno superato i 10 secondi» finiva su `traffic_volume`. Corretto il
routing, quelle query arrivano a `slow_requests` — che non sa leggerne la soglia. **Il
modello è stato insegnato a sentire i secondi mentre il tool non sapeva usarli**: una
correzione a monte ha scoperto un difetto a valle che il misrouting mascherava. È il
motivo per cui un fix di routing va seguito da una prova end-to-end, non da un dry-run.

**Limite noto documentato nel codice**: solo valori interi. `sopra 1,5 secondi` cade sul
default, perché il separatore decimale italiano è la virgola e distinguerlo da un elenco
richiede un'analisi che nessuna query reale oggi giustifica. E `s` nudo come unità non è
supportato di proposito: qui un falso positivo non produce lentezza ma una **soglia
sbagliata**, cioè un difetto di correttezza — l'eccezione dichiarata al pruning
conservativo del principio 5.

### Sweep di produzione: cosa altro è stato verificato

15 tool su 16 eseguiti sui log reali del nodo 4 (`search_all_logs` escluso per durata).
Oltre a THR-1 sono emerse **SVCGRAN-1** e **TRUNC-1** (aperte, vedi tabella), e un
sospetto **scartato**: `filter_errors` dichiarava «nessun errore nel server log» con 113
HTTP 500 in corso, ed è **corretto** — le 43 righe ERROR/WARN del `server.log` sono tutte
alle 08:18, fuori dalla finestra 11:03→13:03 richiesta, e i 500 sono loggati come INFO,
che è precisamente la ragione per cui esiste `filter_app_errors` (il quale li trova).
Verificare il sospetto prima di correggerlo ha evitato un fix a un difetto inesistente.

## GAPREP-1 — Un canale diagnostico reso inutile dal proprio rumore — **FATTO** (2026-08-21)

**Il difetto non era l'assenza di un segnale, era il suo rapporto segnale/rumore.**
`vocab-gap.sh` girava dentro `train.sh` a **ogni** addestramento e nessuno lo leggeva. È
già costato un difetto reale: FLEX-1b ha scoperto che `richieste fallite` — *letteralmente
un esempio di training* — non attivava alcun tool perché non esisteva feature per
`fallit*`, e questo report lo segnalava (`fallimenti — 3 esempi`) da settimane.

Due cause, entrambe **di misura**, più una di presentazione.

### Causa 1 — stadio sbagliato della pipeline (il terzo caso in due giorni)

`vocab-gap.sh:75` faceva `query = tolower($2)` sul labeled **grezzo**, mentre le feature
si calcolano sul **normalizzato**. Il report dichiarava quindi "non coperti" proprio i
token che `nlp/unigrams.txt` **vieta per contratto** (LOGF-3, zero nomi concreti) e che
`normalize-query.sh` assorbe: `database`/`messaging`/`jgroups`/`integr` → `<LOGFILE>`,
`nodo` → `<NODE>`, `produzione` → `<ENV>`, `claimcenter` → `<APP>`. **Consigliava di
aggiungere al vocabolario esattamente ciò che non può starci.**

È lo stesso errore di VOCFIX-1 D3 (contare `api.log` sul file grezzo: numero 25× troppo
grande) e di un terzo caso emerso nella stessa giornata — misurare la copertura con `awk`,
dove `\b` è **backspace** e non confine di parola, che faceva sembrare scoperti
`access\b`, `tempi\b`, `secondi\b`, `sopra\b`. Da qui il commento in `vocab-gap.sh` che
vieta di spostare la Fase 2 in awk: **deve** restare `grep -E`.

### Causa 2 — nessuna nozione di potere discriminante

I commenti di `unigrams.txt` dicono "solo count_status (1 classe) → peso 2", "max 4 classi
→ peso 1", "stop word (9 classi)". Erano annotazioni **scritte a mano**: nessuno script le
calcolava. Ora il numero di classi è una colonna, ed è la **prima chiave di ordinamento**.

Il conteggio si fa su **tutte** le etichette, non solo la primaria: il dataset è
multi-label, e `class = labels[1]` sottostimava la diffusione proprio sui token ambigui,
cioè dove la metrica serve.

### Causa 3 — lo stesso token una volta per classe

113 righe in 16 blocchi alle impostazioni di default, con i token diffusi ripetuti. Ora è
una **lista unica** ordinata a due chiavi — poche classi prima, a parità più esempi — e
non un punteggio composito, che darebbe lo stesso ordine senza essere leggibile.

### La soluzione a tre filtri, e perché il terzo non è opzionale

1. **Normalizzazione** (`lib/dump_norm.py`, riusa `bd.load_profile`/`bd.normalize_query`):
   elimina le coordinate **per costruzione**, non per euristica. In Python perché il
   percorso bash costa **54s misurati** su 1171 query, dentro `train.sh`; 84 ms in
   Python, 640×. Basta il `python3` di sistema.
2. **Filtro placeholder**: `<logfile>` e `<ip>` **sono** pattern del vocabolario
   (`unigrams.txt:234`, `:148`), quindi `<` e `>` non sono separatori — spezzarli darebbe
   il token `logfile` con **155 occorrenze in cima alla lista**, che non combacia col
   pattern `<logfile>`. `<app>`/`<env>`/`<node>` invece non sono nel vocabolario per
   scelta architetturale (sono coordinate estratte a valle) e vanno scartati, o il report
   consiglierebbe «aggiungi `<node>` al vocabolario».
3. **`nlp/report-stopwords.txt`** — 99 parole funzionali italiane. Serve perché il
   conteggio classi **da solo non basta**: misurato, `della` compare in **1 sola classe,
   esattamente come `impattano`**. Un token raro è raro sia perché è grammatica usata di
   sfuggita, sia perché è un termine di dominio che manca — e nessun conteggio distingue i
   due casi. È un fatto linguistico, non statistico.

**Il rimedio ha quasi reintrodotto il difetto, e la misura l'ha intercettato.** Scrivendo
la lista stopword avevo incluso tre parole che si sono rivelate **candidati veri**:

| parola | misura | cosa era davvero |
|---|---|---|
| `dall` | 32 esempi, **31 in `filter_ip`** | la collocazione `dall'ip` / `dall'indirizzo` |
| `come` | 18 esempi, `filter_app_errors` | `loggati come info`, la definizione stessa del tool |
| `dove` | 9 esempi, **9 su 9 in `search_all_logs`** | `dove compare` |

Nasconderle avrebbe reso invisibili tre segnali reali — il difetto che questa voce
corregge, reintrodotto dal suo stesso rimedio. Da lì la **regola** scritta nel file: una
parola entra solo se è funzionale **e non ha valore di collocazione**, e la concentrazione
si misura. Rimosse anche `dalla`/`dalle`/`chi`/`stato`/`dammi`, che sono **già** feature
del vocabolario (`dall[ea]`, `\bchi\b`, `status|stato`, i verbi imperativi): inerti nel
filtro, ma contraddittorie a leggersi.

Al contrario `posso`/`puoi`/`fare` **restano** pur essendo concentrate su `show_help`,
perché il loro segnale è già catturato dai compositi (`posso.fare`, `cosa.puoi`,
`posso.usar`): la forma nuda non aggiunge nulla.

**Due errori miei, corretti dalla misura, che restano nel codice come commento:** avevo
ammesso le **cifre** fra i caratteri dei token, riempiendo la cima della lista di `1000`,
`2026`, `8101`, `0473954` — un numero in una query è un *valore* consumato da
`param-extract.sh`, non un candidato. E `--porcelain` rispettava `--top`, quindi
`gap-report.sh` contava le righe ricevute e annunciava «6 candidati» invece di 74: il
numero che l'utente legge a ogni training era sbagliato **per difetto**, il modo peggiore
di sbagliarlo.

### Due difetti preesistenti trovati per strada, in `gap-report.sh`

- **Un check verde per una misura mai avvenuta.** `... || true` **dentro** la command
  substitution (riga 123) inghiottiva qualunque codice di uscita; `grep -c "[GAP]"` dava
  0 e lo script stampava «✓ Vocabolario: nessun gap rilevante». Bastava un `unigrams.txt`
  cancellato. Ora i codici sono distinti — `0` misurato, `2` **non misurabile**, altro
  errore — e nessun ramo esce non-zero, perché `train.sh:166` invoca `gap-report.sh` sotto
  `set -euo pipefail` e un exit non-zero abortirebbe l'addestramento.
- **`exit 0` se manca il dataset numerico** (riga 56): saltava **tutto** il report, anche
  la sezione vocabolario, che si calcola da `queries_labeled.txt` e non ne ha bisogno. Un
  profilo appena creato non riceveva nemmeno la parte misurabile.

### La riga che l'utente vede a ogni training

```
! Vocabolario: 74 candidati non coperti  (top: attività, dove, code)
  → Esegui: ./gap-report.sh --profile profiles/liquido  per il dettaglio
```

È la modifica più importante del lotto, e la ragione è misurata: la riga compact
**esisteva già** ed era accurata, ma mostrava un **numero** — e `fallimenti — 3 esempi` è
passato inosservato per settimane. Tre parole concrete danno una ragione per guardare; un
conteggio no.

### Esito

| | prima | dopo |
|---|---|---|
| righe | **113** in 16 blocchi, token ripetuti | **74** candidati unici, 25 mostrati |
| stadio | labeled grezzo | testo normalizzato |
| ordine | alfabetico dentro ogni classe | poche classi prima, poi più esempi |
| coordinate | in cima (`database`, `messaging`, `nodo`…) | **assenti per costruzione** |
| copertura di test | **zero** | `tests/test-vocab-gap.sh`, **25 asserzioni** |

Verificato: 176 PASS / 0 FAIL su `liquido` **e** `usnext` con `--parity` (1171/1171, 119
feature); checksum dei pesi `7e6fc068…` **invariato** (nessun retrain: vocabolario,
dataset e modello non sono stati toccati); `train.sh` end-to-end; ramo senza `python3`
verificato con un `PATH` costruito senza di esso.

L'harness è stato validato con **due mutazioni deliberate** su `vocab-gap.sh` — conteggio
classi sulla sola etichetta primaria, e placeholder spezzati — ciascuna delle quali
produce **un solo** FAIL mirato, sull'asserzione giusta. `impattano` e `ripetuti`
discriminano i due meccanismi: il primo vive solo in una riga multi-label (quindi cade con
la logica vecchia), il secondo in due righe single-label (quindi regge).

**Nota sui profili**: il report **dipende dal profilo** anche con `nlp/` condiviso — 74
candidati su `liquido`, 76 su `usnext` — perché la normalizzazione usa `entities.conf`, e
sono le coordinate del cliente a decidere quali token vengono assorbiti.

## VOCFIX-1 — Quattro difetti trovati validando una tabella di esempi — **FATTO** (2026-08-20/21)

**Origine: nessun task, una richiesta di documentazione.** L'utente ha chiesto una tabella
«nomi dei tool + query di esempio per ciascuno, sui 2 profili in PROD». Gli esempi potevano
essere inventati; sono invece stati **validati contro il classificatore vero** — 48 query ×
2 profili = 96 dry-run, replicando la sequenza di `chatbot.sh` via `_front_end()` (il punto
di replica canonico creato da FASE-1). La validazione ha trovato quattro difetti che nessun
test copriva, e questo è il dato di metodo della voce: **scrivere documentazione verificabile
è un harness**, perché obbliga a percorrere la pipeline sugli input che l'utente digiterà.

Una misura collaterale utile: le confidenze coincidono **cifra per cifra** sui due profili
per ogni query priva di coordinate. È la prova empirica che NLP-1 (vocabolario, dataset e
pesi nel framework) è stato applicato per intero.

### D1 — Il ranking di `--dry-run` era ordinato al contrario

`lib/infer-dry.sh` ordinava con `sort -rn -k1`. `nc_predict` emette **notazione scientifica**
per i valori piccoli (`9.5657479403040116e-05`) e `-n` non la interpreta: legge `9.56` e lo
mette in cima. Il sintomo su «statistiche GC del nodo 4»:

```
 ·  ── soglia 25% ──         ← il separatore SOPRA il rank 1
1.    0.0%  count_status
2.    0.0%  filter_app_errors
3.   99.5%  gc_stats          ← il vincitore vero, al terzo posto
```

**Il routing di produzione non era affetto**: `infer.sh:52` confronta con `awk`, che la
notazione scientifica la capisce. Ma è un difetto di visualizzazione **nell'unico strumento
che serve a diagnosticare il misrouting** — cioè inganna esattamente quando lo si consulta.

Fix: `LC_ALL=C sort -grk1`. Due cause, non una:
- `-g` (general numeric) invece di `-n`, per la notazione scientifica;
- `LC_ALL=C` perché **sia `-n` sia `-g` usano il separatore decimale della locale**: sotto
  `LC_NUMERIC=it_IT` (separatore `,`) `0.995` viene letto come `0` e tutti i tool pareggiano
  a zero. Qui non si riproduce solo perché `it_IT` non è installata — **il server di
  produzione può averla**. È un difetto latente corretto senza averlo osservato, ed è
  l'eccezione giustificata alla regola «prima misura, poi correggi»: la condizione è
  l'ambiente, non il codice.

Principio 8 applicato: cercato `sort -n` su valori potenzialmente decimali altrove.
`normalize-query.sh:75` ordina lunghezze intere (`${#k}`) — immune a entrambe le cause, non
toccato.

### D2 — `TOOL_DESC[service_times]` dichiarava la sorgente sbagliata, in entrambi i profili

Diceva «Tempi di esecuzione servizi SOA **dal server.log**», ma `service_times.awk:2` dice
«Sorgente: access log Undertow», usa `access_ts()`/`access_time_ms()`, e
`TOOL_SOURCES[service_times]="access"`. Il commento in `nlp/tools.conf` **cita questa esatta
divergenza** come la ragione per cui `TOOL_SOURCES` è stata creata (HELP-1) — ma la prosa che
l'utente legge nell'help non è stata migrata insieme. È il **principio 8 applicato all'help**:
centralizzata la partizione tool→sorgente, lasciata indietro la descrizione. Corretto nei due
`domain.conf` e in `README.md`, dove sono stati aggiunti anche i tre tool mancanti dalla
tabella (`show_help`, `search_all_logs`, `list_logs`).

### D3 — Tre misrouting, e la causa radice era una fuga di sottostringa nel vocabolario

I tre gap misurati (identici sui due profili, quindi nel vocabolario condiviso):

| query | attesa | prima | dopo |
|---|---|---|---|
| `quante chiamate 503 stamattina su claimcenter` | `count_status` | `traffic_volume` 77% | **97.2%** |
| `quali richieste hanno superato i 10 secondi ieri` | `slow_requests` | `traffic_volume` 67% | **98.9%** |
| `quali comandi posso usare` | `show_help` | nessun tool sopra soglia | **98.1%** |

La diagnosi iniziale — «copertura mancante» — era **sbagliata su una misura sbagliata**:
avevo contato le occorrenze sul file *grezzo*, ma le feature si calcolano sul testo
**normalizzato**, dove `api.log` e `performance_integr.log` diventano `<LOGFILE>`. Il numero
era 25 volte troppo grande, e correggerlo ha cambiato l'intervento. Rimisurato sullo stadio
giusto, il difetto vero è **una fuga di sottostringa**: `[[ =~ ]]` è un match non ancorato.

| pattern | catturava anche | misura sul corpus normalizzato |
|---|---|---|
| `ora \|ore \|ora$` :: **2** | l'interno di **errore**, `oraria`, `peggiorano`, `lavorare` | 21 query prendevano una feature di finestra temporale con peso 2 |
| `per` :: 1 | `performance` (21), `recupera` (14) | 37 spurie su 1152, contro 77 legittime |
| `500` / `404` :: 1 | `5000` (una soglia in ms), `clv00404` | 2 esempi `slow_requests` attivavano `500`, 1 `count_status` attivava `404` |

**La causa che rendeva il difetto invisibile**: `ora |ore |ora$` è scritto **correttamente** —
lo spazio finale *è* il confine di parola che l'autore intendeva. Ma
`query-to-features.sh:47` fa `pattern="${pattern// /}"` e `build_dataset.py:204` fa
`.replace(' ','')`: **è la pipeline che degrada il pattern**, in entrambi i backend
(la parità regge, il difetto è simmetrico). Rileggere il vocabolario non lo mostra mai.
Corretto in `\bor[ae]\b|\borari`, e — principio 8 — anche nei **due bigram** (righe 9 e 15 di
`bigrams.txt`) che avevano la stessa forma: lì la co-presenza «exception … errore» si
attivava senza che la query nominasse alcuna finestra temporale.

Il caso più insidioso è `500` su `5000`: **la rete aveva imparato che un codice di stato può
significare "richiesta lenta"**, che è precisamente la confusione status-code ↔ latenza dei
primi due gap. La causa radice e il sintomo erano la stessa cosa.

**Una collisione che ha cambiato il pattern da scrivere.** Per il gap B serviva l'unità di
misura della soglia. Un `second` nudo avrebbe codificato la confusione invece di risolverla,
perché il corpus contiene **i due sensi opposti della stessa radice**: «quante chiamate al
second**o**» è una *frequenza* (`traffic_volume`), «sopra i 3 second**i**» è una *soglia*
(`slow_requests`). Il discriminante è il **numero grammaticale**, quindi il pattern giusto è
`secondi\b` — il plurale esclude da solo il senso di frequenza, senza pattern composito.
Verificato dopo il retrain: `quante richieste al secondo oggi` → `traffic_volume` 76%,
`richieste sopra i 3 secondi` → `slow_requests` 99.1%.

Per il gap A il discriminante non è **nessuna delle due parole da sola**: `chiamate` vive
nella sezione traffico ed è genuinamente ambigua («chiamate lente», «chiamate 500», «quante
chiamate al minuto» sono tre tool). È la **co-presenza** di un quantificatore e di un codice
di stato — quello è un conteggio per codice, non un volume per finestra. Da qui il bigram
`quant[eo]|quanti|conta|contami|numero :: \b(400|404|500|503|4xx|5xx)\b|status|stato :: 2`.
Su `quante chiamate 503 al minuto`, dove l'ambiguità è reale, il bot attiva **entrambi**
(`count_status` 69.4% + `traffic_volume` 45.2%): il multi-label è la risposta corretta a una
domanda ambigua, non un misrouting.

Il gap C era vettore **identicamente nullo**: ogni pattern della sezione help richiedeva una
seconda parola specifica, e `comandi` da solo non attivava nulla. Aggiunto `comand :: 2`.
Il `vocab-linter` che segnala i vettori tutto-zero — **la classe di difetto esatta del gap C** —
ne riportava già uno pre-esistente: chiuso nella stessa passata, perché un esempio a vettore
nullo è un esempio da cui la rete non può imparare.

**Retrain**: 4 feature nuove (`secondi\b`, `superat|oltre\b`, `comand`, + il bigram),
**115 → 119**; 19 esempi labeled nuovi, 1152 → 1171. Reinizializzazione + training (early
stopping, epoca 815). Modello condiviso: un solo ciclo copre entrambi i profili.

### D4 — `resolve-logs.sh` stampava il comando invece del messaggio (2026-08-21)

Tutte e **5** le uscite d'errore erano `echo "echo '[ERROR] …' >&2" >&2`: l'utente leggeva
la stringa letterale `echo '[ERROR] resolve-logs: …' >&2`.

La forma eval-able **non è sbagliata in sé** — `normalize-query.sh` la usa correttamente. La
differenza sta nel **contratto del chiamante**, e non è stilistica:

| script | invocazione | stdout dopo `exit 1` |
|---|---|---|
| `normalize-query.sh` | `source <(script)` | **eseguito sempre** → la forma eval-able è l'unico modo per far arrivare il messaggio |
| `resolve-logs.sh` | `res=$(script) \|\| { … }` (`chatbot.sh:242`) | **scartato** → `eval` non è mai raggiunto, la forma eval-able è codice morto |

Verificato dal vivo su entrambi i percorsi. Corretto in `echo "[ERROR] …" >&2`, con un
commento in testa al file che spiega perché i due file **devono** divergere — altrimenti la
prossima passata di uniformazione riapre il bug per simmetria.

### La fixture che congelava un valore derivato

Dopo il retrain l'unico FAIL della suite era `tests/test-train-regression.sh`, che aveva
`NUM_FEATURES=115` letterale. Il commento accanto spiegava che `TOPOLOGY` era *derivata* da
`NUM_FEATURES` «invece di riscritta a mano (principio 2)»: **la centralizzazione si era
fermata un livello troppo in basso** — aveva eliminato la duplicazione fra `TOPOLOGY` e
`--inputs`, non quella fra il test e `nlp/tools.conf`.

Il sintomo era anche diagnosticamente fuorviante: `[FAIL] checksum atteso ≠ ottenuto` accusa
la riproducibilità di `neural-c`, cioè l'unica cosa che il test deve misurare, quando la causa
è un dataset più vecchio del vocabolario. Corretto sourciando `nlp/tools.conf` (che calcola
già `NUM_FEATURES = |UNIGRAMS| + |BIGRAMS|` e `MODEL_TOPOLOGY`), più una **guard esplicita**
sulle colonne del dataset che fallisce *prima* delle 200 epoche e nomina il rimedio
(`./build-dataset.sh`) — la stessa forma di verifica che `train.sh` fa in ARCH-4. Validata con
una mutazione deliberata sul dataset, ripristinato bit-identico.

Volutamente **non** si passa per `nlp_resolve_paths()`: quella risolve profilo → framework, e
un profilo con vocabolario proprio renderebbe il checksum pinnato valido solo per quel profilo.

### Verifica finale

- **175 PASS / 0 FAIL** su `liquido` **e** su `usnext`, `--parity` inclusa
- `--parity` **1171/1171** su entrambi, **119 feature**
- `test-train-regression.sh`: checksum `7e6fc068…`, **3 run bit-identici**
- Le 48 query della tabella: **96/96** su due profili, incluse le 3 che fallivano
- Spot-check sui confini a rischio (frequenza vs soglia, query con «errore» dopo la rimozione
  della feature spuria con peso 2): nessuna regressione, `errori delle ultime 2 ore` →
  `filter_errors` 66% con il secondo a 19%
- `vocab-linter`: 0 vettori tutto-zero (era 1)

## FASE-1 — La prima fase della pipeline: tre harness e 9 difetti — **FATTO** (2026-08-20)

Indicazione dell'utente all'inizio della sessione: *«mi sembra che abbiamo molti problemi
nella fase iniziale del bot — parsing della riga ed estrazione parametri»*, con la proposta
di concentrarsi lì costruendo una suite di test più precisa.

**La misura ha confermato la conclusione e corretto la diagnosi.** Sui 31 commit `fix(` dal
1° agosto, i file di produzione più toccati sono `dispatch.sh` (13) e i tool AWK (~32),
contro `normalize-query.sh` (4) e `param-extract.sh` (3). Per conteggio grezzo i bug stanno
nei tool. Ma il conteggio è la metrica sbagliata: i tool sono stati corretti tanto perché
sono **osservabili** (un numero sbagliato in tabella si vede) e perché hanno fixture vere.
La prima fase ha meno fix non perché abbia meno difetti, ma perché i suoi difetti sono
**silenziosi** — e la struttura dei test lo dimostrava in tre punti:

1. **Level 1 asseriva solo il nome del tool.** 89 query di intent, zero asserzioni sui
   parametri estratti. Una query classificata giusta con finestra temporale sbagliata
   **passava la suite** — la classe esatta del bug `"oggi"` (commit `8838683`).
2. **11 dei 19 parametri emessi da `param-extract.sh` non avevano una sola asserzione**:
   `STATUS_CODE`, `THRESHOLD_MS`, `IP_FILTER`, `LOG_LEVEL`, `LEVEL_EXPLICIT`,
   `NAMED_LOG_GLOB`, `DATE_FILTER`, `TIME_ONLY_QUERY`. E `utils-time.sh` + `utils-time.awk`
   — 427 righe, la superficie più ambigua del progetto — avevano **5 asserzioni indirette**
   e nessun file di test dedicato.
3. **Il REPL ha stato, i test no.** `run-tests.sh:245` lo dichiarava esplicitamente
   («chatbot.sh le eredita di proposito, i test no»). Due bug reali erano venuti da lì
   (`e43d1c6` TIME_EXPLICIT persistente, `01c5f6f` DETECTED_* azzerate dall'eval) e
   **nessuno dei due era catturabile dalla suite per costruzione**.

### I tre harness

| file | asserzioni | esito |
|---|---|---|
| `tests/test-utils-time.sh` (nuovo) | 82 | 17 branch della cascata, la loro **precedenza reciproca**, `TIME_ONLY_QUERY`, `DATE_FILTER`, input degeneri, lato AWK (`parse_iso`/`in_range`) |
| `run-tests.sh` — Level 1b (nuovo) | 85 | gli 11 parametri scoperti, asseriti **insieme al tool sulla stessa invocazione** (lezione di LOGDISC-4e: un test per-feature non coglie l'interazione fra feature) |
| `tests/test-repl-state.sh` (nuovo) | 34 | query consecutive nello **stesso processo** via stdin del REPL |

**`_front_end()` in `run-tests.sh`**: punto unico che replica la sequenza di `chatbot.sh`
(normalizza → esporta `NORM_QUERY` → esporta `DETECTED_*` → inferisce → estrae parametri),
usato sia da Level 1 sia da Level 1b. Due repliche indipendenti divergerebbero, ed è
precisamente il difetto che ha reso invisibile il train/serve skew di NLOG-4 (principio 2).
Scrivendolo si è ricalpestata la trappola di HELP-1 (`3859d62`): `[[ ]] && cmd` come ultimo
comando di una subshell restituisce 1 e fa abortire il chiamante sotto `set -e`.

### Risultato negativo importante: lo stato del REPL era già corretto

`test-repl-state.sh` passa **34/34 senza alcun fix**. L'ipotesi di un leak di `DATE_FILTER`
non è confermata; `STATUS_CODE`/`THRESHOLD_MS`/`LOG_LEVEL` non fanno leak perché
`param-extract.sh` ri-emette tutte le 19 variabili a ogni query, anche vuote, e l'`eval` le
sovrascrive; `TIME_EXPLICIT` si ricalcola davvero. **La classe che si temeva di più era già
sana** — ora è blindata invece di essere non verificabile.

**L'harness ha però trovato un difetto in se stesso, e vale più di un difetto nel codice.**
Le asserzioni sulla persistenza della finestra guardavano il **banner**, che stampa
`ACTIVE_TIME_FROM/TO`; i tool ricevono `TIME_FROM/TO`. Sono variabili diverse. Con una
mutazione deliberata che svuotava l'eredità, il banner restava corretto e **tutte le
asserzioni passavano**: si stava asserendo l'etichetta invece dell'effetto, che è LOGSEL-1 D2
in forma di test. Aggiunta l'asserzione sull'effetto (una richiesta 500 fuori fascia che non
deve essere contata), entrambe le mutazioni vengono catturate.

### I 9 difetti trovati e corretti

| ID | forma | comportamento prima | causa |
|---|---|---|---|
| **T1** | `ieri pomeriggio`, `ieri alle 10`, `ieri dalle 10 alle 14` | finestra di **OGGI**, `DATE_FILTER` vuoto | i branch `EXPLICIT_RANGE`/`SINGLE_HOUR`/fasce cablavano `now_date` e **precedevano** il branch `ieri` |
| **T2** | `ieri mattina`, `ieri sera`, `2 giorni fa di mattina` | giornata **intera** (fascia scartata) | `mattina`/`sera` nudi non erano nelle regex delle fasce → cadeva sul branch del giorno |
| **T3** | `ultimo giorno` | **nessun filtro** | `ultim[aei]` esclude il maschile singolare; il commento la dichiarava supportata |
| **T4** | `tra le 10 e le 12` | **nessun filtro** | forma documentata nel commento dal primo giorno, mai implementata nella regex |
| **T5** | `alle 99` | finestra a **2026-08-24 02:30** | nessuna validazione di ora/minuti; `mktime()` normalizza i valori fuori scala |
| **D1** | `dalle 22 alle 2` | intervallo **invertito** → `in_range` sempre 0 → «nessun risultato» | entrambi gli estremi ancorati allo stesso giorno |
| **P1** | `ultime 500 righe`, `sopra i 500 ms`, `ultimi 450 minuti` | `STATUS_CODE=500/450` | `\b[45][0-9]{2}\b` non distingue i ruoli del numero (latente: nei casi misurati nessun tool attivo lo legge) |
| **P2** | `log applicativi` (plurale) | `SYSLOG_KIND`/`LOG_TYPE` vuoti → fallback access log | `applicativ[oa]?` non copre `applicativi`/`applicative` |
| **D2** | riga senza timestamp riconoscibile, filtro attivo | **esclusa** → «nessun risultato» su dati non databili | `in_range(0)`: `0 >= ts_from` è falso per ogni finestra reale |

**T1 e T2 erano lo stesso errore di modellazione, non due bug.** Il giorno e l'ora del giorno
sono dimensioni **indipendenti**; il codice le trattava come rami alternativi della stessa
cascata, quindi mutuamente esclusive — una frase che nominava entrambe *doveva* perderne una,
e quale si perdesse dipendeva soltanto da quale regex capitava di matchare prima.
`_RE_AFTERNOON` conteneva `\bpomeriggio\b` nudo → `ieri pomeriggio` prendeva il ramo della
fascia con `now_date` (**giorno sbagliato**); `_RE_MORNING` richiedeva `di mattina` →
`ieri mattina` cadeva su `ieri` (**fascia persa**). Nessuno ha progettato quell'asimmetria.
La correzione **separa le due fasi** (`utils-time.sh`: Fase 1 ancora di giorno, Fase 2
finestra oraria ancorata), così i quattro sintomi diventano un caso solo e la struttura non
può produrne un quinto.

**T3 e P2 sono lo stesso difetto in due file**: una classe di caratteri che copre alcune
flessioni della parola italiana e non altre. Nessuno dei due dava errore — producevano un
parametro vuoto, cioè un filtro che **si disattiva** invece di fallire. Vale la pena cercare
la stessa forma nelle altre regex flesse del progetto.

**D1 — la regola, indicata dall'utente**: `from` è l'occorrenza **più recente già passata**
di quell'ora del giorno; se `to ≤ from` il range attraversa la mezzanotte e `to` va al giorno
successivo; se il giorno **non** è nominato e `from` cade nel futuro, si arretra di un giorno.
Alle 21:00 `dalle 22 alle 2` → ieri 22:00 → oggi 02:00; alle 23:00 → oggi 22:00 → domani
02:00. **L'arretramento vale solo per un range che attraversa la mezzanotte**: su un range
normale sarebbe una sorpresa (`dalle 10:30 alle 14:45` chiesto alle 09:00 risponderebbe su
ieri) e butterebbe via dati che esistono (principio 5). Verificato su `_range_window()` con un
`now` **sintetico**, non end-to-end: un'asserzione sull'ora reale fallirebbe se la suite
girasse dopo le 22:00 — la stessa fragilità delle date cablate.

**D2 — la scelta e la sua contropartita.** `in_range(epoch <= 0)` ora restituisce 1: un epoch
≤ 0 significa «istante IGNOTO», e non sapere quando è avvenuta una riga non è una ragione per
affermare che sia fuori dal periodo (principio 5). L'esposizione è stata **enumerata prima di
decidere**, non stimata: dei 17 call site di `in_range()`, 9 sono in regole AWK che hanno già
matchato la grammatica del timestamp (epoch 0 irraggiungibile), `grep_named_log:48` gestisce
`row_epoch <= 0` da sé (immune), **`search_all_logs` non chiama `in_range` affatto** — quindi
il fix `722b054` sulle stack trace non si riapre. Restano i 7 call site di `access_ts()`.
La contropartita è `access_ts_format_warning()`, che dice quando il filtro **non** ha potuto
filtrare: senza, si scambierebbe un falso negativo con un falso positivo. Scoperto
implementandola che **`access_ts_ok()` (creata da FORMAT-1) non aveva un solo chiamante** —
il meccanismo per dire «formato non riconosciuto» esisteva e non era collegato (principio 8).
Aggiunta anche `access_ts_period_ok()`: senza, il tool stampava «il filtro non è stato
applicato» e subito dopo «Nessuna richiesta trovata **nel periodo selezionato**» — due frasi
che si contraddicono, e una contraddizione è peggio del falso negativo che il lavoro elimina.

### C1 e C2 — i due misrouting, con retrain

| ID | query | prima | causa |
|---|---|---|---|
| **C1** | `quanti 5xx stamattina` | `traffic_volume` (37%) | firma «quanti + classe 4xx/5xx + espressione temporale» assente dal dataset: 1 solo esempio `count_status` con `5xx` contro 6 di `distribute_status` |
| **C2** | `richieste da 192.168.1.100` | `tail_log` | i soli segnali di `filter_ip` erano le **parole** `\bip\b` e `client\|indirizz`: una query che porta l'indirizzo e non la parola non attivava nulla |

**C2 non era un gap di copertura ma di generalizzazione**, e la diagnosi lo ha mostrato: i 6
esempi `filter_ip` del dataset contenevano **IP letterali** (`172.30.169.1`, `10.156.7.250`,
…), quindi il modello era esposto a ottetti specifici. È lo stesso difetto che `<LOGFILE>` ha
risolto per i nomi di log e `<PATTERN>` per le stringhe quotate, quindi la stessa soluzione:
**nuovo placeholder `<IP>`** in `normalize-query.sh` (sezione 0, riconoscimento per forma) e
unigramma `<ip>`. Non interferisce con `IP_FILTER`, che `param-extract.sh` estrae dalla query
**grezza** (`chatbot.sh:363`).

**Retrain**: `NUM_FEATURES` 113 → 114, `MODEL_TOPOLOGY` → `114,48,16`, reinizializzazione via
`setup.sh` (seed 42), dataset 1262 → 1296 righe labeled (1146 esempi), early stopping
all'epoca 969 su 5000, pesi dall'epoca 869. `test-train-regression.sh` aggiornato: checksum
rigenerato (`4ffd7991…`) e **riproducibilità verificata su 3 run bit-identici**, come
prescrive il suo stesso commento; `TOPOLOGY` e `--inputs` derivano ora da `NUM_FEATURES`
invece di essere lo stesso numero scritto tre volte (principio 2).

**La prova che `<IP>` generalizza**, non memorizza: `8.8.4.4` e `203.0.113.77` — indirizzi
mai visti in training — instradano a `filter_ip` al 98%.

### `DATE_FILTER` è vestigiale (scoperta collaterale)

`utils-time.sh` documentava `DATE_FILTER` come «usato da `resolve-logs.sh` per selezionare il
file di log ruotato corretto». **Falso**: `chatbot.sh:242` glielo passa, `resolve-logs.sh` non
lo legge in nessun punto (grep a zero). Le rotazioni le seleziona il walk temporale su
`TIME_FROM/TO` (LOGDISC-4). L'unico effetto vivo è `chatbot.sh:398`, dove un suo cambio forza
`ctx_changed=1`. Commento corretto — chi lo leggesse come un selettore di file cercherebbe un
bug di selezione rotazioni nel posto sbagliato. Conseguenza da tenere presente: T1 **non** era
un errore composto «finestra sbagliata + file sbagliato», come una prima analisi aveva
scritto; la finestra era sbagliata e il file la seguiva coerentemente.

### Verifica finale

`bash tests/run-tests.sh` → **174 PASS / 0 FAIL** su **liquido** e su **usnext** (pesi
condivisi, entrambi i profili). Suite passata da 96 asserzioni verdi a 174.
`--parity` su entrambi i profili. Fail-before/pass-after: 11 FAIL in `test-utils-time.sh` e
6 in Level 1b prima dei fix, 0 dopo; `test-repl-state.sh` verificato con **due mutazioni
deliberate** su `chatbot.sh` (TIME_EXPLICIT reso persistente, eredità della finestra
svuotata), entrambe catturate, produzione ripristinata bit-identica.

**Quattro asserzioni erano sbagliate le mie e sono state corrette invece di toccare la
produzione** (la lezione di metodo di FORMAT-1: *un test che fallisce non implica un bug nel
codice*): `__MISSING__` su un pattern non quotato è voluto per design; `SYSLOG_KIND` vuoto su
«statistiche GC» è corretto, perché il tool conosce la propria sorgente da `TOOL_SOURCES` e
il campo si popola solo quando l'utente **nomina** un log di sistema; due query erano
genuinamente ambigue fra `tail_named_log` e `grep_named_log`. Più tre errori di aritmetica
della fixture in `test-repl-state.sh`, che al primo giro sembravano difetti del codice.

---

### NLP-1 + PROF-2 — **FATTO** (2026-08-17)

**Struttura realizzata**: `nlp/` con `unigrams.txt`, `bigrams.txt`, `tools.conf` (nuovo,
estratto da `domain.conf`), `dataset/` e `models/intent_classifier/`. I profili scendono a
**4 file di coordinate**: `system.conf`, `entities.conf`, `domain.conf` ridotto (146→125
righe), `examples.sh`. I tre symlink di `usnext` sono spariti.

**`lib/nlp-paths.sh` → `nlp_resolve_paths()`**: punto unico, precedenza profilo→framework
per singolo artefatto. Tre scelte di design con la loro ragione:
1. **non può stare in `domain.conf`** (che si auto-localizzava con `_DOMAIN_DIR`): i test
   creano profili in `mktemp -d`, fuori dal repo. Effetto collaterale positivo: la fixture
   di `test-profile-config.sh` si è *semplificata*, non complicata
2. **`export` su tutto**: `query-to-features.sh`, `infer.sh`, `infer-dry.sh` sono
   subprocessi, e un figlio eredita solo ciò che è esportato
3. **`MODEL_DIR` derivato da `NLP_CUSTOM`**: un profilo che sovrascrive
   vocabolario/topologia/dataset ottiene pesi propri per conseguenza, non per
   configurazione — un flag separato permetterebbe di configurare l'incoerenza

**Corretto un ordine sbagliato preesistente** in `infer.sh`/`infer-dry.sh`: sourciavano
`domain.conf` prima di calcolare `ANALYZER_DIR`. Funzionava per caso.

**Rimossi**: `dataset/` e `models/` alla radice del repo (topologia `72,48,12`, zero
consumatori, commit separato per non confonderli con quelli da spostare) e il backup non
tracciato.

**DIFETTO PREESISTENTE TROVATO durante la verifica**: `test-train-regression.sh` aveva
checksum **obsoleti dal 2026-08-07** — LOGSEL-1b aveva aggiunto 16 esempi al dataset e i
valori non erano stati rigenerati, perché **il test non era nella suite di default e
nessuno lo eseguiva**. Verificato che il dataset è bit-identico da inizio giornata (md5
`5ceb52ae…`) e che `neural-bash`/`train.py` sono fermi al 3 agosto: il disallineamento era
preesistente, non causato dallo spostamento. Checksum rigenerati (riproducibilità
confermata su 3 run bit-identici) e **test aggiunto alla suite**: un checksum verificato
solo a mano è documentazione di uno stato passato, non una rete di sicurezza. È la stessa
classe dei "falsi verdi" di `test-utils-logfiles.sh` — un test che non gira è
indistinguibile da un test che passa.

**Verifica**: md5 dei pesi identici prima/dopo il `git mv`; dataset rigenerato
**bit-identico**; parità 1086/1086 su **entrambi** i profili (per `usnext` è la prova che
il fallback funziona senza symlink); **90 PASS / 0 FAIL**; `grep` sui path vecchi a zero;
`deploy --dry-run` con `nlp/dataset/` escluso e `nlp/models/` incluso; in produzione
`filter_errors` al 97% su entrambi i profili e `Pass.log` al 100% su `usnext`.

**PROF-2**: `CLAUDE.md` riscritta con la distinzione capacità/coordinate; `README.md`
corretto — citava `vocab.sh`, rimosso dal progetto il 2026-07-29.

---

### La struttura decisa prima dell'implementazione (2026-08-17, con l'utente)

**Criterio: il profilo contiene COORDINATE, non CAPACITÀ.** Dove sono i log, come si
chiamano le cose, quale tecnologia — non il vocabolario, non il dataset, non il modello.

**Nel framework** (es. `nlp/`), condivisi da tutti i profili con possibilità di override:

| Cosa | Perché non è del profilo |
|---|---|
| `unigrams.txt`, `bigrams.txt` | 196 righe, **zero nomi concreti**: descrivono come parla un utente in italiano, con i placeholder `<APP>`/`<LOGFILE>` |
| `dataset/queries_labeled.txt` | query in italiano con placeholder, non specifiche del cliente |
| `models/intent_classifier/` | **conseguenza deterministica** di vocabolario + dataset + iperparametri: se gli input sono condivisi, il modello lo è per costruzione. Prova: i pesi di liquido e usnext hanno md5 identico (`8c442f2c…`) |
| `NUM_TOOLS`, `TOOL_THRESHOLD`, `MODEL_TOPOLOGY`, `TOOL_NAMES` | identici nei due profili — e `TOOL_NAMES` **deve** corrispondere all'ordine degli output nei pesi condivisi: duplicarlo per profilo significa che una divergenza produce misrouting silenzioso |

**Nel profilo** — `system.conf`, `entities.conf` e un `domain.conf` ridotto alle sole
stringhe che l'utente legge: `TOOL_DESC`, `TOOL_EXAMPLE`, `HELP_CATEGORIES`,
`SOURCE_CATEGORY`/`SOURCE_LABEL`/`ACTIVITY_CATEGORY` (etichette; la partizione
tool→sorgente è `TOOL_SOURCES` nel framework, `nlp/tools.conf`, dopo HELP-1). Nominano i
log reali (`cc.log` vs `Pass.log`) e i nodi che esistono
davvero, quindi sono coordinate: l'help deve restare **concreto e copiabile**
(«ultime 100 righe del console.log sul nodo 2»), non generico.

**Override**: un profilo che mettesse il proprio `unigrams.txt` (cliente non italiano,
gergo aziendale) lo sovrascrive — stesso schema di `system.local.conf`. Nessuno dei due
profili attuali ne ha bisogno: i tre symlink spariscono.

**Da ripulire nello stesso intervento**: `profiles/liquido/models/intent_classifier.backup/`
(174 KB, non tracciata — `.gitignore` riga 3 — residuo di un training passato) e la
duplicazione `best/`, che è il checkpoint di early stopping di `train.py` e oggi coincide
coi pesi promossi.

**Verifica**: md5 del modello identico prima/dopo lo spostamento, `./train.sh` che gira
end-to-end, suite completa, e il chatbot che risponde su **entrambi** i profili in
produzione. Se un path sfugge il sintomo è netto (bot che non parte) tranne in un caso
da presidiare: `build-dataset.sh` che scrive nel posto sbagliato e `train.sh` che
addestra su un dataset vuoto o vecchio.

---

**Chiuso il 2026-08-17**: LOGDISC-2 (ricorsione in `search_all_logs` + colonna APP),
LOGDISC-4 (log di sistema scoperti sotto il nodo, validazione per-tool, bug `require_app`),
FORMAT-1 (timestamp riconosciuto per forma, non per posizione), DEPLOY-1 + DEPLOY-2
(sentinel di identità, `--delete`, migrazione al server dedicato ppc64le con 6 ambienti,
`neural-c` sincronizzato), CLEAN-1 (rimossa `list_env_app_dirs`, ultimo consumatore di
`APP_SUBPATH`), PROF-1 (profilo usnext operativo: 6 ambienti, 3 app, 12 nodi, con guard di
completezza), TS-1 (quinto formato timestamp, la data europea di Pass.log), ENTCONF-1 +
TECH-1 (un profilo mal configurato fallisce con un messaggio parlante), ACCESS-1 (estrazioni
access centralizzate in 7 funzioni + `ACCESS_LOG_FORMAT` come plugin). Vedi le sezioni dedicate.

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
| SRCH-2 | **Stesso gap di SRCH-1, ma per i log di sistema** (`server.log`/`access.log`/`gc.log`). Risolto estendendo `grep_named_log` (via 1 della nota di design, non `search_all_logs`): `TOOL_SOURCES[grep_named_log]` è passato da `"named"` a `"named|server|access|gc"` (`nlp/tools.conf`), con un ramo dedicato nel dispatch che risolve il path via `resolve_system_log_dir()`/`resolve_log_glob()` invece di `resolve_named_log_path()`. Il canale del pattern testuale, verso il tool AWK, era già quello di SRCH-1 — riusato senza duplicazione. Vedi nota di chiusura sotto per dettagli implementativi, decisioni e bug collaterali corretti | **Fatto** (2026-08-19) |
| QUOTE-1 | **Le virgolette come segnale riconosciuto: `<PATTERN>` nel vocabolario**, simmetrico al `<LOGFILE>` già esistente. Nato come prerequisito di SRCH-2 (serviva per distinguere `cerca "NPE" nel server.log` da `cerca errori nel server.log`) ma è una **feature a sé**, riusabile da qualunque tool che accetti un pattern testuale: qualsiasi stringa quotata che non sia glob-like (niente `*` + `.log`) diventa `<PATTERN>` in `normalize-query.sh` (e nella sua replica Python `build_dataset.py`, parità obbligatoria). Vedi nota di chiusura sotto | **Fatto** (2026-08-19) |
| SRCH-3 | **Bug prod, primo test manuale di SRCH-2**: pattern con spazi (`cerca "No HeadersTranscoder provided." nel server.log`) faceva crashare `grep_named_log.awk` (`gawk: cannot open file 'HeadersTranscoder' for reading`). Causa: i tre siti `eval gawk "$tw_args" ... -v pattern="$_gnl_pattern" ...` nel case `grep_named_log` (glob, sistema, named) fanno un secondo giro di parsing della shell — le virgolette che proteggono `$_gnl_pattern` nel primo giro non sopravvivono al secondo, quindi un pattern multi-parola veniva risplittato in argomenti separati che gawk, non riconoscendoli come `nome=valore`, tratta come file da apire. **Difetto preesistente di SRCH-1** (stesso costrutto da 2026-08-06), invisibile finché nessun pattern testato conteneva uno spazio — SRCH-2 l'ha solo esposto per primo, con un vero utente in produzione. Vedi nota di chiusura sotto | **Fatto** (2026-08-19) |

| SRCH-4 | **Nome di log di sistema quotato senza `*`: resta LETTERALE invece di essere assorbito in `<PATTERN>`.** Nuova sezione (a-ter) in `normalize-query.sh`, fra la (a) glob-quotato e la (a-bis) `<PATTERN>`. Vedi nota di chiusura sotto | **Fatto** (2026-08-20) |

### SRCH-4 — nota di chiusura (2026-08-20)

**Scelta: letterale, non `<LOGFILE>`.** La sezione (b) esclude deliberatamente i log di
sistema dalla generalizzazione a `<LOGFILE>` — hanno tool dedicati — quindi emettere
`<LOGFILE>` qui contraddirebbe quella decisione a due passi di distanza. Lasciando il nome
letterale la query diventa **identica alla forma senza virgolette**, che già instradava
correttamente: nessuna nuova feature, nessun nuovo confine da insegnare alla rete, **nessun
retrain necessario per questo fix**. Si riusa ciò che funziona già.

**Riconoscimento tramite `system_log_kind_of()`** (`utils-logfiles.sh`), unica fonte di verità
sui sinonimi dei log di sistema: nessun secondo rilevatore parallelo che possa divergere
(principio 8). Sostituzione via parameter expansion e non `sed`, perché il contenuto fra
virgolette è testo arbitrario dell'utente e non va reinterpretato come regex.

**Replica Python obbligatoria** (`build_dataset.py`), con tre dettagli su cui la parità
bit-a-bit si gioca e che una replica "ragionevole" sbaglierebbe: si iterano **entrambi** i
tipi di virgoletta (come il `for` in bash, non `if/elif` come la (a-bis) accanto); lo strip di
`.log` è **case-sensitive** come `${_span%.log}`; gli span si raccolgono **una volta** prima
di mutare la stringa, come fa la process substitution in bash.

**Verifica**: la query reale dell'utente passa da `search_all_logs` (87%) a `grep_named_log`
(94%), unico tool sopra `TOOL_THRESHOLD`. 7 asserzioni in `tests/test-normalize-query.sh`
(letterale, `<PATTERN>` sull'altra stringa, **non** `<LOGFILE>`, apici singoli, e i due
confini: glob quotato resta `<LOGFILE>`, stringa non-log resta `<PATTERN>`), 4 di routing in
`run-tests.sh`. `--parity` 1146/1146 su entrambi i profili.

### SRCH-2 + QUOTE-1 — nota di chiusura (2026-08-19)

**La causa era strutturale, non un errore d'uso**, come già inquadrato nella nota di
design originale: `_is_system_log_base()` esclude access/server/gc dalla normalizzazione a
`<LOGFILE>`, quindi `grep_named_log` non li vedeva mai. Confermata anche la seconda causa,
scoperta solo affrontando l'implementazione: senza un segnale che distingua "virgolette =
pattern di ricerca" da "virgolette = nome di log", il classificatore non poteva imparare il
confine — da cui **QUOTE-1**, il prerequisito che ha reso SRCH-2 realizzabile.

**Decisioni prese e confermate in implementazione:**
- **Disambiguazione per forma**: stringa quotata glob-like (`*` + `.log`) → `<LOGFILE>`
  (esisteva già, priorità invariata); ogni altra stringa quotata → `<PATTERN>` (nuovo).
  La regola vive in `lib/normalize-query.sh`, replicata bit-identica in
  `lib/build_dataset.py` (parità verificata 1126/1126 su entrambi i profili).
- **Un solo rilevatore del log di sistema**: `system_log_kind_of()` (nuova, in
  `lib/utils-logfiles.sh`), di cui `_is_system_log_base()` è ora un wrapper booleano —
  evita un secondo rilevatore parallelo (principio 8). `SYSLOG_KIND` è emessa sempre,
  anche vuota, per non lasciare nel REPL il valore della query precedente.
- **Rotazioni**: default solo log corrente; storico completo solo con range temporale
  esplicito (`TIME_EXPLICIT`) — stessa convenzione di `tail_log`.
- **Cross-app**: politica unica sul tool — `require_app` ora vale anche sul ramo glob
  (`open_glob_logs`), che ne era sprovvisto; prima dell'estensione i due rami dello stesso
  tool avrebbero avuto comportamenti diversi sull'ownership dell'app.
- **Retrain**: `NUM_FEATURES` 111 → 113 (`<pattern>` + un bigramma `server.log|gc.log|access.log :: <pattern>|cerca\b|…`,
  tarato per non collidere con `correlate_gc_slow` né con `search_all_logs`), `MODEL_TOPOLOGY` →
  `113,48,16`, reinizializzazione via `setup.sh` (seed 42, deterministico). Accuratezza
  entro il range storico (94,62-95,56%). Verificato con dry-run: `cerca "NPE" nel
  server.log` → `grep_named_log` top-1, `filter_errors`/`search_all_logs` entrambi sotto
  `TOOL_THRESHOLD=0.25` (quindi non eseguiti).
- **Etichetta help (B6)**: `SOURCE_LABEL[named]` era `"named"` (gergo inglese in
  un'interfaccia italiana) — cambiata in `"applicativi"` in entrambi i `domain.conf`.

**Tre bug collaterali corretti in `lib/tools/grep_named_log.awk` (trovati implementando
il ramo di sistema, non presenti — o non osservabili — sul solo ramo named):**
1. **Messaggio fuorviante**: emetteva «nessuna riga riconosciuta nel formato atteso» anche
   quando ogni riga era stata riconosciuta e mancava solo il livello (caso normale per
   access/gc, che non hanno livello). Ora distingue "formato non riconosciuto" da "nessuna
   riga con quel livello", con accumulatore dedicato invece del solo stato per-record.
2. **Colonna thread**: estraeva il primo gruppo `[...]` come thread — su access/gc quel
   gruppo è il timestamp, quindi la colonna mostrava una data al posto del thread.
3. **Dedup silenzioso**: la chiave di deduplicazione era `level SUBSEP substr(msg,1,120)`;
   con `level` vuoto (access/gc) righe di richieste HTTP distinte ma con lo stesso prefisso
   collassavano in una sola riga con contatore, perdendo eventi realmente diversi.

**Verifica finale**: suite completa **96 PASS / 0 FAIL** su liquido e su usnext (pesi
condivisi, entrambi i profili testati); `--parity` **97 PASS / 0 FAIL**, 1126/1126 vettori
identici; `tests/test-help-sources.sh` 20 PASS/0 FAIL (incluse le due asserzioni gemelle
sulla nuova etichetta "applicativi"). Vincolo di performance rispettato per costruzione:
il ramo di sistema riusa `select_log_files_grouped`/`open_current_server_logs` come
`tail_log`, quindi il costo scala con il file scelto, non con il nodo — non con
"search_all_logs e filtra dopo".

### SRCH-3 — nota di chiusura (2026-08-19)

**Meccanismo confermato per riproduzione diretta**, non solo per lettura del codice:
isolato in uno script a parte (`eval echo "$tw_args" ... -v pattern="$_gnl_pattern" ...`
con `set -x`), la traccia mostra `pattern=No HeadersTranscoder provided.` come **una sola
parola** nel primo giro di `eval` ma **tre parole separate** nel secondo (quello che gawk
vede davvero) — `pattern=No`, `HeadersTranscoder`, `provided.`: le ultime due, senza `=`,
sono gli argomenti che gawk apre come file, producendo esattamente l'errore di produzione.

**Fix**: calcolata una sola volta `_gnl_pattern_q` con `printf -v _gnl_pattern_q '%q'
"$_gnl_pattern"` (subito dopo che `_gnl_pattern` è definitivo, prima dei tre rami), poi
`-v pattern=$_gnl_pattern_q` (senza virgolette proprie — `%q` produce già una forma
auto-quotata) in tutti e tre i siti. Un solo calcolo, tre usi (principio 2) — non tre
fix indipendenti. Preferito a estendere manualmente il trucco di `tw_args` (virgolette
singole letterali) perché `%q` gestisce anche apici, `$`, backtick nel pattern, non solo
gli spazi — verificato con un pattern che li contiene tutti.

**Ambito**: `STATUS_CODE` e `IP_FILTER`, che passano per lo stesso costrutto `eval` in
altri rami del case, sono vincolati per costruzione da `param-extract.sh` (rispettivamente
`\b[45][0-9]{2}\b`/`5xx`/`4xx` e un'IP regex) — non possono contenere spazi, quindi non
condividono il difetto. `SEARCH_PATTERN` era l'unico valore realmente libero passato per
questa via; `search_all_logs` usa `export`, non `eval`, quindi non è mai stato esposto.

**Test di regressione**: `tests/test-srch-named-log.sh`, nuova sezione con la stringa
reale dell'incidente (`"No HeadersTranscoder provided."`) aggiunta alla fixture del
server.log — verifica sia l'assenza del crash sia il match corretto. Riprodotta anche la
query esatta dell'utente end-to-end (stesso profilo, stesso tool) prima e dopo il fix.

**Verifica finale**: suite completa **96 PASS / 0 FAIL** su liquido e su usnext (nessuna
modifica al vocabolario o al modello — bug di runtime, non di classificazione, quindi
nessun retrain necessario).

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

## FORMAT-1 — Il formato delle righe si riconosce per forma — **FATTO** (2026-08-17)

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

**RISOLTO** (2026-08-17). Scelta la via del **riconoscimento per forma**, non della config
(`ACCESS_TS_FIELD=2` in `system.conf` era l'alternativa): un indice da configurare sposta il
problema su chi installa un profilo nuovo, che deve contare i campi del proprio access log —
e sbagliare il numero riprodurrebbe lo stesso fallimento silenzioso. Riconoscere la forma è
la strategia già usata da `_logfiles_read_first_ts()`, che identifica 4 formati di timestamp
senza che nessuno sia configurato.

| ID | Descrizione | Stato |
|----|-------------|-------|
| FORMAT-1a | **`access_ts()`** in `utils-time.awk`: scandisce i campi della riga cercando quello con la **forma** `[DD/Mon/YYYY:HH:MM:SS` (pattern abbastanza specifico da non collidere con IP, status o byte count). Il campo trovato è memorizzato in `_ats_field`, quindi la scansione avviene **una volta per file**: dalla seconda riga si va diretti al campo noto. Se il campo memorizzato non produce un timestamp (riga malformata) ri-scandisce invece di restituire 0 — principio 5 | **Fatto** |
| FORMAT-1b | **Reset per file** (`FNR == 1 { _ats_field = 0 }`): i tool ricevono corrente + rotazioni insieme, e `correlate_gc_slow` due sorgenti di formato diverso. Senza reset il campo del primo file "contaminerebbe" i successivi. Vive in `utils-time.awk`, caricato come primo `-f` da tutti i tool, invece di 8 copie della stessa regola (principio 2) | **Fatto** |
| FORMAT-1c | **8 tool migrati** da `parse_access($2)` a `access_ts()`: `count_status`, `distribute_status`, `slow_requests`, `traffic_volume`, `service_times`, `filter_ip`, `tail_log`, `correlate_gc_slow`. `parse_access()` resta invariata e memoizzata — il problema non era la funzione ma gli indici nei chiamanti | **Fatto** |

**Il fallimento era peggiore di come era stato descritto.** L'analisi diceva "il filtro
temporale smetterebbe di filtrare"; misurato, su un log *combined* di 3 righe con una
finestra che ne copre 2, il vecchio codice rispondeva **«Nessuna richiesta trovata nel
periodo selezionato»** — non un filtro inattivo ma un **falso negativo pieno**, la stessa
classe di LOGSEL-1c.

**Costo misurato** (200.000 righe, 15 MB, 5 round): mediana **0.52s → 0.55s**, +6% (~0.03s).
La scansione avviene una volta per file, non per riga, quindi il costo per riga è invariato.
Trascurabile contro i ~83s di una query reale (P4).

**Verifica**: 9 asserzioni in `tests/test-access-format.sh` su 3 formati (Undertow reale,
combined Apache/WebSphere, timestamp in prima posizione) + righe malformate + multi-file con
formati misti. **Fail-before/pass-after**: 6 FAIL senza il fix, 0 con.

**Lezione di metodo**: 2 delle 9 asserzioni fallivano alla prima stesura, e sembrava un bug
del codice — erano invece **asserzioni sbagliate** (cercavano `GET /ping` in una tabella che
separa metodo e URL in colonne). Verificato l'output reale prima di toccare la produzione,
come prescrive il principio 8: *un test che fallisce non implica un bug nel codice*.

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

**Decisione (utente, 2026-08-17): completarlo quando i log saranno montati.** `usnext` verrà
montato su `lxprworkerlana01` accanto a `liquido` (il nuovo `LOG_BASE_DIR` è
`/unipol/logs/farmlog/<profilo>/`, predisposto per il multi-profilo). I nomi dei log si
leggeranno **dal filesystem reale**, non ipotizzati — è l'unico modo di completarlo con dati
verificati. A quel punto diventa anche la prova più forte che il contratto non è
liquido-specifico: oggi la generalità è argomentata leggendo il codice, non dimostrata
eseguendolo.

**Fatto intanto — guard di completezza** (`chatbot.sh`, 2026-08-17): all'avvio verifica le 9
variabili che il contratto richiede (`LOG_BASE_DIR`, i tre `*_LOG_BASE`,
`SERVER_LOG_FORMAT`, `NODE_NAME_TEMPLATE`, `DEFAULT_APP`, `ENV_NODE_CODE`,
`AVAILABLE_APPS`) ed elenca **tutte** quelle mancanti in un messaggio solo, indicando
`profiles/liquido/system.conf` come riferimento. Prima il problema emergeva alla prima
query, una variabile per volta, dal punto di vista di `resolve-logs.sh`. Su `usnext` oggi
dice: `Mancano in system.conf: ACCESS_LOG_BASE SERVER_LOG_BASE GC_LOG_BASE
SERVER_LOG_FORMAT NODE_NAME_TEMPLATE`.

Un profilo incompleto è un errore di **configurazione**, non un incidente di runtime — e va
detto all'avvio, non a metà di una risposta.

---

## USNEXT-1 — Quattro difetti da conoscenza duplicata, trovati validando su dati reali usnext — **FATTO** (2026-08-18)

`profiles/usnext` montato su `lxprworkerlana01` (seguito di PROF-1). La validazione dei 16
tool sul nodo `lxprjbusal01` (app `PassInsurance`) ha esposto quattro difetti, tutti con la
stessa radice — conoscenza duplicata inline invece di condivisa — nessuno visibile su
`liquido`, dove le stesse assunzioni hardcoded erano vere per caso. Piano:
`.claude/plans/rosy-noodling-owl.md`.

- **(a) `service_times` — ~1064/1204 "servizi" fantasma.** `access_url_root()`
  (`lib/utils-access-undertow.awk`) non escludeva `?`/`&`/`=`/`;` dal path: ogni variante di
  query string sullo stesso endpoint diventava un servizio distinto. Corretto derivando la
  radice da `access_url()` (già esistente) invece di una classe negata incompleta; la
  richiesta alla radice (`GET /`) ora restituisce il segmento esplicito `"/"` invece di `""`,
  che `service_times.awk` scartava in silenzio. Riprodotto dal vivo: 1204 servizi sul
  deployato attuale.
- **(b) `grep_named_log` — «Nessuna riga riconosciuta nel formato atteso» su `Pass.log`** (15
  ERROR + 1380 WARN reali, 0 mostrate). Il tool hardcodava la grammatica ISO di `liquido`
  (`GW_RE`) e scartava (`next`) ogni riga in altro formato — incluso quello europeo
  (`DD-MM-YYYY HH:MM:SS.mmm LEVEL msg`) di `Pass.log`. Corretto migrando a
  `logline_parse()` (nuovo `lib/utils-logline.awk`, Intervento 1), tabella ordinata di 6
  grammatiche (le 5 già note al lato bash + il caso solo-ora di `console.log`), e togliendo
  il `next` che scartava: una riga non riconosciuta ora è inclusa senza livello (principio
  5), non persa. Migrati anche gli altri tre cloni della stessa regex:
  `tail_named_log.awk`, `tail_log.awk`, `search_all_logs.awk`.
- **(c) `list_logs` — `undertow_access_log` elencato 70 volte** (su 74 log totali) invece di
  1. `_log_names_in_dir()` (`lib/dispatch.sh`) reimplementava inline la derivazione del nome
  logico con una `sed` che non gestiva la rotazione `NAME.YYYY-MM-DD.log` — lo stesso bug
  già corretto in `logfile_logical_name()` il 2026-08-07, mai migrato qui (principio 8).
  Corretto delegando a `logfile_logical_name()`/nuova `logfile_display_name()`. Riprodotto
  dal vivo anche su `liquido` (35/75 duplicati sul nodo 4): il difetto era presente ovunque,
  solo mascherato su `liquido` da ~40 nomi applicativi realmente distinti. Lo strip del
  prefisso host (`coll1nssa-` → `cc`), prima incondizionato nella stessa `sed`, è diventato
  la chiave opzionale di profilo `LOG_NAME_HOST_PREFIX_RE` (`system.conf`, impostata solo su
  `liquido`) — evita che un nome come `foo-bar.log` venga troncato a `bar` su un profilo che
  non ha quella convenzione.
- **(d) `search_all_logs` — PRIMO/ULTIMO MATCH mostra `-` con `MATCH > 0`** su
  `console.log`, che logga solo l'ora (nessun anno a 4 cifre, che le due regex inline del
  tool richiedevano). Con `logline_parse()` il tool ottiene anche `_ll_has_date` e accumula
  due min/max distinti (datati / solo-ora), emettendo il primo se esiste, altrimenti il
  secondo marcato come parziale — mai mescolati (principio: confronto per stringa,
  `"00:03:37"` ordinerebbe prima di qualsiasi `"2026-..."`). **Scoperta in fase di
  validazione, più seria del sintomo iniziale**: il codice precedente non si limitava a
  omettere la data quando assente — la regex ISO nuda (senza contesto) matchava anche
  timestamp interni a payload JSON di risposta HTTP (es. `"tsAggiornamento":
  "2026-01-14T06:03:37.438777"`, dato anagrafico, non temporale del log), producendo una
  data mostrata **sbagliata**, non solo mancante. Verificato: `logline_parse()` rifiuta
  quella stessa riga (richiede il contesto `[thread] USER ... LIVELLO` attorno al
  timestamp), il codice precedente no.

**Verifica — correzione 2026-08-18 al testo precedente**: `bash tests/run-tests.sh` in
questa sessione non esegue nemmeno il Level 1 (bloccato da **NCLOCAL-1**, sotto — causa
scoperta *dopo* aver scritto la prima versione di questa nota, non collegata ai quattro
bug). Isolando le sole unit test (`run_unit_tests`, bypassando `run_intent_tests`): 13 file
su 16 puliti. I restanti 3 (`test-theme.sh` 10/53 FAIL, `test-srch-named-log.sh` 12/20 FAIL,
`test-profile-config.sh` 7/20 FAIL) **non sono la stessa cosa già documentata prima di
questo intervento**, come scritto qui in precedenza: sono, verificato riga per riga sul
codice dei tre file, **tutti e soli** i FAIL sulle asserzioni che invocano `chatbot.sh
--query` per una classificazione reale — cioè NCLOCAL-1, non un difetto di questo piano. Le
asserzioni che precedono la classificazione (controlli di struttura profilo, guard su file
obbligatori) restano verdi negli stessi file. La correzione dei quattro bug è verificata
dai test che **non** passano da `chatbot.sh`: `tests/test-logline.sh` (nuovo, parità
bash↔AWK sulle 6 grammatiche — bug b/d), `tests/test-logname-display.sh` (nuovo, rotazioni,
prefisso configurato/non configurato, coerenza display↔resolve — bug c), sezione
`service_times` in `tests/test-access-format.sh` (bug a) — tutti e tre invocano `gawk`/le
funzioni bash direttamente, mai `chatbot.sh`, quindi immuni a NCLOCAL-1. La fixture EU
aggiunta a `tests/test-srch-named-log.sh` per il bug (b) è invece bloccata da NCLOCAL-1 come
il resto del file (confermato: riproducendo a mano la stessa query via `chatbot.sh` si
osserva lo stesso fallimento silenzioso, non un formato non riconosciuto) — la correzione
del bug (b) resta comunque verificata da `test-logline.sh`, che testa la stessa grammatica
europea senza passare da `chatbot.sh`.

**Validazione dal vivo** (SSH read-only su `lxprworkerlana01`): i quattro sintomi (a)-(d)
riprodotti contro il codice **attualmente deployato** (non ancora corretto — il deploy
richiede una sessione con autorizzazione in scrittura, non concessa in questa). La
correzione è verificata **localmente** (suite unitaria + fixture dedicate); la validazione
dal vivo del codice corretto resta da fare al prossimo deploy.

---

## NCLOCAL-1 — Modello locale convertito a neural-c, retrain completo — **FATTO** (2026-08-19)

Indicazione esplicita dell'utente: backup dei pesi attuali, poi retrain completo via
`neural-c` per avere tutto convertito localmente, e solo dopo una suite locale verde
valutare un deploy in produzione (il deploy stesso resta fuori scope, decisione
dell'utente).

- **Backup**: `nlp/models/intent_classifier/` copiata (`cp -a`) in
  `nlp/models/intent_classifier.backup/` prima di qualunque azione — coperta dal pattern
  `.gitignore` `**/models/*.backup/`, quindi non tracciata. Contiene gli artefatti
  neural-bash originali (`layer1.txt`, `layer2.txt`, `model.conf`, `best/`) che
  `setup.sh`/`train.sh` non toccano (verificato: `neural-c init --force` scrive solo i
  propri file — `model.txt`, `project.conf`, `train.txt`, poi `dataset.txt` — e lascia
  intatti quelli preesistenti; i vecchi file restano nella directory live, ora orfani,
  perché nessun chiamante li legge più da quando `lib/infer.sh` invoca solo `neural-c
  predict`).
- **Rebuild + retrain**: `build-dataset.sh --profile profiles/liquido` (1086 esempi, contro
  i 968 documentati in una versione precedente di `CLAUDE.md`, ora obsoleta) → `setup.sh`
  (`neural-c init --force`, topologia `111,48,16`) → `train.sh` (adam, early stopping
  all'epoca 635 su un massimo di 5000, pesi selezionati dall'epoca 535, val loss ≈0.0065).
  `gap-report.sh --compact` (eseguito in automatico da `train.sh`): nessun vettore zero (le
  1086 esempi coprono tutte le classi), 16 classi con gap di vocabolario — informativo, non
  azionato in questo intervento.
- **Validazione locale**: `bash tests/run-tests.sh` passa da **91 PASS / 1 FAIL** (subito
  dopo il retrain) a **92 PASS / 0 FAIL**. Level 1 (tutte le query di classificazione
  intent) 100% corretto sul tool atteso, confidenze 31%–99% — anche i casi a confidenza più
  bassa instradano al tool giusto.
- **Difetto scoperto durante la validazione, indipendente dal retrain**:
  `lib/tools/grep_named_log.awk` confondeva "riga riconosciuta da una qualunque grammatica
  di `logline_parse()`" con "riga con un livello di severità leggibile", tramite un unico
  contatore (`matched_format`) usato per decidere se stampare il messaggio LOGSEL-1
  («formato non riconosciuto») invece del generico «Nessuna riga trovata (level=...)». I due
  concetti coincidevano per caso prima della migrazione a `logline_parse()` (Intervento 1 di
  USNEXT-1, sopra): la vecchia regex Guidewire-only matchava solo righe con **sia**
  timestamp **sia** livello. Dopo la migrazione, `logline_parse()` riconosce anche i
  timestamp di access log — che per costruzione non hanno mai un livello testuale
  (`lib/utils-logline.awk`, ramo Undertow, commentato esplicitamente) — rompendo quella
  coincidenza: un file in formato access log ora contava come "formato riconosciuto" pur
  non producendo mai un `row_level`, e il messaggio LOGSEL-1 non scattava più sulla fixture
  di `tests/test-srch-named-log.sh` dedicata (2 FAIL). Corretto sostituendo il contatore con
  `matched_level` (incrementato solo quando `_ll_level != ""`), non `matched_format`.
  Verificato per principio 8 che nessuno degli altri tre tool migrati nello stesso
  intervento (`tail_named_log.awk`, `tail_log.awk`, `search_all_logs.awk`) ha lo stesso
  pattern di conteggio aggregato — il difetto era isolato a questo file. Bug reale e
  precedente al retrain, rimasto invisibile perché **NCLOCAL-1** faceva fallire in silenzio
  ogni query `chatbot.sh` prima di raggiungere quel codice.

**Esito**: modello locale interamente in formato `neural-c`, suite locale interamente
verde. Il deploy in produzione resta una decisione dell'utente, non presa in questo
intervento.

---

## USNEXT-2 — Incoerenza URL fra `distribute_status` e gli altri tool access — **FATTO** (2026-08-19)

Diagnosi corretta rispetto al testo precedente (aperto durante USNEXT-1, Intervento 5):
`service_times` **non** mostra più l'URL con query string da quella stessa correzione —
usa `access_url_root()`, che collassa al primo segmento. Verificati anche `slow_requests` e
`correlate_gc_slow`: mostrano l'URL **intero** (con query string) deliberatamente, perché
sono tool di **detail** (elencano singole richieste/eventi — l'utente vuole identificare o
riprodurre una richiesta specifica), non di aggregazione. Il gap reale era più ristretto di
come la voce originale lo descriveva: `distribute_status` (un tool di **aggregazione**, come
`service_times`, ma a una granularità diversa — endpoint esatto, non modulo) aveva la sola
normalizzazione URL del repo scritta inline, senza test dedicati — lo stesso gap che
`service_times`/`access_url_root()` aveva prima di Intervento 5.

Non unificata con `access_url_root()`: le due funzioni servono granularità diverse e
legittime — `access_url_root()` collassa al primo segmento (`/portal/api/rest/anag` →
`portal`, "che modulo"), `access_url_endpoint()` preserva il path intero e templatizza solo
le parti variabili (`/rest/claims/998877?type=auto` → `/rest/claims/{id}`, "quale rotta
esatta"). Unificarle avrebbe reso `service_times` più grossolano o `distribute_status` più
aggressivo.

- Estratta la normalizzazione inline di `lib/tools/distribute_status.awk` (query string,
  matrix parameter, ID numerici ≥5 cifre, UUID) in `access_url_endpoint()`, nuova funzione
  condivisa in `lib/utils-access-undertow.awk` accanto ad `access_url_root()`.
  `distribute_status.awk` migrato a chiamarla (principio 8: la centralizzazione include il
  chiamante preesistente, non solo la nuova funzione).
- Nuova sezione in `tests/test-access-format.sh`: 5 casi via `distribute_status.awk` reale
  (non la funzione isolata) — due ID ≥5 cifre diversi collassano sullo stesso endpoint, un
  ID corto (2 cifre) **non** templatizzato, matrix parameter tagliato, UUID templatizzato,
  path senza nulla da normalizzare passa invariato.
- `bash tests/run-tests.sh`: **92 PASS / 0 FAIL**, nessuna regressione.

**Esito**: `slow_requests`/`correlate_gc_slow` confermati corretti così com'erano (nessuna
modifica — comportamento voluto). `distribute_status` ora condivide la stessa disciplina di
`service_times`: normalizzazione centralizzata e testata, non inline.

---

## HELP-1 — Categoria dell'help derivata da `TOOL_SOURCES`, non più prosa parallela — **FATTO** (2026-08-19)

Prima di questo intervento esistevano due fonti indipendenti per "quale log apre questo
tool": `require_system_log` chiamato a mano nel `case` di `_dispatch_tool_run`
(`lib/dispatch.sh`) e `TOOL_CATEGORY`, prosa scritta a mano tool-per-tool in ciascun
`domain.conf`. Erano già divergenti: `service_times` era categorizzato "Server log JBoss"
in `TOOL_CATEGORY` ma legge l'access log da `60f679e` (2026-07-29) — un bug dell'help,
invisibile perché non testato, non del dispatch.

- **`TOOL_SOURCES`** (nuova tabella in `nlp/tools.conf`, framework — non nel profilo: la
  partizione tool→sorgente è identica su `liquido` e `usnext`, verificato a diff) diventa
  la sola fonte di verità. Sintassi: un kind singolo (`"access"`), AND con spazio (`"gc
  access"` per `correlate_gc_slow`, entrambe le sorgenti richieste incondizionatamente), OR
  con `|` (`"access|server"` per `tail_log`, scelto a runtime da un selettore — `LOG_TYPE`),
  e i kind non di sistema `named`/`all`/`none`.
- **Guard table-driven**: `tool_source_kinds()` espande la dichiarazione nei kind concreti
  per un tool + selettore; `require_tool_sources()` la consuma fermandosi al primo kind
  assente (il messaggio di skip nomina il kind giusto, come i guard manuali precedenti).
  Ogni chiamata diretta a `require_system_log` nel `case` è stata sostituita — principio 8,
  la centralizzazione include i chiamanti preesistenti, non solo la nuova tabella.
- **Help derivato**: `tool_help_category()` deriva la categoria da `TOOL_SOURCES` (kind
  `none` → nessuna categoria, `all` → `ACTIVITY_CATEGORY` per attività —
  `search_all_logs`/`list_logs` restano su voci distinte, non una categoria "sorgente"
  comune — altrimenti `SOURCE_CATEGORY` del primo kind). `tool_help_annotation()` annota
  inline i tool multi-sorgente (`· access o server` per un OR, `· gc + access` per un AND) —
  un elenco singolo annotato, non una riga duplicata per categoria. `domain.conf` si riduce
  alle sole etichette (`SOURCE_CATEGORY`, `SOURCE_LABEL`, `ACTIVITY_CATEGORY`), coordinate di
  questo profilo — non più la partizione stessa.
- **`tests/test-help-sources.sh`** (nuovo): completezza (ogni tool in `TOOL_NAMES` ha una
  voce in `TOOL_SOURCES`), chiusura (ogni kind citato ha un'etichetta), rendering (nessun
  tool duplicato o assente, `service_times` correttamente sotto "Log HTTP (access log)",
  annotazioni multi-sorgente presenti) su entrambi i profili, e coerenza col codice (zero
  chiamate dirette residue a `require_system_log` nel `case`).
- **Ripresa dopo interruzione**: la sessione che ha scritto l'implementazione si è
  interrotta prima di eseguire il nuovo test per la prima volta. Alla ripresa, il test
  falliva per motivi indipendenti dal refactor:
  1. `_load_profile()` era una funzione bash che sourciava `tools.conf`/`domain.conf` al suo
     interno — in bash `source` non apre un proprio scope, quindi ogni `declare -A` in quei
     file diventava locale alla funzione e spariva al `return` (`count_status: unbound
     variable`). Non un problema in produzione (`chatbot.sh` sorcia a top-level), solo nel
     test — eliminata la funzione, caricamento inlineato due volte (un profilo per volta).
  2. Gap reale nell'invariante di chiusura: `SOURCE_LABEL[named]` mancava in entrambi i
     `domain.conf` (non ancora sfruttato — nessun tool ha `named` in OR/AND con un altro
     kind oggi — ma il test lo richiede per non lasciare un buco silenzioso se un domani lo
     sarà). Aggiunto in entrambi i profili.
  3. L'AWK che isola la sezione-categoria di `service_times` confondeva l'header di
     categoria con la riga del tool stesso — nell'output di `print_help` entrambi iniziano
     con "  " + testo in grassetto, indistinguibili per indentazione dopo lo strip dei
     codici colore. Corretto confrontando contro l'elenco esatto di `HELP_CATEGORIES`
     invece di indovinare dalla forma della riga.
  4. Il test non era ancora agganciato a `tests/run-tests.sh` — aggiunto a
     `run_unit_tests()`.

**Esito**: `bash tests/run-tests.sh` → **93 PASS / 0 FAIL**. `print_help` verificato anche a
occhio: `service_times` sotto "Log HTTP (access log)" (bug storico corretto), `tail_log`
annotato "· access o server", `correlate_gc_slow` "· gc + access", `show_help` assente.

- **Bug di produzione trovato in verifica dal vivo post-deploy**: la query reale `aiuto`
  su `chatbot.sh` (che gira con `set -euo pipefail`, a differenza del test che usa
  `set -uo pipefail` senza `-e` per necessità di scoping — vedi punto 1 sopra) troncava
  l'help dopo la categoria "Log HTTP (access log)" con `exit 1`. Causa:
  `tool_help_category()` aveva `none) return ;;` senza status esplicito — `return` nudo
  eredita l'exit status dell'**ultimo comando eseguito**, cioè il test
  `[[ "$first" == *"|"* ]]`, falso per `"none"` (status 1). L'assegnazione
  `tool_cat="$(tool_help_category ...)"` per `show_help` (kind `none`) propagava quello
  status 1, e sotto `set -e` l'intero script terminava lì — assorbito silenziosamente dal
  trap `EXIT` (`_rotate_query_logs` in `chatbot.sh`), quindi invisibile in `bash -x` senza
  guardare l'exit code stesso. **Fix**: `return 0` esplicito. Aggiunto un test di
  regressione dedicato che isola lo scenario `-e` in un subshell (`bash -c 'set
  -euo pipefail; ...'`), l'unico modo per esercitarlo senza rompere lo scoping degli array
  associativi sourciati nel resto del file. Verificato dal vivo sul server dopo il fix:
  output completo, `exit 0`.

---

## SEV-1 — Denominatore sbagliato e 3xx invisibile in tre tool access log — **FATTO** (2026-08-19)

Trovato dall'utente durante il test manuale in produzione su entrambi i profili
(`liquido` e `usnext`, stessa query in parallelo): `count_status.awk` su "quanti errori
500 stamattina" mostrava `100.0%` nella tabella STATUS, appena sopra un summary che
correttamente riportava un tasso d'errore reale del `0.17%`/`2.18%` — contraddizione
solo apparente, ma fuorviante.

- **Causa**: `pct = count[s] / total * 100` (riga 67) divide per `total`, il contatore
  **filtrato** da `status_filter` — quando il filtro è un codice esatto (es. `"500"`), la
  tabella ha una sola riga e `count[s] == total` per costruzione, quindi `100.0%` è
  matematicamente inevitabile ma non dice nulla sul peso reale sul traffico. Il summary
  sotto (già presente) usa invece correttamente `all_total`, il contatore non filtrato.
  **Fix**: stesso denominatore in entrambi i punti — `pct = count[s] / all_total * 100`.
  Comportamento identico a prima quando `status_filter` è vuoto (`total == all_total` per
  costruzione in quel caso).
- **Verifica principio 8** (parallel-assumption check): controllato se lo stesso pattern
  filtrato/non-filtrato esiste altrove — `distribute_status.awk` non ce l'ha (un solo
  contatore, nessun filtro per singolo status). Nessun altro tool affetto.
- **Gap collegato, stesso principio (2xx ok / 3xx neutro / 4xx warn / 5xx crit)**: la riga
  "Redirect 3xx" nel summary di `count_status.awk` era condizionale (`if (s3xx > 0)`),
  unica delle quattro a poter scomparire a zero invece di mostrare `0 (0.0%)` come le
  altre — tolta la condizione. `traffic_volume.awk` non aveva **nessuna** colonna 3xx
  nella tabella per fascia oraria (solo `TOTALE`/`4xx`/`5xx`) — aggiunta una colonna `3xx`
  tra `TOTALE` e `4xx`, stesso schema di conteggio e colore (`C_INFO`, neutro) di 4xx/5xx.
  `filter_ip.awk` mostrava già il 3xx nella distribuzione per IP (non era un'omissione),
  ma senza colore distintivo — uniformato a `C_INFO` come nel resto del progetto.
  `distribute_status.awk` (filtra di default solo 4xx/5xx, per scelta: un redirect non è
  un fallimento da distribuire per endpoint) e `slow_requests.awk` (colora le righe lente
  in solo due livelli, 5xx vs resto — scelta già dichiarata nel commento del file, non un
  buco emerso ora) sono stati valutati e lasciati invariati: non sono lo stesso difetto.

**Esito**: `bash tests/run-tests.sh` → **93 PASS / 0 FAIL** (nessun test asseriva sui
valori di `%` o sul layout delle colonne di questi tool, quindi nessuna modifica ai test
è stata necessaria). Verificato anche con un log sintetico a mano: `count_status.awk`
filtrato su `500` con 5 richieste totali (2×200, 2×302, 1×500) mostra ora `20.0%`
coerente col summary, non più `100.0%`.

---

## SEV-2 — Riga "Log:" senza spaziatura né contesto su dimensione/freschezza — **FATTO** (2026-08-19)

Trovato dall'utente durante lo stesso test manuale (`distribuzione errori sul nodo 3`,
profilo `usnext`): la riga `Log: /path/...` era attaccata senza soluzione di continuità
alla tabella di risultato sottostante, e non diceva nulla su quanto fosse grande o
recente il file che stava mostrando.

- **Individuazione del punto centrale**: `print_log_source()` (`lib/dispatch.sh`) è già
  il punto unico che stampa la riga "Log:" per 16 delle 18 chiamate nel `case` di
  dispatch — ma `tail_named_log`/`grep_named_log` con log singolo risolto la bypassavano
  con un `printf` diretto (principio 8: centralizzare significa migrare **tutti** i
  chiamanti). Migrati entrambi a `print_log_source "$(open_log "$log_path")"`.
- **Nuove funzioni** (`lib/dispatch.sh`, vicino a `print_log_source`): `_format_size`
  (byte → `B`/`K`/`M`/`G`), `_format_time_ago` (epoch → `Ns fa`/`Nm fa`/`Nh fa`/`Ng fa`,
  stesso vocabolario italiano che `utils-time.sh` già usa in senso inverso per
  interpretare il linguaggio naturale dell'utente), `_log_file_info` (dimensione totale +
  mtime più recente di un elenco di path — con più file, per costruzione, misura il file
  "vivo" che riceve ancora scritture, non una rotazione ferma).
- **Formato scelto**: `[dimensione, N fa]` tra `[]` (non `()`, per coerenza con la riga
  di contesto `[prod · nodo NN · App · ...]` già usata sopra, che adotta la stessa
  convenzione per i metadati). Esempio: `Log: .../undertow_access_log.log [237B, 1s fa]`.
- **Spaziatura strutturale**: `print_log_source()` ha ora un secondo parametro opzionale
  `suffix` (assorbe le annotazioni `(glob: ...)`/`(level=...)` che prima erano `printf`
  separati nei chiamanti) e termina sempre con una riga vuota — un solo punto decide la
  spaziatura verso il corpo della risposta, invece di richiederla a ciascun chiamante.
- **Test-fix collegato**: `tests/test-theme.sh` confrontava byte-per-byte l'output tra
  temi diversi per garantire che nessun tema nasconda dati — ma l'annotazione `[N fa]` è
  per natura legata all'orologio reale (ogni tema è un'invocazione separata di
  `chatbot.sh` a distanza di secondi dalle altre), quindi il numero cambia legittimamente
  run per run. Aggiunta una maschera (`_mask_log_info`) che normalizza il blocco
  `[dimensione, N fa]` prima del confronto — non un rilassamento del test, ma la
  correzione di un'assunzione (contenuto deterministico) diventata falsa per un dato che
  è deliberatamente non deterministico.

**Esito**: `bash tests/run-tests.sh` → **93 PASS / 0 FAIL**. Verificato anche dal vivo con
`chatbot.sh` su una fixture sintetica (stessa fixture di `test-theme.sh`): riga vuota tra
`Log:` e la tabella, annotazione `[237B, 1s fa]` corretta sia nel caso a file singolo che
nel caso a più file (rotazione, dove mostra la somma delle dimensioni e il "fa" del file
più recente del gruppo).

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
| PERF-NNET | **Overhead fisso per query (~574ms)**: classificazione neurale (`infer.sh`) + `normalize-query.sh` + `param-extract.sh` + fork di `resolve-logs.sh`. Vedi sotto | — | **Chiuso 2026-08-18 — la modifica major (migrazione a `neural-c`) è fatta; riaperto come NNET-C-PERF se il costo del digest per-`predict` risulta significativo** |

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

**Chiuso 2026-08-18 — la modifica major è `neural-c`.** `neural-bash` e il backend PyTorch
(`lib/train.py`) sono stati rimossi; `neural-c` è ora l'unico motore neurale del progetto
(training e inferenza), su x86_64 e ppc64le. Migrazione completata in 4 fasi (vedi
`docs/sessions/2026-08-18-01.md`): equivalenza numerica del forward pass verificata,
5 esperimenti di training confrontati con la baseline PyTorch, sostituzione dei 6 file che
conoscevano il formato dei pesi, validazione end-to-end (`setup.sh` → `build-dataset.sh` →
`train.sh` → `tests/run-tests.sh`) in una copia isolata: **90 PASS / 0 FAIL**, invariato
rispetto alla baseline pre-migrazione.

**Non ancora misurato — riapre come NNET-C-PERF se il numero è alto:** `neural-c predict`
ricalcola i digest del progetto (inclusi ~138.000 valori di `train.txt`) a ogni invocazione.
La baseline di 574ms era su `nnet-run.sh predict` (gawk, nessun digest); il costo reale della
nuova pipeline va misurato in produzione con `perf-report.sh` **dopo** la Fase 5 (ciclo
completo su `lxprworkerlana01`, non ancora eseguita — richiede accesso SSH e conferma
esplicita, dato il rischio di toccare pesi in produzione). Se il digest domina, la correzione
va fatta in `neural-c` (l'utente ne è il maintainer), non aggirata qui — vedi il piano di
migrazione per il dettaglio del meccanismo.

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
