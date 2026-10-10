"""edge_checks.py <v2.1 package dir> <v1 reader binary> <tmp dir> - the 1.0.1 statements on cases outside the package,
each run through the v1 reader built from research/refrel/refrel3v1.cpp @ 5b6d5ce and through specdec.py (v2.1):
meta variants (steps 12 / 12a / 13), contig-table count (step 14), reference layout (step 0), fetch requests (section
14). Prints one line per case: v1 reader response | spec decoder response | the 1.0.1 statement. Variants are built
from archives/asmD.q16k.nohash.rr3 (meta rebuilt, meta_bytes / header XXH3 recomputed, payload untouched). XXH3 through
XXH3_BIN. Not shipped; exit 1 if a case contradicts the expectation written next to it."""
import os, struct, subprocess, sys
import zstandard
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specdec as S

P, BIN, T = (os.path.abspath(x) for x in sys.argv[1:4]); os.makedirs(T, exist_ok=True)
REF = os.path.join(P, "reference", "reference.fa")
BASE = open(os.path.join(P, "archives", "asmD.q16k.nohash.rr3"), "rb").read()


def split(a):
    L = a[136] | a[137] << 8; mz, mr, hs = (int.from_bytes(a[o:o + 8], "little") for o in (96, 104, 112)); m0 = 138 + L
    return bytearray(a[:m0]), a[m0:m0 + mz], a[m0 + mz:m0 + mz + hs], a[m0 + mz + hs:], mr


def join(head, mz, mr, hs, payload):
    head = bytearray(head); head[96:104] = struct.pack("<Q", len(mz)); head[104:112] = struct.pack("<Q", mr)
    b = bytearray(head + mz + hs); b[128:136] = bytes(8); b[128:136] = struct.pack("<Q", S.xxh3(b))
    return bytes(b + payload)


def v1(args):
    out = os.path.join(T, "out.fa")
    if os.path.exists(out): os.remove(out)
    r = subprocess.run([BIN] + args, capture_output=True, text=True); w = os.path.exists(out)
    if w: os.remove(out)
    return (r.stderr.strip().splitlines() or ["(accepted%s)" % (", output written" if w else "")])[-1].replace(T + "/", "")


def spec_decode(ref, arch):
    try:
        R, rs = S.load_ref(ref); S.full(S.open_archive(open(arch, "rb").read(), R, rs)); return "(accepted)"
    except S.Refuse as e: return "open: " + str(e)
    except S.Refusal as e: return e.stage + ": " + e.msg


head, mzb, hs, payload, mr = split(BASE)
M = zstandard.ZstdDecompressor().decompress(mzb)
z19 = lambda m, **k: zstandard.ZstdCompressor(level=19, write_content_size=True, **k).compress(m)
skip = b"\x50\x2a\x4d\x18" + struct.pack("<I", 4) + b"abcd"
fhd = mzb[4]; ss = fhd >> 5 & 1; pos = 5 + (0 if ss else 1)
dictflag = mzb[:4] + bytes([fhd | 1]) + mzb[5:pos] + b"\x07" + mzb[pos:]          # 1-byte Dictionary_ID = 7
ck = bytearray(z19(M, write_checksum=True)); ckbad = bytes(ck[:-1]) + bytes([ck[-1] ^ 1])
M_nrec = struct.pack("<I", len(M) + 1) + M[4:]                                 # nrec > meta_raw
CASES = [  # name, meta section, meta_raw, v1 reader expected (substring), spec decoder expected (prefix)
    ("meta + empty frame", mzb + z19(b""), mr, "(accepted", "open: meta frame count"),
    ("meta + skippable frame", mzb + skip, mr, "(accepted", "open: meta frame count"),
    ("meta + 9 garbage bytes", mzb + bytes(range(1, 10)), mr, "refused: meta decompress", "open: meta frame count"),
    ("meta truncated by 3 B", mzb[:-3], mr, "refused: meta decompress", "open: meta frame count"),
    ("skippable frame first", skip + mzb, mr, "refused: meta frame", "open: meta frame"),
    ("Dictionary_ID = 7", dictflag, mr, "refused: meta decompress", "open: meta decompress"),
    ("content checksum, valid", bytes(ck), mr, "(accepted", "(accepted)"),
    ("content checksum, wrong", ckbad, mr, "refused: meta decompress", "open: meta decompress"),
    ("meta_raw field + 1", mzb, mr + 1, "refused: meta frame", "open: meta frame"),
    ("nrec = meta_raw + 1", z19(M_nrec), len(M_nrec), "refused: records", "open: records"),
]
bad = 0
for name, m, r, want_v1, want_spec in CASES:
    f = os.path.join(T, "case.rr3"); open(f, "wb").write(join(head, m, r, hs, payload))
    a, b = v1(["decode", REF, f, os.path.join(T, "out.fa")]), spec_decode(REF, f)
    ok = want_v1 in a and b.startswith(want_spec); bad += not ok
    print(f"{'ok ' if ok else 'BAD'} {name:28s} | v1 reader: {a:40s} | spec 1.0.1: {b}")

