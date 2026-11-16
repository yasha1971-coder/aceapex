#!/usr/bin/env python3
"""S1 baseline throughput (windows/s), NO model. CPU.
  Base A: pysam FastaFile random-window fetch + tokenize, on bgzip+faidx FASTA (NVMe),
          k = 1 / 4 / all-cores workers (multiprocessing), 5 repeats.
  Base B: memmap uint8 of a decompressed assembly, random-window read + tokenize (warm cache;
          cold = NVMe-random-read bound, noted — dropping page cache needs root).
Window list is the SAME seeded list as S0 (via pvloader_lib.build_window_list)."""
import argparse, glob, json, os, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pvloader_lib as PL

W = 2048
ASMDIR = None

def _worker_A(args):
    import pysam
    stem, wins = args
    fa = pysam.FastaFile(os.path.join(ASMDIR, stem + ".fa.gz"))
    n = 0
    for (cn, st) in wins:
        seq = fa.fetch(cn, st, st + W).encode()
        _ = PL.tokenize(seq)
        n += 1
    return n

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cohort", required=True); ap.add_argument("--reference", required=True)
    ap.add_argument("--asmdir", required=True); ap.add_argument("--W", type=int, default=2048)
    ap.add_argument("--n", type=int, default=20000); ap.add_argument("--seed", type=int, default=20261115)
    ap.add_argument("--repeats", type=int, default=5); ap.add_argument("--out", required=True)
    a = ap.parse_args()
    global W, ASMDIR; W = a.W; ASMDIR = a.asmdir
    import panvram, pysam, multiprocessing as mp
    stems = sorted(os.path.basename(f)[:-6] for f in glob.glob(os.path.join(a.asmdir, "*.fa.gz")))
    mans = [PL.stem_to_manifest(s) for s in stems]
    c = panvram.Cohort.open(a.cohort, device="cpu", dataset="q4k", reference=a.reference, assemblies=mans)
    contigs_by_asm = {s: [(str(r[0]), int(r[2])) for r in c.contigs(m)] for s, m in zip(stems, mans)}
    wins = PL.build_window_list(contigs_by_asm, a.n, a.W, a.seed)      # (asm,contig,start)
    ncores = os.cpu_count()

    # ---- Base A: pysam, k workers ----
    def run_A(k):
        # split windows into k chunks, grouped per assembly for FastaFile reuse
        per = [[] for _ in range(k)]
        for i, (s, cn, st) in enumerate(wins):
            per[i % k].append((s, cn, st))
        tasks = []
        for chunk in per:
            byasm = {}
            for (s, cn, st) in chunk: byasm.setdefault(s, []).append((cn, st))
            tasks.append(list(byasm.items()))
        # flatten: one (stem, wins) task per (worker, assembly)
        flat = [t for worker in tasks for t in worker]
        reps = []
        for _ in range(a.repeats):
            t0 = time.time()
            if k == 1:
                tot = sum(_worker_A(t) for t in flat)
            else:
                with mp.Pool(k) as pool:
                    tot = sum(pool.map(_worker_A, flat))
            dt = time.time() - t0
            reps.append(tot / dt)
        return dict(k=k, windows=len(wins), reps_win_s=[round(x) for x in reps],
                    median_win_s=round(sorted(reps)[len(reps)//2]))
    baseA = {str(k): run_A(k) for k in (1, 4, ncores)}

    # ---- Base B: memmap uint8 of ONE decompressed assembly ----
    stem0 = stems[0]; man0 = PL.stem_to_manifest(stem0)
    mmbin = os.path.join(a.asmdir, stem0 + ".u8")
    offsets = {}
    if not os.path.exists(mmbin):
        fa0 = pysam.FastaFile(os.path.join(a.asmdir, stem0 + ".fa.gz"))
        with open(mmbin, "wb") as out:
            off = 0
            for cn in fa0.references:
                b = fa0.fetch(cn).encode(); out.write(b); offsets[cn] = (off, len(b)); off += len(b)
        json.dump(offsets, open(mmbin + ".off.json", "w"))
    else:
        offsets = json.load(open(mmbin + ".off.json"))
    mm = np.memmap(mmbin, dtype=np.uint8, mode="r")
    winsB = [(cn, st) for (s, cn, st) in wins if s == stem0 and cn in offsets]
    def run_B():
        reps = []
        for _ in range(a.repeats):
            t0 = time.time(); n = 0
            for (cn, st) in winsB:
                base, L = offsets[cn]
                _ = PL.LUT[mm[base + st: base + st + a.W]]
                n += 1
            dt = time.time() - t0; reps.append(n / dt)
        return reps
    baseB = dict(assembly=stem0, memmap_bytes=os.path.getsize(mmbin), n_windows=len(winsB),
                 warm_reps_win_s=[round(x) for x in run_B()],
                 cold_note="warm (page-cached) throughput; cold = NVMe random-read bound (page-cache drop needs root, not run)")

    res = dict(config=dict(W=a.W, n=a.n, seed=a.seed, repeats=a.repeats, cores=ncores,
                           assemblies=stems, note="6 local R2 held-out-class assemblies; windows/s is per-access rate (N-independent); capacity in S5"),
               base_A_pysam=baseA, base_B_memmap=baseB,
               panvram_S1="GPU — run after TRAIN-2 (pvloader_s1_panvram.py)")
    json.dump(res, open(a.out, "w"), indent=2)
    print("Base A (pysam) median win/s:", {k: baseA[k]["median_win_s"] for k in baseA})
    print("Base B (memmap warm) win/s:", baseB["warm_reps_win_s"])

if __name__ == "__main__":
    main()
