#!/usr/bin/env python3
"""plot.py - window curves of research/refrel from the logs: RRWIN rows (CPU, refrel.cpp windows) and, when given, RGWIN
rows (GPU, refrel_gpu curves). Usage: python3 research/refrel/plot.py <out.png> <log>...   (GB/s and windows/s against W)"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

rows = {}
for path in sys.argv[2:]:
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if f[0] == "RRWIN":                       # RRWIN kind W n threads windows/s GB/s check
            key = f"CPU {f[1]}, {f[4]} thread{'s' if f[4] != '1' else ''}"; rows.setdefault(key, []).append((int(f[2]), float(f[5]), float(f[6])))
        elif f[0] == "RGWIN":                     # RGWIN kind W n windows/s GB/s host-us check
            key = f"GPU {f[1]}"; rows.setdefault(key, []).append((int(f[2]), float(f[4]), float(f[5])))
fig, ax = plt.subplots(1, 2, figsize=(10, 3.6))
for key, v in sorted(rows.items()):
    v.sort(); ls = "-" if "refrel" in key else "--"
    ax[0].plot([x[0] for x in v], [x[2] for x in v], ls, marker="o", label=key)
    ax[1].plot([x[0] for x in v], [x[1] for x in v], ls, marker="o", label=key)
for a in ax:
    a.set_xscale("log", base=2); a.set_yscale("log"); a.set_xlabel("window W, bases"); a.grid(alpha=.3)
ax[0].set_ylabel("GB/s of windows"); ax[1].set_ylabel("windows / s"); ax[0].legend(fontsize=7)
fig.tight_layout(); fig.savefig(sys.argv[1], dpi=160)
