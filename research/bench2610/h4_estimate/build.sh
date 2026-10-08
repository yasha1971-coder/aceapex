#!/usr/bin/env bash
# build.sh <dir> - h4breaks against a copy of research/refrel @ 5b6d5ce with the cost hooks of ../h0_ledger/ledger_patch.py; h4agg
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$H" rev-parse --show-toplevel); O=${1:?}; mkdir -p "$O/src"; O=$(cd "$O" && pwd)
[ -e "$O/src/research/refrel/refrel3v1_nomain.cpp" ] || { git -C "$REPO" archive 5b6d5cec0f5962a561ac48822a1b5c48793a5b47 research/refrel src | tar -x -C "$O/src"
  python3 "$H/../h0_ledger/ledger_patch.py" "$O/src/research/refrel/refrel3.h"
  sed '243s/^int main(int argc, char\*\* argv) {$/static int refrel3v1_main(int argc, char** argv) {/' "$O/src/research/refrel/refrel3v1.cpp" > "$O/src/research/refrel/refrel3v1_nomain.cpp"; }
g++ -std=c++17 -O2 -I"$O/src/src" -I"$O/src/research/refrel" "$H/h4breaks.cpp" "$O/src/src/aceapex_api.cpp" -lzstd -lpthread -o "$O/h4breaks"
g++ -std=c++17 -O2 "$H/h4agg.cpp" -o "$O/h4agg"
