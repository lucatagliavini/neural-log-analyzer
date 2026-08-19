# stratified-split.awk — split train/validation stratificato sulla firma binaria
# del vettore output, porta bash/awk di stratified_split() in lib/train.py.
# Nessuna dipendenza da PyTorch/torch.randperm: la migrazione a neural-c serve
# proprio a eliminare quella dipendenza, quindi lo split non poteva reintrodurla.
#
# Necessario perché il problema è multi-label: raggruppare per firma ("quali
# tool sono attivi in questo esempio") assicura che ogni combinazione di label
# sia rappresentata proporzionalmente sia nel training set che nel validation
# set, invece di rischiare che una combinazione rara finisca tutta in un lato.
#
# Input: un file in formato "neural-c dataset 1" (righe "in1 ... inN -> out1 ...outM").
# Output: due file nello stesso formato, out_train e out_val.
#
# Uso: gawk -v val_split=0.15 -v seed=42 -v out_train=train.txt -v out_val=validation.txt \
#          -f lib/stratified-split.awk dataset.txt

function hash_key(i, sig,    h, k) {
    # Combinazione deterministica (seed, indice riga, firma) -> intero.
    # Non crittografica: serve solo un ordinamento pseudo-casuale riproducibile
    # per bucket, non l'imprevedibilità. Determinismo qui significa "stesso
    # seed -> stesso split", non "identico al vecchio split PyTorch": i pesi
    # ripartono da zero con neural-c, quindi un nuovo split è accettabile.
    h = (seed * 2654435761 + i * 40503) % 2147483647
    for (k = 1; k <= length(sig); k++) {
        h = (h * 31 + (substr(sig, k, 1) + 0) + 1) % 2147483647
    }
    return h
}

BEGIN {
    if (val_split < 0 || val_split >= 1) {
        print "[ERROR] stratified-split: val_split deve essere in [0,1), ricevuto " val_split > "/dev/stderr"
        exit 1
    }
    if (out_train == "" || out_val == "") {
        print "[ERROR] stratified-split: out_train e out_val sono obbligatori" > "/dev/stderr"
        exit 1
    }
    n = 0
    nb = 0
}

/^neural-c dataset/ { next }
NF == 0 { next }
{
    sep = index($0, " -> ")
    if (sep == 0) next
    out_part = substr($0, sep + 4)
    m = split(out_part, ov, " ")
    sig = ""
    for (k = 1; k <= m; k++) sig = sig (ov[k] + 0 > 0 ? "1" : "0")

    n++
    rows[n] = $0
    if (!(sig in bucket_seen)) {
        bucket_seen[sig] = 1
        buckets_list[++nb] = sig
    }
    bucket_members[sig] = bucket_members[sig] SUBSEP n
}

END {
    if (n == 0) {
        print "[ERROR] stratified-split: nessuna riga dati in input" > "/dev/stderr"
        exit 1
    }

    asort(buckets_list)  # determinismo indipendente dall'ordine di iterazione di awk

    for (b = 1; b <= nb; b++) {
        sig = buckets_list[b]
        cnt = split(bucket_members[sig], members, SUBSEP)
        # split() con SUBSEP iniziale produce un primo campo vuoto: scartalo.
        off = (members[1] == "") ? 1 : 0

        c = 0
        for (a = 1 + off; a <= cnt; a++) {
            c++
            idx[c] = members[a] + 0
            key[c] = hash_key(idx[c], sig)
        }

        # Ordina idx per key (selection sort: c è piccolo, una firma per riga).
        for (a = 1; a <= c; a++) {
            for (d = a + 1; d <= c; d++) {
                if (key[d] < key[a]) {
                    tk = key[a]; key[a] = key[d]; key[d] = tk
                    ti = idx[a]; idx[a] = idx[d]; idx[d] = ti
                }
            }
        }

        k_val = int(val_split * c + 0.5)
        for (a = 1; a <= k_val; a++) is_val[idx[a]] = 1

        delete idx; delete key
    }

    print "neural-c dataset 1" > out_train
    print ""                    > out_train
    print "neural-c dataset 1" > out_val
    print ""                    > out_val

    n_train = 0; n_val = 0
    for (i = 1; i <= n; i++) {
        if (i in is_val) { print rows[i] > out_val;   n_val++ }
        else             { print rows[i] > out_train; n_train++ }
    }

    printf "totale=%d train=%d validation=%d\n", n, n_train, n_val
}
