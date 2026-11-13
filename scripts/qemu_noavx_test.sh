#!/usr/bin/env bash
# qemu_noavx_test.sh - release gate "CPU without AVX-512" (2.6.2), dynamic part: a static x86-64 CLI under qemu-x86_64
# -cpu Haswell (qemu 6.2 TCG gives neither AVX2 nor AVX-512: the SSE4.2 / scalar paths run; an AVX / AVX-512 instruction
# outside the CPU dispatch would end in SIGILL). Usage: qemu_noavx_test.sh STATIC_CLI [INPUT >= 16 MiB]
#   1) the CPU the program sees: no avx2, no avx512f (a static probe under the same qemu)
#   2) every conformance fixture with no decode environment decodes to its sha256
#   3) round trip of 16 MiB of INPUT (default: the first 16 MiB of silesia.tar), levels 1 2 3 4 11 14, threads 1 and 4
# Prints qemu_cpu / qemu_conformance / qemu_roundtrip lines and exits 1 on any failure.
set -u
B=$1; IN=${2:-/tmp/hwref/corpus/silesia.tar}; F=verify/fixtures/conf; T=$(mktemp -d); Q="qemu-x86_64 -cpu Haswell"; bad=0
printf '#include <stdio.h>\nint main(){__builtin_cpu_init();printf("avx2=%%d avx512f=%%d\\n",!!__builtin_cpu_supports("avx2"),!!__builtin_cpu_supports("avx512f"));return 0;}\n' > $T/p.c
gcc -O2 -static -o $T/p $T/p.c && c=$($Q $T/p)
[ "$c" = "avx2=0 avx512f=0" ] && v=pass || { v=fail; bad=1; }
printf 'qemu_cpu\t%s\t%s -cpu Haswell, the program sees: %s\n' $v "$(qemu-x86_64 --version | head -1)" "$c"
n=0; f=0
while IFS=$'\t' read -r name size sha env; do
  [ -z "$name" ] || [ "${name:0:1}" = "#" ] || [ "$env" != "-" ] && continue
  n=$((n+1)); $Q $B d --in $F/$name.aet --out $T/o >/dev/null 2>&1; got=$(sha256sum $T/o 2>/dev/null | cut -c1-64)
  [ "$got" = "$sha" ] || { f=$((f+1)); echo "  conformance $name: $got" >&2; }; rm -f $T/o
done < $F/manifest.tsv
[ $f = 0 ] && [ $n -gt 0 ] && v=pass || { v=fail; bad=1; }
printf 'qemu_conformance\t%s\t%d fixtures decoded under qemu, %d with another sha256\n' $v $n $f
head -c 16777216 "$IN" > $T/in; n=0; f=0
for L in 1 2 3 4 11 14; do for th in 1 4; do n=$((n+1))
  if $Q $B c --in $T/in --out $T/a.aet --level $L --threads $th >/dev/null 2>&1 && $Q $B d --in $T/a.aet --out $T/o --threads $th >/dev/null 2>&1 && cmp -s $T/in $T/o
  then :; else f=$((f+1)); echo "  roundtrip L$L t$th" >&2; fi; rm -f $T/a.aet $T/o
done; done
[ $f = 0 ] && v=pass || { v=fail; bad=1; }
printf 'qemu_roundtrip\t%s\t%d round trips under qemu (16 MiB of %s, levels 1 2 3 4 11 14, threads 1 and 4), %d failed\n' $v $n "$(basename $IN)" $f
rm -rf $T; exit $bad
