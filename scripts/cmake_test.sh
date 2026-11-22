#!/usr/bin/env bash
# claim head_cmake (2.6.4): CMakeLists.txt configures, builds and installs the library (aceapex::aceapex, aceapex.h,
# lib/cmake/aceapex) and the CLI; a consumer project finds it with find_package(aceapex CONFIG REQUIRED) and round-trips
# 1 MiB through aceapex_compress / aceapex_decompress; the installed CLI round-trips the same bytes (c, d, sha256).
# v2.6.3's CMakeLists.txt does not link (the CLI from aceapex_main.cpp alone: undefined aceapex_decompress_mt, VCPKG_CHECK).
# Usage: scripts/cmake_test.sh [source dir]   Prints one judge line.
set -uo pipefail
S=$(cd "${1:-.}" && pwd); T=$(mktemp -d)
fail() { printf 'head_cmake\tfail\t%s\n' "$1"; rm -rf "$T"; exit 1; }
command -v cmake >/dev/null || { printf 'head_cmake\tdeclared\tcmake not installed on this host\n'; exit 0; }
cmake -S "$S" -B "$T/b" -DCMAKE_INSTALL_PREFIX="$T/inst" >"$T/cfg.log" 2>&1 || fail "configure: $(tail -c 200 "$T/cfg.log" | tr '\n\t' '  ')"
cmake --build "$T/b" -j"$(nproc)" >"$T/build.log" 2>&1 || fail "build: $(grep -m1 -E 'error' "$T/build.log" | head -c 200)"
cmake --install "$T/b" >"$T/inst.log" 2>&1 || fail "install: $(tail -c 200 "$T/inst.log" | tr '\n\t' '  ')"
mkdir -p "$T/c"
cat >"$T/c/CMakeLists.txt" <<'C'
cmake_minimum_required(VERSION 3.14)
project(consumer CXX)
find_package(aceapex CONFIG REQUIRED)
add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE aceapex::aceapex)
C
cat >"$T/c/main.cpp" <<'C'
#include <aceapex.h>
#include <cstdio>
#include <vector>
int main() { std::vector<unsigned char> in(1 << 20); for (size_t i = 0; i < in.size(); i++) in[i] = (unsigned char)("ACGT\n"[(i * 7 + i / 61) % 5]);
  std::vector<unsigned char> z(aceapex_compress_bound(in.size())), out(in.size());
  long long n = aceapex_compress(in.data(), in.size(), z.data(), z.size(), 2, 2);
  long long m = n > 0 ? aceapex_decompress(z.data(), (size_t)n, out.data(), out.size()) : -1;
  bool ok = m == (long long)in.size() && out == in; printf("%s %lld %s\n", ok ? "ok" : "FAIL", n, ACEAPEX_VERSION_STRING); return ok ? 0 : 1; }
C
cmake -S "$T/c" -B "$T/cb" -DCMAKE_PREFIX_PATH="$T/inst" >"$T/ccfg.log" 2>&1 || fail "consumer configure: $(grep -m1 -i error "$T/ccfg.log" | head -c 200)"
cmake --build "$T/cb" >"$T/cbuild.log" 2>&1 || fail "consumer build: $(grep -m1 -E 'error' "$T/cbuild.log" | head -c 200)"
co=$("$T/cb/consumer") || fail "consumer run: $co"
head -c 1048576 /dev/urandom | base64 >"$T/in.txt"
"$T/inst/bin/aceapex" c --in "$T/in.txt" --out "$T/in.aet" >/dev/null 2>&1 && "$T/inst/bin/aceapex" d --in "$T/in.aet" --out "$T/out.txt" >/dev/null 2>&1 \
  || fail "installed CLI round trip failed"
[ "$(sha256sum <"$T/in.txt")" = "$(sha256sum <"$T/out.txt")" ] || fail "installed CLI: sha256 differs"
printf 'head_cmake\tpass\tconfigure + build + install (lib/libaceapex.a, include/aceapex.h, lib/cmake/aceapex, bin/aceapex); consumer find_package(aceapex CONFIG) -> aceapex::aceapex: %s; installed CLI c/d round trip of %s B, sha256 equal\n' "$co" "$(stat -c%s "$T/in.txt")"
rm -rf "$T"
