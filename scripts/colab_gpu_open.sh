#!/usr/bin/env bash
# Colab (or any CUDA host, any GPU: T4 sm_75, A100 sm_80, L4 sm_89, H100 sm_90, Blackwell sm_120):
# the open profile on the GPU (ADR-019) - a genome decoded without a zstd frame - against the zstd
# default and the rANS token profile. One Colab cell, the same on every GPU:
#   from google.colab import drive; drive.mount('/content/drive')
#   !rm -rf /content/aceapex && git clone -q -b main https://github.com/yasha1971-coder/aceapex /content/aceapex && bash /content/aceapex/scripts/colab_gpu_open.sh
# Corpora (read from Google Drive when mounted, folder $DRV = MyDrive/aceapex_corpus):
#   chr1.fa   hg38 chr1, md5 pinned; from Drive, else downloaded from UCSC (with a hint to keep it)
#   t2t.fa    CHM13 v2.0 whole genome (or t2t.fa.gz), md5 pinned; only if it is on Drive. Source: NCBI
#             GenBank GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz (932 696 125 B, md5 9280657210e4161147cbe13b022225b9;
#             UCSC hs1.fa.gz is the same sequence with other names, 50-column lines and 54.6 % soft-masked
#             against 40.3 % - a different file, not comparable). The CLI
#             encoder needs 11.2 GB RSS on it: encoded where the host has >= 20 GB RAM, and the
#             archives are cached in $DRV/cache (sizes pinned: bytes of the archive are the same
#             on every machine), so a later run on a small-RAM host takes them from there.
# Steps: provenance, libzstd + nvCOMP (pip nvidia-nvcomp-cu12; the open archive makes no nvCOMP
# call, the other two need it), CLI + aceapex_gpu build for the GPU's compute capability, both
# warp-step emulators, the open conformance fixtures on the GPU (compute-sanitizer on a failure),
# per corpus three archives with the T4 profile of 2026-09-28 (16 KiB blocks, 64 KiB literal chunks):
#   zstd   FSE_CHUNK=4096       tokens and literals in zstd frames (nvCOMP)
#   rans   AX_TOK=rans          tokens rANS (k_rans), literals zstd (ADR-018)
#   open   AX_PROFILE=open      tokens rANS, literals open DNA pack / open plain (ADR-019)
# CPU round-trip of each archive, aceapex_gpu on each, then per corpus two tables: stages, and the
# parts of lit (per piece class) and unpack (per kernel). Log: results/colab-<date>-<gpu>-gpu-open.log.
set -uo pipefail
cd "$(dirname "$0")/.."; D=$(date -u +%Y-%m-%d); mkdir -p results
GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
TAG=$(echo "$GPU" | tr 'A-Z' 'a-z' | sed 's/^nvidia //; s/^tesla //; s/[^a-z0-9]\+/-/g; s/^-//; s/-$//')
L=results/colab-$D-$TAG-gpu-open.log
W=${WORK:-/content/work}; mkdir -p $W
DRV=${DRV:-/content/drive/MyDrive/aceapex_corpus}; HAVE_DRIVE=0; [ -d "$(dirname "$DRV")" ] && HAVE_DRIVE=1
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
{ echo "== provenance $D"
  echo "gpu $GPU | cc $(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1) | driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)"
  echo "clocks max sm/mem $(nvidia-smi --query-gpu=clocks.max.sm,clocks.max.mem --format=csv,noheader | head -n 1) | memory $(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1) | power limit $(nvidia-smi --query-gpu=power.limit --format=csv,noheader | head -n 1)"
  echo "host $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //'), $(nproc) threads, RAM $RAM_GB GB, drive $HAVE_DRIVE"
  nvcc --version | tail -1; g++ --version | head -1; echo "commit $(git rev-parse --short HEAD)"; } 2>&1 | tee $L
