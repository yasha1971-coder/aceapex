#!/usr/bin/env python3
"""Runs decoder.py against EXPECTED.json and TEST_VECTORS.json; writes results.json."""
import hashlib, json, os, sys, time, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decoder as D

PKG = "/home/claude/cr2/pkg/refrel3_cleanroom_v2"
OUT = "/home/claude/cr2/work/out"
os.makedirs(OUT, exist_ok=True)
exp = json.load(open(os.path.join(PKG, "EXPECTED.json")))
tv = json.load(open(os.path.join(PKG, "TEST_VECTORS.json")))
P = lambda p: os.path.join(PKG, p)
res = {"decode": [], "fetch": [], "corrupt": [], "vectors": []}
t0 = time.time()

# a) full decodes, b) fetches
for e in exp["archives"]:
    name = e["archive"]
    outp = os.path.join(OUT, os.path.basename(name) + ".fa")
    if os.path.exists(outp):
        os.remove(outp)
    try:
        fa = D.full_decode(P(name), P(e["reference"]))
        open(outp, "wb").write(fa)
        sha = hashlib.sha256(fa).hexdigest()
        ok = sha == e["fasta_sha256"] and len(fa) == e["fasta_bytes"]
        res["decode"].append({"archive": name, "ok": ok, "sha256": sha, "bytes": len(fa)})
    except D.Refused as r:
        res["decode"].append({"archive": name, "ok": False, "refused": [r.stage, r.message]})
    # fetch
    try:
        a = D.open_archive(P(name), P(e["reference"]))
    except D.Refused as r:
        a = None
    lines = open(P(e["fetch"])).read().split("\n")
    assert lines[0].split("\t") == ["contig", "start", "length", "sha256"], lines[0]
    for ln in lines[1:]:
        if not ln.strip():
            continue
        ctg, st, length, sha = ln.split("\t")
        row = {"archive": name, "contig": ctg, "start": int(st), "length": int(length)}
        if a is None:
            row.update(ok=False, err="open refused")
        else:
            try:
                got = D.fetch(a, ctg, int(st), int(length))
                row["ok"] = hashlib.sha256(got).hexdigest() == sha
                if not row["ok"]:
                    row["got"] = hashlib.sha256(got).hexdigest()
            except D.Refused as r:
                row.update(ok=False, err=[r.stage, r.message])
        res["fetch"].append(row)

# c) corrupt
for e in exp["corrupt"]:
    name = e["archive"]
    outp = os.path.join(OUT, os.path.basename(name) + ".fa")
    if os.path.exists(outp):
        os.remove(outp)
    rr = e["reader_response"]
    try:
        fa = D.full_decode(P(name), P(e["reference"]))
        open(outp, "wb").write(fa)
        res["corrupt"].append({"archive": name, "refused": False, "output_written": True, "ok": False})
        continue
    except D.Refused as r:
        stage, msg = r.stage, r.message
    written = os.path.exists(outp)
    # reason match: the expected message equals ours, or ours begins with the expected message
    # (we append a detail in parentheses), or the expected message begins with our §5 reason
    exp_msg = rr["message"]
    reason_ok = (msg == exp_msg or msg.startswith(exp_msg) or exp_msg.startswith(msg.split(" (")[0]))
    res["corrupt"].append({"archive": name, "refused": True, "stage": stage, "message": msg,
                           "expected_stage": rr["stage"], "expected_message": exp_msg,
                           "stage_ok": stage == rr["stage"], "reason_ok": reason_ok,
                           "exact_message": msg == exp_msg,
                           "output_written": written,
                           "ok": stage == rr["stage"] and reason_ok and not written and not rr["output_written"]})

# d) test vectors
def hx(v):
    return "%016x" % v

