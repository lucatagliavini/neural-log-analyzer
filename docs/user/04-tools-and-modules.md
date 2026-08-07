# Tool disponibili e modularizzazione AWK

## I 15 tool

### Log HTTP (access.log)

| Tool | Query tipica |
|------|-------------|
| `count_status` | "quanti errori 500 ci sono stati stamattina" |
| `distribute_status` | "distribuzione errori sul nodo 10" |
| `slow_requests` | "richieste lente delle ultime 2 ore" |
| `traffic_volume` | "volume traffico del nodo 7 in mattinata" |
| `filter_ip` | "chi ha fatto più richieste sul nodo 2" |
| `tail_log` | "ultime 50 righe del log" |

### Server log JBoss

| Tool | Query tipica |
|------|-------------|
| `filter_errors` | "errori nel server log del nodo 3" |
| `filter_app_errors` | "errori applicativi nascosti sul nodo 8" |
| `service_times` | "tempi dei servizi di stamattina" |

### GC / JVM

| Tool | Query tipica |
|------|-------------|
| `gc_stats` | "statistiche GC del nodo 5" |
| `correlate_gc_slow` | "il GC sta causando lentezza sul nodo 6?" |

### Log applicativi custom

| Tool | Query tipica |
|------|-------------|
| `tail_named_log` | "ultime 100 righe del api.log sul nodo 9" |
| `grep_named_log` | "errori nel cc.log del nodo 12" |

### Cross-log e assistenza

| Tool | Query tipica |
|------|-------------|
| `search_all_logs` | "cerca NullPointerException nei log del nodo 5" |
| `show_help` | "cosa sai fare?" / "aiuto" |

---

## Modularizzazione AWK — il pattern utility

Ogni tool `.awk` non è autosufficiente: carica un insieme di **utility condivise** tramite `gawk -f`. Tutti i file `-f` condividono un unico namespace globale.

```bash
gawk \
  -f utils-time.awk    \   # filtro temporale
  -f utils-colors.awk  \   # costanti ANSI
  -f utils-jboss.awk   \   # parsing formato log
  -f utils-dedup.awk   \   # aggregazione deduplicata
  -f tools/filter_errors.awk \
  server.log
```

### Le quattro utility

**`utils-time.awk`** — filtro temporale
```
in_range(epoch)  → 1 se il timestamp cade nella finestra time_from/time_to
parse_server(date_s, time_s)  → epoch unix
```

**`utils-colors.awk`** — costanti ANSI condivise
```
RED, YELLOW, GREEN, CYAN, BOLD, DIM, RESET
```
Prima di questo file ogni tool ridefiniva gli stessi 7 colori — 14 × 2 righe duplicate eliminate.

**`utils-jboss.awk`** — parsing del formato log JBoss/WildFly
```
parse_server_log()  → popola _level, _msg, _ts_date, _ts_time, _logger
                       restituisce 1 se la riga è un log JBoss valido
is_stack_frame(msg) → 1 se la riga è un frame di stack trace (at ..., Caused by:)
```
Il formato JBoss ha il campo `(thread)` con spazi interni — impossibile usare field splitting posizionale. La funzione usa `match()` con regex.

Per aggiungere un formato alternativo (WebSphere, Tomcat): creare `utils-websphere.awk` con le stesse funzioni, e impostare `SERVER_LOG_FORMAT=websphere` in `system.conf`.

**`utils-dedup.awk`** — aggregazione e deduplicazione
```
dedup_add(chiave, livello, messaggio, timestamp, extra)
dedup_sort()     → insertion sort per conteggio crescente
dedup_print(N)   → stampa le prime N voci con colori e contatore ×N
```
Usato da `filter_errors`, `grep_named_log`, `filter_app_errors`. Prima i tre tool avevano ognuno la propria implementazione di sort + print.

---

## Formato log JBoss — nota tecnica

```
2026-07-29 09:15:32,441 ERROR [com.example.MyClass] (webcontainer-worker task-7049) Messaggio
                                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                      thread con spazi — non splittabile
```

Lo stack trace segue su righe separate, senza timestamp:
```
	at com.example.MyClass.method(MyClass.java:42)
	at org.jboss.bootstrap.Bootstrap.run(Bootstrap.java:195)
	Caused by: java.lang.NullPointerException: ...
```

`filter_errors` gestisce questo con una state machine: quando incontra un `ERROR`/`WARN` entra in modalità eccezione e accumula i frame `at ...` fino alla riga successiva con timestamp.

---

## Ricerca parallela (`search_all_logs`)

Su un nodo con 31 log Guidewire (fino a 125 MB ciascuno), la ricerca usa un pool di worker:

```
Lista 33 log
    │
    ├── slot 1: grep -cE "pattern" cc.log        (125 MB)
    ├── slot 2: grep -cE "pattern" policysearch.log (59 MB)
    ├── slot 3: grep -cE "pattern" ccCanaliz.log  (53 MB)
    └── slot 4: grep -cE "pattern" pc1.log        (35 MB)
                     ↓ appena un slot si libera
              prende il prossimo file dalla coda
```

Output:
```
Ricerca: NullPointerException  (33 log, 4 worker paralleli)

  pc1nssproda-cc.9.log   ████████████   73  │  2026-07-29 08:12:01  │  34 MB
  prod1nssa-cc.log       ██████████     61  │  2026-07-29 09:15:04  │  86 MB

  Totale: 134 occorrenze in 2 log  (31 senza match)
  → Per dettaglio: "cerca NullPointerException nel cc.9.log"
```

Il numero di worker paralleli è configurabile in `system.conf` con `SEARCH_PARALLEL_JOBS` (default: 4).
