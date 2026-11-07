/* the aligned_alloc interposer of TurboBench v2026.11.06.164 turbobench.c lines 314-319, reduced */
#define _GNU_SOURCE
#include <stdlib.h>
#include <stdio.h>
#include <dlfcn.h>
static void *(*mem_aligned_alloc)(size_t, size_t);
static size_t mem_used, mem_peak;
static void mem_add(size_t n) { if ((mem_used += n) > mem_peak) mem_peak = mem_used; }
#include <malloc.h>
static __attribute__((constructor)) void mem_init(void) { mem_aligned_alloc = dlsym(RTLD_NEXT, "aligned_alloc"); }
void *aligned_alloc(size_t alignment, size_t size) {
  if(!mem_aligned_alloc) { fprintf(stderr, "aligned_alloc\n"); exit(1); }
  void *p = (*mem_aligned_alloc)(alignment, size);
  if(p) mem_add(malloc_usable_size(p));
  return p;
}
int main(void) {
  void* small = malloc(1 << 20); printf("malloc 1 MiB: %s\n", small ? "ok" : "null"); fflush(stdout);
  void* big = aligned_alloc((size_t)2 << 20, (size_t)256 << 20);   /* what aceapex's ax_big_malloc does for >= 64 MiB */
  printf("aligned_alloc 256 MiB: %p\n", big);
  return 0;
}
