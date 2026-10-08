"""make_req.py <N> <out dir> - M6 requests (PROTOCOL_M6 section 4) for the first N manifest assemblies, from the contig
tables of their v1 archives (panvram CPU path; names = FASTA header up to the first space, lengths in bases):
  windows_4096.tsv  10 000 windows of 4 096 bases uniform over every valid start, random.Random(20261011 + N)
  regions_1M.tsv    100 regions of 1 000 000 bases uniform over every valid start of contigs >= 1 000 000, random.Random(20261111 + N)
  names.tsv         manifest name <tab> AGC set name (identical)
  samples4.txt      the first 4 manifest names, comma-separated
Columns of the request files: id sample contig start(0-based) length."""
import bisect, os, random, sys
import panvram

N, out = int(sys.argv[1]), sys.argv[2]; os.makedirs(out, exist_ok=True)
V1 = os.path.expanduser("~/pubrepo/.wk/hprc_cohort/v1")
names = [l.split("\t")[0] for l in list(open(os.path.join(V1, "manifest_v1.tsv")))[1:N + 1]]
c = panvram.Cohort.open(V1, device="cpu", dataset="q4k", reference=os.path.expanduser("~/golden/genome/t2t.fa"), assemblies=names)
ctgs = [(n, name, L) for n in names for (name, _, L, _, _) in c.contigs(n)]


def uniform(W, seed, count, prefix, path):
    valid = [max(0, L - W + 1) for (_, _, L) in ctgs]; cum, s = [], 0
    for v in valid: s += v; cum.append(s)
    rng = random.Random(seed)
    with open(path, "w") as f:
        f.write("id\tsample\tcontig\tstart\tlength\n")
        for i in range(count):
            u = rng.randrange(s); k = bisect.bisect_right(cum, u); st = u - (cum[k] - valid[k])
            assert 0 <= st and st + W <= ctgs[k][2]
            f.write(f"{prefix}{i}\t{ctgs[k][0]}\t{ctgs[k][1]}\t{st}\t{W}\n")
    return s


s1 = uniform(4096, 20261011 + N, 10000, "w", os.path.join(out, "windows_4096.tsv"))
s2 = uniform(1000000, 20261111 + N, 100, "r", os.path.join(out, "regions_1M.tsv"))
open(os.path.join(out, "names.tsv"), "w").write("".join(f"{n}\t{n}\n" for n in names))
open(os.path.join(out, "samples4.txt"), "w").write(",".join(names[:4]) + "\n")
print(f"N {N}: {len(ctgs)} contigs, {s1} valid window starts, {s2} valid 1 Mb starts")
