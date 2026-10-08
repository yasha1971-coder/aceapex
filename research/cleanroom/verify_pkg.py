"""verify_pkg.py - check the package against the frozen tool (refrel3v1 @ 5b6d5ce): every archive decodes to the
expected FASTA SHA-256, every fetch row (tool's own fetch, 1-based inclusive name:start-end) gives the expected
SHA-256, every corrupt case is refused (non-zero exit, no output file). Prints a summary; exit 0 only if all pass."""
import hashlib, json, os, subprocess, sys, tempfile

W = os.path.dirname(os.path.abspath(__file__)); P = os.path.join(W, "pkg", "refrel3_cleanroom_v1"); TOOL = os.path.join(W, "refrel3v1")
sha = lambda b: hashlib.sha256(b).hexdigest()
exp = json.load(open(os.path.join(P, "EXPECTED.json")))
ok_dec = ok_fetch = n_fetch = ok_ref = 0
with tempfile.TemporaryDirectory() as t:
    for a in exp["archives"]:
        out = os.path.join(t, "x.fa")
        r = subprocess.run([TOOL, "decode", os.path.join(P, a["reference"]), os.path.join(P, a["archive"]), out], capture_output=True)
        ok_dec += r.returncode == 0 and sha(open(out, "rb").read()) == a["fasta_sha256"]
        os.remove(out)
        rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(P, a["fetch"]))][1:]
        args = ["%s:%d-%d" % (c, int(s) + 1, int(s) + int(n)) for c, s, n, _ in rows]
        r = subprocess.run([TOOL, "fetch", os.path.join(P, a["reference"]), os.path.join(P, a["archive"])] + args, capture_output=True)
        recs, cur = [], None
        for line in r.stdout.split(b"\n"):
            if line.startswith(b">"): cur = []; recs.append(cur)
            elif cur is not None and line: cur.append(line)
        for row, rec in zip(rows, recs):
            n_fetch += 1; ok_fetch += sha(b"".join(rec)) == row[3]
    for c in exp["corrupt"]:
        out = os.path.join(t, "y.fa")
        r = subprocess.run([TOOL, "decode", os.path.join(P, c["reference"]), os.path.join(P, c["archive"]), out], capture_output=True, timeout=60)
        refused = r.returncode != 0 and not os.path.exists(out)
        ok_ref += refused
        print("CORRUPT", c["archive"], "exit", r.returncode, r.stderr.decode().strip()[:80], "->", "refused" if refused else "NOT REFUSED")
        if os.path.exists(out): os.remove(out)
print(f"decode {ok_dec}/{len(exp['archives'])} == expected FASTA SHA-256; fetch {ok_fetch}/{n_fetch} (rows {sum(50 for _ in exp['archives'])}); corrupt refused {ok_ref}/{len(exp['corrupt'])}")
sys.exit(0 if ok_dec == len(exp["archives"]) and ok_fetch == n_fetch == 50 * len(exp["archives"]) and ok_ref == len(exp["corrupt"]) else 1)
