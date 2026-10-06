// truth_v1.cpp <ref.fa> <archive dir> <names.tsv> <requests.tsv>... - truth for sets whose source FASTA is not on disk:
// every v1 archive (<dir>/<manifest name>.q16k.rr3) decoded in full with every check on (block XXH3 and the XXH3 of the
// rebuilt FASTA == the header's, i.e. the source file's XXH3 recorded at encoding, also in the manifest), and only then
// the same lines as truth.cpp (CTG / REQ / SAMPLE, upper-case bases) from that FASTA. names.tsv: manifest name <tab>
// AGC set name (the sample column of the requests). One archive in memory at a time.
#include "refrel3v1_nomain.cpp"
#include "bench_common.h"
int main(int argc, char** argv) {
    if (argc < 5) return 1;
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    Ref ref = load_ref(argv[1], 1, false); const std::string dir = argv[2]; const int T = (int)std::thread::hardware_concurrency();
    std::map<std::string, std::map<std::string, std::vector<Req>>> want; for (int a = 4; a < argc; a++) for (auto& q : read_reqs(argv[a])) want[q.sample][q.ctg].push_back(q);
    for (auto& v : read_tsv(argv[3])) { const std::string man = v[0], smp = v[1];
        const std::vector<uint8_t> f = slurp(dir + "/" + man + ".q16k.rr3"); V1 X; std::string why, fa;
        if (open_v1(f.data(), f.size(), ref, X, why)) { fprintf(stderr, "%s refused: %s\n", man.c_str(), why.c_str()); return 2; }
        const int e = full_v1(X, ref, fa, true, T); if (e) { fprintf(stderr, "%s: decode check %d failed\n", man.c_str(), e); return 3; }
        EVP_MD_CTX* whole = EVP_MD_CTX_new(); EVP_DigestInit_ex(whole, EVP_sha256(), nullptr); uint64_t total = 0; auto& wq = want[smp];
        size_t i = 0; std::string seq;
        while (i < fa.size()) { const size_t he = fa.find('\n', i); const std::string hdr = fa.substr(i + 1, he - i - 1); const std::string name = hdr.substr(0, hdr.find_first_of(" \t"));
            size_t j = he + 1; seq.clear(); while (j < fa.size() && fa[j] != '>') { const size_t le = fa.find('\n', j); seq.append(fa, j, le - j); j = le + 1; }
            for (auto& c : seq) if (c >= 'a' && c <= 'z') c -= 32;
            printf("CTG\t%s\t%s\t%zu\n", smp.c_str(), name.c_str(), seq.size()); EVP_DigestUpdate(whole, seq.data(), seq.size()); total += seq.size();
            auto it = wq.find(name); if (it != wq.end()) for (auto& q : it->second) { if (q.start + q.len > seq.size()) { fprintf(stderr, "request outside\n"); return 4; } printf("REQ\t%s\t%s\n", q.id.c_str(), sha_upper(seq.data() + q.start, q.len).c_str()); }
            i = j; }
        unsigned char md[32]; unsigned int ml = 32; EVP_DigestFinal_ex(whole, md, &ml); EVP_MD_CTX_free(whole);
        printf("SAMPLE\t%s\t%llu\t%s\n", smp.c_str(), (unsigned long long)total, sha_hex(md).c_str()); fflush(stdout);
        fprintf(stderr, "%s ok (FASTA XXH3 == source)\n", man.c_str()); }
    return 0;
}
