"""specdec.py (v2.1) - a refrel3 v1 decoder written from FORMAT_V1_SPEC.md 1.0.1 only (section numbers in comments), with
the normative refusal reasons of §20 (stage + reason, detail in parentheses). Not shipped.
Used to check that the specification is complete (every archive, fetch and refusal of the package) and to produce the
test vectors with intermediate values.
  specdec.py decode <ref.fa> <archive> <out.fa>        exit 0 / 2 refused on open / 3 decode failed
  specdec.py check <package dir>                         all archives, fetches and corrupt cases of EXPECTED.json;
                                                         a refusal counts only with the expected stage and reason
XXH3 (seed 0) through an external xxh3 program (env XXH3_BIN: reads stdin, prints 16 hex digits)."""
import hashlib, json, os, subprocess, sys
import zstandard

XXH3_BIN = os.environ.get("XXH3_BIN", "xxh3_stdin")
MASK64 = (1 << 64) - 1


def xxh3(b):
    return int(subprocess.run([XXH3_BIN], input=bytes(b), capture_output=True, check=True).stdout.decode().strip(), 16)


class Refuse(Exception): pass                                       # open stage, str = reason (§5)
class Fail(Exception): pass                                         # a block fails a §15 check other than its XXH3
class HashFail(Exception): pass                                     # the block's stored XXH3 differs
class Refusal(Exception):                                           # reported refusal: stage + message
    def __init__(s, stage, msg): super().__init__(msg); s.stage, s.msg = stage, msg


# ---------------------------------------------------------------- §3 FASTA
def parse_fasta(f):
    recs, B, i = [], bytearray(), 0
    while i < len(f):
        if f[i] != 0x3E: raise Refuse("no header (byte %d)" % i)
        e = f.find(b"\n", i); e = len(f) if e < 0 else e; hdr = bytes(f[i + 1:e]); i = e + 1; ln = lw = 0; last = False
        while i < len(f) and f[i] != 0x3E:
            le = f.find(b"\n", i)
            if le < 0: raise Refuse("no final line end")
            w = le - i
            if last or w == 0 or (lw and w > lw): raise Refuse("irregular line layout")
            if not lw: lw = w
            elif w < lw: last = True
            B += f[i:le]; ln += w; i = le + 1
        recs.append((hdr, ln, lw))
    return recs, bytes(B)


def upper(b): return bytes(c - 32 if 0x61 <= c <= 0x7A else c for c in b)


def load_ref(path):
    _, B = parse_fasta(open(path, "rb").read()); R = upper(B); return R, hashlib.sha256(R).digest()


# ---------------------------------------------------------------- §0 / §7
def leb(buf, i):
    v = sh = 0
    while True:
        if i >= len(buf) or sh > 63: raise Refuse("leb")
        c = buf[i]; i += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v & MASK64, i
        sh += 7


def unzz(z): return (z >> 1) ^ -(z & 1)
def s64(u): u &= MASK64; return u - (1 << 64) if u >> 63 else u


# ---------------------------------------------------------------- §8
ALPHA = [104] * 4 + [6] * 10 + [6] * 17 + [6] * 16 + [104, 104, 3, 104, 2, 104] + [104] * 6 + [4, 104]
assert len(ALPHA) == 61 and sum(ALPHA) == 1827
CONT, DELTA, REP, ABS, SELF, FLIP = range(6)
def kclass(k): return 0 if k is None else 1 if k == CONT else 2 if k in (DELTA, REP, FLIP) else 3
def llc(ll): return 0 if ll == 0 else 1 if ll == 1 else 2 if ll <= 8 else 3
COMP = bytes(range(256)).translate(bytes.maketrans(b"ACGT", b"TGCA"))


