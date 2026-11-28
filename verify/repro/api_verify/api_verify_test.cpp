// api_verify_test.cpp - claim head_api_verify, C++ part (2.6.7, API-CHK-1): aceapex_decompress_ex with ACEAPEX_VERIFY_XXH3
// refuses the three archives of this directory (gen.py: one flipped bit, decoded with success to wrong bytes by the
// unchecked calls) and decodes every conformance fixture whole; without the flag it is aceapex_decompress_mt (the same
// wrong bytes); an unknown flag bit is ACEAPEX_ERR_BUFFER.
//   default build:        3 of 3 refused with the flag, 3 of 3 wrong-but-success without; fixtures 28 of 28   -> pass
//   -DAX_VERIFY_NO_CHECK: the control - with the flag the three come back with success (the bytes are wrong)
// Prints: api_verify_cpp <check|control> <pass|fail> <detail>. Usage: api_verify_test <this directory> <fixtures/conf>
#include "aceapex.h"
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <algorithm>
static std::vector<uint8_t> slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {}); }
int main(int argc, char** argv) {
#ifdef AX_VERIFY_NO_CHECK
    const bool control = true;
#else
    const bool control = false;
#endif
    if (argc < 3) { fprintf(stderr, "usage: %s <dir> <fixtures/conf>\n", argv[0]); return 2; }
    const char* bad[3][2] = {{"text_200K_p972", "text_200K"}, {"text_fast_200K_p102", "text_fast_200K"}, {"dna_4096B_p177", "dna_4096B"}};
    int refused = 0, silent_plain = 0, silent_flag = 0, miss = 0;
    for (auto& b : bad) {
        const auto a = slurp(std::string(argv[1]) + "/" + b[0] + ".aet"), fx = slurp(std::string(argv[2]) + "/" + b[1] + ".aet");
        if (a.size() < 36 || fx.size() < 36) { miss++; continue; }
        uint64_t n; memcpy(&n, fx.data() + 12, 8); std::vector<uint8_t> o(n + 64), d(n + 64);
        if (aceapex_decompress_mt(fx.data(), fx.size(), o.data(), n, 1) != (int64_t)n) { miss++; continue; }
        const int64_t r0 = aceapex_decompress_ex(a.data(), a.size(), d.data(), n, 1, 0);
        if (r0 == (int64_t)n && memcmp(d.data(), o.data(), n)) silent_plain++;
        const int64_t r1 = aceapex_decompress_ex(a.data(), a.size(), d.data(), n, 1, ACEAPEX_VERIFY_XXH3);
        if (r1 == ACEAPEX_ERR_DATA) refused++; else if (r1 == (int64_t)n && memcmp(d.data(), o.data(), n)) silent_flag++;
    }
    int fx = 0, fok = 0, badflag = 0; std::string fails;
    if (DIR* dd = opendir(argv[2])) { std::vector<std::string> names; while (dirent* e = readdir(dd)) { std::string s = e->d_name; if (s.size() > 4 && s.substr(s.size() - 4) == ".aet") names.push_back(s); } closedir(dd);
        std::sort(names.begin(), names.end());
        for (auto& s : names) { if (s == "dna_depth_legacy.aet") continue;   // needs FSE_CHUNK of tuning builds
            const auto a = slurp(std::string(argv[2]) + "/" + s); uint64_t n; memcpy(&n, a.data() + 12, 8); std::vector<uint8_t> o(n + 64), d(n + 64); fx++;
            const bool ok = aceapex_decompress_mt(a.data(), a.size(), o.data(), n, 1) == (int64_t)n && aceapex_decompress_ex(a.data(), a.size(), d.data(), n, 0, ACEAPEX_VERIFY_XXH3) == (int64_t)n && !memcmp(o.data(), d.data(), n);
            if (ok) fok++; else fails += " " + s;
            if (aceapex_decompress_ex(a.data(), a.size(), d.data(), n, 1, 2u) == ACEAPEX_ERR_BUFFER) badflag++; } }
    const bool pass = miss == 0 && silent_plain == 3 && fok == fx && fx > 0 && badflag == fx && (control ? silent_flag == 3 : refused == 3);
    printf("api_verify_cpp\t%s\t%s\twith the flag: %d of 3 refused, %d of 3 wrong bytes with success; without: %d of 3 wrong with success; fixtures verified %d of %d, unknown flag refused %d of %d%s%s\n",
           control ? "control" : "check", pass ? "pass" : "fail", refused, silent_flag, silent_plain, fok, fx, badflag, fx, fails.empty() ? "" : "; failed:", fails.c_str());
    return pass ? 0 : 1;
}
