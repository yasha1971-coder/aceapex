#!/usr/bin/env bash
# repro.sh <new work dir> - rebuild refrel3_cleanroom_v1.zip from nothing: frozen tool from 5b6d5ce, synthetic data,
# 24 archives, package, hash fixtures, SHA256SUMS == the committed copy, frozen-tool verification, then the ZIP with the
# entry order / mtime / mode of zip_entries_v1.tsv. Expected ZIP SHA-256 75ff3f60...; exit 0 only if it matches.
set -euo pipefail
ulimit -c 0
export TZ=UTC LC_ALL=C
H=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$H" rev-parse --show-toplevel)
W=${1:?usage: repro.sh <new work dir>}; [ -e "$W" ] && { echo "exists: $W"; exit 1; }
mkdir -p "$W/src"; W=$(cd "$W" && pwd); cd "$W"
cp "$H"/gen.py "$H"/build_pkg.py "$H"/add_hash_fixtures.py "$H"/add_swap_fixture.py "$H"/verify_pkg.py "$H"/opstat.cpp "$H"/blocks.cpp .

# frozen tool (g++ 11.4.0; FP contraction makes encoder bytes compiler-dependent)
git -C "$REPO" archive 5b6d5cec0f5962a561ac48822a1b5c48793a5b47 research/refrel src | tar -x -C src
g++ -std=c++17 -O3 -march=x86-64-v3 -funroll-loops -Isrc/src -Isrc/research/refrel src/research/refrel/refrel3v1.cpp src/src/aceapex_api.cpp -lzstd -lpthread -o refrel3v1
echo "tool $(sha256sum refrel3v1 | cut -c1-64) (expected b7d1842d340f32ddb2ae67fa4ebb67fdbdd1843378a46ab072c77bdc91b8a17a)"
sed '243s/^int main(int argc, char\*\* argv) {$/static int refrel3v1_main(int argc, char** argv) {/' src/research/refrel/refrel3v1.cpp > src/research/refrel/refrel3v1_nomain.cpp
g++ -std=c++17 -O2 -Isrc/src -Isrc/research/refrel blocks.cpp src/src/aceapex_api.cpp -lzstd -lpthread -o blocks
gcc -O2 -I"$REPO/src" "$REPO/research/agc_vs_refrel3/xxh3_stdin.c" -o xxh3_stdin

python3 gen.py data
mkdir arch
for a in asmA asmB asmC asmD asmE asmF; do for q in 4096 16384; do for h in hash nohash; do
  qn=$([ $q = 4096 ] && echo q4k || echo q16k); extra=$([ $h = nohash ] && echo nohash || echo "")
  ./refrel3v1 encode data/reference.fa $q 4 data/$a.fa arch/$a.$qn.$h.rr3 $extra > /dev/null
done; done; done

python3 build_pkg.py
X3="$W/xxh3_stdin" python3 add_hash_fixtures.py
X3="$W/xxh3_stdin" python3 add_swap_fixture.py
P=pkg/refrel3_cleanroom_v1
cp "$H/README_TASK.md" $P/README_TASK.md
(cd $P && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum > SHA256SUMS)
cmp $P/SHA256SUMS "$H/SHA256SUMS" && echo "SHA256SUMS == committed copy ($(wc -l < $P/SHA256SUMS) files)"
python3 verify_pkg.py

# ZIP with the original entry order, mtimes and modes
grep -v '^#' "$H/zip_entries_v1.tsv" | while IFS=$'\t' read -r name t mode; do chmod "$mode" "pkg/$name"; done
grep -v '^#' "$H/zip_entries_v1.tsv" | while IFS=$'\t' read -r name t mode; do touch -d "$t" "pkg/$name"; done
(cd pkg && grep -v '^#' "$H/zip_entries_v1.tsv" | cut -f1 | zip -q -X -@ "$W/refrel3_cleanroom_v1.zip")
S=$(sha256sum refrel3_cleanroom_v1.zip | cut -c1-64)
echo "zip $S $(stat -c %s refrel3_cleanroom_v1.zip) B"
[ "$S" = 75ff3f609399e738d69312fafab5a17ec034883632ea9822bd8921db5221cc79 ] && echo "REPRODUCED" || { echo "ZIP DIFFERS"; exit 1; }