# ---------------------------------------------------------------- §4 zstd frame (RFC 8878 §3.1)
def frame_header(b):
    """-> (content_size or None if absent, dict_id, header_size, checksum_flag) of the frame at b[0:], 'skip' for a
    skippable frame; raises ValueError if the header cannot be parsed."""
    if len(b) < 4: raise ValueError
    m = int.from_bytes(b[:4], "little")
    if m & 0xFFFFFFF0 == 0x184D2A50: return "skip"
    if m != 0xFD2FB528 or len(b) < 5: raise ValueError
    fhd = b[4]; fcsf, ss, ck, did = fhd >> 6, fhd >> 5 & 1, fhd >> 2 & 1, fhd & 3
    if fhd & 8: raise ValueError                                    # reserved bit
    pos = 5 + (0 if ss else 1); dl = (0, 1, 2, 4)[did]; fl = (1 if ss else 0, 2, 4, 8)[fcsf]
    if len(b) < pos + dl + fl: raise ValueError
    dict_id = int.from_bytes(b[pos:pos + dl], "little"); pos += dl
    cs = int.from_bytes(b[pos:pos + fl], "little") + (256 if fl == 2 else 0) if fl else None
    return cs, dict_id, pos + fl, ck


def first_frame_size(b):
    """compressed size of the first frame (header, blocks to Last_Block, checksum), None if it does not end inside b"""
    try: h = frame_header(b)
    except ValueError: return None
    if h == "skip": return 8 + int.from_bytes(b[4:8], "little") if len(b) >= 8 and 8 + int.from_bytes(b[4:8], "little") <= len(b) else None
    pos = h[2]
    while True:
        if pos + 3 > len(b): return None
        bh = int.from_bytes(b[pos:pos + 3], "little"); last, typ, sz = bh & 1, bh >> 1 & 3, bh >> 3
        if typ == 3: return None
        pos += 3 + (1 if typ == 1 else sz)
        if pos > len(b): return None
        if last: break
    pos += 4 if h[3] else 0
    return pos if pos <= len(b) else None


# ---------------------------------------------------------------- §5 open
class Archive: pass


