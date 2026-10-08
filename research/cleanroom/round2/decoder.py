#!/usr/bin/env python3
"""refrel3 v1 clean-room decoder, written only from FORMAT_V1_SPEC.md.

Libraries: zstandard (python-zstandard, ZstdDecompressor.decompressobj / get_frame_parameters)
           xxhash (xxhash.xxh3_64_intdigest)   hashlib (sha256)

CLI:
  decoder.py decode ARCHIVE REFERENCE OUT.fa
  decoder.py fetch  ARCHIVE REFERENCE NAME START0 LENGTH
Exit status 0 on success, 2 on refusal (message on stderr, stage: open/decode).
"""
import hashlib
import os
import struct
import sys

import xxhash
import zstandard

MASK64 = (1 << 64) - 1
M = 4096
L_LO = 1 << 16
MAGIC = b"RFRL3V1\x00"
VALID_Q = (1024, 2048, 4096, 16384)
ALPHA = [104] * 4 + [6] * 10 + [6] * 17 + [6] * 16 + [104, 104, 3, 104, 2, 104] + [104] * 6 + [4, 104]
assert len(ALPHA) == 61 and sum(ALPHA) == 1827
CONT, DELTA, REP, ABS, SELF, FLIP = range(6)
KIND_NAMES = ["CONT", "DELTA", "REP", "ABS", "SELF", "FLIP"]
COMP = bytes.maketrans(b"ACGT", b"TGCA")


class Refused(Exception):
    def __init__(self, stage, message):
        super().__init__(message)
        self.stage = stage
        self.message = message


class BlockFail(Exception):
    pass


def xxh3(b):
    return xxhash.xxh3_64_intdigest(b, seed=0)


def s64(v):
    v &= MASK64
    return v - (1 << 64) if v >> 63 else v


def unzz(z):
    z &= MASK64
    return s64((z >> 1) ^ (-(z & 1) & MASK64))


def leb128(buf, pos, end):
    """Returns (value, newpos) or raises ValueError (§0)."""
    v = 0
    shift = 0
    while True:
        if pos >= end:
            raise ValueError("LEB128 past end")
        if shift > 63:
            raise ValueError("LEB128 too long")
        b = buf[pos]
        pos += 1
        v |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            return v & MASK64, pos


# ---------------------------------------------------------------- FASTA (§3.1)

def parse_fasta(data):
    """Strict §3.1 parse. Returns list of (header_bytes, bases_bytes, lw)."""
    recs = []
    if len(data) == 0:
        return recs
    if data[0:1] != b">":
        raise ValueError("FASTA does not start with '>'")
    if data[-1:] != b"\n":
        raise ValueError("FASTA last line lacks LF")
    lines = data[:-1].split(b"\n")
    cur = None
    short_seen = False
    for ln in lines:
        if ln[:1] == b">":
            if cur is not None:
                recs.append((cur[0], b"".join(cur[1]), cur[2]))
            cur = [ln[1:], [], 0]
            short_seen = False
        else:
            if len(ln) == 0:
                raise ValueError("empty sequence line")
            if short_seen:
                raise ValueError("sequence line after a shorter line")
            if cur[2] == 0:
                cur[2] = len(ln)
            elif len(ln) > cur[2]:
                raise ValueError("sequence line longer than line width")
            elif len(ln) < cur[2]:
                short_seen = True
            cur[1].append(ln)
    if cur is not None:
        recs.append((cur[0], b"".join(cur[1]), cur[2]))
    return recs


UPPER = bytes(range(0x61)) + bytes(range(0x41, 0x5B)) + bytes(range(0x7B, 256))
assert len(UPPER) == 256

_REF_CACHE = {}


def load_reference(path):
    """Decoded reference R (§3.2) and its SHA-256."""
    key = os.path.realpath(path)
    if key in _REF_CACHE:
        return _REF_CACHE[key]
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        recs = parse_fasta(data)
    except ValueError as e:
        raise Refused("open", "refused: reference FASTA layout (%s)" % e)
    R = b"".join(r[1] for r in recs).translate(UPPER)
    res = (R, hashlib.sha256(R).digest())
    _REF_CACHE[key] = res
    return res


