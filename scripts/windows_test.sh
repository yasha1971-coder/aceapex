#!/usr/bin/env bash
# windows_test.sh - the CLI on Windows (CI job windows-msys2: windows-2022, MSYS2 UCRT64 gcc + zstd; run from the repo root
# in the msys2 shell). Gate of a release, threshold 0 failures:
#   1) every conformance fixture of verify/fixtures/conf/manifest.tsv that needs no decode environment decodes to its sha256
#   2) round trip: 8 MiB of text (the repository's sources repeated) and 4 MiB of seeded A/C/G/T lines, levels 1 2 3 4 11 14,
#      --threads 1 and 4, byte for byte
#   3) atomic --out: a one-bit flip after the 68-byte header -> exit 1 and no output file left
# Prints windows_conformance / windows_roundtrip / windows_cli_atomic lines (tab-separated) and exits 1 on any failure.
set -u
B=./aceapex.exe; F=verify/fixtures/conf; T=$(mktemp -d); bad=0
g++ -std=c++17 -O2 -DACEAPEX_CLI -Isrc -o $B src/aceapex_api.cpp -lzstd -lpthread || { printf 'windows_build\tfail\tg++ failed\n'; exit 1; }
printf 'windows_build\tpass\t%s; %s\n' "$($B --version 2>&1 | head -1)" "$(g++ --version | head -1)"
n=0; f=0
while IFS=$'\t' read -r name size sha env; do
  [ -z "$name" ] || [ "${name:0:1}" = "#" ] || [ "$env" != "-" ] && continue
  n=$((n+1)); $B d --in $F/$name.aet --out $T/o >/dev/null 2>&1; got=$(sha256sum $T/o 2>/dev/null | cut -c1-64)
  [ "$got" = "$sha" ] || { f=$((f+1)); echo "  conformance $name: $got" >&2; }; rm -f $T/o
done < $F/manifest.tsv
[ $f = 0 ] && [ $n -gt 0 ] && v=pass || { v=fail; bad=1; }
printf 'windows_conformance\t%s\t%d fixtures decoded, %d with another sha256\n' $v $n $f
for i in $(seq 1 60); do cat src/*.cpp src/*.h; done | head -c 8388608 > $T/text.bin
awk 'BEGIN{srand(20261113); s="ACGT"; for(i=0;i<69905;i++){l=""; for(k=0;k<60;k++) l=l substr(s,int(rand()*4)+1,1); print l}}' > $T/dna.fa
n=0; f=0
for in in $T/text.bin $T/dna.fa; do for L in 1 2 3 4 11 14; do for th in 1 4; do n=$((n+1))
  if $B c --in $in --out $T/a.aet --level $L --threads $th >/dev/null 2>&1 && $B d --in $T/a.aet --out $T/o --threads $th >/dev/null 2>&1 && cmp -s $in $T/o
  then :; else f=$((f+1)); echo "  roundtrip $(basename $in) L$L t$th" >&2; fi; rm -f $T/a.aet $T/o
done; done; done
[ $f = 0 ] && v=pass || { v=fail; bad=1; }
printf 'windows_roundtrip\t%s\t%d round trips (text %s B, DNA %s B, levels 1 2 3 4 11 14, threads 1 and 4), %d failed\n' $v $n "$(stat -c %s $T/text.bin)" "$(stat -c %s $T/dna.fa)" $f
$B c --in $T/text.bin --out $T/a.aet --level 1 >/dev/null 2>&1
python3 - "$T/a.aet" <<'PY'
import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[len(b)//2]^=1; open(sys.argv[1],'wb').write(b)
PY
$B d --in $T/a.aet --out $T/out.bin >/dev/null 2>&1; rc=$?; left=$(ls $T | grep -c 'out.bin')
[ $rc = 1 ] && [ "$left" = 0 ] && v=pass || { v=fail; bad=1; }
printf 'windows_cli_atomic\t%s\tcorrupt archive (one byte changed in the middle): exit %d, output files left %s\n' $v $rc "$left"
exit $bad
