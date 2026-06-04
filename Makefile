CC ?= cc
UNAME_S := $(shell uname -s)

CFLAGS ?= -Wall -Wextra -O2 -std=gnu23
LDFLAGS ?=

ifeq ($(UNAME_S),Linux)
LDFLAGS += -Wl,--gc-sections
endif

TARGET = Собранное/Транспилятор
SRC = основа.c массив_токенов.c токенизатор_лексер.c конвейер.c ввод_вывод.c транспиляция.c
OBJ = $(SRC:.c=.o)

all: $(TARGET)

test: $(TARGET)
	sh tests/run.sh

$(TARGET): $(OBJ)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(OBJ) $(LDFLAGS) -o $(TARGET)

%.o: %.c транспилятор.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJ)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/konda
