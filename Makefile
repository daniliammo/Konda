CC ?= cc
UNAME_S := $(shell uname -s)

CFLAGS ?= -Wall -Wextra -O2 -std=gnu23
LDFLAGS ?=

ifeq ($(UNAME_S),Linux)
LDFLAGS += -Wl,--gc-sections
endif

TARGET = Собранное/Транспилятор
SRC = основа.c дин_массив.c токенизатор_лексер.c конвейер.c ввод_вывод.c аст.c разбор.c семантика.c кодоген.c
OBJ = $(SRC:.c=.o)

all: $(TARGET)

test: $(TARGET)
	sh tests/run.sh

$(TARGET): $(OBJ)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(OBJ) $(LDFLAGS) -o $(TARGET)

%.o: %.c транспилятор.h аст.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJ)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/konda
