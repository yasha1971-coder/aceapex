// fuzz_api.cpp - libFuzzer harness over the C API (FREEZE-4, ClusterFuzzLite), the api_fuzz logic driven by the fuzzer.
// Byte 0 picks the path:
//   bit 7 = 0, raw path: the rest is an archive. aceapex_decompress_mt into a heap buffer of exactly the size the
//      header claims (<= 16 MiB), then aceapex_decompress_stream with and without ACEAPEX_STREAM_VERIFY into a sink.
//      Only the sanitizers judge (ASan/UBSan): the plain API has no checksum, a wrong-bytes success is allowed here.
//   bit 7 = 1, VERIFY path: byte 0 & 15 picks the level (1, 2, 3, 11..18), bytes 1..24 are 8 edits (3 bytes each:
//      offset lo, offset hi, xor mask; offset counted after the 68-byte header, mask 0 = no edit), byte 25 a cut
//      (0 = none, else keep size * byte / 256), the rest the original (<= 256 KiB). The original is compressed, the
//      edits applied, the archive decoded by decompress_mt (sanitizers only) and by the stream decoder with
//      ACEAPEX_STREAM_VERIFY: a success must hand out exactly the original bytes, else abort() (the fuzzer reports it).
// -DFUZZ_API_CONTROL drops the VERIFY flag there: the same assert must then fire (negative control).
#include "aceapex.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
namespace {
struct Src { const uint8_t* p; size_t n; };
int64_t rd(void* c, uint64_t off, void* dst, size_t n) {
    const Src* s = (const Src*)c; if (off >= s->n) return 0;
    const size_t k = n < s->n - off ? n : (size_t)(s->n - off); memcpy(dst, s->p + off, k); return (int64_t)k;
}
struct Sink { const uint8_t* want; size_t wn; size_t pos; bool diff; };
int wr(void* c, const void* b, size_t n) {
    Sink* s = (Sink*)c;
    if (s->want && (s->pos + n > s->wn || memcmp(s->want + s->pos, b, n))) s->diff = true;
    s->pos += n; return s->pos > (64u << 20);   // stop a runaway stream
}
uint64_t rd64(const uint8_t* p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
void raw_decode(const uint8_t* z, size_t zn) {
    const uint64_t claimed = zn >= 20 ? rd64(z + 12) : 0;
    if (claimed <= (16u << 20)) {
        uint8_t* o = (uint8_t*)malloc(claimed ? (size_t)claimed : 1);
        (void)aceapex_decompress_mt(z, zn, o, (size_t)claimed, 1);
        free(o);
    }
}
}
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1) return 0;
    if (!(data[0] & 0x80)) {
        const uint8_t* z = data + 1; const size_t zn = size - 1;
        raw_decode(z, zn);
        for (unsigned f = 0; f < 2; f++) { Src s{z, zn}; Sink k{nullptr, 0, 0, false}; (void)aceapex_decompress_stream(rd, &s, wr, &k, 1, f); }
        return 0;
    }
    if (size < 26) return 0;
    static const int levels[16] = {1, 2, 3, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 11, 14};
    const int lv = levels[data[0] & 15];
    const uint8_t* in = data + 26; size_t n = size - 26; if (n > (256u << 10)) n = 256u << 10;
    std::vector<uint8_t> z(aceapex_compress_bound(n));
    const int64_t zs = aceapex_compress(in, n, z.data(), z.size(), lv, 1);
    if (zs <= 0) abort();                                // a valid input must compress
    z.resize((size_t)zs);
    for (int e = 0; e < 8; e++) {
        const uint8_t* q = data + 1 + 3 * e; if (!q[2] || z.size() <= 68) continue;
        z[68 + ((size_t)q[0] | (size_t)q[1] << 8) % (z.size() - 68)] ^= q[2];
    }
    if (data[25]) z.resize(z.size() * data[25] / 256);
    raw_decode(z.data(), z.size());
    Src s{z.data(), z.size()}; Sink k{in, n, 0, false};
#ifndef FUZZ_API_CONTROL
    const int64_t v = aceapex_decompress_stream(rd, &s, wr, &k, 1, ACEAPEX_STREAM_VERIFY);
#else
    const int64_t v = aceapex_decompress_stream(rd, &s, wr, &k, 1, 0);  // negative control: without VERIFY it must abort
#endif
    if (v >= 0 && (v != (int64_t)n || k.diff || k.pos != n)) abort();   // verified success with other bytes
    return 0;
}
