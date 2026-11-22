// stream_peak_test.cpp - claim head_stream_peak (2.6.4 step 4): the streaming decoder of the default profile
// (aceapex_decompress_stream) refuses the archives of #12 instead of holding memory the archive declares. Inputs (gen.py):
//   st_group  33 KB: 4 blocks of 64 MiB, 8 command chunks of 128 MiB (4 KiB zstd frames of zeros), block 0's command
//             slice the whole stream - 955a415 (main after step 3 + #11) held 2.1 GB
//   st_slice  34 KB: the same with 64 chunks of 16 MiB and a 1 GiB slice of block 0 - held the whole 1 GiB window
// Each archive is streamed (pread, a sink that discards, threads 1 and 4, with and without ACEAPEX_STREAM_VERIFY) in a
// child process; the child's peak is its own VmHWM after exec (wait4's ru_maxrss carries the parent's resident set over
// exec). Pass: a negative code and a peak of at most 64 MiB in every run. Prints one judge line.
// Usage: stream_peak_test <dir of the archives>
#include "aceapex.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
static int64_t rd(void* c, uint64_t o, void* d, size_t n) { return pread(*(int*)c, d, n, (off_t)o); }
static int wr(void*, const void*, size_t) { return 0; }
int main(int argc, char** argv) {
    if (argc == 6 && !strcmp(argv[1], "--child")) {   // child: stream, write "rc VmHWM" to argv[5]
        const int fd = open(argv[2], O_RDONLY); if (fd < 0) return 2;
        int f = fd; const int64_t r = aceapex_decompress_stream(rd, &f, wr, nullptr, atoi(argv[3]), atoi(argv[4]) ? ACEAPEX_STREAM_VERIFY : 0);
        FILE* q = fopen("/proc/self/status", "r"); char l[256]; long hwm = -1;
        while (q && fgets(l, sizeof l, q)) if (!strncmp(l, "VmHWM:", 6)) hwm = atol(l + 6);
        if (q) fclose(q); FILE* o = fopen(argv[5], "w"); if (o) { fprintf(o, "%lld %ld\n", (long long)r, hwm); fclose(o); }
        return 0;
    }
    if (argc < 2) { fprintf(stderr, "usage: %s <dir>\n", argv[0]); return 2; }
    std::string det; bool ok = true; long worst = 0;
    for (const char* nm : {"st_group", "st_slice"}) for (int T : {1, 4}) for (int V : {0, 1}) {
        const std::string a = std::string(argv[1]) + "/" + nm + ".aet";
        char out[] = "/tmp/ax_peak_XXXXXX"; const int ofd = mkstemp(out); if (ofd >= 0) close(ofd);
        const std::string ts = std::to_string(T), vs = std::to_string(V);
        const pid_t pid = fork();
        if (pid == 0) { execl("/proc/self/exe", argv[0], "--child", a.c_str(), ts.c_str(), vs.c_str(), out, (char*)nullptr); _exit(3); }
        int st = 0; waitpid(pid, &st, 0);
        long long rc = 0; long hwm = -1; FILE* f = fopen(out, "r"); const bool got = f && fscanf(f, "%lld %ld", &rc, &hwm) == 2; if (f) fclose(f); unlink(out);
        const bool good = WIFEXITED(st) && WEXITSTATUS(st) == 0 && got && rc < 0 && hwm >= 0 && hwm <= 64 * 1024;
        ok = ok && good; if (hwm > worst) worst = hwm;
        char b[160]; snprintf(b, sizeof b, "%s%s T%d%s rc %lld VmHWM %ld KiB%s", det.empty() ? "" : ", ", nm, T, V ? " VERIFY" : "", rc, hwm, good ? "" : " (FAIL)");
        det += b;
    }
    printf("head_stream_peak\t%s\t#12 archives (33-34 KB declaring 128 MiB token chunks / a 1 GiB slice) streamed in a child, limit a negative code and VmHWM <= 64 MiB: %s\n",
           ok ? "pass" : "fail", det.c_str());
    return ok ? 0 : 1;
}
