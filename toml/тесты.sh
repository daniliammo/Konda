#!/bin/sh
# Тесты libkonda_toml. POSIX sh (dash-safe): имена переменных/функций — ASCII.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../Собранное/ТранспиляторКонда"
OUT="$HERE/вывод"

fail() { echo "  ОШИБКА: $1" >&2; exit 1; }
assert_eq() { # ожидание, факт, метка
    if [ "$1" != "$2" ]; then
        echo "  ОШИБКА [$3]: ожидалось [$1], получено [$2]" >&2; exit 1
    fi
}

[ -x "$BIN" ] || fail "нет транспилятора: $BIN (собери 'make' в корне)"

echo "== сборка библиотеки (--библиотека → .so + .и) =="
"$BIN" --библиотека "$HERE/toml.конда" >/dev/null 2>&1 \
    || fail "toml.конда не собралась как библиотека"
[ -f "$OUT/toml.so" ] || fail "нет вывод/toml.so"
[ -f "$OUT/toml.и" ]  || fail "нет вывод/toml.и"
grep -q "^Ф томл_значение" "$OUT/toml.и" || fail ".и не экспортирует томл_значение"
echo "  ок: .so + .и собраны, интерфейс экспортирован"

echo "== самотест (query-API: секции, строки, флаги, массивы) =="
"$BIN" "$HERE/toml.конда" "$HERE/тест.конда" >/dev/null 2>&1 \
    || fail "самотест не собрался"
OUTP="$("$OUT/toml.elf")"
assert_eq "имя=[конда_init]"        "$(echo "$OUTP" | sed -n 1p)"  "строка из [проект]"
assert_eq "версия=[0.1.0]"          "$(echo "$OUTP" | sed -n 2p)"  "строка версии"
assert_eq "режим=[релиз]"           "$(echo "$OUTP" | sed -n 3p)"  "строка из [сборка]"
assert_eq "статический=1"           "$(echo "$OUTP" | sed -n 4p)"  "флаг true"
assert_eq "стдлиб=1"                "$(echo "$OUTP" | sed -n 5p)"  "флаг да"
assert_eq "отладка(умолч)=0"        "$(echo "$OUTP" | sed -n 6p)"  "флаг по умолчанию"
assert_eq "исходников=2"            "$(echo "$OUTP" | sed -n 7p)"  "длина массива"
assert_eq "ист0=[основа.конда]"     "$(echo "$OUTP" | sed -n 8p)"  "элемент массива 0"
assert_eq "ист1=[утилиты.конда]"    "$(echo "$OUTP" | sed -n 9p)"  "элемент массива 1"
assert_eq "нетключа=<нет>"          "$(echo "$OUTP" | sed -n 10p)" "отсутствующий ключ"
echo "  ок: все запросы вернули верные значения"

echo "== ASan+UBSan (память сгенерированного C чиста) =="
"$BIN" --только-си "$HERE/toml.конда" "$HERE/тест.конда" >/dev/null 2>&1
cc -std=gnu23 -g -O0 -fsanitize=address,undefined -I "$HERE" "$OUT/toml.c" -o "$OUT/toml_asan" 2>/dev/null \
    || fail "ASan-сборка не удалась"
"$OUT/toml_asan" >/dev/null 2>"$OUT/toml_asan.log" \
    || { cat "$OUT/toml_asan.log" >&2; fail "самотест падает под ASan/UBSan"; }
echo "  ок: ASan/UBSan-чисто"

echo "OK: все проверки libkonda_toml прошли"
