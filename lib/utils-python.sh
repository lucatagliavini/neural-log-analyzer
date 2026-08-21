#!/bin/bash
#
# utils-python.sh — punto UNICO di risoluzione dell'interprete Python.
#
# ─── VENVGATE-1 (2026-08-21): perché questo file esiste ──────────────────────
#
# Tre script cercavano Python in tre modi diversi, e due erano sbagliati:
#
#   build-dataset.sh          [[ -x .venv/bin/python3 ]]   → altrimenti ramo bash
#   tests/test-normalize-parity.sh  idem, ma `exit 1`      → FAIL in produzione
#   vocab-gap.sh              command -v python3           → corretto
#
# Il gate su `.venv` è **vestigiale**: il venv esisteva per **PyTorch**, quando il
# training passava da `lib/train.py`. Quel file è stato rimosso il 2026-08-18 e il
# motore neurale è `neural-c` (C, nessuna dipendenza Python), ma il gate è restato.
# Verificato: in `.venv/lib/python*/site-packages` ci sono ancora `functorch`,
# `filelock`, `fsspec`, `jinja2` — l'albero di dipendenze di torch. E
# `lib/build_dataset.py` importa **solo stdlib** (`re`, `sys`, `os`, `argparse`,
# `shlex`), quindi il `python3` di sistema gli basta.
#
# Costo misurato del difetto: in produzione (`lxprworkerlana01`) esiste
# `/usr/bin/python3` e NON esiste `.venv`, quindi ogni `build-dataset.sh` prendeva
# il ramo bash — **0,2 s contro ≥110 s** (54 s misurati per la sola normalizzazione
# di 1171 query, e il ramo bash fa due subprocess per riga). Il gate proteggeva da
# una dipendenza che non esiste più, al prezzo di rinunciare all'unico backend
# veloce proprio sulla macchina che ne ha più bisogno.
#
# ─── Le versioni, e una mia affermazione da correggere ────────────────────────
#
# Avevo scritto che in produzione ci fosse **3.12.3**, come in locale. Non l'avevo
# verificato: avevo letto solo il PATH dell'interprete. La versione reale è
# **3.9.25** — due minor release di distanza, ed è precisamente la differenza che
# rende non ovvia la domanda «i due interpreti producono lo stesso dataset?».
#
# Verificato dal vivo DOPO il deploy, ed è più forte di quel che avevo affermato:
# `build-dataset.sh` su 3.9.25 in produzione rigenera `queries.txt` con md5
# **identico** a quello prodotto da 3.12.3 in locale, e `gap-report.sh` dà gli
# stessi 74 candidati. Quindi l'output è stabile fra 3.9 e 3.12 — per misura, non
# perché l'avessi presupposto.
#
# Conseguenza pratica per chi tocca questi script: il codice Python del progetto
# deve restare compatibile con **3.9**, non solo con la versione locale. Niente
# `match`, niente unione di tipi con `|` negli annotamenti, niente novità 3.10+.
#
# La terza incoerenza l'ho introdotta io lo stesso giorno con GAPREP-1, aggiungendo
# un quarto consumatore di Python con un quarto criterio. Da qui questo file: il
# criterio è uno, e i chiamanti sono migrati tutti (principio 8 — centralizzare
# senza migrare lascia il difetto dove era, solo più difficile da vedere).

# resolve_python
# Emette su stdout il path dell'interprete da usare; ritorna 1 e non emette nulla
# se non c'è alcun Python utilizzabile.
#
# Precedenza: `.venv` PRIMA del sistema. Non è un residuo del gate ma una scelta:
# il venv è un override per-installazione (chi lo crea di proposito, per pinnare
# una versione o provare una patch, vuole che venga usato), esattamente come
# `system.local.conf` vince su `system.conf`. La differenza con prima è che
# la sua ASSENZA non è più un errore.
# Override esplicito: NLA_PYTHON=/path/to/python3 forza quell'interprete.
#
# Serve a due cose reali, non è un aggancio per i test. La prima: pinnare un
# interprete su una macchina dove `python3` è una versione che non si vuole usare,
# senza dover creare un venv (stesso spirito di `system.local.conf`, che sovrascrive
# per installazione). La seconda: poter dire «qui NON c'è Python» in modo
# deterministico — svuotare il PATH non basta più, perché `.venv` viene trovato per
# path assoluto, e infatti è così che il ramo di degradazione va verificato.
#
# Se è impostato e non è eseguibile, resolve_python FALLISCE invece di ricadere sul
# venv o sul sistema: chi ha pinnato un interprete ha espresso una scelta, e
# scavalcarla in silenzio nasconderebbe un errore di configurazione (ARCH-6).
resolve_python() {
    local _self _root _sys
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _root="$(cd "$_self/.." && pwd)"

    if [[ -n "${NLA_PYTHON:-}" ]]; then
        if [[ -x "$NLA_PYTHON" ]]; then
            echo "$NLA_PYTHON"
            return 0
        fi
        return 1
    fi

    if [[ -x "$_root/.venv/bin/python3" ]]; then
        echo "$_root/.venv/bin/python3"
        return 0
    fi
    if _sys="$(command -v python3 2>/dev/null)" && [[ -n "$_sys" ]]; then
        echo "$_sys"
        return 0
    fi
    return 1
}

# python_origin PATH → "venv" | "sistema"
# Serve solo ai messaggi [INFO]: sapere QUALE interprete è stato scelto è la prima
# cosa che si vuole quando i tempi non tornano.
python_origin() {
    if [[ -n "${NLA_PYTHON:-}" && "$1" == "$NLA_PYTHON" ]]; then
        echo "NLA_PYTHON"
    elif [[ "$1" == */.venv/bin/python3 ]]; then
        echo "venv"
    else
        echo "sistema"
    fi
}
