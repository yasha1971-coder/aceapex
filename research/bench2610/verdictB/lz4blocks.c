// lz4blocks <in.seq> <out.lz4blocks> <out.index.json> <contig_map.json> <block bytes> - independent LZ4 blocks
// (LZ4_compress_default, lz4 1.10.0) of a canonical sequence stream, concatenated; index JSON for the hw-apex
// IndexedLz4Reader: {"contigs": <from the contig map>, "frames": [{uoff, coff, ulen, clen}...]}. One block = one
// independent decode granule; the last block is the tail. No LZ4 frame format (no headers), nothing else in the file.
#include "lz4.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char** argv) {
  if (argc < 6) return 1;
  FILE* in = fopen(argv[1], "rb"); FILE* out = fopen(argv[2], "wb"); FILE* ix = fopen(argv[3], "w"); FILE* mp = fopen(argv[4], "r");
  const int B = atoi(argv[5]); if (!in || !out || !ix || !mp || B <= 0) return 2;
  char* src = malloc(B); char* dst = malloc(LZ4_compressBound(B));
  // contigs: copy the "contigs" array text of the map verbatim
  fseek(mp, 0, SEEK_END); long ml = ftell(mp); fseek(mp, 0, SEEK_SET); char* m = malloc(ml + 1); fread(m, 1, ml, mp); m[ml] = 0;
  char* c0 = strstr(m, "\"contigs\":"); char* c1 = strstr(c0, "]"); if (!c0 || !c1) return 3;
  fprintf(ix, "{\"lz4_version\": \"%s\", \"block_bytes\": %d, %.*s], \"frames\": [", LZ4_versionString(), B, (int)(c1 - c0), c0);
  unsigned long long uoff = 0, coff = 0; int n; int first = 1;
  while ((n = (int)fread(src, 1, B, in)) > 0) {
    int c = LZ4_compress_default(src, dst, n, LZ4_compressBound(B)); if (c <= 0) return 4;
    fwrite(dst, 1, c, out);
    fprintf(ix, "%s\n {\"uoff\": %llu, \"coff\": %llu, \"ulen\": %d, \"clen\": %d}", first ? "" : ",", uoff, coff, n, c); first = 0;
    uoff += n; coff += c;
  }
  fprintf(ix, "\n], \"uncompressed_bytes\": %llu, \"compressed_bytes\": %llu}\n", uoff, coff);
  fclose(in); fclose(out); fclose(ix); printf("%s: %llu -> %llu bytes\n", argv[2], uoff, coff); return 0;
}
