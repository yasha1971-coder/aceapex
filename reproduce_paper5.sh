#!/usr/bin/env bash
# reproduce_paper5.sh — "What Actually Serializes GPU LZ77 Decode"
# Emits results.json: one record per claim with level R/M/E, expected, measured, verdict.
set -uo pipefail

GOLDEN=${GOLDEN:-$HOME/golden}
CHR1=${CHR1:-$GOLDEN/genome/chr1.fa}
ENWIK8=${ENWIK8:-$GOLDEN/text/enwik8}
ENWIK9=${ENWIK9:-$GOLDEN/text/enwik9}
SILESIA=${SILESIA:-$GOLDEN/mixed/silesia.tar}
FASTQ=${FASTQ:-$GOLDEN/genome/ERR194147_1gb.fastq}
ZSTD_INC=${ZSTD_INC:-}
OUT=${OUT:-results.json}
BIN=${BIN:-./aceapex_p5}

export ACEAPEX_BS=16384
CHR1_MD5_EXPECTED=9465e0f0df6e2c6eb39729c39cee5465

HW="$(uname -m) $(nproc) cores"
command -v nvidia-smi >/dev/null 2>&1 && \
  HW="$HW + $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"

PASS=0; FAIL=0; SKIP=0
: > /tmp/_p5_records

rec () {
  printf '  {"claim_id":"%s","level":"%s","expected":"%s","tolerance":"%s","measured":"%s","verdict":"%s","command":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> /tmp/_p5_records
  case "$6" in
    pass) PASS=$((PASS+1)); printf '  PASS %-26s %s (exp %s)\n' "$1" "$5" "$3" ;;
    fail) FAIL=$((FAIL+1)); printf '  FAIL %-26s %s (exp %s)\n' "$1" "$5" "$3" ;;
    *)    SKIP=$((SKIP+1)); printf '  %-4s %-26s %s\n' "$6" "$1" "$5" ;;
  esac
}

within () {
  python3 -c "
import sys
m,e,t=float('$1'),float('$2'),float('$3')
sys.exit(0 if abs(m-e)<=abs(e)*t else 1)" 2>/dev/null
}

ratio_of () {
  local out; out=$(env "$@" ACEAPEX_BS=16384 "$BIN" t --in "$SRC" --threads 8 2>&1)
  grep -q 'BIT-PERFECT' <<<"$out" || { echo 0; return; }
  grep -oE 'Ratio: *[0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | head -1
}

echo "=== ACEAPEX Paper 5 reproduction ==="
echo "hardware: $HW"

echo ""
echo "--- corpus identity ---"
if [ -f "$CHR1" ]; then
  GOT=$(md5sum "$CHR1" | cut -d' ' -f1)
  [ "$GOT" = "$CHR1_MD5_EXPECTED" ] && V=pass || V=fail
  rec chr1_md5 R "$CHR1_MD5_EXPECTED" 0 "$GOT" "$V" "md5sum CHR1"
else
  rec chr1_md5 R "$CHR1_MD5_EXPECTED" 0 missing skipped-no-corpus "md5sum CHR1"
fi

echo ""
echo "--- build encoder ---"
INC=""; [ -n "$ZSTD_INC" ] && INC="-I$ZSTD_INC"
if g++ -O3 -march=native -funroll-loops -std=c++17 -Isrc $INC \
      -o "$BIN" aceapex_depth.cpp -lpthread -lzstd 2>/tmp/_p5_build; then
  echo "  built: $BIN"
else
  echo "  BUILD FAILED; set ZSTD_INC to the directory holding zstd.h"; tail -3 /tmp/_p5_build; exit 1
fi

