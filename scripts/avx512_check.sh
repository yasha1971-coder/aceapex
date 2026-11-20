#!/usr/bin/env bash
# avx512_check.sh - release gate "CPU without AVX-512" (2.6.2), static part: AVX-512 instructions (zmm registers, mask
# registers k1-k7, embedded broadcast, AVX-512-only mnemonics) may appear only inside axr_decode_avx512 (src/ax_rans.h,
# chosen at run time only with AX_RANS_SIMD=512 in an ACEAPEX_ENV_TUNING build; the default rANS path is AVX2).
# Usage: avx512_check.sh NAME=FILE ...   (objects or executables). Control: inside axr_decode_avx512 the detector must
# find such instructions in at least one file (it sees EVEX code). glibc's own CPU-dispatched variants in a static binary
# (__memcpy_avx512_*, __strlen_evex, _dl_runtime_profile_avx512, ...: glibc picks them by CPUID, never on a CPU without AVX-512) are counted apart.
# Prints one line per file and avx512_static <pass|fail>.
set -u
re='%zmm|%k[1-7]|[{]1to|\b(kmov[bwdq]|kand|kor|kxor|knot|kshift|kunpck|kortest|ktest|vmovdqu(8|16|32|64)|vmovdqa(32|64)|vpternlog[dq]|vpermt2|vpermi2|vpcompress|vpexpand|vcompress|vexpand|vpbroadcastm|vpmovm2|vpmov[bwdq]2m|vpro[lr][dq]|vpro[lr]v|vpsravw|vpsllvw|vpsrlvw|vpermw|vpermb|vpmultishift|vpopcnt|vpconflict|vplzcnt|vpshld|vpshrd|vpabsq|vpm(ax|in)[su]q|vpmullq|vpsraq|valign[dq]|vshuf[if](32x4|64x2)|vinsert[if](32x4|32x8|64x2|64x4)|vextract[if](32x4|32x8|64x2|64x4)|vgetexp|vrndscale|vscalef|vfixupimm|vrange|vreduce|vfpclass|vcvt[a-z]*2u[dq]q?|vcvtu?qq2)'
bad=0; seen=0; det=""
for a in "$@"; do n=${a%%=*}; f=${a#*=}
  r=$(objdump -d --no-show-raw-insn -C "$f" 2>/dev/null | awk -v RE="$re" '
    /^[0-9a-f]+ <.*>:$/ { fn=$0; sub(/^[0-9a-f]+ </,"",fn); sub(/>:$/,"",fn); next }
    $0 ~ RE { if (fn ~ /axr_decode_avx512/) inside++; else if (fn ~ /^_+[a-z0-9_]*(avx512|evex)[a-z0-9_]*$/) libc++;
              else { out++; if (!(fn in shown)) { shown[fn]=1; list=list " " fn } } }
    END { printf "%d\t%d\t%s\t%d\n", inside+0, out+0, list, libc+0 }')
  in_=$(echo "$r" | cut -f1); out=$(echo "$r" | cut -f2); fns=$(echo "$r" | cut -f3 | cut -c1-300); lc=$(echo "$r" | cut -f4)
  [ "$in_" -gt 0 ] && seen=1; [ "$out" = 0 ] || bad=1
  printf 'avx512_file\t%s\t%s: %s AVX-512 instructions inside axr_decode_avx512, %s outside%s; glibc CPU-dispatched variants %s\n' "$([ "$out" = 0 ] && echo pass || echo fail)" "$n" "$in_" "$out" "${fns:+ (in:$fns)}" "$lc"
  det+=" $n $in_/$out;"
done
v=$([ $bad = 0 ] && [ $seen = 1 ] && echo pass || echo fail)
printf 'avx512_static\t%s\tinside/outside axr_decode_avx512:%s control (EVEX code seen inside): %s\n' $v "$det" "$([ $seen = 1 ] && echo yes || echo NO)"
[ $v = pass ]
