# NLP e Training — Come funziona la classificazione

## Il problema

Data una query in italiano come `"errori nel server log di stamattina"`, il sistema deve scegliere uno tra 15 tool possibili.

Non usiamo un LLM perché il dominio è chiuso e ben definito: le query riguardano sempre log, sempre su ambienti noti. Una rete neurale piccola addestrata su esempi reali basta — ed è 100× più veloce e non richiede internet.

---

## Step 1 — Dal testo al vettore numerico

`query-to-features.sh` converte la query in un vettore di 97 numeri.

**Come funziona:**

```
query → lowercase → match contro 97 pattern ERE → vettore [0, 0, 2, 1, 0, ...]
```

Ogni posizione corrisponde a un pattern del vocabolario. Il valore è:
- `0` se il pattern non è presente nella query
- `1` o `2` se è presente (il peso è definito in `unigrams.txt`)

**Esempio:**

```
Query: "errori 500 di stamattina"

Pattern         Valore
errore|errori     2    ← peso 2 (discriminante)
500               1
stamatt|stanott   1
lent[oaie]|slow   0
gc|garbage        0
...               ...
```

Il vettore risultante è l'**input** della rete neurale.

---

## Step 2 — Unigram e Bigram

Il vocabolario ha due livelli:

**Unigram** (`unigrams.txt`) — un pattern presente da solo nella query:
```
lent[oaie]|slow           :: 2    ← attivato da "lento", "slow", "lenti", ...
gc|garbage                :: 1
cerca\b|trova\b           :: 2
```

**Bigram** (`bigrams.txt`) — due pattern che devono essere presenti *insieme*:
```
lent[oaie]|slow :: servizi|soa\b  ← "servizi lenti" → service_times, NON slow_requests
gc\b|garbage    :: lent[oaie]     ← "GC lento" → correlate_gc_slow, NON gc_stats
```

I bigram risolvono le ambiguità che gli unigram non possono: "lento" da solo attiva `slow_requests`, ma "GC lento" deve attivare `correlate_gc_slow`.

---

## Step 3 — La rete neurale

Topologia: **97 → 48 → 15**

```
Input layer        Hidden layer       Output layer
(97 feature)  →   (48 neuroni)   →   (15 probabilità)
                   sigmoid            softmax → somma = 1
```

Ogni output corrisponde a un tool. Il tool scelto è quello con probabilità più alta, purché superi la soglia di confidenza (0.25).

**I pesi** sono memorizzati in due file di testo:
- `layer1.txt` — 48 righe × 98 colonne (97 input + 1 bias)
- `layer2.txt` — 15 righe × 49 colonne (48 neuroni + 1 bias)

---

## Step 4 — Training

Il dataset è in `profiles/liquido/dataset/queries_labeled.txt`:

```tsv
filter_errors     errori nel server log di stamattina
slow_requests     richieste lente delle ultime 2 ore
grep_named_log    errori nel cc.log del nodo 5
```

**Pipeline completa:**

```
1. build-dataset.sh
   queries_labeled.txt → queries.txt
   (ogni query passa per query-to-features.sh → vettore numerico)

2. Linter automatico
   Segnala query con vettore tutto-zero (nessun pattern attivato)
   → indicano che manca vocabulario o la query è mal formulata

3. train.sh
   - ottimizzatore: Adam
   - loss: cross-entropy
   - epoche: ~2000
   - output: layer1.txt, layer2.txt aggiornati
```

---

## Aggiungere un nuovo intent (tool)

1. Scrivere il tool `.awk` in `lib/tools/`
2. Aggiungere il tool a `TOOL_NAMES` in `domain.conf`
3. Aggiungere esempi in `queries_labeled.txt`
4. Aggiungere vocab se mancano pattern in `unigrams.txt`
5. `build-dataset.sh` + `train.sh`

La rete si adatta automaticamente al nuovo numero di output.
