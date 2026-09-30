#!/usr/bin/env bash
# Bring lz+entropy/aceapex in an lzbench checkout up to this tree (PR "aceapex X.Y.Z").
# usage: scripts/lzbench_sync.sh <path-to-lzbench>   (run from the aceapex repo root)
# Layout of lzbench master since 2.4.1 (27-30.09.2026): codecs with an entropy stage live in
# lz+entropy/<codec>/, each codec's build in mk/<codec>.mk (aceapex: one object,
# lz+entropy/aceapex/aceapex_lzbench.o, which #includes the library sources). Copies the codec
# sources verbatim (since ADR-018/019 also ax_rans.h, ax_lit_open.h), points the wrapper at
# aceapex_decompress_mt (threads=1 spawns nothing under lzbench -T) and sets the codec name.
# The CUDA decoder (lz+entropy/aceapex/cuda, aceapex_cuda 0.9) is not touched: its
# aceapex_streams_t has the same layout as the one in aceapex.h. Levels, algorithm string,
# README and CHANGELOG are edited by hand in lzbench style. Idempotent.
set -euo pipefail
LZ=${1:?lzbench dir}; V=$(sed -n 's/#define ACEAPEX_VERSION_STRING "\(.*\)"/\1/p' src/aceapex.h)
D="$LZ/lz+entropy/aceapex"
[ -d "$D" ] && [ -f "$LZ/mk/aceapex.mk" ] || { echo "$LZ: no lz+entropy/aceapex or mk/aceapex.mk (lzbench before 2.4.1?)"; exit 1; }
for f in aceapex.h aceapex_api.cpp aceapex_main.cpp lit_fse.cpp ax_align.h ax_rans.h ax_lit_open.h xxhash.h; do cp src/$f "$D/$f"; done
python3 - "$LZ" "$V" <<'PY'
import sys, re
lz, v = sys.argv[1], sys.argv[2]
p = lz + '/lz+entropy/aceapex/aceapex_lzbench.cpp'; s = open(p).read()
s = s.replace("""    int thr = opts->threads > 0 ? opts->threads : (s ? s->threads : 1);
    int64_t r = aceapex_decompress(inbuf, insize, outbuf, outsize, thr);
    return r >= 0 ? (int64_t)outsize : -1;""",
"""    // thr == 1 (lzbench -T: one codec copy per pool thread) decodes on the calling
    // thread and spawns nothing; -I# gives the codec its own budget.
    int thr = opts->threads > 0 ? opts->threads : (s ? s->threads : 1);
    int64_t r = aceapex_decompress_mt(inbuf, insize, outbuf, outsize, thr);
    return r >= 0 ? r : -1;""")
open(p, 'w').write(s)
p = lz + '/bench/lzbench.h'; s = open(p).read()
s = re.sub(r'\{ "aceapex",    "aceapex [0-9.]+",', '{ "aceapex",    "aceapex %s",' % v, s)
open(p, 'w').write(s)
PY
cd "$LZ" && git status --short && echo "lz+entropy/aceapex == aceapex $V; build: make -j\$(nproc); CI set: ./lzbench -eLZ -v5 ./lzbench; -eLZ+ENTROPY -v5 ./lzbench; -eSYMMETRIC -v5 ./lzbench; -eFASTEST -t0,0 -T2 -jr ."
