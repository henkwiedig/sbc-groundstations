CC ?= gcc
CFLAGS ?= -O2
LDFLAGS ?=

all: openipc-bsel

openipc-bsel: openipc-bsel.c
	$(CC) $(CFLAGS) -static -o $@ $< $(LDFLAGS)

clean:
	rm -f openipc-bsel

.PHONY: all clean
