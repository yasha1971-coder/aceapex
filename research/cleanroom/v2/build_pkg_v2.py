"""build_pkg_v2.py <repro work dir> <out dir> - clean-room package v2 (not shipped from the repository): FORMAT_V1_SPEC.md,
the v1 fixtures (reference, 24 archives, 7 corrupt cases, fetch tables - byte-identical to package v1), the ABS fixture
(reference_abs.fa, asmG.q4k hash / nohash, fetch tables), two refusal fixtures for the stricter checks (zero_context,
meta_two_frames), EXPECTED.json (expected hashes; reader_response = the v1 reader with the stricter checks, env
PANVRAM_PY = its python), TEST_VECTORS.json (four fixtures), SHA256SUMS. No task text (given separately).
Then: specdec.py check of the package, a grep of every file for source / internal names (must be 0), and a
deterministic ZIP (sorted entries, fixed mtime 2026-10-07 00:00:00 UTC, modes 644 / 755, zip -X)."""
import hashlib, json, os, random, re, shutil, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))
W, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
V1 = os.path.join(W, "pkg", "refrel3_cleanroom_v1"); NAME = "refrel3_cleanroom_v2"; P = os.path.join(OUT, NAME)
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

FORBIDDEN = [r"refrel3v1", r"refrel3\.h", r"refrel_format", r"refrel3_gpu", r"refrel_io", r"refrel2", r"\.cpp\b", r"\.cu\b",
             r"\.hpp\b", r"\br3_\w+", r"\bR3_\w+", r"\brr_\w+", r"\bRR_\w+", r"aceapex", r"panvram", r"pubrepo", r"research/",
             r"/home/", r"aeterna", r"\bsrc/", r"xxhash\.h", r"exec_fast", r"open_v1", r"block_v1", r"full_v1", r"specdec",
             r"build_pkg", r"gen\.py", r"refrel3\.cpp", r"\bR3Tab\b", r"\bR3Diag\b", r"\bRrOp\b", r"hw-apex", r"frozen tool"]


