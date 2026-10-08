"""make_root.py <spec.json> - assemble a hash-bound INPUT_ROOT for hw-apex tools.verdict_refrel3 (B job): cohort.json,
native libraries + build receipts, runbook copy, `prepare`, plan.json. Archives must already be in the root (paths in
the spec are root-relative). Nothing here times anything. Run with the hw-apex venv python from the hw-apex checkout.
spec.json: {root, repo, run_id, windows (optional list), assemblies: [{assembly_id, fasta, source_url, source_sha256}],
  reference, refrel3: {q4k: [archive...], q16k: [...]}, bgzf: {default: [archive...], matched: [archive...], granule},
  zstd: [{archive, contig_map}...], lz4: [{archive, index}...], ozseg: {variants: [...], archives: [...]} | null,
  agc: {archive, reference, geometry, cohort_order} | null, libs: {refrel3, bgzf, zstd, lz4, openzl, agc}: absolute .so paths}"""
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path

spec = json.load(open(sys.argv[1])); R = Path(spec["root"]).resolve(); REPO = Path(spec["repo"]).resolve()
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
def ref(rel): p = R / rel; return {"path": rel, "bytes": p.stat().st_size, "sha256": sha(p)}
def put(rel, obj):
    p = R / rel; p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists(): p.unlink()
    p.write_text(json.dumps(obj, sort_keys=True, indent=2) + "\n")
    return ref(rel)

PINS = {"refrel3": "5b6d5cec0f5962a561ac48822a1b5c48793a5b47", "bgzf": "4b705e4fada8ee2b6b15746f725ee8ac51631803",
        "zstd": "f8745da6ff1ad1e7bab384bd1f9d742439278e99", "lz4": "ebb370ca83af193212df4dcbadcc5d87bc0de2f0",
        "openzl": "32246b48faee46807f84183dac4db479089f5445", "agc": "e67e3fc865a459779118d3d4e9fbdf42c70ba75e"}
GCC = subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.split("\n")[0]
RECEIPTS = {
 "refrel3": {"codec_version": "refrel3 v1 (research/refrel @ 5b6d5ce), hw-apex native/refrel3_reader.cpp", "flags": ["-std=c++17", "-O3", "-fPIC", "-shared", "-march=native", "-funroll-loops"],
             "dependencies": {"libzstd": "system 1.4.8 (Ubuntu 22.04)", "aceapex_api.cpp": "aceapex 5b6d5ce src/aceapex_api.cpp", "build_script": "review/axis3/build_refrel3_native.sh"}},
 "bgzf": {"codec_version": "1.24", "flags": ["-O3", "-std=gnu11", "-fPIC", "-shared"], "dependencies": {"htslib": "4b705e4fada8ee2b6b15746f725ee8ac51631803 (PACKAGE_VERSION=1.24, --with-libdeflate)", "libdeflate": "dd12ff2b36d603dbb7fa8838fe7e7176fcbd4f6f", "build_script": "review/axis3/build_bgzf_axis3.sh"}},
 "zstd": {"codec_version": "1.5.7", "flags": ["-O3", "-std=gnu11", "-fPIC", "-shared", "-DXXH_NAMESPACE=ZSTD_"], "dependencies": {"zstd": "v1.5.7 f8745da6ff1ad1e7bab384bd1f9d742439278e99, lib/libzstd.a", "seekable_format": "contrib/seekable_format/zstdseek_decompress.c of the same tree", "shim": "codecs/native/zstd_seekable.c"}},
 "lz4": {"codec_version": "1.10.0", "flags": ["-O3", "-fPIC", "-shared"], "dependencies": {"lz4": "v1.10.0 ebb370ca83af193212df4dcbadcc5d87bc0de2f0 (OpenZL 32246b4 submodule deps/lz4), lib/lz4.c", "shim": "review/axis3/native/lz4_indexed.c", "build_script": "review/axis3/build_lz4_native.sh"}},
 "openzl": {"codec_version": "0.3.0", "flags": ["-O3", "-fPIC", "-shared"], "dependencies": {"openzl": "32246b48faee46807f84183dac4db479089f5445 libopenzl.a", "zstd": "1.5.7 (submodule)", "lz4": "1.10.0 (submodule)", "shim": "review/axis3/native/openzl_reader.c"}},
 "agc": {"codec_version": "3.2.4", "flags": ["-O3", "-march=native", "-std=c++20", "-fPIC", "-shared"], "dependencies": {"agc": "e67e3fc865a459779118d3d4e9fbdf42c70ba75e libagc.a", "shim": "review/axis3/agc_shim.cpp", "build_script": "review/axis3/build_agc_v324.sh"}},
}

def lib_and_receipt(key, extra=None):
    src = Path(spec["libs"][key]); dst = R / "lib" / src.name; dst.parent.mkdir(exist_ok=True)
    if not dst.exists() or sha(dst) != sha(src): shutil.copy2(src, dst)
    rc = {"schema": "window-law-build-receipt-v1", "family_key": key, "source_commit": PINS[key], "compiler": GCC, "decoder_threads": 1,
          "library_sha256": sha(dst), "library_path": f"lib/{src.name}", "built_on": "ace-core", **RECEIPTS[key], **(extra or {})}
    return ref(f"lib/{src.name}"), put(f"lib/{src.name}.receipt.json", rc)

