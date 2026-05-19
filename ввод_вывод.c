#include <stddef.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>


char* прочитать_файл(char *путь_к_файлу, size_t *out_size) {

    FILE *f = fopen(путь_к_файлу, "rb");
    // if (!f) {
    //     perror("fopen");
    //     return 2;
    // }

    int fd = fileno(f);

    struct stat st;
    if (fstat(fd, &st) == 0) {
        printf("Размер файла: %ld байт\n", st.st_size);
    } else {
        perror("stat");
    }

    *out_size = st.st_size;

    char *buffer = (char *)malloc(st.st_size + 1);
    size_t bytes_read = fread(buffer, 1, st.st_size, f);

    buffer[bytes_read] = '\0';

    fclose(f);

    return buffer;

    // if (fseek(f, 0, SEEK_END) == 0) {
    //     long len = ftell(f);
    //     if (len >= 0) {
    //         rewind(f);
    //         char *buf = malloc((size_t)len + 1);
    //         if (!buf) { perror("malloc"); exit(1); }
    //         size_t r = fread(buf, 1, (size_t)len, f);
    //         buf[r] = '\0';
    //         if (out_size) *out_size = r;
    //         return buf;
    //     }
    // }

    // size_t cap = 4096, sz = 0;
    // char *buf = malloc(cap);
    // if (!buf) { perror("malloc"); exit(1); }
    // for (;;) {
    //     size_t r = fread(buf + sz, 1, cap - sz, f);
    //     sz += r;
    //     if (r == 0) break;
    //     if (sz + 1 >= cap) {
    //         cap *= 2;
    //         buf = realloc(buf, cap);
    //         if (!buf) { perror("realloc"); exit(1); }
    //     }
    // }
    // buf[sz] = '\0';
    // if (out_size) *out_size = sz;
    // return buf;
}
