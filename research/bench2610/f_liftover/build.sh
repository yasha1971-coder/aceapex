#!/usr/bin/env bash
# build.sh <out dir> - chainstat against refrel3v1.cpp @ 5b6d5ce (git archive), main() renamed as in research/cleanroom
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$H" rev-parse --show-toplevel); O=${1:?out dir}; mkdir -p "$O/src"; O=$(cd "$O" && pwd)
git -C "$REPO" archive 5b6d5cec0f5962a561ac48822a1b5c48793a5b47 research/refrel src | tar -x -C "$O/src"
sed '243s/^int main(int argc, char\*\* argv) {$/static int refrel3v1_main(int argc, char** argv) {/' "$O/src/research/refrel/refrel3v1.cpp" > "$O/src/research/refrel/refrel3v1_nomain.cpp"
g++ -std=c++17 -O2 -I"$O/src/src" -I"$O/src/research/refrel" "$H/chainstat.cpp" "$O/src/src/aceapex_api.cpp" -lzstd -lpthread -o "$O/chainstat"
