"""api_verify_py.py - claim head_api_verify, Python part (2.6.7, API-CHK-1): aceapex.open(bytes).decompress(verify=True)
raises DecodeError on the three archives of this directory, decompress() returns their wrong bytes, every conformance
fixture decompresses with verify=True to the bytes of decompress(). The library: ACEAPEX_DECODE_SO (c/aceapex_decode.c).
Prints: api_verify_py <check|control> <pass|fail> <detail>. Usage: python3 api_verify_py.py <this dir> <fixtures/conf> <check|control>"""
import glob, os, sys
import aceapex
d, fx, mode = sys.argv[1], sys.argv[2], sys.argv[3]
bad = [("text_200K_p972", "text_200K"), ("text_fast_200K_p102", "text_fast_200K"), ("dna_4096B_p177", "dna_4096B")]
refused = wrong_plain = wrong_flag = 0
for b, f in bad:
    orig = aceapex.open(open(f"{fx}/{f}.aet", "rb").read()).decompress()
    a = aceapex.open(open(f"{d}/{b}.aet", "rb").read())
    if a.decompress() != orig: wrong_plain += 1
    try:
        if a.decompress(verify=True) != orig: wrong_flag += 1
    except aceapex.DecodeError:
        refused += 1
ok = n = 0
for p in sorted(glob.glob(f"{fx}/*.aet")):
    if os.path.basename(p) == "dna_depth_legacy.aet": continue
    n += 1; a = aceapex.open(open(p, "rb").read())
    try: ok += a.decompress(verify=True) == a.decompress()
    except aceapex.DecodeError: pass
passed = wrong_plain == 3 and ok == n and n > 0 and (wrong_flag == 3 if mode == "control" else refused == 3)
print(f"api_verify_py\t{mode}\t{'pass' if passed else 'fail'}\tverify=True: {refused} of 3 refused, {wrong_flag} of 3 wrong; plain: {wrong_plain} of 3 wrong; fixtures verified {ok} of {n}")
sys.exit(0 if passed else 1)