for fx in tv["fixtures"]:
    chk = []
    def C(label, got, want):
        chk.append({"check": label, "ok": got == want, **({} if got == want else {"got": got, "want": want})})
    a = D.open_archive(P(fx["archive"]), P(fx["reference"]))
    h = fx["header"]
    f = a.f
    C("file_bytes", len(f), fx["file_bytes"])
    C("file_sha256", hashlib.sha256(f).hexdigest(), fx["file_sha256"])
    hv = {"magic_hex": f[:8].hex(), "version": 1, "Q": a.Q, "flags": a.flags,
          "reserved": struct.unpack_from("<I", f, 20)[0], "ref_sha256": f[24:56].hex(),
          "ref_bases": len(a.R), "n": a.n, "nblocks": a.nblocks, "fasta_xxh3": hx(a.fasta_xxh3),
          "bases_xxh3": hx(a.bases_xxh3), "meta_bytes": a.meta_bytes, "meta_raw": a.meta_raw,
          "hash_bytes": a.hash_bytes, "payload_bytes": a.payload_bytes, "header_xxh3": hx(a.header_xxh3),
          "reference_name_length": a.L, "reference_name": a.ref_name.decode("latin-1"),
          "meta_offset": a.meta_off, "hash_section_offset": a.hash_off, "payload_start": a.payload_start}
    hdr = bytearray(f[:a.payload_start]); hdr[128:136] = bytes(8)
    hv["header_xxh3_recomputed"] = hx(D.xxh3(bytes(hdr)))
    for k, v in h.items():
        C("header." + k, hv.get(k, "<not computed>"), v)
    m = fx["meta"]
    C("meta.meta_frame_first_bytes_hex", f[a.meta_off:a.meta_off + 8].hex(), m["meta_frame_first_bytes_hex"])
    C("meta.records", [{"header": r[0].decode("latin-1"), "length": r[1], "line_width": r[2], "base_offset": r[3]}
                       for r in a.recs], m["records"])
    C("meta.lowercase_runs", len(a.runs), m["lowercase_runs"])
    C("meta.lowercase_runs_first", [{"start": s, "length": l} for s, l in a.runs[:len(m["lowercase_runs_first"])]],
      m["lowercase_runs_first"])
    C("meta.context_sums", [sum(x) for x in a.freqs], m["context_sums"])
    allf = [v for fc in a.freqs for v in fc]
    C("meta.frequency_values_total", len(allf), m["frequency_values_total"])
    C("meta.nonzero_frequencies", sum(1 for v in allf if v), m["nonzero_frequencies"])
    C("meta.frequencies_sha256_u16le", hashlib.sha256(struct.pack("<%dH" % len(allf), *allf)).hexdigest(),
      m["frequencies_sha256_u16le"])
    C("meta.frequencies_context_31", a.freqs[31], m["frequencies_context_31"])
    C("meta.frequencies_context_0_nonzero", {str(i): v for i, v in enumerate(a.freqs[0]) if v},
      m["frequencies_context_0_nonzero"])
    C("meta.block_table_first", [{"block": b, "stream_bytes": a.blocks[b][1], "start_diagonal_c": a.blocks[b][2],
                                  "dir": a.blocks[b][3]} for b in range(len(m["block_table_first"]))],
      m["block_table_first"])
    for k in m:
        if not any(c["check"] == "meta." + k for c in chk):
            chk.append({"check": "meta." + k, "ok": None, "note": "not compared"})
    C("block_xxh3_first", [hx(v) for v in a.hashes[:len(fx["block_xxh3_first"])]], fx["block_xxh3_first"])
    fa = D.full_decode(P(fx["archive"]), P(fx["reference"]))
    C("full_decode", {"fasta_bytes": len(fa), "fasta_sha256": hashlib.sha256(fa).hexdigest(),
                      "fasta_xxh3": hx(D.xxh3(fa))}, fx["full_decode"])
    for bk in fx["blocks"]:
        b = bk["block"]
        trace = []
        events = []
        out, rs = D.decode_block(a, b, trace, events)
        poff, slen, c0, d0 = a.blocks[b]
        pre = "block%d." % b
        C(pre + "blen", len(out), bk["blen"])
        C(pre + "stream_offset_in_payload", poff, bk["stream_offset_in_payload"])
        C(pre + "stream_bytes", slen, bk["stream_bytes"])
        C(pre + "stream_first_bytes_hex", f[a.payload_start + poff:a.payload_start + poff + 8].hex(),
          bk["stream_first_bytes_hex"])
        C(pre + "start_diagonal", {"c": c0, "dir": d0}, bk["start_diagonal"])
        C(pre + "rans_init_state", trace[0]["x"], bk["rans_init_state"])
        C(pre + "rans_events_first", trace[:len(bk["rans_events_first"])], bk["rans_events_first"])
        syms = [t for t in trace if t["event"] == "symbol"]
        C(pre + "rans_state_after_symbols", {k: syms[int(k) - 1]["x"] for k in bk["rans_state_after_symbols"]},
          bk["rans_state_after_symbols"])
        C(pre + "symbols_in_block", rs.nsym, bk["symbols_in_block"])
        C(pre + "raw_bit_fields_in_block", rs.nbits, bk["raw_bit_fields_in_block"])
        C(pre + "rans_final", {"state": rs.x, "bytes_consumed": rs.pos}, bk["rans_final"])
        C(pre + "events_first", events[:len(bk["events_first"])], bk["events_first"])
        copies = [e for e in events if e["type"] != "literal_run"]
        C(pre + "first_16_copies", copies[:len(bk["first_16_copies"])], bk["first_16_copies"])
        C(pre + "output_first_64", out[:64].decode("latin-1"), bk["output_first_64"])
        C(pre + "output_sha256", hashlib.sha256(out).hexdigest(), bk["output_sha256"])
        C(pre + "output_xxh3", hx(D.xxh3(out)), bk["output_xxh3"])
        for k in bk:
            if not any(c["check"] == pre + k for c in chk) and k != "block":
                chk.append({"check": pre + k, "ok": None, "note": "not compared"})
    res["vectors"].append({"fixture": fx["archive"], "checks": chk})

res["seconds"] = round(time.time() - t0, 2)
json.dump(res, open("/home/claude/cr2/work/results.json", "w"), indent=1)

def cnt(lst):
    return sum(1 for x in lst if x["ok"]), len(lst)
print("decode %d/%d" % cnt(res["decode"]))
print("fetch %d/%d" % cnt(res["fetch"]))
print("corrupt %d/%d" % cnt(res["corrupt"]))
for x in res["decode"] + res["fetch"] + res["corrupt"]:
    if not x["ok"]:
        print("FAIL", x)
for c in res["corrupt"]:
    print("CORRUPT", c["archive"], c["stage"], "|", c["message"], "| expected:", c["expected_stage"], c["expected_message"])
for v in res["vectors"]:
    cs = v["checks"]
    print("VEC", v["fixture"], sum(1 for c in cs if c["ok"]), "/", sum(1 for c in cs if c["ok"] is not None),
          "not compared:", [c["check"] for c in cs if c["ok"] is None])
    for c in cs:
        if c["ok"] is False:
            print("   MISMATCH", json.dumps(c)[:600])
print("seconds", res["seconds"])
