"""summarize.py - RESULTS_M6 tables and CSV curves from logs/N*/ (PROTOCOL_M6 v1.1 section 8). Reads only; writes
curves_timing.csv, curves_counters.csv, curves_zstd_sites.csv and prints the markdown tables to stdout."""
import csv, json, os, re, statistics as st, sys

D = os.path.dirname(os.path.abspath(__file__)); L = os.path.join(D, "logs"); NS = [50, 100, 200, 558]
ROWS = [(t, ds, k, T) for T in (1, 16) for t, ds in (("rr3", "q4k"), ("rr3", "q16k"), ("agc", None)) for k in ("win", "reg", "s4")]
KIND = {"win": "windows W = 4 096 (10 000)", "reg": "regions 1 Mb (100)", "s4": "whole samples (first 4)"}


def label(t, ds, k, T): return f"{t}_{ds}_{k}_t{T}" if ds else f"{t}_{k}_t{T}"


def parse_log(path):
    r = {"timed": [], "warm": [], "sha_ok": True, "items": None, "bytes": None, "rss": None, "open": None}
    for l in open(path):
        if l.startswith("RUN\t"):
            f = l.rstrip("\n").split("\t"); t = float(f[4]); r["items"] = int(f[5].split()[0]); r["bytes"] = int(f[6].split()[0])
            a, b = f[7].split()[1].split("/"); r["sha_ok"] &= a == b
            (r["timed"] if f[3] == "timed" else r["warm"]).append(t)
        elif l.startswith("OPEN\t"): r["open"] = float(l.rstrip("\n").split("\t")[-1].split()[0])
        elif "Maximum resident set size" in l: r["rss"] = int(l.split()[-1])
    return r


timing = []
for N in NS:
    for t, ds, k, T in ROWS:
        p = os.path.join(L, f"N{N}", label(t, ds, k, T) + ".log")
        if not os.path.exists(p): continue
        r = parse_log(p); x = r["timed"]
        if not x: continue
        med = st.median(x)
        timing.append({"N": N, "tool": t, "dataset": ds or "", "kind": k, "threads": T, "runs": len(x), "median_s": med, "min_s": min(x), "max_s": max(x),
                       "raw_s": " ".join(f"{v:.6f}" for v in x), "items": r["items"], "bytes": r["bytes"], "req_per_s": r["items"] / med,
                       "s_per_req": med / r["items"], "peak_rss_kb": r["rss"], "open_s": r["open"], "sha_ok": int(r["sha_ok"] and all(True for _ in r["warm"]))})
