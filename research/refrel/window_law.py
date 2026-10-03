#!/usr/bin/env python3
"""window_law.py - the block-size choice of refrel3 from the run_colab_r3.sh logs (research; nothing is frozen by it).
Window law: a window of W bases at block size Q decodes on average W + Q - 1 bases, so windows/s ~ D_Q / (W + Q - 1),
D_Q = the full-decode rate at block size Q (bases/s). Q* = argmax over Q of D_Q / (W + Q - 1) subject to r(Q) <= r_target,
r(Q) = size per assembly at Q / size at Q = 16384. Prints: sizes, D_Q, predicted vs measured windows/s, Q* per W and
r_target, from the measured windows/s and from the law.
Usage: python3 window_law.py <run dir with build_<Q>.txt and curves_<Q>.txt>"""
import glob, os, re, sys

d = sys.argv[1]
Qs = sorted(int(re.search(r"build_(\d+)\.txt", f).group(1)) for f in glob.glob(os.path.join(d, "build_*.txt")))
size, DQ, meas = {}, {}, {}
for Q in Qs:
    v = [int(l.split()[3]) for l in open(os.path.join(d, f"build_{Q}.txt")) if l.startswith("R3SIZE")]
    if v: size[Q] = sum(v) / len(v)
    for l in open(os.path.join(d, f"curves_{Q}.txt")):
        f = l.rstrip("\n").split("\t")
        if f[0] == "FULLQ": DQ[(Q, f[2])] = float(f[3].split()[0]) * 1e9
        if f[0] == "CURVE":
            W = int(f[2]); m = {"classic": float(re.search(r"classic ([\d.]+) w/s", l).group(1)), "queue": float(re.search(r"queue ([\d.]+) w/s", l).group(1)),
                                "raw": float(re.search(r"raw ([\d.]+) w/s", l).group(1))}
            meas[(Q, W)] = m
if 16384 not in size: sys.exit("no Q = 16384 run")
Ws = sorted({W for (_, W) in meas})
print("## sizes per assembly (mean of the four) and full-decode rate D_Q")
print("| Q | size, bytes | r(Q) | D_Q classic, GB/s | D_Q queue, GB/s |"); print("|---:|---:|---:|---:|---:|")
for Q in Qs:
    print(f"| {Q} | {size.get(Q, 0):,.0f} | {size.get(Q, 0) / size[16384]:.4f} | {DQ.get((Q, 'classic'), 0) / 1e9:.1f} | {DQ.get((Q, 'queue'), 0) / 1e9:.1f} |")
for kern in ("classic", "queue"):
    print(f"\n## {kern} kernel: measured windows/s and the law D_Q / (W + Q - 1)")
    print("| W | " + " | ".join(f"Q={Q} meas / law" for Q in Qs) + " |"); print("|---:|" + "---:|" * len(Qs))
    for W in Ws:
        cells = []
        for Q in Qs:
            m = meas.get((Q, W), {}).get(kern, 0); law = DQ.get((Q, kern), 0) / (W + Q - 1)
            cells.append(f"{m:,.0f} / {law:,.0f}")
        print(f"| {W} | " + " | ".join(cells) + " |")
targets = [1.00, 1.02, 1.05, 1.10, 1.25]
for kern in ("classic", "queue"):
    print(f"\n## Q* ({kern}): argmax windows/s subject to r(Q) <= r_target - measured (law)")
    print("| W | " + " | ".join(f"r <= {t:.2f}" for t in targets) + " |"); print("|---:|" + "---:|" * len(targets))
    for W in Ws:
        cells = []
        for t in targets:
            ok = [Q for Q in Qs if Q in size and size[Q] / size[16384] <= t + 1e-9]
            if not ok: cells.append("-"); continue
            qm = max(ok, key=lambda Q: meas.get((Q, W), {}).get(kern, 0)); ql = max(ok, key=lambda Q: DQ.get((Q, kern), 0) / (W + Q - 1))
            cells.append(f"{qm} ({ql})")
        print(f"| {W} | " + " | ".join(cells) + " |")
