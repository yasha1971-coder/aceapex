"""zstd_legacy_py.py - claim head_zstd_legacy_reject, Python part (2.6.5, SEC-ZSTD-1): the Python package (aceapex,
ctypes over the C99 decoder) on the four archives of this directory: aceapex.open(data).decompress() and .read() of
the whole output. MODE check (the package's .so as built): zl_v1 decodes to its .expect, the other three raise
aceapex.DecodeError. MODE control (a .so built with -DAX_ZFRAME_NO_CHECK): zl_skip_v1 decodes, and zl_v07 / zl_v1_v07
decode too when LEGACY=1 (the caller's libzstd decodes the v0.7 frame alone).
Usage: PYTHONPATH=python ACEAPEX_DECODE_SO=<so> python3 zstd_legacy_py.py DIR check|control [LEGACY]
Prints one line: zstd_legacy_py <mode> <pass|fail> <detail>."""
import os, sys
import aceapex

d, mode = sys.argv[1], sys.argv[2]
legacy = len(sys.argv) > 3 and sys.argv[3] == "1"
bad = n = 0; det = []
for nm in ("zl_v1", "zl_v07", "zl_v1_v07", "zl_skip_v1"):
    a = open(os.path.join(d, nm + ".aet"), "rb").read(); want = open(os.path.join(d, nm + ".expect"), "rb").read()
    if mode == "check": expect = 1 if nm == "zl_v1" else 0
    else: expect = 1 if (nm in ("zl_v1", "zl_skip_v1") or legacy) else -1
    ok = 0
    for ep in ("decompress", "read"):
        try:
            h = aceapex.open(a)
            got = h.decompress() if ep == "decompress" else h.read(0, len(want))
            h.close(); r = 1 if bytes(got) == want else 2
        except aceapex.DecodeError:
            r = 0
        if expect >= 0:
            n += 1
            if r == expect: ok += 1
            else: bad += 1; det.append("%s/%s=%d" % (nm, ep, r))
    det.append("%s:%s" % (nm, "n/a" if expect < 0 else "%d/2" % ok))
print("zstd_legacy_py\t%s\t%s\t%d/%d calls as expected %s" % (mode, "fail" if bad else "pass", n - bad, n, " ".join(det)))
sys.exit(1 if bad else 0)