# ---------------------------------------------------------------- open (§2, §4, §5)

class Archive:
    pass


def open_archive(path, ref_path):
    with open(path, "rb") as fh:
        f = fh.read()
    size = len(f)
    def refuse(msg):
        raise Refused("open", "refused: " + msg)
    # 1
    if size < 138:
        refuse("short file")
    # 2
    if f[0:8] != MAGIC:
        refuse("magic")
    version, Q, flags, reserved = struct.unpack_from("<IIII", f, 8)
    ref_sha = f[24:56]
    (ref_bases, n, nblocks, fasta_xxh3, bases_xxh3, meta_bytes, meta_raw,
     hash_bytes, payload_bytes, header_xxh3) = struct.unpack_from("<10Q", f, 56)
    # 3..6
    if version != 1:
        refuse("version")
    if Q not in VALID_Q:
        refuse("block size")
    if flags & ~1:
        refuse("unknown flags")
    if reserved != 0:
        refuse("reserved")
    # 7
    L = struct.unpack_from("<H", f, 136)[0]
    payload_start = 138 + L + meta_bytes + hash_bytes
    if not (meta_bytes <= size and hash_bytes <= size and payload_bytes <= size and payload_start <= size
            and payload_start + payload_bytes == size):
        refuse("section sizes")
    # 8
    if nblocks != (n + Q - 1) // Q or (n > 0 and nblocks == 0):
        refuse("block count")
    # 9
    if hash_bytes != (8 * nblocks if flags & 1 else 0):
        refuse("hash section size")
    # 10
    hdr = bytearray(f[0:payload_start])
    hdr[128:136] = b"\x00" * 8
    if xxh3(bytes(hdr)) != header_xxh3:
        refuse("header XXH3")
    # 11
    R, rsha = load_reference(ref_path)
    if rsha != ref_sha or len(R) != ref_bases:
        refuse("reference SHA-256 / size differs (wrong reference)")
    # 12
    meta_off = 138 + L
    meta = f[meta_off:meta_off + meta_bytes]
    if meta_raw > (1 << 32):
        refuse("meta frame")
    try:
        fp = zstandard.get_frame_parameters(meta)
    except zstandard.ZstdError:
        refuse("meta frame")
    if fp.content_size != meta_raw or fp.dict_id != 0:
        refuse("meta frame")
    # 13 (and §4: exactly one frame, nothing after it)
    try:
        dobj = zstandard.ZstdDecompressor().decompressobj()
        raw = dobj.decompress(meta)
        eof = dobj.eof
        unused = dobj.unused_data
    except zstandard.ZstdError:
        refuse("meta decompress")
    if not eof:
        refuse("meta decompress")
    if len(unused) != 0:
        refuse("meta frame (meta section is not exactly one zstd frame)")
    if len(raw) != meta_raw:
        refuse("meta decompress")
    end = len(raw)
    pos = 0
    # 14 contig table
    recs = []
    try:
        if pos + 4 > end:
            raise ValueError
        nrec = struct.unpack_from("<I", raw, pos)[0]; pos += 4
        if nrec > meta_raw:
            raise ValueError
        tot = 0
        for _ in range(nrec):
            if pos + 4 > end:
                raise ValueError
            hlen = struct.unpack_from("<I", raw, pos)[0]; pos += 4
            if pos + hlen + 12 > end:
                raise ValueError
            hdrb = raw[pos:pos + hlen]; pos += hlen
            ln, lw = struct.unpack_from("<QI", raw, pos); pos += 12
            if ln > 0 and lw == 0:
                raise ValueError
            recs.append((hdrb, ln, lw, tot))
            tot += ln
        if tot != n:
            raise ValueError
    except (ValueError, struct.error):
        refuse("records / contig table")
    # 15 lower-case runs
    runs = []
    try:
        if pos + 8 > end:
            raise ValueError
        nruns = struct.unpack_from("<Q", raw, pos)[0]; pos += 8
        if nruns > n:
            raise ValueError
        e = 0
        for _ in range(nruns):
            gap, pos = leb128(raw, pos, end)
            ln, pos = leb128(raw, pos, end)
            s = e + gap
            e = s + ln
            if e > n:
                raise ValueError
            runs.append((s, ln))
    except (ValueError, struct.error):
        refuse("case runs")
    # 16 model tables
    freqs = []
    try:
        for c in range(61):
            fc = []
            for _ in range(ALPHA[c]):
                v, pos = leb128(raw, pos, end)
                if v > 4096:
                    raise ValueError
                fc.append(v)
            if sum(fc) not in (0, 4096):
                raise ValueError
            freqs.append(fc)
    except ValueError:
        refuse("model tables")
    # 17 block table
    blocks = []
    try:
        poff = 0
        prev = None
        for b in range(nblocks):
            slen, pos = leb128(raw, pos, end)
            v, pos = leb128(raw, pos, end)
            d = v & 1
            q = v >> 1
            delta = unzz(q)
            if b == 0:
                pred = 0
            elif prev[1] == 1:
                pred = prev[0] - Q
            else:
                pred = prev[0] + Q
            c = s64(pred + delta)
            blocks.append((poff, slen, c, d))
            prev = (c, d)
            poff += slen
        if pos != end:
            raise ValueError
        if poff != payload_bytes:
            raise ValueError
    except ValueError:
        refuse("block table")

    a = Archive()
    a.f = f; a.Q = Q; a.flags = flags; a.n = n; a.nblocks = nblocks
    a.fasta_xxh3 = fasta_xxh3; a.bases_xxh3 = bases_xxh3; a.header_xxh3 = header_xxh3
    a.L = L; a.ref_name = f[138:138 + L]
    a.meta_off = meta_off; a.meta_bytes = meta_bytes; a.meta_raw = meta_raw
    a.hash_off = meta_off + meta_bytes; a.hash_bytes = hash_bytes
    a.payload_start = payload_start; a.payload_bytes = payload_bytes
    a.R = R; a.recs = recs; a.runs = runs; a.freqs = freqs; a.blocks = blocks
    a.hashes = None
    if flags & 1:
        a.hashes = list(struct.unpack_from("<%dQ" % nblocks, f, a.hash_off)) if nblocks else []
    # §6.2 tables
    a.cum = []
    a.sym = []
    for c in range(61):
        fc = freqs[c]
        cum = [0] * len(fc)
        acc = 0
        st = bytearray(4096)
        for s, fv in enumerate(fc):
            cum[s] = acc
            st[acc:acc + fv] = bytes([s]) * fv
            acc += fv
        a.cum.append(cum)
        a.sym.append(bytes(st))
    return a


