#include "refrel3v1_nomain.cpp"
int main(int argc, char** argv) { for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Ref ref = load_ref(argv[1], 1, false);
  for (int a = 2; a < argc; a++) { std::vector<uint8_t> f = slurp(argv[a]); V1 X; std::string why; if (open_v1(f.data(), f.size(), ref, X, why)) { printf("%s refused %s\n", argv[a], why.c_str()); continue; }
    long k[4] = {0}; std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q);
    for (uint64_t b = 0; b < X.nb; b++) { const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
      int n = r3_decode_block(X.P + X.off[b], (uint32_t)(X.off[b+1]-X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size());
      for (int i = 0; i < n; i++) k[ops[i].kind]++; }
    printf("%s Q %u blocks %llu hashes %d case_runs %zu contigs %zu | literal %ld ref %ld self %ld rc %ld\n", argv[a], X.Q, (unsigned long long)X.nb, X.hashes ? 1 : 0, X.low.size(), X.rec.size(), k[0], k[1], k[2], k[3]); } }
