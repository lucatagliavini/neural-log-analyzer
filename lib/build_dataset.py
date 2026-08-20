#!/usr/bin/env python3
"""
build_dataset.py — versione Python di build-dataset.sh.
Genera profiles/<n>/dataset/queries.txt da queries_labeled.txt.

Carica la configurazione del profilo in-process (nessun fork) e
processa tutti gli esempi con un unico loop Python: ~100× più veloce
della versione bash che esegue 2 subprocess per ogni riga.

Uso: python3 lib/build_dataset.py --profile profiles/liquido
"""
import re
import sys
import os
import argparse
import shlex


# ─── Parsing file di configurazione bash ────────────────────────────────────

def _array_block(text, varname):
    """Stringa tra le parentesi di VAR=( ... ) con conteggio di profondità.
    Gestisce parentesi annidate nei valori (es. pattern ERE con gruppi)."""
    m = re.search(r'\b' + re.escape(varname) + r'\s*=\s*\(', text)
    if not m:
        return None
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    return text[start:i - 1]


def parse_simple_array(text, varname):
    """Estrae VAR=( item... ) come lista ordinata.
    Gestisce sia un item per riga sia array bash su riga singola
    (es. AVAILABLE_APPS=("ClaimCenter" "ContactManager")) — usa shlex.split
    per rispettare le virgolette invece di uno strip ingenuo."""
    block = _array_block(text, varname)
    if block is None:
        return []
    stripped_lines = [re.sub(r'\s*#.*$', '', line) for line in block.splitlines()]
    return shlex.split(' '.join(stripped_lines))


def parse_assoc_array(text, varname):
    """Estrae VAR=( [k]="v"... ) e/o VAR[k]="v" separati come dict."""
    result = {}
    block = _array_block(text, varname)
    if block:
        for k, v in re.findall(r'\[([^\]]+)\]\s*=\s*["\']([^"\']*)["\']', block):
            result[k] = v
    for k, v in re.findall(re.escape(varname) + r'\[([^\]]+)\]\s*=\s*["\']([^"\']*)["\']', text):
        result[k] = v
    return result


def parse_scalar(text, varname):
    """Estrae VAR='value' o VAR="value" come stringa."""
    m = re.search(r'\b' + re.escape(varname) + r"\s*=\s*'([^']*)'", text)
    if m:
        return m.group(1)
    m = re.search(r'\b' + re.escape(varname) + r'\s*=\s*"([^"]*)"', text)
    if m:
        return m.group(1)
    return ''


# ─── Conversione POSIX → Python regex ───────────────────────────────────────

def posix_to_python(pat):
    pat = pat.replace('[[:space:]]', r'\s')
    pat = pat.replace('[[:alpha:]]', r'[a-zA-Z]')
    pat = pat.replace('[[:digit:]]', r'[0-9]')
    pat = pat.replace('[[:alnum:]]', r'[a-zA-Z0-9]')
    return pat


# ─── Risoluzione degli artefatti NLP ────────────────────────────────────────
# Replica in Python di lib/nlp-paths.sh (NLP-1, 2026-08-17): vocabolario, dataset e
# modello vivono nel framework (nlp/), con override per-artefatto nel profilo.
#
# La duplicazione bash/Python è INTENZIONALE ed è lo stesso pattern già usato per
# normalize_query()/vectorize() contro normalize-query.sh/query-to-features.sh, con
# tests/test-normalize-parity.py come rete contro la divergenza. Qui la logica è
# molto più semplice (solo esistenza di file), ma il principio resta: una singola
# fonte di verità in Python, riusata da build_dataset.py e dal test di parità.

def resolve_nlp_paths(profile_dir):
    nlp_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'nlp')
    if not os.path.isdir(nlp_dir):
        raise RuntimeError(f"resolve_nlp_paths: directory del framework non trovata: {nlp_dir}")

    def resolve_file(rel):
        for base in (profile_dir, nlp_dir):
            p = os.path.join(base, rel)
            if os.path.isfile(p):
                return p
        # ARCH-6, nessun default implicito: errore con entrambi i path controllati.
        raise RuntimeError(
            f"resolve_nlp_paths: '{rel}' non trovato\n"
            f"        cercato in: {os.path.join(profile_dir, rel)}\n"
            f"                    {os.path.join(nlp_dir, rel)}")

    prof_dataset = os.path.join(profile_dir, 'dataset')
    dataset_dir = prof_dataset if os.path.isdir(prof_dataset) else os.path.join(nlp_dir, 'dataset')

    return {
        'nlp_dir':         nlp_dir,
        'unigrams_file':   resolve_file('unigrams.txt'),
        'bigrams_file':    resolve_file('bigrams.txt'),
        'tools_conf_file': resolve_file('tools.conf'),
        'dataset_dir':     dataset_dir,
        'labeled_file':    os.path.join(dataset_dir, 'queries_labeled.txt'),
        'dataset_file':    os.path.join(dataset_dir, 'queries.txt'),
    }