# ---------------------------------------------------------------- rANS (§6)

class RANS:
    def __init__(self, p, trace=None):
        self.p = p
        self.slen = len(p)
        if self.slen < 3:
            raise BlockFail("stream shorter than 3 bytes")
        self.x = p[0] | (p[1] << 8) | (p[2] << 16)
        self.pos = 3
        self.trace = trace
        self.nsym = 0
        self.nbits = 0
        if trace is not None:
            trace.append({"event": "init", "x": self.x, "pos": 3})

    def renorm(self):
        x = self.x
        while x < L_LO:
            if self.pos == self.slen:
                raise BlockFail("stream exhausted")
            x = (x << 8) | self.p[self.pos]
            self.pos += 1
        self.x = x

    def sym(self, a, c):
        x = self.x
        slot = x & 4095
        s = a.sym[c][slot]
        fc = a.freqs[c]
        f = fc[s] if s < len(fc) else 0
        if f == 0:
            raise BlockFail("symbol with frequency 0 (context %d)" % c)
        self.x = f * (x >> 12) + slot - a.cum[c][s]
        self.renorm()
        self.nsym += 1
        if self.trace is not None:
            self.trace.append({"event": "symbol", "ctx": c, "sym": s, "x": self.x, "pos": self.pos})
        return s

    def bits(self, k):
        k0 = k
        v = 0
        sh = 0
        while k > 0:
            t = 16 if k > 16 else k
            b = self.x & ((1 << t) - 1)
            self.x >>= t
            self.renorm()
            v |= b << sh
            sh += t
            k -= t
        self.nbits += 1
        if self.trace is not None:
            self.trace.append({"event": "bits", "n": k0, "value": v, "x": self.x, "pos": self.pos})
        return v

    def value(self, a, c):
        s = self.sym(a, c)
        if s < 16:
            return s
        e = (s - 16) // 4 + 4
        m = (s - 16) % 4
        nb = e - 2
        return (1 << e) + m * (1 << (e - 2)) + self.bits(nb)

    def finish(self):
        if self.x != L_LO or self.pos != self.slen:
            raise BlockFail("final state %d / %d of %d bytes consumed" % (self.x, self.pos, self.slen))


