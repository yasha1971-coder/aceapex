// enc_bs_test.cpp - claim head_enc_bs_bound (2.6.4 step 2): the encoder never writes block_size above the decoders'
// 64 MiB bound (FORMAT_ACEPX2.md). The only way to ask for another block size is ACEAPEX_BS, read in tuning builds
// (-DACEAPEX_ENV_TUNING); v2.6.3 wrote any value >= 4096 into the header. 2 MiB of text at level 2: ACEAPEX_BS = 1 MiB
// is honoured, 2^27 and 2^32 + 4096 are not (the size the encoder picks by itself), every archive round-trips.
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
int main(int argc, char** argv) {   // argv: other ACEAPEX_BS values (the negative control asks one at a time)
    std::vector<uint8_t> in(2u << 20); uint64_t s = 88172645463325252ull;
    static const char* w[] = {"the ", "block ", "archive ", "genome ", "of ", "and\n"};
    for (size_t i = 0; i < in.size(); ) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; for (const char* p = w[s % 6]; *p && i < in.size(); ) in[i++] = (uint8_t)*p++; }
    std::vector<uint8_t> z(aceapex_compress_bound(in.size())), out(in.size());
    std::vector<const char*> asks = {"1048576", "134217728", "4294971392"};
    if (argc > 1) asks.assign(argv + 1, argv + argc);
    std::string detail; bool ok = true;
    for (const char* a : asks) {
        setenv("ACEAPEX_BS", a, 1);
        const int64_t n = aceapex_compress(in.data(), in.size(), z.data(), z.size(), 2, 1);
        uint32_t bs = 0; if (n >= 68) memcpy(&bs, z.data() + 20, 4);
        const bool rt = n > 0 && aceapex_decompress(z.data(), (size_t)n, out.data(), out.size()) == (int64_t)in.size() && out == in;
        const bool want = strtoull(a, nullptr, 10) <= ((uint64_t)64 << 20) ? bs == (uint32_t)strtoull(a, nullptr, 10) : bs <= ((uint32_t)64 << 20);
        if (!rt || !want) ok = false;
        char b[160]; snprintf(b, sizeof b, "%sACEAPEX_BS=%s -> block_size %u%s", detail.empty() ? "" : ", ", a, bs, rt ? "" : " (round trip FAILED)"); detail += b;
    }
    printf("head_enc_bs_bound\t%s\t%s\n", ok ? "pass" : "fail", detail.c_str());
    return ok ? 0 : 1;
}
