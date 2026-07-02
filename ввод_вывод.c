#include <stddef.h>
#include <stdlib.h>
#include <string.h>
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

int скомпилировать_си(const char *путь_си, const char *путь_вывода, int релиз,
                      int библиотека)
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
    const char *argv[16];
    int n = 0;
    argv[n++] = "cc";
    argv[n++] = "-std=gnu23";
    argv[n++] = "-Wall";
    argv[n++] = "-Wextra";
    if (релиз) {
        argv[n++] = "-O2";
    } else {
        argv[n++] = "-O0";
        argv[n++] = "-g";
    }
    if (библиотека) {
        argv[n++] = "-shared";
        argv[n++] = "-fPIC";
    }
    argv[n++] = "-o";
    argv[n++] = путь_с_суффиксом;
    argv[n++] = путь_си;
    argv[n] = nullptr;

    for (int i = 0; i < n; ++i) {
        printf(i == 0 ? "%s" : " %s", argv[i]);
    }
    printf("\n");

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        execvp("cc", (char *const *)argv);
        perror("execvp");
        _exit(127);
    }
    int статус = 0;
    if (waitpid(pid, &статус, 0) < 0) {
        perror("waitpid");
        return 1;
    }
    if (!WIFEXITED(статус) || WEXITSTATUS(статус) != 0) {
        fprintf(stderr, "Ошибка компиляции (код %d)\n",
                WIFEXITED(статус) ? WEXITSTATUS(статус) : -1);
        return 1;
    }
    printf("Собрано: %s\n", путь_с_суффиксом);
    return 0;
}
