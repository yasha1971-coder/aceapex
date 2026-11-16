#!/usr/bin/env python3
"""TRAIN-2: train cohort + reference_only (model/hypers from examples/train_small.py,
panvram UNCHANGED), SAVE weights, then evaluate each on three held-out sets:
  (a) random  — ev.sample (TRAIN-1 replication / control)
  (b) HLA+KIR+SegDup — windows from train2_eval_windows.json[seed]['b'] via Cohort.fetch
  (c) SV-insertion   — windows from train2_eval_windows.json[seed]['c'] via Cohort.fetch
bits/base per (seed, model, set). Imports TinyCNNLM/bits_per_base/read_fasta_tokens/
reference_sampler from the frozen train_small.py.
"""
import argparse, json, os, random, sys, time
import torch, torch.nn.functional as F


def load_train_small(src_examples):
    sys.path.insert(0, src_examples)
    import importlib.util
    spec = importlib.util.spec_from_file_location("train_small", os.path.join(src_examples, "train_small.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--cohort", required=True); p.add_argument("--reference", required=True)
    p.add_argument("--dataset", default="q4k"); p.add_argument("--device", default="cuda")
    p.add_argument("--holdout", type=int, default=50); p.add_argument("--steps", type=int, default=2000)
    p.add_argument("--batch", type=int, default=64); p.add_argument("--W", type=int, default=2048)
    p.add_argument("--d", type=int, default=128); p.add_argument("--layers", type=int, default=8)
    p.add_argument("--lr", type=float, default=2e-3)
    p.add_argument("--seed", type=int, required=True); p.add_argument("--seed-label", required=True)
    p.add_argument("--eval-windows", required=True); p.add_argument("--src-examples", required=True)
    p.add_argument("--out", required=True); p.add_argument("--eval-batches", type=int, default=8)
    a = p.parse_args()
    ts = load_train_small(a.src_examples)
    import panvram
    V = ts.V
    device = torch.device(a.device)
    os.makedirs(os.path.join(a.out, "weights"), exist_ok=True)

    # holdout split — identical to train_small
    names = panvram.Cohort.open(a.cohort, device="cpu", dataset=a.dataset, reference=a.reference).names
    rnd = random.Random(a.seed)
    held = sorted(rnd.sample(names, a.holdout))
    train_names = [n for n in names if n not in held]
    tr = panvram.Cohort.open(a.cohort, device=a.device, dataset=a.dataset, reference=a.reference, assemblies=train_names)
    ev = panvram.Cohort.open(a.cohort, device=a.device, dataset=a.dataset, reference=a.reference, assemblies=held)

    def train_model(kind):
        torch.manual_seed(a.seed)
        model = ts.TinyCNNLM(a.d, a.layers).to(device)
        opt = torch.optim.AdamW(model.parameters(), lr=a.lr)
        if kind == "cohort":
            g = torch.Generator(device=a.device).manual_seed(a.seed)
            nb = lambda: tr.sample(a.batch, a.W, generator=g, tokens=True, reverse_complement=0.5).long()
        else:
            reftok = ts.read_fasta_tokens(a.reference)
            g = torch.Generator().manual_seed(a.seed)
            nb = lambda: ts.reference_sampler(reftok, a.batch, a.W, device, g)
        t0, toks = time.time(), 0
        for _ in range(a.steps):
            x = nb()
            loss = F.cross_entropy(model(x[:, :-1]).reshape(-1, V), x[:, 1:].reshape(-1))
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
            toks += x.numel()
        if device.type == "cuda": torch.cuda.synchronize()
        dt = time.time() - t0
        wp = os.path.join(a.out, "weights", f"{kind}.seed-{a.seed_label}.pt")
        torch.save(model.state_dict(), wp)
        model.eval()
        return model, dict(train_s=round(dt, 2), tokens_per_s=round(toks / dt), weights=wp)

    def bpb_batches(model, batches):
        with torch.no_grad():
            return sum(ts.bits_per_base(model, x) for x in batches) / len(batches)

    # eval set (a) random — same generator as train_small
    g_ev = torch.Generator(device=a.device).manual_seed(a.seed + 1)
    rand_batches = [ev.sample(a.batch, a.W, generator=g_ev, tokens=True).long() for _ in range(a.eval_batches)]

    # eval sets (b),(c) from precomputed windows -> fetch tokens, batch
    EW = json.load(open(a.eval_windows))["windows"][a.seed_label]
    def fetch_batches(key):
        wins = EW[key]
        toks = []
        for man, contig, st in wins:
            t = ev.fetch(man, contig, int(st), a.W, tokens=True)
            toks.append(t.to(device).long())
        if not toks: return []
        X = torch.stack(toks)                      # [N, W]
        nb = X.shape[0] // a.batch
        return [X[i*a.batch:(i+1)*a.batch] for i in range(nb)]
    b_batches = fetch_batches("b")
    c_batches = fetch_batches("c")

    out = {"seed_label": a.seed_label, "seed": a.seed, "W": a.W, "steps": a.steps,
           "batch": a.batch, "holdout": a.holdout, "heldout_assemblies": held,
           "panvram": getattr(panvram, "__version__", "?"), "models": {}}
    for kind in ("cohort", "reference_only"):
        model, meta = train_model(kind)
        res = dict(meta)
        res["random"] = round(bpb_batches(model, rand_batches), 4)
        res["hla_kir_segdup"] = round(bpb_batches(model, b_batches), 4) if b_batches else None
        res["sv_insertion"] = round(bpb_batches(model, c_batches), 4) if c_batches else None
        out["models"][kind] = res
        print(f"[{a.seed_label}] {kind}: random={res['random']} b={res['hla_kir_segdup']} c={res['sv_insertion']}", flush=True)
    jp = os.path.join(a.out, f"train2.seed-{a.seed_label}.json")
    json.dump(out, open(jp, "w"), indent=2)
    print("wrote", jp, flush=True)


if __name__ == "__main__":
    main()
