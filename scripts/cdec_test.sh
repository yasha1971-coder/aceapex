#!/usr/bin/env bash
# The standalone C decoder (c/aceapex_decode.c) against the fixtures: whole-archive decode
# by sha256 on every fixture, then 200 random ranges through the batch API compared with
# slices of the decoded bytes. No corpus needed. Output: claim_id <TAB> verdict <TAB> measured
set -uo pipefail; shopt -s nullglob
F=verify/fixtures; EXP=$(cat $F/chr1_4MiB.sha256); T=$(mktemp -d)
if ! ${CC:-gcc} -std=c99 -O2 -o $T/axdec c/axdec.c c/aceapex_decode.c -lzstd 2>$T/build.err; then
  printf 'head_cdecoder_fixtures\tfail\tbuild failed: %s\n' "$(head -c 200 $T/build.err | tr '\n\t' '  ')"
  rm -rf $T; exit 0
fi
ok=0; n=0; msg=""
for a in $F/chr1_4MiB.zstd-*.aet; do
  n=$((n+1)); v=${a##*zstd-}; v=${v%.aet}
  env -i PATH="$PATH" $T/axdec $a $T/o_$v >/dev/null 2>&1
  got=$(sha256sum $T/o_$v 2>/dev/null | cut -c1-64)
  if [ "$got" = "$EXP" ]; then ok=$((ok+1)); else msg="$msg $v:${got:0:12}"; fi
done
[ $n -gt 0 ] && [ $ok = $n ] && r=pass || r=fail
printf 'head_cdecoder_fixtures\t%s\t%d/%d fixtures decode to sha256 %s..%s\n' "$r" $ok $n "${EXP:0:12}" "$msg"
A=$(ls $F/chr1_4MiB.zstd-*.aet | head -n 1); O=$T/o_${A##*zstd-}; O=${O%.aet}
python3 - "$A" "$O" "$T" <<'PY'
import random, subprocess, sys
a,o,t=sys.argv[1:4]; ref=open(o,'rb').read(); N=len(ref); random.seed(2026)
rg=[]
for _ in range(200):
    l=random.choice([1,17,4096,16384,70000,300000]); rg.append((random.randrange(0,N-l+1),l))
open(t+'/r.txt','w').write(''.join(f'{o} {l}\n' for o,l in rg))
r=subprocess.run([t+'/axdec',a,t+'/r.out','-r',t+'/r.txt'],capture_output=True)
got=open(t+'/r.out','rb').read() if r.returncode==0 else b''
exp=b''.join(ref[o:o+l] for o,l in rg)
v='pass' if got==exp else 'fail'
print(f"head_cdecoder_ranges_200\t{v}\t200 random ranges via aceapex_decompress_ranges, {len(exp)} bytes, rc={r.returncode}")
PY
if [ -f $F/empty.aet ]; then
  $T/axdec $F/empty.aet $T/ce.out >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] && [ "$(stat -c%s $T/ce.out 2>/dev/null)" = 0 ] && r=pass || r=fail
  printf 'head_cdecoder_empty\t%s\tC decoder on empty.aet: rc=%s, %s bytes\n' "$r" "$rc" "$(stat -c%s $T/ce.out 2>/dev/null)"
fi
if [ -f $F/conf/manifest.tsv ]; then
  ok=0; n=0; bad=""
  while IFS=$'\t' read -r name sz sha denv; do
    n=$((n+1)); E=""; [ "$denv" != "-" ] && E="$denv"
    env -i PATH="$PATH" $E $T/axdec $F/conf/$name.aet $T/cc_$name >/dev/null 2>&1
    got=$(sha256sum $T/cc_$name 2>/dev/null | cut -c1-64)
    if [ "$got" = "$sha" ]; then ok=$((ok+1)); else bad="$bad $name"; fi
  done < $F/conf/manifest.tsv
  [ $n -gt 0 ] && [ $ok = $n ] && r=pass || r=fail
  printf 'head_conformance_cdecoder\t%s\t%d/%d fixtures decode to manifest sha256%s\n' "$r" $ok $n "${bad:+; failed:$bad}"
fi
# the pip package compiles its own copy of the decoder: it must be byte-identical to c/
if cmp -s c/aceapex_decode.c python/csrc/aceapex_decode.c && cmp -s c/aceapex_decode.h python/csrc/aceapex_decode.h \
   && cmp -s src/ax_rans.h c/ax_rans.h && cmp -s src/ax_rans.h python/csrc/ax_rans.h; then r=pass; else r=fail; fi
printf 'head_python_csrc_in_sync\t%s\tpython/csrc == c/ (aceapex_decode.c, .h) and ax_rans.h identical in src/, c/, python/csrc/\n' "$r"
# library round-trip through the C++ API (the CLI never exercises aceapex_compress):
# sizes across the adaptive block-size boundaries, both levels, several thread counts
if ${CXX:-g++} -std=c++17 -O2 -Isrc -o $T/api_rt scripts/api_roundtrip.cpp src/aceapex_api.cpp -lzstd -lpthread 2>$T/api.err; then
  $T/api_rt 2>/dev/null || true
else printf 'head_api_roundtrip\tfail\tbuild failed: %s\n' "$(head -c 150 $T/api.err | tr '\n\t' '  ')"; fi
# python layer over the same fixtures, without installing: ctypes loads a fresh .so
if python3 -c "import pytest" 2>/dev/null; then
  if ${CC:-gcc} -std=c99 -O2 -fPIC -shared -Ic -o $T/libaceapex_decode.so c/aceapex_decode.c -lzstd 2>/dev/null \
     && ACEAPEX_DECODE_SO=$T/libaceapex_decode.so PYTHONPATH=python python3 -m pytest -q python/tests >$T/py.log 2>&1; then r=pass; else r=fail; fi
  printf 'head_python_tests\t%s\t%s\n' "$r" "$(tail -n 1 $T/py.log | tr '\t' ' ' | head -c 120)"
else
  printf 'head_python_tests\tdeclared\tpytest not installed on this host\n'
fi
rm -rf $T
