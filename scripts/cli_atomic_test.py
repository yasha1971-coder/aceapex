#!/usr/bin/env python3
"""cli_atomic_test.py - claim head_cli_atomic (FREEZE-4): `aceapex d --in A --out FILE` writes FILE only when the decode
succeeds and its XXH3 matches the header. 40 archives with one random bit flipped after the header (levels 1, 2, 3, 11, 14;
seeded text input, 1 MB): exit 1 and no FILE, no temporary file left; an intact archive gives FILE == input; a failed
decode over an existing FILE leaves it as it was. Prints one judge line. Usage: cli_atomic_test.py ./aceapex [PER_LEVEL=8]
(PER_LEVEL 40 = the 200-corruption run of FREEZE-4)."""
import os, random, subprocess, sys, tempfile, glob, shutil
cli = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "./aceapex"); per = int(sys.argv[2]) if len(sys.argv) > 2 else 8
d = tempfile.mkdtemp(prefix="ax_atomic_"); r = random.Random(20261105)
words = [b"the ", b"archive ", b"of ", b"block ", b"genome\n", b"decoder "]
src = b"".join(words[r.randrange(6)] for _ in range(200000))[:1000000]
open(f"{d}/in", "wb").write(src)
bad = present = tmpleft = 0; n = 0
for L in (1, 2, 3, 11, 14):
    subprocess.run([cli, "c", "--in", f"{d}/in", "--out", f"{d}/z.aet", "--level", str(L)], capture_output=True, check=True)
    z = open(f"{d}/z.aet", "rb").read()
    for _ in range(per):
        b = bytearray(z); b[r.randrange(68, len(b))] ^= 1 << r.randrange(8); open(f"{d}/m.aet", "wb").write(b)
        out = f"{d}/out"
        if os.path.exists(out): os.remove(out)
        p = subprocess.run([cli, "d", "--in", f"{d}/m.aet", "--out", out], capture_output=True); n += 1
        bad += p.returncode != 1; present += os.path.exists(out); tmpleft += len(glob.glob(out + ".aceapex-tmp.*"))
subprocess.run([cli, "c", "--in", f"{d}/in", "--out", f"{d}/z.aet", "--level", "1"], capture_output=True, check=True)
out = f"{d}/ok"; intact = subprocess.run([cli, "d", "--in", f"{d}/z.aet", "--out", out], capture_output=True).returncode == 0 and open(out, "rb").read() == src
open(out, "wb").write(b"keep"); b = bytearray(open(f"{d}/z.aet", "rb").read()); b[len(b) * 3 // 4] ^= 0x20; open(f"{d}/m.aet", "wb").write(b)
kept = subprocess.run([cli, "d", "--in", f"{d}/m.aet", "--out", out], capture_output=True).returncode == 1 and open(out, "rb").read() == b"keep"
shutil.rmtree(d)
ok = bad == 0 and present == 0 and tmpleft == 0 and intact and kept
print(f"head_cli_atomic\t{'pass' if ok else 'fail'}\taceapex d --out FILE on {n} one-bit-flip archives (levels 1,2,3,11,14): exit 1 in {n - bad}, FILE created {present}, temp files left {tmpleft}; intact archive -> FILE == input: {intact}; failed decode over an existing FILE leaves it: {kept}")
sys.exit(0 if ok else 1)
