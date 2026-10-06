"""build_pkg.py - assemble the clean-room package directory (not shipped). Expected values come from the synthetic
source FASTA (independent of any decoder); every expected value is then checked against the frozen tool."""
import hashlib, json, os, random, shutil, subprocess, sys

W = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(W, "data"); A = os.path.join(W, "arch")
OUT = os.path.join(W, "pkg", "refrel3_cleanroom_v1"); TOOL = os.path.join(W, "refrel3v1")
sha = lambda b: hashlib.sha256(b).hexdigest()


def parse_fasta(b):
    recs, name, seq = [], None, []
    for line in b.split(b"\n"):
        if line.startswith(b">"):
            if name is not None: recs.append((name, b"".join(seq)))
            name, seq = line[1:].split(b" ")[0].split(b"\t")[0], []
        elif line: seq.append(line)
    if name is not None: recs.append((name, b"".join(seq)))
    return recs


def main():
    if os.path.exists(OUT): sys.exit("output exists: " + OUT)
    for d in ("reference", "archives", "fetch", "corrupt"): os.makedirs(os.path.join(OUT, d))
    shutil.copy(os.path.join(W, "src/research/refrel/FORMAT.md"), os.path.join(OUT, "FORMAT.md"))
    for f in ("reference.fa", "reference_wrong.fa"): shutil.copy(os.path.join(D, f), os.path.join(OUT, "reference", f))
    exp = {"format": "refrel3 v1 (FORMAT.md)", "coordinates": "fetch: contig = record name (header up to the first space or tab), start 0-based, length in bases; answer = those bases, case as in the FASTA",
           "references": {f: sha(open(os.path.join(D, f), "rb").read()) for f in ("reference.fa", "reference_wrong.fa")},
           "archives": [], "corrupt": []}
    for f in sorted(os.listdir(A)):
        asm = f.split(".")[0]; src = open(os.path.join(D, asm + ".fa"), "rb").read(); recs = [(n, s) for n, s in parse_fasta(src)]
        shutil.copy(os.path.join(A, f), os.path.join(OUT, "archives", f))
        rng = random.Random(int(sha(f.encode())[:8], 16)); rows = []
        cand = [(n, s) for n, s in recs if len(s) > 0]
        for i in range(50):
            n, s = cand[rng.randrange(len(cand))]
            kind = i % 5
            if kind == 0: start, ln = 0, min(len(s), 1 + rng.randrange(5000))                       # contig start
            elif kind == 1: ln = min(len(s), 1 + rng.randrange(5000)); start = len(s) - ln          # contig end
            elif kind == 2: ln = 1; start = rng.randrange(len(s))                                   # single base
            else: ln = min(len(s), 1 + int(2 ** (rng.random() * 17))); start = rng.randrange(len(s) - ln + 1)
            rows.append((n.decode(), start, ln, sha(s[start:start + ln])))
        with open(os.path.join(OUT, "fetch", f + ".fetch.tsv"), "w") as o:
            o.write("contig\tstart\tlength\tsha256\n")
            for r in rows: o.write("%s\t%d\t%d\t%s\n" % r)
        exp["archives"].append({"archive": "archives/" + f, "reference": "reference/reference.fa", "expect": "decode",
                                "fasta_sha256": sha(src), "fasta_bytes": len(src), "fetch": "fetch/" + f + ".fetch.tsv"})
    def corrupt(name, base, how, ref="reference.fa"):
        b = bytearray(open(os.path.join(A, base), "rb").read()); how(b)
        open(os.path.join(OUT, "corrupt", name), "wb").write(bytes(b))
        exp["corrupt"].append({"archive": "corrupt/" + name, "reference": "reference/" + ref, "expect": "refuse"})
    corrupt("truncated.rr3", "asmB.q16k.hash.rr3", lambda b: b.__delitem__(slice(int(len(b) * 0.7), None)))
    corrupt("header_byte.rr3", "asmE.q4k.nohash.rr3", lambda b: b.__setitem__(70, b[70] ^ 0x10))
    def block(b):                       # a payload byte near the end (in a block with its XXH3 in the archive)
        b[len(b) - 777] ^= 0x04
    corrupt("block_with_hash.rr3", "asmA.q4k.hash.rr3", block)
    shutil.copy(os.path.join(A, "asmF.q4k.hash.rr3"), os.path.join(OUT, "corrupt", "valid_for_wrong_reference.rr3"))
    exp["corrupt"].append({"archive": "corrupt/valid_for_wrong_reference.rr3", "reference": "reference/reference_wrong.fa", "expect": "refuse"})
    json.dump(exp, open(os.path.join(OUT, "EXPECTED.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