# ─── Caricamento configurazione profilo ─────────────────────────────────────

def load_profile(profile_dir):
    def read(fname):
        with open(os.path.join(profile_dir, fname)) as f:
            return f.read()

    system   = read('system.conf')
    entities = read('entities.conf')

    # TOOL_NAMES è passato al framework con NLP-1: domain.conf non lo contiene più.
    # Il file è risolto con la stessa precedenza profilo→framework degli altri
    # artefatti, così un profilo con tools.conf proprio viene rispettato.
    paths = resolve_nlp_paths(profile_dir)
    with open(paths['tools_conf_file']) as f:
        tools_conf = f.read()

    cfg = {}
    cfg['tool_names']      = parse_simple_array(tools_conf, 'TOOL_NAMES')
    cfg['available_apps']  = parse_simple_array(system, 'AVAILABLE_APPS')

    entity_app = parse_assoc_array(entities, 'ENTITY_APP')
    # Ordine esplicito (lunghezza decrescente, poi alfabetico) — replica
    # normalize-query.sh:33-34/2.4: "${!ARR[@]}" ha ordine hash bash non garantito,
    # con break-al-primo-match questo renderebbe la scelta indefinita a parità di
    # lunghezza (es. le chiavi di ENV_NODE_CODE hanno tutte 4 caratteri).
    cfg['entity_app_keys'] = sorted(entity_app.keys(), key=lambda k: (-len(k), k))

    env_node_code = parse_assoc_array(system, 'ENV_NODE_CODE')
    cfg['env_node_code'] = {k: env_node_code[k] for k in sorted(env_node_code, key=lambda k: (-len(k), k))}
    env_synonyms = parse_assoc_array(entities, 'ENV_SYNONYMS')
    cfg['env_synonyms'] = {k: env_synonyms[k] for k in sorted(env_synonyms, key=lambda k: (-len(k), k))}

    cfg['app_canonical']       = parse_assoc_array(entities, 'APP_CANONICAL')
    cfg['app_short_aliases']   = parse_assoc_array(entities, 'APP_SHORT_ALIASES')
    cfg['app_alias_regex']     = parse_assoc_array(entities, 'APP_ALIAS_REGEX')

    raw_node_patterns      = parse_simple_array(entities, 'NODE_PATTERNS')
    cfg['node_patterns']   = [posix_to_python(p) for p in raw_node_patterns]

    cfg['node_host_regex'] = parse_scalar(system, 'NODE_HOST_REGEX') \
                             or r'lx[a-z]{2}[a-z]+[a-z]{2}[0-9]+'

    # Basename dei log di infrastruttura: esclusi da <LOGFILE> perché hanno tool
    # dedicati (filter_errors, tail_log via LOG_TYPE). Sono l'unica cosa che serve
    # sapere per la sezione 3.5: i nomi dei log applicativi NON servono, la
    # sostituzione avviene per forma ("<token>.log").
    cfg['system_log_bases'] = [
        b.lower() for b in (
            parse_scalar(system, 'ACCESS_LOG_BASE'),
            parse_scalar(system, 'SERVER_LOG_BASE'),
            parse_scalar(system, 'GC_LOG_BASE'),
        ) if b
    ]
    # Sinonimi (es. "access" -> "undertow_access_log", SYSTEM_LOG_SYNONYMS in
    # system.conf): replica _is_system_log_base() (utils-logfiles.sh) per
    # mantenere la parità con normalize-query.sh, verificata da
    # test-normalize-parity.py.
    cfg['system_log_synonyms'] = {
        k.lower(): v.lower() for k, v in parse_assoc_array(system, 'SYSTEM_LOG_SYNONYMS').items()
    }

    return cfg


# ─── Vocabolario ────────────────────────────────────────────────────────────

