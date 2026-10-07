#!/usr/bin/env bash
# build_native.sh <hw-apex checkout> <out dir> - native shared libraries for the S2 native tests of hw-apex PR #63, each
# from its pinned source with the repository's own build script where one exists; prints the env lines for the tests.
#   refrel3   review/axis3/build_refrel3_native.sh against a local clone of aceapex at 5b6d5ce
#   BGZF      review/axis3/build_bgzf_axis3.sh (htslib 4b705e4, libdeflate dd12ff2) -> libhwa_bgzf.so (also the
#             FASTA+faidx row: same hwa_bgzf_* ABI on the same pinned htslib)
#   AGC       review/axis3/build_agc_v324.sh (e67e3fc) -> libhwa_agc.so
#   OpenZL    review/axis3/build_openzl_v030.sh (32246b4), then build_openzl_native.sh -> libhwa_openzl.so
#   LZ4       build_lz4_native.sh with LZ4_ROOT = the OpenZL submodule deps/lz4 (v1.10.0, checked by the script)
#   zstd      codecs/native/zstd_seekable.c against zstd v1.5.7 (tag, built here) as codecs/zstd_seekable.sh does
set -euo pipefail
HW=$(cd "${1:?hw-apex checkout}" && pwd); O=${2:?out}; mkdir -p "$O"; O=$(cd "$O" && pwd)
log() { echo "== $* $(date -u +%T)"; }
log refrel3; mkdir -p "$O/refrel3"
[ -e "$O/refrel3/aceapex" ] || { git clone --quiet "$HOME/pubrepo" "$O/refrel3/aceapex"; git -C "$O/refrel3/aceapex" checkout --quiet 5b6d5cec0f5962a561ac48822a1b5c48793a5b47; }
bash "$HW/review/axis3/build_refrel3_native.sh" "$O/refrel3"
log bgzf; bash "$HW/review/axis3/build_bgzf_axis3.sh" "$O/bgzf" > "$O/bgzf.build.log" 2>&1
log agc; bash "$HW/review/axis3/build_agc_v324.sh" "$O/agc" > "$O/agc.build.log" 2>&1
log openzl; bash "$HW/review/axis3/build_openzl_v030.sh" "$O/openzl" > "$O/openzl.build.log" 2>&1 || echo "build_openzl_v030.sh exit $? (see log; the library step is checked next)"
bash "$HW/review/axis3/build_openzl_native.sh" "$O/openzl"
log lz4; LZ4_ROOT="$O/openzl/openzl/deps/lz4" bash "$HW/review/axis3/build_lz4_native.sh" "$O/libhwa_lz4.so"
log zstd; [ -e "$O/zstd" ] || git clone --quiet --branch v1.5.7 --depth 1 https://github.com/facebook/zstd.git "$O/zstd"
git -C "$O/zstd" describe --tags > "$O/zstd.VERSION.txt"; make -C "$O/zstd/lib" -j2 libzstd.a > "$O/zstd.build.log" 2>&1
gcc -O3 -std=gnu11 -fPIC -shared -DXXH_NAMESPACE=ZSTD_ -I"$HW/harness" -I"$O/zstd/lib" -I"$O/zstd/lib/common" -I"$O/zstd/contrib/seekable_format" \
  "$HW/codecs/native/zstd_seekable.c" "$O/zstd/contrib/seekable_format/zstdseek_decompress.c" "$O/zstd/lib/libzstd.a" -pthread -o "$O/libhwa_zstd_seekable.so"
sha256sum "$O"/refrel3/libhwa_refrel3.so "$O"/bgzf/libhwa_bgzf.so "$O"/agc/libhwa_agc.so "$O"/openzl/libhwa_openzl.so "$O"/libhwa_lz4.so "$O"/libhwa_zstd_seekable.so | tee "$O/SHA256SUMS"
cat > "$O/env.sh" <<EOF
export HWAPEX_REFREL3_SO=$O/refrel3/libhwa_refrel3.so HWAPEX_BGZF_SO=$O/bgzf/libhwa_bgzf.so HWAPEX_HTSLIB_SO=$O/bgzf/libhwa_bgzf.so
export HWAPEX_AGC_SO=$O/agc/libhwa_agc.so HWAPEX_OPENZL_SO=$O/openzl/libhwa_openzl.so HWAPEX_LZ4_SO=$O/libhwa_lz4.so HWAPEX_ZSTD_SEEKABLE_SO=$O/libhwa_zstd_seekable.so
EOF
log done
