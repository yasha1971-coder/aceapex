"""check_strict_1116.py - the two FORMAT_V1_SPEC.md 1.0.1 rules where the first v1 reader (refrel3v1.cpp @ 5b6d5ce) is
laxer (spec section 21), on published archives, read-only:
  rule 1 (step 12a): the meta section is exactly one zstd frame - the compressed size of the first frame == meta_bytes
         (own frame walk per RFC 8878 and libzstd ZSTD_findFrameCompressedSize must both agree); frames in the section
         are also counted (zstd and skippable) by walking until the end; the first frame decompresses to meta_raw bytes
  rule 2 (section 0, steps 7, 8, 9, 14, 15, 17): sizes and sums with exact integers - payload_start + payload_bytes ==
         file size, nblocks == ceil(n / Q), hash_bytes, sum of record lengths == n, every lower-case run end <= n,
         sum of block stream lengths == payload_bytes, meta consumed exactly; every LEB128 <= 10 bytes and < 2^64; and
         the u64 (mod 2^64) results equal the exact ones (no wrap anywhere)
Modes:
  stream <dataset> <tar part>...    tar stream (tarfile 'r|') over the concatenated parts, nothing extracted; the
                                    SHA-256 of the whole stream and of every member (vs ~/panvram/MANIFEST.tsv
                                    <dataset>_sha256) is checked; one TSV line per archive on stdout   [--limit N]
  files <dataset|-> <archive>...    the same checks on files (no manifest check when dataset is -)
  selftest <valid archive>          negative cases built in memory from a valid archive; each must be caught
Not shipped."""
import ctypes, ctypes.util, hashlib, os, struct, sys, tarfile
import zstandard

ZL = ctypes.CDLL(ctypes.util.find_library("zstd") or "libzstd.so.1")
ZL.ZSTD_findFrameCompressedSize.restype = ctypes.c_size_t
ZL.ZSTD_findFrameCompressedSize.argtypes = (ctypes.c_char_p, ctypes.c_size_t)
ZL.ZSTD_isError.argtypes = (ctypes.c_size_t,)
M64 = 1 << 64
COLS = ["dataset", "name", "member", "bytes", "sha256", "sha256_eq_manifest", "Q", "n", "nblocks", "meta_bytes", "meta_raw",
        "meta_frames", "meta_skippable_frames", "first_frame_size", "libzstd_frame_size", "rule1_one_frame", "nrec",
        "sum_len_eq_n", "nruns", "max_run_end_le_n", "sum_slen_eq_payload", "meta_consumed", "u64_eq_exact", "rule2_exact_sums", "detail"]


# ---------------------------------------------------------------- zstd frames (RFC 8878 section 3.1)
def frame_size(b, at):
    """(size, kind) of the frame at b[at:], kind 'zstd' / 'skip'; (None, why) if it does not end inside b"""
    if at + 4 > len(b): return None, "short"
    m = int.from_bytes(b[at:at + 4], "little")
    if m & 0xFFFFFFF0 == 0x184D2A50:
        if at + 8 > len(b): return None, "short skippable"
        s = 8 + int.from_bytes(b[at + 4:at + 8], "little")
        return (s, "skip") if at + s <= len(b) else (None, "truncated skippable")
    if m != 0xFD2FB528: return None, "not a frame"
    if at + 5 > len(b): return None, "short header"
    fhd = b[at + 4]; fcsf, ss, ck, did = fhd >> 6, fhd >> 5 & 1, fhd >> 2 & 1, fhd & 3
    if fhd & 8: return None, "reserved bit"
    pos = at + 5 + (0 if ss else 1) + (0, 1, 2, 4)[did] + (1 if ss else 0, 2, 4, 8)[fcsf]
    while True:
        if pos + 3 > len(b): return None, "truncated block header"
        bh = int.from_bytes(b[pos:pos + 3], "little"); last, typ, sz = bh & 1, bh >> 1 & 3, bh >> 3
        if typ == 3: return None, "reserved block type"
        pos += 3 + (1 if typ == 1 else sz)
        if pos > len(b): return None, "truncated block"
        if last: break
    pos += 4 if ck else 0
    return (pos - at, "zstd") if pos <= len(b) else (None, "truncated checksum")


def count_frames(b):
    at = nz = ns = 0
    while at < len(b):
        s, k = frame_size(b, at)
        if s is None: return nz, ns, "garbage at %d (%s)" % (at, k)
        nz += k == "zstd"; ns += k == "skip"; at += s
    return nz, ns, ""


