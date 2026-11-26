# Regression inputs for SEC-ZSTD-1 (2.6.5): archives whose zstd chunk carries a frame other than one zstd v1 frame.
# Written byte for byte by this script (no libzstd needed): one block, a chunked literal stream (FORMAT_ACEPX2 3.2.2)
# of one chunk, a raw command stream of literal runs, no offsets or lengths. Every archive is well-formed except for
# its chunk, so a decoder without the frame check decodes it whenever its libzstd accepts the chunk:
#   zl_v07.aet       the chunk is a zstd v0.7 frame (legacy format, magic 0xFD2FB527)              -> legacy support
#   zl_v1_v07.aet    a valid v1 frame of 16 bytes, then the v0.7 frame: a check of the first four
#                    bytes alone passes it, and ZSTD_decompress decodes the second frame too      -> legacy support
#   zl_skip_v1.aet   a skippable frame (magic 0x184D2A50), then a v1 frame                        -> any libzstd
#   zl_v1.aet        one v1 frame: the valid control, decoded with or without the check
# The v0.7 frame is the fourth frame of COMPRESSED in zstd's tests/legacy.c (v1.5.7; BSD or GPLv2, (c) Meta
# Platforms, Inc.): bytes 560..737. It decodes to T, the first 239 bytes of EXPECTED there.
# <name>.expect: the bytes a decoder WITHOUT the check produces when its libzstd accepts the chunk (negative control).
import struct

V07 = bytes.fromhex(
    "27b52ffd20ef0000a612e4841fb001100000003559a6e7a1ef7cfcbd3fff9fefeeef61c3aa311d343822220444218032ad28f3d6"
    "280c0a0ed65cac198d205f45022e1750666dac8b9c6e077346bb4414e798c3b917326e337c0e21b1dbcb89512334ab9dbc6d20f5"
    "03a9914c2e1f59dbd935674b0c9579100085a696952edf787b4a5c097697d15c96127535a3554ad40b00350b71b5c02a5ce60845"
    "f13943f11c4b54109d3150854b540e014b3d01c00000")
T = (
    b"snowden is snowed in / he's now then in his snow den / when does the snow end?\ng"
    b"oodbye little dog / you dug some holes in your day / they'll be hard to fill.\nwh"
    b'en life shuts a door, / just open it. it\xe2\x80\x99s a door. / that is how doors work.\n')
CH = 65536


def v1_raw(x):   # one zstd v1 frame: single segment, 1-byte content size, one raw last block
    assert len(x) < 256
    return b"\x28\xb5\x2f\xfd" + bytes([0x20, len(x)]) + (1 | (len(x) << 3)).to_bytes(3, "little") + x


def skippable(payload):
    return struct.pack("<II", 0x184D2A50, len(payload)) + payload


# XXH3-64 of each decoded output (header field at offset 28), computed with src/xxhash.h (XXH3_64bits)
XXH3 = {239: 0x784B1920E98C141D, 255: 0xE2342A1EE4D3CB4D}   # T, and A16 + T


def archive(chunk, S):
    lit = struct.pack("<QQQ", S | (1 << 62) | (1 << 61), CH, len(chunk)) + chunk
    tok = b"\x7f" * (S // 128) + (bytes([S % 128 - 1]) if S % 128 else b"")
    cmd = struct.pack("<QQ", len(tok) | (1 << 48), 1 << 63) + tok
    hdr = b"ACEPX2\0\0" + struct.pack("<IQIIQ", 2, S, CH, 1, XXH3[S]) + struct.pack("<QQQQ", len(lit), 0, 0, len(cmd))
    table = struct.pack("<8Q", 0, 0, 0, 0, S, 0, 0, len(tok))
    return hdr + table + lit + cmd


assert len(V07) == 178 and V07[:4] == bytes([0x27, 0xB5, 0x2F, 0xFD]) and len(T) == 239
A16 = b"A" * 16
cases = {
    "zl_v07": (V07, T),
    "zl_v1_v07": (v1_raw(A16) + V07, A16 + T),
    "zl_skip_v1": (skippable(b"ACE!") + v1_raw(T), T),
    "zl_v1": (v1_raw(T), T),
}
for name, (chunk, out) in cases.items():
    open(name + ".aet", "wb").write(archive(chunk, len(out)))
    open(name + ".expect", "wb").write(out)
