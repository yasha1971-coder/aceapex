#!/bin/bash -eu
# ClusterFuzzLite build (FREEZE-4): zstd 1.5.6 from source with the sanitizer flags (static), the C API, fuzz/fuzz_api.cpp
# linked with libFuzzer, and a seed corpus from fuzz/make_seeds.cpp. 2.6.4: fuzz_c99 - the C99 decoder (c/, = python/csrc)
# through fuzz/fuzz_c99.c; its seeds are the raw-path seeds without the selector byte plus verify/repro/c99_alloc.
make -C "$SRC/zstd/lib" -j"$(nproc)" libzstd.a CC="$CC" CFLAGS="$CFLAGS" ZSTD_LEGACY_SUPPORT=0 > /dev/null
$CXX $CXXFLAGS -std=c++17 -I"$SRC/zstd/lib" -Isrc -c src/aceapex_api.cpp -o aceapex_api.o
$CXX $CXXFLAGS -std=c++17 -Isrc fuzz/fuzz_api.cpp aceapex_api.o $LIB_FUZZING_ENGINE "$SRC/zstd/lib/libzstd.a" -lpthread -o "$OUT/fuzz_api"
$CXX $CXXFLAGS -std=c++17 -Isrc fuzz/make_seeds.cpp aceapex_api.o "$SRC/zstd/lib/libzstd.a" -lpthread -o make_seeds
mkdir -p seeds && ./make_seeds seeds && (cd seeds && zip -q "$OUT/fuzz_api_seed_corpus.zip" ./*)
printf '[libfuzzer]\nmax_len = 300000\nrss_limit_mb = 2560\n' > "$OUT/fuzz_api.options"
$CC $CFLAGS -std=c99 -I"$SRC/zstd/lib" -Ic -c c/aceapex_decode.c -o aceapex_decode.o
$CC $CFLAGS -std=c99 -Ic -c fuzz/fuzz_c99.c -o fuzz_c99.o
$CXX $CXXFLAGS fuzz_c99.o aceapex_decode.o $LIB_FUZZING_ENGINE "$SRC/zstd/lib/libzstd.a" -lm -o "$OUT/fuzz_c99"
mkdir -p seeds_c99 && for f in seeds/raw*; do tail -c +2 "$f" > "seeds_c99/${f##*/}"; done && cp verify/repro/c99_alloc/*.aet seeds_c99/
(cd seeds_c99 && zip -q "$OUT/fuzz_c99_seed_corpus.zip" ./*)
printf '[libfuzzer]\nmax_len = 300000\nrss_limit_mb = 2560\nmalloc_limit_mb = 128\n' > "$OUT/fuzz_c99.options"
