"""make_vectors.py <work dir> <out TEST_VECTORS.json> <ABS fixture dir> - intermediate values for four fixtures, computed by specdec.py
(the decoder written from FORMAT_V1_SPEC.md). Not shipped; its output is. Cross-checked by trace_check.sh against the
frozen v1 code (rANS states and ops)."""
import hashlib, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specdec as S

W, OUT, AB = sys.argv[1], sys.argv[2], sys.argv[3]
FIX = [(f, os.path.join(W, "arch"), os.path.join(W, "data", "reference.fa"), "reference/reference.fa") for f in ("asmB.q16k.hash.rr3", "asmC.q4k.hash.rr3", "asmD.q4k.hash.rr3")] + \
      [("asmG.q4k.hash.rr3", AB, os.path.join(AB, "reference_abs.fa"), "reference/reference_abs.fa")]
NEV, NCOPY = 64, 16


def block_vec(X, b):
    tr, ops = [], []
    out = S.decode_block(X, b, trace=tr, ops=ops)
    cache_log, cache = [], [X.st[b]]
    copies = []
    for o in ops:
        if o[0] == "literal": copies.append({"type": "literal_run", "offset": o[1], "length": o[2]})
        elif o[0] == "self": copies.append({"type": "SELF", "offset": o[1], "length": o[2], "distance": o[3], "source_offset": o[1] - o[3]})
        else:
            g = ((((o[3] + o[2] - 1 + o[1]) if o[4] else (o[3] - o[1])) & S.MASK64), o[4])
            if g in cache: cache.remove(g)
            elif len(cache) == 4: cache.pop()
            cache.insert(0, g)
            copies.append({"type": o[0], "offset": o[1], "length": o[2], "ref_start": o[3], "strand": "reverse_complement" if o[4] else "forward",
                           "diagonal": S.s64(g[0]), "cache_after": [[S.s64(c), d] for c, d in cache]})
    first = [c for c in copies][:NCOPY + sum(1 for c in copies[:2 * NCOPY] if c["type"] == "literal_run")]
    ev = [e for e in tr][:NEV + 1]
    syms = [e for e in tr if e["event"] == "symbol"]
    return {"block": b, "blen": len(out), "stream_offset_in_payload": X.off[b], "stream_bytes": X.off[b + 1] - X.off[b],
            "stream_first_bytes_hex": X.P[X.off[b]:X.off[b] + 8].hex(),
            "start_diagonal": {"c": S.s64(X.st[b][0]), "dir": X.st[b][1]},
            "rans_init_state": tr[0]["x"],
            "rans_events_first": ev,
            "rans_state_after_symbols": {str(n): syms[n - 1]["x"] for n in (1, 2, 4, 8, 16, 32, 64) if n <= len(syms)},
            "symbols_in_block": len(syms), "raw_bit_fields_in_block": sum(1 for e in tr if e["event"] == "bits"),
            "rans_final": {"state": 65536, "bytes_consumed": X.off[b + 1] - X.off[b]},
            "events_first": first[:2 * NCOPY],
            "first_16_copies": [c for c in copies if c["type"] != "literal_run"][:NCOPY],
            "output_first_64": out[:64].decode("latin-1"),
            "output_sha256": hashlib.sha256(out).hexdigest(), "output_xxh3": "%016x" % S.xxh3(out)}


