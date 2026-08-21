#!/usr/bin/env python3
"""
dump_norm.py — emette il dataset labeled NORMALIZZATO, una riga per esempio.

Uso:   python3 lib/dump_norm.py --profile profiles/liquido
Output: <labels><TAB><norm_query>   su stdout, niente intestazioni

Serve a vocab-gap.sh, che fino al 2026-08-21 tokenizzava il labeled GREZZO
(`vocab-gap.sh:75`, `query = tolower($2)`) mentre le feature si calcolano sul
NORMALIZZATO. Conseguenza: il report dichiarava "non coperti" proprio i token che
nlp/unigrams.txt VIETA per contratto (LOGF-3, zero nomi concreti) e che la
normalizzazione assorbe — `database`/`messaging`/`jgroups` → <LOGFILE>,
`nodo` → <NODE>, `produzione` → <ENV>. Vedi GAPREP-1 in BACKLOG.md.

Perché Python e non bash: `lib/normalize-query.sh` in un ciclo shell costa **54s
misurati** su 1171 query, e gap-report.sh gira dentro train.sh a OGNI
addestramento. Qui la normalizzazione è in-process, nessun fork per riga.

Perché un file separato e non un flag di build_dataset.py: il `main()` di quello
SCRIVE il dataset, e una modalità che non lo scrive gli darebbe una seconda
responsabilità. Questo script non ha politica: solo la trasformazione. Filtro,
conteggio classi, stopword e ordinamento restano in bash/awk, dove vive il resto
della logica del progetto.

Solo stdlib (come build_dataset.py): gira col python3 di sistema, il .venv non
serve — contiene l'albero di dipendenze di PyTorch, rimosso il 2026-08-18.
"""
import os
import sys
import argparse

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import build_dataset as bd  # noqa: E402  (dopo sys.path, necessariamente)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--profile', required=True)
    args = ap.parse_args()

    profile_dir = os.path.realpath(args.profile)
    cfg   = bd.load_profile(profile_dir)
    paths = bd.resolve_nlp_paths(profile_dir)

    # Le condizioni di skip replicano ESATTAMENTE build_dataset.py:454-462: se
    # divergessero, vocab-gap.sh conterebbe token su un insieme di esempi diverso
    # da quello su cui la rete è addestrata — cioè lo stesso errore di stadio che
    # questo script esiste per eliminare, solo spostato di un passo.
    with open(paths['labeled_file']) as fin:
        for raw in fin:
            stripped = raw.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if '\t' not in raw:
                continue
            labels, query = raw.split('\t', 1)
            labels = labels.strip()
            query  = query.strip()
            if not query or query.startswith('#') or labels.startswith('#'):
                continue

            # Il TAB come separatore è sicuro: verificato su 1171 query, zero
            # normalizzazioni contengono TAB o newline.
            sys.stdout.write(f'{labels}\t{bd.normalize_query(query, cfg)}\n')


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        # Un consumatore che chiude la pipe presto (`| head`) è normale, non un
        # errore: senza questo l'utente vede un traceback su stderr e crede di
        # aver rotto qualcosa. Si chiude stderr prima di uscire perché
        # l'interprete altrimenti riprova a fare flush di stdout in teardown e
        # ristampa l'eccezione.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stderr.fileno())
        sys.exit(0)
