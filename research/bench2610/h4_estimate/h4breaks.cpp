// h4breaks <ref.fa> <out dir> <archive>... - H4 estimate input (read only; no encoding): for every block of every
// archive, the ops in stream order with the cost of each op in bits (symbols log2(4096/f) + raw bits, cost hooks of
// ../h0_ledger/ledger_patch.py on a copy of the frozen v1 decoder). An EVENT is a literal run (possibly empty) plus
// the copy that follows it, or a final literal run. A BREAK is an event that is not the first of its block: its key is
// the T2T position where the previous reference copy ended (forward: end of the copy, reverse complement: its start,
// i.e. where the next base would come from) and the strand; its cost is the bits of the event. First events of blocks
// are not breaks (block start, kept as "block_start" cost). One binary file per archive: <name>.brk, records of
// u64 key (= position * 2 + strand), f32 cost bits; one TSV line per archive on stdout with totals.
#include "refrel3v1_nomain.cpp"
#include <cmath>
static double g_mark = 0;
static double cost_now() { double s = 0; for (int c = 0; c < 64; c++) s += g_led_sym[c] + (double)g_led_raw[c]; return s; }
static double g_cont_bits = 0; static uint64_t g_cont_n = 0;   // copies that continue the previous copy exactly, no literal in between
struct Sink {
    std::vector<std::pair<uint64_t, float>>* out; double* start_cost; uint64_t* n_ev;
    bool have_prev = false; uint64_t prev_end = 0; uint32_t prev_dir = 0; bool first = true; double ev_cost = 0; bool pending_lit = false;
    void flush() {
        if (first) *start_cost += ev_cost; else if (have_prev) out->push_back({prev_end * 2 + prev_dir, (float)ev_cost}); else *start_cost += ev_cost;
        (*n_ev)++; first = false; ev_cost = 0; pending_lit = false;
    }
    bool lit(uint32_t, uint32_t, uint8_t) { return true; }
    bool op(uint32_t kind, uint64_t src, uint32_t, uint32_t len) {
        const double c = cost_now(); ev_cost += c - g_mark; g_mark = c;
        if (kind == 0) { pending_lit = true; return true; }
        // a copy closes the event
        const bool cont = have_prev && !pending_lit && !first && ((kind == 1 && prev_dir == 0 && src == prev_end) || (kind == 3 && prev_dir == 1 && src + len == prev_end));
        if (cont) { g_cont_bits += ev_cost; g_cont_n++; }
        flush();
        if (kind == 1) { have_prev = true; prev_end = src + len; prev_dir = 0; }
        else if (kind == 3) { have_prev = true; prev_end = src; prev_dir = 1; }
        return true;
    }
};
int main(int argc, char** argv) {
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    Ref ref = load_ref(argv[1], 1, false); const std::string od = argv[2];
    printf("archive\tblocks\tevents\tbreaks\tbreak_bytes\tblock_start_bytes\tpayload_bytes\tfile_bytes\thash_bytes\tcont_events\tcont_bytes\n");
    for (int ai = 3; ai < argc; ai++) {
        std::vector<uint8_t> f = slurp(argv[ai]); V1 X; std::string why;
        if (open_v1(f.data(), f.size(), ref, X, why)) { fprintf(stderr, "%s refused %s\n", argv[ai], why.c_str()); return 2; }
        std::vector<std::pair<uint64_t, float>> brk; double start_cost = 0; uint64_t nev = 0; g_cont_bits = 0; g_cont_n = 0;
        memset(g_led_sym, 0, sizeof g_led_sym); memset(g_led_raw, 0, sizeof g_led_raw); g_led = 1; g_mark = 0;
        for (uint64_t b = 0; b < X.nb; b++) {
            const uint32_t blen = (uint32_t)std::min<uint64_t>(X.Q, X.nbases - b * X.Q);
            Sink sk; sk.out = &brk; sk.start_cost = &start_cost; sk.n_ev = &nev;
            if (r3_decode_stream(X.P + X.off[b], (uint32_t)(X.off[b + 1] - X.off[b]), X.T, ref.R.data(), ref.R.size(), blen, X.st[b], sk) < 0) { fprintf(stderr, "block failed\n"); return 3; }
            const double c = cost_now(); sk.ev_cost += c - g_mark; g_mark = c;
            if (sk.pending_lit || sk.ev_cost > 0) sk.flush();
        }
        g_led = 0;
        double bb = 0; for (auto& x : brk) bb += x.second;
        std::string nm = argv[ai]; nm = nm.substr(nm.find_last_of('/') + 1);
        FILE* o = fopen((od + "/" + nm + ".brk").c_str(), "wb"); for (auto& x : brk) { fwrite(&x.first, 8, 1, o); fwrite(&x.second, 4, 1, o); } fclose(o);
        printf("%s\t%llu\t%llu\t%zu\t%.0f\t%.0f\t%llu\t%zu\t%llu\t%llu\t%.0f\n", nm.c_str(), (unsigned long long)X.nb, (unsigned long long)nev, brk.size(), bb / 8, start_cost / 8,
               (unsigned long long)rd64(&f[120]), f.size(), (unsigned long long)rd64(&f[112]), (unsigned long long)g_cont_n, g_cont_bits / 8);
        fflush(stdout);
    }
}
