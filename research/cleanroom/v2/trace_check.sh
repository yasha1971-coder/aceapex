#!/usr/bin/env bash
# trace_check.sh <repro work dir> <TEST_VECTORS.json> <ABS fixture dir> - rANS events (every symbol and raw-bit field: context, symbol,
# state, stream position) of every block in the vectors, from specdec.py and from a traced copy of the frozen v1 code
# (5b6d5ce sources, two printf lines added to a COPY of the entropy-coder header); all must be equal. Not shipped.
set -euo pipefail
W=$(cd "$1" && pwd); TV=$(realpath "$2"); H=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d "$W/trace.XXXX"); cp -r "$W/src" "$T/"
python3 "$H/trace_patch.py" "$T/src/research/refrel/refrel3.h"
cp "$H/trace.cpp" "$T/"
g++ -std=c++17 -O2 -I"$T/src/src" -I"$T/src/research/refrel" "$T/trace.cpp" "$T/src/src/aceapex_api.cpp" -lzstd -lpthread -o "$T/trace"
XXH3_BIN="$W/xxh3_stdin" python3 "$H/trace_compare.py" "$W" "$T/trace" "$TV" "$(cd "$3" && pwd)"
