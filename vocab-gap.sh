#!/bin/bash
#
# vocab-gap.sh — individua i token del dataset non coperti dal vocabolario, e li
# ordina per FORZA DEL CANDIDATO. Non modifica nulla.
#
# Uso: ./vocab-gap.sh --profile profiles/liquido [--min-count N] [--top N] [--porcelain]
#
# --min-count N  soglia minima di esempi per segnalare un token (default: 3)
# --top N        massimo candidati mostrati in totale (default: 25) — 0 = tutti
# --porcelain    TSV senza colori né intestazioni: token, classi, esempi, classe
#                prevalente. Interfaccia macchina, usata da gap-report.sh.
#                IGNORA --top: emette sempre la lista completa (il troncamento è
#                presentazione, e spetta al consumatore).
#
# ─── GAPREP-1 (2026-08-21): perché questo file è stato riscritto ──────────────
#
# Il report c'era, girava a ogni `train.sh`, ed era **inutilizzabile** — quindi non
# veniva letto. È già costato un difetto reale: FLEX-1b ha scoperto che
# `richieste fallite`, *letteralmente un esempio di training*, non attivava alcun
# tool perché non esisteva feature per `fallit*`. Questo report lo segnalava
# (`fallimenti — 3 esempi`) da settimane. Il difetto non era di chi non guardava:
# era del rapporto segnale/rumore, e aveva due cause di MISURA.
#
# 1. STADIO SBAGLIATO DELLA PIPELINE. Si tokenizzava il labeled GREZZO
#    (`query = tolower($2)`), mentre le feature si calcolano sul NORMALIZZATO.
#    Il report dichiarava quindi "non coperti" proprio i token che unigrams.txt
#    VIETA per contratto (LOGF-3, zero nomi concreti) e che la normalizzazione
#    assorbe: `database`/`messaging`/`jgroups` → <LOGFILE>, `nodo` → <NODE>,
#    `produzione` → <ENV>. Consigliava di aggiungere al vocabolario esattamente
#    ciò che non può starci. Ora la sorgente è lib/dump_norm.py.
#
# 2. NESSUNA NOZIONE DI POTERE DISCRIMINANTE, che è invece il criterio VERO del
#    vocabolario: i commenti di unigrams.txt dicono "solo count_status (1 classe)
#    → peso 2", "max 4 classi → peso 1", "stop word (9 classi)". Erano annotazioni
#    scritte a mano, nessuno le calcolava. Ora il numero di classi è una colonna,
#    ed è la prima chiave di ordinamento.
#
# Terza causa, non di misura ma di presentazione: il report elencava lo stesso
# token UNA VOLTA PER CLASSE, quindi un token diffuso compariva molte volte —
# 113 righe in 16 blocchi alle impostazioni di default. Ora è una lista unica.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_DIR=""
MIN_COUNT=3
TOP_N=25
PORCELAIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)   PROFILE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --min-count) MIN_COUNT="$2"; shift 2 ;;
        --top)       TOP_N="$2"; shift 2 ;;
        --porcelain) PORCELAIN=1; shift ;;
        *) echo "[ERROR] opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROFILE_DIR" ]]; then
    echo "[ERROR] --profile obbligatorio. Es: ./vocab-gap.sh --profile profiles/liquido" >&2
    exit 1
fi

# ─── Codici di uscita ─────────────────────────────────────────────────────────
#   0  misura riuscita (una lista vuota è un esito legittimo, non un errore)
#   1  errore d'USO (opzione sconosciuta, --profile mancante) — bug del chiamante
#   2  NON MISURABILE (python3 assente, helper fallito, artefatti irrisolvibili)
#
# Il 2 esiste perché gap-report.sh deve poter distinguere "misurato, zero gap" da
# "non ho potuto misurare". Prima li confondeva e stampava "✓ nessun gap
# rilevante" per una misura mai avvenuta: una risposta ben formata alla domanda
# sbagliata, cioè il difetto che questo progetto combatte (LOGSEL-1 D2).

source "$SCRIPT_DIR/lib/nlp-paths.sh"
nlp_resolve_paths || exit 2

