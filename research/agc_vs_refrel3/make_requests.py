"""make_requests.py <archives dir with y1_<sample>.q4k.rr3 + reference> <out dir> - request files for the AGC vs refrel3
comparison, from the contig tables of the archives (names = FASTA header up to the first space; lengths = bases):
  windows_8192.tsv  10 000 windows of 8 192 bases, uniform over every valid start of every contig of the 50 samples
                    (a window never crosses contigs), random.Random(20261003)
  regions.tsv       1 000 regions: sample uniform, contig weighted by length, length 1 + floor(2^(20 u)) capped at the
                    contig, start uniform, random.Random(20261005)
Columns: id sample contig start(0-based) length. Sample = the AGC set name: manifest name without the y1_ prefix, or
by the optional map file (third argument: manifest name <tab> AGC set name)."""
import bisect
import os
import random
import sys

import panvram  # noqa: E402  (CPU path: contig tables only)

src, out = sys.argv[1], sys.argv[2]
amap = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[3])) if len(sys.argv) > 3 else None   # manifest name -> AGC set name
c = panvram.Cohort.open(src, device="cpu", dataset="q4k")
samples = [amap[n] for n in c.names] if amap else [n[3:] if n.startswith("y1_") else n for n in c.names]
ctgs = [(samples[a], name, length) for a in range(len(c)) for (name, _, length, _, _) in c.contigs(a)]
W = 8192
valid = [max(0, L - W + 1) for (_, _, L) in ctgs]
cum, s = [], 0
for v in valid:
    s += v
    cum.append(s)
rng = random.Random(20261003)
with open(os.path.join(out, "windows_8192.tsv"), "w") as f:
    f.write("id\tsample\tcontig\tstart\tlength\n")
    for i in range(10000):
        u = rng.randrange(s)
        k = bisect.bisect_right(cum, u)
        start = u - (cum[k] - valid[k])
        f.write(f"w{i}\t{ctgs[k][0]}\t{ctgs[k][1]}\t{start}\t{W}\n")
rng = random.Random(20261005)
with open(os.path.join(out, "regions.tsv"), "w") as f:
    f.write("id\tsample\tcontig\tstart\tlength\n")
    for i in range(1000):
        a = rng.randrange(len(c))
        cs = c.contigs(a)
        p = rng.randrange(sum(x[2] for x in cs))
        for name, _, L, _, _ in cs:
            if p < L:
                break
            p -= L
        n = min(L, 1 + int(2 ** (rng.random() * 20)))
        f.write(f"r{i}\t{samples[a]}\t{name}\t{rng.randrange(L - n + 1)}\t{n}\n")
print(len(c), "samples,", len(ctgs), "contigs,", s, "valid window starts")
