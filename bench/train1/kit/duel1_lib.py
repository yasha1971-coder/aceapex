"""DUEL-1 phase A shared helpers: names manifest, PAF (cg:Z) index + CIGAR walk.

Coordinate conventions
----------------------
Combined PAF hprc465vsgrch38.aln.paf.gz: query = assembly contig (PanSN
SAMPLE#hap#contig, == panvram contig name), target = GRCh38#0#chrN.
cg:Z CIGAR ops over query->target: '='/'X' consume both, 'I' consumes query,
'D' consumes target (standard PAF). qs<qe, ts<te always; strand '-' means the
query segment is reverse-complemented relative to the target.
"""
import gzip
import re

CIG = re.compile(rb"(\d+)([=XID])")
_RC = bytes.maketrans(b"ACGTNacgtn", b"TGCANtgcan")


def rc(seq: bytes) -> bytes:
    return seq.translate(_RC)[::-1]


def load_names(tsv_path):
    """manifest tsv -> list of dicts {manifest, sample, hap_label, pansn, pansn_hap}.
    pansn_hap is '1' or '2' (PanSN haplotype index == VCF GT position)."""
    rows = []
    with open(tsv_path) as fh:
        for ln in fh:
            if ln.startswith("#") or not ln.strip():
                continue
            c = ln.rstrip("\n").split("\t")
            manifest, sample, hap_label, pansn = c[0], c[2], c[3], c[4]
            sample = re.sub(r"^y1_", "", sample)
            pansn = re.sub(r"^y1_", "", pansn)
            m = re.search(r"#([12])$", pansn)
            rows.append(dict(manifest=manifest, sample=sample, hap_label=hap_label,
                             pansn=pansn, pansn_hap=(m.group(1) if m else None)))
    return rows


def vcf_samples_from_header(chrom_header_path):
    with open(chrom_header_path) as fh:
        line = fh.readline().rstrip("\n")
    return line.split("\t")[9:]


