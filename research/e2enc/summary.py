#!/usr/bin/env python3
"""E2-ENC: median table per step / corpus / level from bench.sh TSVs. Usage: summary.py <tsv>... (base step first)."""
import csv, statistics as S, sys
rows = [r for f in sys.argv[1:] for r in csv.DictReader(open(f), delimiter="\t")]
key = lambda r: (r["step"], r["corpus"], int(r["level"]))
groups = {}
for r in rows: groups.setdefault(key(r), []).append(r)
base = {}
print("| step | corpus | level | ratio % | comp MB/s (med, min-max) | dec MB/s (med) | archive sha256 | vs first step: ratio pp / comp / dec |")
print("|---|---|---|---|---|---|---|---|")
for k in sorted(groups, key=lambda k: (k[1], k[2], [r['step'] for r in rows].index(k[0]))):
    g = groups[k]
    if all(r["run"] == "0" for r in g):   # RUNS=0: archive only (size, sha256), compared with the first step that has the pair
        b = base.get((k[1], k[2])); same = "" if b is None else ("sha256 == " + b[3] if g[0]["archive_sha256"][:12] == b[3] else "sha256 DIFFERS from " + b[3])
        print(f"| {k[0]} | {k[1]} | {k[2]} | {float(g[0]['ratio_pct']):.3f} | - | - | {g[0]['archive_sha256'][:12]} | {same} |"); continue
    c = [float(r["c_mbs"]) for r in g]; d = [float(r["d_mbs"]) for r in g if r["d_mbs"] not in ("", "n/a")]
    rat = float(g[0]["ratio_pct"]); cm = S.median(c); dm = S.median(d) if d else float("nan")
    b = base.setdefault((k[1], k[2]), (rat, cm, dm, g[0]["archive_sha256"][:12]))
    rel = "" if b[:3] == (rat, cm, dm) else f"{rat - b[0]:+.3f} / {(cm / b[1] - 1) * 100:+.1f} % / {(dm / b[2] - 1) * 100:+.1f} %"
    print(f"| {k[0]} | {k[1]} | {k[2]} | {rat:.3f} | {cm:.2f} ({min(c):.2f}-{max(c):.2f}) | {dm:.1f} | {g[0]['archive_sha256'][:12]} | {rel} |")
