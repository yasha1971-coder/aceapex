#!/usr/bin/env bash
# Bring lz/aceapex in an lzbench checkout up to this tree (PR "aceapex 2.1.0").
# usage: scripts/lzbench_sync.sh <path-to-lzbench>   (run from the aceapex repo root)
# Copies the codec sources verbatim, drops the unused acepx3.cpp, points the wrapper at
# aceapex_decompress_mt (threads=1 spawns nothing under lzbench -T), makes the CUDA
# header take aceapex_streams_t from aceapex.h, and bumps the codec name. Idempotent.
set -euo pipefail
LZ=${1:?lzbench dir}; V=$(sed -n 's/#define ACEAPEX_VERSION_STRING "\(.*\)"/\1/p' src/aceapex.h)
for f in aceapex.h aceapex_api.cpp aceapex_main.cpp lit_fse.cpp ax_align.h xxhash.h; do cp src/$f "$LZ/lz/aceapex/$f"; done
rm -f "$LZ/lz/aceapex/acepx3.cpp"
python3 - "$LZ" "$V" <<'PY'
import sys, re
lz, v = sys.argv[1], sys.argv[2]
p = lz + '/lz/aceapex/aceapex_lzbench.cpp'; s = open(p).read()
s = s.replace("""    int thr = opts->threads > 0 ? opts->threads : (s ? s->threads : 1);
    int64_t r = aceapex_decompress(inbuf, insize, outbuf, outsize, thr);
    return r >= 0 ? (int64_t)outsize : -1;""",
"""    // thr == 1 (lzbench -T: one codec copy per pool thread) decodes on the calling
    // thread and spawns nothing; -I# gives the codec its own budget.
    int thr = opts->threads > 0 ? opts->threads : (s ? s->threads : 1);
    int64_t r = aceapex_decompress_mt(inbuf, insize, outbuf, outsize, thr);
    return r >= 0 ? r : -1;""")
open(p, 'w').write(s)
p = lz + '/lz/aceapex/cuda/aceapex_cuda.h'; s = open(p).read()
if 'aceapex_streams_t;' in s:
    i = s.index('// Raw decoded streams'); j = s.index('void aceapex_streams_free(aceapex_streams_t* s);') + len('void aceapex_streams_free(aceapex_streams_t* s);')
    s = s[:i] + '// aceapex_streams_t, aceapex_decode_streams and aceapex_streams_free come from the\n// codec\'s own header (lz/aceapex/aceapex.h) since ACEAPEX 2.1.0.\n#include "../aceapex.h"' + s[j:]
    open(p, 'w').write(s)
p = lz + '/bench/lzbench.h'; s = open(p).read()
s = re.sub(r'\{ "aceapex",    "aceapex [0-9.]+",', '{ "aceapex",    "aceapex %s",' % v, s)
open(p, 'w').write(s)
PY
cd "$LZ" && git status --short && echo "lz/aceapex == aceapex $V; build: make -j\$(nproc); test: ./lzbench -eaceapex,1,2 -t0,0 -i1,1 <tiny files>"
