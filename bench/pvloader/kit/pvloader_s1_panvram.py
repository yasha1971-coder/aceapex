#!/usr/bin/env python3
"""S1 panvram throughput (GPU) — RUN ON THE L4 VM AFTER TRAIN-2.
windows/s with NO model, panvram resident in VRAM decoding on-card. Two measures:
  - sample: Cohort.sample(batch, W, tokens=True) (random windows, the training path)
  - fetch : the SAME seeded window list as S0 (Cohort.fetch per window), for apples-to-apples
            vs the FASTA baselines (pvloader_s1_base.py).
5 repeats each. panvram FROZEN 01f0ce11, UNCHANGED."""
import argparse, glob, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pvloader_lib as PL

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cohort", required=True); ap.add_argument("--reference", required=True)
    ap.add_argument("--asmdir", default=""); ap.add_argument("--assemblies", default="",
                    help="comma manifests; default = the asmdir stems (same 6 as the CPU baseline) or all")
    ap.add_argument("--W", type=int, default=2048); ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--n", type=int, default=10000); ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--seed", type=int, default=20261115); ap.add_argument("--out", required=True)
    a = ap.parse_args()
    import torch, panvram
    assert torch.cuda.is_available(), "S1-panvram needs CUDA"
    if a.assemblies:
        mans = a.assemblies.split(",")
    elif a.asmdir:
        mans = [PL.stem_to_manifest(os.path.basename(f)[:-6]) for f in sorted(glob.glob(os.path.join(a.asmdir, "*.fa.gz")))]
    else:
        mans = None
    c = panvram.Cohort.open(a.cohort, device="cuda", dataset="q4k", reference=a.reference, assemblies=mans)
    g = torch.Generator(device="cuda").manual_seed(a.seed)
    # sample path (training loader path)
    nb = a.n // a.batch
    def run_sample():
        reps = []
        for _ in range(a.repeats):
            torch.cuda.synchronize(); t0 = time.time()
            for _ in range(nb):
                _ = c.sample(a.batch, a.W, generator=g, tokens=True)
            torch.cuda.synchronize(); dt = time.time() - t0
            reps.append(nb * a.batch / dt)
        return [round(x) for x in reps]
    # fetch path (same seeded window list as S0) — build from the opened cohort's contigs
    contigs_by_asm = {}
    for man in c.names:
        contigs_by_asm[man] = [(str(r[0]), int(r[2])) for r in c.contigs(man)]
    wins = PL.build_window_list(contigs_by_asm, a.n, a.W, a.seed)
    def run_fetch():
        reps = []
        for _ in range(a.repeats):
            torch.cuda.synchronize(); t0 = time.time()
            for (man, cn, st) in wins:
                _ = c.fetch(man, cn, st, a.W, tokens=True)
            torch.cuda.synchronize(); dt = time.time() - t0
            reps.append(len(wins) / dt)
        return [round(x) for x in reps]
    res = dict(config=dict(W=a.W, batch=a.batch, n=a.n, repeats=a.repeats, seed=a.seed,
                           n_assemblies=len(c.names), gpu=torch.cuda.get_device_name(0)),
               sample_win_s=run_sample(), fetch_win_s=run_fetch())
    json.dump(res, open(a.out, "w"), indent=2)
    print("panvram sample win/s:", res["sample_win_s"], "fetch win/s:", res["fetch_win_s"])

if __name__ == "__main__":
    main()
