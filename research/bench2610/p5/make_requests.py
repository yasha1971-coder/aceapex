"""make_requests.py <work dir> - request files of PROTOCOL_FAIDX (P1) and PROTOCOL_COHORT_REGION (P3), from contig
lengths only (.fai of the uncompressed FASTA for P1; the 558 contig tables for P3). Columns: id, fasta key, contig,
start (0-based), length.
P1: corpora chr1, T2T, HPRC4 (HG00438.1/.2, HG00621.1/.2 together); L in 100, 1 000, 10 000, 100 000, 1 000 000;
    10 000 regions per corpus x L, uniform over every valid start of every contig with length >= L,
    random.Random(20261007 + i), i = index of L.
P3: 20 triples (L_j log-uniform in [50 000, 1 000 000], rank r_j in 0..9, f_j in [0, 1)) from random.Random(20261008),
    applied to every one of the 558 assemblies: contig of rank r_j (by length descending, ties by name), start =
    floor(f_j x (len - L_j)); a rank beyond the assembly's contigs or a contig shorter than L_j -> that request is
    skipped and listed (never moved to another contig)."""
import bisect, math, os, random, sys

W = sys.argv[1]
LS = [100, 1000, 10000, 100000, 1000000]


def fai(path):
    return [(l.split("\t")[0], int(l.split("\t")[1])) for l in open(path + ".fai")]


def p1():
    corpora = {"chr1": ["chr1"], "t2t": ["t2t"], "hprc4": ["HG00438.1", "HG00438.2", "HG00621.1", "HG00621.2"]}
    os.makedirs(os.path.join(W, "req_p1"), exist_ok=True)
    for cname, keys in corpora.items():
        ctgs = [(k, n, ln) for k in keys for n, ln in fai(os.path.join(W, "fa", k + ".fa"))]
        for i, L in enumerate(LS):
            valid = [max(0, ln - L + 1) for _, _, ln in ctgs]
            cum, s = [], 0
            for v in valid:
                s += v; cum.append(s)
            rng = random.Random(20261007 + i)
            with open(os.path.join(W, "req_p1", f"{cname}_L{L}.tsv"), "w") as f:
                f.write("id\tfasta\tcontig\tstart\tlength\n")
                for r in range(10000):
                    u = rng.randrange(s); k = bisect.bisect_right(cum, u); st = u - (cum[k] - valid[k])
                    f.write(f"{cname}_L{L}_{r}\t{ctgs[k][0]}\t{ctgs[k][1]}\t{st}\t{L}\n")


def p3(truth_ctg):
    rng = random.Random(20261008)
    trip = [(int(round(math.exp(math.log(50000) + rng.random() * (math.log(1000000) - math.log(50000))))), int(rng.random() * 10), rng.random()) for _ in range(20)]
    os.makedirs(os.path.join(W, "req_p3"), exist_ok=True)
    with open(os.path.join(W, "req_p3", "regions20.tsv"), "w") as f:
        f.write("j\tlength\trank\tfraction\n")
        for j, (L, r, fr) in enumerate(trip): f.write(f"{j}\t{L}\t{r}\t{fr!r}\n")
    ctg = {}
    for l in open(truth_ctg):
        x = l.rstrip("\n").split("\t")
        if x[0] == "CTG": ctg.setdefault(x[1], []).append((x[2], int(x[3])))
    skipped = 0
    with open(os.path.join(W, "req_p3", "requests.tsv"), "w") as f, open(os.path.join(W, "req_p3", "skipped.tsv"), "w") as sk:
        f.write("id\tsample\tcontig\tstart\tlength\n"); sk.write("sample\tj\treason\n")
        for asm in sorted(ctg):
            order = sorted(ctg[asm], key=lambda c: (-c[1], c[0]))
            for j, (L, r, fr) in enumerate(trip):
                if r >= len(order) or order[r][1] < L: sk.write(f"{asm}\t{j}\t{'no contig of that rank' if r >= len(order) else 'contig shorter than L'}\n"); skipped += 1; continue
                n, ln = order[r]; st = int(fr * (ln - L))
                f.write(f"{asm}#{j}\t{asm}\t{n}\t{st}\t{L}\n")
    print("P3:", len(ctg), "assemblies,", skipped, "requests skipped")


if __name__ == "__main__":
    p1()
    p3(sys.argv[2])
