// hdr_sum_overflow_test.cpp - claim head_hdr_sum_overflow (2.6.2): the header check of aceapex_decompress_mt sums the
// four u64 stream sizes (zlit/zoff/zlen/zcmd) without letting the total wrap past src_size. Input built here byte for
// byte: a 132-byte version-2 header, block_size 1 MiB, num_blocks 1, orig 1000, zlit_sz 100, zcmd_sz 2^64-150 so the
// single-expression sum of <= 2.6.1 wraps to 82 (<= 132) and the "need <= src_size" check passes - then zcmd points far
// past the archive and ax_fse_check reads out of bounds. Built under ASan+UBSan in the judge: the fix returns
// ACEAPEX_ERR_DATA with no sanitizer report; <= 2.6.1 (and the earlier 2.6.2 candidate) abort with a heap-buffer-overflow
// read in fse_stream_size (the lzbench / TurboBench decompress path). Pass: ACEAPEX_ERR_DATA at 1, 2 and 8 threads.
// Prints one judge line: head_hdr_sum_overflow <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
static void w32(uint8_t* p, uint32_t v) { memcpy(p, &v, 4); }
static void w64(uint8_t* p, uint64_t v) { memcpy(p, &v, 8); }
int main() {
    std::vector<uint8_t> a(132, 0); memcpy(a.data(), "ACEPX2\0\0", 8);
    w32(&a[8], 2); w64(&a[12], 1000); w32(&a[20], 1u << 20); w32(&a[24], 1);
    w64(&a[36], 100); w64(&a[44], 0); w64(&a[52], 0); w64(&a[60], ~0ull - 149);   // 68 + 64 + 100 + (2^64-150) wraps to 82
    const uint64_t wrapped = 68ull + 64 + 100 + 0 + 0 + (~0ull - 149);
    std::vector<uint8_t> o(4096); bool ok = true; std::string det = " (wrapped need " + std::to_string(wrapped) + " <= 132)";
    for (int th : {1, 2, 8}) {
        int64_t r = aceapex_decompress_mt(a.data(), a.size(), o.data(), o.size(), th);   // <= 2.6.1: ASan aborts here
        const bool good = r == ACEAPEX_ERR_DATA;
        ok = ok && good; det += "; t" + std::to_string(th) + ": rc " + std::to_string((long long)r) + (good ? "" : " FAIL");
    }
    printf("head_hdr_sum_overflow\t%s\tzlit_sz 100 + zcmd_sz 2^64-150 in a 132-byte v2 archive through aceapex_decompress_mt (ASan+UBSan), pass = ACEAPEX_ERR_DATA, no out-of-bounds read%s\n", ok ? "pass" : "fail", det.c_str());
    return ok ? 0 : 1;
}