def open_archive(a, R, rsha):
    X = Archive(); n = len(a); u32 = lambda o: int.from_bytes(a[o:o + 4], "little"); u64 = lambda o: int.from_bytes(a[o:o + 8], "little")
    if n < 138: raise Refuse("short file")
    if a[:8] != b"RFRL3V1\0": raise Refuse("magic")
    if u32(8) != 1: raise Refuse("version")
    X.Q = u32(12)
    if X.Q not in (1024, 2048, 4096, 16384): raise Refuse("block size")
    X.flags = u32(16)
    if X.flags & ~1: raise Refuse("unknown flags")
    if u32(20): raise Refuse("reserved")
    X.n, X.nb, X.fasta_xxh3, X.bases_xxh3 = u64(64), u64(72), u64(80), u64(88)
    mz, mr, hs, pl = u64(96), u64(104), u64(112), u64(120)
    L = a[136] | a[137] << 8; pstart = 138 + L + mz + hs
    if mz > n or hs > n or pl > n or pstart > n or pstart + pl != n: raise Refuse("section sizes")
    if X.nb != (X.n + X.Q - 1) // X.Q or (X.n and not X.nb): raise Refuse("block count")
    if hs != (X.nb * 8 if X.flags & 1 else 0): raise Refuse("hash section size")
    h = bytearray(a[:pstart]); h[128:136] = bytes(8)
    if xxh3(h) != u64(128): raise Refuse("header XXH3")
    if a[24:56] != rsha or u64(56) != len(R): raise Refuse("reference SHA-256 / size differs")
    mzb = a[138 + L:138 + L + mz]
    try: fh = frame_header(mzb)                                     # step 12
    except ValueError: raise Refuse("meta frame")
    cs = 0 if fh == "skip" else fh[0]
    if mr > 1 << 32 or cs != mr: raise Refuse("meta frame")
    if first_frame_size(mzb) != mz: raise Refuse("meta frame count")  # step 12a: exactly one frame
    if fh == "skip": M = b""                                        # step 13 (only reachable with meta_raw = 0)
    else:
        if fh[1]: raise Refuse("meta decompress (dictionary id %d)" % fh[1])
        try:
            dobj = zstandard.ZstdDecompressor().decompressobj(); M = dobj.decompress(mzb)
        except zstandard.ZstdError as e: raise Refuse("meta decompress (%s)" % e)
    if len(M) != mr: raise Refuse("meta decompress")
    i = 0
    def take(k):
        nonlocal i
        if i + k > len(M): raise Refuse("contig table")
        v = M[i:i + k]; i += k; return v
    nrec = int.from_bytes(take(4), "little")
    if nrec > len(M): raise Refuse("records")
    X.rec, bo = [], 0
    for _ in range(nrec):                                           # §4.1
        hl = int.from_bytes(take(4), "little"); hdr = bytes(take(hl)); ln = int.from_bytes(take(8), "little"); lw = int.from_bytes(take(4), "little")
        if ln and not lw: raise Refuse("contig table")
        X.rec.append((hdr, ln, lw, bo)); bo += ln
    if bo != X.n: raise Refuse("contig table")
    try:                                                            # §4.2
        nr = int.from_bytes(take(8), "little")
    except Refuse: raise Refuse("case runs")
    if nr > X.n: raise Refuse("case runs")
    X.low, last = [], 0
    try:
        for _ in range(nr):
            g, i = leb(M, i); l, i = leb(M, i)
            if last + g + l > X.n: raise Refuse("case runs")
            X.low.append((last + g, l)); last += g + l
    except Refuse: raise Refuse("case runs")
    X.freq = []                                                     # §4.3
    try:
        for c in range(61):
            fs = []
            for s in range(ALPHA[c]):
                f, i = leb(M, i)
                if f > 4096: raise Refuse("model tables")
                fs.append(f)
            if sum(fs) not in (0, 4096): raise Refuse("model tables")
            X.freq.append(fs)
    except Refuse: raise Refuse("model tables")
    X.cum, X.sym = [], []                                           # §6.2
    for fs in X.freq:
        cum, sym, acc = [], bytearray(4096), 0
        for s, f in enumerate(fs):
            cum.append(acc); sym[acc:acc + f] = bytes([s]) * f; acc += f
        X.cum.append(cum); X.sym.append(sym)
    X.off, X.st, prev = [0], [], None                               # §4.4
    try:
        for b in range(X.nb):
            sl, i = leb(M, i); v, i = leb(M, i)
            d = v & 1; delta = unzz(v >> 1)
            pred = 0 if b == 0 else (prev[0] - X.Q if prev[1] else prev[0] + X.Q)
            c = (pred + delta) & MASK64; X.st.append((c, d)); prev = (c, d); X.off.append(X.off[-1] + sl)
    except Refuse: raise Refuse("block table")
    if i != len(M) or X.off[-1] != pl: raise Refuse("block table")
    X.hashes = a[138 + L + mz:138 + L + mz + hs] if X.flags & 1 else None
    X.P = a[pstart:]; X.R = R
    return X


# ---------------------------------------------------------------- §6 rANS
class Dec:
    def __init__(s, p, trace=None):
        if len(p) < 3: raise Fail("short stream")
        s.p, s.x, s.pos, s.trace = p, p[0] | p[1] << 8 | p[2] << 16, 3, trace
        if trace is not None: trace.append({"event": "init", "x": s.x, "pos": s.pos})
    def renorm(s):
        while s.x < 65536:
            if s.pos >= len(s.p): raise Fail("exhausted")
            s.x = (s.x << 8) | s.p[s.pos]; s.pos += 1
    def sym(s, X, c):
        slot = s.x & 4095; v = X.sym[c][slot]; f = X.freq[c][v]
        if not f: raise Fail("zero frequency")
        s.x = f * (s.x >> 12) + slot - X.cum[c][v]; s.renorm()
        if s.trace is not None: s.trace.append({"event": "symbol", "ctx": c, "sym": v, "x": s.x, "pos": s.pos})
        return v
    def bits(s, k):
        v = sh = 0; k0 = k
        while k:
            t = min(16, k); b = s.x & ((1 << t) - 1); s.x >>= t; s.renorm(); v |= b << sh; sh += t; k -= t
        if s.trace is not None and k0: s.trace.append({"event": "bits", "n": k0, "value": v, "x": s.x, "pos": s.pos})
        return v
    def value(s, X, c):                                             # §7.1
        sy = s.sym(X, c)
        if sy < 16: return sy
        e = (sy - 16) // 4 + 4; m = (sy - 16) & 3
        return (1 << e) | (m << (e - 2)) | s.bits(e - 2)
    def finish(s):
        if s.x != 65536 or s.pos != len(s.p): raise Fail("final state")


