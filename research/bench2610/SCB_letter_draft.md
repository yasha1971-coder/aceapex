# Draft - not sent. Letter to Kirill Kryukov (Sequence Compression Benchmark), proposing ACEAPEX for inclusion

Subject: Sequence Compression Benchmark - request to add the ACEAPEX compressor (v2.2.2)

Dear Dr. Kryukov,

I would like to ask whether ACEAPEX could be added to the Sequence Compression Benchmark.

- Codec: ACEAPEX, a block LZ77 compressor with independently decodable blocks (random access to any byte range),
  CPU and GPU decoders reading the same archive. Format: `docs/FORMAT_ACEPX2.md`.
- Version: 2.2.2 (tag `v2.2.2`), DOI 10.5281/zenodo.23090998; licence MIT.
- Source: https://github.com/yasha1971-coder/aceapex
- Build (Linux, g++ >= 11, libzstd-dev):

      git clone https://github.com/yasha1971-coder/aceapex.git
      cd aceapex && git checkout v2.2.2 && make
      # produces ./aceapex

- Commands for your harness (one thread; levels 1 = fast, 2 = default, 3 = slowest / best on DNA):

      ./aceapex c --in <input> --out <input>.aet --level <1|2|3> --threads 1
      ./aceapex d --in <input>.aet --out <output> --threads 1

  The archive bytes do not depend on the thread count. The input is compressed as bytes (FASTA as is, headers and line
  ends included); the decoder restores it byte for byte and checks an XXH3 of the original stored in the header.
- Suggested settings: levels 1, 2, 3 at one thread; the multi-threaded setting `--threads 0` (all cores) if your
  benchmark has such a column.

[Measured numbers to be added from the M5 evidence (GRCh38 GCA_000001405.28): compression / decompression speed at one
thread, peak memory of compression and decompression - only after M5.]

Best regards,
Yakiv Shavidze
aceapex.contour@outlook.com
ORCID 0009-0008-3622-3448