# ---------------------------------------------------------------- checks
def check(a):
    """dict of COLS values (without dataset / name / member / sha256 fields)"""
    r = {}; det = []; n = len(a); r["bytes"] = n
    u32 = lambda o: int.from_bytes(a[o:o + 4], "little"); u64 = lambda o: int.from_bytes(a[o:o + 8], "little")
    if n < 138 or a[:8] != b"RFRL3V1\0" or u32(8) != 1:
        r.update(rule1_one_frame=False, rule2_exact_sums=False, detail="not a v1 archive"); return r
    Q, flags, nb_, nbl = u32(12), u32(16), u64(64), u64(72)
    mz, mr, hs, pl = u64(96), u64(104), u64(112), u64(120); L = a[136] | a[137] << 8
    r.update(Q=Q, n=nb_, nblocks=nbl, meta_bytes=mz, meta_raw=mr)
    wrap = []                                                        # (what, exact, u64) where they differ
    pstart = 138 + L + mz + hs
    ok7 = pstart + pl == n and mz <= n and hs <= n and pl <= n
    if (pstart % M64 + pl) % M64 != pstart + pl: wrap.append(("payload_start + payload_bytes", pstart + pl))
    ceil = -(-nb_ // Q); ok8 = nbl == ceil and (nb_ == 0 or nbl > 0)
    if (nb_ + Q - 1) % M64 // Q != ceil: wrap.append(("ceil(n/Q)", ceil))
    ok9 = hs == (8 * nbl if flags & 1 else 0)
    if not (ok7 and ok8 and ok9): det.append("step7 %s step8 %s step9 %s" % (ok7, ok8, ok9))
    sec = bytes(a[138 + L:138 + L + mz]) if ok7 else b""
    # rule 1
    ff, why = frame_size(sec, 0); lz = ZL.ZSTD_findFrameCompressedSize(sec, len(sec))
    lz = None if ZL.ZSTD_isError(lz) else lz
    nz, ns, g = count_frames(sec)
    r.update(meta_frames=nz, meta_skippable_frames=ns, first_frame_size=ff, libzstd_frame_size=lz)
    rule1 = ok7 and ff == mz and lz == mz and nz == 1 and ns == 0 and not g
    if g: det.append("meta: " + g)
    M = None
    if rule1:
        try: M = zstandard.ZstdDecompressor().decompress(sec, max_output_size=mr + 1)
        except zstandard.ZstdError as e: det.append("meta decompress: %s" % e); rule1 = False
        if M is not None and len(M) != mr: det.append("meta %d B != meta_raw" % len(M)); rule1 = False
    r["rule1_one_frame"] = rule1
    # rule 2: meta sums, exact
    ok14 = ok15 = ok17 = consumed = False
    if M is not None:
        i = 0; bad = []
        def take(k):
            nonlocal i
            if i + k > len(M): raise IndexError("meta overrun")
            v = M[i:i + k]; i += k; return v
        def leb():
            nonlocal i
            v = sh = 0; k = 0
            while True:
                if i >= len(M): raise IndexError("LEB128 past the end")
                c = M[i]; i += 1; k += 1; v |= (c & 0x7F) << sh
                if not c & 0x80: break
                sh += 7
                if k == 10: raise IndexError("LEB128 longer than 10 bytes")
            if v >= M64: bad.append("LEB128 >= 2^64")
            return v
        try:
            nrec = int.from_bytes(take(4), "little"); s = s64 = 0; lw0 = False
            for _ in range(nrec):
                hl = int.from_bytes(take(4), "little"); take(hl); ln = int.from_bytes(take(8), "little"); lw = int.from_bytes(take(4), "little")
                lw0 |= ln > 0 and lw == 0; s += ln; s64 = (s64 + ln) % M64
            ok14 = s == nb_ and not lw0
            if s64 != s: wrap.append(("sum len", s))
            nr = int.from_bytes(take(8), "little"); last = last64 = 0; mx = 0; ok15 = nr <= nb_
            for _ in range(nr):
                g_, l_ = leb(), leb(); e = last + g_ + l_; e64 = (last64 + g_ % M64 + l_ % M64) % M64
                if e != e64: wrap.append(("run end", e))
                ok15 &= e <= nb_; mx = max(mx, e); last, last64 = e, e64
            r.update(nrec=nrec, nruns=nr)
            for c in range(1827): leb()
            sl = sl64 = 0
            for _ in range(nbl):
                x = leb(); leb(); sl += x; sl64 = (sl64 + x) % M64
            if sl64 != sl: wrap.append(("sum slen", sl))
            ok17 = sl == pl; consumed = i == len(M)
            r["max_run_end_le_n"] = ok15
        except IndexError as e: det.append("meta parse: %s" % e)
        if bad: det.append(bad[0]); ok14 = ok15 = ok17 = False
    r.update(sum_len_eq_n=ok14, sum_slen_eq_payload=ok17, meta_consumed=consumed, u64_eq_exact=not wrap)
    r.setdefault("max_run_end_le_n", ok15)
    if wrap: det.append("u64 wraps: " + ", ".join("%s exact %d" % w for w in wrap[:3]))
    r["rule2_exact_sums"] = ok7 and ok8 and ok9 and ok14 and ok15 and ok17 and consumed and not wrap
    r["detail"] = "; ".join(det) or "-"
    return r


def line(r): return "\t".join(str(r.get(c, "-")) for c in COLS)


class Cat:                                                           # concatenated parts as one read-only stream + SHA-256
    def __init__(s, paths): s.p = list(paths); s.f = None; s.h = hashlib.sha256(); s.n = 0
    def read(s, k=-1):
        out = b""
        while k < 0 or len(out) < k:
            if s.f is None:
                if not s.p: break
                s.f = open(s.p.pop(0), "rb")
            b = s.f.read(1 << 20 if k < 0 else min(1 << 20, k - len(out)))
            if not b: s.f.close(); s.f = None; continue
            out += b
        s.h.update(out); s.n += len(out); return out


def manifest(ds):
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.expanduser("~/panvram/MANIFEST.tsv"))]
    h = rows[0]; return {r[0]: r[h.index(ds + "_sha256")] for r in rows[1:]}


