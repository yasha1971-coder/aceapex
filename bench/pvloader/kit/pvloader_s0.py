#!/usr/bin/env python3
"""S0 determinism: one seeded window list for ALL loaders; per-batch checksum must be
IDENTICAL for panvram and the FASTA baseline, else STOP. CPU (panvram device=cpu)."""
import argparse, glob, json, os, sys
import numpy as np, xxhash, pysam
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pvloader_lib as PL

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cohort", required=True); ap.add_argument("--reference", required=True)
    ap.add_argument("--asmdir", required=True)           # dir with <stem>.fa.gz (+.fai,.gzi)
    ap.add_argument("--W", type=int, default=2048); ap.add_argument("--n", type=int, default=512)
    ap.add_argument("--batch", type=int, default=64); ap.add_argument("--seed", type=int, default=20261115)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    import panvram
    stems = sorted(os.path.basename(f)[:-6] for f in glob.glob(os.path.join(a.asmdir, "*.fa.gz")))
    mans = [PL.stem_to_manifest(s) for s in stems]
    c = panvram.Cohort.open(a.cohort, device="cpu", dataset="q4k", reference=a.reference, assemblies=mans)
    # contigs per assembly (use panvram contig table; same names as FASTA PanSN)
    contigs_by_asm = {}
    for s, man in zip(stems, mans):
        contigs_by_asm[s] = [(str(r[0]), int(r[2])) for r in c.contigs(man)]
    wins = PL.build_window_list(contigs_by_asm, a.n, a.W, a.seed)
    fa = {s: pysam.FastaFile(os.path.join(a.asmdir, s + ".fa.gz")) for s in stems}

    def batch_tokens_panvram(batch):
        rows = []
        for (s, cn, st) in batch:
            t = c.fetch(PL.stem_to_manifest(s), cn, st, a.W, tokens=True)
            rows.append(np.asarray(t.cpu().numpy() if hasattr(t, "cpu") else t, dtype=np.uint8))
        return np.stack(rows)
    def batch_tokens_fasta(batch):
        rows = []
        for (s, cn, st) in batch:
            seq = fa[s].fetch(cn, st, st + a.W).encode()
            rows.append(PL.tokenize(seq))
        return np.stack(rows)

    nb = len(wins) // a.batch
    mism = 0; sums = []
    for b in range(nb):
        batch = wins[b*a.batch:(b+1)*a.batch]
        p = batch_tokens_panvram(batch); f = batch_tokens_fasta(batch)
        hp = xxhash.xxh3_64(p.tobytes()).hexdigest(); hf = xxhash.xxh3_64(f.tobytes()).hexdigest()
        ok = (hp == hf)
        if not ok: mism += 1
        sums.append(dict(batch=b, panvram=hp, fasta=hf, match=ok))
    res = dict(seed=a.seed, W=a.W, n=len(wins), batch=a.batch, n_batches=nb,
               assemblies=stems, mismatches=mism, all_match=(mism == 0),
               per_batch=sums[:8])
    json.dump(res, open(a.out, "w"), indent=2)
    print(f"S0: {nb} batches, mismatches={mism}, ALL_MATCH={mism==0}")
    if mism: print("STOP: panvram vs FASTA batch checksums differ"); sys.exit(1)

if __name__ == "__main__":
    main()
