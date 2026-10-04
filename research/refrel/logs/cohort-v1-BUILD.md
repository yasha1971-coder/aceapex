# refrel3 v1 archives of the cohort - how the bytes were made (cohort-v1-manifest-2026-10-04.tsv)

- Encoder: aceapex `research/refrel/refrel3v1.cpp` @ 5b6d5ce (`refrel3v1 recode`, 16 threads), ace-core AMD EPYC 4344P.
- Compiler: g++ (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0, `-std=c++17 -O3 -march=native -funroll-loops`.
- Reproduce the bytes with: `g++ -std=c++17 -O3 -march=x86-64-v3 -funroll-loops -Isrc -Iresearch/refrel
  research/refrel/refrel3v1.cpp src/aceapex_api.cpp -lzstd -lpthread` (gcc 11.4). Checked: y1_HG00438.1 q4k and
  y1_HG00621.1 q16k == the manifest's sha256; native / x86-64-v4 / haswell / skylake-avx512 / icelake-server /
  sapphirerapids / znver3 give the same bytes; threads 1 / 4 / 8 / 12 / 16 give the same bytes.
- FP contraction: the encoder's match scores are doubles (`refrel3.cpp` lines 35, 52: `L * LITB - cost`, compared
  with `>`). With FMA (x86-64-v3 and up, gcc's default `-ffp-contract=fast`) near ties fall one way, without it
  (`-march=x86-64-v2` or `-ffp-contract=off`) another: y1_HG00438.1 q4k 21 765 975 B (sha256 8c4a13f8...) instead of
  21 765 741 B (7a0b3cc9...), decoded == the FASTA as well. Other compilers / versions may give other bytes.
  The format and the decoders are not affected - any build's archive decodes; byte identity of archives needs the
  same compiler and flags.
