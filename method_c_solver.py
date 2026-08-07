#!/usr/bin/env python3
# method_c_solver.py — МЕТОД В: движок дисциплины, кодирующий 5-шаговый метод,
# что сработал сегодня 8+ раз. НЕ "решатель всего" (такого нет) — а СТРАЖ,
# не дающий двигаться к оптимизации, пока каждый шаг не подтверждён ФАКТОМ.
# Прогоняет РЕАЛЬНУЮ задачу через 5 гейтов, требуя данные на каждом.
#
# Применяем к живой задаче: "ускорить encode SA-build".
import sys

class Gate:
    def __init__(s, num, name, question, need):
        s.num=num; s.name=name; s.question=question; s.need=need; s.passed=None; s.evidence=""

GATES = [
    Gate(1,"Локализация bottleneck",
         "Где узкое место — ИЗМЕРЕНО, не предположено?",
         "профиль/таймер с долями (%)"),
    Gate(2,"Обход без смены ядра",
         "Можно обойти bottleneck, НЕ трогая проверенное ядро?",
         "какой компонент меняем, что остаётся неизменным"),
    Gate(3,"Механизм изолированно",
         "Механизм обхода проверен ОТДЕЛЬНО до интеграции?",
         "smoke-тест механизма, границы (где ломается)"),
    Gate(4,"Bit-perfect на реальных",
         "Результат bit-perfect на РЕАЛЬНЫХ данных (не синтетике)?",
         "FNV/md5/cmp на реальном датасете"),
    Gate(5,"Контроль против самообмана",
         "Красивое число проверено ПРАВИЛЬНЫМ контролем?",
         "equal-window/baseline/re-measure — что убило бы иллюзию"),
]

def run(task, evidence):
    """task — описание, evidence — dict {gate_num: строка-факт или None}"""
    print(f"=== МЕТОД В: дисциплина решения ===")
    print(f"ЗАДАЧА: {task}\n")
    all_pass=True
    for g in GATES:
        ev = evidence.get(g.num)
        status = "✓ ПРОЙДЕН" if ev else "✗ НЕ ПОДТВЕРЖДЁН"
        if not ev: all_pass=False
        print(f"[Гейт {g.num}] {g.name}: {status}")
        print(f"    вопрос: {g.question}")
        print(f"    нужен факт: {g.need}")
        if ev: print(f"    ФАКТ: {ev}")
        else:  print(f"    -> СТОП. Не двигаться дальше, пока нет факта.")
        print()
    print("=== ВЕРДИКТ ===")
    if all_pass:
        print("ВСЕ ГЕЙТЫ ПРОЙДЕНЫ — оптимизация обоснована, можно интегрировать.")
    else:
        first = next(g for g in GATES if not evidence.get(g.num))
        print(f"СТОП на гейте {first.num} ({first.name}).")
        print(f"Следующее действие: добыть факт '{first.need}' ПРЕЖДЕ чем идти дальше.")
    return all_pass

if __name__=='__main__':
    # применяем к живой задаче encode с тем, что УЖЕ знаем фактом на сегодня
    task = "Ускорить encode SA-build (floor 47 MB/s)"
    evidence = {
        1: "профиль: SA-build=96%, rank=0.17ms, candidates=3% (изм. на pod)",
        2: "меняем SA-алгоритм (thrust->libsais/libcubwt), candidates-слой НЕ трогаем",
        3: None,  # ещё не сделали smoke настоящего SA
        4: "GPU-SA прототип bit-perfect на enwik9/fastq (изм. на pod)",
        5: None,  # нет baseline: libsais vs thrust на одних данных
    }
    run(task, evidence)
