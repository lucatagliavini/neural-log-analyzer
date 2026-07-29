# Neural Log Analyzer — Panoramica

## Cos'è

Un **chatbot a riga di comando** che risponde a domande in linguaggio naturale sui log di un'applicazione enterprise (JBoss / Guidewire).

```
$ ./chatbot.sh --profile profiles/liquido --env prod --node 4

> errori nel server log di stamattina
→ [esegue filter_errors su server.log]

> richieste lente delle ultime 2 ore
→ [esegue slow_requests su access.log, finestra 06:00–08:00]

> cerca NullPointerException in tutti i log del nodo
→ [esegue ricerca parallela su 33 log Guidewire + JBoss]
```

---

## Cosa non è

- Non è un LLM. Non usa GPT, Ollama o servizi cloud.
- Non ha accesso a internet.
- Non "capisce" il testo — **classifica l'intent** con una rete neurale locale, poi esegue lo strumento corretto.

---

## Stack tecnologico

| Livello | Tecnologia | Perché |
|---------|-----------|--------|
| Shell | `bash` | Orchestrazione, routing, parametri |
| Analisi log | `gawk` | Parsing, aggregazione, output |
| Classificazione | Rete neurale in `gawk` | Nessuna dipendenza esterna |
| Modello | File di testo `.txt` | Leggibili, versionabili, trasportabili |

**Dipendenze runtime:** `gawk`, `bash`, `gunzip`. Nient'altro.

---

## I numeri del sistema (profilo Liquido)

| Metrica | Valore |
|---------|--------|
| Tool disponibili | 15 |
| Feature NLP del vettore | 97 |
| Topologia rete | 97 → 48 → 15 |
| Esempi di training | ~950 |
| Accuracy sul test set | ~94% |
| File di peso del modello | 2 file `.txt` |