[ -f /usr/include/zstd.h ] || { apt-get -qq update && apt-get -qq install -y libzstd-dev >/dev/null; }
grep -h '#define ZSTD_VERSION_\(MAJOR\|MINOR\|RELEASE\)' /usr/include/zstd.h | awk '{print $3}' | paste -sd. - | sed 's/^/libzstd /' | tee -a $L
pip -q install nvidia-nvcomp-cu12 2>&1 | grep -v 'requires\|incompatible' | tail -1
NV=$(dirname "$(dirname "$(find / -name libnvcomp.so.5 -path '*libnvcomp/lib64*' 2>/dev/null | head -n 1)")")
[ -f "$NV/include/nvcomp/zstd.h" ] || { echo "nvCOMP not found" | tee -a $L; exit 1; }
pip show nvidia-nvcomp-cu12 2>/dev/null | grep -i '^version' | sed 's/^/nvcomp /' | tee -a $L
export LD_LIBRARY_PATH=$NV/lib64:${LD_LIBRARY_PATH:-}
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d '.')
make -s 2>&1 | grep -i error; [ -x ./aceapex ] || { echo "no CLI" | tee -a $L; exit 1; }
NVL="-I$NV/include -L$NV/lib64 -l:libnvcomp.so.5"
if nvcc -O3 -arch=sm_$SM $NVL -o $W/aceapex_gpu aceapex_gpu.cu 2>$W/nvcc.err; then
  echo "built aceapex_gpu sm_$SM" | tee -a $L
elif nvcc -O3 -gencode arch=compute_90,code=compute_90 $NVL -o $W/aceapex_gpu aceapex_gpu.cu 2>>$W/nvcc.err; then
  echo "built aceapex_gpu compute_90 PTX, JIT to sm_$SM (this nvcc has no sm_$SM)" | tee -a $L
