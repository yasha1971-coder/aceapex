#!/usr/bin/env bash
# sync-check.sh — расхождения между копиями исходника и собранными бинарями.
# Трижды за одну сессию вывод делался из кода, который не был собран или лежал
# в другой копии: дефолт правился в одном файле и измерялся из другого, бинарь
# оказывался старше исходника, переменная окружения переживала свой замер.
set -uo pipefail
FAIL=0

echo "--- копии исходника ---"
for pair in "aceapex_depth.cpp:$HOME/aceapex/aceapex_depth.cpp" \
            "src/aceapex_main.cpp:$HOME/lzbench/bench/aceapex_main.cpp"; do
  a="${pair%%:*}"; b="${pair##*:}"
  if [ ! -f "$b" ]; then echo "  нет $b (пропуск)"; continue; fi
  if cmp -s "$a" "$b"; then echo "  OK   $a = $b"
  else echo "  РАСХОЖДЕНИЕ $a != $b"; FAIL=1; fi
done

echo "--- бинарь новее исходника? ---"
for pair in "$HOME/aceapex/aceapex_region:aceapex_depth.cpp" \
            "$HOME/lzbench/lzbench:src/aceapex_main.cpp"; do
  bin="${pair%%:*}"; src="${pair##*:}"
  if [ ! -f "$bin" ]; then echo "  нет $bin (пропуск)"; continue; fi
  if [ "$bin" -nt "$src" ]; then echo "  OK   $(basename $bin) собран после правки"
  else echo "  УСТАРЕЛ $(basename $bin): $src новее — пересоберите"; FAIL=1; fi
done

echo "--- переменные окружения, влияющие на замеры ---"
for v in ACEAPEX_DUMP LIT_CHUNK MIN_MATCH NO_REP FORCED_BIN; do
  if [ -n "${!v:-}" ]; then echo "  ЗАДАНА $v=${!v} — числа будут не эталонными"; FAIL=1; fi
done
[ "${ACEAPEX_BS:-}" ] && echo "  ACEAPEX_BS=$ACEAPEX_BS (это нормально, если так задумано)"

echo ""
[ "$FAIL" -eq 0 ] && echo "СИНХРОННО" || echo "ЕСТЬ РАСХОЖДЕНИЯ — см. выше"
exit $FAIL
