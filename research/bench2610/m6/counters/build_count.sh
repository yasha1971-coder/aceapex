#!/usr/bin/env bash
# build_count.sh <out dir> - the COUNTING libagc: a copy of AGC e67e3fc src/ patched by patch_agc.py, compiled with the
# flags of the AGC makefile plus -g and -include cnt.h; 3rd-party libraries of the original build linked unchanged;
# agccount linked against it. The timed build (.wk/tools/agc-src) is not touched.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); G=$HOME/pubrepo/.wk/tools/agc-src; O=${1:?}; mkdir -p "$O"; O=$(cd "$O" && pwd)
[ "$(git -C "$G" rev-parse HEAD)" = e67e3fc865a459779118d3d4e9fbdf42c70ba75e ]
[ -e "$O/src" ] || cp -r "$G/src" "$O/src"
grep -q AGCCNT "$O/src/common/segment.cpp" || python3 "$H/patch_agc.py" "$O/src"
FL="-DREFRESH_USE_ZLIB -std=c++20 -Wall -fPIC -pthread -fpermissive -O3 -g -march=native -DARCH_X64 -DGIT_COMMIT=e67e3fc -I$O -I$G -I$G/3rd_party/mimalloc/include -I$G/3rd_party/zlib-ng/build-g++ -I$G/3rd_party/zlib-ng/build-g++/zlib-ng -I$G/3rd_party/libdeflate -I$G/3rd_party/zstd -I$G/3rd_party/raduls-inplace/Raduls -I$G/3rd_party"
OBJ=""
for s in lib-cxx/lib-cxx common/agc_basic common/agc_decompressor_lib common/archive common/collection common/collection_v1 common/collection_v2 common/collection_v3 common/lz_diff common/segment common/utils; do
  g++ $FL -include "$H/cnt.h" -c "$O/src/$s.cpp" -o "$O/$(basename $s).o" 2>&1 | grep -E "error" || true; OBJ="$OBJ $O/$(basename $s).o"; done
g++ -std=c++20 -O3 -g -march=native -I"$H/../../../agc_vs_refrel3" -I"$G/src/lib-cxx" -I"$G/3rd_party" "$H/agccount.cpp" $OBJ \
  $G/3rd_party/zstd/lib/libzstd.a $G/3rd_party/libdeflate/build/libdeflate.a $G/3rd_party/zlib-ng/build-g++/zlib-ng/libz.a $G/3rd_party/raduls-inplace/Raduls/libraduls.a -lpthread -l:libcrypto.so.3 -o "$O/agccount"
ls -l "$O/agccount"
