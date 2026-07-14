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
                      const char **доп_so, size_t число_so)
{
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
    size_t макс_арг = 18 + 2 * число_so + 1;
    const char **argv = calloc(макс_арг, sizeof(*argv));
    char (*rpaths)[PATH_MAX + 32] = число_so ? calloc(число_so, sizeof(*rpaths)) : nullptr;
    if (!argv || (число_so && !rpaths)) { perror("calloc"); free(argv); free(rpaths); return 1; }
    int n = 0;
    argv[n++] = "cc";
    argv[n++] = "-std=gnu23";
    argv[n++] = "-Wall";
    argv[n++] = "-Wextra";
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
    if (библиотека) {
        argv[n++] = "-shared";
        argv[n++] = "-fPIC";
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
    for (size_t i = 0; i < число_so; ++i) {
        char каталог[PATH_MAX];
        абс_каталог_файла(доп_so[i], каталог, sizeof(каталог));
        snprintf(rpaths[i], sizeof(rpaths[i]), "-Wl,-rpath,%s", каталог);
        argv[n++] = доп_so[i];
        argv[n++] = rpaths[i];
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
        execvp("cc", (char *const *)argv);
        perror("execvp");
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