# python3 è RICHIESTO, senza fallback bash. La normalizzazione via
# lib/normalize-query.sh in un ciclo shell costa **54s misurati** su 1171 query, e
# questo script gira dentro train.sh a ogni addestramento: un fallback lento
# sarebbe un rallentamento che nessuno riesce a spiegarsi. Serve il python3 di
# SISTEMA (build_dataset.py importa solo stdlib): il .venv non c'entra, contiene
# l'albero di dipendenze di PyTorch, rimosso il 2026-08-18.
if ! command -v python3 >/dev/null 2>&1; then
    echo "[UNAVAILABLE] vocab-gap: python3 non trovato — il dataset non può essere" >&2
    echo "              normalizzato allo stesso stadio delle feature, quindi la" >&2
    echo "              misura NON è stata eseguita (nessun gap dichiarato)." >&2
    exit 2
fi

DUMP_PY="$SCRIPT_DIR/lib/dump_norm.py"
if [[ ! -f "$DUMP_PY" ]]; then
    echo "[UNAVAILABLE] vocab-gap: $DUMP_PY mancante — misura non eseguita." >&2
    exit 2
fi

# ─── Regex combinata di tutto il vocabolario ──────────────────────────────────
# Gli spazi vengono RIMOSSI dai pattern, esattamente come fanno
# query-to-features.sh (`${pattern// /}`) e build_dataset.py (`.replace(' ','')`):
# la copertura va valutata sul pattern EFFETTIVO, non su quello scritto. È la
# degradazione che nel 2026-08-21 ha reso `ora |ore |ora$` capace di matchare
# l'interno di «errore» (VOCFIX-1) — qui la si replica di proposito.
COMBINED_RE=$(
    grep -hv '^[[:space:]]*#\|^[[:space:]]*$' \
        "$UNIGRAMS_FILE" \
        "$BIGRAMS_FILE" \
    | awk -F'::' '{
        gsub(/[[:space:]]/,"",$1); printf "%s|", $1
        if (NF >= 2) {
            pat2 = $2
            gsub(/[[:space:]]/,"",pat2)
            if (pat2 !~ /^[0-9]+$/) printf "%s|", pat2
        }
    }' | sed 's/|$//'
)
COMBINED_RE="${COMBINED_RE:-NOMATCH}"

TOKEN_TABLE=$(mktemp)
CAND_FILE=$(mktemp)
trap 'rm -f "$TOKEN_TABLE" "$CAND_FILE"' EXIT

# ─── Fase 1: dump normalizzato → token, esempi, classi, classe prevalente ─────
if ! python3 "$DUMP_PY" --profile "$PROFILE_DIR" > "$TOKEN_TABLE.raw" 2>"$TOKEN_TABLE.err"; then
    echo "[UNAVAILABLE] vocab-gap: dump_norm.py fallito — misura non eseguita:" >&2
    sed 's/^/              /' "$TOKEN_TABLE.err" >&2
    rm -f "$TOKEN_TABLE.raw" "$TOKEN_TABLE.err"
    exit 2
fi
rm -f "$TOKEN_TABLE.err"

