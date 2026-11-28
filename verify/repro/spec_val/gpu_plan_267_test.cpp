// gpu_plan_267_test.cpp - claim head_gpu_plan_267 (2.6.7, SPEC-VAL-1): the GPU library's host plan (agp::build) refuses
// bs128m and tokch17m (D3: the bounds of the CPU decoders), lit_ch32k (D7), lit_ch65636 (D6), dna_noexc_h3 (D18), and keeps
// refusing zstd_multi (one frame per chunk, refused before); every version-2 conformance fixture still plans (as in 2.6.6).
//   default build: 6 of 6 refused                                                                             -> pass
//   control -DAX_GPU_BOUNDS_NO_CHECK -DAX_LITCH_NO_CHECK -DAX_DNA_NOEXC_NO_CHECK (the plan of 2.6.6): the 5 new ones plan
// Host only. Prints: gpu_plan_267 <check|control> <pass|fail> <detail>. Usage: gpu_plan_267_test <this dir> <fixtures/conf>
#include "aceapex.h"
#include "aceapex_gpu_plan.h"
#include <algorithm>
#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
static uint64_t nvt(size_t n, size_t, size_t) { return 64 * n; }
static int plan(const std::string& p) { std::ifstream f(p, std::ios::binary); std::vector<uint8_t> a((std::istreambuf_iterator<char>(f)), {});
    if (a.size() < 12) return -1; agp::Plan P; return agp::build(a.data(), a.size(), P, nvt); }
int main(int argc, char** argv) {
#if defined(AX_GPU_BOUNDS_NO_CHECK) && defined(AX_LITCH_NO_CHECK) && defined(AX_DNA_NOEXC_NO_CHECK)
    const bool control = true;
#else
    const bool control = false;
#endif
    if (argc < 3) return 2;
    const char* nw[5] = {"bs128m", "tokch17m", "lit_ch32k", "lit_ch65636", "dna_noexc_h3"};
    int rn = 0, an = 0, miss = 0; std::string det;
    for (const char* x : nw) { const int r = plan(std::string(argv[1]) + "/" + x + ".aet"); if (r < 0) miss++; else if (r) rn++; else an++; det += std::string(det.empty() ? "" : ", ") + x + " " + std::to_string(r); }
    const int ro = plan(std::string(argv[1]) + "/zstd_multi.aet");
    int fx = 0, fok = 0;
    if (DIR* d = opendir(argv[2])) { std::vector<std::string> v; while (dirent* e = readdir(d)) { std::string s = e->d_name; if (s.size() > 4 && s.substr(s.size() - 4) == ".aet") v.push_back(s); } closedir(d);
        for (auto& s : v) { std::ifstream f(std::string(argv[2]) + "/" + s, std::ios::binary); char h[12] = {}; f.read(h, 12); uint32_t ver; memcpy(&ver, h + 8, 4);
            if (ver != 2 || s == "dna_depth_legacy.aet") continue; fx++; if (plan(std::string(argv[2]) + "/" + s) == 0) fok++; } }
    const bool pass = miss == 0 && ro > 0 && fx > 0 && fok == fx && (control ? an == 5 : rn == 5);
    printf("gpu_plan_267\t%s\t%s\tplan status: %s; zstd_multi %d; version-2 fixtures planned %d of %d\n", control ? "control" : "check", pass ? "pass" : "fail", det.c_str(), ro, fok, fx);
    return pass ? 0 : 1;
}
