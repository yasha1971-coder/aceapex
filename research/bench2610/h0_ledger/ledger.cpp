// ledger <ref.fa> <archive>... - size ledger of refrel3 v1 archives (read only): file = header 136 + name 2+L + meta
// (zstd) + block-hash section + payload, exactly; meta raw split into contig table / case runs / model tables / block
// table; payload split by field: ideal entropy bits of the symbols (log2(4096/f)) + raw bits, per context group, and
// the coder overhead = payload bits - ideal bits (state flush 3 B per block, renormalisation rounding). Prints one LED
// line per archive (all values in bytes; fields in fractional bytes).
#include "refrel3v1_nomain.cpp"
static const char* GN[] = {"LL", "lit_short", "lit_long", "kind", "delta", "rep_which", "rep_delta", "abs_dir_pos", "self_dist", "length", "flip_which", "flip_delta"};
static int grp(int c) { return c < 4 ? 0 : c < 14 ? 1 : c < 31 ? 2 : c < 47 ? 3 : c < 49 ? 4 : c == 49 ? 5 : c == 50 ? 6 : c == 51 ? 7 : c == 52 ? 8 : c < 59 ? 9 : c == 59 ? 10 : 11; }
int main(int argc, char** argv) { for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
  Ref ref = load_ref(argv[1], 1, false);
  printf("#LED\tarchive\tfile\theader\tname\tmeta_zstd\tmeta_raw\tmeta_raw_contigs\tmeta_raw_case\tmeta_raw_tables\tmeta_raw_blocktable\thashes\tpayload\tblocks");
  for (auto g : GN) printf("\t%s_sym\t%s_raw", g, g); printf("\tcoder_overhead\tcheck\n");
  for (int ai = 2; ai < argc; ai++) {
    std::vector<uint8_t> f = slurp(argv[ai]); V1 X; std::string why;
    if (open_v1(f.data(), f.size(), ref, X, why)) { printf("REFUSED\t%s\t%s\n", argv[ai], why.c_str()); return 2; }
    const uint64_t nl = f[136] | f[137] << 8, mz = rd64(&f[96]), mr = rd64(&f[104]), hs = rd64(&f[112]), pl = rd64(&f[120]);
    // meta raw parts (same parse as open_v1)
    std::vector<uint8_t> M(mr); ZSTD_decompress(M.data(), mr, &f[138 + nl], mz); size_t i = 0;
    auto lebs = [&]() { while (M[i++] & 0x80) {} };
    uint32_t nr; memcpy(&nr, &M[0], 4); i = 4; for (uint32_t r = 0; r < nr; r++) { uint32_t hl; memcpy(&hl, &M[i], 4); i += 4 + hl + 12; }
    const size_t p_ct = i; uint64_t nruns; memcpy(&nruns, &M[i], 8); i += 8; for (uint64_t k = 0; k < 2 * nruns; k++) lebs();
    const size_t p_case = i - p_ct; const size_t t0 = i; for (int c = 0; c < R3_NCTX; c++) for (int s = 0; s < R3_ALPHA[c]; s++) lebs();
    const size_t p_tab = i - t0; const size_t p_bt = M.size() - i;
    memset(g_led_sym, 0, sizeof g_led_sym); memset(g_led_raw, 0, sizeof g_led_raw); memset(g_led_n, 0, sizeof g_led_n); g_led = 1;
    std::vector<RrOp> ops(RR_MAXOPS); std::vector<uint8_t> lit(X.Q);
    for (uint64_t b = 0; b < X.nb; b++) { const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
      if (r3_decode_block(X.P + X.off[b], (uint32_t)(X.off[b + 1] - X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], ops.data(), (uint32_t)ops.size(), lit.data(), (uint32_t)lit.size()) < 0) { printf("FAILED\t%s\tblock %llu\n", argv[ai], (unsigned long long)b); return 3; } }
    g_led = 0;
    double gs[12] = {0}, gr[12] = {0}, ideal = 0; for (int c = 0; c < R3_NCTX; c++) { gs[grp(c)] += g_led_sym[c] / 8; gr[grp(c)] += g_led_raw[c] / 8.0; ideal += g_led_sym[c] / 8 + g_led_raw[c] / 8.0; }
    const uint64_t sum = 136 + 2 + nl + mz + hs + pl;
    printf("LED\t%s\t%zu\t136\t%llu\t%llu\t%llu\t%zu\t%zu\t%zu\t%zu\t%llu\t%llu\t%llu", argv[ai], f.size(), (unsigned long long)(2 + nl), (unsigned long long)mz, (unsigned long long)mr, p_ct, p_case, p_tab, p_bt, (unsigned long long)hs, (unsigned long long)pl, (unsigned long long)X.nb);
    for (int g = 0; g < 12; g++) printf("\t%.3f\t%.3f", gs[g], gr[g]);
    printf("\t%.3f\t%s\n", pl - ideal, sum == f.size() && p_ct + p_case + p_tab + p_bt == mr ? "sum==file" : "SUM_DIFFERS"); fflush(stdout); } }