# cohort.json
cohort = {"schema": "window-law-corpus-v1", "assemblies": [{"assembly_id": a["assembly_id"], "fasta": ref(a["fasta"]), "source_url": a["source_url"], "source_sha256": a["source_sha256"]} for a in spec["assemblies"]]}
put("cohort.json", cohort)
# runbook copy
shutil.copy(REPO / "review/axis3/RUN.md", R / "RUN.md")
# prepare
if not (R / "prepared" / "prepared.json").exists():
    cmd = [sys.executable, "-m", "tools.verdict_refrel3", "prepare", "--root", str(R), "--manifest", "cohort.json", "--out", "prepared"]
    if spec.get("windows"): cmd += ["--windows", ",".join(str(w) for w in spec["windows"])]
    print(subprocess.run(cmd, cwd=REPO, check=True, capture_output=True, text=True).stdout)
harness = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
variants = []
L, C = lib_and_receipt("refrel3")
for q in ("q4k", "q16k"):
    variants.append({"id": f"refrel3_{q}", "family": "refrel3", "variant": q, "library": L, "build_receipt": C, "reference": ref(spec["reference"]),
                     "archives": [{"assembly_id": a["assembly_id"], "archive": ref(p)} for a, p in zip(spec["assemblies"], spec["refrel3"][q])]})
L, C = lib_and_receipt("bgzf")
for v, key in (("default", "default"), ("matched-g", "matched")):
    row = {"id": f"bgzf_{key}", "family": "bgzf", "variant": v, "library": L, "build_receipt": C,
           "archives": [{"assembly_id": a["assembly_id"], "archive": ref(p), "fai": ref(p + ".fai"), "gzi": ref(p + ".gzi")} for a, p in zip(spec["assemblies"], spec["bgzf"][key])]}
    if v == "matched-g": row["granule_raw_bytes"] = spec["bgzf"]["granule"]
    variants.append(row)
L, C = lib_and_receipt("zstd")
variants.append({"id": "zstd_seekable_l3_f16k", "family": "zstd-seekable", "variant": "seekable_compression level 3, frame 16384 B", "library": L, "build_receipt": C,
                 "archives": [{"assembly_id": a["assembly_id"], "archive": ref(z["archive"]), "contig_map": ref(z["contig_map"])} for a, z in zip(spec["assemblies"], spec["zstd"])]})
L, C = lib_and_receipt("lz4")
variants.append({"id": "lz4_indexed_b4m", "family": "lz4-indexed", "variant": "LZ4_compress_default, independent 4 MiB blocks", "library": L, "build_receipt": C,
                 "archives": [{"assembly_id": a["assembly_id"], "archive": ref(z["archive"]), "index": ref(z["index"])} for a, z in zip(spec["assemblies"], spec["lz4"])]})
L, C = lib_and_receipt("openzl")
oz = spec.get("ozseg") or {}
for v in oz.get("variants", ["l1_w64k"]):
    arcs = oz["archives"][v] if isinstance(oz.get("archives"), dict) else (oz.get("archives") or [oz["placeholder"]] * len(spec["assemblies"]))
    variants.append({"id": f"ozseg_{v}", "family": "ozseg", "variant": v, "library": L, "build_receipt": C,
                     "archives": [{"assembly_id": a["assembly_id"], "archive": ref(p)} for a, p in zip(spec["assemblies"], arcs)]})
ag = spec.get("agc") or {}
note = R / "agc" / "GEOMETRY_MISSING.note.txt"; note.parent.mkdir(exist_ok=True)
note.write_text("AGC 3.2.4 (e67e3fc) exposes no independently decodable canonical granule through its public API. The frozen B job accepts only "
                "instrumented source-level evidence (schema agc-canonical-geometry-v1: canonical_unit_sizes + source log). The create parameter -s 60000, "
                "the metadata-pack size or any guessed value is not accepted. No such artifact exists: AGC is FAILED in this run, not measured.\n")
put("agc/GEOMETRY_MISSING.json", {"schema": "agc-canonical-geometry-v1-MISSING", "status": "no retained source-level evidence of independently decodable canonical units",
                                  "source_commit": PINS["agc"], "archive_sha256": sha(R / ag["archive"]), "domain": "canonical-sequence",
                                  "independent_unit_definition": "", "canonical_unit_sizes": [], "source_log": ref("agc/GEOMETRY_MISSING.note.txt")})
L, C = lib_and_receipt("agc", {"create_calls": ag.get("create_calls", 1), "append_calls": 0, "mode": "t2t", "cohort_order": ag.get("cohort_order", [a["assembly_id"] for a in spec["assemblies"]])})
variants.append({"id": "agc_t2t", "family": "agc", "variant": "t2t", "library": L, "build_receipt": C, "archive": ref(ag["archive"]), "reference": ref(ag["reference"]), "geometry": ref(ag["geometry"])})
plan = {"schema": "window-law-plan-v1", "run_id": spec["run_id"], "harness_commit": harness, "scope": "cpu-in-process", "threads": 1, "seed": 20261003,
        "dq_warmups": 3, "dq_repeats": 9, "runbook": ref("RUN.md"), "prepared": ref("prepared/prepared.json"), "variants": variants}
put("plan.json", plan)
print("plan.json written:", len(variants), "variants; harness", harness)
