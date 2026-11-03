// dna_err_test.cpp - claim head_dna_err (lzbench #357, 2.6.1): a corrupt DNA literal chunk must come back as
// ACEAPEX_ERR_DATA from aceapex_decompress_mt, not as orig_size with wrong bytes. Until 2.6.0 dna_decompress() raised
// only g_dec_err, ax_lit_chunk_decode() returned true and nothing checked the flag after the tiled decode.
// Input: 4 MiB of seeded A/C/G/T in 60-column lines with repeats (the default profile packs it as DNA). The test finds a
// DNA chunk in the archive (tag 1, 20-byte header, a zstd frame right after it), damages the zstd magic of its
// packed-sequence frame and decodes with 1, 2 and 4 threads: every decode must return ACEAPEX_ERR_DATA. Control: the
// intact archive decodes to the input. Prints one judge line: head_dna_err <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <random>
static uint32_t rd32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
int main() {
    std::mt19937 rng(20261103); const char B[4] = {'A', 'C', 'G', 'T'};
    std::vector<uint8_t> in; in.reserve(4u << 20);
    while (in.size() < (4u << 20)) {
        if (in.size() > 4096 && rng() % 8 == 0) { const size_t len = 200 + rng() % 2000, from = rng() % (in.size() - len); for (size_t k = 0; k < len && in.size() < (4u << 20); k++) in.push_back(in[from + k]); }
        else for (int k = 0; k < 300 && in.size() < (4u << 20); k++) in.push_back((uint8_t)B[rng() & 3]);
    }
    for (size_t i = 60; i < in.size(); i += 61) in[i] = '\n';
    const size_t n = in.size(); std::vector<uint8_t> z(aceapex_compress_bound(n)), out(n);
    const int64_t zs = aceapex_compress(in.data(), n, z.data(), z.size(), 1, 1);
    if (zs <= 0) { printf("head_dna_err\tfail\tcompress rc %lld\n", (long long)zs); return 1; }
    if (aceapex_decompress_mt(z.data(), zs, out.data(), n, 2) != (int64_t)n || memcmp(out.data(), in.data(), n)) { printf("head_dna_err\tfail\tcontrol: the intact archive does not round-trip\n"); return 1; }
    // a DNA chunk: tag 1, u32 h[5] = {nexc, seq, case, gap, val}, the sequence frame (zstd magic) right after
    int64_t at = -1;
    for (int64_t i = 0; i + 25 < zs && at < 0; i++) {
        if (z[i] != 1) continue;
        const uint8_t* h = &z[i + 1];
        const uint64_t s1 = rd32(h + 4), sum = 20ull + s1 + rd32(h + 8) + rd32(h + 12) + rd32(h + 16);
        if (rd32(h + 20) == 0xFD2FB528u && s1 > 64 && sum <= (uint64_t)(zs - i - 1)) at = i;
    }
    if (at < 0) { printf("head_dna_err\tfail\tno DNA chunk found in the archive (%lld B): input not packed as DNA\n", (long long)zs); return 1; }
    // the sequence frame's zstd magic damaged: zstd rejects the frame, dna_decompress raises g_dec_err (bytes inside a
    // frame without a checksum can decode to other bytes unnoticed - that is zstd's contract, not this test's)
    const uint32_t s1 = rd32(&z[at + 5]);
    std::vector<uint8_t> bad(z.begin(), z.begin() + zs);
    bad[at + 21] ^= 0xff;
    int ok = 0; char det[160] = "";
    for (int t : {1, 2, 4}) {
        const int64_t r = aceapex_decompress_mt(bad.data(), zs, out.data(), n, t);
        ok += r == ACEAPEX_ERR_DATA;
        snprintf(det + strlen(det), sizeof det - strlen(det), " T%d rc %lld%s", t, (long long)r, r == (int64_t)n ? (memcmp(out.data(), in.data(), n) ? " (wrong bytes)" : " (same bytes)") : "");
    }
    printf("head_dna_err\t%s\tcorrupt DNA chunk (offset %lld, magic of its %u-byte sequence frame) -> ACEAPEX_ERR_DATA at %d/3 thread counts:%s; intact archive round-trips\n",
           ok == 3 ? "pass" : "fail", (long long)at, s1, ok, det);
    return ok == 3 ? 0 : 1;
}