# ---------------------------------------------------------------- block decoder (§8-§11, §17)

def kclass(k):
    if k is None:
        return 0
    if k == CONT:
        return 1
    if k in (DELTA, REP, FLIP):
        return 2
    return 3


def llc(LL):
    return 0 if LL == 0 else 1 if LL == 1 else 2 if LL <= 8 else 3


LIT = b"ACGTN"
RB = [4] * 256
for _i, _ch in enumerate(b"ACGT"):
    RB[_ch] = _i
RBC = [4] * 256  # refbase of the complemented byte
for _ch, _cc in zip(b"ACGT", b"TGCA"):
    RBC[_ch] = RB[_cc]


def decode_block(a, b, trace=None, events=None):
    poff, slen, c0, dir0 = a.blocks[b]
    Q = a.Q
    blen = min(Q, a.n - b * Q)
    R = a.R
    nR = len(R)
    st = a.f[a.payload_start + poff: a.payload_start + poff + slen]
    rs = RANS(st, trace)
    out = bytearray(blen)
    cache = [(c0, dir0)]
    prevk = None
    o = 0
    while o < blen:
        LL = rs.value(a, 0 + kclass(prevk))
        if LL > blen - o:
            raise BlockFail("LL > blen - o")
        p1 = p2 = 16
        for j in range(LL):
            if LL <= 8:
                gc, gd = cache[0]
                q = s64(gc - (o + j)) if gd == 1 else s64(gc + (o + j))
                if q < 0 or q >= nR:
                    rb = 4
                else:
                    rb = RBC[R[q]] if gd == 1 else RB[R[q]]
                ctx = 4 + 2 * rb + (1 if j == 0 else 0)
            else:
                ctx = 14 + (16 if p1 == 16 else (p1 if p2 == 16 else 4 * p2 + p1))
            s = rs.sym(a, ctx)
            out[o + j] = LIT[s] if s < 5 else rs.bits(8)
            p2 = p1
            p1 = s if s < 4 else 0
        if events is not None and LL > 0:
            events.append({"type": "literal_run", "offset": o, "length": LL})
        o += LL
        if o == blen:
            break
        kind = rs.sym(a, 31 + 4 * llc(LL) + kclass(prevk))
        d = 0
        dist = 0
        i = 0
        if kind == DELTA:
            d = unzz(rs.value(a, 47 if LL == 0 else 48))
        elif kind == REP:
            i = 1 + rs.sym(a, 49)
            d = unzz(rs.value(a, 50))
            if i >= len(cache):
                raise BlockFail("REP index >= nc")
        elif kind == ABS:
            dr = rs.sym(a, 51)
            p = rs.bits(32)
        elif kind == SELF:
            dist = rs.value(a, 52)
        elif kind == FLIP:
            i = rs.sym(a, 59)
            d = unzz(rs.value(a, 60))
            if i >= len(cache):
                raise BlockFail("FLIP index >= nc")
        elif kind != CONT:
            raise BlockFail("kind symbol >= 6")
        ln = rs.value(a, 53 + kind) + 12
        if ln > blen - o:
            raise BlockFail("len > blen - o")
        if kind == SELF:
            if dist == 0 or dist > o:
                raise BlockFail("SELF dist 0 or > o")
            for j in range(ln):
                out[o + j] = out[o - dist + j]
            if events is not None:
                events.append({"type": "SELF", "offset": o, "length": ln, "distance": dist,
                               "source_offset": o - dist})
        else:
            if kind == FLIP:
                gc, gd = cache[i]
                dr = 1 - gd
                locus = s64(gc + o) if gd == 0 else s64(gc - o)
                p = s64(locus + d)
            elif kind != ABS:
                gc, gd = cache[i if kind == REP else 0]
                dr = gd
                ex = s64(gc + o) if gd == 0 else s64(gc - o - ln + 1)
                p = s64(ex + d)
            if p < 0 or p > nR or ln > nR - p:
                raise BlockFail("reference copy outside R")
            if dr == 0:
                out[o:o + ln] = R[p:p + ln]
                diag = s64(p - o)
            else:
                out[o:o + ln] = R[p:p + ln][::-1].translate(COMP)
                diag = s64(p + ln - 1 + o)
            g = (diag, dr)
            if g in cache:
                cache.remove(g)
            elif len(cache) == 4:
                cache.pop()
            cache.insert(0, g)
            if events is not None:
                events.append({"type": KIND_NAMES[kind], "offset": o, "length": ln, "ref_start": p,
                               "strand": "forward" if dr == 0 else "reverse_complement",
                               "diagonal": diag, "cache_after": [list(x) for x in cache]})
        o += ln
        prevk = kind
    rs.finish()
    return bytes(out), rs


