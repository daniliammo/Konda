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

echo "== хеш-кэш: повторный прогон пропускает сборку =="
( cd "$DEMO" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e2.log" 2>&1 ) || fail "2-й прогон упал"
grep -q "актуально" "$HERE/вывод/e2e2.log" \
    || { cat "$HERE/вывод/e2e2.log" >&2; fail "2-й прогон должен был пропустить сборку (кэш)"; }
echo "  ок: кэш совпал → сборка пропущена"

echo "== --пересобрать форсирует сборку несмотря на кэш =="
( cd "$DEMO" && KONDA_TRANSPILER="$BIN" "$FRONT" --пересобрать >"$HERE/вывод/e2e3.log" 2>&1 ) || fail "форс-прогон упал"
grep -q "готово" "$HERE/вывод/e2e3.log" \
    || { cat "$HERE/вывод/e2e3.log" >&2; fail "--пересобрать должен был собрать заново"; }
echo "  ок: --пересобрать собрал заново"

echo "== смена флага в манифесте → пересборка (не устаревает) =="
cp "$DEMO/Konda.toml" "$HERE/вывод/Konda.toml.копия"
sed -i 's/режим       = "релиз"/режим       = "дебаг"/' "$DEMO/Konda.toml"
( cd "$DEMO" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e4.log" 2>&1 ); RC=$?
cp "$HERE/вывод/Konda.toml.копия" "$DEMO/Konda.toml"   # восстановить
[ "$RC" = 0 ] || { cat "$HERE/вывод/e2e4.log" >&2; fail "прогон после смены флага упал"; }
grep -q "готово" "$HERE/вывод/e2e4.log" \
    || { cat "$HERE/вывод/e2e4.log" >&2; fail "смена флага должна была вызвать пересборку"; }
echo "  ок: смена флага манифеста → ключ изменился → пересборка"

echo "== #2: удаление выходного бинаря → пересборка (кэш не пропускает без бинаря) =="
rm -f "$DEMO/вывод/привет.elf"
( cd "$DEMO" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e5.log" 2>&1 ) || { cat "$HERE/вывод/e2e5.log" >&2; fail "прогон после rm бинаря упал"; }
grep -q "сборка" "$HERE/вывод/e2e5.log" || { cat "$HERE/вывод/e2e5.log" >&2; fail "удалён бинарь, но сборка пропущена по кэшу (#2)"; }
[ -x "$DEMO/вывод/привет.elf" ] || fail "бинарь не восстановлен после rm"
echo "  ок: нет бинаря → пересборка несмотря на совпавший кэш"

echo "== #3: правка локального C-заголовка меняет ключ → пересборка =="
INCDIR="$HERE/вывод/вкл-проект"
rm -rf "$INCDIR"; mkdir -p "$INCDIR"
printf '#pragma once\nstatic inline int дв(int x){return x*2;}\n' > "$INCDIR/ш.h"
cat > "$INCDIR/м.конда" <<'KONDA'
#содержит <stdio.h>
#содержит "ш.h"
внешняя целое32 дв(целое32 x)
целое32 точка_входа(срез<символ*> аргументы)
{
    printf("%d\n", дв(3))
    вернуть 0
}
KONDA
printf '[проект]\nисходники = ["м.конда"]\n' > "$INCDIR/Konda.toml"
( cd "$INCDIR" && KONDA_TRANSPILER="$BIN" "$FRONT" >/dev/null 2>&1 ) || fail "вкл: первая сборка упала"
printf '#pragma once\nstatic inline int дв(int x){return x*3;}\n' > "$INCDIR/ш.h"
( cd "$INCDIR" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e6.log" 2>&1 ) || fail "вкл: пересборка упала"
grep -q "сборка" "$HERE/вывод/e2e6.log" || { cat "$HERE/вывод/e2e6.log" >&2; fail "правка C-заголовка не вызвала пересборку (#3)"; }
echo "  ок: изменённый #содержит-заголовок → пересборка"

echo "== #1: смена ИСТОЧНИКА зависимости → пересборка главного (транзитивно) =="
DEPROOT="$HERE/вывод/деп-проект"
rm -rf "$DEPROOT"; mkdir -p "$DEPROOT/либа" "$DEPROOT/главный"
printf 'целое32 ф(целое32 x) { вернуть x }\n' > "$DEPROOT/либа/л.конда"
printf '[проект]\nтип = "библиотека"\nисходники = ["л.конда"]\n' > "$DEPROOT/либа/Konda.toml"
cat > "$DEPROOT/главный/г.конда" <<'KONDA'
#содержит <stdio.h>
целое32 точка_входа(срез<символ*> аргументы)
{
    printf("g\n")
    вернуть 0
}
KONDA
printf '[проект]\nисходники = ["г.конда"]\n[сборка]\nзависимости = ["../либа"]\n' > "$DEPROOT/главный/Konda.toml"
( cd "$DEPROOT/главный" && KONDA_TRANSPILER="$BIN" "$FRONT" >/dev/null 2>&1 ) || fail "деп: первая сборка упала"
( cd "$DEPROOT/главный" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e7.log" 2>&1 ) || fail "деп: повтор упал"
grep -q "актуально" "$HERE/вывод/e2e7.log" || { cat "$HERE/вывод/e2e7.log" >&2; fail "без изменений главный должен быть актуален"; }
printf 'целое32 ф(целое32 x) { вернуть x + 1 }\n' > "$DEPROOT/либа/л.конда"
( cd "$DEPROOT/главный" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/e2e8.log" 2>&1 ) || fail "деп: пересборка упала"
grep -q "\[хост\] сборка" "$HERE/вывод/e2e8.log" || { cat "$HERE/вывод/e2e8.log" >&2; fail "смена источника зависимости не пересобрала главного (#1)"; }
echo "  ок: изменилась зависимость → главный пересобрался"

echo "== execvp: путь источника с ПРОБЕЛОМ собирается (system() бы разбил по словам) =="
SPACEDIR="$HERE/вывод/проб-проект"
rm -rf "$SPACEDIR"; mkdir -p "$SPACEDIR"
cat > "$SPACEDIR/мой модуль.конда" <<'KONDA'
#содержит <stdio.h>
целое32 точка_входа(срез<символ*> аргументы)
{
    printf("пробел ок\n")
    вернуть 0
}
KONDA
cat > "$SPACEDIR/Konda.toml" <<'TOML'
[проект]
исходники = ["мой модуль.конда"]
выход     = "прог"
TOML
( cd "$SPACEDIR" && KONDA_TRANSPILER="$BIN" "$FRONT" >"$HERE/вывод/проб.log" 2>&1 ) \
    || { cat "$HERE/вывод/проб.log" >&2; fail "сборка с пробелом в пути упала"; }
[ -x "$SPACEDIR/вывод/прог" ] || fail "выход не собран для пути с пробелом"
[ "$("$SPACEDIR/вывод/прог")" = "пробел ок" ] \
    || fail "программа из пути с пробелом дала неверный вывод"
echo "  ок: путь с пробелом собран (execvp, без shell)"

echo "OK: все проверки konda build прошли"