def run_stream(ds, parts, limit):
    man = manifest(ds); cnt = {"n": 0, "man": 0, "r1": 0, "r2": 0}; seen = set()
    print("\t".join(COLS)); src = Cat(parts)
    with tarfile.open(fileobj=src, mode="r|") as t:
        for m in t:
            if not m.isfile(): continue
            a = t.extractfile(m).read(); base = os.path.basename(m.name)
            if not base.endswith(".rr3"):
                print("# other member %s %d B sha256 %s" % (m.name, len(a), hashlib.sha256(a).hexdigest()), flush=True); continue
            name = base.rsplit(".", 2)[0] if base.endswith(".rr3") else base
            r = check(a); sh = hashlib.sha256(a).hexdigest()
            r.update(dataset=ds, name=name, member=m.name, sha256=sh, sha256_eq_manifest=man.get(name) == sh)
            print(line(r), flush=True); seen.add(name)
            cnt["n"] += 1; cnt["man"] += r["sha256_eq_manifest"]; cnt["r1"] += r["rule1_one_frame"]; cnt["r2"] += r["rule2_exact_sums"]
            if limit and cnt["n"] >= limit: break
    if not limit:
        while src.read(1 << 20): pass                                # rest of the stream (tar end blocks) for the hash
    miss = sorted(set(man) - seen) if not limit else []
    print("# %s: archives %d, sha256 == manifest %d, rule 1 (one meta frame) %d, rule 2 (exact sums) %d, manifest names not in the tar %d%s"
          % (ds, cnt["n"], cnt["man"], cnt["r1"], cnt["r2"], len(miss), (" " + ",".join(miss[:5])) if miss else ""))
    if not limit: print("# %s stream: %d B, sha256 %s" % (ds, src.n, src.h.hexdigest()))
    return 0 if cnt["n"] == cnt["man"] == cnt["r1"] == cnt["r2"] and not miss else 1


