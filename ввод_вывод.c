#include <stddef.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>


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

int скомпилировать_си(const char *путь_си, const char *путь_исполняемого, int релиз)
{
    // Релиз: -O2 (проверки уже сняты кодогеном → скорость уровня C).
    // Отладка: -O0 -g — быстрая компиляция и удобная отладка; рантайм-проверки
    // из кодогена ловят UB с понятным сообщением.
    const char *флаги_опт = релиз ? "-O2" : "-O0 -g";
    char команда[2048];
    snprintf(команда, sizeof(команда),
             "cc -std=gnu23 -Wall -Wextra %s -o \"%s.elf\" \"%s\"",
             флаги_опт, путь_исполняемого, путь_си);
    printf("%s\n", команда);
    int код = system(команда);
    if (код != 0) {
        fprintf(stderr, "Ошибка компиляции (код %d)\n", код);
        return 1;
    }
    printf("Собрано: %s.elf\n", путь_исполняемого);
    return 0;
}
