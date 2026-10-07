#!/usr/bin/env bash
# build_native_rest.sh <hw-apex checkout> <out dir> - the two libraries build_native.sh did not finish:
#   LZ4: S2's build_lz4_native.sh reads the version from LZ4_VERSION_STRING, which in lz4 1.10.0 is a macro
#        (LZ4_EXPAND_AND_QUOTE(LZ4_LIB_VERSION)), so its check fails on the right tree. Here the version comes from
#        LZ4_VERSION_MAJOR / MINOR / RELEASE (must be 1.10.0) and the script's own compile line is used unchanged.
#   zstd seekable: as codecs/zstd_seekable.sh, against zstd v1.5.7 (tag) built here.
set -euo pipefail
HW=$(cd "${1:?}" && pwd); O=$(cd "${2:?}" && pwd)
L=$O/openzl/openzl/deps/lz4
v=$(awk '/^#define LZ4_VERSION_(MAJOR|MINOR|RELEASE)/{printf "%s%s", s, $3; s="."}' "$L/lib/lz4.h")
[ "$v" = 1.10.0 ] || { echo "LZ4 $v != 1.10.0"; exit 2; }
cc -O3 -fPIC -shared -I"$L/lib" "$HW/review/axis3/native/lz4_indexed.c" "$L/lib/lz4.c" -o "$O/libhwa_lz4.so"
printf 'version=%s\nsource=%s\ncommit=%s\n' "$v" "$L" "$(git -C "$L" rev-parse HEAD)" > "$O/libhwa_lz4.so.receipt"
[ -e "$O/zstd" ] || git clone --quiet --branch v1.5.7 --depth 1 https://github.com/facebook/zstd.git "$O/zstd"
git -C "$O/zstd" describe --tags > "$O/zstd.VERSION.txt"; git -C "$O/zstd" rev-parse HEAD >> "$O/zstd.VERSION.txt"
make -C "$O/zstd/lib" -j2 libzstd.a > "$O/zstd.build.log" 2>&1
gcc -O3 -std=gnu11 -fPIC -shared -DXXH_NAMESPACE=ZSTD_ -I"$HW/harness" -I"$O/zstd/lib" -I"$O/zstd/lib/common" -I"$O/zstd/contrib/seekable_format" \
  "$HW/codecs/native/zstd_seekable.c" "$O/zstd/contrib/seekable_format/zstdseek_decompress.c" "$O/zstd/lib/libzstd.a" -pthread -o "$O/libhwa_zstd_seekable.so"
sha256sum "$O"/refrel3/libhwa_refrel3.so "$O"/bgzf/libhwa_bgzf.so "$O"/agc/libhwa_agc.so "$O"/openzl/libhwa_openzl.so "$O"/libhwa_lz4.so "$O"/libhwa_zstd_seekable.so | tee "$O/SHA256SUMS"
cat > "$O/env.sh" <<EOF
export HWAPEX_REFREL3_SO=$O/refrel3/libhwa_refrel3.so HWAPEX_BGZF_SO=$O/bgzf/libhwa_bgzf.so HWAPEX_HTSLIB_SO=$O/bgzf/libhwa_bgzf.so
export HWAPEX_AGC_SO=$O/agc/libhwa_agc.so HWAPEX_OPENZL_SO=$O/openzl/libhwa_openzl.so HWAPEX_LZ4_SO=$O/libhwa_lz4.so HWAPEX_ZSTD_SEEKABLE_SO=$O/libhwa_zstd_seekable.so
EOF
cat "$O/libhwa_lz4.so.receipt" "$O/zstd.VERSION.txt"
