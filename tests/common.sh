# common.sh — общая преамбула тест-набора: хелперы, маркеры санитайзера,
# проверка компилятора. Подключается драйверами: run.sh (последовательный,
# эталон) и run_par.sh (параллельный шардированный, идентичный результат).
# ROOT/BIN/TMP задаёт драйвер. Имена переменных — ТОЛЬКО ASCII: скрипт под
# dash — кириллическое имя трактуется как команда, а не присваивание.

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

# Маркеры отчёта санитайзера (общие для обоих ASan/UBSan-прогонов). Обычные
# диагностики Konda — на русском («Ошибка транспиляции») — с ними не
# пересекаются → ложных срабатываний нет.
SAN_MARKERS='AddressSanitizer|UndefinedBehaviorSanitizer|runtime error:|SUMMARY: (Address|Undefined)'

# Требуем современный компилятор: gcc ≥ 15 или clang ≥ 19 (musttail → TCO;
# полный C23 -std=gnu23/nullptr). Проверяем ТОТ cc, которым транспилятор
# компилирует вывод (внутренний «cc», совпадает с $CC/make).
check_compiler() {
    cc_bin=${CC:-cc}
    if "$cc_bin" --version 2>/dev/null | grep -qi clang; then
        cc_major=$("$cc_bin" -dumpversion 2>/dev/null | cut -d. -f1)
        case "$cc_major" in
            ''|*[!0-9]*) : ;;  # версию не распознали — не блокируем (напр. Apple clang)
            *) [ "$cc_major" -ge 19 ] || fail "нужен clang >= 19 (обнаружен clang $cc_major): нужна полная поддержка C23 (-std=gnu23, nullptr). Установите clang-19, либо используйте gcc >= 15." ;;
        esac
    else
        cc_major=$("$cc_bin" -dumpversion 2>/dev/null | cut -d. -f1)
        case "$cc_major" in
            ''|*[!0-9]*) : ;;  # версию не распознали — не блокируем
            *) [ "$cc_major" -ge 15 ] || fail "нужен gcc >= 15 (обнаружен gcc $cc_major): musttail для гарантированного TCO. Соберите с CC=gcc-15 или используйте clang." ;;
        esac
    fi
}
