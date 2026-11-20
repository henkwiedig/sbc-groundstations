/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * artosyn_ge2d - userspace ABI of the Artosyn AR9311 GE2D 2D engine driver.
 *
 * One ioctl runs one job: a destination frame and a list of blits onto it.
 * Every buffer is a dma-buf fd of physically contiguous memory (the mmz
 * dma-heap, vb2-dma-contig decoder frames, DRM GEM-DMA dumb buffers). The
 * call returns once the engine has finished the job.
 *
 * Blits are drawn in order. A blit reads its source rectangle and the
 * destination under it and writes the blend back: with GE2D_BLIT_GLOBAL_ALPHA
 * the blit's alpha (0..255, used as 7 bits) replaces the source's own, else
 * the source's per-pixel alpha is used (straight, not premultiplied). A
 * format without alpha with GE2D_BLIT_GLOBAL_ALPHA and alpha 255 copies.
 */
#ifndef _ARTOSYN_GE2D_H
#define _ARTOSYN_GE2D_H

#include <linux/types.h>
#include <linux/ioctl.h>

/* The engine's own format codes. */
#define GE2D_FMT_ARGB8888	0	/* 32 bit, A in the top byte of the LE word */
#define GE2D_FMT_PACKED16_1	1	/* 16 bit packed, layout per the bench probe */
#define GE2D_FMT_PACKED16_2	2	/* 16 bit packed, layout per the bench probe */
#define GE2D_FMT_I420		3	/* planar Y, U, V (4:2:0) */
#define GE2D_FMT_NV12		4	/* Y plane + interleaved UV plane (4:2:0) */

/* RGB -> YUV matrix and range for a YUV destination. */
#define GE2D_CSC_BT601_LIMITED	0
#define GE2D_CSC_BT601_FULL	1
#define GE2D_CSC_BT709_LIMITED	2
#define GE2D_CSC_BT709_FULL	3

/* A frame: the planes are at offset[] into the dma-buf, rows stride[] bytes
 * apart. Packed formats use plane 0 only, NV12 planes 0 and 1. Strides must
 * be multiples of 8 pixels' worth of bytes (the engine counts in those).
 */
struct ge2d_frame {
	__s32 fd;
	__u32 format;
	__u32 width;
	__u32 height;
	__u32 stride[3];
	__u32 offset[3];
};

#define GE2D_BLIT_GLOBAL_ALPHA	(1u << 0)

struct ge2d_blit {
	struct ge2d_frame src;	/* its width/height bound the source rectangle */
	__u16 src_x, src_y;
	__u16 width, height;
	__u16 dst_x, dst_y;
	__u32 flags;		/* GE2D_BLIT_* */
	__u32 alpha;		/* 0..255, with GE2D_BLIT_GLOBAL_ALPHA */
};

#define GE2D_MAX_BLITS	512

struct ge2d_job {
	struct ge2d_frame dst;	/* GE2D_FMT_I420 */
	__u32 csc;		/* GE2D_CSC_* */
	__u32 n_blits;		/* 1..GE2D_MAX_BLITS */
	__u64 blits;		/* user pointer to struct ge2d_blit[n_blits] */
	__u32 timeout_ms;	/* 0 = the module's default */
	__u32 busy_us;		/* out: engine time from kick to done */
};

#define GE2D_IOC_MAGIC	'G'
#define GE2D_IOC_RUN	_IOWR(GE2D_IOC_MAGIC, 0x01, struct ge2d_job)

#endif /* _ARTOSYN_GE2D_H */