awk -F'\t' '
{
    nl = split($1, L, /,/)
    q  = tolower($2)

    # `<` e `>` NON sono separatori: i placeholder devono restare token ATOMICI,
    # perché `<logfile>` (unigrams.txt:234) e `<ip>` (:148) sono pattern veri del
    # vocabolario. Spezzandoli si otterrebbe il token `logfile`, che NON combacia
    # col pattern `<logfile>` e comparirebbe come falso gap — con 155 occorrenze,
    # in cima alla lista.
    #
    # Le CIFRE restano separatori, come nella versione originale: un numero in una
    # query è un VALORE (soglia in ms, porta, numero di sinistro, anno) consumato a
    # valle da param-extract.sh, non un candidato di vocabolario. Ammetterle —
    # provato il 2026-08-21 — riempie la cima della lista di `1000`, `2026`,
    # `8101`, `0473954`. I codici di stato fanno eccezione, ma sono un insieme
    # chiuso e già coperto (`\b500\b`, `\b404\b`, `5xx`…).
    # NB: niente apostrofi in questo commento — il programma awk è quotato con
    # apici singoli, e un apostrofo lo chiuderebbe a metà.
    n = split(q, W, /[^a-zàèéìòù<>]+/)

    delete seen
    for (i = 1; i <= n; i++) {
        w = W[i]
        if (length(w) < 4) continue
        # Dedup PER RIGA: "errori errori" in una query è UN esempio, non due.
        # Senza, una query ripetitiva peserebbe come più esempi distinti.
        if (w in seen) continue
        seen[w] = 1
        ex[w]++
        for (j = 1; j <= nl; j++) {
            lab = L[j]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lab)
            if (lab == "") continue
            # Conteggio classi su TUTTE le etichette, non solo la primaria: il
            # dataset è multi-label, e usare labels[1] (come si faceva prima)
            # SOTTOSTIMA la diffusione di un token che vive in righe multi-label —
            # cioè falsa la metrica proprio dove serve, sui token ambigui.
            key = w SUBSEP lab
            if (!(key in cl)) ncl[w]++
            cl[key]++
            if (cl[key] > bestn[w]) { bestn[w] = cl[key]; bestlab[w] = lab }
        }
    }
}
END {
    for (w in ex) printf "%s\t%d\t%d\t%s\n", w, ncl[w], ex[w], bestlab[w]
}
' "$TOKEN_TABLE.raw" > "$TOKEN_TABLE"
rm -f "$TOKEN_TABLE.raw"

TOTAL_TOK=$(wc -l < "$TOKEN_TABLE")

# ─── Fase 2: scarta i token già coperti dal vocabolario ───────────────────────
# UN SOLO `grep -vE` su tutta la lista invece di un `grep -qE` per token in un
# ciclo bash (~400 fork). Semantica identica, perché grep valuta riga per riga.
#
# Deve restare `grep` e NON diventare un `match()` awk: i pattern del vocabolario
# usano `\b`, che grep -E interpreta come confine di parola e awk come BACKSPACE
# (il vincolo è già documentato in bigrams.txt). Spostarlo in awk romperebbe
# silenziosamente la copertura di `access\b`, `tempi\b`, `secondi\b`, `sopra\b`…
cut -f1 "$TOKEN_TABLE" | grep -vE "$COMBINED_RE" > "$CAND_FILE" || true
UNCOVERED=$(wc -l < "$CAND_FILE")

# ─── Fase 2b: scarta i placeholder strutturali ────────────────────────────────
# <app>, <env>, <node> non sono nel vocabolario **per scelta architetturale**: non
# sono segnale di intent, sono coordinate estratte a valle (param-extract.sh,
# resolve-logs.sh). Senza questo filtro il report consiglierebbe «aggiungi <node>
# al vocabolario», che è il tipo esatto di consiglio insensato che GAPREP-1
# elimina — solo introdotto dal suo stesso rimedio.
grep -vxE '<[a-z]+>' "$CAND_FILE" > "$CAND_FILE.np" || true
mv "$CAND_FILE.np" "$CAND_FILE"

# ─── Fase 2c: scarta le parole funzionali ─────────────────────────────────────
STOPWORDS_ACTIVE=0
if [[ -n "${STOPWORDS_FILE:-}" && -f "$STOPWORDS_FILE" ]]; then
    SW=$(mktemp)
    grep -hv '^[[:space:]]*#\|^[[:space:]]*$' "$STOPWORDS_FILE" | tr -d ' \t' | grep . > "$SW" || true
    if [[ -s "$SW" ]]; then
        STOPWORDS_ACTIVE=$(wc -l < "$SW")
        grep -vxF -f "$SW" "$CAND_FILE" > "$CAND_FILE.nsw" || true
        mv "$CAND_FILE.nsw" "$CAND_FILE"
    fi
    rm -f "$SW"
fi
AFTER_SW=$(wc -l < "$CAND_FILE")

