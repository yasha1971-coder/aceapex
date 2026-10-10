#include "refrel3v1_nomain.cpp"
int main(int argc, char** argv) { for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Ref ref = load_ref(argv[1], 1, false); std::vector<uint8_t> f = slurp(argv[2]); V1 X; std::string why;
  if (open_v1(f.data(), f.size(), ref, X, why)) return 2; const uint64_t b = strtoull(argv[3], 0, 10);
  std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q); const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
  const uint8_t* s = X.P + X.off[b]; printf("I %u\n", (uint32_t)s[0] | (uint32_t)s[1] << 8 | (uint32_t)s[2] << 16);
  r3_trace = 1; r3_trace_base = s;
  int n = r3_decode_block(s, (uint32_t)(X.off[b+1]-X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size());
  r3_trace = 0; printf("N %d\n", n); }