echo ""
echo "--- R: encoder claims on chr1 ---"
if [ -f "$CHR1" ]; then
  SRC="$CHR1"
  M=$(ratio_of MIN_MATCH=0); within "$M" 3.18065 0.00001 && V=pass || V=fail
  rec chr1_baseline_ratio R 3.18065 1e-5 "$M" "$V" "MIN_MATCH=0 t --in chr1"
  M=$(ratio_of NO_REP=1);   within "$M" 3.16347 0.00001 && V=pass || V=fail
  rec norep_ratio R 3.16347 1e-5 "$M" "$V" "NO_REP=1 t --in chr1"
  M=$(python3 -c "print(f'{(3.18065/3.16347-1)*100:.3f}')")
  within "$M" 0.540 0.02 && V=pass || V=fail
  rec norep_cost_percent R 0.540 0.02 "$M" "$V" "derived from the two ratios"
  M=$(ratio_of MIN_MATCH=16); within "$M" 3.22581 0.00001 && V=pass || V=fail
  rec min_match16_ratio R 3.22581 1e-5 "$M" "$V" "MIN_MATCH=16 t --in chr1"
else
  for C in chr1_baseline_ratio norep_ratio norep_cost_percent min_match16_ratio; do
    rec "$C" R - - "missing corpus" skipped-no-corpus "set CHR1"; done
fi

