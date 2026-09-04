#!/bin/sh
# E2E-тест фронтенда «konda build»: собрать фронтенд, прогнать на демо-проекте
# сборка/пример (манифест Konda.toml → транспилятор → рабочий .elf). POSIX sh,
# имена переменных — ASCII.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/Собранное/ТранспиляторКонда"
FRONT="$HERE/вывод/сборка.elf"
DEMO="$HERE/пример"

fail() { echo "  ОШИБКА: $1" >&2; exit 1; }

echo "== сборка фронтенда (libkonda_toml + сборка.конда) =="
sh "$HERE/собрать.sh" >/dev/null 2>&1 || fail "фронтенд не собрался"
[ -x "$FRONT" ] || fail "нет $FRONT"
echo "  ок"

echo "== konda build на демо-проекте (манифест → транспилятор → .elf) =="
[ -f "$DEMO/Konda.toml" ] || fail "нет демо-манифеста $DEMO/Konda.toml"
rm -rf "$DEMO/вывод"
( cd "$DEMO" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e.log" 2>&1 ) \
    || { cat "$HERE/вывод/e2e.log" >&2; fail "konda build завершился с ошибкой"; }
grep -q "готово" "$HERE/вывод/e2e.log" || { cat "$HERE/вывод/e2e.log" >&2; fail "нет отметки 'готово'"; }
[ -x "$DEMO/вывод/привет.elf" ] || fail "транспилятор не собрал привет.elf"
OUTP="$("$DEMO/вывод/привет.elf")"
[ "$OUTP" = "привет из собранной программы" ] \
    || fail "собранная программа дала неожиданный вывод: [$OUTP]"
echo "  ок: манифест разобран, программа собрана и запущена"

echo "OK: все проверки konda build прошли"
