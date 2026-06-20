CC ?= cc
UNAME_S := $(shell uname -s)

CFLAGS ?= -Wall -Wextra -O2 -std=gnu23
# Объекты идут в разделяемую библиотеку, поэтому собираем позиционно-независимо.
CFLAGS += -fPIC
LDFLAGS ?=

ifeq ($(UNAME_S),Linux)
LDFLAGS += -Wl,--gc-sections
endif

# Разделяемая библиотека: вся логика транспиляции, кроме CLI (основа.c).
LIB = Собранное/libkonda.so
LIB_SRC = дин_массив.c токенизатор_лексер.c конвейер.c ввод_вывод.c аст.c разбор.c семантика.c кодоген.c
LIB_OBJ = $(LIB_SRC:.c=.o)

# Исполняемый CLI поверх публичного API библиотеки.
TARGET = Собранное/Транспилятор
CLI_OBJ = основа.o

all: $(TARGET)

test: $(TARGET)
	sh tests/run.sh

# .so из библиотечных объектов.
$(LIB): $(LIB_OBJ)
	mkdir -p Собранное
	$(CC) -shared $(LIB_OBJ) $(LDFLAGS) -o $(LIB)

# CLI линкуется с libkonda; rpath $ORIGIN — чтобы .so находилась рядом с бинарником.
$(TARGET): $(CLI_OBJ) $(LIB)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(CLI_OBJ) -L Собранное -lkonda $(LDFLAGS) -Wl,-rpath,'$$ORIGIN' -o $(TARGET)

%.o: %.c транспилятор.h аст.h konda.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(LIB) $(LIB_OBJ) $(CLI_OBJ)

# Установка библиотеки, публичного заголовка и CLI.
PREFIX ?= /usr/local
install: $(TARGET)
	install -d $(PREFIX)/lib $(PREFIX)/include $(PREFIX)/bin
	install -m 644 $(LIB) $(PREFIX)/lib/libkonda.so
	install -m 644 konda.h транспилятор.h аст.h $(PREFIX)/include/
	install -m 755 $(TARGET) $(PREFIX)/bin/konda
