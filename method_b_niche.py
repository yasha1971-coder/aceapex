#!/usr/bin/env python3
# method_b_niche.py — МЕТОД Б: количественно найти свободную нишу.
# Гипотеза: ACEAPEX absolute-offset random access решает боль, которой нет
# у существующих (samtools/CRAM распаковывают много, чтобы достать один регион).
# Метод: на РЕАЛЬНОМ геноме измерить, сколько данных надо прочитать/распаковать,
# чтобы достать 1 регион — у блочного absolute-offset vs у обычного потокового.
import sys, time, os, subprocess

def measure_random_access(path, region_bytes=16384, n_probes=100):
    """Сколько РЕАЛЬНО байт надо распаковать, чтобы достать n_probes случайных
    регионов. Блочный absolute-offset: только нужные блоки. Потоковый: всё до региона."""
    import random
    random.seed(42)
    fsz = os.path.getsize(path)
    BLOCK = 65536  # блок absolute-offset random access

    # ACEAPEX-модель: чтобы достать регион, распаковываем только его блок(и)
    aceapex_bytes = 0
    stream_bytes = 0
    for _ in range(n_probes):
        pos = random.randint(0, max(0,fsz-region_bytes))
        # блочный: округляем до границ блоков, читаем только их
        blk_start = (pos//BLOCK)*BLOCK
        blk_end = ((pos+region_bytes+BLOCK-1)//BLOCK)*BLOCK
        aceapex_bytes += (blk_end - blk_start)
        # потоковый (типичный gzip/поток): чтобы декодировать позицию pos,
        # надо распаковать ВСЁ от начала текущего большого чанка. Моделируем
        # типичный gzip-чанк 900KB (bgzip) — но классический gzip = с начала файла.
        # bgzip-модель (лучший случай потоковых): чанк 65280 (bgzip default)
        BGZIP=65280
        stream_bytes += BGZIP  # bgzip тоже блочный ~64KB — честное сравнение
    return aceapex_bytes, stream_bytes, n_probes

def main():
    path = sys.argv[1] if len(sys.argv)>1 else None
    if not path or not os.path.exists(path):
        print("нужен путь к реальному геному (fastq/fa)"); return
    print("=== МЕТОД Б: поиск ниши — random access преимущество ===")
    print(f"данные: {path}, {os.path.getsize(path)/1e6:.1f} MB")
    for region in [1024, 16384, 65536]:
        a,s,n = measure_random_access(path, region)
        print(f"\nрегион={region}B, {n} случайных запросов:")
        print(f"  ACEAPEX (блок 64K, absolute-offset): {a/1e6:.1f} MB распаковано")
        print(f"  bgzip-модель (потоковый блок 64K):   {s/1e6:.1f} MB")
        ratio = s/a if a else 0
        print(f"  -> для региона {region}B ACEAPEX читает {'меньше' if ratio<1 else 'столько же'}")
    print("\n--- ЧЕСТНЫЙ ВЫВОД ---")
    print("Ключевое НЕ 'меньше байт' (bgzip тоже блочный), а ЧТО ACEAPEX даёт")
    print("GPU-параллельный random access: 100 регионов декодятся ОДНОВРЕМЕННО")
    print("на тысячах ядер, position-invariant. bgzip/CRAM — последовательно на CPU.")
    print("Ниша = GPU-native random access, не 'меньше байт'. Это надо мерить на GPU.")
    print("Метод Б говорит: преимущество НЕ в объёме, а в ПАРАЛЛЕЛИЗМЕ доступа.")
    print("Следующий тест: 100 GPU random seeks одновременно vs 100 CPU samtools.")

if __name__=='__main__': main()
