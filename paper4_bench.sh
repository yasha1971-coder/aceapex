#!/bin/bash
# ============================================================================
# paper4_bench.sh — ВСЕ прогоны для защиты статьи 4 в ОДНОМ заходе.
# Готовит baseline-таблицу + ablation развязки + охват трилогии.
# Пишет в /tmp/paper4_results.txt — компактно, для копирования.
#
# ТРЕБУЕТ на поде: e2e_pipe (старый pointer), e2e_pipe_tile (tile-ANS),
#   e2e_pipe_tile_split (профиль), aceapex_depth, DietGPU собран.
# Данные: fastq/enwik9/silesia/chr1 в /workspace/data/
# ============================================================================
set +e
DEPTH=/workspace/aceapex/aceapex_depth
DATA=/workspace/data
OUT=/tmp/paper4_results.txt
: > "$OUT"
cd /workspace/aceapex

log(){ echo "$@" | tee -a "$OUT"; }

log "=============================================================="
log "СТАТЬЯ 4 — полный бенчмарк для защиты на ревью"
log "дата: $(date), GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
log "=============================================================="

# --- helper: медиана-3 tile throughput на файле+блоке ---
run_tile(){ local src=$1 bs=$2; export ACEAPEX_BS=$bs
  $DEPTH c --in "$src" --out /tmp/c.aet --threads 8 2>/dev/null
  $DEPTH d --in /tmp/c.aet --out /tmp/c_dec 2>/dev/null
  local b=""
  for r in 1 2 3; do
    v=$(./e2e_pipe_tile streams.bin "$src" 32 2>&1 | grep -oE '\-> [0-9.]+ GB/s' | grep -oE '[0-9.]+'); b="$b $v"; done
  local med=$(echo $b | tr ' ' '\n' | sort -n | sed -n '2p')
  local bp=$(./e2e_pipe_tile streams.bin "$src" 32 2>&1 | grep -oE 'MATCHES OK|DIFFERS')
  echo "$med $bp"; unset ACEAPEX_BS; rm -f /tmp/c.aet /tmp/c_dec streams.bin; }

# ============ A1. BASELINE-ТАБЛИЦА (2.4x против чего) ============
log ""
log "### A1. BASELINE: старый pointer vs tile-ANS, одни данные, один прогон ###"
log "формат@блок | OLD(pointer,win) | TILE-ANS | выигрыш | bit-perfect"
for combo in "fastq:$DATA/NA12878_1gb.fastq:16384" "fastq:$DATA/NA12878_1gb.fastq:32768" "enwik9:$DATA/enwik9:16384" "silesia:$DATA/silesia.tar:16384" "chr1:$DATA/hg38/chr1.fa:32768"; do
  name=$(echo $combo|cut -d: -f1); src=$(echo $combo|cut -d: -f2); bs=$(echo $combo|cut -d: -f3)
  [ ! -f "$src" ] && { log "  $name: НЕТ ФАЙЛА $src"; continue; }
  export ACEAPEX_BS=$bs
  $DEPTH c --in "$src" --out /tmp/c.aet --threads 8 2>/dev/null
  $DEPTH d --in /tmp/c.aet --out /tmp/c_dec 2>/dev/null
  nbtot=$(( $(stat -c%s "$src") / bs )); win=$(( nbtot>24576?24576:nbtot )); st=$(( (nbtot-win)/2 ))
  old=$(./e2e_pipe streams.bin "$src" 32 $st $win 2>&1 | grep -oE '\-> [0-9.]+ GB/s' | grep -oE '[0-9.]+')
  new=$(./e2e_pipe_tile streams.bin "$src" 32 2>&1 | grep -oE '\-> [0-9.]+ GB/s' | grep -oE '[0-9.]+')
  bp=$(./e2e_pipe_tile streams.bin "$src" 32 2>&1 | grep -oE 'MATCHES OK|DIFFERS')
  gain=$(python3 -c "print(f'{$new/$old:.2f}x')" 2>/dev/null || echo "?")
  log "  $name@$bs | OLD=$old | TILE=$new | $gain | $bp"
  unset ACEAPEX_BS; rm -f /tmp/c.aet /tmp/c_dec streams.bin
done

# ============ A2. ABLATION развязки (выигрыш от развязки, не от размера) ============
log ""
log "### A2. ABLATION: связано (tile=block) vs развязано (tile=64K, block=16K) ###"
log "Показывает: выигрыш от РАЗВЯЗКИ гранулярностей, а не просто от крупных тайлов."
log "(tile-ANS всегда tile=64K; сравниваем разные block_size — match-занятость)"
for bs in 16384 65536 262144; do
  export ACEAPEX_BS=$bs
  r=$(run_tile "$DATA/NA12878_1gb.fastq" $bs)
  log "  fastq block=$bs, tile=64K: $r"
  unset ACEAPEX_BS
done
log "  Читать: если мелкий block (16K) БЫСТРЕЕ крупного (256K) — развязка сняла"
log "  штраф мелкого блока (match получил occupancy, ANS не пострадал). Это ablation."

# ============ A3. SPLIT-профиль (механизм: ANS обнулён) ============
log ""
log "### A3. МЕХАНИЗМ: split-таймер (ANS% vs match%) ###"
if [ -x ./e2e_pipe_tile_split ]; then
  export ACEAPEX_BS=16384
  $DEPTH c --in "$DATA/NA12878_1gb.fastq" --out /tmp/c.aet --threads 8 2>/dev/null
  $DEPTH d --in /tmp/c.aet --out /tmp/c_dec 2>/dev/null
  ./e2e_pipe_tile_split streams.bin "$DATA/NA12878_1gb.fastq" 2>&1 | grep -E "SPLIT|implied" | tee -a "$OUT"
  unset ACEAPEX_BS; rm -f /tmp/c.aet /tmp/c_dec streams.bin
else log "  e2e_pipe_tile_split НЕ найден — пропуск"; fi

# ============ A4. RATIO + stream composition (охват, для полноты) ============
log ""
log "### A4. RATIO + композиция потоков (закон ratio, для полноты статьи) ###"
for combo in "fastq:$DATA/NA12878_1gb.fastq:16384" "enwik9:$DATA/enwik9:16384" "silesia:$DATA/silesia.tar:16384" "chr1:$DATA/hg38/chr1.fa:32768"; do
  name=$(echo $combo|cut -d: -f1); src=$(echo $combo|cut -d: -f2); bs=$(echo $combo|cut -d: -f3)
  [ ! -f "$src" ] && continue
  export ACEAPEX_BS=$bs
  $DEPTH c --in "$src" --out /tmp/c.aet --threads 8 2>/dev/null
  osz=$(stat -c%s "$src"); csz=$(stat -c%s /tmp/c.aet)
  ratio=$(python3 -c "print(f'{$osz/$csz:.2f}')")
  log "  $name: ratio=$ratio"
  unset ACEAPEX_BS; rm -f /tmp/c.aet
done

log ""
log "=============================================================="
log "ГОТОВО. Всё в $OUT — скопировать целиком для статьи 4."
log "=============================================================="
