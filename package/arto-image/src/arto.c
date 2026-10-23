/*
 * arto - read Artosyn "ARTO" update images: the stock firmware container of
 * the BetaFPV P1 (Artosyn PROXIMA 9311), and OpenIPC images built in the same
 * layout (customer version "OpenIPC").
 *
 *   arto info IMAGE        header, partitions, segments, hash
 *   arto check IMAGE       exit 0 if the structure is sound and the SHA-256 matches
 *   arto parts IMAGE       one line per partition the image carries data for:
 *                          name flash_offset partition_size data_length
 *   arto cat IMAGE NAME    that partition's data on stdout, decompressed; from
 *                          the partition's start to its last segment's end,
 *                          gaps 0xff. NAME "loader" is the loader (SPL) area.
 *
 * Layout, little endian (reversed from the stock U-Boot's do_upgrade and the
 * images themselves):
 *
 *   0x000 u32 magic 0x4152544f ("OTRA" in the file)
 *   0x004 u8  header version        0x005 u8  compressed (segments LZO1X)
 *   0x006 u8  flash type (2 = NAND) 0x007 u8  partition status
 *   0x008 u16 header extension size 0x00a u16 hash size (0x20, SHA-256)
 *   0x00c u16 signature size (0x100, RSA-2048)
 *   0x00e u16 signature's real size
 *   0x010 u64 size of everything after the signature
 *   0x018 u32 rom size              0x01c u32 loader size
 *   0x020 u16 partitions            0x022 u16 segments
 *   0x024 u32 object version        0x028 u32 dependency version
 *   0x02c     customer version (to 0x040), 0x080 SDK version (product)
 *   0x100 + header extension: SHA-256 of everything after the signature,
 *         then the signature
 *   then the rom, the loader, the partition table (0x34 bytes each: name[32],
 *   u64 flash offset, u64 size, u32 flags), the segment table (0x20 bytes
 *   each: u64 file offset, u64 flash offset, u64 stored size, u64 size) and
 *   the segment data.
 *
 * The signature is not checked here (the keys live in the stock U-Boot); the
 * hash guards the content. Built by package/arto-image.
 */

#include <errno.h>
#include <fcntl.h>
#include <lzo/lzo1x.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAGIC 0x4152544f
#define BASE_HDR 0x100
#define PART_ENTRY 0x34
#define SEG_ENTRY 0x20
#define MAX_SEG_SIZE (64u << 20)

struct part {
	char name[33];
	uint64_t off, size;
	uint32_t flags;
};

struct seg {
	uint64_t file_off, flash_off, stored, size;
};

struct image {
	int fd;
	uint64_t file_size;
	unsigned char hdr[BASE_HDR];
	int compressed, flash_type;
	unsigned hext, hash_size, sig_size, nparts, nsegs;
	uint64_t body_off, rom_size, loader_off, loader_size;
	struct part *parts;
	struct seg *segs;
};

static uint16_t le16(const unsigned char *p) { return p[0] | p[1] << 8; }
static uint32_t le32(const unsigned char *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }
static uint64_t le64(const unsigned char *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }

/* ---------------------------------------------------------------- SHA-256 */

struct sha256 {
	uint32_t h[8];
	uint64_t len;
	unsigned char buf[64];
	size_t fill;
};

static const uint32_t K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) ((x) >> (n) | (x) << (32 - (n)))

static void sha256_block(struct sha256 *s, const unsigned char *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
	for (; i < 64; i++)
		w[i] = (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ w[i - 2] >> 10) + w[i - 7] +
		       (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ w[i - 15] >> 3) + w[i - 16];
	a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3];
	e = s->h[4], f = s->h[5], g = s->h[6], h = s->h[7];
	for (i = 0; i < 64; i++) {
		t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
		t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		h = g, g = f, f = e, e = d + t1, d = c, c = b, b = a, a = t1 + t2;
	}
	s->h[0] += a, s->h[1] += b, s->h[2] += c, s->h[3] += d;
	s->h[4] += e, s->h[5] += f, s->h[6] += g, s->h[7] += h;
}

static void sha256_init(struct sha256 *s)
{
	static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
					0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	memcpy(s->h, iv, sizeof(iv));
	s->len = 0;
	s->fill = 0;
}

