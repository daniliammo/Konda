#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <stdio.h>
#include <unistd.h>
#include "транспилятор.h"   // КОНДА_СУФФИКС_БИБЛ


char* прочитать_файл(char *путь_к_файлу, size_t *out_size) {

    FILE *f = fopen(путь_к_файлу, "rb");
    if (!f) {
        perror(путь_к_файлу);
        return nullptr;
    }

    int fd = fileno(f);

    struct stat st;
    if (fstat(fd, &st) != 0) {
        perror("fstat");
        fclose(f);
        return nullptr;
    }

    if (st.st_size < 0) {
        fprintf(stderr, "Некорректный размер файла: %s\n", путь_к_файлу);
        fclose(f);
        return nullptr;
    }

    *out_size = (size_t)st.st_size;

    char *buffer = (char *)malloc(*out_size + 1);
    if (!buffer) {
        perror("malloc");
        fclose(f);
        return nullptr;
    }

    size_t bytes_read = fread(buffer, 1, *out_size, f);
    if (bytes_read != *out_size && ferror(f)) {
        perror("fread");
        free(buffer);
        fclose(f);
        return nullptr;
    }

    buffer[bytes_read] = '\0';
    *out_size = bytes_read;

    fclose(f);

    return buffer;
}

// Абсолютный каталог, содержащий файл (для -rpath); пусто → «.».
static void абс_каталог_файла(const char *путь, char *out, size_t cap)
{
    char копия[600];
    snprintf(копия, sizeof(копия), "%s", путь);
    char *слэш = strrchr(копия, '/');
    if (слэш) *слэш = '\0';
    else snprintf(копия, sizeof(копия), ".");
    char абс[PATH_MAX];   // realpath требует буфер размером PATH_MAX
    if (realpath(копия[0] ? копия : ".", абс)) snprintf(out, cap, "%s", абс);
    else snprintf(out, cap, "%s", копия[0] ? копия : ".");
}