def load_unigrams(path):
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('::')
            if len(parts) < 2:
                continue
            # Replica query-to-features.sh: `pattern="${pattern// /}"` — tutti gli spazi rimossi.
            # Così "ora |ore |ora$" diventa "ora|ore|ora$" e matcha anche a fine stringa.
            pattern = parts[0].strip().replace(' ', '')
            try:
                weight = int(parts[-1].strip())
            except ValueError:
                weight = 1
            entries.append((pattern, weight))
    return entries


def load_bigrams(path):
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = [p.strip() for p in line.split('::')]
            if len(parts) < 2:
                continue
            # Stesso strip-spazi di query-to-features.sh
            patA = parts[0].replace(' ', '')
            if len(parts) >= 3:
                try:
                    weight = int(parts[-1])
                    patB = parts[1].replace(' ', '')
                except ValueError:
                    weight = 1
                    patB = parts[1].replace(' ', '')
            else:
                weight = 1
                patB = parts[1].replace(' ', '')
            entries.append((patA, patB, weight))
    return entries


# ─── Normalizzazione entità (equivalente normalize-query.sh) ────────────────

def _word_sub(norm, literal, replacement):
    """Sostituisce `literal` rispettando confini di parola (non-lettera).
    Usa gruppi di ritorno consumanti come sed -E "s/(^|[^a-zA-Z])X([^a-zA-Z]|$)/\\1<Y>\\2/g"
    (normalize-query.sh:39,49,59), non un lookaround non-consumante: su occorrenze
    adiacenti ("jboss jboss") sed consuma il separatore e salta la seconda occorrenza,
    un lookaround la sostituirebbe due volte."""
    pat = r'(^|[^a-zA-Z])' + re.escape(literal) + r'([^a-zA-Z]|$)'
    return re.sub(pat, r'\1' + replacement + r'\2', norm, flags=re.IGNORECASE)


