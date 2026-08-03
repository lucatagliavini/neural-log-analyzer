#!/usr/bin/env python3
"""
train.py — PyTorch trainer per intent classifier del neural-log-analyzer.
Legge e scrive il formato layer AWK (layer*.txt), sostituisce il loop gawk
per il training. Compatibile al 100% con l'inferenza AWK esistente.

Uso:
  .venv/bin/python3 lib/train.py dataset/queries.txt models/intent_classifier [opzioni]
"""

import argparse
import os
import re
import shutil
import sys
import time

import torch
import torch.nn as nn


# ── I/O formato AWK ────────────────────────────────────────────────────────────

def load_layer(path):
    """Legge file layer AWK → (activation_str, weight Tensor out×in, bias Tensor out)."""
    activation = "sigmoid"
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("ACTIVATION="):
                activation = line.split("=", 1)[1]
            elif line:
                rows.append(list(map(float, line.split())))
    w = torch.tensor([r[:-1] for r in rows], dtype=torch.float32)
    b = torch.tensor([r[-1]  for r in rows], dtype=torch.float32)
    return activation, w, b


def save_layer(path, activation, weight, bias):
    """Scrive file layer AWK da Tensor PyTorch (weight: out×in, bias: out)."""
    with open(path, "w") as f:
        f.write(f"ACTIVATION={activation}\n")
        for i in range(weight.shape[0]):
            vals = weight[i].tolist() + [bias[i].item()]
            f.write(" ".join(f"{v:.10g}" for v in vals) + "\n")


def load_dataset(path, num_features, num_outputs):
    """Carica dataset numerico AWK → (X Tensor n×f, Y Tensor n×o)."""
    X, Y = [], []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            vals = list(map(float, line.split()))
            if len(vals) != num_features + num_outputs:
                continue
            X.append(vals[:num_features])
            Y.append(vals[num_features:])
    return (
        torch.tensor(X, dtype=torch.float32),
        torch.tensor(Y, dtype=torch.float32),
    )


# ── Split di validazione ───────────────────────────────────────────────────────

def stratified_split(Y, val_split, seed):
    """
    Split deterministico stratificato sulla firma binarizzata del vettore label
    (es. "000000000000100"), necessario perche' il problema e' multi-label. Le
    firme con pochi esempi contribuiscono 0 al val set per arrotondamento,
    restando interamente nel training set.
    Ritorna (train_idx LongTensor, val_idx LongTensor).
    """
    from collections import defaultdict

    buckets = defaultdict(list)
    for i in range(Y.shape[0]):
        sig = "".join("1" if v > 0 else "0" for v in Y[i].tolist())
        buckets[sig].append(i)

    g = torch.Generator().manual_seed(seed)
    val_idx = []
    for sig in sorted(buckets):  # sorted() = determinismo indipendente da dict order
        idx = buckets[sig]
        perm = torch.randperm(len(idx), generator=g).tolist()
        k = int(round(val_split * len(idx)))
        val_idx.extend(idx[p] for p in perm[:k])

    val_set = set(val_idx)
    train_idx = [i for i in range(Y.shape[0]) if i not in val_set]
    return (
        torch.tensor(sorted(train_idx), dtype=torch.long),
        torch.tensor(sorted(val_idx), dtype=torch.long),
    )


# ── Metriche neutrali ───────────────────────────────────────────────────────────

def compute_metrics(model, X, Y, threshold):
    """
    Metriche confrontabili tra loss diverse (MSE e BCE hanno scale diverse).
    - mse         : nn.MSELoss sempre, come numero comune tra i rami mse/bce
    - exact_match : insieme dei tool >= threshold == insieme dei target > 0
    - argmax_acc  : il top-1 e' una delle label vere (rispecchia l'uso reale di infer.sh)
    - precision/recall/f1: micro, per-label, a threshold
    """
    model.eval()
    with torch.no_grad():
        out = model(X)
        pred = out >= threshold
        tgt = Y > 0  # binarizza le soft label (es. 0.7) per le metriche d'insieme

        mse = nn.MSELoss()(out, Y).item()
        exact = (pred == tgt).all(dim=1).float().mean().item()

        top1 = out.argmax(dim=1, keepdim=True)
        argmx = tgt.gather(1, top1).squeeze(1).float().mean().item()

        tp = (pred & tgt).sum().item()
        fp = (pred & ~tgt).sum().item()
        fn = (~pred & tgt).sum().item()
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    model.train()

    return {
        "mse": mse, "exact_match": exact, "argmax_acc": argmx,
        "precision": prec, "recall": rec, "f1": f1,
    }


