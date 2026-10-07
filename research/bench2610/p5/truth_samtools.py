"""truth_samtools.py <work dir> <requests.tsv> <out truth.tsv> - P5 truth: every request answered by samtools faidx
(htslib 1.24) on the uncompressed FASTA <work>/fa/<fasta key>.fa (1-based inclusive region contig:start+1-start+len),
the sequence lines joined, case kept; SHA-256 per request id. Requests are sent per FASTA in one samtools call; the
output records are matched to the requests in order (and their region header checked)."""
import hashlib, os, subprocess, sys, tempfile
W, reqf, outf = sys.argv[1:4]
ST = os.path.expanduser("~/build/htslib-latest/bin/samtools")
os.environ["LD_LIBRARY_PATH"] = os.path.expanduser("~/build/htslib-latest/lib")
rows = [l.rstrip("\n").split("\t") for l in open(reqf)][1:]
by = {}
for r in rows: by.setdefault(r[1], []).append(r)
res = {}
for key, rs in by.items():
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as t:
        for _, _, c, s, n in rs: t.write(f"{c}:{int(s) + 1}-{int(s) + int(n)}\n")
    p = subprocess.Popen([ST, "faidx", "-n", "1000000000", "-r", t.name, os.path.join(W, "fa", key + ".fa")], stdout=subprocess.PIPE)
    i, h, cur = -1, None, None
    def close():
        if cur is not None:
            want = f"{rs[i][2]}:{int(rs[i][3]) + 1}-{int(rs[i][3]) + int(rs[i][4])}"
            assert h == want, (h, want)
            res[rs[i][0]] = cur.hexdigest()
    for line in p.stdout:
        if line.startswith(b">"):
            close(); i += 1; h = line[1:].strip().decode(); cur = hashlib.sha256()
        else: cur.update(line.rstrip(b"\n"))
    close(); assert p.wait() == 0; os.unlink(t.name)
    assert i + 1 == len(rs), (key, i + 1, len(rs))
with open(outf, "w") as f:
    f.write("id\tsha256\n")
    for r in rows: f.write(f"{r[0]}\t{res[r[0]]}\n")
print(reqf, len(rows), "answers")
