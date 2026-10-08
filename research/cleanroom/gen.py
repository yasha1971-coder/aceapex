"""gen.py <out dir> - deterministic synthetic reference and assemblies for the clean-room fixtures (not shipped).
Only random.Random(seed).random() is used."""
import os
import random
import sys

COMP = bytes.maketrans(b"ACGTacgt", b"TGCAtgca")


def R(seed):
    r = random.Random(seed)
    return lambda k: int(r.random() * k)


def seq(ri, n, alph=b"ACGT"):
    return bytes(alph[ri(len(alph))] for _ in range(n))


def rc(s):
    return s.translate(COMP)[::-1]


def mutate(ri, s, snp=250, indel=1500):
    out, i = bytearray(), 0
    while i < len(s):
        e = ri(snp * indel)
        if e < indel:
            c = s[i:i + 1].upper()
            out += b"ACGT"[(b"ACGT".find(c) + 1 + ri(3)) % 4:][:1] if c in (b"A", b"C", b"G", b"T") else s[i:i + 1]
            i += 1
        elif e < indel + snp // 2:
            out += seq(ri, 1 + ri(6))
        elif e < indel + snp:
            i += 1 + ri(6)
        else:
            out += s[i:i + 1]
            i += 1
    return bytes(out)


def lower(ri, s, runs, maxlen):
    b = bytearray(s)
    for _ in range(runs):
        p = ri(max(1, len(b)))
        l = 1 + ri(maxlen)
        b[p:p + l] = bytes(b[p:p + l]).lower()
    return bytes(b)


def fasta(recs, width):
    o = bytearray()
    for h, s in recs:
        o += b">" + h + b"\n"
        for i in range(0, len(s), width):
            o += s[i:i + width] + b"\n"
    return bytes(o)


def reference():
    ri = R(70001)
    a = seq(ri, 1_200_000)
    b = seq(ri, 300_000) + b"N" * 20_000 + seq(ri, 280_000)
    c = seq(ri, 200_000)
    return [(b"ref1 synthetic reference record 1", a), (b"ref2", b), (b"ref3", c)]


def assemblies():
    (_, a), (_, b), (_, c) = reference()
    out = {}
    ri = R(1)   # A: forward copies with SNPs / indels, several contigs
    out["asmA"] = ([(b"A_ctg1", mutate(ri, a[0:400_000])), (b"A_ctg2 forward copy", mutate(ri, a[500_000:800_000])),
                    (b"A_ctg3", mutate(ri, c[10_000:150_000]))], 60)
    ri = R(2)   # B: reverse-complement copies, lower-case runs
    out["asmB"] = ([(b"B_rc1", lower(ri, mutate(ri, rc(b[0:250_000])), 30, 2000)), (b"B_rc2", mutate(ri, rc(a[900_000:1_100_000])))], 80)
    ri = R(3)   # C: inversion mosaic, an N run, IUPAC codes
    m = bytearray(mutate(ri, a[200_000:260_000] + rc(a[260_000:300_000]) + a[300_000:380_000] + b"N" * 7_000 + b[330_000:400_000]))
    for _ in range(80):
        m[ri(len(m))] = b"RYKMSWBDHVn"[ri(11)]
    out["asmC"] = ([(b"C_mosaic", bytes(m)), (b"C_refN", b[290_000:330_000])], 70)
    ri = R(4)   # D: novel sequence, tandem repeats (copies inside a block), empty / short / block-edge contigs
    unit = seq(ri, 137)
    novel = seq(ri, 40_000) + mutate(ri, unit * 120, snp=40) + seq(ri, 8_000) + (seq(ri, 9) * 2_000)
    recs = [(b"D_novel", novel), (b"D_empty", b"")]
    for n in (1, 5, 4095, 4096, 4097, 16383, 16384, 16385):
        recs.append((b"D_len%d" % n, mutate(ri, c[150_000:150_000 + n + 50])[:n]))
    out["asmD"] = (recs, 60)
    ri = R(5)   # E: soft-masked (mostly lower case), mixed
    out["asmE"] = ([(b"E_soft", mutate(ri, a[1_000_000:1_150_000]).lower()), (b"E_mixed", lower(ri, mutate(ri, c[0:120_000]), 60, 3000))], 60)
    ri = R(6)   # F: one long contig over many blocks, short last line
    out["asmF"] = ([(b"F_long single contig", mutate(ri, a[0:600_000] + rc(c[0:100_000]) + b[600_000 - 20_000:600_000]))], 61)
    return out


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    ref = reference()
    open(os.path.join(d, "reference.fa"), "wb").write(fasta(ref, 80))
    bad = [(h, s) for h, s in ref]
    s1 = bytearray(bad[0][1]); s1[123_456] = ord("C") if s1[123_456] != ord("C") else ord("G"); bad[0] = (bad[0][0], bytes(s1))
    open(os.path.join(d, "reference_wrong.fa"), "wb").write(fasta(bad, 80))
    for name, (recs, w) in assemblies().items():
        open(os.path.join(d, name + ".fa"), "wb").write(fasta(recs, w))


if __name__ == "__main__":
    main()
