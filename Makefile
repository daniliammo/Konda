CC ?= cc
UNAME_S := $(shell uname -s)

# ── Требование к компилятору: gcc ≥ 15 или clang ≥ 19 ─────────────────────
# Проект опирается на musttail → ГАРАНТИРОВАННЫЙ TCO (у gcc — только с 15-й
# версии, у clang — давно), а также на полный C23 (-std=gnu23, nullptr).
# Старый компилятор собрал бы БЕЗ гарантии (тихая деградация: глубокая хвостовая
# рекурсия переполнит стек; или не поймёт флаг -std=gnu23) — по решению
# пользователя это ЯВНАЯ ОШИБКА сборки, а не молчаливое ослабление.
# Переопределить компилятор: make CC=gcc-15  или  make CC=clang-19.
CC_ID := $(shell $(CC) --version 2>/dev/null | head -1)
ifeq ($(findstring clang,$(CC_ID)),)
  # gcc: musttail только с 15-й
  CC_MAJ := $(shell $(CC) -dumpversion 2>/dev/null | cut -d. -f1)
  ifneq ($(CC_MAJ),)
    ifeq ($(shell [ "$(CC_MAJ)" -lt 15 ] 2>/dev/null && echo old),old)
      $(error Требуется gcc >= 15 (обнаружен gcc $(CC_MAJ)): нужен musttail для гарантированного TCO. Установите gcc-15 и соберите «make CC=gcc-15», либо используйте clang ≥ 19.)
    endif
  endif
else
  # clang: проверяем версию (нужен полный C23, -std=gnu23)
  CLANG_MAJ := $(shell $(CC) -dumpversion 2>/dev/null | cut -d. -f1)
  ifneq ($(CLANG_MAJ),)
    ifeq ($(shell [ "$(CLANG_MAJ)" -lt 19 ] 2>/dev/null && echo old),old)
      $(error Требуется clang >= 19 (обнаружен clang $(CLANG_MAJ)): нужна полная поддержка C23 (-std=gnu23, nullptr). Установите clang-19 и соберите «make CC=clang-19», либо используйте gcc >= 15.)
    endif
  endif
endif

CFLAGS ?= -Wall -Wextra -O2 -std=gnu23
# Объекты идут в разделяемую библиотеку, поэтому собираем позиционно-независимо.
CFLAGS += -fPIC
# Предупреждения — ОШИБКИ: транспилятор не должен собираться с варнингами (CI
# ловит регрессии сразу). Проверено чистым на gcc-13/14/15 при -O2. Отключаемо
# через «make WERROR=» — на случай нового компилятора с новым классом варнингов
# (тогда чинить варнинг, а не молча жить с ним). Только для сборки самого
# транспилятора (-O2); санитайзер-прогоны в run.sh зовут cc напрямую, без -Werror
# (у них при -O0 есть безобидные -Wformat-truncation, не относящиеся к сборке).
WERROR ?= -Werror
CFLAGS += $(WERROR)
LDFLAGS ?=

ifneq ($(filter $(UNAME_S),Linux FreeBSD OpenBSD),)
	LDFLAGS += -Wl,--gc-sections
	LIB_NAME = libkonda-transpiler.so
	SHARED_FLAGS = -shared
	# При локальной сборке библиотека лежит рядом с CLI; после make install —
	# в ../lib относительно $(PREFIX)/bin/konda.
	RPATH_FLAGS = -Wl,-rpath,'$$ORIGIN' -Wl,-rpath,'$$ORIGIN/../lib'

else ifeq ($(UNAME_S),Darwin)
	LIB_NAME = libkonda-transpiler.dylib
	SHARED_FLAGS = -dynamiclib -Wl,-install_name,@rpath/$(LIB_NAME)
	RPATH_FLAGS = -Wl,-rpath,@loader_path -Wl,-rpath,@loader_path/../lib
else
	$(error Неподдерживаемая операционная система: $(UNAME_S))
endif

# Разделяемая библиотека: вся логика транспиляции, кроме CLI (основа.c).
LIB = Собранное/$(LIB_NAME)
LIB_SRC = дин_массив.c токенизатор_лексер.c конвейер.c ввод_вывод.c аст.c разбор.c обобщения.c семантика.c владение.c кодоген.c заголовки.c интерфейс.c макросы.c libkonda_ide.c
LIB_OBJ = $(LIB_SRC:.c=.o)

# Исполняемый CLI поверх публичного API библиотеки.
TARGET = Собранное/ТранспиляторКонда
CLI_OBJ = основа.o

all: $(TARGET)

test: $(TARGET)
	sh tests/run.sh

# Разделяемая библиотека из библиотечных объектов.
$(LIB): $(LIB_OBJ)
	mkdir -p Собранное
	$(CC) $(SHARED_FLAGS) $(LIB_OBJ) $(LDFLAGS) -o $(LIB)

# CLI ищет libkonda-transpiler рядом с собой при локальной сборке и в ../lib после установки.
$(TARGET): $(CLI_OBJ) $(LIB)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(CLI_OBJ) -L Собранное -lkonda-transpiler $(LDFLAGS) $(RPATH_FLAGS) -o $(TARGET)

%.o: %.c транспилятор.h аст.h konda.h владение.h интерфейс.h макросы.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) Собранное/libkonda-transpiler.so Собранное/libkonda-transpiler.dylib $(LIB_OBJ) $(CLI_OBJ)

# Установка библиотеки, публичного заголовка и CLI.
PREFIX ?= /usr/local
install: $(TARGET)
	install -d $(PREFIX)/lib $(PREFIX)/include $(PREFIX)/bin
	install -m 644 $(LIB) $(PREFIX)/lib/$(LIB_NAME)
	install -m 644 konda.h транспилятор.h аст.h заголовки.h обобщения.h интерфейс.h макросы.h libkonda_ide.h $(PREFIX)/include/
	install -m 755 $(TARGET) $(PREFIX)/bin/konda
