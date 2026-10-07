"""gen_abs.py <out dir> - deterministic data for the ABS fixture (not shipped): the encoder codes a copy as ABS only when
its start is >= 2^24 away from every cached diagonal, so the reference must be longer than 2^24 bases.
  reference_abs.fa: r1 = 1 000 000 random ACGT, r2 = 17 000 000 N (compresses to nothing), r3 = 1 000 000 random ACGT
  asmG.fa: two records; segments of 2 000 - 6 000 bases copied alternately from r1 and r3 (forward or reverse
           complement), each with ~1 SNP per 700 bases, every segment start chosen at random - so almost every copy
           start is a jump of > 2^24 from the previous diagonal. Lower-case run in record 2.
Only random.Random(seed).random() is used. Line width 60."""
import os, random, sys

COMP = bytes.maketrans(b"ACGTacgt", b"TGCAtgca")


def R(seed):
    r = random.Random(seed)
    return lambda k: int(r.random() * k)


def seq(ri, n): return bytes(b"ACGT"[ri(4)] for _ in range(n))


def fasta(recs):
    out = bytearray()
    for name, s in recs:
        out += b">" + name + b"\n"
        for i in range(0, len(s), 60): out += s[i:i + 60] + b"\n"
    return bytes(out)


def main():
    d = sys.argv[1]; os.makedirs(d, exist_ok=True)
    ri = R(20261008)
    r1, r3 = seq(ri, 1_000_000), seq(ri, 1_000_000)
    open(os.path.join(d, "reference_abs.fa"), "wb").write(fasta([(b"r1", r1), (b"r2", b"N" * 17_000_000), (b"r3", r3)]))
    off3 = 1_000_000 + 17_000_000                                  # r3 in the decoded reference: > 2^24 from r1
    recs = []
    for k, total in enumerate((120_000, 80_000)):
        s = bytearray(); src = k
        while len(s) < total:
            L = 2000 + ri(4000); base = r1 if src % 2 == 0 else r3; p = ri(len(base) - L)
            seg = bytearray(base[p:p + L])
            if ri(3) == 0: seg = bytearray(bytes(seg)[::-1].translate(COMP))
            for _ in range(L // 700): q = ri(L); seg[q] = b"ACGT"[(b"ACGT".index(seg[q]) + 1 + ri(3)) % 4]
            s += seg; src += 1
        recs.append([b"g%d chromosome-like test record" % (k + 1), bytes(s[:total])])
    s2 = bytearray(recs[1][1]); s2[10_000:13_000] = bytes(s2[10_000:13_000]).lower(); recs[1][1] = bytes(s2)
    open(os.path.join(d, "asmG.fa"), "wb").write(fasta([(n, s) for n, s in recs]))
    print("reference_abs.fa bases", 19_000_000, "r3 offset", off3, "> 2^24 =", 1 << 24, "| asmG bases", sum(len(s) for _, s in recs))


if __name__ == "__main__":
    main()