static void sha256_update(struct sha256 *s, const unsigned char *p, size_t n)
{
	s->len += n;
	while (n) {
		size_t take = 64 - s->fill < n ? 64 - s->fill : n;

		memcpy(s->buf + s->fill, p, take);
		s->fill += take, p += take, n -= take;
		if (s->fill == 64) {
			sha256_block(s, s->buf);
			s->fill = 0;
		}
	}
}

static void sha256_final(struct sha256 *s, unsigned char out[32])
{
	uint64_t bits = s->len * 8;
	unsigned char pad = 0x80, zero = 0, len[8];
	int i;

	sha256_update(s, &pad, 1);
	while (s->fill != 56)
		sha256_update(s, &zero, 1);
	for (i = 0; i < 8; i++)
		len[i] = bits >> (56 - 8 * i);
	sha256_update(s, len, 8);
	for (i = 0; i < 8; i++) {
		out[4 * i] = s->h[i] >> 24;
		out[4 * i + 1] = s->h[i] >> 16;
		out[4 * i + 2] = s->h[i] >> 8;
		out[4 * i + 3] = s->h[i];
	}
}

/* ---------------------------------------------------------------- image */

static int fail(const char *msg)
{
	fprintf(stderr, "arto: %s\n", msg);
	return -1;
}

static int read_at(int fd, void *buf, size_t n, uint64_t off)
{
	size_t done = 0;

	while (done < n) {
		ssize_t r = pread(fd, (char *)buf + done, n - done, off + done);

		if (r <= 0)
			return -1;
		done += r;
	}
	return 0;
}

/* Opens and parses IMAGE; checks that every table and segment lies in the file. */
static int image_open(struct image *im, const char *path)
{
	unsigned char *tab;
	struct stat st;
	uint64_t ptab, stab;
	unsigned i;

	memset(im, 0, sizeof(*im));
	im->fd = open(path, O_RDONLY);
	if (im->fd < 0 || fstat(im->fd, &st) < 0) {
		fprintf(stderr, "arto: %s: %s\n", path, strerror(errno));
		return -1;
	}
	im->file_size = st.st_size;
	if (read_at(im->fd, im->hdr, BASE_HDR, 0) < 0 || le32(im->hdr) != MAGIC)
		return fail("not an ARTO image");
	im->compressed = im->hdr[5];
	im->flash_type = im->hdr[6];
	im->hext = le16(im->hdr + 8);
	im->hash_size = le16(im->hdr + 0x0a);
	im->sig_size = le16(im->hdr + 0x0c);
	im->rom_size = le32(im->hdr + 0x18);
	im->loader_size = le32(im->hdr + 0x1c);
	im->nparts = le16(im->hdr + 0x20);
	im->nsegs = le16(im->hdr + 0x22);
	if (im->hash_size != 32 || im->nparts == 0 || im->nparts > 64 || im->nsegs > 256)
		return fail("implausible header");
	im->body_off = BASE_HDR + im->hext + im->hash_size + im->sig_size;
	if (le64(im->hdr + 0x10) != im->file_size - im->body_off)
		return fail("size in the header does not match the file (truncated?)");
	im->loader_off = im->body_off + im->rom_size;
	ptab = im->loader_off + im->loader_size;
	stab = ptab + (uint64_t)im->nparts * PART_ENTRY;
	if (stab + (uint64_t)im->nsegs * SEG_ENTRY > im->file_size)
		return fail("tables run past the end of the file");

	im->parts = calloc(im->nparts, sizeof(*im->parts));
	im->segs = calloc(im->nsegs ? im->nsegs : 1, sizeof(*im->segs));
	tab = malloc(im->nparts * PART_ENTRY + im->nsegs * SEG_ENTRY);
	if (!im->parts || !im->segs || !tab)
		return fail("out of memory");
	if (read_at(im->fd, tab, im->nparts * PART_ENTRY + im->nsegs * SEG_ENTRY, ptab) < 0)
		return fail("cannot read the tables");
	for (i = 0; i < im->nparts; i++) {
		const unsigned char *e = tab + i * PART_ENTRY;

		memcpy(im->parts[i].name, e, 32);
		im->parts[i].off = le64(e + 0x20);
		im->parts[i].size = le64(e + 0x28);
		im->parts[i].flags = le32(e + 0x30);
	}
	for (i = 0; i < im->nsegs; i++) {
		const unsigned char *e = tab + im->nparts * PART_ENTRY + i * SEG_ENTRY;
		struct seg *s = &im->segs[i];

		s->file_off = le64(e);
		s->flash_off = le64(e + 8);
		s->stored = le64(e + 0x10);
		s->size = le64(e + 0x18);
		if (s->file_off < stab + (uint64_t)im->nsegs * SEG_ENTRY ||
		    s->file_off + s->stored > im->file_size || s->size > MAX_SEG_SIZE ||
		    (!im->compressed && s->stored != s->size)) {
			free(tab);
			return fail("a segment lies outside the file or is implausible");
		}
	}
	free(tab);
	return 0;
}

