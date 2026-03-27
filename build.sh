#!/bin/bash
sudo apt-get install -y libzstd-dev
g++ -O3 -march=native -funroll-loops -std=c++17 \
    -o aceapex src/aceapex_main.cpp -lpthread -lzstd
echo "Build OK: $(ls -lh aceapex)"
