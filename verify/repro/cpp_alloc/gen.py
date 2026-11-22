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