# ─── Fase 3: tabella finale, ordinata per forza del candidato ─────────────────
# Ordinamento a DUE CHIAVI, non un punteggio composito: poche classi prima
# (potere discriminante), a parità di classi più esempi prima (evidenza). Un
# punteggio tipo esempi/classi darebbe lo stesso ordine in molti casi ma
# nessuno saprebbe più leggerlo né motivarlo.
RANKED=$(
    awk -F'\t' -v min="$MIN_COUNT" '
        NR == FNR { cand[$1] = 1; next }
        ($1 in cand) && $3 + 0 >= min { print }
    ' "$CAND_FILE" "$TOKEN_TABLE" \
    | LC_ALL=C sort -t$'\t' -k2,2n -k3,3rn
)

N_CAND=0
[[ -n "$RANKED" ]] && N_CAND=$(printf '%s\n' "$RANKED" | grep -c . || true)

SHOWN="$RANKED"
if [[ "$TOP_N" -gt 0 && "$N_CAND" -gt "$TOP_N" ]]; then
    SHOWN=$(printf '%s\n' "$RANKED" | head -n "$TOP_N")
fi

if [[ "$PORCELAIN" -eq 1 ]]; then
    # Il porcelain IGNORA --top e emette la lista COMPLETA: è un'interfaccia
    # macchina, e il troncamento è una scelta di presentazione che spetta al
    # consumatore. Emettendo la lista tagliata, gap-report.sh contava le righe
    # ricevute e annunciava «6 candidati» invece di 39 — cioè il numero che
    # l'utente legge a ogni training sarebbe stato sbagliato per difetto, che è
    # il modo peggiore di sbagliarlo: fa sembrare il problema più piccolo.
    [[ -n "$RANKED" ]] && printf '%s\n' "$RANKED"
    exit 0
fi

BOLD="\033[1m"; CYAN="\033[36m"; YELLOW="\033[33m"; GREEN="\033[32m"
DIM="\033[2m"; RESET="\033[0m"

printf "\n${BOLD}Vocab gap report${RESET} — profilo: $(basename "$PROFILE_DIR")\n"
printf "${DIM}Stadio: testo NORMALIZZATO (come le feature). Token unici: %d | non coperti: %d" \
    "$TOTAL_TOK" "$UNCOVERED"
if [[ "$STOPWORDS_ACTIVE" -gt 0 ]]; then
    printf " | dopo stopword: %d${RESET}\n" "$AFTER_SW"
else
    printf "${RESET}\n"
    printf "${YELLOW}Filtro parole funzionali DISATTIVATO${RESET} ${DIM}(report-stopwords.txt assente o vuoto)${RESET}\n"
fi
printf "${DIM}Soglia: >= %d esempi. Ordine: poche classi prima, poi più esempi.${RESET}\n\n" "$MIN_COUNT"

if [[ "$N_CAND" -eq 0 ]]; then
    printf "  ${GREEN}✓${RESET} Nessun candidato: ogni token frequente è coperto dal vocabolario.\n\n"
    exit 0
fi

printf "  ${BOLD}%-22s %6s %7s  %s${RESET}\n" "TOKEN" "CLASSI" "ESEMPI" "CLASSE PREVALENTE"
printf '%s\n' "$SHOWN" | awk -F'\t' -v y="$YELLOW" -v c="$CYAN" -v d="$DIM" -v r="$RESET" '
    { printf "  %s%-22s%s %s%6d%s %s%7d%s  %s%s%s\n", y,$1,r, d,$2,r, d,$3,r, c,$4,r }'

N_SHOWN=$(printf '%s\n' "$SHOWN" | grep -c . || true)
printf "\n${DIM}Mostrati %d di %d candidati" "$N_SHOWN" "$N_CAND"
[[ "$N_SHOWN" -lt "$N_CAND" ]] && printf ' — --top 0 per vederli tutti'
printf "${RESET}\n"
printf "${DIM}Poche classi = alto potere discriminante: è il criterio con cui unigrams.txt${RESET}\n"
printf "${DIM}assegna i pesi (1 classe → peso 2, fino a 4 classi → peso 1, oltre → stop word).${RESET}\n\n"