def decode_block_checked(a, b):
    try:
        out, _ = decode_block(a, b)
    except BlockFail as e:
        raise Refused("decode", "block decode failed (block %d: %s)" % (b, e))
    if a.hashes is not None and xxh3(out) != a.hashes[b]:
        raise Refused("decode", "block XXH3 mismatch (block %d)" % b)
    return out


# ---------------------------------------------------------------- full decode (§13), fetch (§14)

def full_decode(archive, ref):
    a = open_archive(archive, ref)
    U = bytearray()
    for b in range(a.nblocks):
        U += decode_block_checked(a, b)
    for s, ln in a.runs:
        for x in range(s, s + ln):
            U[x] |= 0x20
    parts = []
    for hdrb, ln, lw, boff in a.recs:
        parts.append(b">" + hdrb + b"\n")
        if ln:
            seq = U[boff:boff + ln]
            for k in range(0, ln, lw):
                parts.append(bytes(seq[k:k + lw]) + b"\n")
    fa = b"".join(parts)
    if xxh3(fa) != a.fasta_xxh3:
        raise Refused("decode", "FASTA XXH3 differs from the header")
    return fa


def record_name(h):
    for i, ch in enumerate(h):
        if ch == 0x20 or ch == 0x09:
            return h[:i]
    return h


def fetch(a, name, start0, length):
    """a = already opened archive (open checks done)."""
    if isinstance(name, str):
        name = name.encode("latin-1")
    rec = None
    for r in a.recs:
        if record_name(r[0]) == name:
            rec = r
            break
    if rec is None:
        raise Refused("fetch", "unknown record name")
    end0 = start0 + length
    if not (0 <= start0 < end0 <= rec[1]):
        raise Refused("fetch", "invalid interval")
    lo = rec[3] + start0
    hi = rec[3] + end0
    Q = a.Q
    buf = bytearray()
    b0 = lo // Q
    for b in range(b0, (hi - 1) // Q + 1):
        buf += decode_block_checked(a, b)
    base = b0 * Q
    res = bytearray(buf[lo - base: hi - base])
    for s, ln in a.runs:
        if s >= hi:
            break
        e = s + ln
        if e <= lo:
            continue
        for x in range(max(s, lo), min(e, hi)):
            res[x - lo] |= 0x20
    return bytes(res)


def main(argv):
    try:
        if argv[1] == "decode":
            fa = full_decode(argv[2], argv[3])
            tmp = argv[4] + ".part"
            with open(tmp, "wb") as fh:
                fh.write(fa)
            os.replace(tmp, argv[4])
        elif argv[1] == "fetch":
            a = open_archive(argv[2], argv[3])
            sys.stdout.buffer.write(fetch(a, argv[4], int(argv[5]), int(argv[6])) + b"\n")
        else:
            print(__doc__, file=sys.stderr)
            return 1
    except Refused as e:
        print("%s: %s" % (e.stage, e.message), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