def main():
    if os.path.exists(P): sys.exit("exists: " + P)
    os.makedirs(P)
    AB, SF = os.path.join(OUT, "work_abs"), os.path.join(OUT, "work_strict")
    # ABS fixture: data, frozen encoder, frozen decode == source
    subprocess.run([sys.executable, os.path.join(H, "gen_abs.py"), AB], check=True)
    for h in ("hash", "nohash"):
        subprocess.run([os.path.join(W, "refrel3v1"), "encode", "reference_abs.fa", "4096", "4", "asmG.fa", f"asmG.q4k.{h}.rr3"] + (["nohash"] if h == "nohash" else []), cwd=AB, check=True, capture_output=True)
        subprocess.run([os.path.join(W, "refrel3v1"), "decode", "reference_abs.fa", f"asmG.q4k.{h}.rr3", "back.fa"], cwd=AB, check=True, capture_output=True)
        assert open(os.path.join(AB, "back.fa"), "rb").read() == open(os.path.join(AB, "asmG.fa"), "rb").read()
    subprocess.run([sys.executable, os.path.join(H, "make_strict.py"), W, SF], check=True)
    for d in ("reference", "archives", "corrupt", "fetch"): shutil.copytree(os.path.join(V1, d), os.path.join(P, d))
    shutil.copy(os.path.join(AB, "reference_abs.fa"), os.path.join(P, "reference"))
    for h in ("hash", "nohash"): shutil.copy(os.path.join(AB, f"asmG.q4k.{h}.rr3"), os.path.join(P, "archives"))
    for f in ("zero_context.rr3", "meta_two_frames.rr3"): shutil.copy(os.path.join(SF, f), os.path.join(P, "corrupt"))
    shutil.copy(os.path.join(H, "FORMAT_V1_SPEC.md"), P)
    exp = json.load(open(os.path.join(V1, "EXPECTED.json")))
    exp["format"] = "refrel3 v1 (FORMAT_V1_SPEC.md)"
    exp["coordinates"] = "fetch: contig = record name (header up to the first space or tab), start 0-based, length in bases; answer = bases [start, start + length), case as in the FASTA (FORMAT_V1_SPEC.md section 14)"
    exp["references"]["reference_abs.fa"] = sha(open(os.path.join(P, "reference", "reference_abs.fa"), "rb").read())
    src = open(os.path.join(AB, "asmG.fa"), "rb").read(); recs = [(n, q) for n, q in parse_fasta(src) if q]
    for h in ("hash", "nohash"):                                        # fetch tables as for the v1 archives
        f = f"asmG.q4k.{h}.rr3"; rng = random.Random(int(sha(f.encode())[:8], 16)); rows = []
        for i in range(50):
            n, q = recs[rng.randrange(len(recs))]; kind = i % 5
            if kind == 0: st, ln = 0, min(len(q), 1 + rng.randrange(5000))
            elif kind == 1: ln = min(len(q), 1 + rng.randrange(5000)); st = len(q) - ln
            elif kind == 2: ln = 1; st = rng.randrange(len(q))
            else: ln = min(len(q), 1 + int(2 ** (rng.random() * 17))); st = rng.randrange(len(q) - ln + 1)
            rows.append((n.decode(), st, ln, sha(q[st:st + ln])))
        with open(os.path.join(P, "fetch", f + ".fetch.tsv"), "w") as o:
            o.write("contig\tstart\tlength\tsha256\n")
            for r in rows: o.write("%s\t%d\t%d\t%s\n" % r)
        exp["archives"].append({"archive": "archives/" + f, "reference": "reference/reference_abs.fa", "expect": "decode",
                                "fasta_sha256": sha(src), "fasta_bytes": len(src), "fetch": "fetch/" + f + ".fetch.tsv",
                                "note": "ABS copies (reference longer than 2^24 bases)"})
    exp["corrupt"] += [{"archive": "corrupt/zero_context.rr3", "reference": "reference/reference.fa", "expect": "refuse",
                        "how": "asmB.q4k.hash.rr3 with every frequency of context 59 set to 0 (meta rebuilt, header XXH3 recomputed, payload untouched): a symbol is read from an all-zero context (sections 6.3, 15)"},
                       {"archive": "corrupt/meta_two_frames.rr3", "reference": "reference/reference.fa", "expect": "refuse",
                        "how": "asmD.q16k.nohash.rr3 with an empty zstd frame appended to the meta section (meta content identical; meta_bytes and header XXH3 updated): the meta must be exactly one frame (sections 4, 5)"}]
    # responses of the v1 reader with the stricter checks
    for c in exp["corrupt"]:
        c.pop("tool_response", None)
        out = subprocess.run([os.environ["PANVRAM_PY"], os.path.join(H, "reader_responses.py"), os.path.join(OUT, "work_reader", os.path.basename(c["archive"])),
                              os.path.join(P, c["reference"]), os.path.join(P, c["archive"])], check=True, capture_output=True, text=True).stdout
        r = json.loads(out.strip().split("\n")[-1])
        assert r["refused"], c["archive"]
        c["reader_response"] = {"stage": r["stage"], "message": r["message"].split(": ", 1)[1], "output_written": False}
    json.dump(exp, open(os.path.join(P, "EXPECTED.json"), "w"), indent=1)
    subprocess.run([sys.executable, os.path.join(H, "make_vectors.py"), W, os.path.join(P, "TEST_VECTORS.json"), AB], check=True)
    files = sorted(os.path.relpath(os.path.join(dp, f), P) for dp, _, fs in os.walk(P) for f in fs)
    with open(os.path.join(P, "SHA256SUMS"), "w") as s:
        for f in files: s.write(f"{sha(open(os.path.join(P, f), 'rb').read())}  {f}\n")
    # source / internal names: 0 matches in every text and binary file
    hits = []
    for f in files + ["SHA256SUMS"]:
        b = open(os.path.join(P, f), "rb").read().decode("latin-1")
        for pat in FORBIDDEN:
            for m in re.finditer(pat, b): hits.append((f, pat, b[max(0, m.start() - 30):m.end() + 30].replace("\n", " ")))
        for pat in FORBIDDEN:
            if re.search(pat, f): hits.append((f, pat, "file name"))
    print("internal-name grep:", len(hits), "matches")
    for h in hits[:40]: print("  HIT", h)
    r = subprocess.run([sys.executable, os.path.join(H, "specdec.py"), "check", P], capture_output=True, text=True)
    print(r.stdout.strip().split("\n")[-1])
    # deterministic ZIP
    entries = [NAME + "/"] + sorted({NAME + "/" + os.path.dirname(f) + "/" for f in files if os.path.dirname(f)}) + [NAME + "/" + f for f in sorted(files + ["SHA256SUMS"])]
    entries = sorted(set(entries))
    for e in entries:
        p = os.path.join(OUT, e); os.chmod(p, 0o755 if e.endswith("/") else 0o644)
        os.utime(p, (1791331200, 1791331200))                           # 2026-10-07 00:00:00 UTC
    z = os.path.join(OUT, NAME + ".zip")
    if os.path.exists(z): sys.exit("exists: " + z)
    subprocess.run(["zip", "-q", "-X", "-@", z], input="\n".join(entries) + "\n", text=True, cwd=OUT, check=True, env=dict(os.environ, TZ="UTC"))
    zb = open(z, "rb").read()
    print(f"zip {sha(zb)} {len(zb)} B, {len(entries)} entries ({len(files) + 1} files)")
    sys.exit(1 if hits or r.returncode else 0)


if __name__ == "__main__":
    main()
