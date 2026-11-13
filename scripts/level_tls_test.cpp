// level_tls_test.cpp - claim head_level_tls (2.6.2): the level that picks the literal layout (g_enc_level, thread_local,
// read in lit_chunk_size) belongs to each aceapex_compress call. Levels 2 (1 MiB literal chunks) and 4 (4-part layout)
// give different bytes on non-DNA input; two threads that compress at the same time, one at level 2 and one at level 4,
// each with 4 codec threads, get the bytes of the same level compressed alone, round after round; so does one thread that
// alternates the levels. Input: 24 MiB of seeded word text. Prints one judge line: head_level_tls <pass|fail> <detail>.
#include "aceapex.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <atomic>
#include <random>
#include <string>
#include <thread>
typedef std::vector<uint8_t> Buf;
static Buf comp(const Buf& in, int level) {
    Buf z(aceapex_compress_bound(in.size()));
    const int64_t zs = aceapex_compress(in.data(), in.size(), z.data(), z.size(), level, 4);
    z.resize(zs > 0 ? (size_t)zs : 0); return z;
}
int main() {
    std::mt19937 rng(20261113);
    static const char* wd[] = {"the", "of", "and", "genome", "block", "archive", "decoder", "thread", "level", "layout", "chunk", "random"};
    std::string s; while (s.size() < (24u << 20)) { s += wd[rng() % 12]; s += (rng() % 11) ? ' ' : '\n'; }
    const Buf in(s.begin(), s.begin() + (24u << 20));
    const Buf r2 = comp(in, 2), r4 = comp(in, 4);
    int bad = 0, rt = 0; const int R = 12;
    for (int r = 0; r < R; r++) {
        Buf a, b; std::atomic<int> go{0};
        std::thread ta([&] { go++; while (go < 2) {} a = comp(in, 2); });
        std::thread tb([&] { go++; while (go < 2) {} b = comp(in, 4); });
        ta.join(); tb.join();
        bad += (a != r2) + (b != r4);
    }
    for (int r = 0; r < 4; r++) bad += (comp(in, r & 1 ? 4 : 2) != (r & 1 ? r4 : r2));
    for (const Buf* z : {&r2, &r4}) { Buf o(in.size());
        rt += aceapex_decompress(z->data(), z->size(), o.data(), o.size()) != (int64_t)in.size() || o != in; }
    const bool ok = !r2.empty() && !r4.empty() && r2 != r4 && !bad && !rt;
    printf("head_level_tls\t%s\t24 MiB text, 4 codec threads per call: level 2 %zu B, level 4 %zu B (differ: %s); %d rounds of "
           "levels 2 and 4 compressed at once in two threads + 4 alternating calls in one thread: %d archives differ from "
           "the level's own bytes; round trip failures %d\n", ok ? "pass" : "fail", r2.size(), r4.size(), r2 != r4 ? "yes" : "no",
           R, bad, rt);
    return ok ? 0 : 1;
}
