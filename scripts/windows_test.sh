#!/usr/bin/env bash
# windows_test.sh - the library on Windows (CI job windows-msys2: windows-2022, MSYS2 UCRT64 gcc + zstd; run from the repo
# root in the msys2 shell). The CLI is Linux / macOS only (faidx and region map the archive with mmap, since 02.10.2026);
# Windows users get the library, as lzbench and TurboBench build it. Gate of a release, threshold 0 failures:
#   1) the library TU and scripts/lib_tool.cpp build with the host gcc
#   2) every conformance fixture of verify/fixtures/conf/manifest.tsv that needs no decode environment decodes through
#      aceapex_decompress_stream (+ VERIFY) and aceapex_decompress_mt to the same bytes, with the manifest's sha256
#   3) round trip through the API: 8 MiB of text (the repository's sources repeated) and 4 MiB of seeded A/C/G/T lines,
#      levels 1 2 3 4 11 14, threads 1 and 4, byte for byte
# Prints windows_build / windows_conformance / windows_roundtrip lines (tab-separated); exit 1 on any failure.
set -u
B=./lib_tool.exe; F=verify/fixtures/conf; T=$(mktemp -d); bad=0
g++ -std=c++17 -O2 -Isrc -o $B scripts/lib_tool.cpp src/aceapex_api.cpp -lzstd -lpthread || { printf 'windows_build\tfail\tg++ failed\n'; exit 1; }
printf 'windows_build\tpass\tlibrary %s; %s\n' "$(grep -o 'ACEAPEX_VERSION_STRING "[^"]*"' src/aceapex.h)" "$(g++ --version | head -1)"
n=0; f=0
while IFS=$'\t' read -r name size sha env; do
  [ -z "$name" ] || [ "${name:0:1}" = "#" ] || [ "$env" != "-" ] && continue
  n=$((n+1)); $B d $F/$name.aet $T/o >/dev/null 2>&1; got=$(sha256sum $T/o 2>/dev/null | cut -c1-64)
  [ "$got" = "$sha" ] || { f=$((f+1)); echo "  conformance $name: $got" >&2; }; rm -f $T/o
done < $F/manifest.tsv
[ $f = 0 ] && [ $n -gt 0 ] && v=pass || { v=fail; bad=1; }
printf 'windows_conformance\t%s\t%d fixtures decoded through the library (stream + VERIFY and decompress_mt), %d with another sha256\n' $v $n $f
for i in $(seq 1 60); do cat src/*.cpp src/*.h; done | head -c 8388608 > $T/text.bin
awk 'BEGIN{srand(20261113); s="ACGT"; for(i=0;i<69905;i++){l=""; for(k=0;k<60;k++) l=l substr(s,int(rand()*4)+1,1); print l}}' > $T/dna.fa
n=0; f=0
for in in $T/text.bin $T/dna.fa; do for L in 1 2 3 4 11 14; do for th in 1 4; do n=$((n+1))
  $B rt $in $L $th >/dev/null 2>&1 || { f=$((f+1)); echo "  roundtrip $(basename $in) L$L t$th" >&2; }
done; done; done
[ $f = 0 ] && v=pass || { v=fail; bad=1; }
printf 'windows_roundtrip\t%s\t%d round trips through the API (text %s B, DNA %s B, levels 1 2 3 4 11 14, threads 1 and 4), %d failed\n' $v $n "$(stat -c %s $T/text.bin)" "$(stat -c %s $T/dna.fa)" $f
rm -rf $T $B; exit $bad
