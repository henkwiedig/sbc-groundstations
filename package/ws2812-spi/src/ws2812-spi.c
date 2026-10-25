// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * ws2812-spi - sets a WS2812/SK6812 LED chain on a spidev to one colour.
 *
 * The chain takes its data line from the SPI master's MOSI: at 6.25 MHz one
 * SPI byte (1.28 us) is one WS2812 bit, 0x80 a "0" (~0.16 us high) and 0xFC
 * a "1" (~0.96 us high), 24 bits per pixel in G, R, B order, MSB first, then
 * 320 low bytes (~410 us) that latch the frame. The same low stretch also
 * goes first, so the chain starts from a reset whatever the line did before
 * (the first run after a cold boot once stayed dark without it). The chain
 * keeps showing the colour after this exits. (The BetaFPV VR04's three-pixel status LED on
 * /dev/spidev0.0: a "0" as long as the vendor's 0xC0 is read as a "1"
 * further down the chain, as MissingLynk found.)
 *
 * usage: ws2812-spi [-d /dev/spidevB.C] [-n pixels] COLOUR
 *   COLOUR: RRGGBB in hex, or off, red, green, blue, orange, white
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/spi/spidev.h>

#define SPEED_HZ	6250000
#define T0		0x80
#define T1		0xFC
#define LATCH		320

static const struct {
	const char *name;
	uint32_t rgb;
} colours[] = {
	{ "off",    0x000000 },
	{ "red",    0xff0000 },
	{ "green",  0x00ff00 },
	{ "blue",   0x0000ff },
	{ "orange", 0xff2800 },	/* stock's: GRB(40,255,0) */
	{ "white",  0xffffff },
};

static int parse_colour(const char *s, uint32_t *rgb)
{
	char *end;

	for (size_t i = 0; i < sizeof(colours) / sizeof(colours[0]); i++) {
		if (!strcasecmp(s, colours[i].name)) {
			*rgb = colours[i].rgb;
			return 0;
		}
	}
	if (strlen(s) != 6)
		return -1;
	*rgb = strtoul(s, &end, 16);
	return *end ? -1 : 0;
}

static void usage(void)
{
	fprintf(stderr, "usage: ws2812-spi [-d /dev/spidevB.C] [-n pixels] RRGGBB|off|red|green|blue|orange|white\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/spidev0.0";
	int pixels = 3, opt, fd;
	uint32_t rgb;

	while ((opt = getopt(argc, argv, "d:n:")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 'n': pixels = atoi(optarg); break;
		default: usage();
		}
	}
	if (optind != argc - 1 || pixels < 1 || pixels > 64 || parse_colour(argv[optind], &rgb))
		usage();

	const size_t len = LATCH + (size_t)pixels * 24 + LATCH;
	uint8_t *frame = calloc(1, len);
	const uint8_t grb[3] = { (rgb >> 8) & 0xff, (rgb >> 16) & 0xff, rgb & 0xff };
	uint8_t *p = frame + LATCH;

	if (!frame)
		return 1;
	for (int i = 0; i < pixels; i++)
		for (int c = 0; c < 3; c++)
			for (int bit = 7; bit >= 0; bit--)
				*p++ = (grb[c] >> bit) & 1 ? T1 : T0;

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "ws2812-spi: %s: %s\n", dev, strerror(errno));
		return 1;
	}
	uint8_t mode = SPI_MODE_0, bits = 8;
	uint32_t speed = SPEED_HZ;
	struct spi_ioc_transfer tr = {
		.tx_buf = (unsigned long)frame,
		.len = len,
		.speed_hz = SPEED_HZ,
		.bits_per_word = 8,
	};
	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 || ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
	    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0 || ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0) {
		fprintf(stderr, "ws2812-spi: %s: %s\n", dev, strerror(errno));
		return 1;
	}
	close(fd);
	free(frame);
	return 0;
}
