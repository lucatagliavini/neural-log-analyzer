#!/usr/bin/env python3
"""
test-normalize-parity.py — verifica che lib/build_dataset.normalize_query()
produca lo stesso NORM_QUERY di lib/normalize-query.sh su ogni query del
dataset labeled. Le due implementazioni sono duplicate per performance
(build_dataset.py evita 2 fork per riga durante il rebuild del dataset,
~100x piu' veloce) — questo test e' l'unica cosa che impedisce alle due
di divergere di nuovo silenziosamente.

Uso: .venv/bin/python3 tests/test-normalize-parity.py --profile profiles/liquido
"""
import argparse
import os
import re
import subprocess
import sys

LIB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'lib')
sys.path.insert(0, LIB_DIR)
import build_dataset as bd


def load_queries(labeled_path):
    path = labeled_path
    queries = []
    with open(path) as f:
        for raw in f:
            stripped = raw.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if '\t' not in raw:
                continue
            labels, query = raw.split('\t', 1)
            query = query.strip()
            labels = labels.strip()
            if not query or query.startswith('#') or labels.startswith('#'):
                continue
            queries.append(query)
    return queries


def bash_norm_query(query, profile_dir, env):
    """Invoca normalize-query.sh e restituisce NORM_QUERY decodificato.
    Usa bash stesso per fare l'unescape di printf %q (piu' robusto di un
    unescape manuale con regex, che rischierebbe edge case su backslash/quote)."""
    script = os.path.join(LIB_DIR, 'normalize-query.sh')
    cmd = ['bash', '-c', 'source <("$0" "$1"); printf "%s" "$NORM_QUERY"', script, query]
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"normalize-query.sh fallito su {query!r}: {result.stderr}")
    return result.stdout


def bash_features(query, norm_query, profile_dir, env):
    """Invoca query-to-features.sh con NORM_QUERY esportata (come fa il pipeline
    reale chatbot.sh -> normalize-query.sh -> query-to-features.sh) e restituisce
    il vettore di feature come lista di stringhe."""
    script = os.path.join(LIB_DIR, 'query-to-features.sh')
    run_env = env.copy()
    run_env['NORM_QUERY'] = norm_query
    result = subprocess.run(['bash', script, query], env=run_env, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"query-to-features.sh fallito su {query!r}: {result.stderr}")
    return result.stdout.strip().split()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--profile', required=True)
    args = ap.parse_args()

    profile_dir = os.path.realpath(args.profile)
    cfg = bd.load_profile(profile_dir)

    # Riusa la risoluzione di build_dataset (NLP-1): niente terza implementazione
    # della precedenza profilo→framework — sarebbe il difetto che il test stesso
    # esiste per intercettare.
    paths = bd.resolve_nlp_paths(profile_dir)
    queries = load_queries(paths['labeled_file'])

    unigrams = bd.load_unigrams(paths['unigrams_file'])
    bigrams  = bd.load_bigrams(paths['bigrams_file'])

    # I subprocessi bash (normalize-query.sh, query-to-features.sh) sourciano
    # domain.conf → tools.conf, quindi hanno bisogno dei path risolti nel loro env:
    # un figlio eredita solo ciò che è esportato.
    env = os.environ.copy()
    env['PROFILE_DIR']     = profile_dir
    env['UNIGRAMS_FILE']   = paths['unigrams_file']
    env['BIGRAMS_FILE']    = paths['bigrams_file']
    env['TOOLS_CONF_FILE'] = paths['tools_conf_file']

    norm_mismatches = []
    feat_mismatches = []
    for query in queries:
        py_norm = bd.normalize_query(query, cfg)
        bash_norm = bash_norm_query(query, profile_dir, env)
        if py_norm != bash_norm:
            norm_mismatches.append((query, py_norm, bash_norm))
            continue  # confronto feature non ha senso su NORM_QUERY già divergente

        py_feat = [str(v) for v in bd.vectorize(py_norm, unigrams, bigrams)]
        bash_feat = bash_features(query, bash_norm, profile_dir, env)
        if py_feat != bash_feat:
            feat_mismatches.append((query, py_norm, py_feat, bash_feat))

    total = len(queries)
    print(f"[INFO] Query confrontate: {total}")

    if norm_mismatches:
        print(f"\n[FAIL] {len(norm_mismatches)}/{total} divergenze bash/Python su NORM_QUERY:\n")
        for query, py_norm, bash_norm in norm_mismatches:
            print(f"  Query : {query!r}")
            print(f"    bash  : {bash_norm!r}")
            print(f"    python: {py_norm!r}")
            print()

    if feat_mismatches:
        print(f"\n[FAIL] {len(feat_mismatches)}/{total} divergenze bash/Python sul vettore feature:\n")
        for query, norm, py_feat, bash_feat in feat_mismatches:
            diff_idx = [i for i, (a, b) in enumerate(zip(py_feat, bash_feat)) if a != b]
            print(f"  Query      : {query!r}")
            print(f"  NORM_QUERY : {norm!r}")
            print(f"  Indici diversi: {diff_idx}")
            print(f"    python: {py_feat}")
            print(f"    bash  : {bash_feat}")
            print()

    if norm_mismatches or feat_mismatches:
        sys.exit(1)

    print(f"[OK] {total}/{total} identici — NORM_QUERY e vettori feature ({len(unigrams) + len(bigrams)} feature).")
    sys.exit(0)


if __name__ == '__main__':
    main()
