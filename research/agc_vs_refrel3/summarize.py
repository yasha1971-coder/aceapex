"""summarize.py - SUMMARY.md from logs/*.log (RUN lines; timed runs only)."""
import glob, os, statistics
L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
def runs(label):
    t, items, nbytes, sha = [], 0, 0, []
    for l in open(os.path.join(L, label + ".log")):
        f = l.rstrip("\n").split("\t")
        if f[0] == "RUN":
            sha.append(f[7])
            if f[3] == "timed":
                t.append(float(f[4])); items = int(f[5].split()[0]); nbytes = int(f[6].split()[0])
    ok = all(s.split()[1].split("/")[0] == s.split()[1].split("/")[1] for s in sha)
    return t, items, nbytes, ok, len(sha)
FMT = [("refrel3 q4k", "rr3_q4k"), ("refrel3 q16k", "rr3_q16k"), ("AGC t2t_50", "agc_t2t_50"), ("AGC noref_50", "agc_noref_50")]
out = []
P = out.append
P("# AGC 3.2.4 vs refrel3 v1 - HPRC N=50, ace-core (AMD EPYC 4344P, 16 threads), CPU in process\n")
P("Truth: the 50 source FASTA (.fa.gz SHA-256 == manifest source_sha256), upper-case bases. Every answer SHA-256 == truth after every run (warm-ups included). 3 warm-ups + 9 timed runs; threads 1 = one thread pinned (taskset -c 3), 16 = 16 worker threads. Times are per run of the whole request set.\n")
def table(title, mode, unit):
    P(f"## {title}\n")
    P(f"| format | threads | median, s | min, s | max, s | 9 timed runs, s | {unit} | SHA-256 |")
    P("|---|---:|---:|---:|---:|---|---:|---|")
    for name, pre in FMT + ([("AGC CLI t2t_50 (one process, all requests)", "agccli_t2t_50"), ("AGC CLI noref_50 (one process)", "agccli_noref_50")] if mode in ("windows", "regions") else []):
        for T in (1, 16):
            lab = f"{pre}_{mode}_t{T}"
            if not os.path.exists(os.path.join(L, lab + ".log")):
                continue
            t, items, nb, ok, n = runs(lab)
            m = statistics.median(t)
            rate = f"{items / m:,.0f} /s; {nb / m / 1e9:.3f} GB/s" if mode != "sample4" else f"{nb / m / 1e9:.3f} GB/s; {m / items:.3f} s per sample"
            P(f"| {name} | {T} | {m:.4f} | {min(t):.4f} | {max(t):.4f} | {', '.join(f'{x:.4f}' for x in t)} | {rate} | {n * items}/{n * items} {'ok' if ok else 'FAIL'} |")
    P("")
table("Random windows: 10 000 x 8 192 bases (uniform over every valid start of the 50 samples, seed 20261003)", "windows", "windows/s; bases/s")
table("Regions: 1 000 (sample uniform, contig by length, length 1 .. 2^20, seed 20261005; 86.7 MB in total)", "regions", "regions/s; bases/s")
table("Whole samples: the first 4 (HG00438.1/.2, HG00621.1/.2; 11 989 829 249 bases)", "sample4", "rate")
P("## Whole samples: all 50, one timed run (one sample in memory at a time; time = sum of the per-sample decode times)\n")
P("| format | threads | total, s | s per sample | GB/s | SHA-256 |")
P("|---|---:|---:|---:|---:|---|")
for name, pre in FMT:
    for T in (1, 16):
        t, items, nb, ok, n = runs(f"{pre}_sample50_t{T}")
        P(f"| {name} | {T} | {t[0]:.3f} | {t[0] / items:.3f} | {nb / t[0] / 1e9:.3f} | {items}/{items} {'ok' if ok else 'FAIL'} |")
P("")
open(os.path.join(os.path.dirname(L), "SUMMARY_runs.md"), "w").write("\n".join(out) + "\n")
print("\n".join(out))
