#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN="$ROOT/Собранное/Транспилятор"
TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    expected=$1
    actual=$2
    name=$3
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
}

make -C "$ROOT"

cd "$TMP"

# тест.конда — это «песочница», её содержимое меняется. Здесь только
# дымовой тест: должна транспилироваться и компилироваться без ошибок.
"$BIN" "$ROOT/тест.конда" >"$TMP/build.log" 2>&1 || {
    cat "$TMP/build.log" >&2
    fail "пример тест.конда должен транспилироваться и компилироваться"
}

# Поведение printf (передача аргументов как есть, без подстановки "%s\n")
# проверяем на собственной стабильной фикстуре.
cat > basic.конда <<'KONDA'
#содержит <stdio.h>

целое4 точка_входа(целое4 количество_аргументов, символ** аргументы)
{
    если (количество_аргументов > 1) {
        printf(аргументы[1]);
    } иначе {
        printf("нет аргумента");
    }
}
KONDA

"$BIN" basic.конда >"$TMP/basic.log" 2>&1 || {
    cat "$TMP/basic.log" >&2
    fail "базовый пример должен транспилироваться и компилироваться"
}
assert_eq "hello" "$(./вывод/basic.elf hello)" "printf передаёт аргумент как есть"
assert_eq "нет аргумента" "$(./вывод/basic.elf)" "printf со строковым литералом"

cat > ge.конда <<'KONDA'
#содержит <stdio.h>

целое4 точка_входа(целое4 количество_аргументов, символ** аргументы)
{
    если (количество_аргументов >= 2) {
        printf(аргументы[1]);
    } иначе {
        printf("мало аргументов");
    }
}
KONDA

"$BIN" ge.конда >"$TMP/ge.log" 2>&1 || {
    cat "$TMP/ge.log" >&2
    fail "условие >= должно поддерживаться"
}
assert_eq "ok" "$(./вывод/ge.elf ok)" "условие >="

cat > bad_bounds.конда <<'KONDA'
#содержит <stdio.h>

целое4 точка_входа(целое4 количество_аргументов, символ** аргументы)
{
    если (количество_аргументов > 0) {
        printf(аргументы[1]);
    }
}
KONDA

if "$BIN" bad_bounds.конда >"$TMP/bounds.log" 2>&1; then
    cat "$TMP/bounds.log" >&2
    fail "небезопасный доступ к аргументы[1] должен быть ошибкой"
fi
grep -q "индекс 1 вне границ" "$TMP/bounds.log" || {
    cat "$TMP/bounds.log" >&2
    fail "ошибка границ должна быть понятной"
}

if "$BIN" missing.конда >"$TMP/missing.log" 2>&1; then
    cat "$TMP/missing.log" >&2
    fail "несуществующий файл должен завершаться ошибкой"
fi
grep -q "Не удалось прочитать" "$TMP/missing.log" || {
    cat "$TMP/missing.log" >&2
    fail "ошибка чтения файла должна быть понятной"
}

printf 'OK: все тесты прошли\n'
