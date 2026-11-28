// gpu_plan_266_test.cpp - claim head_gpu_plan_266 (2.6.7, PORT-266): the GPU library's host plan (agp::build,
// src/aceapex_gpu_plan.h - every GPU decode starts from it) refuses the regression archives of 2.6.6 as the CPU decoders
// do: verify/repro/hdr_version (8, E_HEADER - already before), boffs_contig (3, E_TABLE - new), stream_hdr (4: the two
// literal-size ones before, tok_bit63 and lit_tag_nochunk new), dna_exc_h3h4zero (before); and builds the plan of
// dna_exc_intact and of every version-2 conformance fixture it built before. Host only (no device, no nvCOMP).
//   default build:                                         16 of 16 refused; fixtures as the control   -> pass
//   -DAX_BOFFS_CONTIG_NO_CHECK -DAX_STREAM_HDR_NO_CHECK:   the control (the plan of 2.6.6) - the 5 new ones build a plan
// Prints: gpu_plan_266 <check|control> <pass|fail> <detail>. Usage: gpu_plan_266_test <verify/repro> <verify/fixtures/conf>
#include "aceapex.h"
#include "aceapex_gpu_plan.h"
#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <algorithm>
static uint64_t nvt(size_t n, size_t, size_t) { return 64 * n; }
static int plan(const std::string& p) { std::ifstream f(p, std::ios::binary); std::vector<uint8_t> a((std::istreambuf_iterator<char>(f)), {});
    if (a.size() < 12) return -1; agp::Plan P; return agp::build(a.data(), a.size(), P, nvt); }
int main(int argc, char** argv) {
#if defined(AX_BOFFS_CONTIG_NO_CHECK) && defined(AX_STREAM_HDR_NO_CHECK)
    const bool control = true;
#else
    const bool control = false;
#endif
    if (argc < 3) { fprintf(stderr, "usage: %s <verify/repro> <fixtures/conf>\n", argv[0]); return 2; }
    const std::string R = argv[1];
    const char* old_[] = {"hdr_version/dna_4096B_v0", "hdr_version/dna_4096B_v1", "hdr_version/dna_4096B_v4", "hdr_version/dna_4096B_vce02",
        "hdr_version/text_200K_v0", "hdr_version/text_200K_v1", "hdr_version/text_200K_v4", "hdr_version/text_200K_vce02",
        "stream_hdr/litch_e63", "stream_hdr/lit4_e63", "dna_exc/dna_exc_h3h4zero"};
    const char* new_[] = {"boffs_contig/last_lit0", "boffs_contig/mid_lit0", "boffs_contig/mid_lit_shift", "stream_hdr/tok_bit63", "stream_hdr/lit_tag_nochunk"};
    int ro = 0, rn = 0, an = 0, miss = 0;
    for (const char* x : old_) { const int r = plan(R + "/" + x + ".aet"); if (r < 0) miss++; else if (r != 0) ro++; }
    for (const char* x : new_) { const int r = plan(R + "/" + x + ".aet"); if (r < 0) miss++; else if (r != 0) rn++; else an++; }
    const bool intact = plan(R + "/dna_exc/dna_exc_intact.aet") == 0;
    // version-2 fixtures: the plan of each must be built (E_OK) except the two it never built (empty.aet is not in conf;
    // dna_depth_legacy: the plan refuses it with and without these checks)
    int fx = 0, fok = 0; std::string bad;
    if (DIR* d = opendir(argv[2])) { std::vector<std::string> names; while (dirent* e = readdir(d)) { std::string n = e->d_name; if (n.size() > 4 && n.substr(n.size() - 4) == ".aet") names.push_back(n); } closedir(d);
        std::sort(names.begin(), names.end());
        for (auto& n : names) { std::ifstream f(std::string(argv[2]) + "/" + n, std::ios::binary); char h[12] = {}; f.read(h, 12); uint32_t v; memcpy(&v, h + 8, 4);
            if (v != 2 || n == "dna_depth_legacy.aet") continue; fx++; if (plan(std::string(argv[2]) + "/" + n) == 0) fok++; else bad += " " + n; } }
    const bool pass = miss == 0 && intact && fx > 0 && fok == fx && ro == 11 && (control ? an == 5 : rn == 5);
    printf("gpu_plan_266\t%s\t%s\trefused: %d of 11 old, %d of 5 new (%d built a plan); dna_exc_intact %s; version-2 fixtures planned %d of %d%s%s\n",
           control ? "control" : "check", pass ? "pass" : "fail", ro, rn, an, intact ? "planned" : "REFUSED", fok, fx, bad.empty() ? "" : " - refused:", bad.c_str());
    if (miss) printf("gpu_plan_266\tinputs missing: %d\n", miss);
    return pass ? 0 : 1;
}
