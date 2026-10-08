// blocks <ref.fa> <archive>: payload start, hash-section start, per block: index, payload offset (absolute), length
#include "refrel3v1_nomain.cpp"
int main(int argc, char** argv) { for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Ref ref = load_ref(argv[1], 1, false); std::vector<uint8_t> f = slurp(argv[2]); V1 X; std::string why;
  if (open_v1(f.data(), f.size(), ref, X, why)) { printf("refused %s\n", why.c_str()); return 2; }
  printf("PSTART %zu\nHASHES %zu\nNB %llu\n", (size_t)(X.P - f.data()), X.hashes ? (size_t)(X.hashes - f.data()) : 0, (unsigned long long)X.nb);
  for (uint64_t b = 0; b < X.nb; b++) printf("B %llu %zu %llu\n", (unsigned long long)b, (size_t)(X.P - f.data()) + X.off[b], (unsigned long long)(X.off[b + 1] - X.off[b])); }
