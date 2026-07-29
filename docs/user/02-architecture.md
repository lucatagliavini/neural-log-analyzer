# Architettura del sistema

## Flusso di una query

```
Utente digita: "errori nel cc.log del nodo 5 di prod"
        │
        ▼
  param-extract.sh          ← estrae: ENV=prod, NODE=5, NAMED_LOG=cc
        │
        ▼
  query-to-features.sh      ← converte la query in vettore numerico [0,1,2,...]
        │
        ▼
  nnet-predict (gawk)        ← rete neurale → vettore di probabilità per 15 tool
        │
        ▼
  dispatch.sh               ← seleziona il tool con prob > soglia (0.25)
        │
        ▼
  grep_named_log.awk (gawk) ← analizza il log, produce output colorato
        │
        ▼
  Output a terminale
```

---

## Struttura delle directory

```
neural-log-analyzer/
├── chatbot.sh              ← entry point — legge query, coordina tutto
├── train.sh                ← addestra il modello su un profilo
├── build-dataset.sh        ← trasforma queries_labeled.txt → queries.txt
│
├── lib/
│   ├── query-to-features.sh  ← testo → vettore numerico
│   ├── param-extract.sh      ← estrae ENV, NODE, NAMED_LOG, TIME_WINDOW, ecc.
│   ├── dispatch.sh           ← routing: chiama il tool AWK giusto
│   │
│   ├── utils-time.awk        ← filtro temporale (time_from / time_to)
│   ├── utils-colors.awk      ← costanti ANSI condivise
│   ├── utils-jboss.awk       ← parse_server_log(), is_stack_frame()
│   ├── utils-dedup.awk       ← dedup_add(), dedup_sort(), dedup_print()
│   │
│   └── tools/
│       ├── filter_errors.awk
│       ├── filter_app_errors.awk
│       ├── grep_named_log.awk
│       ├── search_all_logs.awk
│       └── ... (11 tool totali)
│
├── profiles/
│   └── liquido/
│       ├── domain.conf       ← topologia rete, lista tool, soglia
│       ├── system.conf       ← path log, ambienti, nodi
│       ├── unigrams.txt      ← vocabolario (97 pattern)
│       ├── bigrams.txt       ← co-occorrenze (6 bigram)
│       ├── vocab.sh          ← carica il vocabolario in variabili bash
│       └── dataset/
│           ├── queries_labeled.txt   ← sorgente esempi (mano)
│           └── queries.txt          ← dataset compilato (generato)
│
└── models/
    └── intent_classifier/
        ├── layer1.txt        ← pesi layer nascosto (97×48)
        ├── layer2.txt        ← pesi layer output (48×15)
        └── model.conf        ← metadati (topologia, activation, optimizer)
```

---

## Separazione delle responsabilità

| File | Responsabilità | Modifica richiede retrain? |
|------|---------------|---------------------------|
| `unigrams.txt` / `bigrams.txt` | Vocabolario NLP | Sì |
| `domain.conf` | Tool disponibili, topologia | Sì |
| `system.conf` | Path log, ambienti | No |
| `dispatch.sh` | Routing tool → gawk | No |
| `*.awk` (tools) | Logica analisi log | No |
| `layer*.txt` | Pesi rete neurale | (sono l'output del retrain) |

---

## Multi-profilo

Lo stesso engine supporta installazioni diverse (Liquido, USNext, futuri clienti) cambiando solo la directory `--profile`. Ogni profilo ha vocabolario, esempi e modello indipendenti.