def normalize_query(query, cfg):
    norm = query.lower()

    # 0. IP → <IP>. Replica di normalize-query.sh sezione 0: riconoscimento per
    #    FORMA, come <LOGFILE> e <PATTERN>. Sta in testa perché un IPv4 è una forma
    #    lessicale autonoma e nessuna altra sezione deve poterne consumare un pezzo.
    #    I confini \b coincidono fra sed -E e re: il punto non è un word char, quindi
    #    le due implementazioni delimitano gli stessi span.
    norm = re.sub(r'\b([0-9]{1,3}\.){3}[0-9]{1,3}\b', '<IP>', norm)

    # 1. APP (longest-match)
    detected_app = ''
    for alias in cfg['entity_app_keys']:
        if re.search(r'(?<![a-z])' + re.escape(alias) + r'(?![a-z])', norm):
            detected_app = alias
            norm = _word_sub(norm, alias, '<APP>')
            break

    # 2a. ENV dai codici diretti (prod, coll, inte, ...)
    detected_env = ''
    for env_name in cfg['env_node_code']:
        if re.search(r'(?<![a-z])' + re.escape(env_name) + r'(?![a-z])', norm):
            detected_env = env_name
            norm = _word_sub(norm, env_name, '<ENV>')
            break

    # 2b. ENV dai sinonimi italiani (produzione → prod, ...)
    if not detected_env:
        for syn, canonical in cfg['env_synonyms'].items():
            if re.search(r'(?<![a-z])' + re.escape(syn) + r'(?![a-z])', norm, re.IGNORECASE):
                detected_env = canonical
                norm = _word_sub(norm, syn, '<ENV>')
                break

    # 2c. Hostname completo → ENV + NODE (lxprjbliq05 → prod, 5)
    detected_node = ''
    if not detected_env or not detected_node:
        m = re.search(cfg['node_host_regex'], norm)
        if m:
            hostname  = m.group(0)
            node_code = hostname[2:4]
            nums      = re.findall(r'[0-9]+$', hostname)
            node_num  = nums[0].lstrip('0') if nums else '0'
            if not node_num:
                node_num = '0'  # "00" -> lstrip svuota la stringa; fallback come normalize-query.sh:77-78
            if not detected_env:
                inv = {v: k for k, v in cfg['env_node_code'].items()}
                detected_env = inv.get(node_code, '')
            if not detected_node and node_num:
                detected_node = node_num
            norm = norm.replace(hostname, '<ENV> <NODE>')

    # 3. NODE dai pattern (nodo 5, worker3, ...)
    if not detected_node:
        for pat in cfg['node_patterns']:
            m = re.search(pat, norm, re.IGNORECASE)
            if m:
                nums = re.findall(r'[0-9]+', m.group(0))
                detected_node = nums[0] if nums else ''
                norm = re.sub(pat, '<NODE>', norm, flags=re.IGNORECASE)
                break

    # 3.5 LOGFILE — replica normalize-query.sh sezione 3.5.
    # Sta fra NODE e APP_SHORT_ALIASES: dopo la sezione 1 perché un nome app completo
    # vince sempre, prima della 4 perché `\bcc\b` matcha dentro "cc.log" (il "." è
    # word boundary) e produrrebbe "<APP>.log".
    logfile_done = False

    # a) Glob quotato: ha priorità, è una scelta esplicita dell'utente.
    #    Non imposta detected_app — un glob non identifica un'applicazione.
    if re.search(r'"[^"]*\*[^"]*\.log"', norm):
        norm = re.sub(r'"[^"]*\*[^"]*\.log"', '<LOGFILE>', norm)
        logfile_done = True
    elif re.search(r"'[^']*\*[^']*\.log'", norm):
        norm = re.sub(r"'[^']*\*[^']*\.log'", '<LOGFILE>', norm)
        logfile_done = True

    # a-ter) SRCH-4 — nome di log di SISTEMA quotato senza wildcard: virgolette
    #    rimosse, nome LETTERALE. Replica di normalize-query.sh sezione (a-ter):
    #    senza questo passo entrambe le stringhe quotate di
    #    `trova "..." nel "server.log"` diventavano <PATTERN> e il bigramma che
    #    discrimina SRCH-2 — che matcha la sottostringa letterale — non si attivava.
    #
    #    Tre dettagli su cui la parità bit-a-bit si gioca, e che una replica
    #    "ragionevole" sbaglierebbe:
    #      1. si iterano ENTRAMBI i tipi di virgoletta (come il `for` in bash), non
    #         if/elif come la (a-bis) subito sotto
    #      2. lo strip di '.log' è case-SENSITIVE, come `${_span%.log}` in bash
    #      3. gli span si raccolgono UNA VOLTA prima di mutare la stringa, come la
    #         process substitution in bash, che è uno snapshot
    if not logfile_done:
        for quo in ('"', "'"):
            for span in re.findall(quo + r'[^' + quo + r']*' + quo, norm):
                inner = span[1:-1]
                base = inner[:-len('.log')] if inner.endswith('.log') else inner
                resolved = cfg['system_log_synonyms'].get(base.lower(), base.lower())
                if resolved in cfg['system_log_bases']:
                    norm = norm.replace(span, inner)

    # a-bis) Qualsiasi stringa quotata RESTANTE (non glob-like) → <PATTERN>.
    #    Simmetrico a <LOGFILE>; deve girare DOPO la (a), stessa priorità.
    if re.search(r'"[^"]*"', norm):
        norm = re.sub(r'"[^"]*"', '<PATTERN>', norm)
    elif re.search(r"'[^']*'", norm):
        norm = re.sub(r"'[^']*'", '<PATTERN>', norm)

    # b) Qualsiasi "<token>.log" → <LOGFILE>, non solo i nomi noti: sul nodo di
    #    produzione ci sono 28 log distinti e APP_LOG_NAMES ne elenca 16, quindi una
    #    whitelist lascerebbe i restanti senza segnale. Esclusi solo i log di
    #    infrastruttura, che hanno tool dedicati.
    if not logfile_done:
        m_log = re.search(r'[a-zA-Z0-9_.-]+\.log', norm)
        if m_log:
            cand_log = m_log.group(0)
            cand_base = cand_log[:-len('.log')]
            cand_base_resolved = cfg['system_log_synonyms'].get(cand_base.lower(), cand_base.lower())
            if cand_base_resolved not in cfg['system_log_bases']:
                # c) Preserva detected_app quando il nome del log è anche uno
                #    short-alias di app (cc→claimcenter, cm→contactmanager).
                if not detected_app:
                    alias_target = cfg['app_short_aliases'].get(cand_base.lower(), '')
                    if alias_target:
                        detected_app = alias_target
                # Gruppi di ritorno consumanti come sed, non lookaround — vedi _word_sub().
                pat = r'(^|[^a-zA-Z0-9_.-])' + re.escape(cand_log) + r'([^a-zA-Z0-9]|$)'
                norm = re.sub(pat, r'\1<LOGFILE>\2', norm, flags=re.IGNORECASE)

    # 4. Abbreviazioni APP_SHORT_ALIASES (solo dopo sostituzione ENV/NODE, come in bash).
    # Nota: qui si usa \b (grep -qE "\b...\b"), non il costrutto (?<![a-z]) delle
    # sezioni 1-3 — replica intenzionale della semantica diversa di normalize-query.sh:121.
    if not detected_app:
        available_lower = {a.lower() for a in cfg['available_apps']}
        for abbr, target in cfg['app_short_aliases'].items():
            canonical = cfg['app_canonical'].get(target, '').lower()
            if canonical not in available_lower and target not in available_lower:
                continue
            if re.search(r'\b' + re.escape(abbr) + r'\b', norm):
                detected_app = target
                norm = re.sub(r'\b' + re.escape(abbr) + r'\b', '<APP>', norm)
                break
            rx = cfg['app_alias_regex'].get(target, '')
            if rx and re.search(rx, norm):
                detected_app = target
                norm = re.sub(rx, '<APP>', norm)
                break

    return norm