/* The partition a segment belongs to, or NULL. */
static const struct part *seg_part(const struct image *im, const struct seg *s)
{
	unsigned i;

	for (i = 0; i < im->nparts; i++) {
		const struct part *p = &im->parts[i];

		if (s->flash_off >= p->off && s->flash_off + s->size <= p->off + p->size)
			return p;
	}
	return NULL;
}

static int hash_ok(const struct image *im)
{
	unsigned char want[32], got[32], *buf = malloc(1 << 20);
	struct sha256 s;
	uint64_t off;

	if (!buf || read_at(im->fd, want, 32, BASE_HDR + im->hext) < 0) {
		free(buf);
		return 0;
	}
	sha256_init(&s);
	for (off = im->body_off; off < im->file_size;) {
		size_t n = im->file_size - off < (1 << 20) ? im->file_size - off : (1 << 20);

		if (read_at(im->fd, buf, n, off) < 0) {
			free(buf);
			return 0;
		}
		sha256_update(&s, buf, n);
		off += n;
	}
	free(buf);
	sha256_final(&s, got);
	return memcmp(want, got, 32) == 0;
}

static int signed_image(const struct image *im)
{
	unsigned char sig[256];
	unsigned i;

	if (im->sig_size != sizeof(sig) ||
	    read_at(im->fd, sig, sizeof(sig), BASE_HDR + im->hext + im->hash_size) < 0)
		return 0;
	for (i = 0; i < sizeof(sig); i++)
		if (sig[i])
			return 1;
	return 0;
}

static void field(const struct image *im, unsigned off, unsigned len, char *out)
{
	memcpy(out, im->hdr + off, len);
	out[len] = 0;
}

/* ---------------------------------------------------------------- commands */

static int cmd_info(struct image *im)
{
	char customer[21], product[65];
	unsigned i;

	field(im, 0x2c, 20, customer);
	field(im, 0x80, 64, product);
	printf("product %s, customer version %s, object version %#x, dependency %#x\n", product,
	       customer, le32(im->hdr + 0x24), le32(im->hdr + 0x28));
	printf("flash type %d, segments %s, loader %llu bytes, rom %llu bytes\n", im->flash_type,
	       im->compressed ? "LZO1X" : "raw", (unsigned long long)im->loader_size,
	       (unsigned long long)im->rom_size);
	printf("hash %s, %s\n", hash_ok(im) ? "ok" : "MISMATCH", signed_image(im) ? "signed" : "unsigned");
	for (i = 0; i < im->nparts; i++)
		printf("  part %-10s %#010llx %#09llx flags %#x\n", im->parts[i].name,
		       (unsigned long long)im->parts[i].off, (unsigned long long)im->parts[i].size,
		       im->parts[i].flags);
	for (i = 0; i < im->nsegs; i++) {
		const struct part *p = seg_part(im, &im->segs[i]);

		printf("  seg  %-10s %#010llx %#09llx (stored %#llx)\n", p ? p->name : "?",
		       (unsigned long long)im->segs[i].flash_off, (unsigned long long)im->segs[i].size,
		       (unsigned long long)im->segs[i].stored);
	}
	return 0;
}

static int cmd_check(struct image *im)
{
	unsigned i;

	for (i = 0; i < im->nsegs; i++)
		if (!seg_part(im, &im->segs[i]))
			return fail("a segment lies outside every partition");
	if (!hash_ok(im))
		return fail("SHA-256 mismatch");
	return 0;
}

/* Data length the image carries for p: its last segment's end, 0 if none. */
static uint64_t part_data_len(const struct image *im, const struct part *p)
{
	uint64_t end = 0;
	unsigned i;

	for (i = 0; i < im->nsegs; i++)
		if (seg_part(im, &im->segs[i]) == p && im->segs[i].flash_off + im->segs[i].size - p->off > end)
			end = im->segs[i].flash_off + im->segs[i].size - p->off;
	return end;
}

