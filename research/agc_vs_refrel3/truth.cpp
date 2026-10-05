// truth.cpp <sample> <requests.tsv>... < FASTA   - the reference answers from the source FASTA (gzip -dc of the
// manifest-checked .fa.gz): per contig its upper-case bases; prints CTG lines (order of the file), REQ lines for every
// request of this sample (SHA-256 of the upper-case range), SAMPLE line (bases, SHA-256 of all upper-case bases in
// file order). Contig name = header up to the first space or tab.
#include "bench_common.h"
int main(int argc, char** argv) {
    if (argc < 2) return 1; const std::string sample = argv[1]; std::map<std::string, std::vector<Req>> want;
    for (int a = 2; a < argc; a++) for (auto& q : read_reqs(argv[a])) if (q.sample == sample) want[q.ctg].push_back(q);
    std::vector<char> buf(1 << 24); std::string name, seq; bool have = false; uint64_t total = 0; unsigned char md[32];
    EVP_MD_CTX* whole = EVP_MD_CTX_new(); EVP_DigestInit_ex(whole, EVP_sha256(), nullptr);
    auto flush = [&] { if (!have) return; printf("CTG\t%s\t%s\t%zu\n", sample.c_str(), name.c_str(), seq.size()); EVP_DigestUpdate(whole, seq.data(), seq.size()); total += seq.size();
        auto it = want.find(name); if (it != want.end()) for (auto& q : it->second) { if (q.start + q.len > seq.size()) { fprintf(stderr, "request %s outside %s\n", q.id.c_str(), name.c_str()); exit(2); }
            printf("REQ\t%s\t%s\n", q.id.c_str(), sha_upper(seq.data() + q.start, q.len).c_str()); }
        seq.clear(); };
    std::string line; int c; line.reserve(1 << 20);
    for (;;) { size_t n = fread(buf.data(), 1, buf.size(), stdin); if (!n) break;
        for (size_t i = 0; i < n; i++) { c = buf[i]; if (c == '\n') {
                if (!line.empty() && line[0] == '>') { flush(); name = line.substr(1, line.find_first_of(" \t") - 1); have = true; }
                else { for (auto& ch : line) if (ch >= 'a' && ch <= 'z') ch -= 32; seq += line; } line.clear(); }
            else if (c != '\r') line.push_back((char)c); } }
    if (!line.empty()) { for (auto& ch : line) if (ch >= 'a' && ch <= 'z') ch -= 32; seq += line; }
    flush(); unsigned int ml = 32; EVP_DigestFinal_ex(whole, md, &ml); const std::string s = sha_hex(md);
    printf("SAMPLE\t%s\t%llu\t%s\n", sample.c_str(), (unsigned long long)total, s.c_str()); return 0;
}