def fixture(f, adir, rpath, rname):
    R, rs = S.load_ref(rpath)
    a = open(os.path.join(adir, f), "rb").read(); X = S.open_archive(a, R, rs)
    u64 = lambda o: int.from_bytes(a[o:o + 8], "little"); L = a[136] | a[137] << 8
    pstart = 138 + L + u64(96) + u64(112)
    h = bytearray(a[:pstart]); h[128:136] = bytes(8)
    v = {"archive": "archives/" + f, "reference": rname, "file_bytes": len(a), "file_sha256": hashlib.sha256(a).hexdigest(),
         "header": {"magic_hex": a[:8].hex(), "version": int.from_bytes(a[8:12], "little"), "Q": X.Q, "flags": X.flags,
                    "reserved": int.from_bytes(a[20:24], "little"), "ref_sha256": a[24:56].hex(), "ref_bases": u64(56), "n": X.n,
                    "nblocks": X.nb, "fasta_xxh3": "%016x" % X.fasta_xxh3, "bases_xxh3": "%016x" % X.bases_xxh3, "meta_bytes": u64(96),
                    "meta_raw": u64(104), "hash_bytes": u64(112), "payload_bytes": u64(120), "header_xxh3": "%016x" % u64(128),
                    "header_xxh3_recomputed": "%016x" % S.xxh3(h), "reference_name_length": L, "reference_name": a[138:138 + L].decode("latin-1"),
                    "meta_offset": 138 + L, "hash_section_offset": 138 + L + u64(96), "payload_start": pstart},
         "meta": {"meta_frame_first_bytes_hex": a[138 + L:138 + L + 8].hex(),
                  "records": [{"header": r[0].decode("latin-1"), "length": r[1], "line_width": r[2], "base_offset": r[3]} for r in X.rec],
                  "lowercase_runs": len(X.low), "lowercase_runs_first": [{"start": s, "length": l} for s, l in X.low[:8]],
                  "context_sums": [sum(fs) for fs in X.freq], "frequency_values_total": sum(len(fs) for fs in X.freq),
                  "nonzero_frequencies": sum(1 for fs in X.freq for x in fs if x),
                  "frequencies_sha256_u16le": hashlib.sha256(b"".join(x.to_bytes(2, "little") for fs in X.freq for x in fs)).hexdigest(),
                  "frequencies_context_31": X.freq[31], "frequencies_context_0_nonzero": {str(s): x for s, x in enumerate(X.freq[0]) if x},
                  "block_table_first": [{"block": b, "stream_bytes": X.off[b + 1] - X.off[b], "start_diagonal_c": S.s64(X.st[b][0]), "dir": X.st[b][1]} for b in range(min(8, X.nb))]},
         "block_xxh3_first": ["%016x" % int.from_bytes(X.hashes[8 * b:8 * b + 8], "little") for b in range(min(8, X.nb))] if X.hashes is not None else None}
    fa = S.full(X)
    v["full_decode"] = {"fasta_bytes": len(fa), "fasta_sha256": hashlib.sha256(fa).hexdigest(), "fasta_xxh3": "%016x" % S.xxh3(fa)}
    # block 0 and the first block holding each of: SELF, FLIP, reverse-complement copy, escaped literal, DELTA, REP
    want, picks = {"SELF", "FLIP", "rc", "escape", "DELTA", "REP", "ABS"}, [0]
    for b in range(X.nb):
        tr, ops = [], []; S.decode_block(X, b, trace=tr, ops=ops)
        has = {o[0].upper() for o in ops} | ({"rc"} if any(len(o) == 5 and o[4] for o in ops) else set()) | \
              ({"escape"} if any(e["event"] == "symbol" and 4 <= e["ctx"] <= 30 and e["sym"] == 5 for e in tr) else set())
        if has & want: picks.append(b); want -= has
        if not want: break
    v["blocks"] = [block_vec(X, b) for b in sorted(set(picks))]
    v["blocks_why"] = "block 0, then the first block holding each of SELF, FLIP, reverse-complement copy, escaped literal, DELTA, REP, ABS (if any)"
    return v


doc = {"about": "Intermediate values of four fixtures (the fourth: ABS copies against reference_abs.fa), for checking a decoder step by step against FORMAT_V1_SPEC.md. Section numbers refer to it. "
                "rans_events_first: 'init' = state after the 3 initial bytes; 'symbol' = context id, symbol, state x and stream position after the symbol "
                "(after renormalisation); 'bits' = raw-bit field (n bits, value), state and position after it. Diagonal values are signed (int64). "
                "events_first lists literal runs and copies in stream order; offsets are block offsets. Strings are latin-1.",
       "fixtures": [fixture(*x) for x in FIX]}
json.dump(doc, open(OUT, "w"), indent=1)
print("fixtures", [f["archive"] for f in doc["fixtures"]], "blocks", [[b["block"] for b in f["blocks"]] for f in doc["fixtures"]])