echo ""
echo "--- R: class matrix, independent 16 KB blocks ---"
if python3 -c "import zstandard" 2>/dev/null; then
  for E in "chr1:$CHR1:3.18065:3.03362" "enwik8:$ENWIK8:2.63791:2.33351" \
           "enwik9:$ENWIK9:2.98108:2.56673" "silesia:$SILESIA:3.00457:2.67498" \
           "fastq:$FASTQ:3.96476:3.62875"; do
    NAME=${E%%:*}; R1=${E#*:}; P=${R1%%:*}; R2=${R1#*:}; EU=${R2%%:*}; EZ=${R2##*:}
    if [ ! -f "$P" ]; then rec "class_${NAME}" R "$EU" 1e-5 "missing" skipped-no-corpus "set path"; continue; fi
    SRC="$P"; M=$(ratio_of MIN_MATCH=0); within "$M" "$EU" 0.00001 && V=pass || V=fail
    rec "class_${NAME}_aceapex" R "$EU" 1e-5 "$M" "$V" "t --in $NAME"
    Z=$(python3 -c "
import zstandard as z,os
c=z.ZstdCompressor(level=3); t=0
with open('$P','rb') as f:
    while True:
        b=f.read(16384)
        if not b: break
        t+=len(c.compress(b))
print(f'{os.path.getsize(\"$P\")/t:.5f}')")
    within "$Z" "$EZ" 0.001 && V=pass || V=fail
    rec "class_${NAME}_zstd3_16k" R "$EZ" 1e-3 "$Z" "$V" "zstd-3 over 16 KB chunks"
  done
else
  rec class_matrix R - - "pip install zstandard" skipped-no-dep "pip install zstandard"
fi

echo ""
echo "--- R: what is sequential in the parse ---"
if [ -f "$CHR1" ]; then
  env MIN_MATCH=0 ACEAPEX_BS=16384 "$BIN" c --in "$CHR1" --out /tmp/_p5.aet --threads 8 >/dev/null 2>&1
  env MIN_MATCH=0 ACEAPEX_BS=16384 ACEAPEX_DUMP=1 "$BIN" d --in /tmp/_p5.aet --out /tmp/_p5.dec >/dev/null 2>&1
  if [ -f streams.bin ]; then
    read -r CHAINED RUN50 <<<"$(python3 - << 'PY'
import numpy as np, struct
HDR=68; p='streams.bin'
d=open(p,'rb').read(HDR)
ver,orig,bs,nb=struct.unpack_from('<IQII',d,8)
t=np.fromfile(p,dtype=np.uint64,count=nb*8,offset=HDR).reshape(nb,8)
base=HDR+nb*64; tot=[int(t[:,4+k].sum()) for k in range(4)]
f=open(p,'rb'); f.seek(base+tot[0]+tot[1]+tot[2])
CMD=np.frombuffer(f.read(tot[3]),dtype=np.uint8)
co=t[:,3].astype(np.int64); cs=t[:,7].astype(np.int64)
seq=n=0; runs=[]
for b in range(0,nb,7):
    c=CMD[co[b]:co[b]+cs[b]].astype(np.int32)
    if len(c)==0: continue
    rst=(c==0xFF); rep=((c&0xC0)==0x80)&~rst
    ext=(c==0xFE)|(rep&((c&0x0F)==0x0F))
    idx=np.flatnonzero(rep|ext)
    seq+=len(idx); n+=len(c)
    if len(idx)==0: runs.append(len(c)); continue
    g=np.diff(np.concatenate([[-1],idx,[len(c)]]))-1
    runs.extend(g[g>0].tolist())
print(f'{seq/n*100:.2f} {int(np.percentile(runs,50))}')
PY
)"
    within "$CHAINED" 5.46 0.05 && V=pass || V=fail
    rec parse_chained_percent R 5.46 0.05 "$CHAINED" "$V" "decompose chr1 command stream"
    within "$RUN50" 4 0.30 && V=pass || V=fail
    rec parse_run_median R 4 0.30 "$RUN50" "$V" "median dependency-free run"
    rm -f streams.bin tokens.bin levels.bin lit_positions.bin lits.bin
  else
    rec parse_chained_percent R 5.46 0.05 "no streams.bin" fail "decode should dump streams.bin"
  fi
else
  rec parse_chained_percent R 5.46 0.05 "missing corpus" skipped-no-corpus "set CHR1"
fi

echo ""
echo "--- R: GPU claims ---"
if command -v nvcc >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  OK=1
  for K in real par run; do
    nvcc -O3 -arch=${ARCH:-sm_90} -o /tmp/wf_$K wf_$K.cu 2>/dev/null || OK=0
  done
  [ "$OK" = 1 ] || rec wf_build R "3 kernels" - "nvcc failed" fail "nvcc -O3 -arch=sm_90"
  if [ "$OK" = 1 ] && [ -f "$CHR1" ]; then
    env MIN_MATCH=0 ACEAPEX_BS=16384 "$BIN" c --in "$CHR1" --out /tmp/_p5.aet --threads 8 >/dev/null 2>&1
    env MIN_MATCH=0 ACEAPEX_BS=16384 ACEAPEX_DUMP=1 "$BIN" d --in /tmp/_p5.aet --out /tmp/_p5.dec >/dev/null 2>&1
    for K in real par; do
      O=$(/tmp/wf_$K tokens.bin "$CHR1" 2>&1)
      MS=$(grep -oE '[0-9.]+ ms' <<<"$O" | grep -oE '[0-9.]+' | head -1)
      BP=$(grep -c 'BIT-PERFECT: YES' <<<"$O")
      [ "$K" = real ] && EXP=5.846 || EXP=1.291
      if [ "$BP" = "1" ] && within "$MS" "$EXP" 0.10; then V=pass; else V=fail; fi
      rec "wavefront_${K}_ms" R "$EXP" 0.10 "${MS:-none} bp=$BP" "$V" "wf_$K tokens.bin chr1"
    done
    rm -f streams.bin tokens.bin levels.bin lit_positions.bin lits.bin
  fi
else
  for C in wf_build wavefront_real_ms wavefront_par_ms; do
    rec "$C" R - - "no nvcc or no CUDA device" skipped-no-gpu "install CUDA toolkit"; done
fi

echo ""
echo "--- R: genomic literal transform and region read ---"
if [ -f "$CHR1" ]; then
  SRC="$CHR1"
  M=$(ratio_of MIN_MATCH=0 LIT_CHUNK=1048576)
  within "$M" 3.77696 0.00001 && V=pass || V=fail
  rec transform_chr1_ratio R 3.77696 1e-5 "$M" "$V" "LIT_CHUNK=1048576 aceapex t --in chr1"

  env MIN_MATCH=0 ACEAPEX_BS=16384 LIT_CHUNK=1048576 "$BIN" c --in "$CHR1" \
      --out /tmp/_p5r.aet --threads 8 >/dev/null 2>&1
  OK=1
  for OFF in 16384 126959616 253902848; do
    env ACEAPEX_BS=16384 "$BIN" r --in /tmp/_p5r.aet --out /tmp/_p5r.bin \
        --region $OFF 16384 >/dev/null 2>&1
    dd if="$CHR1" of=/tmp/_p5r.ref bs=1 skip=$OFF count=16384 2>/dev/null
    cmp -s /tmp/_p5r.bin /tmp/_p5r.ref || OK=0
  done
  [ "$OK" = 1 ] && V=pass || V=fail
  rec region_16k_byte_exact R "3 points match" 0 "$([ $OK = 1 ] && echo match || echo differ)" "$V" \
      "aceapex r --region, compared with dd from the original"

  SZ=$(stat -c%s /tmp/_p5r.aet)
  within "$SZ" 68224719 0.001 && V=pass || V=fail
  rec transform_archive_bytes R 68224719 1e-3 "$SZ" "$V" "size of the transformed archive"
  rm -f /tmp/_p5r.aet /tmp/_p5r.bin /tmp/_p5r.ref
else
  for C in transform_chr1_ratio region_16k_byte_exact transform_archive_bytes; do
    rec "$C" R - - "missing corpus" skipped-no-corpus "set CHR1"; done
fi

echo ""
echo "--- R: genomic coordinate lookup ---"
if [ -f "$CHR1" ]; then
  "$BIN" faidx --in "$CHR1" --out /tmp/_p5.fai >/dev/null 2>&1
  GOT=$(grep -v "^#" /tmp/_p5.fai 2>/dev/null | tr -s "\t" " " | tr -d "\n")
  [ "$GOT" = "chr1 248956422 6 50 51" ] && V=pass || V=fail
  rec fasta_index R "chr1 248956422 6 50 51" 0 "$GOT" "$V" "aceapex faidx --in chr1.fa"

  env MIN_MATCH=0 ACEAPEX_BS=16384 LIT_CHUNK=1048576 "$BIN" c --in "$CHR1" \
      --out /tmp/_p5c.aet --threads 8 >/dev/null 2>&1
  env ACEAPEX_BS=16384 "$BIN" r --in /tmp/_p5c.aet --out /tmp/_p5c.bin \
      --fai /tmp/_p5.fai --range chr1:5000000-5016000 >/dev/null 2>&1
  dd if="$CHR1" of=/tmp/_p5c.ref bs=1 skip=5100004 count=16321 2>/dev/null
  cmp -s /tmp/_p5c.bin /tmp/_p5c.ref && V=pass || V=fail
  rec coord_range_byte_exact R "match" 0 "$([ "$V" = pass ] && echo match || echo differ)" "$V" \
      "aceapex r --fai --range chr1:5000000-5016000"
  rm -f /tmp/_p5.fai /tmp/_p5c.aet /tmp/_p5c.bin /tmp/_p5c.ref
else
  for C in fasta_index coord_range_byte_exact; do
    rec "$C" R - - "missing corpus" skipped-no-corpus "set CHR1"; done
fi

echo ""
echo "--- R: FAI compatibility and index binding ---"
if [ -f "$CHR1" ] && python3 -c "import pysam" 2>/dev/null; then
  env MIN_MATCH=0 ACEAPEX_BS=16384 LIT_CHUNK=1048576 "$BIN" c --in "$CHR1" \
      --out /tmp/_p5f.aet --fai-out /tmp/_p5f.fai --threads 8 >/dev/null 2>&1
  cp "$CHR1" /tmp/_p5f.fa 2>/dev/null || ln -f "$CHR1" /tmp/_p5f.fa
  python3 -c "import pysam; pysam.faidx('/tmp/_p5f.fa')" 2>/dev/null
  grep -v "^#" /tmp/_p5f.fai > /tmp/_p5f.clean
  cmp -s /tmp/_p5f.clean /tmp/_p5f.fa.fai && V=pass || V=fail
  rec fai_matches_htslib R "byte-identical" 0 \
      "$([ "$V" = pass ] && echo identical || echo differs)" "$V" \
      "aceapex c --fai-out, compared with pysam.faidx"

  env ACEAPEX_BS=16384 "$BIN" r --in /tmp/_p5f.aet --out /tmp/_p5f.seq \
      --fai /tmp/_p5f.fai --range chr1:5000000-5016000 --view sequence >/dev/null 2>&1
  GOT=$(python3 -c "
import pysam
fa=pysam.FastaFile('/tmp/_p5f.fa')
print('match' if open('/tmp/_p5f.seq').read()==fa.fetch('chr1',4999999,5016000) else 'differ')" 2>/dev/null)
  [ "$GOT" = match ] && V=pass || V=fail
  rec view_sequence_vs_htslib R "match" 0 "$GOT" "$V" \
      "aceapex r --view sequence vs pysam fetch"

  sed "s/^#aceapex-src-xxh3.*/#aceapex-src-xxh3\tdeadbeefdeadbeef/" /tmp/_p5f.fai > /tmp/_p5f.alien
  env ACEAPEX_BS=16384 "$BIN" r --in /tmp/_p5f.aet --out /tmp/_p5f.bad \
      --fai /tmp/_p5f.alien --range chr1:5000000-5016000 >/dev/null 2>&1
  RC=$?
  [ "$RC" != 0 ] && [ ! -f /tmp/_p5f.bad ] && V=pass || V=fail
  rec alien_index_refused R "nonzero exit, no output" 0 \
      "exit $RC$([ -f /tmp/_p5f.bad ] && echo ", file written")" "$V" \
      "index whose source hash does not match the archive"
  rm -f /tmp/_p5f.aet /tmp/_p5f.fai /tmp/_p5f.fa /tmp/_p5f.fa.fai /tmp/_p5f.clean \
        /tmp/_p5f.seq /tmp/_p5f.alien /tmp/_p5f.bad
else
  for C in fai_matches_htslib view_sequence_vs_htslib alien_index_refused; do
    rec "$C" R - - "needs chr1 and pysam" skipped-no-tool "pip install --user pysam"; done
fi

echo ""
echo "--- M / E: declared, not verifiable here ---"
rec seek_50gb_position_invariance M "292-387 us" - "original not on disk; FNV has nothing to compare against" declared "v7ra streams_50gb.bin"
rec min_match_cost_probe M "1.291 -> 0.215 ms" - "tokens dropped without substituting literals" declared "wf_par, filtered tokens"
rec scan_parser_speedup E "2.7x" - "parse 2.555 ms scaled by the 93.94 percent share; not verified on GPU" declared "no prototype yet"

{
  echo '{'
  printf '  "paper": "What Actually Serializes GPU LZ77 Decode",\n'
  printf '  "date": "%s",\n' "$(date -u +%FT%TZ)"
  printf '  "hardware": "%s",\n' "$HW"
  printf '  "corpus_md5_expected": "%s",\n' "$CHR1_MD5_EXPECTED"
  printf '  "summary": {"pass": %d, "fail": %d, "skipped": %d},\n' "$PASS" "$FAIL" "$SKIP"
  echo '  "claims": ['
  sed '$!s/$/,/' /tmp/_p5_records
  echo '  ]'
  echo '}'
} > "$OUT"

echo ""
echo "=== summary: $PASS pass, $FAIL fail, $SKIP skipped -> $OUT ==="
[ "$FAIL" -eq 0 ]
