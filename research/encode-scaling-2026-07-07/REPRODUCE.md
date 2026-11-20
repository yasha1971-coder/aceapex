# Encode scaling + MAX_DIST sweep (breakthrough 8)

## Что доказывает
LZ77 encode phase = 95% времени, масштабируется 7.3x на 16 ядрах (42 -> 307 MB/s).
MAX_DIST 128M->64K: encode +15%, ratio неизменен (окно не bottleneck).

## Воспроизведение
1. Собрать варианты с разным окном:
   for D in 134217728 1048576 262144 65536; do
     sed "s/#define MAX_DIST     (128 \* 1024 \* 1024)/#define MAX_DIST     ($D)/" \
       aceapex_depth.cpp > /tmp/ad.cpp
     g++ -O3 -march=native -std=c++17 -I. -Isrc -I<zstd_include> /tmp/ad.cpp \
       -o /tmp/aceapex_$D <libzstd.so> -lpthread
   done

2. Scaling: aceapex_depth c --in enwik9 --threads {1,2,4,8,16}, читать "Phase LZ77:"

## Результаты (H100 pod, EPYC, enwik9)
threads 1->2->4->8->16 = 42->77->134->216->307 MB/s (7.3x; было записано 11.5x - ошибка счёта, исправлено 11.11.2026)
MAX_DIST 128M/64K: fastq 507/566, enwik9 217/255 MB/s, ratio неизменен