# step 0: reference layout
ARCH = os.path.join(P, "archives", "asmD.q16k.nohash.rr3")
src = open(REF, "rb").read(); first = src.index(b"\n", src.index(b"\n") + 1) + 1          # end of the first sequence line
REFS = [("ref: blank first line", b"\n" + src, "no header", "open: no header"),
        ("ref: no final LF", src[:-1], "no final line end", "open: no final line end"),
        ("ref: empty sequence line", src[:first] + b"\n" + src[first:], "irregular line layout", "open: irregular line layout"),
        ("ref: + header without LF", src + b">x", "(accepted", "(accepted)")]      # same R, tolerated (section 3.1)
for name, rb, want_v1, want_spec in REFS:
    rf = os.path.join(T, "ref.fa"); open(rf, "wb").write(rb)
    a, b = v1(["decode", rf, ARCH, os.path.join(T, "out.fa")]), spec_decode(rf, ARCH)
    ok = want_v1 in a and b.startswith(want_spec); bad += not ok
    print(f"{'ok ' if ok else 'BAD'} {name:28s} | v1 reader: {a:40s} | spec 1.0.1: {b}")
# fetch (section 14): 1-based inclusive in the v1 reader's command line
R0, s0 = S.load_ref(REF); X = S.open_archive(open(ARCH, "rb").read(), R0, s0); nm, ln = X.rec[0][0].split(b" ")[0].decode(), X.rec[0][1]
FETCH = [("unknown name", f"nosuch:1-10", "no contig", ("nosuch", 0, 10), "fetch: no contig"),
         ("end beyond the record", f"{nm}:1-{ln + 1}", "bad range", (nm, 0, ln + 1), "fetch: bad range"),
         ("zero length (start > end)", f"{nm}:5-4", "bad range", (nm, 4, 4), "fetch: bad range"),
         ("start 0 in 1-based form", f"{nm}:0-4", "bad range", (nm, -1, 4), "fetch: bad range")]
for name, req, want_v1, (n0, s0_, e0), want_spec in FETCH:
    a = v1(["fetch", REF, ARCH, req])
    try: S.fetch(X, n0.encode(), s0_, e0); b = "(answered)"
    except S.Refusal as e: b = e.stage + ": " + e.msg
    ok = a.startswith(want_v1) and b.startswith(want_spec); bad += not ok
    print(f"{'ok ' if ok else 'BAD'} {'fetch: ' + name:28s} | v1 reader: {a:40s} | spec 1.0.1: {b}")
print("edge cases:", len(CASES) + len(REFS) + len(FETCH) - bad, "/", len(CASES) + len(REFS) + len(FETCH), "as stated")
sys.exit(1 if bad else 0)
