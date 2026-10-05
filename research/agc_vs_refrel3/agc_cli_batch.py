"""agc_cli_batch.py <agc binary> <archive> <requests.tsv> <truth.tsv> <threads> <warmups> <runs> <label> - AGC CLI scope:
all requests in ONE process: agc getctg -t <threads> <archive> contig@sample:start-end ... (0-based inclusive), stdout
captured; wall time of the process; after every run (outside timing) each FASTA record joined, upper-cased, SHA-256 ==
truth, in request order. RUN lines as bench_common.h."""
import hashlib, subprocess, sys, time

agc, arc, reqf, truthf, T, WU, R, label = sys.argv[1:9]
T, WU, R = int(T), int(WU), int(R)
reqs = [l.rstrip("\n").split("\t") for l in open(reqf) if l.strip() and not l.startswith("id\t")]
truth = {}
for l in open(truthf):
    f = l.rstrip("\n").split("\t")
    if f[0] == "REQ":
        truth[f[1]] = f[2]
args = [agc, "getctg", "-t", str(T), arc] + [f"{c}@{s}:{int(st)}-{int(st) + int(n) - 1}" for (_, s, c, st, n) in reqs]
nbytes = sum(int(r[4]) for r in reqs)
bad = 0
for r in range(WU + R):
    t0 = time.perf_counter()
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    t = time.perf_counter() - t0
    recs, cur = [], None
    for line in p.stdout.split(b"\n"):
        if line.startswith(b">"):
            cur = []
            recs.append(cur)
        elif cur is not None and line:
            cur.append(line)
    ok = 0
    if p.returncode == 0 and len(recs) == len(reqs):
        for q, rec in zip(reqs, recs):
            ok += hashlib.sha256(b"".join(rec).upper()).hexdigest() == truth[q[0]]
    bad += ok != len(reqs)
    print(f"RUN\t{label}\t{r}\t{'warmup' if r < WU else 'timed'}\t{t:.6f}\t{len(reqs)} items\t{nbytes} bytes\tsha256 {ok}/{len(reqs)}", flush=True)
sys.exit(4 if bad else 0)