# ---------------------------------------------------------------- §9-§11 block
def decode_block(X, b, trace=None, ops=None):
    blen = min(X.Q, X.n - b * X.Q); R = X.R; nR = len(R)
    d = Dec(X.P[X.off[b]:X.off[b + 1]], trace)
    cache = [X.st[b]]; prevk = None; o = 0; out = bytearray(blen)
    def refbase(g, o):
        c, dr = g; q = s64(c) - o if dr else s64(c) + o
        if q < 0 or q >= nR: return 4
        r = COMP[R[q]] if dr else R[q]
        return b"ACGT".find(bytes([r])) if r in b"ACGT" else 4
    def push(g):
        if g in cache: cache.remove(g)
        elif len(cache) == 4: cache.pop()
        cache.insert(0, g)
    while o < blen:
        LL = d.value(X, 0 + kclass(prevk))
        if LL > blen - o: raise Fail("LL")
        p1 = p2 = 16
        for j in range(LL):
            if LL <= 8: ctx = 4 + 2 * refbase(cache[0], o + j) + (1 if j == 0 else 0)
            else: ctx = 14 + (16 if p1 == 16 else p1 if p2 == 16 else 4 * p2 + p1)
            s = d.sym(X, ctx)
            out[o + j] = b"ACGTN"[s] if s < 5 else d.bits(8)
            p2 = p1; p1 = s if s < 4 else 0
        if LL and ops is not None: ops.append(("literal", o, LL))
        o += LL
        if o == blen: break
        kind = d.sym(X, 31 + 4 * llc(LL) + kclass(prevk))
        dd = dist = 0
        if kind == DELTA: dd = unzz(d.value(X, 47 if LL == 0 else 48))
        elif kind == REP:
            i = 1 + d.sym(X, 49); dd = unzz(d.value(X, 50))
            if i >= len(cache): raise Fail("rep index")
        elif kind == ABS: dr = d.sym(X, 51); p = d.bits(32)
        elif kind == SELF: dist = d.value(X, 52)
        elif kind == FLIP:
            i = d.sym(X, 59); dd = unzz(d.value(X, 60))
            if i >= len(cache): raise Fail("flip index")
        elif kind != CONT: raise Fail("kind")
        ln = d.value(X, 53 + kind) + 12
        if ln > blen - o: raise Fail("length")
        if kind == SELF:
            if dist == 0 or dist > o: raise Fail("self")
            for j in range(ln): out[o + j] = out[o - dist + j]
            if ops is not None: ops.append(("self", o, ln, dist))
        else:
            if kind == FLIP: c, gd = cache[i]; dr = 1 - gd; p = (s64(c) - o if gd else s64(c) + o) + dd
            elif kind != ABS:
                c, dr = cache[i if kind == REP else 0]; p = (s64(c) - o - ln + 1 if dr else s64(c) + o) + dd
            if p < 0 or p > nR or ln > nR - p: raise Fail("copy bounds")
            out[o:o + ln] = R[p:p + ln] if not dr else R[p:p + ln][::-1].translate(COMP)
            push((((p + ln - 1 + o) if dr else (p - o)) & MASK64, dr))
            if ops is not None: ops.append((["CONT", "DELTA", "REP", "ABS", "SELF", "FLIP"][kind], o, ln, p, dr))
        o += ln; prevk = kind
    d.finish()
    if X.hashes is not None and xxh3(out) != int.from_bytes(X.hashes[8 * b:8 * b + 8], "little"): raise HashFail()
    return bytes(out)


