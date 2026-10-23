CC ?= gcc
CFLAGS ?= -O2
LDFLAGS ?=

all: arto

arto: arto.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -llzo2

clean:
	rm -f arto

.PHONY: all clean
