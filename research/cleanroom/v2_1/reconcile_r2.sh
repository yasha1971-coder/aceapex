#!/usr/bin/env bash
# reconcile_r2.sh <unzipped refrel3_cleanroom_v2_1 dir> <new work dir> - runs the round-2 clean-room decoder unchanged
# (research/cleanroom/round2/decoder.py, run_tests.py; only run_tests.py's three hard-coded paths are rewritten in a copy)
# against package v2.1, so its decodes / fetches / refusals / vectors can be compared with EXPECTED.json v2.1 (normative
# reasons). If python3 has no `xxhash` module, a ctypes stand-in (xxh3_64_intdigest only, seed 0) is built from
# src/xxhash.h into the work dir. Prints run_tests.py's summary and the corrupt lines; <work>/results.json.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$H" rev-parse --show-toplevel)
PKG=$(cd "${1:?usage: reconcile_r2.sh <pkg dir> <work dir>}" && pwd); W=${2:?usage}
[ -e "$W" ] && { echo "exists: $W"; exit 1; }
mkdir -p "$W/out"; W=$(cd "$W" && pwd)
cp "$H/../round2/decoder.py" "$W/"
sed -e "s|^PKG = .*|PKG = \"$PKG\"|" -e "s|^OUT = .*|OUT = \"$W/out\"|" -e "s|/home/claude/cr2/work/results.json|$W/results.json|" "$H/../round2/run_tests.py" > "$W/run_tests.py"
if ! python3 -c "import xxhash" 2>/dev/null; then
  printf '#define XXH_INLINE_ALL\n#include "xxhash.h"\nunsigned long long x3(const void* p, unsigned long n) { return XXH3_64bits(p, n); }\n' > "$W/x3.c"
  gcc -O2 -shared -fPIC -I"$REPO/src" "$W/x3.c" -o "$W/libx3.so"
  cat > "$W/xxhash.py" <<EOF
import ctypes
_l = ctypes.CDLL("$W/libx3.so"); _l.x3.restype = ctypes.c_ulonglong; _l.x3.argtypes = (ctypes.c_char_p, ctypes.c_ulong)
def xxh3_64_intdigest(b, seed=0):
    assert seed == 0; b = bytes(b); return _l.x3(b, len(b))
EOF
fi
cd "$W" && python3 run_tests.py
# the same refusals under the matching rule of FORMAT_V1_SPEC.md 1.0.1 section 5 (reason exact, or reason + " (detail)";
# the open-stage prefix "refused: " of the message is not part of the reason)
python3 - "$W/results.json" "$PKG/EXPECTED.json" <<'PY'
import json, sys
res, exp = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
want = {c["archive"]: c["reader_response"] for c in exp["corrupt"]}; n = ok = 0
for c in res["corrupt"]:
    w = want[c["archive"]]; m = c.get("message") or ""; m = m[len("refused: "):] if m.startswith("refused: ") else m
    good = c.get("refused") and c.get("stage") == w["stage"] and (m == w["reason"] or m.startswith(w["reason"] + " (")) and not c.get("output_written")
    n += 1; ok += bool(good)
    print("SPEC101", "ok " if good else "DIFF", c["archive"], "|", c.get("stage"), m, "| normative:", w["stage"], w["reason"])
print("refusals with normative stage and reason (1.0.1 section 5 rule): %d/%d" % (ok, n))
PY
