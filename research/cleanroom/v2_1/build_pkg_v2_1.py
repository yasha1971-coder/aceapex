"""build_pkg_v2_1.py <v2 package dir> <out dir> - clean-room package v2.1 (not shipped from the repository): the fixtures
of package v2 byte for byte (reference/, archives/, corrupt/, fetch/, TEST_VECTORS.json; the v2 package is first checked
against its SHA256SUMS), FORMAT_V1_SPEC.md 1.0.1, EXPECTED.json v2.1 and README_TASK.md from this directory, SHA256SUMS.
Then a grep of every file for source / internal names (must be 0), the v2.1 spec decoder (specdec.py check: decodes,
fetches, refusals with stage and reason; XXH3 through env XXH3_BIN) and a deterministic ZIP (sorted entries, fixed
mtime 2026-10-08 00:00:00 UTC, modes 644 / 755, zip -X, TZ=UTC). Exit 0 only if grep = 0 and the check passes."""
import hashlib, os, re, shutil, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))
V2, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
NAME = "refrel3_cleanroom_v2_1"; P = os.path.join(OUT, NAME); MTIME = 1791417600       # 2026-10-08 00:00:00 UTC
sha = lambda b: hashlib.sha256(b).hexdigest()
FIXTURES = ("reference", "archives", "corrupt", "fetch", "TEST_VECTORS.json")
OWN = ("FORMAT_V1_SPEC.md", "EXPECTED.json", "README_TASK.md")
FORBIDDEN = [r"refrel3v1", r"refrel3\.h", r"refrel_format", r"refrel3_gpu", r"refrel_io", r"refrel2", r"\.cpp\b", r"\.cu\b",
             r"\.hpp\b", r"\br3_\w+", r"\bR3_\w+", r"\brr_\w+", r"\bRR_\w+", r"aceapex", r"panvram", r"pubrepo", r"research/",
             r"/home/", r"aeterna", r"\bsrc/", r"xxhash\.h", r"exec_fast", r"open_v1", r"block_v1", r"full_v1", r"specdec",
             r"build_pkg", r"gen\.py", r"refrel3\.cpp", r"\bR3Tab\b", r"\bR3Diag\b", r"\bRrOp\b", r"hw-apex", r"frozen",
             r"5b6d5ce", r"pv_v1", r"make_expected", r"cleanroom/"]


def main():
    if os.path.exists(P): sys.exit("exists: " + P)
    z = os.path.join(OUT, NAME + ".zip")
    if os.path.exists(z): sys.exit("exists: " + z)
    bad = [l for l in subprocess.run(["sha256sum", "-c", "--quiet", "SHA256SUMS"], cwd=V2, capture_output=True, text=True).stdout.splitlines() if l]
    if bad: sys.exit("v2 package differs from its SHA256SUMS: %s" % bad[:5])
    os.makedirs(P)
    for f in FIXTURES:
        (shutil.copytree if os.path.isdir(os.path.join(V2, f)) else shutil.copyfile)(os.path.join(V2, f), os.path.join(P, f))
    for f in OWN: shutil.copyfile(os.path.join(H, f), os.path.join(P, f))
    files = sorted(os.path.relpath(os.path.join(dp, f), P) for dp, _, fs in os.walk(P) for f in fs)
    with open(os.path.join(P, "SHA256SUMS"), "w") as s:
        for f in files: s.write(f"{sha(open(os.path.join(P, f), 'rb').read())}  {f}\n")
    # fixtures == v2 byte for byte
    v2sums = dict(l.split("  ", 1)[::-1] for l in open(os.path.join(V2, "SHA256SUMS")).read().splitlines())
    newsums = dict(l.split("  ", 1)[::-1] for l in open(os.path.join(P, "SHA256SUMS")).read().splitlines())
    same = [f for f in newsums if f not in OWN and v2sums.get(f) == newsums[f]]
    print("fixtures identical to v2:", len(same), "of", len(newsums) - len(OWN), "| own files:", ", ".join(OWN))
    if len(same) != len(newsums) - len(OWN): sys.exit("fixture differs from v2")
    hits = []
    for f in files + ["SHA256SUMS"]:
        b = open(os.path.join(P, f), "rb").read().decode("latin-1")
        for pat in FORBIDDEN:
            for m in re.finditer(pat, b): hits.append((f, pat, b[max(0, m.start() - 30):m.end() + 30].replace("\n", " ")))
            if re.search(pat, f): hits.append((f, pat, "file name"))
    print("internal-name grep:", len(hits), "matches")
    for h in hits[:40]: print("  HIT", h)
    r = subprocess.run([sys.executable, os.path.join(H, "specdec.py"), "check", P], capture_output=True, text=True)
    print("\n".join(l for l in r.stdout.splitlines() if l.startswith(("CORRUPT", "spec decoder"))))
    if r.returncode: print(r.stderr[-2000:])
    entries = sorted(set([NAME + "/"] + [NAME + "/" + os.path.dirname(f) + "/" for f in files if os.path.dirname(f)]
                         + [NAME + "/" + f for f in files + ["SHA256SUMS"]]))
    for e in entries:
        p = os.path.join(OUT, e); os.chmod(p, 0o755 if e.endswith("/") else 0o644); os.utime(p, (MTIME, MTIME))
    subprocess.run(["zip", "-q", "-X", "-@", z], input="\n".join(entries) + "\n", text=True, cwd=OUT, check=True, env=dict(os.environ, TZ="UTC"))
    zb = open(z, "rb").read()
    print(f"zip {sha(zb)} {len(zb)} B, {len(entries)} entries ({len(files) + 1} files)")
    sys.exit(1 if hits or r.returncode else 0)


if __name__ == "__main__":
    main()