class PafIndex:
    """One streaming pass over the decompressed PAF. Keeps, per query contig,
    a list of blocks (ts, te, strand, qs, qe, byte_offset) so a later random
    seek can re-read the single line and walk its CIGAR. Also accumulates the
    union of query-covered bases per contig (A5 component c) and query lengths.

    We index by *query contig* (SAMPLE#hap#contig). The caller groups contigs
    into haplotypes by the SAMPLE#hap prefix.
    """

    def __init__(self):
        self.blocks = {}      # qcontig -> list[(ts,te,strand,qs,qe,offset,tchrom)]
        self.qlen = {}        # qcontig -> query length
        self.qcov = {}        # qcontig -> list[(qs,qe)] (to be merged)

    @staticmethod
    def open_text(path):
        if path.endswith(".gz"):
            return gzip.open(path, "rb")
        return open(path, "rb")

    def build(self, paf_path, want_prefixes=None, progress=None):
        """want_prefixes: iterable of 'SAMPLE#hap#' byte prefixes to keep (None=all)."""
        pref = None
        if want_prefixes is not None:
            pref = tuple(p.encode() if isinstance(p, str) else p for p in want_prefixes)
        off = 0
        n = 0
        with self.open_text(paf_path) as fh:
            for raw in fh:
                ln = len(raw)
                start = off
                off += ln
                n += 1
                if progress and n % 2_000_000 == 0:
                    progress(n, start)
                if pref is not None and not raw.startswith(pref):
                    continue
                f = raw.rstrip(b"\n").split(b"\t")
                if len(f) < 12:
                    continue
                q = f[0].decode()
                qlen = int(f[1]); qs = int(f[2]); qe = int(f[3])
                strand = f[4].decode()
                tchrom = f[5].decode().split("#")[-1]  # GRCh38#0#chrY -> chrY
                ts = int(f[7]); te = int(f[8])
                self.qlen[q] = qlen
                self.blocks.setdefault(q, []).append((ts, te, strand, qs, qe, start, tchrom))
                self.qcov.setdefault(q, []).append((qs, qe))
        return n

    @staticmethod
    def collect_cigars(paf_gz, needed_offsets, progress=None):
        """Single streaming pass over the (gzipped) PAF, capturing the fields+cigar for
        every decompressed-stream byte offset in `needed_offsets`. Avoids both a 30 GB
        decompressed file and O(offset) gzip.seek per window. Returns {offset:(fields,cigar)}.
        """
        need = set(needed_offsets)
        out = {}
        off = 0
        n = 0
        opener = gzip.open if str(paf_gz).endswith(".gz") else open
        with opener(paf_gz, "rb") as fh:
            for raw in fh:
                start = off
                off += len(raw)
                n += 1
                if progress and n % 2_000_000 == 0:
                    progress(n)
                if start in need:
                    f = raw.rstrip(b"\n").split(b"\t")
                    cg = None
                    for t in f[12:]:
                        if t.startswith(b"cg:Z:"):
                            cg = t[5:]; break
                    out[start] = (f, cg)
                    if len(out) == len(need):
                        break
        return out

    def read_cigar(self, paf_path, offset):
        # offset is a byte offset into the DECOMPRESSED stream (build() accumulates
        # len(decompressed line)). Seeking must therefore use the PLAIN file, never a
        # gzip object (gzip.seek re-decompresses from the start -> O(offset) per call).
        if paf_path.endswith(".gz"):
            raise ValueError("read_cigar needs the decompressed PAF (plain), not .gz; "
                             "offsets are decompressed-stream offsets")
        with open(paf_path, "rb") as fh:
            fh.seek(offset)
            raw = fh.readline()
        f = raw.rstrip(b"\n").split(b"\t")
        cg = None
        for t in f[12:]:
            if t.startswith(b"cg:Z:"):
                cg = t[5:]
                break
        return f, cg

    @staticmethod
    def merge_len(intervals):
        if not intervals:
            return 0
        iv = sorted(intervals)
        tot = 0
        cs, ce = iv[0]
        for s, e in iv[1:]:
            if s > ce:
                tot += ce - cs
                cs, ce = s, e
            else:
                ce = max(ce, e)
        tot += ce - cs
        return tot


def map_target_window(cigar, blk_ts, blk_qs, strand, qlen, tw0, tw1):
    """Walk CIGAR to map GRCh38 target interval [tw0,tw1) -> query interval.
    Returns (q0, q1) in *forward* query coordinates (q0<q1), or None if the
    window is not fully covered by aligned (=/X) columns (i.e. falls in a pure
    deletion / outside). Positions are block-local absolute (blk_qs/blk_ts base).
    """
    tpos = blk_ts
    qpos = blk_qs
    q_at_tw0 = None
    q_at_tw1 = None
    for mnum, mop in CIG.findall(cigar):
        num = int(mnum)
        op = mop  # bytes
        if op in (b"=", b"X"):
            # both advance; map any target coord in [tpos,tpos+num)
            if q_at_tw0 is None and tpos <= tw0 < tpos + num:
                q_at_tw0 = qpos + (tw0 - tpos)
            if q_at_tw1 is None and tpos < tw1 <= tpos + num:
                q_at_tw1 = qpos + (tw1 - tpos)
            tpos += num
            qpos += num
        elif op == b"D":   # target only (gap in query)
            tpos += num
        elif op == b"I":   # query only (insertion)
            qpos += num
        if q_at_tw0 is not None and q_at_tw1 is not None:
            break
    if q_at_tw0 is None or q_at_tw1 is None:
        return None
    q0, q1 = q_at_tw0, q_at_tw1
    if strand == "-":
        # forward query coords: reflect around qlen
        q0f = qlen - q_at_tw1
        q1f = qlen - q_at_tw0
        q0, q1 = q0f, q1f
    if q1 <= q0:
        return None
    return q0, q1