def print_metrics(scope, m):
    """Stampa metriche in formato parsabile: [METRIC] <scope>.<key>=<value>"""
    for k in ("mse", "exact_match", "argmax_acc", "precision", "recall", "f1"):
        print(f"[METRIC] {scope}.{k}={m[k]:.6f}")


# ── Costruzione modello ────────────────────────────────────────────────────────

_ACT_MAP = {
    "sigmoid":    nn.Sigmoid,
    "tanh":       nn.Tanh,
    "relu":       nn.ReLU,
    "leaky_relu": nn.LeakyReLU,
}


def build_model(layer_files):
    """
    Costruisce nn.Sequential dai file layer AWK con warm-start dai pesi salvati.
    Ritorna (model, activations, linears).
    """
    modules    = []
    activations = []
    linears    = []

    for path in layer_files:
        act_name, w, b = load_layer(path)
        linear = nn.Linear(w.shape[1], w.shape[0])
        with torch.no_grad():
            linear.weight.copy_(w)
            linear.bias.copy_(b)
        modules.append(linear)
        modules.append(_ACT_MAP.get(act_name, nn.Sigmoid)())
        activations.append(act_name)
        linears.append(linear)

    return nn.Sequential(*modules), activations, linears


# ── Training loop ──────────────────────────────────────────────────────────────

def train_loop(model, X, Y, epochs, lr, optimizer_name, min_delta, patience,
               loss_name="mse", Xv=None, Yv=None):
    criterion = nn.BCELoss() if loss_name == "bce" else nn.MSELoss()
    use_val = Xv is not None and Xv.shape[0] > 0

    if optimizer_name == "adam":
        opt = torch.optim.Adam(model.parameters(), lr=lr)
    elif optimizer_name in ("sgd-momentum", "sgd-momentum-decay"):
        opt = torch.optim.SGD(model.parameters(), lr=lr, momentum=0.9)
    else:
        opt = torch.optim.SGD(model.parameters(), lr=lr)

    best_loss   = float("inf")
    best_state  = None
    best_epoch  = 0
    no_improve  = 0
    last_epoch  = 0
    t0 = time.time()

    for epoch in range(1, epochs + 1):
        last_epoch = epoch
        model.train()
        opt.zero_grad()
        loss = criterion(model(X), Y)
        loss.backward()
        opt.step()

        if use_val:
            model.eval()
            with torch.no_grad():
                monitor = criterion(model(Xv), Yv).item()
            model.train()
        else:
            monitor = loss.item()

        if epoch == 1 or epoch % 100 == 0 or epoch == epochs:
            if loss_name == "mse" and not use_val:
                print(f"[EPOCH {epoch}] MSE = {monitor:.6f} | LR = {lr:.6f} | elapsed = {time.time()-t0:.1f}s")
            else:
                tag = "VAL_LOSS" if use_val else "LOSS"
                print(f"[EPOCH {epoch}] {tag}({loss_name}) = {monitor:.6f} | LR = {lr:.6f} | elapsed = {time.time()-t0:.1f}s")

        if monitor < best_loss - min_delta:
            best_loss  = monitor
            best_epoch = epoch
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
            no_improve = 0
        else:
            no_improve += 1
            if patience > 0 and no_improve >= patience:
                print(f"[INFO] Early stopping at epoch {epoch} "
                      f"(no improvement for {patience} epochs)")
                break

    return best_state, best_loss, best_epoch, last_epoch


# ── Aggiornamento model.conf ───────────────────────────────────────────────────

