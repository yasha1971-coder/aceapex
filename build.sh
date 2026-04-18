#!/bin/bash
ZSTD_DIR=${ZSTD_DIR:-./zstd_src}

if [ ! -d "$ZSTD_DIR/lib" ]; then
    echo "Cloning zstd..."
    git clone --depth=1 https://github.com/facebook/zstd "$ZSTD_DIR"
fi

g++ -O3 -march=native -funroll-loops -std=c++17 \
    -I${ZSTD_DIR}/lib -I${ZSTD_DIR}/lib/common \
    -o aceapex src/aceapex_main.cpp \
    $(find $ZSTD_DIR/lib -name "*.c" | grep -v "zstd_compress_superblock\|zbuff\|legacy") \
    -lpthread -lxxhash

echo "Build OK: $(ls -lh aceapex 2>/dev/null || echo 'FAILED')"