with open(os.path.join(D, "curves_timing.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(timing[0].keys())); w.writeheader(); w.writerows(timing)

# counters
CK = ["alloc_new_calls", "alloc_new_bytes", "alloc_delete_calls", "dctx_create", "zstd_calls", "zstd_in", "zstd_out", "desc_batch_names_load", "desc_batch_details_load",
      "batch_clear", "desc_contigs_scanned", "desc_segments_copied", "dc_desc_segments", "dc_desc_scanned", "dc_seg_decoded", "dc_seg_revcomp", "lz_ref_bytes", "lz_delta_bytes",
      "lz_out_bytes", "dc_assembled_bytes", "dc_returned_bytes", "conv_bytes", "dc_fast_false", "dc_fast_true", "dc_calls"]
cnt = []
for N in NS:
    for inp in ("cnt_win", "cnt_win_sorted", "cnt_reg"):
        p = os.path.join(L, f"N{N}", inp + ".req.tsv")
        if not os.path.exists(p): continue
        rows = list(csv.DictReader(open(p), delimiter="\t"))
        for key in CK:
            v = [int(r.get(key, 0) or 0) for r in rows]
            cnt.append({"N": N, "input": inp, "counter": key, "n": len(v), "median": st.median(v), "mean": st.mean(v), "p90": sorted(v)[int(0.9 * (len(v) - 1))], "max": max(v)})
with open(os.path.join(D, "curves_counters.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(cnt[0].keys())); w.writeheader(); w.writerows(cnt)
sites = []
for N in NS:
    for inp in ("cnt_win", "cnt_win_sorted", "cnt_reg"):
        p = os.path.join(L, f"N{N}", inp + ".zstd.tsv")
        if not os.path.exists(p): continue
        agg = {}
        nreq = len(set(r["id"] for r in csv.DictReader(open(p), delimiter="\t")))
        for r in csv.DictReader(open(p), delimiter="\t"):
            a = agg.setdefault(r["site"], [0, 0, 0, 0]); a[0] += 1; a[1] += int(r["calls"]); a[2] += int(r["in_bytes"]); a[3] += int(r["out_bytes"])
        for s, a in sorted(agg.items()):
            sites.append({"N": N, "input": inp, "site": s, "requests_with_site": a[0], "requests": nreq, "calls_per_request": a[1] / nreq, "in_bytes_per_request": a[2] / nreq, "out_bytes_per_request": a[3] / nreq})
with open(os.path.join(D, "curves_zstd_sites.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(sites[0].keys())); w.writeheader(); w.writerows(sites)


def md(x, nd=3): return f"{x:,.{nd}f}".replace(",", " ")


out = []
out.append("## Timing (median of 9 timed runs after 3 warm-ups; every answer of every run SHA-256 == truth)\n")
for k in ("win", "reg", "s4"):
    unit = "requests/s" if k != "s4" else "s per sample"
    out.append(f"### {KIND[k]} - {unit}\n")
    out.append("| N | AGC t1 | AGC t16 | refrel3 q4k t1 | refrel3 q4k t16 | refrel3 q16k t1 | refrel3 q16k t16 |")
    out.append("|---:|---:|---:|---:|---:|---:|---:|")
    for N in NS:
        cells = []
        for t, ds in (("agc", ""), ("rr3", "q4k"), ("rr3", "q16k")):
            for T in (1, 16):
                m = [r for r in timing if r["N"] == N and r["tool"] == t and r["dataset"] == ds and r["kind"] == k and r["threads"] == T]
                if not m: cells.append("-"); continue
                r = m[0]; cells.append(md(r["req_per_s"], 0) if k != "s4" else md(r["median_s"] / 4, 3))
        out.append(f"| {N} | " + " | ".join(cells) + " |")
    out.append("")
out.append("### Median seconds per row (min .. max), peak RSS GB\n")
out.append("| N | row | median s | min | max | RSS GB | open s |")
out.append("|---:|---|---:|---:|---:|---:|---:|")
for r in timing:
    out.append(f"| {r['N']} | {label(r['tool'], r['dataset'] or None, r['kind'], r['threads'])} | {r['median_s']:.4f} | {r['min_s']:.4f} | {r['max_s']:.4f} | {r['peak_rss_kb'] / 1e6:.2f} | {r['open_s']:.1f} |")
out.append("")
out.append("## Counters (counting build, one handle, one thread; medians per request)\n")
SHOW = ["zstd_calls", "zstd_in", "zstd_out", "dctx_create", "alloc_new_calls", "alloc_new_bytes", "desc_batch_names_load", "desc_batch_details_load", "batch_clear",
        "desc_contigs_scanned", "desc_segments_copied", "dc_desc_scanned", "dc_seg_decoded", "lz_ref_bytes", "lz_delta_bytes", "dc_assembled_bytes", "conv_bytes"]
for inp, title in (("cnt_win", "first 1 000 windows, file order"), ("cnt_win_sorted", "the same 1 000 windows sorted by (manifest order, contig, start)"), ("cnt_reg", "100 regions of 1 Mb")):
    out.append(f"### {title}\n")
    out.append("| counter | " + " | ".join(f"N={N}" for N in NS) + " |"); out.append("|---|" + "---:|" * len(NS))
    for key in SHOW:
        cells = []
        for N in NS:
            m = [c for c in cnt if c["N"] == N and c["input"] == inp and c["counter"] == key]
            cells.append(md(m[0]["median"], 0) if m else "-")
        out.append(f"| {key} | " + " | ".join(cells) + " |")
    out.append("")
out.append("### zstd call sites (windows, file order): calls and bytes per request\n")
out.append("| site | " + " | ".join(f"N={N} calls / in B / out B" for N in NS) + " |"); out.append("|---|" + "---|" * len(NS))
allsites = sorted(set(s["site"] for s in sites if s["input"] == "cnt_win"))
for s in allsites:
    cells = []
    for N in NS:
        m = [x for x in sites if x["N"] == N and x["input"] == "cnt_win" and x["site"] == s]
        cells.append(f"{m[0]['calls_per_request']:.2f} / {md(m[0]['in_bytes_per_request'], 0)} / {md(m[0]['out_bytes_per_request'], 0)}" if m else "-")
    out.append(f"| {s} | " + " | ".join(cells) + " |")
out.append("")
out.append("## Profile (perf, cycles:u, one thread, 10 000 windows; samples under agc_get_ctg_seq)\n")
for N in NS:
    sh = open(os.path.join(L, f"N{N}", "perf_parent_share.txt")).read().strip().replace("\n", "; ")
    run = [l for l in open(os.path.join(L, f"N{N}", "perf_run.log")) if l.startswith("RUN")][0].split("\t")[4]
    out.append(f"### N = {N}: profiled pass {float(run):.1f} s for 10 000 windows; share of samples: {sh}\n")
    for which, fn in (("self", "perf_self.txt"), ("children", "perf_children.txt")):
        rows = []
        for l in open(os.path.join(L, f"N{N}", fn)):
            m = re.match(r"\s+([0-9.]+)%\s+(?:([0-9.]+)%\s+)?\[(.)\]\s+(.*?)\s*$", l)
            if m: rows.append((float(m.group(1)), m.group(4)[:90]))
        rows = [r for r in rows if not r[1].startswith("0x")][:20]
        out.append(f"top 20 by {which} time:\n"); out.append("| % | symbol |"); out.append("|---:|---|")
        for p, sym in rows: out.append(f"| {p:.2f} | `{sym}` |")
        out.append("")
print("\n".join(out))
