// standalone.cpp - runs fuzz_api's LLVMFuzzerTestOneInput without libFuzzer (gcc builds, the local check): every file
// named on the command line, then SECONDS of random mutations of them (bit flips, byte overwrites, the VERIFY path's
// edit bytes). Usage: standalone SECONDS FILE...
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <vector>
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);
static uint64_t rs = 88172645463325252ull;
static uint64_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
int main(int argc, char** argv) {
    std::vector<std::vector<uint8_t>> in;
    for (int i = 2; i < argc; i++) {
        FILE* f = fopen(argv[i], "rb"); if (!f) continue; std::vector<uint8_t> b; int c;
        while ((c = fgetc(f)) != EOF) b.push_back((uint8_t)c); fclose(f);
        LLVMFuzzerTestOneInput(b.data(), b.size()); in.push_back(b);
    }
    const int secs = argc > 1 ? atoi(argv[1]) : 10; const time_t t0 = time(nullptr); long runs = 0;
    while (!in.empty() && time(nullptr) - t0 < secs) {
        std::vector<uint8_t> b = in[rnd() % in.size()]; if (b.size() < 2) continue;
        const int op = (int)(rnd() % 3);
        if (op == 0) for (int k = 1 + (int)(rnd() % 8); k > 0; k--) b[1 + rnd() % (b.size() - 1)] ^= (uint8_t)(1u << (rnd() % 8));
        if (op == 1) for (int k = 1 + (int)(rnd() % 4); k > 0; k--) b[1 + rnd() % (b.size() - 1)] = (uint8_t)rnd();
        if (op == 2 && (b[0] & 0x80) && b.size() > 26) for (int k = 1; k < 26; k++) b[k] = rnd() % 3 ? 0 : (uint8_t)rnd();
        LLVMFuzzerTestOneInput(b.data(), b.size()); runs++;
    }
    printf("standalone: %zu files, %ld mutants in %d s, no abort\n", in.size(), runs, secs);
    return 0;
}