else echo "BUILD FAILED aceapex_gpu" | tee -a $L; cat $W/nvcc.err; exit 1; fi
for e in rans_warp_emu open_warp_emu; do
  g++ -std=c++17 -O2 -Isrc -o $W/$e scripts/$e.cpp && $W/$e verify/fixtures/conf/*.aet | tee -a $L; done

# the open conformance fixtures on the GPU (inputs regenerated from their seeds); 5 hashes each:
# warm-up, sequential, old pipeline, stream pipeline on cleared buffers, stream pipeline timed
python3 scripts/make_fixtures.py --regen >/dev/null
FX="dna_open_2MiB dna_open_mixed_300K dna_open_4097B dna_openlit_300K text_open_200K"; FXBAD=""
for f in $FX; do
  r=$($W/aceapex_gpu verify/fixtures/conf/$f.aet /tmp/conf_inputs/$f auto 3 1 --pipeline=3 2>&1); rc=$?
  echo "fixture $f on the GPU: exit $rc, $(echo "$r" | grep -c 'MATCHES OK') MATCHES OK, $(echo "$r" | grep -c 'DIFFERS X') DIFFERS" | tee -a $L
  [ $rc = 0 ] || { FXBAD="$FXBAD $f"; echo "$r" | grep -v '^probe' | tail -3 | sed 's/^/  /' | tee -a $L; }
done
CS=$(command -v compute-sanitizer || ls /usr/local/cuda/bin/compute-sanitizer 2>/dev/null)
for f in $FXBAD; do [ -n "$CS" ] || break
  echo "== compute-sanitizer $f" | tee -a $L
  $CS --tool memcheck --show-backtrace device $W/aceapex_gpu verify/fixtures/conf/$f.aet /tmp/conf_inputs/$f 16 1 1 2>&1 \
    | grep -v '^probe\|^\[' | grep -m 12 -i 'error\|kernel\|at 0x\|by thread\|in \|====' | tee -a $L
  break   # the first failing fixture is enough to name the kernel
done

# corpus: from Drive, else downloaded (chr1 only); md5 pinned
get_corpus(){ # name md5 url -> $W/name or empty
  local n=$1 m=$2 u=$3 c=$W/$1
  if [ ! -s $c ]; then
    if [ $HAVE_DRIVE = 1 ] && [ -s $DRV/$n ]; then cp $DRV/$n $c; echo "$n: from Drive" | tee -a $L
    elif [ $HAVE_DRIVE = 1 ] && [ -s $DRV/$n.gz ]; then gunzip -c $DRV/$n.gz > $c; echo "$n: from Drive ($n.gz)" | tee -a $L
    elif [ -n "$u" ]; then   # to a file first: a cut stream gave a truncated corpus (L4, 29.09)
      for try in 1 2 3; do curl -fsSL --retry 3 -o $c.gz $u && gzip -t $c.gz 2>/dev/null && break; rm -f $c.gz; done
      gunzip -c $c.gz > $c; rm -f $c.gz; echo "$n: downloaded" | tee -a $L
      [ $HAVE_DRIVE = 1 ] && echo "$m  $c" | md5sum -c - >/dev/null 2>&1 && mkdir -p $DRV && cp $c $DRV/$n && echo "$n: saved to Drive" | tee -a $L
    else echo "$n: not on Drive ($DRV/$n or $n.gz) - skipped" | tee -a $L; return 1; fi
  fi
  echo "$m  $c" | md5sum -c - >/dev/null 2>&1 && echo "$n: md5 $m OK" | tee -a $L || { echo "$n: MD5 MISMATCH" | tee -a $L; rm -f $c; return 1; }
}
# archive bytes; zstd frames depend on the libzstd version (t2t: 1.5.5 on Colab, 1.4.8 on ace-core),
# the open archive has none; chr1 at 16 KiB blocks came out the same under both
ZV=$(grep -h '#define ZSTD_VERSION_\(MAJOR\|MINOR\|RELEASE\)' /usr/include/zstd.h | awk '{print $3}' | paste -sd. -)
pinned(){ case $1.$2 in chr1.zstd) echo 69410925;; chr1.rans) echo 69106957;; chr1.open) echo 67975888;;
  t2t.zstd) [ "$ZV" = 1.4.8 ] && echo 902319887 || echo 901676480;;
  t2t.rans) [ "$ZV" = 1.4.8 ] && echo 898903131 || echo 898263414;; t2t.open) echo 887641942;; esac; }
T=$(nproc); CORP=""
get_corpus chr1.fa 9465e0f0df6e2c6eb39729c39cee5465 https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr1.fa.gz && CORP="chr1"
get_corpus t2t.fa cd1e52ce400c027ed0b7ab4b9d613f5a "" && CORP="$CORP t2t"
for X in $CORP; do
  C=$W/$X.fa
  for P in zstd rans open; do
    case $P in zstd) E="FSE_CHUNK=4096";; rans) E="AX_TOK=rans";; open) E="AX_PROFILE=open";; esac
    A=$W/$X.$P.aet; PIN=$(pinned $X $P); SRC=encoded
    if [ ! -s $A ] && [ $HAVE_DRIVE = 1 ] && [ "$(stat -c%s $DRV/cache/$X.$P.aet 2>/dev/null)" = "$PIN" ]; then cp $DRV/cache/$X.$P.aet $A; SRC="from Drive cache"; fi
    if [ ! -s $A ]; then
      if [ $X = t2t ] && [ $RAM_GB -lt 20 ]; then echo "$X.$P: RAM $RAM_GB GB < 20 GB for the encoder (11.2 GB RSS) and no cached archive - skipped; run once on a host with more RAM (A100/G4) to fill $DRV/cache" | tee -a $L; continue; fi
      env -i PATH=$PATH ACEAPEX_BS=16384 LIT_CHUNK=65536 $E ./aceapex c --in $C --out $A --threads $T >/dev/null 2>&1
      [ $HAVE_DRIVE = 1 ] && [ "$(stat -c%s $A)" = "$PIN" ] && mkdir -p $DRV/cache && cp $A $DRV/cache/ && SRC="encoded, cached on Drive"
    fi
    env -i PATH=$PATH ./aceapex d --in $A --out $W/rt.bin >/dev/null 2>&1
    S=$(stat -c%s $A); [ "$S" = "$PIN" ] && PS="== pinned" || PS="!= pinned $PIN"
    cmp -s $W/rt.bin $C && echo "$X.$P ($E): archive $S B ($PS), $SRC, CPU round-trip bit-perfect" | tee -a $L \
      || echo "$X.$P: CPU ROUND-TRIP FAILED" | tee -a $L
    rm -f $W/rt.bin
  done
  for P in zstd rans open; do [ -s $W/$X.$P.aet ] || continue
    R=${REPS:-3}
    echo "== aceapex_gpu $X.$P" | tee -a $L
    $W/aceapex_gpu $W/$X.$P.aet $C auto $R 4 --pipeline=${PIPE:-auto} 2>&1 | tee -a $L; echo "exit ${PIPESTATUS[0]} $X.$P" | tee -a $L
  done
done

# tables per corpus; TSV lines (gpu, corpus, row) for the table across GPUs
for X in $CORP; do
  grep -q "^ROW	$W/$X\." $L || continue
  echo; echo "$X on $GPU, ms, median of ${REPS:-3}; pipeline = chosen path (${PIPE:-auto}: stream pipeline when H2D >= on-device/2 and >= 2 batches of 64 MB, else sequential); batches 0 = sequential" | tee -a $L.t1
  { printf 'archive\tbytes\ttokens\tliterals\ttok\tlit\tunpack\tmatch\ton-device\t+H2D\tpipeline\tbatches\tGB/s\tcheck\tH2D-pageable\tH2D-pinned\n'
    grep "^ROW	$W/$X\." $L | awk -F'\t' -v OFS='\t' '{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$24,$27,$12,$13,$25" GB/s",$26" GB/s"}' | sed "s#$W/##"; } | column -t -s $'\t' | tee -a $L.t1
  echo "parts, ms: lit = zstd frames + pieces by class; unpack = zstd-pack kernels + open kernels" | tee -a $L.t1
  { printf 'archive\tlit.zstd\tseq\tcse\tgap\tval\tplain\tun.zstdpack\tbases\tcase\texceptions\n'
    grep "^ROW	$W/$X\." $L | awk -F'\t' -v OFS='\t' '{print $2,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23}' | sed "s#$W/##"; } | column -t -s $'\t' | tee -a $L.t1
done
[ -f $L.t1 ] && cat $L.t1 >> $L; rm -f $L.t1
grep '^ROW' $L | sed "s#$W/##" | awk -F'\t' -v OFS='\t' -v g="$TAG" '{$1="TSV\t" g; print}' | tee -a $L
# verdict: each archive run is valid on its own (the GPU output is hashed against the original);
# the run as a whole needs both emulators, the 5 fixtures, the chr1 open row, and no failure line
RUN=$(grep -c '^exit [0-9]* ' $L); OK=$(grep -c '^exit 0 ' $L); N=$(awk -F'\t' '$1=="ROW" && $13=="bit-perfect"' $L | wc -l)
E=$(grep -c $'^head_\(rans\|open\)_warp_emu\tpass' $L); F=$(grep -c '^fixture .*: exit 0, 5 MATCHES OK, 0 DIFFERS$' $L)
echo "archives on the GPU: bit-perfect $N of $RUN (exit 0: $OK); emulators $E/2, fixtures $F/5" | tee -a $L
grep '^exit [1-9]' $L | sed 's/^/  FAILED: /' | tee -a $L
[ "$N" = "$RUN" ] && [ "$E" = 2 ] && [ "$F" = 5 ] && grep -q "^ROW	$W/chr1.open" $L \
  && ! grep -q 'DIFFERS X\|archive rejected\|MISMATCH\|ROUND-TRIP FAILED' $L \
  && echo "RESULT: all passes bit-perfect on $GPU" | tee -a $L \
  || { echo "!!! NOT PASSED on $GPU - valid figures only in bit-perfect rows" | tee -a $L; exit 1; }
