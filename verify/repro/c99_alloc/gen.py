# Regression inputs for the C99 decoder (2.6.4 step 1), from the audit of 13.11 (AUDIT_ALLOC_262 #1, #3, #4, #5):
# each archive is 132-248 B and asked v2.6.3 for 4-32 GiB (or read past its end). Written byte for byte by this script.
import struct
def v2(nb, bs, orig, zs, table, streams):
    h = b"ACEPX2\0\0" + struct.pack("<IQII", 2, orig, bs, nb) + b"\0"*8 + struct.pack("<QQQQ", *zs)
    return h + table + streams
# T2: empty streams, bs = 2^32-1
bo = struct.pack("<8Q", 0,0,0,0, 0,0,0,0)
open("v2_bs.aet","wb").write(v2(1, 0xffffffff, 0xffffffff, (0,0,0,0), bo, b""))
# T3: lit stream kind1 (bit62|bit61), size 2^36, chunk 2^35 (nc=2), entries 1 byte each; block lit slice [0,2^35+1) spans 2 chunks
size = 1<<36; ch = 1<<35
lit = struct.pack("<QQ", (1<<62)|(1<<61)|size, ch) + struct.pack("<QQ", 1, 1) + b"\0\0"
bo = struct.pack("<8Q", 0,0,0,0, ch+1,0,0,1)
cmd = b""
open("v2_lit.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,0), bo, lit))
# T3b: single chunk, slice inside chunk 0 -> realloc(chunk+64)
size=1<<34; ch=1<<34
lit = struct.pack("<QQ", (1<<62)|(1<<61)|size, ch) + struct.pack("<Q", 1) + b"\0"
bo = struct.pack("<8Q", 0,0,0,0, 1,0,0,0)
open("v2_lit1.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,0), bo, lit))
# T4: tagged lit, chunk raw 8, mode-1 dna, nexc = 2^32-1, h1..h4 = 0
size=8; ch=8
chunk = b"\x01" + struct.pack("<5I", 0xffffffff, 0,0,0,0)
lit = struct.pack("<QQ", (1<<62)|(1<<61)|(1<<60)|size, ch) + struct.pack("<Q", len(chunk)) + chunk
bo = struct.pack("<8Q", 0,0,0,0, 1,0,0,0)
open("v2_dna.aet","wb").write(v2(1, 4096, 4096, (len(lit),0,0,0), bo, lit))
# T5: wrap of 'need': zls = 100 bytes real, zcs = 2^64-50
lit = struct.pack("<Q", 0) + b"\0"*92   # empty FSE layout (size 0)
size=1<<26; f=(1<<26)>>12   # chunk 64 MiB, nc=1
cmd = struct.pack("<Q", (f<<48)|size) + struct.pack("<Q", (1<<63)) # raw chunk
zcs = (1<<64)-50
bo = struct.pack("<8Q", 0,0,0,0, 0,0,0,1)
open("v2_wrap.aet","wb").write(v2(1, 4096, 4096, (100,0,0,zcs), bo, lit+cmd))
# T6 (found by fuzz_c99, 21.11; not in the audit): block entry lit_off + lit_sz wraps past 2^64 -> the slice looked empty,
# the block decoder took lit_sz (2^64 - 8) as the literal bytes available and copied 128 from the archive itself, past its end
cmd = struct.pack("<Q", (1<<48)|1) + struct.pack("<Q", 1<<63) + b"\x7f"     # FSE layout: size 1, chunk 4096, one raw chunk: token 0x7F
bo = struct.pack("<8Q", 8,0,0,0, (1<<64)-8,0,0,1)
open("v2_slicewrap.aet","wb").write(v2(1, 4096, 4096, (0,0,0,len(cmd)), bo, cmd))