# ─── Vettorizzazione (equivalente query-to-features.sh) ─────────────────────

def vectorize(query, unigrams, bigrams):
    # Replica query-to-features.sh:22-23: lowercase applicato di nuovo qui,
    # non solo in normalize_query() — i placeholder <APP>/<ENV>/<NODE> arrivano
    # in maiuscolo da normalize_query() ma i pattern del vocabolario li
    # referenziano minuscoli (<app>.log).
    query = query.lower()
    features = []
    for pat, weight in unigrams:
        try:
            features.append(weight if re.search(pat, query) else 0)
        except re.error:
            features.append(0)
    for patA, patB, weight in bigrams:
        try:
            hit = re.search(patA, query) and re.search(patB, query)
            features.append(weight if hit else 0)
        except re.error:
            features.append(0)
    return features


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--profile', required=True)
    args = ap.parse_args()

    profile_dir = os.path.realpath(args.profile)

    cfg        = load_profile(profile_dir)
    tool_names = cfg['tool_names']

    paths = resolve_nlp_paths(profile_dir)
    unigrams = load_unigrams(paths['unigrams_file'])
    bigrams  = load_bigrams(paths['bigrams_file'])
    num_features = len(unigrams) + len(bigrams)

    labeled_path = paths['labeled_file']
    out_path     = paths['dataset_file']

    count     = 0
    zero_vecs = []

    with open(labeled_path) as fin, open(out_path, 'w') as fout:
        fout.write('# Neural Log Analyzer — intent classification dataset\n')
        fout.write(f'# Profilo: {os.path.basename(profile_dir)} | '
                   f'{num_features} feature + {len(tool_names)} tool output (multi-label)\n')
        fout.write('# Generato da build_dataset.py — non modificare a mano\n')

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

            norm = normalize_query(query, cfg)
            feat = vectorize(norm, unigrams, bigrams)

            if all(v == 0 for v in feat):
                zero_vecs.append((labels, query))

            label_list = [l.strip() for l in labels.split(',')]
            primary    = label_list[0]
            out_vec    = []
            for tool in tool_names:
                if tool == primary:
                    out_vec.append('1')
                elif tool in label_list:
                    out_vec.append('0.7')
                else:
                    out_vec.append('0')

            if all(v == '0' for v in out_vec):
                print(f"[WARN] build_dataset: label sconosciuto '{labels}', riga scartata",
                      file=sys.stderr)
                continue

            fout.write(' '.join(str(v) for v in feat) + ' ' + ' '.join(out_vec) + '\n')
            count += 1

    print(f'[OK] Dataset generato: {count} esempi → {out_path}')

    if zero_vecs:
        print(f'\n[WARN] vocab-linter: {len(zero_vecs)} esempi con feature vector tutto-zero '
              f'(la rete non può imparare da questi):', file=sys.stderr)
        for lbl, q in zero_vecs:
            print(f'         → [{lbl}] "{q}"', file=sys.stderr)
        print('\n       Suggerimento: estendi unigrams.txt con un pattern che copra queste query,',
              file=sys.stderr)
        print('       oppure riformula gli esempi usando termini già nel vocabolario.',
              file=sys.stderr)


if __name__ == '__main__':
    main()
