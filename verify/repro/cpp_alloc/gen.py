# Regression inputs for the C++ decoder (2.6.4 step 2): AUDIT_ALLOC_262 #6, #7, the legacy literal table, the 4-part
# literal layout of no bytes and the region slices (LIST_264_AUDIT "попутно"), written byte for byte by this script.
# The C99 archives of ../c99_alloc (#1-#5 and the slice wrap) go through the C++ entry points too (cpp_alloc_test.cpp).
import struct
def v2(nb, bs, orig, zs, table, streams):
    h = b"ACEPX2\0\0" + struct.pack("<IQII", 2, orig, bs, nb) + b"\0"*8 + struct.pack("<QQQQ", *zs)
    return h + table + streams
def bo(*v): return struct.pack("<8Q", *v)   # lit_off, off_off, len_off, cmd_off, lit_sz, off_sz, len_sz, cmd_sz
CMD1 = struct.pack("<Q", (1<<48)|1) + struct.pack("<Q", 1<<63) + b"\x7f"   # token layout: size 1, chunk 4096, one raw chunk: token 0x7F

# tokwin (#6): the command stream declares 64 chunks of 0x7FFF << 12 B (8.6 GB), each stored as 1 compressed byte; the
# table fits the stream, so only a bound by orig refuses it. Block 0's command slice is the whole declared stream:
# v2.6.3 region / ranges allocate the window over it (8.6 GB).
CH = 0x7FFF << 12; S = 64 * CH
cmd = struct.pack("<Q", (0x7FFF << 48) | S) + struct.pack("<64Q", *([1]*64)) + b"\0"*64
open("v2_tokwin.aet","wb").write(v2(1, 4096, 4096, (0,0,0,len(cmd)), bo(0,0,0,0, 0,0,0,S), cmd))

# bigblock (#7): one block of 1 GiB, empty streams. v2.6.3 region / ranges allocate the block span (1 GiB), the CLI and
# faidx the output (1 GiB) before anything is decoded; above the 64 MiB block bound.
open("v2_bigblock.aet","wb").write(v2(1, 1<<30, 1<<30, (0,0,0,0), bo(0,0,0,0, 0,0,0,0), b""))

# litlegacy: a legacy literal stream (bit 62 clear) declaring 4096 B in one raw chunk, 8 bytes of body; it is the last
# stream, so v2.6.3 copies 4096 B from the end of the archive (full decode, region): its table was not checked.
lit = struct.pack("<Q", 4096) + struct.pack("<Q", 1<<63) + b"A"*8
open("v2_litlegacy.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,0), bo(0,0,0,0, 4096,0,0,0), lit))

# lit4zero: the 4-part literal layout (bit 62, not chunked) of 0 bytes: chunk size (0 + 3) / 4 = 0, and v2.6.3 region
# divides by it (SIGFPE)
lit = struct.pack("<Q", 1<<62) + struct.pack("<4Q", 0,0,0,0)
open("v2_lit4zero.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,len(CMD1)), bo(0,0,0,0, 0,0,0,1), lit + CMD1))

# litslice: the literal stream decodes to 8 bytes, block 0 claims 4096 of them and its one token copies 128: v2.6.3
# region reads 120 bytes past the 8-byte window (the slices were not checked against the decoded streams)
lit = struct.pack("<Q", 8) + struct.pack("<Q", 1<<63) + b"ACGTACGT"
open("v2_litslice.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,len(CMD1)), bo(0,0,0,0, 4096,0,0,1), lit + CMD1))

# 2.6.4 step 4 - the streaming decoder of the default profile (aceapex_decompress_stream):
LIT8 = struct.pack("<QQ", (1<<62)|(1<<61)|8, 4096) + struct.pack("<Q", 0)   # chunked literals, 8 B in one chunk (no body)
# st_tokcap (#11): the command stream declares 64 chunks of 0x7FFF << 12 B (8.6 GB), 1 compressed byte each; block 0's
# command slice is the whole declared stream: v2.6.3 decodes the chunks of the window, 128 MiB each, before any check
cmd = struct.pack("<Q", (0x7FFF << 48) | S) + struct.pack("<64Q", *([1]*64)) + b"\0"*64
open("st_tokcap.aet","wb").write(v2(1, 4096, 4096, (len(LIT8),0,0,len(cmd)), bo(0,0,0,0, 8,0,0,S), LIT8 + cmd))
# st_lchempty: chunked literals of 0 bytes (no chunk in the table), block 0 with an empty literal slice: v2.6.3's
# stream worker reads c.lch[0] of an empty vector (SIGSEGV)
lit0 = struct.pack("<QQ", (1<<62)|(1<<61)|0, 4096)
open("st_lchempty.aet","wb").write(v2(1, 4096, 4096, (len(lit0),0,0,len(CMD1)), bo(0,0,0,0, 0,0,0,1), lit0 + CMD1))

# zstd frame of n zero bytes from RLE blocks of 128 KiB (stdlib only): magic, single-segment header with a 4-byte
# content size, then 3-byte block headers (type 1 = RLE, the block size is the regenerated size) and the byte 0
def zrle(n):
    f = struct.pack("<IB", 0xFD2FB528, 0xA0) + struct.pack("<I", n); left = n
    while left:
        k = min(left, 128 << 10); left -= k
        f += struct.pack("<I", (1 if not left else 0) | (1 << 1) | (k << 3))[:3] + b"\0"
    return f
# st_group (#12): 4 blocks of 64 MiB (orig 256 MiB), the command stream 8 chunks of 0x7FFF << 12 B (128 MiB), each a
# 4 KiB zstd frame of zeros; block 0's command slice is the whole stream. 33.5 KB that made the streaming decoder of
# 955a415 hold 2.1 GB (VmHWM). Refused since 2.6.4: token chunks above 16 MiB.
CHG = 0x7FFF << 12; zg = zrle(CHG); bsg = 64 << 20
cmd = struct.pack("<Q", (0x7FFF << 48) | (8 * CHG)) + struct.pack("<8Q", *([len(zg)] * 8)) + zg * 8
tab = bo(0,0,0,0, 8,0,0,8*CHG) + bo(0,0,0,0, 0,0,0,0) * 3
open("st_group.aet","wb").write(v2(4, bsg, 4 * bsg, (len(LIT8),0,0,len(cmd)), tab, LIT8 + cmd))
# st_slice (#12): the same with 64 chunks of 16 MiB (allowed) and block 0's command slice 1 GiB (above 4 x 64 MiB + 4 KiB):
# without the slice bound the decoder holds the whole window (64 x 16 MiB). Refused since 2.6.4: the slice bound.
CHS = 16 << 20; zs_ = zrle(CHS)
cmd = struct.pack("<Q", ((CHS >> 12) << 48) | (64 * CHS)) + struct.pack("<64Q", *([len(zs_)] * 64)) + zs_ * 64
tab = bo(0,0,0,0, 8,0,0,64*CHS) + bo(0,0,0,0, 0,0,0,0) * 3
open("st_slice.aet","wb").write(v2(4, bsg, 4 * bsg, (len(LIT8),0,0,len(cmd)), tab, LIT8 + cmd))
