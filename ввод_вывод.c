#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <stdio.h>
#include <unistd.h>


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
                       int статический)
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
    // Релиз: -O2 (проверки уже сняты кодогеном → скорость уровня C).
    // Отладка: -O0 -g — быстрая компиляция и удобная отладка; рантайм-проверки
    // из кодогена ловят UB с понятным сообщением.
    const char *суффикс = библиотека ? "so" : "elf";
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
    size_t макс_арг = 25 + 2 * число_so + 5;
    const char **argv = calloc(макс_арг, sizeof(*argv));
    char (*rpaths)[PATH_MAX + 32] = число_so ? calloc(число_so, sizeof(*rpaths)) : nullptr;
    if (!argv || (число_so && !rpaths)) { perror("calloc"); free(argv); free(rpaths); return 1; }
    int n = 0;
    argv[n++] = компилятор;
    if (статический) argv[n++] = "-static";
    argv[n++] = "-std=gnu23";
    argv[n++] = "-Wall";
    argv[n++] = "-Wextra";
    // Hardening — переносимая защита с НУЛЕВОЙ ценой на горячем пути (инвариант
    // №1 цел). На хост-gcc большинство этого — дефолт, но кросс-тулчейны/vanilla
    // clang/musl их могут НЕ включать, поэтому задаём ЯВНО (страховка на цель):
    //   • -Wl,-z,relro,-z,now — full RELRO: GOT только для чтения после старта;
    //     цена лишь на загрузке, горячий путь не тронут;
    //   • -Wl,-z,noexecstack — неисполняемый стек (NX), ноль цены;
    //   • -fstack-clash-protection — зондирование больших кадров, чтобы
    //     аллокация НЕ ПЕРЕПРЫГНУЛА guard-страницу. Прямо усиливает защиту стека
    //     из рекурсии: обработчик ловит переполнение постфактум, а этот флаг не
    //     даёт перепрыгнуть страницу вовсе; near-zero (зонд только на крупных
    //     кадрах);
    //   • -fstack-protector-strong — канарейка против переполнения буфера в
    //     кадре (в safe-коде их нет, но в «небезопасно»/при баге кодогена —
    //     defense-in-depth). Стоит копейки, дистрибутивы включают всем.
    // (-fPIE/ASLR не дублируем — это дефолт линковки; -march=native НЕ ставим —
    //  ломал бы переносимость и кросс.)
    // В статическом режиме GOT нет (не PIC) → relro/now бесполезны; noexecstack
    // сохраняем (стек всё ещё NX).
    if (!статический) {
        argv[n++] = "-Wl,-z,relro";
        argv[n++] = "-Wl,-z,now";
    }
    argv[n++] = "-Wl,-z,noexecstack";
    argv[n++] = "-fstack-clash-protection";
    argv[n++] = "-fstack-protector-strong";
    if (релиз) {
        argv[n++] = "-O2";
        // Знаковое переполнение — определённое (обёртка по модулю 2^N), а не UB.
        // Нулевая рантайм-цена на two's-complement машинах; убирает целый класс
        // неопределённого поведения в релизе. В отладке переполнение по-прежнему
        // ловится guard'ами (abort с сообщением), здесь же — предсказуемая обёртка.
        argv[n++] = "-fwrapv";
    } else {
        argv[n++] = "-O0";
        argv[n++] = "-g";
    }
    // Читаемость бэктрейса (конда_прервать вшит в рантайм всегда). Эти флаги
    // влияют только на РАЗМЕР бинарника, не на скорость, поэтому включены по
    // умолчанию и снимаются флагом «--без-символов» (трейс останется, но
    // адресами вместо имён): -rdynamic — символы в .dynsym для
    // backtrace_symbols_fd; -funwind-tables — .eh_frame для раскрутки БЕЗ frame
    // pointer (поэтому -fno-omit-frame-pointer НЕ нужен — скорость релиза цела);
    // -g в релизе — имена/строки для addr2line (в отладке -g уже добавлен выше).
    if (символы) {
        if (!статический) argv[n++] = "-rdynamic";
        argv[n++] = "-funwind-tables";
        if (релиз) argv[n++] = "-g";
    }
    if (библиотека) {
        argv[n++] = "-shared";
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
    // jemalloc — интерпозиция malloc/calloc/free: линкуем по версионному soname
    // (работает и без dev-пакета). Ставим ПОСЛЕ источника/библиотек, чтобы
    // неопределённые calloc/free программы разрешились в jemalloc, а не libc.
    if (линк_jemalloc) {
        // Статический бинарник: -ljemalloc найдёт libjemalloc.a (с активным
        // -static предпочтение у статической версии); нужен libjemalloc-dev.
        // Динамический: -l:libjemalloc.so.2 (версионный soname, без dev-пакета).
        argv[n++] = статический ? "-ljemalloc" : "-l:libjemalloc.so.2";
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