int скомпилировать_си(const char *путь_си, const char *путь_вывода, int релиз,
                       int библиотека, const char *вкл_каталог,
                       const char **доп_so, size_t число_so, int потоки,
                       const char *компилятор, int jemalloc, int символы,
                       int статический, int использует_embed)
{
    if (!компилятор || !компилятор[0]) компилятор = "cc";
    // jemalloc — только для исполняемых файлов: у .so аллокатор выбирает
    // финальная программа, навязывать интерпозицию в библиотеке нельзя.
    int линк_jemalloc = jemalloc && !библиотека;
    if (статический && библиотека) {
        fprintf(stderr, "Ошибка: --статический несовместим с --библиотека (.so).\n");
        return 1;
    }
    if (статический && число_so > 0) {
        fprintf(stderr, "Ошибка: статическая линковка Konda-библиотек (.so) не поддержана.\n");
        return 1;
    }
#if defined(__APPLE__)
    // На macOS полностью статические бинарники не поддержаны (нет статической
    // libSystem — Apple документирует это официально). Отказываем понятно, а не
    // ловим позднее ошибку линковщика.
    if (статический) {
        fprintf(stderr, "Ошибка: --статический не поддержан на macOS (нет статической libSystem).\n");
        return 1;
    }
#endif
    // Релиз: -O2 (проверки уже сняты кодогеном → скорость уровня C).
    // Отладка: -O0 -g — быстрая компиляция и удобная отладка; рантайм-проверки
    // из кодогена ловят UB с понятным сообщением.
    // Суффикс библиотеки — из транспилятор.h (КОНДА_СУФФИКС_БИБЛ = «so»/«dylib»
    // по хосту), исполняемый — всегда «elf» (условное имя проекта, не значимо
    // для ОС: и Linux, и macOS запускают файл по x-биту, а не суффиксу).
    const char *суффикс = библиотека ? КОНДА_СУФФИКС_БИБЛ : "elf";
    char путь_с_суффиксом[600];
    snprintf(путь_с_суффиксом, sizeof(путь_с_суффиксом), "%s.%s",
             путь_вывода, суффикс);

    // execvp с готовым argv — компилятор запускается напрямую, без промежуточной
    // shell-команды. Путь к файлу (из имени, заданного пользователем) идёт
    // отдельным элементом argv и никогда не разбирается интерпретатором:
    // содержимое вроде «"; rm -rf ~; echo "» — просто буквы в имени файла,
    // а не команда (в отличие от прежней сборки строки для system()).
    // 16 базовых + «-I каталог» (2) + по 2 на каждую .so (путь + -rpath) + NULL.
    // +1 «-pthread», +1 jemalloc, +3 символы (-rdynamic/-funwind-tables/-g),
    // +5 hardening (-Wl,-z,relro/now/noexecstack + stack-clash/protector-strong).
    size_t макс_арг = 25 + 2 * число_so + 5 + 1 /* --embed-dir */;
    const char **argv = calloc(макс_арг, sizeof(*argv));
    char (*rpaths)[PATH_MAX + 32] = число_so ? calloc(число_so, sizeof(*rpaths)) : nullptr;
    if (!argv || (число_so && !rpaths)) { perror("calloc"); free(argv); free(rpaths); return 1; }
    char embed_dir[PATH_MAX + 16];  // «--embed-dir=<каталог>» — живёт до execvp
    int n = 0;
    argv[n++] = компилятор;
    if (статический) argv[n++] = "-static";
    argv[n++] = "-std=gnu23";
    argv[n++] = "-Wall";
    argv[n++] = "-Wextra";
    // Hardening — переносимая защита с НУЛЕВОЙ ценой на горячем пути (инвариант
    // №1 цел). На хост-gcc большинство этого — дефолт, но кросс-тулчейны/vanilla
    // clang/musl их могут НЕ включать, поэтому задаём ЯВНО (страховка на цель).
    // ПОРТИРУЕМОСТЬ (Linux/BSD/macOS):
    //   • -Wl,-z,relro/-z,now/-z,noexecstack — GNU/LLD-опции, есть на Linux и
    //     BSD (LLD/bfd-порт). На macOS ld64 их НЕ ЗНАЕТ (упадёт «unknown option
    //     -z») — там NX-стек и защита GOT обеспечиваются форматом Mach-O
    //     платформой, флаги не нужны;
    //   • -fstack-clash-protection — есть в gcc≥8 и clang≥13 на Linux/BSD; на
    //     AppleClang номера версий свои и поддержка исторически неровная —
    //     на Darwin не ставим, чтобы не ломать сборку;
    //   • -fstack-protector-strong — переносим (gcc/clang на всех POSIX).
    // (-fPIE/ASLR не дублируем — это дефолт линковки; -march=native НЕ ставим —
    //  ломал бы переносимость и кросс.)
    // В статическом режиме GOT нет (не PIC) → relro/now бесполезны; noexecstack
    // сохраняем (стек всё ещё NX).
#if !defined(__APPLE__)
    if (!статический) {
        argv[n++] = "-Wl,-z,relro";
        argv[n++] = "-Wl,-z,now";
    }
    argv[n++] = "-Wl,-z,noexecstack";
    argv[n++] = "-fstack-clash-protection";
#endif
    argv[n++] = "-fstack-protector-strong";
    if (релиз) {
        argv[n++] = "-O2";
        // Знаковое переполнение — определённое (обёртка по модулю 2^N), а не UB.
        // Нулевая рантайм-цена на two's-complement машинах; убирает целый класс
        // неопределённого поведения в релизе. В отладке переполнение по-прежнему
        // ловится guard'ами (abort с сообщением), здесь же — предсказуемая обёртка.
        argv[n++] = "-fwrapv";
        // -fno-math-errno: sqrt/exp/log/pow и т.п. по стандарту C ставят errno при
        // доменной ошибке (sqrt(-1) → EDOM). Компилятор ОБЯЗАН вызывать их через
        // реальный библиотечный call и не может векторизовать — сохранение errno
        // считается побочным эффектом. Флаг снимает это разрешение (стандарт C
        // явно позволяет), gcc сам инлайнит математику в SIMD-инструкции.
        // Инвариант №1 цел: не проверка, а разрешение оптимизации — ничего не
        // добавляет к рантайму, только снимает искусственный барьер.
        argv[n++] = "-fno-math-errno";
        // -fno-plt: каждый вызов libc/jemalloc/pthread идёт через PLT-thunk
        // (косвенный прыжок + `bnd`-байт + запись в .got.plt при первом вызове).
        // С -fno-plt gcc генерирует прямой indirect через GOT
        // (`call *printf@GOTPCREL(%rip)`) — минус одна инструкция на каждый
        // внешний вызов. Полностью совместимо с §28 FULL RELRO: там уже
        // «-Wl,-z,now» → GOT разрешается при старте, ленивого разрешения нет,
        // так что оверхеда PLT нет никакого — только выгода от прямого вызова.
        argv[n++] = "-fno-plt";
    } else {
        argv[n++] = "-O0";
        argv[n++] = "-g";
    }
    // Читаемость бэктрейса (конда_прервать вшит в рантайм всегда). Эти флаги
    // влияют только на РАЗМЕР бинарника, не на скорость, поэтому включены по
    // умолчанию и снимаются флагом «--без-символов»:
    //   • -rdynamic — GNU-ld опция для .dynsym → backtrace_symbols_fd на ELF;
    //     на macOS не нужна (dyld всегда экспортирует символы для CoreSymbolication;
    //     backtrace_symbols на Darwin читает Mach-O напрямую);
    //   • -funwind-tables — .eh_frame для раскрутки БЕЗ frame pointer;
    //     переносимо (gcc/clang на всех POSIX). Поэтому -fno-omit-frame-pointer
    //     НЕ нужен — скорость релиза цела;
    //   • -g в релизе — имена/строки для addr2line/atos (в отладке уже выше).
    if (символы) {
#if !defined(__APPLE__)
        if (!статический) argv[n++] = "-rdynamic";
#endif
        argv[n++] = "-funwind-tables";
        if (релиз) argv[n++] = "-g";
    }
    if (библиотека) {
        // -fPIC — переносимо; форма разделяемой библиотеки различается:
        // ELF (Linux/BSD): «-shared» → .so;
        // Mach-O (macOS):   «-dynamiclib» → .dylib + install_name (@rpath —
        //                   потребитель находит по своему -rpath).
#if defined(__APPLE__)
        argv[n++] = "-dynamiclib";
        // install_name с @rpath: потребитель (bundle/elf) сам определит путь
        // через свой -Wl,-rpath,<каталог> — так же, как -rpath на ELF.
        char *inst = calloc(1, PATH_MAX + 64);
        if (inst) {
            const char *базовое = strrchr(путь_с_суффиксом, '/');
            базовое = базовое ? базовое + 1 : путь_с_суффиксом;
            snprintf(inst, PATH_MAX + 64, "-Wl,-install_name,@rpath/%s", базовое);
            argv[n++] = inst;   // намеренно утекает вместе с процессом (короткоживущим)
        }
#else
        argv[n++] = "-shared";
#endif
        argv[n++] = "-fPIC";
    }
    // Потоки: «-pthread» и для компиляции, и для линковки. Добавляем только
    // когда программа реально их использует — обычные сборки не трогаем.
    if (потоки) {
        argv[n++] = "-pthread";
    }
    // Каталог исходника — чтобы локальные «#include "…"» разрешались (сгенерир.
    // .c лежит в «вывод/», а include-пути записаны относительно исходника).
    if (вкл_каталог && вкл_каталог[0]) {
        argv[n++] = "-I";
        argv[n++] = вкл_каталог;
        // «встроить("файл")» (C23 #embed): «#embed "путь"» ищет файл рядом с .c
        // (вывод/) и по «--embed-dir», но НЕ по «-I». Даём каталог исходника через
        // «--embed-dir», чтобы относительные пути «встроить» разрешались как у
        // «#содержит». Флаг ставим ТОЛЬКО когда embed реально используется — иначе
        // не навязываем его компилятору (старый cc без #embed на не-embed сборках
        // не должен падать на неизвестном флаге).
        if (использует_embed) {
            snprintf(embed_dir, sizeof(embed_dir), "--embed-dir=%s", вкл_каталог);
            argv[n++] = embed_dir;
        }
    }
    argv[n++] = "-o";
    argv[n++] = путь_с_суффиксом;
    argv[n++] = путь_си;
    // Линковка Konda-библиотек (безопасный путь 2): позиционный .so + rpath на
    // её абсолютный каталог, чтобы .elf находил её при запуске.
    // В статике число_so == 0 (отвергнуто в начале функции).
    for (size_t i = 0; i < число_so; ++i) {
        char каталог[PATH_MAX];
        абс_каталог_файла(доп_so[i], каталог, sizeof(каталог));
        snprintf(rpaths[i], sizeof(rpaths[i]), "-Wl,-rpath,%s", каталог);
        argv[n++] = доп_so[i];
        argv[n++] = rpaths[i];
    }
    // jemalloc — интерпозиция malloc/calloc/free. Ставим ПОСЛЕ источника/
    // библиотек, чтобы неопределённые calloc/free программы разрешились в
    // jemalloc, а не libc. Форма линковки — по хосту:
    //  • Linux (GNU-ld/LLD): «-l:libjemalloc.so.2» — версионный soname без
    //    dev-symlink (пакет libjemalloc2 достаточен, libjemalloc-dev не нужен);
    //    «-l:name» — GNU-расширение, LLD его поддерживает;
    //  • BSD/macOS: «-l:name» их линковщики (bsd ld/ld64) не знают, поэтому
    //    обычное «-ljemalloc» (Homebrew/pkg дают libjemalloc.dylib/.so
    //    и dev-symlink);
    //  • статика (-static, только Linux): «-ljemalloc» найдёт libjemalloc.a.
    if (линк_jemalloc) {
#if defined(__linux__)
        argv[n++] = статический ? "-ljemalloc" : "-l:libjemalloc.so.2";
#else
        argv[n++] = "-ljemalloc";
#endif
    }
    argv[n] = nullptr;

    for (int i = 0; i < n; ++i) {
        printf(i == 0 ? "%s" : " %s", argv[i]);
    }
    printf("\n");

    int рез = 0;
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        рез = 1;
    } else if (pid == 0) {
        execvp(компилятор, (char *const *)argv);
        perror(компилятор);
        _exit(127);
    } else {
        int статус = 0;
        if (waitpid(pid, &статус, 0) < 0) {
            perror("waitpid");
            рез = 1;
        } else if (!WIFEXITED(статус) || WEXITSTATUS(статус) != 0) {
            fprintf(stderr, "Ошибка компиляции (код %d)\n",
                    WIFEXITED(статус) ? WEXITSTATUS(статус) : -1);
            рез = 1;
        } else {
            printf("Собрано: %s\n", путь_с_суффиксом);
        }
    }
    free(argv);
    free(rpaths);
    return рез;
}