static int cmd_parts(struct image *im)
{
	unsigned i;

	if (im->loader_size)
		printf("loader 0 %llu %llu\n", (unsigned long long)im->loader_size,
		       (unsigned long long)im->loader_size);
	for (i = 0; i < im->nparts; i++) {
		uint64_t len = part_data_len(im, &im->parts[i]);

		if (len)
			printf("%s %llu %llu %llu\n", im->parts[i].name, (unsigned long long)im->parts[i].off,
			       (unsigned long long)im->parts[i].size, (unsigned long long)len);
	}
	return 0;
}

static int write_all(const void *buf, size_t n)
{
	const char *p = buf;

	while (n) {
		ssize_t w = write(1, p, n);

		if (w <= 0)
			return -1;
		p += w, n -= w;
	}
	return 0;
}

static int write_ff(uint64_t n)
{
	unsigned char ff[4096];

	memset(ff, 0xff, sizeof(ff));
	while (n) {
		size_t k = n < sizeof(ff) ? n : sizeof(ff);

		if (write_all(ff, k) < 0)
			return -1;
		n -= k;
	}
	return 0;
}

static int cat_range(struct image *im, uint64_t off, uint64_t n)
{
	unsigned char *buf = malloc(1 << 20);

	if (!buf)
		return fail("out of memory");
	while (n) {
		size_t k = n < (1 << 20) ? n : (1 << 20);

		if (read_at(im->fd, buf, k, off) < 0 || write_all(buf, k) < 0) {
			free(buf);
			return fail("cannot copy");
		}
		off += k, n -= k;
	}
	free(buf);
	return 0;
}

static int cmd_cat(struct image *im, const char *name)
{
	const struct part *p = NULL;
	uint64_t pos = 0;
	unsigned i, done = 0;

	if (strcmp(name, "loader") == 0)
		return cat_range(im, im->loader_off, im->loader_size);
	for (i = 0; i < im->nparts; i++)
		if (strcmp(im->parts[i].name, name) == 0)
			p = &im->parts[i];
	if (!p)
		return fail("no such partition in the image");

	/* Segments of p in flash order (the tables list them that way; checked). */
	while (done < im->nsegs) {
		const struct seg *s = NULL;
		unsigned char *in, *out;
		lzo_uint out_len;

		for (i = 0; i < im->nsegs; i++)
			if (seg_part(im, &im->segs[i]) == p && im->segs[i].flash_off - p->off >= pos &&
			    (!s || im->segs[i].flash_off < s->flash_off))
				s = &im->segs[i];
		if (!s)
			break;
		done++;
		if (write_ff(s->flash_off - p->off - pos) < 0)
			return fail("cannot write");
		pos = s->flash_off - p->off;
		if (!im->compressed) {
			if (cat_range(im, s->file_off, s->size) < 0)
				return -1;
			pos += s->size;
			continue;
		}
		in = malloc(s->stored);
		out = malloc(s->size);
		if (!in || !out)
			return fail("out of memory");
		out_len = s->size;
		if (read_at(im->fd, in, s->stored, s->file_off) < 0 ||
		    lzo1x_decompress_safe(in, s->stored, out, &out_len, NULL) != LZO_E_OK ||
		    out_len != s->size) {
			free(in);
			free(out);
			return fail("a segment does not decompress");
		}
		if (write_all(out, out_len) < 0) {
			free(in);
			free(out);
			return fail("cannot write");
		}
		free(in);
		free(out);
		pos += s->size;
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct image im;

	if (argc < 3 || (strcmp(argv[1], "cat") == 0 && argc != 4)) {
		fprintf(stderr, "usage: arto {info|check|parts} IMAGE | arto cat IMAGE PARTITION\n");
		return 2;
	}
	if (lzo_init() != LZO_E_OK || image_open(&im, argv[2]) < 0)
		return 1;
	if (strcmp(argv[1], "info") == 0)
		return cmd_info(&im) ? 1 : 0;
	if (strcmp(argv[1], "check") == 0)
		return cmd_check(&im) ? 1 : 0;
	if (strcmp(argv[1], "parts") == 0)
		return cmd_parts(&im) ? 1 : 0;
	if (strcmp(argv[1], "cat") == 0)
		return cmd_cat(&im, argv[3]) ? 1 : 0;
	fprintf(stderr, "arto: unknown command %s\n", argv[1]);
	return 2;
}
