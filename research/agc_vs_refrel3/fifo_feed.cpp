// fifo_feed.cpp <ref.fa> <archive dir> <dataset> <fifo dir> <max decodes> <manifest name>... - feeds AGC with FASTA
// that is never stored: for every name a named pipe <fifo dir>/<name>.fa is created and served by its own thread: the
// thread blocks until a reader opens the pipe, then decodes <archive dir>/<name>.<dataset>.rr3 with every check on
// (refrel3v1 full_v1 verify: block XXH3 + rebuilt FASTA XXH3 == the header's = the source's) and writes the FASTA;
// a failed check writes nothing (the reader sees an empty file) and is reported. At most <max decodes> decodes hold
// memory at a time. The decoded T2T is loaded once. Exit code 0 only if every pipe was served in full.
// A name may be given as <fifo name>=<archive name> (pipe <fifo name>.fa fed from <archive name>.<dataset>.rr3).
#include "refrel3v1_nomain.cpp"
#include <condition_variable>
#include <map>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc, char** argv) {
    if (argc < 7) { fprintf(stderr, "usage: fifo_feed <ref.fa> <archive dir> <dataset> <fifo dir> <max decodes> <name>...\n"); return 1; }
    signal(SIGPIPE, SIG_IGN);
    for (int c = 0; c < 256; c++) COMP[c] = rr_comp((uint8_t)c);
    Ref ref = load_ref(argv[1], 1, false); const std::string adir = argv[2], ds = argv[3], fdir = argv[4]; const int MAXD = atoi(argv[5]);
    std::vector<std::string> names(argv + 6, argv + argc);
    std::map<std::string, std::string> arc; for (auto& n : names) { const size_t e = n.find('='); if (e != std::string::npos) { arc[n.substr(0, e)] = n.substr(e + 1); n = n.substr(0, e); } else arc[n] = n; }
    for (auto& n : names) { const std::string p = fdir + "/" + n + ".fa"; unlink(p.c_str()); if (mkfifo(p.c_str(), 0600)) { perror(p.c_str()); return 2; } }
    fprintf(stderr, "fifo_feed: reference loaded, %zu pipes ready\n", names.size());
    std::mutex mu; std::condition_variable cv; int active = 0; std::atomic<int> bad{0};
    std::vector<std::thread> th;
    for (auto& n : names) th.emplace_back([&, n] {
        const std::string p = fdir + "/" + n + ".fa";
        const int fd = open(p.c_str(), O_WRONLY);                                     // blocks until AGC opens it
        if (fd < 0) { perror(p.c_str()); bad++; return; }
        { std::unique_lock<std::mutex> lk(mu); cv.wait(lk, [&] { return active < MAXD; }); active++; }
        std::string fa; bool ok = false;
        { const std::vector<uint8_t> a = slurp(adir + "/" + arc.at(n) + "." + ds + ".rr3"); V1 X; std::string why;
          if (open_v1(a.data(), a.size(), ref, X, why)) fprintf(stderr, "%s refused: %s\n", n.c_str(), why.c_str());
          else { const int e = full_v1(X, ref, fa, true, 4); if (e) fprintf(stderr, "%s: decode check %d failed\n", n.c_str(), e); else ok = true; } }
        size_t off = 0;
        if (ok) while (off < fa.size()) { const ssize_t w = write(fd, fa.data() + off, std::min<size_t>(1 << 20, fa.size() - off)); if (w <= 0) { fprintf(stderr, "%s: write failed at %zu\n", n.c_str(), off); break; } off += (size_t)w; }
        close(fd); std::string().swap(fa);
        { std::lock_guard<std::mutex> lk(mu); active--; } cv.notify_all();
        if (!ok || off == 0) bad++;
        fprintf(stderr, "%s %s (%zu B)\n", n.c_str(), ok && off ? "served" : "FAILED", off); });
    for (auto& t : th) t.join();
    for (auto& n : names) unlink((fdir + "/" + n + ".fa").c_str());
    return bad ? 3 : 0;
}
