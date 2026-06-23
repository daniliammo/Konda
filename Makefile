CC ?= cc
UNAME_S := $(shell uname -s)

CFLAGS ?= -Wall -Wextra -O2 -std=gnu23
# Объекты идут в разделяемую библиотеку, поэтому собираем позиционно-независимо.
CFLAGS += -fPIC
LDFLAGS ?=

ifeq ($(UNAME_S),Linux)
LDFLAGS += -Wl,--gc-sections
LIB_NAME = libkonda.so
SHARED_FLAGS = -shared
# При локальной сборке библиотека лежит рядом с CLI; после make install —
# в ../lib относительно $(PREFIX)/bin/konda.
RPATH_FLAGS = -Wl,-rpath,'$$ORIGIN' -Wl,-rpath,'$$ORIGIN/../lib'
else ifeq ($(UNAME_S),Darwin)
LIB_NAME = libkonda.dylib
SHARED_FLAGS = -dynamiclib -Wl,-install_name,@rpath/$(LIB_NAME)
RPATH_FLAGS = -Wl,-rpath,@loader_path -Wl,-rpath,@loader_path/../lib
else
$(error Неподдерживаемая операционная система: $(UNAME_S))
endif

# Разделяемая библиотека: вся логика транспиляции, кроме CLI (основа.c).
LIB = Собранное/$(LIB_NAME)
LIB_SRC = дин_массив.c токенизатор_лексер.c конвейер.c ввод_вывод.c аст.c разбор.c семантика.c владение.c кодоген.c
LIB_OBJ = $(LIB_SRC:.c=.o)

# Исполняемый CLI поверх публичного API библиотеки.
TARGET = Собранное/Транспилятор
CLI_OBJ = основа.o

all: $(TARGET)

test: $(TARGET)
	sh tests/run.sh

# Разделяемая библиотека из библиотечных объектов.
$(LIB): $(LIB_OBJ)
	mkdir -p Собранное
	$(CC) $(SHARED_FLAGS) $(LIB_OBJ) $(LDFLAGS) -o $(LIB)

# CLI ищет libkonda рядом с собой при локальной сборке и в ../lib после установки.
$(TARGET): $(CLI_OBJ) $(LIB)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(CLI_OBJ) -L Собранное -lkonda $(LDFLAGS) $(RPATH_FLAGS) -o $(TARGET)

%.o: %.c транспилятор.h аст.h konda.h владение.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) Собранное/libkonda.so Собранное/libkonda.dylib $(LIB_OBJ) $(CLI_OBJ)

# Установка библиотеки, публичного заголовка и CLI.
PREFIX ?= /usr/local
install: $(TARGET)
	install -d $(PREFIX)/lib $(PREFIX)/include $(PREFIX)/bin
	install -m 644 $(LIB) $(PREFIX)/lib/$(LIB_NAME)
	install -m 644 konda.h транспилятор.h аст.h $(PREFIX)/include/
	install -m 755 $(TARGET) $(PREFIX)/bin/konda
