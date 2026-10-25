CFLAGS ?= -O2
CFLAGS += -Wall -Wextra

ws2812-spi: ws2812-spi.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f ws2812-spi
