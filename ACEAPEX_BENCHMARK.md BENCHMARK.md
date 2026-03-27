ACEAPEX v2 — Benchmark Results
Hardware

CPU: AMD EPYC 4344P 8-Core Processor
RAM: 128 GB
OS: Ubuntu 22.04 LTS
libzstd: 1.4.8
Compiler: g++ 11.4, flags: -O3 -march=native -funroll-loops -std=c++17

Dataset

enwik9: Wikipedia XML text, 1,000,000,000 bytes
Source: http://mattmahoney.net/dc/enwik9.zip
SHA-256: 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc
xml: Silesia corpus, 5,345,280 bytes
x-ray: Silesia corpus, 8,474,240 bytes (medical image data)
mozilla: Silesia corpus, 51,220,480 bytes

Methodology

Each test run performs: encode + decode + SHA-256 verify
Reported encode time: LZ77 phase only (excludes zstd entropy coding)
Reported decode time: full reconstruct (zstd decompress + LZ77 decode)
All SHA-256 verification passed (BIT-PERFECT) on every run
Competitor codecs measured via system time command
No memory limits imposed

ACEAPEX v2 — Encode Scaling (enwik9, 1GB)
ThreadsRatioEncode MB/sDecode MB/sStatus13.747x15310032BIT-PERFECT23.747x29210601BIT-PERFECT43.747x52410435BIT-PERFECT83.747x80310460BIT-PERFECT
ACEAPEX v2 — Full Corpus (8 threads)
FileSizeRatioEncode MB/sDecode MB/sStatusenwik91000 MB3.747x80310460BIT-PERFECTxml5.35 MB7.732x5244488BIT-PERFECTx-ray8.47 MB1.645x2706195BIT-PERFECTmozilla51.22 MB3.146x6328985BIT-PERFECT
Head-to-Head (enwik9, 1GB, 8 threads)
Encode
CodecCommandTimeEncode MB/sOutput sizeLZ4 -9lz4 -9 enwik9 out.lz418.2s55 MB/s358 MBzstd -1zstd -1 -T8 enwik90.50s1996 MB/s341 MBzstd -3zstd -3 -T8 enwik90.62s1613 MB/s300 MBzstd -9zstd -9 -T8 enwik94.09s245 MB/s266 MBzstd -19zstd -19 -T8 enwik974.8s13 MB/s225 MBACEAPEX v2aceapex t --in enwik9 --threads 81.25s803 MB/s267 MB
Decode
CodecCommandTimeDecode MB/sLZ4 -9lz4 -d out.lz4 /dev/null0.37s2703 MB/szstd -1zstd -d out.zst -o /dev/null0.65s1534 MB/szstd -3zstd -d out.zst -o /dev/null0.73s1379 MB/szstd -9zstd -d out.zst -o /dev/null0.70s1429 MB/szstd -19zstd -d out.zst -o /dev/null0.70s1420 MB/sACEAPEX v2(included in test run)0.096s10460 MB/s
Summary
CodecRatioEncode MB/sDecode MB/sLZ4 -92.794x552703zstd -12.797x19961534zstd -33.187x16131379zstd -93.759x2451429zstd -194.245x131420ACEAPEX v23.747x80310460
Reproduce
bash# Build
sudo apt-get install -y libzstd-dev g++
bash build.sh

# Run benchmark
./aceapex t --in /path/to/enwik9 --threads 8

# Verify SHA-256
sha256sum /path/to/enwik9
# expected: 159b85351e5f76e60cbe32e04c677847a9ecba3adc79addab6f4c6c7aa3744bc

# Compare with zstd
sudo apt-get install -y zstd
time zstd -9 -T8 /path/to/enwik9 -o /tmp/test.zst -f
time zstd -d /tmp/test.zst -o /dev/null -f
Notes

ACEAPEX decode time includes full SHA-256 verification of output
zstd decode times do not include verification
Competitor encode times measured via time (wall clock)
ACEAPEX encode time measured internally (LZ77 phase only, not including zstd entropy coding time)
All results on warm filesystem cache