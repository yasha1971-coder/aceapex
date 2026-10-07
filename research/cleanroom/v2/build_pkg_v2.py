"""build_pkg_v2.py <repro work dir> <out dir> - clean-room package v2 (not shipped from the repository): FORMAT_V1_SPEC.md,
the v1 fixtures (reference, 24 archives, 7 corrupt cases, fetch tables - byte-identical to package v1), EXPECTED.json
(expected hashes; format field pointing to the specification), TEST_VECTORS.json, README_TASK.md, SHA256SUMS.
Then: specdec.py check of the package, a grep of every file for source / internal names (must be 0), and a
deterministic ZIP (sorted entries, fixed mtime 2026-10-07 00:00:00 UTC, modes 644 / 755, zip -X)."""
import hashlib, json, os, re, shutil, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))
W, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
V1 = os.path.join(W, "pkg", "refrel3_cleanroom_v1"); NAME = "refrel3_cleanroom_v2"; P = os.path.join(OUT, NAME)
sha = lambda b: hashlib.sha256(b).hexdigest()

TASK = """# Task

Write a decoder for the archive format specified in `FORMAT_V1_SPEC.md` (refrel3 v1), working only from that
specification and the files of this package. Language and design are your choice.

## Inputs

- `FORMAT_V1_SPEC.md` - the complete byte-level specification (self-contained).
- `TEST_VECTORS.json` - intermediate values for three fixtures (header and meta fields, model tables, block start
  diagonals, rANS states after each symbol of selected blocks, the first copies with their diagonal cache, block and file
  hashes) to check a decoder step by step.
- `reference/reference.fa` - the reference FASTA every archive was encoded against.
- `reference/reference_wrong.fa` - a reference that differs from it.
- `archives/*.rr3` - 24 archives (6 assemblies x block size 4096 / 16384 x with / without per-block hashes).
- `corrupt/*.rr3` - 7 damaged or mismatched cases (truncation, header byte, payload byte, wrong reference, stored block
  hash changed, source-FASTA hash field changed, two blocks swapped).
- `fetch/<archive>.fetch.tsv` - 50 region requests per archive: `contig`, `start`, `length`, `sha256`.
- `EXPECTED.json` - every expected value; `SHA256SUMS` - the SHA-256 of every file of the package (relative paths).

## What the decoder must do

1. Full decode: given an archive and a reference, produce the original FASTA file (headers, line breaks, letter case),
   byte for byte (specification section 13).
2. Region fetch: given an archive, a reference, a contig name (the FASTA header up to the first space or tab), a 0-based
   start and a length, produce exactly those bases of that contig, letter case as in the original, without line breaks
   (section 14: the request is [start, start + length), zero-based half-open).
3. Refusal: when the archive is damaged, truncated, does not belong to the given reference, or fails any check the
   specification requires (sections 5 and 15), report an error and produce no output (no partial FASTA, no region bytes).

## How it is checked

- For every entry of `EXPECTED.json` "archives": SHA-256 of the full decoded FASTA == `fasta_sha256` (and the byte count ==
  `fasta_bytes`); for every row of its fetch table: SHA-256 of the returned bases == `sha256`.
- For every entry of "corrupt": a full decode with the listed reference reports an error and writes no output
  ("reader_response" is what a reader following the check order of section 5 reports).
- A run passes only if all 24 full decodes, all 1 200 fetch answers and all 7 refusals match. Any crash, hang (allow at
  most 60 s per archive) or output on a refusal case is a failure.
- First verify the package itself: `sha256sum -c SHA256SUMS` from the package root.
- Report every place where the specification was insufficient or ambiguous, with the section number.
"""

FORBIDDEN = [r"refrel3v1", r"refrel3\.h", r"refrel_format", r"refrel3_gpu", r"refrel_io", r"refrel2", r"\.cpp\b", r"\.cu\b",
             r"\.hpp\b", r"\br3_\w+", r"\bR3_\w+", r"\brr_\w+", r"\bRR_\w+", r"aceapex", r"panvram", r"pubrepo", r"research/",
             r"/home/", r"aeterna", r"\bsrc/", r"xxhash\.h", r"exec_fast", r"open_v1", r"block_v1", r"full_v1", r"specdec",
             r"build_pkg", r"gen\.py", r"refrel3\.cpp", r"\bR3Tab\b", r"\bR3Diag\b", r"\bRrOp\b", r"hw-apex", r"frozen tool"]


def main():
    if os.path.exists(P): sys.exit("exists: " + P)
    os.makedirs(P)
    for d in ("reference", "archives", "corrupt", "fetch"): shutil.copytree(os.path.join(V1, d), os.path.join(P, d))
    shutil.copy(os.path.join(H, "FORMAT_V1_SPEC.md"), P)
    open(os.path.join(P, "README_TASK.md"), "w").write(TASK)
    exp = json.load(open(os.path.join(V1, "EXPECTED.json")))
    exp["format"] = "refrel3 v1 (FORMAT_V1_SPEC.md)"
    exp["coordinates"] = "fetch: contig = record name (header up to the first space or tab), start 0-based, length in bases; answer = bases [start, start + length), case as in the FASTA (FORMAT_V1_SPEC.md section 14)"
    for c in exp["corrupt"]:
        r = c.pop("tool_response"); c["reader_response"] = {"exit": r["exit"], "message": r["message"], "output_written": r["output_written"]}
    json.dump(exp, open(os.path.join(P, "EXPECTED.json"), "w"), indent=1)
    subprocess.run([sys.executable, os.path.join(H, "make_vectors.py"), W, os.path.join(P, "TEST_VECTORS.json")], check=True)
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
