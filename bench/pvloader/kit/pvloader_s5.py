#!/usr/bin/env python3
"""S5 capacity: storage the FASTA baselines need for N=50 and N=558, vs panvram 11.6 GB
VRAM. CPU. Measures the local assemblies' bgzip .fa.gz size and decompressed length
(.fai), extrapolates by mean per-assembly size. Also reports whether each fits on ace-core
disk (878 GB) / RAM (125 GB)."""
import argparse, glob, json, os, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asmdir", required=True)
    ap.add_argument("--cohort", required=True)
    ap.add_argument("--panvram-q4k-bytes", type=int, default=12330370123)  # 558 q4k (frag_a4)
    ap.add_argument("--panvram-vram-gb", type=float, default=11.6)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    gz = sorted(glob.glob(os.path.join(a.asmdir, "*.fa.gz")))
    per = []
    for f in gz:
        fai = f + ".fai"
        bases = 0
        if os.path.exists(fai):
            bases = sum(int(l.split("\t")[1]) for l in open(fai))
        per.append(dict(stem=os.path.basename(f)[:-6], gz_bytes=os.path.getsize(f), bases=bases))
    n = len(per)
    mean_gz = sum(p["gz_bytes"] for p in per) / n
    mean_bases = sum(p["bases"] for p in per) / n       # decompressed uint8 = 1 byte/base
    GB = 1024**3; TB = 1024**4
    def row(N):
        return dict(N=N,
                    bgzip_fasta_GB=round(mean_gz * N / GB, 1),
                    memmap_uint8_GB=round(mean_bases * N / GB, 1),
                    memmap_uint8_TB=round(mean_bases * N / TB, 3))
    panvram_disk_GB = round(a.panvram_q4k_bytes / GB, 2)
    out = dict(
        measured=dict(n_assemblies=n, mean_gz_GB=round(mean_gz/GB,2), mean_bases_Gbp=round(mean_bases/1e9,3),
                      assemblies=[p["stem"] for p in per]),
        baseline_storage={"N50": row(50), "N558": row(558)},
        panvram={"q4k_disk_558_GB": panvram_disk_GB, "vram_resident_GB": a.panvram_vram_gb,
                 "note": "panvram is resident in VRAM (11.6 GB) and decodes windows on-card; no per-assembly files"},
        fit=dict(ace_core_disk_GB=878, ace_core_ram_GB=125,
                 N50_memmap_fits_disk=(mean_bases*50/GB < 878),
                 N50_memmap_fits_ram=(mean_bases*50/GB < 125),
                 N558_memmap_fits_disk=(mean_bases*558/GB < 878),
                 N558_memmap_fits_ram=(mean_bases*558/GB < 125)),
        ratio=dict(memmap_N558_over_panvram_vram=round((mean_bases*558/GB)/a.panvram_vram_gb,1),
                   bgzip_N558_over_panvram_vram=round((mean_gz*558/GB)/a.panvram_vram_gb,1)))
    json.dump(out, open(a.out, "w"), indent=2)
    print(json.dumps({"baseline_storage": out["baseline_storage"], "panvram": out["panvram"],
                      "ratio": out["ratio"], "fit": out["fit"]}, indent=2))

if __name__ == "__main__":
    main()
