# AGC 3.2.4 vs refrel3 v1 on 558 - run record (PROTOCOL_AGC558, SHA-256 in PROTOCOL_AGC558.sha256)

## Environment

- Host ace-core: AMD EPYC 4344P 8-Core Processor, 16 threads, 125 GB RAM (115 GB available at the start), Ubuntu 22.04.5 LTS, kernel 5.15.0-163-generic.
- Compiler: g++ (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0.
- AGC: source tag v3.2.4, commit e67e3fc (`.wk/tools/agc-src`), its makefile: g++ -O3 -march=native -std=c++20
  -DREFRESH_USE_ZLIB -DARCH_X64; the same build for create, CLI and libagc.a (binary reports "v. 3.2.4 [build 20260722.1]").
- aceapex (refrel3, fifo_feed, benches): branch refrel, research/refrel sources == 5b6d5cec0f5962a561ac48822a1b5c48793a5b47;
  tools in research/agc_vs_refrel3 at the commit of this record.
- Protocol SHA-256: 676b4b713e7201d814115aaf7a173a2b41aafeeffd098d6611738bf082385266.

## 3a. Dress rehearsal (50 sets of t2t_50.agc) - PASS

`rehearsal.sh`: agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16, inputs = FIFOs <name>.fa fed by fifo_feed from the q16k
v1 archives (every check on), names and order of `agc listset t2t_50.agc`:
- archive SHA-256 af83a12d08a4ed29759977db7f0b2edf32986a9e3f85caec133f96c83254937a, 1 139 665 987 B == t2t_50.agc (byte for byte);
- wall 6:46.50, peak RSS 26 355 932 KB (`rehearsal_create50.time`); every pipe served in full (`rehearsal_feed50.log`);
- peak RSS N = 5: 26 465 808 KB, N = 50: 26 355 932 KB - flat in N (batch of 50). RAM 125 GB, 80 % = 100 GB; forecast for
  558 about 27 GB (assumption: flat as between 5 and 50) - below 80 %: create on 558 goes ahead.

## Section 2. create on 558 - done; integrity - PASS

`create558.sh`: one call `agc create -d -k 31 -l 20 -s 60000 -b 50 -t 16 -o agc558.agc <T2T> <558 FIFOs, manifest order>`:
- agc558.agc 3 721 635 360 B, SHA-256 9011701c446ba1395b5ce2bc56708a931aa9bfe4b7e010e920651e5b0dc14721; wall 1:17:21,
  peak RSS 34 741 376 KB (`create558.time`); 558 / 558 pipes served in full (`feed558.log`);
- T2T alone (same build and options): t2t_alone.agc 707 323 301 B, SHA-256 2759808c5f418d4c37deb94e1ec9895679636e20d61bb7cba11838ee0c90be8d;
  -> 3 014 312 059 B for the 558 assemblies, 5.40 MB per assembly.
- `integrity.sh` (`integrity.out`, `integrity558.tsv`): listset == t2t + 558; listctg == the FASTA's contigs in order
  558 / 558; getset -l 80 (year-1) / 60 (release 2) -> XXH3 == manifest fasta_xxh3 558 / 558 (every assembly comes back
  byte for byte as its source file).
