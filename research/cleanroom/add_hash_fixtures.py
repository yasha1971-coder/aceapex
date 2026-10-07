"""add_hash_fixtures.py - three hash-targeted corrupt fixtures added to the existing package directory (not shipped):
  block_hash_byte.rr3      one byte of a stored per-block XXH3 changed, payload intact, header XXH3 recomputed so that
                           the header check passes and the block-hash check is what must fail
  fasta_xxh3_field.rr3     the header's source-FASTA XXH3 field changed, header XXH3 recomputed (everything else intact)
  blocks_swapped.rr3       two payload blocks of equal length swapped (block table unchanged, header untouched); kept
                           only if the frozen tool decodes both rANS streams and refuses on the block XXH3
Every case is run through the frozen tool; its exit code and message go to EXPECTED.json ("tool_response")."""
import json, os, struct, subprocess, sys

W = os.path.dirname(os.path.abspath(__file__)); P = os.path.join(W, "pkg", "refrel3_cleanroom_v1"); A = os.path.join(W, "arch")
TOOL = os.path.join(W, "refrel3v1"); BLK = os.path.join(W, "blocks"); X3 = os.environ.get("X3", os.path.join(W, "xxh3_stdin"))
REF = os.path.join(P, "reference", "reference.fa")


def geometry(path):
    out = subprocess.run([BLK, REF, path], capture_output=True, text=True, check=True).stdout.split("\n")
    g = {"blocks": []}
    for l in out:
        f = l.split()
        if not f: continue
        if f[0] == "PSTART": g["pstart"] = int(f[1])
        elif f[0] == "HASHES": g["hashes"] = int(f[1])
        elif f[0] == "B": g["blocks"].append((int(f[1]), int(f[2]), int(f[3])))
    return g


def rehash(b, pstart):
    b[128:136] = b"\0" * 8
    h = subprocess.run([X3], input=bytes(b[:pstart]), capture_output=True, check=True).stdout.decode().strip()
    b[128:136] = struct.pack("<Q", int(h, 16))


def tool(path, ref=REF):
    out = os.path.join(W, "tmp_out.fa")
    r = subprocess.run([TOOL, "decode", ref, path, out], capture_output=True, timeout=60)
    made = os.path.exists(out)
    if made: os.remove(out)
    return r.returncode, r.stderr.decode().strip(), made


def main():
    exp = json.load(open(os.path.join(P, "EXPECTED.json")))
    for c in exp["corrupt"]:                                   # tool response of the existing four
        code, msg, made = tool(os.path.join(P, c["archive"]), os.path.join(P, c["reference"]))
        c["tool_response"] = {"exit": code, "message": msg, "output_written": made}
    new = []
    # 1. stored block hash byte
    src = os.path.join(A, "asmC.q4k.hash.rr3"); g = geometry(src); b = bytearray(open(src, "rb").read())
    b[g["hashes"] + 8 * 5 + 3] ^= 0x01; rehash(b, g["pstart"])
    new.append(("block_hash_byte.rr3", b, "asmC.q4k.hash.rr3: byte 3 of the stored XXH3 of block 5 changed; payload intact; header XXH3 recomputed"))
    # 2. source FASTA XXH3 field
    src = os.path.join(A, "asmD.q16k.hash.rr3"); g = geometry(src); b = bytearray(open(src, "rb").read())
    b[80] ^= 0x01; rehash(b, g["pstart"])
    new.append(("fasta_xxh3_field.rr3", b, "asmD.q16k.hash.rr3: byte 0 of the header's source-FASTA XXH3 field (offset 80) changed; header XXH3 recomputed"))
    # 3. two equal-length blocks swapped
    src = os.path.join(A, "asmA.q4k.hash.rr3"); g = geometry(src); base = open(src, "rb").read()
    by_len = {}
    for i, off, ln in g["blocks"]: by_len.setdefault(ln, []).append((i, off))
    found, tried = None, 0
    for ln, lst in sorted(by_len.items()):
        for x in range(len(lst)):
            for y in range(x + 1, len(lst)):
                (i, oi), (j, oj) = lst[x], lst[y]
                b = bytearray(base); b[oi:oi + ln], b[oj:oj + ln] = base[oj:oj + ln], base[oi:oi + ln]
                if b == bytearray(base): continue
                tmp = os.path.join(W, "tmp_swap.rr3"); open(tmp, "wb").write(b); tried += 1
                code, msg, made = tool(tmp); os.remove(tmp)
                if code != 0 and "block XXH3" in msg and not made: found = (i, j, ln, b); break
            if found: break
        if found: break
    if found:
        i, j, ln, b = found
        new.append(("blocks_swapped.rr3", b, "asmA.q4k.hash.rr3: payload blocks %d and %d (both %d B) swapped; block table and header untouched" % (i, j, ln)))
        print(f"swap: blocks {i} and {j} ({ln} B), found after {tried} tried pairs")
    else:
        print(f"swap: NOT POSSIBLE - {tried} equal-length pairs tried, none decoded both streams and failed on the block XXH3")
        exp["notes"] = exp.get("notes", []) + ["blocks_swapped: not produced - no equal-length pair of asmA.q4k.hash.rr3 decodes both rANS streams after the swap (%d pairs tried)" % tried]
    for name, b, how in new:
        path = os.path.join(P, "corrupt", name); open(path, "wb").write(bytes(b))
        code, msg, made = tool(path)
        exp["corrupt"].append({"archive": "corrupt/" + name, "reference": "reference/reference.fa", "expect": "refuse", "how": how,
                               "tool_response": {"exit": code, "message": msg, "output_written": made}})
        print(name, code, msg, made)
    json.dump(exp, open(os.path.join(P, "EXPECTED.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