# ---------------------------------------------------------------- negative cases
def selftest(path):
    a = open(path, "rb").read(); L = a[136] | a[137] << 8; mz, mr = (int.from_bytes(a[o:o + 8], "little") for o in (96, 104))
    m0 = 138 + L; sec = a[m0:m0 + mz]; M = zstandard.ZstdDecompressor().decompress(sec)

    def build(new_sec, new_raw=None):
        h = bytearray(a[:m0]); h[96:104] = struct.pack("<Q", len(new_sec)); h[104:112] = struct.pack("<Q", mr if new_raw is None else new_raw)
        return bytes(h) + new_sec + a[m0 + mz:]

    def remeta(m): return build(zstandard.ZstdCompressor(level=3, write_content_size=True).compress(m), len(m))

    def lebenc(v):
        o = bytearray()
        while True:
            c = v & 0x7F; v >>= 7
            if v: o.append(c | 0x80)
            else: o.append(c); return bytes(o)

    def lebdec(m, i):
        v = sh = 0
        while True:
            c = m[i]; i += 1; v |= (c & 0x7F) << sh
            if not c & 0x80: return v, i
            sh += 7
    # offsets inside the meta
    i = 4; recs = []
    for _ in range(int.from_bytes(M[:4], "little")):
        hl = int.from_bytes(M[i:i + 4], "little"); recs.append(i + 4 + hl); i += 4 + hl + 12
    nr = int.from_bytes(M[i:i + 8], "little"); runs_at = i + 8; j = runs_at; runs = []
    for _ in range(nr):
        g, j2 = lebdec(M, j); l, j3 = lebdec(M, j2); runs.append((j, j3, g, l)); j = j3
    for _ in range(1827): _, j = lebdec(M, j)
    blk_at = j; s0, k1 = lebdec(M, j); v0, k2 = lebdec(M, k1); s1, k3 = lebdec(M, k2)
    assert len(recs) >= 2 and nr >= 1
    def setlen(m, at, v): return m[:at] + struct.pack("<Q", v % M64) + m[at + 8:]
    m_len = setlen(setlen(M, recs[0], int.from_bytes(M[recs[0]:recs[0] + 8], "little") + (1 << 63)), recs[1], int.from_bytes(M[recs[1]:recs[1] + 8], "little") + (1 << 63))
    r0 = runs[0]; m_run = M[:r0[0]] + lebenc(M64 - 1) + lebenc(r0[2] + r0[3] + 1) + M[r0[1]:]
    m_sl = M[:blk_at] + lebenc(s0 + (1 << 63)) + M[k1:k2] + lebenc(s1 + (1 << 63)) + M[k3:]
    empty = zstandard.ZstdCompressor(write_content_size=True).compress(b"")
    skip = b"\x50\x2a\x4d\x18" + struct.pack("<I", 4) + b"abcd"
    cases = [("valid archive", a, True, True),
             ("meta + empty zstd frame", build(sec + empty), False, None),
             ("meta + skippable frame", build(sec + skip), False, None),
             ("meta + 9 garbage bytes", build(sec + bytes(range(1, 10))), False, None),
             ("meta truncated by 3 B", build(sec[:-3]), False, None),
             ("skippable frame first", build(skip + sec), False, None),
             ("record lengths +2^63 +2^63 (sum wraps)", remeta(m_len), True, False),
             ("run gap 2^64-1 (run end wraps)", remeta(m_run), True, False),
             ("slen +2^63 +2^63 (sum wraps)", remeta(m_sl), True, False)]
    v2 = os.path.expanduser("~/pubrepo/.wk/cr2v2_a/refrel3_cleanroom_v2/corrupt/meta_two_frames.rr3")
    if os.path.exists(v2): cases.append(("package v2 corrupt/meta_two_frames.rr3", open(v2, "rb").read(), False, None))
    bad = 0
    for name, b, w1, w2 in cases:
        r = check(b); ok = r["rule1_one_frame"] == w1 and (w2 is None or r["rule2_exact_sums"] == w2)
        bad += not ok
        print("%s %-42s rule1 %-5s rule2 %-5s frames %s+%s skip, first %s / libzstd %s / meta_bytes %s | %s" % (
            "ok " if ok else "BAD", name, r["rule1_one_frame"], r["rule2_exact_sums"], r.get("meta_frames"), r.get("meta_skippable_frames"),
            r.get("first_frame_size"), r.get("libzstd_frame_size"), r.get("meta_bytes"), r["detail"]))
    print("selftest: %d/%d as expected" % (len(cases) - bad, len(cases)))
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "stream":
        lim = 0; args = sys.argv[2:]
        if "--limit" in args: k = args.index("--limit"); lim = int(args[k + 1]); del args[k:k + 2]
        sys.exit(run_stream(args[0], args[1:], lim))
    if sys.argv[1] == "files":
        ds = sys.argv[2]; man = manifest(ds) if ds != "-" else {}; print("\t".join(COLS)); fails = 0
        for p in sys.argv[3:]:
            a = open(p, "rb").read(); r = check(a); nm = os.path.basename(p); sh = hashlib.sha256(a).hexdigest()
            r.update(dataset=ds, name=nm, member=p, sha256=sh, sha256_eq_manifest=man.get(nm.rsplit(".", 2)[0]) == sh if man else "-")
            print(line(r)); fails += not (r["rule1_one_frame"] and r["rule2_exact_sums"])
        sys.exit(1 if fails else 0)
    if sys.argv[1] == "selftest": sys.exit(selftest(sys.argv[2]))
    sys.exit(__doc__)
