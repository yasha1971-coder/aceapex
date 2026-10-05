// bench_common.h - shared by truth.cpp, agcbench.cpp, rr3bench.cpp (research/agc_vs_refrel3): request files, truth
// files, SHA-256 (OpenSSL libcrypto), the 3 warm-up + 9 timed run protocol, output lines.
// Request TSV: id <tab> sample <tab> contig <tab> start (0-based) <tab> length. Truth TSV (truth.cpp): REQ id sha256 /
// CTG sample contig length / SAMPLE sample bases sha256 - every SHA over upper-case bases, no line ends, no headers.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <atomic>
#include <map>
#include <string>
#include <thread>
#include <vector>
extern "C" {
unsigned char* SHA256(const unsigned char* d, size_t n, unsigned char* md);
typedef struct evp_md_ctx_st EVP_MD_CTX; typedef struct evp_md_st EVP_MD;               // OpenSSL 3 EVP (streaming SHA-256)
EVP_MD_CTX* EVP_MD_CTX_new(void); void EVP_MD_CTX_free(EVP_MD_CTX*); const EVP_MD* EVP_sha256(void);
int EVP_DigestInit_ex(EVP_MD_CTX*, const EVP_MD*, void*); int EVP_DigestUpdate(EVP_MD_CTX*, const void*, size_t); int EVP_DigestFinal_ex(EVP_MD_CTX*, unsigned char*, unsigned int*);
}
static std::string sha_hex(const unsigned char* md) { static const char* h = "0123456789abcdef"; std::string s; for (int i = 0; i < 32; i++) { s += h[md[i] >> 4]; s += h[md[i] & 15]; } return s; }
struct Req { std::string id, sample, ctg; uint64_t start, len; };
static double now_s_() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static std::string sha_upper(const char* p, size_t n) {
    std::string u(p, n); for (auto& c : u) if (c >= 'a' && c <= 'z') c -= 32;
    unsigned char md[32]; SHA256((const unsigned char*)u.data(), u.size(), md); static const char* h = "0123456789abcdef"; std::string s;
    for (int i = 0; i < 32; i++) { s += h[md[i] >> 4]; s += h[md[i] & 15]; } return s;
}
static std::vector<std::vector<std::string>> read_tsv(const char* path) {
    std::vector<std::vector<std::string>> r; FILE* f = fopen(path, "r"); if (!f) { perror(path); exit(1); } char line[1 << 16];
    while (fgets(line, sizeof line, f)) { std::string L(line); while (!L.empty() && (L.back() == '\n' || L.back() == '\r')) L.pop_back(); if (L.empty() || L[0] == '#') continue;
        std::vector<std::string> v; size_t p = 0; for (;;) { size_t q = L.find('\t', p); v.push_back(L.substr(p, q - p)); if (q == std::string::npos) break; p = q + 1; } r.push_back(v); }
    fclose(f); return r;
}
static std::vector<Req> read_reqs(const char* path) { std::vector<Req> r; for (auto& v : read_tsv(path)) if (v.size() >= 5 && v[0] != "id") r.push_back({v[0], v[1], v[2], strtoull(v[3].c_str(), 0, 10), strtoull(v[4].c_str(), 0, 10)}); return r; }
struct Truth { std::map<std::string, std::string> req, sample_sha; std::map<std::string, std::vector<std::pair<std::string, uint64_t>>> ctgs; std::map<std::string, uint64_t> bases; };
static Truth read_truth(const char* path) { Truth t; for (auto& v : read_tsv(path)) {
    if (v[0] == "REQ") t.req[v[1]] = v[2]; else if (v[0] == "CTG") t.ctgs[v[1]].push_back({v[2], strtoull(v[3].c_str(), 0, 10)});
    else if (v[0] == "SAMPLE") { t.bases[v[1]] = strtoull(v[2].c_str(), 0, 10); t.sample_sha[v[1]] = v[3]; } } return t; }
// run protocol: body(run) returns per-item outputs; check(run) -> number correct; prints RUN lines
template <class Body, class Check> static int protocol(const char* label, int WU, int R, size_t items, uint64_t bytes, Body body, Check check) {
    int bad = 0;
    for (int r = 0; r < WU + R; r++) { const double t0 = now_s_(); body(); const double t = now_s_() - t0; const size_t ok = check();
        if (ok != items) bad++;
        printf("RUN\t%s\t%d\t%s\t%.6f\t%zu items\t%llu bytes\tsha256 %zu/%zu\n", label, r, r < WU ? "warmup" : "timed", t, items, (unsigned long long)bytes, ok, items); fflush(stdout); }
    return bad;
}
template <class F> static void par_for(size_t n, int T, F f) {           // dynamic chunks of 16; f(thread, i)
    std::atomic<size_t> next{0}; std::vector<std::thread> th;
    for (int t = 0; t < T; t++) th.emplace_back([&, t] { for (;;) { const size_t a = next.fetch_add(16); if (a >= n) break; for (size_t i = a; i < std::min(n, a + 16); i++) f(t, i); } });
    for (auto& x : th) x.join();
}
