#!/usr/bin/env python3
"""sync_axfast.py - one source for the FAST-profile decoder (FREEZE-2 b): src/ax_fast.h, c/ax_fast.h and
python/csrc/ax_fast.h are generated from aceapex-fast's axfast.c (the section between its "format and decoder" marker
and its XXH3 section) plus this repository's header preamble and closing #endif. scripts/axfast.lock pins the
aceapex-fast commit and the sha256 of its axfast.c.
Usage: sync_axfast.py AXFAST_C            write the three copies
       sync_axfast.py --check AXFAST_C    exit 1 unless axfast.c matches the lock and all three copies equal the output"""
import hashlib, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
COPIES = ["src/ax_fast.h", "c/ax_fast.h", "python/csrc/ax_fast.h"]
START = "/* ---- format and decoder (src/ax_fast.h, 2.6.1) ---- */\n"
END = "\n/* ---- XXH3-64"


def build(axfast: bytes) -> bytes:
    t = axfast.decode()
    i = t.index(START) + len(START); j = t.index(END, i)
    body = t[i:j]                                       # the decoder, from "#define AXF_VERSION" to its last line
    cur = (ROOT / "src/ax_fast.h").read_text()
    pre = cur[:cur.index("\n#define AXF_VERSION") + 1]  # the header comment, include guard and includes
    assert body.startswith("#define AXF_VERSION"), "axfast.c layout changed: decoder section not found"
    return (pre + body + "#endif\n").encode()


def main() -> int:
    check = sys.argv[1] == "--check"
    src = pathlib.Path(sys.argv[2 if check else 1]).read_bytes()
    lock = dict(l.split("=", 1) for l in (ROOT / "scripts/axfast.lock").read_text().split() if "=" in l)
    sha = hashlib.sha256(src).hexdigest()
    if sha != lock["axfast_c_sha256"]:
        print(f"axfast.c sha256 {sha} != lock {lock['axfast_c_sha256']} (aceapex-fast {lock['commit']})"); return 1
    out = build(src)
    if not check:
        for c in COPIES: (ROOT / c).write_bytes(out)
        print(f"wrote {len(COPIES)} copies from aceapex-fast {lock['commit']}"); return 0
    bad = [c for c in COPIES if (ROOT / c).read_bytes() != out]
    print(("FAIL: differ from aceapex-fast " + lock["commit"] + ": " + ", ".join(bad)) if bad else
          f"ax_fast.h x{len(COPIES)} == decoder of aceapex-fast {lock['commit']} (axfast.c sha256 {sha[:16]}...)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
