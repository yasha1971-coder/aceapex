"""fuzz_python.py - the Python package (aceapex, ctypes over the C99 decoder) on corrupted archives (2.6.4), stdlib only.

Usage: python3 fuzz_python.py SECONDS FILE...   (PYTHONPATH=python, ACEAPEX_DECODE_SO=<libaceapex_decode.so>)
Every file as given, then SECONDS of random mutants of them (bit flips, byte overwrites, truncation, extension, header
field edits). Each input: aceapex.open(bytes) -> decompress() when the declared size is <= 16 MiB, read() of up to
4 KiB, ranges() of three spans, close(). The address space is limited to 2 GiB (RLIMIT_AS) and every input is at most
a few MiB, so "out of memory" means the decoder sized an allocation from an archive field: a failure, as is any
exception other than aceapex.DecodeError. A crash of the interpreter (signal) is reported by the caller (exit code).
The input being decoded is kept in $FUZZ_LAST (default /tmp/fuzz_python_last.aet) for reproduction.
Prints one judge line: head_python_fuzz <pass|fail> <detail>.
"""
import os, random, resource, struct, sys, time

resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))
import aceapex  # noqa: E402

CLAIM_MAX = 16 << 20
LAST = os.environ.get("FUZZ_LAST", "/tmp/fuzz_python_last.aet")


def mutate(rng, b):
    b = bytearray(b)
    for _ in range(rng.randint(1, 4)):
        k = rng.randrange(6)
        if k == 0 and b: i = rng.randrange(len(b)); b[i] ^= 1 << rng.randrange(8)
        elif k == 1 and b: i = rng.randrange(len(b)); b[i] = rng.randrange(256)
        elif k == 2 and len(b) > 1: del b[rng.randrange(1, len(b)):]
        elif k == 3: b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 64)))
        elif k == 4 and len(b) >= 68:   # a header field: orig, block_size, num_blocks or one stream size
            off, fmt = rng.choice([(12, "<Q"), (20, "<I"), (24, "<I"), (36, "<Q"), (44, "<Q"), (52, "<Q"), (60, "<Q")])
            v = rng.choice([0, 1, 0xFFFFFFFF, 1 << 32, 1 << 48, (1 << 64) - 1, rng.getrandbits(64)])
            b[off:off + struct.calcsize(fmt)] = struct.pack(fmt, v & ((1 << (8 * struct.calcsize(fmt))) - 1))
        elif k == 5 and len(b) > 68 + 64:   # a block table field of block 0
            off = 68 + 8 * rng.randrange(8); b[off:off + 8] = struct.pack("<Q", rng.getrandbits(rng.choice([8, 32, 64])))
    return bytes(b)


def one(data, stats):
    with open(LAST, "wb") as f: f.write(data)
    try:
        a = aceapex.open(data)
    except aceapex.DecodeError as e:
        stats["refused"] += 1
        return "out of memory" in str(e)
    try:
        if a.size <= CLAIM_MAX: a.decompress()
        n = a.size
        if n:
            o = (len(data) * 7919) % n; l = min(4096, n - o) or 1
            a.read(o, l)
            a.ranges([(o, l), ((o * 31) % n, 1), (0, min(n, 4096))])
        stats["decoded"] += 1
        return False
    except aceapex.DecodeError as e:
        stats["refused"] += 1
        return "out of memory" in str(e)
    finally:
        a.close()


def main():
    secs = float(sys.argv[1]); seeds = []
    for p in sys.argv[2:]:
        with open(p, "rb") as f: seeds.append(f.read())
    stats = {"inputs": 0, "refused": 0, "decoded": 0}; bad = []; rng = random.Random(20261122)
    def run(d, tag):
        stats["inputs"] += 1
        try:
            if one(d, stats): bad.append(f"{tag}: out of memory")
        except Exception as e:   # anything but DecodeError
            bad.append(f"{tag}: {type(e).__name__}: {e}")
    for i, s in enumerate(seeds): run(s, f"seed {os.path.basename(sys.argv[2 + i])}")
    t0 = time.time()
    while seeds and time.time() - t0 < secs:
        run(mutate(rng, rng.choice(seeds)), f"mutant {stats['inputs']}")
    ok = not bad
    print(f"head_python_fuzz\t{'pass' if ok else 'fail'}\t{len(seeds)} files + {stats['inputs'] - len(seeds)} mutants in "
          f"{secs:.0f} s (RLIMIT_AS 2 GiB): {stats['refused']} refused, {stats['decoded']} decoded, {len(bad)} failures"
          + (f": {bad[0]}" if bad else ""))
    for b in bad[1:8]: print("  " + b, file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
