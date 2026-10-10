// opdump <ref.fa> <archive> - every op of every block as decoded by the frozen v1 code: block kind src dst len (not shipped)
#include "refrel3v1_nomain.cpp"
int main(int argc, char** argv) { for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Ref ref = load_ref(argv[1], 1, false); std::vector<uint8_t> f = slurp(argv[2]); V1 X; std::string why;
  if (open_v1(f.data(), f.size(), ref, X, why)) { printf("refused %s\n", why.c_str()); return 2; }
  std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q);
  for (uint64_t b = 0; b < X.nb; b++) { const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
    int n = r3_decode_block(X.P + X.off[b], (uint32_t)(X.off[b+1]-X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size());
    if (n < 0) { printf("block %llu failed\n", (unsigned long long)b); return 3; }
    for (int i = 0; i < n; i++) printf("%llu %u %llu %u %u\n", (unsigned long long)b, ops[i].kind, (unsigned long long)ops[i].src, ops[i].dst, ops[i].len); } }
