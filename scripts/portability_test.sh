#!/usr/bin/env bash
# portability_test.sh - the library translation unit (src/aceapex_api.cpp, what lzbench and TurboBench compile) built
# with the compilers that broke inside lzbench's CI (#355): MinGW-w64 x86_64 and i686 (no pread), gcc 10 (no
# _mm256_cvtsi256_si32), 32-bit ARMv5 arm-linux-gnueabi (no lock-free 64-bit atomics: the object must not reference
# __atomic_*_8). Compilers that are not installed are reported as declared, not as failures.
# Output: claim_id <TAB> verdict <TAB> measured. ZSTD_INC: a zstd lib/ directory (zstd.h); default: zstd.h and
# zstd_errors.h copied from /usr/include.
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf $T' EXIT
# -I/usr/include would hand a cross compiler the host's Linux headers (asm/errno.h missing under MinGW): without
# ZSTD_INC the zstd headers alone are copied from /usr/include into a private directory.
if [ -n "${ZSTD_INC:-}" ]; then Z=$ZSTD_INC; else Z=$T/zinc; mkdir -p $Z; cp /usr/include/zstd.h /usr/include/zstd_errors.h $Z/ 2>/dev/null; fi
ok=0; n=0; bad=""; skip=""
for C in x86_64-w64-mingw32-g++-posix x86_64-w64-mingw32-g++ i686-w64-mingw32-g++-posix i686-w64-mingw32-g++ g++-10 arm-linux-gnueabi-g++; do
  command -v $C >/dev/null || { skip="$skip $C"; continue; }
  case $C in x86_64-w64-mingw32-g++) command -v x86_64-w64-mingw32-g++-posix >/dev/null && continue;; i686-w64-mingw32-g++) command -v i686-w64-mingw32-g++-posix >/dev/null && continue;; esac
  n=$((n+1))
  if $C -std=c++17 -O2 -I"$Z" -Isrc -c src/aceapex_api.cpp -o $T/o.o 2>$T/e.txt; then
    if [ "$C" = arm-linux-gnueabi-g++ ] && nm -u $T/o.o | grep -q '__atomic_.*_8'; then bad="$bad $C(__atomic_*_8)"; else ok=$((ok+1)); fi
  else bad="$bad $C($(grep -m1 'error' $T/e.txt | cut -c1-120))"; fi
done
if [ $n = 0 ]; then printf 'head_portability\tdeclared\tno cross compiler installed (skipped:%s)\n' "$skip"
elif [ $ok = $n ]; then printf 'head_portability\tpass\t%d/%d compilers build src/aceapex_api.cpp (MinGW-w64, gcc 10, armel without 64-bit atomics)%s\n' $ok $n "${skip:+; not installed:$skip}"
else printf 'head_portability\tfail\t%d/%d; failed:%s\n' $ok $n "$bad"; fi