# ---------------------------------------------------------------- §13 / §14
def block_or_refuse(X, b, stage):
    try: return decode_block(X, b)
    except Fail as e: raise Refusal(stage, "block (block %d: %s)" % (b, e))
    except HashFail: raise Refusal(stage, ("block XXH3" if stage == "decode" else "block") + " (block %d)" % b)


def full(X):
    U = bytearray()
    for b in range(X.nb): U += block_or_refuse(X, b, "decode")
    for s, l in X.low:
        for x in range(s, s + l): U[x] |= 0x20
    fa = bytearray()
    for hdr, ln, lw, bo in X.rec:
        fa += b">" + hdr + b"\n"
        for x in range(0, ln, lw if lw else 1): fa += U[bo + x:bo + min(ln, x + lw)] + b"\n"
    if xxh3(fa) != X.fasta_xxh3: raise Refusal("decode", "FASTA XXH3")
    return bytes(fa)


def fetch(X, name, start0, end0):
    r = next((r for r in X.rec if r[0].split(b" ")[0].split(b"\t")[0] == name), None)
    if r is None: raise Refusal("fetch", "no contig")
    if not (0 <= start0 < end0 <= r[1]): raise Refusal("fetch", "bad range")
    s, e = r[3] + start0, r[3] + end0; out = bytearray()
    for b in range(s // X.Q, (e - 1) // X.Q + 1):
        blk = block_or_refuse(X, b, "fetch"); bs = b * X.Q; out += blk[max(s, bs) - bs:min(e, bs + X.Q) - bs]
    for ls, ll in X.low:
        for x in range(max(s, ls), min(e, ls + ll)): out[x - s] |= 0x20
    return bytes(out)


def reason_ok(msg, reason):                                         # §5 matching rule
    return msg == reason or msg.startswith(reason + " (")


def check(P):
    exp = json.load(open(os.path.join(P, "EXPECTED.json"))); refs = {}
    def ref(p):
        if p not in refs: refs[p] = load_ref(os.path.join(P, p))
        return refs[p]
    okd = okf = nf = okr = 0
    for a in exp["archives"]:
        R, rs = ref(a["reference"]); X = open_archive(open(os.path.join(P, a["archive"]), "rb").read(), R, rs)
        fa = full(X); okd += hashlib.sha256(fa).hexdigest() == a["fasta_sha256"] and len(fa) == a["fasta_bytes"]
        for row in list(open(os.path.join(P, a["fetch"])))[1:]:
            c, s, ln, h = row.rstrip("\n").split("\t"); nf += 1
            okf += hashlib.sha256(fetch(X, c.encode(), int(s), int(s) + int(ln))).hexdigest() == h
    for c in exp["corrupt"]:
        stage = msg = None
        try:
            R, rs = ref(c["reference"])
            full(open_archive(open(os.path.join(P, c["archive"]), "rb").read(), R, rs))
        except Refuse as e: stage, msg = "open", str(e)
        except Refusal as e: stage, msg = e.stage, e.msg
        want = c["reader_response"]; ok = stage == want["stage"] and msg is not None and reason_ok(msg, want["reason"])
        okr += ok
        print("CORRUPT", c["archive"], stage, "|", msg or "NOT REFUSED", "| expected:", want["stage"], want["reason"], "OK" if ok else "MISMATCH")
    print(f"spec decoder: decode {okd}/{len(exp['archives'])}, fetch {okf}/{nf}, refused with expected stage and reason {okr}/{len(exp['corrupt'])}")
    return okd == len(exp["archives"]) and okf == nf and okr == len(exp["corrupt"])


if __name__ == "__main__":
    if sys.argv[1] == "check": sys.exit(0 if check(sys.argv[2]) else 1)
    if sys.argv[1] == "decode":
        try:
            R, rs = load_ref(sys.argv[2]); X = open_archive(open(sys.argv[3], "rb").read(), R, rs)
        except Refuse as e: print("refused:", e, file=sys.stderr); sys.exit(2)
        try: fa = full(X)
        except Refusal as e: print("decode failed:", e.msg, file=sys.stderr); sys.exit(3)
        open(sys.argv[4], "wb").write(fa)