def update_model_conf(conf_path, epochs, actual_epochs, lr, optimizer, best_mse, best_epoch, loss="mse"):
    if not os.path.exists(conf_path):
        return
    with open(conf_path) as f:
        conf = f.read()
    subs = {
        "last_epochs":        str(epochs),
        "last_actual_epochs": str(actual_epochs),
        "last_lr":            str(lr),
        "last_optimizer":     optimizer,
        "last_loss":          loss,
        "best_mse":           f"{best_mse:.9f}",
        "best_epoch":         str(best_epoch),
        "interrupted":        "0",
    }
    if not conf.endswith("\n"):
        conf += "\n"
    for key, val in subs.items():
        conf, n = re.subn(rf"^{key}=.*", f"{key}={val}", conf, flags=re.MULTILINE)
        if n == 0:
            conf += f"{key}={val}\n"
    with open(conf_path, "w") as f:
        f.write(conf)


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="PyTorch trainer AWK-compatible per intent classifier"
    )
    ap.add_argument("dataset",     help="Path al dataset numerico (queries.txt)")
    ap.add_argument("model_dir",   help="Directory modello (contiene layer*.txt)")
    ap.add_argument("--epochs",    type=int,   default=5000)
    ap.add_argument("--lr",        type=float, default=0.01)
    ap.add_argument("--optimizer", default="adam",
                    choices=["adam", "sgd", "sgd-momentum", "sgd-momentum-decay"])
    ap.add_argument("--min-delta", type=float, default=0.00005, dest="min_delta")
    ap.add_argument("--patience",  type=int,   default=100)
    ap.add_argument("--loss",      default="mse", choices=["mse", "bce"],
                    help="Funzione di loss per il training (default: mse)")
    ap.add_argument("--val-split", type=float, default=0.0, dest="val_split",
                    help="Frazione di validation set stratificato (0 = disabilitato, default)")
    ap.add_argument("--seed",      type=int,   default=42,
                    help="Seed per lo split di validazione (default: 42)")
    ap.add_argument("--threshold", type=float, default=0.25,
                    help="Soglia di attivazione tool per le metriche (default: 0.25)")
    ap.add_argument("--no-save",   action="store_true", dest="no_save")
    args = ap.parse_args()

    if not 0.0 <= args.val_split < 1.0:
        print("[ERROR] --val-split deve essere in [0, 1)", file=sys.stderr)
        sys.exit(1)

    # Trova layer files ordinati (layer1.txt, layer2.txt, ...)
    layer_files = sorted(
        os.path.join(args.model_dir, fn)
        for fn in os.listdir(args.model_dir)
        if re.match(r"^layer\d+\.txt$", fn)
    )
    if not layer_files:
        print(f"[ERROR] Nessun file layer in {args.model_dir}", file=sys.stderr)
        sys.exit(1)

    model, activations, linears = build_model(layer_files)

    num_features = linears[0].in_features
    num_outputs  = linears[-1].out_features
    topo = f"{num_features} → " + " → ".join(str(l.out_features) for l in linears)

    print(f"[INFO] Topologia: {topo}")
    print(f"[INFO] Dataset: {args.dataset}")
    print(f"[INFO] Epochs: {args.epochs} | LR: {args.lr} | Optimizer: {args.optimizer}"
          f" | loss: {args.loss} | min-delta: {args.min_delta} | patience: {args.patience}")

    X, Y = load_dataset(args.dataset, num_features, num_outputs)
    if X.shape[0] == 0:
        print("[ERROR] Dataset vuoto o formato non riconosciuto", file=sys.stderr)
        sys.exit(1)
    print(f"[INFO] Campioni caricati: {X.shape[0]}")

    if args.val_split > 0:
        tr_idx, va_idx = stratified_split(Y, args.val_split, args.seed)
        Xt, Yt = X[tr_idx], Y[tr_idx]
        Xv, Yv = X[va_idx], Y[va_idx]
        print(f"[INFO] Split stratificato (seed={args.seed}): "
              f"train={Xt.shape[0]} val={Xv.shape[0]}")
    else:
        Xt, Yt, Xv, Yv = X, Y, None, None
    print()

    best_state, best_loss, best_epoch, actual_epochs = train_loop(
        model, Xt, Yt,
        epochs=args.epochs,
        lr=args.lr,
        optimizer_name=args.optimizer,
        min_delta=args.min_delta,
        patience=args.patience,
        loss_name=args.loss,
        Xv=Xv, Yv=Yv,
    )
    print()
    print(f"[INFO] Training completato! Best {args.loss.upper()} "
          f"{'val ' if Xv is not None else ''}loss = {best_loss:.6f} (epoch {best_epoch})")

    # Ripristina i pesi migliori PRIMA di calcolare le metriche e prima di --no-save,
    # cosi' le metriche riflettono il checkpoint best sia con --no-save che senza.
    if best_state is not None:
        model.load_state_dict(best_state)

    if Xv is not None:
        print_metrics("val", compute_metrics(model, Xv, Yv, args.threshold))
    print_metrics("train", compute_metrics(model, Xt, Yt, args.threshold))

    if args.no_save:
        return

    # Salva layer files in formato AWK
    for lf, linear, act in zip(layer_files, linears, activations):
        save_layer(lf, act, linear.weight.data, linear.bias.data)
        print(f"[INFO] Salvato: {lf}")

    # Checkpoint best/
    best_dir = os.path.join(args.model_dir, "best")
    os.makedirs(best_dir, exist_ok=True)
    for lf in layer_files:
        shutil.copy2(lf, best_dir)
    print(f"[INFO] Best checkpoint → {best_dir}")

    # Aggiorna model.conf
    update_model_conf(
        os.path.join(args.model_dir, "model.conf"),
        args.epochs, actual_epochs, args.lr, args.optimizer,
        best_loss, best_epoch, args.loss,
    )

    print(f"\n[OK] Modello salvato in {args.model_dir}")


if __name__ == "__main__":
    main()
