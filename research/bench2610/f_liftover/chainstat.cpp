// chainstat <ref.fa> <archive.rr3> - how far the RLZ copies of a refrel3 v1 archive go as a reference -> haplotype map.
// Every ref / rc op of every block is put at its absolute haplotype position; consecutive copies on the same diagonal
// (forward: ref - hap constant, rc: ref + hap constant, drift <= DRIFT bases, hap gap <= GAP bases, same hap contig and
// same ref chromosome) are merged into chains. Prints bases by op kind, copy-length percentiles, chain count / N50, hap
// bases inside chains >= 10 kb / 100 kb / 1 Mb, and the share of copied bases whose ref chromosome is the dominant one
// of their hap contig. Built against refrel3v1.cpp with its main() renamed (see build.sh).
#include "refrel3v1_nomain.cpp"
#include <algorithm>
static const int64_t DRIFT = 64, GAP = 1000;
struct Cp { uint64_t h, r; uint32_t len; int rc; };
int main(int argc, char** argv) {
  for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Fasta RF = read_fasta(argv[1]); Ref ref; ref.R = upper(RF.b); rr_sha256(ref.R.data(), ref.R.size(), ref.sha);
  std::vector<uint64_t> rs; uint64_t acc = 0; for (auto& r : RF.rec) { rs.push_back(acc); acc += r.len; } rs.push_back(acc);
  RF.b.clear(); RF.b.shrink_to_fit();
  auto rchr = [&](uint64_t p) { return (int)(std::upper_bound(rs.begin(), rs.end(), p) - rs.begin()) - 1; };
  std::vector<uint8_t> f = slurp(argv[2]); V1 X; std::string why;
  if (open_v1(f.data(), f.size(), ref, X, why)) { printf("refused %s\n", why.c_str()); return 2; }
  std::vector<uint64_t> hs; acc = 0; for (auto& r : X.rec) { hs.push_back(acc); acc += r.len; } hs.push_back(acc);
  auto hctg = [&](uint64_t p) { return (int)(std::upper_bound(hs.begin(), hs.end(), p) - hs.begin()) - 1; };
  uint64_t kb[4] = {0}, kn[4] = {0}; std::vector<Cp> cp; std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q);
  for (uint64_t b = 0; b < X.nb; b++) {
    const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
    int n = r3_decode_block(X.P + X.off[b], (uint32_t)(X.off[b+1]-X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size());
    if (n < 0) { printf("block %llu failed\n", (unsigned long long)b); return 3; }
    for (int i = 0; i < n; i++) { kb[ops[i].kind] += ops[i].len; kn[ops[i].kind]++;
      if (ops[i].kind == 1 || ops[i].kind == 3) cp.push_back({b * X.Q + ops[i].dst, ops[i].src, ops[i].len, ops[i].kind == 3}); } }
  std::vector<uint32_t> L; for (auto& c : cp) L.push_back(c.len); std::sort(L.begin(), L.end());
  auto pct = [&](double q) { return L.empty() ? 0u : L[(size_t)(q * (L.size() - 1))]; };
  // chains (copies are already in haplotype order)
  std::vector<uint64_t> chainlen; uint64_t ch_h0 = 0, ch_h1 = 0; int64_t diag = 0; int crc = -1, cc = -1, cr = -1;
  auto close = [&]() { if (crc >= 0) chainlen.push_back(ch_h1 - ch_h0); };
  for (auto& c : cp) {
    int hc = hctg(c.h), rc_ = rchr(c.r); int64_t d = c.rc ? (int64_t)(c.r + c.len) + (int64_t)c.h : (int64_t)c.r - (int64_t)c.h;
    if (crc == c.rc && cc == hc && cr == rc_ && (int64_t)c.h - (int64_t)ch_h1 <= GAP && std::llabs(d - diag) <= DRIFT) { ch_h1 = c.h + c.len; diag = d; continue; }
    close(); crc = c.rc; cc = hc; cr = rc_; ch_h0 = c.h; ch_h1 = c.h + c.len; diag = d; }
  close();
  std::vector<uint64_t> C = chainlen; std::sort(C.rbegin(), C.rend()); uint64_t tot = 0; for (auto x : C) tot += x;
  uint64_t run = 0, n50 = 0; for (auto x : C) { run += x; if (run * 2 >= tot) { n50 = x; break; } }
  uint64_t in10k = 0, in100k = 0, in1m = 0; for (auto x : C) { if (x >= 10000) in10k += x; if (x >= 100000) in100k += x; if (x >= 1000000) in1m += x; }
  // dominant ref chromosome per hap contig, by copied bases
  std::vector<std::vector<uint64_t>> by(X.rec.size(), std::vector<uint64_t>(rs.size(), 0));
  for (auto& c : cp) by[hctg(c.h)][rchr(c.r)] += c.len;
  uint64_t dom = 0, all = 0; for (auto& v : by) { uint64_t m = 0; for (auto x : v) { all += x; m = std::max(m, x); } dom += m; }
  const double H = (double)X.nbases;
  printf("archive %s\nQ %u blocks %llu hap_bases %llu hap_contigs %zu ref_chromosomes %zu\n", argv[2], X.Q, (unsigned long long)X.nb, (unsigned long long)X.nbases, X.rec.size(), RF.rec.size());
  const char* K[4] = {"literal", "ref", "self", "rc"};
  for (int k = 0; k < 4; k++) printf("kind %-7s ops %12llu bases %14llu (%.4f of hap)\n", K[k], (unsigned long long)kn[k], (unsigned long long)kb[k], kb[k] / H);
  printf("copies(ref+rc) %zu  length p10 %u p50 %u p90 %u p99 %u max %u\n", L.size(), pct(.1), pct(.5), pct(.9), pct(.99), L.empty() ? 0 : L.back());
  printf("chains %zu (drift <= %lld, gap <= %lld) N50 %llu  hap bases in chains: total %.4f, >=10kb %.4f, >=100kb %.4f, >=1Mb %.4f\n", C.size(), (long long)DRIFT, (long long)GAP,
         (unsigned long long)n50, tot / H, in10k / H, in100k / H, in1m / H);
  printf("copied bases on the dominant ref chromosome of their hap contig: %.4f\n", all ? (double)dom / all : 0.0);
  printf("index bytes at 24 B per chain: %llu; at 16 B per copy: %llu\n", (unsigned long long)C.size() * 24, (unsigned long long)L.size() * 16);
}
