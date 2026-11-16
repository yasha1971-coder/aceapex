#!/usr/bin/env python3
"""S2 synthetic compute ceiling (GPU) — RUN ON THE L4 VM AFTER TRAIN-2.
t_step (fwd+bwd+opt) of three model sizes on a batch ALREADY resident on the GPU (no data
loader), so t_step == t_count (pure compute). Models scale TinyCNNLM d/layers to ~x1 / x8 /
x64 parameters. Implied compute-bound ceiling = batch / t_step (windows/s the GPU can consume).
Imports TinyCNNLM from the frozen examples/train_small.py (panvram UNCHANGED)."""
import argparse, json, os, sys, time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-examples", required=True)
    ap.add_argument("--W", type=int, default=2048); ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--steps", type=int, default=50); ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--lr", type=float, default=2e-3); ap.add_argument("--out", required=True)
    a = ap.parse_args()
    import importlib.util, torch, torch.nn.functional as F
    spec = importlib.util.spec_from_file_location("train_small", os.path.join(a.src_examples, "train_small.py"))
    ts = importlib.util.module_from_spec(spec); spec.loader.exec_module(ts)
    V = ts.V
    dev = torch.device("cuda")
    assert torch.cuda.is_available(), "S2 needs CUDA"
    # ~x1 / x8 / x64 params via d,layers (params ~ d^2 * layers). d128L8 base.
    configs = [("x1_d128L8", 128, 8), ("x8_d256L16", 256, 16), ("x64_d512L32", 512, 32)]
    torch.manual_seed(20261115)
    x = torch.randint(0, V, (a.batch, a.W), device=dev)   # resident batch, no loader
    out = {}
    for name, d, L in configs:
        model = ts.TinyCNNLM(d, L).to(dev)
        opt = torch.optim.AdamW(model.parameters(), lr=a.lr)
        nparams = sum(p.numel() for p in model.parameters())
        def step():
            loss = F.cross_entropy(model(x[:, :-1]).reshape(-1, V), x[:, 1:].reshape(-1))
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
        for _ in range(a.warmup): step()
        torch.cuda.synchronize(); t0 = time.time()
        for _ in range(a.steps): step()
        torch.cuda.synchronize(); dt = (time.time() - t0) / a.steps
        out[name] = dict(d=d, layers=L, params=nparams,
                         t_step_s=round(dt, 6), t_step_ms=round(dt*1000, 3),
                         compute_bound_windows_s=round(a.batch / dt),
                         gpu=torch.cuda.get_device_name(0))
        print(f"{name}: params={nparams} t_step={dt*1000:.3f}ms ceiling={round(a.batch/dt)} win/s", flush=True)
    json.dump(dict(config=dict(W=a.W, batch=a.batch, steps=a.steps, seed=20261115), models=out),
              open(a.out, "w"), indent=2)

if __name__ == "__main__":
    main()
