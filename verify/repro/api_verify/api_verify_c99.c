/* api_verify_c99.c - claim head_api_verify, C99 part (2.6.7, API-CHK-1; c/aceapex_decode.c = python/csrc): as
 * api_verify_test.cpp for the C99 decoder - aceapex_decompress_ex with ACEAPEX_VERIFY_XXH3 refuses the three archives of
 * this directory, without the flag they decode with success to wrong bytes, every conformance fixture verifies.
 *   default build: 3 of 3 refused, 3 of 3 wrong-but-success without the flag, fixtures 27 of 27   -> pass
 *   -DAX_VERIFY_NO_CHECK: the control - with the flag the three come back with success
 * Prints: api_verify_c99 <check|control> <pass|fail> <detail>. Usage: api_verify_c99 <this directory> <fixtures/conf> */
#include "aceapex_decode.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned char* slurp(const char* path, size_t* n) { FILE* f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long k = ftell(f); fseek(f, 0, SEEK_SET); unsigned char* b = (unsigned char*)malloc(k > 0 ? (size_t)k : 1);
    *n = fread(b, 1, (size_t)k, f); fclose(f); return b; }
int main(int argc, char** argv) {
#ifdef AX_VERIFY_NO_CHECK
    const int control = 1;
#else
    const int control = 0;
#endif
    static const char* bad[3][2] = {{"text_200K_p972", "text_200K"}, {"text_fast_200K_p102", "text_fast_200K"}, {"dna_4096B_p177", "dna_4096B"}};
    int refused = 0, silent_plain = 0, silent_flag = 0, miss = 0, fx = 0, fok = 0, badflag = 0; char p[4096];
    if (argc < 3) return 2;
    for (int i = 0; i < 3; i++) { size_t na = 0, nf = 0;
        snprintf(p, sizeof p, "%s/%s.aet", argv[1], bad[i][0]); unsigned char* a = slurp(p, &na);
        snprintf(p, sizeof p, "%s/%s.aet", argv[2], bad[i][1]); unsigned char* f = slurp(p, &nf);
        if (!a || !f || na < 36 || nf < 36) { miss++; free(a); free(f); continue; }
        uint64_t n; memcpy(&n, f + 12, 8); unsigned char* o = (unsigned char*)malloc(n + 64); unsigned char* d = (unsigned char*)malloc(n + 64);
        if (aceapex_decompress(f, nf, o, n) != (int64_t)n) miss++;
        else { int64_t r0 = aceapex_decompress_ex(a, na, d, n, 0, 0); if (r0 == (int64_t)n && memcmp(d, o, n)) silent_plain++;
               int64_t r1 = aceapex_decompress_ex(a, na, d, n, 0, ACEAPEX_VERIFY_XXH3);
               if (r1 == ACEAPEX_ERR_DATA) refused++; else if (r1 == (int64_t)n && memcmp(d, o, n)) silent_flag++; }
        free(a); free(f); free(o); free(d); }
    DIR* dd = opendir(argv[2]); struct dirent* e;
    while (dd && (e = readdir(dd))) { size_t L = strlen(e->d_name), na = 0; if (L < 5 || strcmp(e->d_name + L - 4, ".aet") || !strcmp(e->d_name, "dna_depth_legacy.aet")) continue;
        snprintf(p, sizeof p, "%s/%s", argv[2], e->d_name); unsigned char* a = slurp(p, &na); if (!a) continue; fx++;
        uint64_t n = 0; if (na >= 20) memcpy(&n, a + 12, 8); unsigned char* o = (unsigned char*)malloc(n + 64); unsigned char* d = (unsigned char*)malloc(n + 64);
        if (aceapex_decompress(a, na, o, n) == (int64_t)n && aceapex_decompress_ex(a, na, d, n, 0, ACEAPEX_VERIFY_XXH3) == (int64_t)n && !memcmp(o, d, n)) fok++;
        else printf("api_verify_c99\tfixture failed: %s\n", e->d_name);
        if (aceapex_decompress_ex(a, na, d, n, 0, 2u) == ACEAPEX_ERR_BUFFER) badflag++;
        free(a); free(o); free(d); }
    if (dd) closedir(dd);
    const int pass = miss == 0 && silent_plain == 3 && fx > 0 && fok == fx && badflag == fx && (control ? silent_flag == 3 : refused == 3);
    printf("api_verify_c99\t%s\t%s\twith the flag: %d of 3 refused, %d of 3 wrong bytes with success; without: %d of 3 wrong with success; fixtures verified %d of %d, unknown flag refused %d of %d\n",
           control ? "control" : "check", pass ? "pass" : "fail", refused, silent_flag, silent_plain, fok, fx, badflag, fx);
    return pass ? 0 : 1;
}
