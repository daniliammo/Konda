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

# ─── Санитайзер-фазы (общий код для обоих драйверов) ────────────────────────
# jemalloc НЕСОВМЕСТИМ с ASan (перехват malloc/free мимо интерцепторов) → всюду
# libc: транспилятор с --аллокатор=libc, сгенерированный C — напрямую через cc.
# Утечки не утверждаем (detect_leaks=0): транспилятор короткоживущий (арена).

# Собирает ASan+UBSan-сборку транспилятора (KASAN) в файл $1.
build_kasan() {
    _kasan=$1
    cc -std=gnu23 -g -O0 -fsanitize=address,undefined \
        "$ROOT"/дин_массив.c "$ROOT"/токенизатор_лексер.c "$ROOT"/конвейер.c \
        "$ROOT"/ввод_вывод.c "$ROOT"/аст.c "$ROOT"/разбор.c "$ROOT"/обобщения.c \
        "$ROOT"/семантика.c "$ROOT"/владение.c "$ROOT"/кодоген.c "$ROOT"/заголовки.c \
        "$ROOT"/интерфейс.c "$ROOT"/макросы.c "$ROOT"/libkonda_ide.c "$ROOT"/основа.c \
        -o "$_kasan" 2>"${_kasan}_сборка.log" || {
        cat "${_kasan}_сборка.log" >&2
        fail "сборка транспилятора с ASan+UBSan должна проходить"
    }
}

# Санитайзит корпус фикстур в ТЕКУЩЕМ каталоге (cwd = каталог со ВСЕМИ *.конда).
# ЦЕНТРАЛИЗОВАННО и ПАРАЛЛЕЛЬНО (xargs -P): при полном корпусе xargs балансирует
# нагрузку на уровне ФАЙЛОВ — лучше, чем дробить по шардам (пробовали пер-шард:
# неравные куски → простой ядер, медленнее). Две оси:
#   (1) KASAN --только-си по каждому *.конда (+ тест.конда) — ловит ошибки памяти
#       В САМОМ ТРАНСПИЛЯТОРЕ и РЕГЕНЕРИТ вывод/<имя>.c в ОТЛАДКЕ (guard'ы на
#       месте, libc — не как «оставил» body, где часть с --релиз);
#   (2) ASan+UBSan СГЕНЕРИРОВАННОГО C: каждый исполняемый вывод/*.c (метка
#       «int32_t main(» — библиотеки без main отсеиваются) собирается cc
#       -fsanitize и ЗАПУСКАЕТСЯ. Падение фикстур-гардов (abort) — норма,
#       реагируем ТОЛЬКО на маркеры; stdin </dev/null + timeout от зависаний.
# Плюс МУЛЬТИФАЙЛОВЫЕ наборы (путь слияния/cross-file — нужны файлы вместе).
# Падает (fail) на первом маркере. Ожидает: $KASAN, $SAN_MARKERS, $ROOT.
sanitize_corpus() {
    NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

    # (1) транспилятор — параллельно по фикстурам (NUL-разделитель: имя может нести «"»)
    printf 'Санитайзер: ASan+UBSan транспилятора по корпусу…\n'
    : > "_сан_список"
    for _f in "$ROOT/tests/тест.конда" ./*.конда; do
        [ -e "$_f" ] || continue
        printf '%s\0' "$_f" >> "_сан_список"
    done
    : > "_сан_ошибки"
    xargs -0 -P "$NPROC" -I {} sh -c '
        f=$1; SAN=$2; KASAN=$3; ROOT=$4
        base=$(basename "$f")
        ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=1 \
            KONDA_STDLIB="$ROOT/stdlib/вывод" \
            "$KASAN" --только-си --аллокатор=libc "$f" >"_сан_${base}.log" 2>&1 || true
        if grep -qE "$SAN" "_сан_${base}.log"; then
            printf "FAIL: санитайзер (транспилятор) на %s\n" "$base" >&2
            cat "_сан_${base}.log" >&2
            printf "%s\n" "$base" >> "_сан_ошибки"
        fi
    ' _ {} "$SAN_MARKERS" "$KASAN" "$ROOT" < "_сан_список"

    # Мультифайловые наборы — последовательно (их немного), в тот же файл ошибок.
    while IFS= read -r _combo; do
        [ -n "$_combo" ] || continue
        ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=1 \
            "$KASAN" --только-си --аллокатор=libc $_combo >"_сан_комбо.log" 2>&1 || true
        if grep -qE "$SAN_MARKERS" "_сан_комбо.log"; then
            printf 'FAIL: санитайзер на мультифайле: %s\n' "$_combo" >&2
            cat "_сан_комбо.log" >&2
            printf '%s\n' "$_combo" >> "_сан_ошибки"
        fi
    done <<'COMBOS'
файлы_главный.конда файлы_модуль.конда
файлы_модуль.конда файлы_главный.конда
файлы_использует_типы.конда файлы_типы.конда
обобщ_главный.конда обобщ_модуль.конда
обобщ_модуль.конда обобщ_главный.конда
файлы_использует_перечисление.конда файлы_перечисление.конда
файлы_перечисление.конда файлы_использует_перечисление.конда
возврат_структуры_файл_б.конда возврат_структуры_файл_а.конда
COMBOS
    [ ! -s "_сан_ошибки" ] || fail "транспилятор должен быть чист под ASan+UBSan на всём корпусе"

    # (2) сгенерированный C (.elf) — параллельно по исполняемым вывод/*.c
    command -v cc >/dev/null 2>&1 || return 0
    printf 'Санитайзер: ASan+UBSan сгенерированного C (.elf, кодоген)…\n'
    : > "_elf_список"
    for _c in вывод/*.c; do
        [ -e "$_c" ] || continue
        grep -qE '^int32_t main\(' "$_c" && printf '%s\0' "$_c" >> "_elf_список"
    done
    [ -s "_elf_список" ] || return 0
    : > "_elf_ошибки"
    xargs -0 -P "$NPROC" -I {} sh -c '
        c=$1; SAN=$2
        base=$(basename "$c" .c)
        cc -std=gnu23 -g -O0 -fsanitize=address,undefined "$c" -o "вывод/${base}_asan" 2>/dev/null || exit 0
        ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=1 \
            timeout 30 "вывод/${base}_asan" </dev/null >"вывод/${base}.сан" 2>&1 || true
        if grep -qE "$SAN" "вывод/${base}.сан"; then
            printf "FAIL: санитайзер (.elf кодоген) на %s\n" "$base" >&2
            cat "вывод/${base}.сан" >&2
            printf "%s\n" "$base" >> "_elf_ошибки"
        fi
    ' _ {} "$SAN_MARKERS" < "_elf_список"
    [ ! -s "_elf_ошибки" ] || fail "сгенерированный C должен быть чист под ASan+UBSan (ошибка кодогена)"
}
