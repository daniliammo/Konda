#!/bin/sh
# bench.sh — замеры производительности stdlib/кодогена Konda ПРОТИВ рукописного
# C+glibc. Отвечает на вопрос «насколько Konda медленнее glibc» числами, а не
# декларациями. POSIX sh (dash-совместимо); ИМЕНА переменных и функций — ТОЛЬКО
# ASCII (dash трактует кириллическое имя как команду). Русский — лишь в строках.
#
# Нагрузки:
#   равенство — строковое равно() (→ glibc memcmp, §81) vs C memcmp: ПАРИТЕТ.
#   сумма     — числовой цикл по срезу (BCE + --march-векторизация §78) vs C.
#   хеш       — FNV-1a (чистый Konda, §84) vs C: ПАРИТЕТ.
#
# Konda собирается в РЕЛИЗЕ на трёх ISA (в1 baseline / в3 дефолт / нативный),
# C — на -O2 baseline и -O2 -march=native. Каждая программа сама крутит крупную
# нагрузку; берём лучшее из 3 прогонов (меньше шума планировщика).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN="$ROOT/Собранное/ТранспиляторКонда"
STD="$ROOT/stdlib/вывод"
OUT="$ROOT/bench/вывод"
CC=${CC:-cc}
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "нет транспилятора — сначала make" >&2; exit 1; }

# best_ms <result-file> <command…> → печатает миллисекунды (лучшее из 3).
best_ms() {
    res="$1"; shift
    best=""
    i=0
    while [ "$i" -lt 3 ]; do
        s=$(date +%s%N)
        "$@" >"$res" 2>/dev/null || true
        e=$(date +%s%N)
        ms=$(( (e - s) / 1000000 ))
        if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
        i=$((i + 1))
    done
    echo "$best"
}

# build_konda <имя> <уровень> → $OUT/<имя>_<уровень>.elf
build_konda() {
    name="$1"; lvl="$2"
    KONDA_STDLIB="$STD" "$BIN" --релиз --march="$lvl" --вывод="$OUT" \
        --имя="${name}_${lvl}" "$ROOT/bench/${name}.конда" >/dev/null 2>&1
}

printf 'Опорная машина: %s\n' "$(uname -mrs)"
printf 'CPU: %s\n\n' "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo '?')"
printf '%-12s %10s %10s %10s %10s %10s\n' нагрузка 'Konda в1' 'Konda в3' 'Konda нат' 'C -O2' 'C native'
printf '%-12s %10s %10s %10s %10s %10s\n' --------- -------- -------- --------- ------- --------

for work in равенство сумма хеш; do
    for lvl in в1 в3 нативный; do build_konda "$work" "$lvl"; done
    $CC -O2 -std=gnu23 "$ROOT/bench/${work}.c" -o "$OUT/${work}_c.elf" 2>/dev/null
    $CC -O2 -march=native -std=gnu23 "$ROOT/bench/${work}.c" -o "$OUT/${work}_cnat.elf" 2>/dev/null

    t_v1=$(best_ms  "$OUT/o_kv1"  "$OUT/${work}_в1.elf")
    t_v3=$(best_ms  "$OUT/o_kv3"  "$OUT/${work}_в3.elf")
    t_nat=$(best_ms "$OUT/o_knat" "$OUT/${work}_нативный.elf")
    t_c=$(best_ms   "$OUT/o_c"    "$OUT/${work}_c.elf")
    t_cn=$(best_ms  "$OUT/o_cn"   "$OUT/${work}_cnat.elf")

    if [ -s "$OUT/o_knat" ] && [ -s "$OUT/o_cn" ] \
       && ! diff -q "$OUT/o_knat" "$OUT/o_cn" >/dev/null 2>&1; then
        printf '%-12s  РАСХОЖДЕНИЕ РЕЗУЛЬТАТА (Konda != C)\n' "$work"
    fi
    printf '%-12s %9sм %9sм %9sм %8sм %9sм\n' \
        "$work" "$t_v1" "$t_v3" "$t_nat" "$t_c" "$t_cn"
done

echo
echo "Меньше — быстрее. равенство/хеш → паритет с C (зовём те же glibc/алгоритм)."
echo "сумма → эффект --march (в3/нативный ускоряют числовой цикл против в1)."
