CC = gcc
CFLAGS = -Wall -Wextra -O3 -s -fdata-sections -ffunction-sections -flto -fno-stack-protector -std=gnu23
LDFLAGS = -Wl,--gc-sections
TARGET = Собранное/Транспилятор
SRC = основа.c массив_токенов.c токенизатор_лексер.c конвейер.c ввод_вывод.c
OBJ = $(SRC:.c=.o)

all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(CFLAGS) $(OBJ) $(LDFLAGS) -o $(TARGET)

%.o: %.c транспилятор.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJ)

install: $(TARGET)
	install -D -m 755 $(TARGET) /bin/$(TARGET)
