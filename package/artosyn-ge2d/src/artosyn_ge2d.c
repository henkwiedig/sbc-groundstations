// SPDX-License-Identifier: GPL-2.0
/*
 * artosyn_ge2d - the Artosyn AR9311 GE2D 2D engine as /dev/ge2d.
 *
 * The engine (0x0881f000) runs a command list from memory: a START block
 * naming the destination frame, then blit commands, then END. A blit reads a
 * source rectangle (ARGB, 16 bit packed or YUV) and blends it onto the
 * destination with its per-pixel alpha or one global alpha, converting RGB to
 * YUV on the way; the vendor's OSD "region" server burns its overlays into
 * video frames this way. The command words, the clock/reset sequence and the
 * kick/done registers were read from the vendor's libmpp_service (ge2d_hw.c,
 * ge2d_server.c) and checked on a BetaFPV VR04.
 *
 * Not a DT driver: the kernel's device tree has no ge2d node, so the module
 * maps the engine itself and creates its own platform device for the dma-buf
 * attachments. Completion is polled (the vendor's IRQ, GIC SPI 79, is not
 * wired up); a small job takes about a millisecond, a full 1080p blend 22 ms.
 *
 * The engine's clock and reset sit in the display subsystem's CRG register
 * (0x0a106018), whose low bits the VO driver owns; this driver only touches
 * bits 16-28 and never the VO's.
 */
#define pr_fmt(fmt) "artosyn_ge2d: " fmt

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

#include "artosyn_ge2d.h"

#define GE2D_PHYS		0x0881f000
#define GE2D_SIZE		0x1000
#define CRG_PHYS		0x0a106000
#define CRG_SIZE		0x1000
#define CRG_DC			0x18

/* CRG_DC bits of the engine (the VO's are 0-2, 9, 10, 12). */
#define CRG_GE2D_B16		BIT(16)
#define CRG_GE2D_CLK		BIT(17)
#define CRG_GE2D_B18		BIT(18)
#define CRG_GE2D_RST_A		BIT(25)
#define CRG_GE2D_RST_B		BIT(26)
#define CRG_GE2D_B28		BIT(28)
#define CRG_GE2D_ON		(CRG_GE2D_CLK | CRG_GE2D_RST_A | CRG_GE2D_RST_B | CRG_GE2D_B28)

#define R_CTRL			0x00	/* bits 6:0 = sub-block resets */
#define R_08			0x08
#define R_STATUS		0x0c	/* bit 1 = frame done (W1C); 0x1fc0 = errors */
#define R_10			0x10
#define R_18			0x18
#define R_CMD_START		0x1c
#define R_CMD_END		0x20
#define R_KICK			0x24	/* the frame id; writing it starts the list */
#define R_2C			0x2c
#define R_30			0x30
#define R_DONE_IDX		0x60
#define R_64			0x64
#define R_68			0x68
#define R_6C			0x6c
#define R_70			0x70
#define R_74			0x74
#define R_78			0x78
#define R_B8			0xb8
#define R_FRAME			0xbc

#define ST_DONE			BIT(1)
#define ST_ERRORS		0x1fc0

#define CMD_START		0xA1FE10A1u
#define CMD_BLIT		0xA30000A3u
#define CMD_END			0xA50001A5u

/* START is 6 words, a planar blit 9, END 1. */
#define CMD_WORDS_MAX		(6 + 9 * GE2D_MAX_BLITS + 1)
#define CMD_BYTES		PAGE_ALIGN(CMD_WORDS_MAX * 4)

static unsigned int timeout_ms = 200;
module_param(timeout_ms, uint, 0644);
MODULE_PARM_DESC(timeout_ms, "default job timeout in ms");

/* Whether R_CMD_END names the list's last word (1) or the address after it (0). */
static unsigned int end_inclusive;
module_param(end_inclusive, uint, 0644);
MODULE_PARM_DESC(end_inclusive, "R_CMD_END = address of the last word (1) or one past it (0)");

struct ge2d_map {
	struct dma_buf *dmabuf;
	struct dma_buf_attachment *attach;
	struct sg_table *sgt;
	dma_addr_t base;
	size_t size;
	u64 stamp;
};

#define CACHE_ENTRIES 24

/* Per open file: the dma-bufs it used, attached and mapped once. */
struct ge2d_client {
	struct ge2d_map ent[CACHE_ENTRIES];
	u64 tick;
};

static struct {
	void __iomem *regs;
	void __iomem *crg;
	struct platform_device *pdev;
	struct device *dev;
	struct mutex lock;	/* the engine, the command list, every client's cache */
	u32 *cmd;
	dma_addr_t cmd_dma;
	u8 frame;
	bool ready;
} g;

static inline u32 rd(u32 off) { return readl(g.regs + off); }
static inline void wr(u32 off, u32 v) { writel(v, g.regs + off); }
static inline void set(u32 off, u32 m) { wr(off, rd(off) | m); }
static inline void clr(u32 off, u32 m) { wr(off, rd(off) & ~m); }

static void crg_set(u32 m) { writel(readl(g.crg + CRG_DC) | m, g.crg + CRG_DC); }
static void crg_clr(u32 m) { writel(readl(g.crg + CRG_DC) & ~m, g.crg + CRG_DC); }

/* The vendor's ge2d_hw power-on and init, in its order. */
static void ge2d_hw_init(void)
{
	crg_clr(CRG_GE2D_B16);
	crg_set(CRG_GE2D_CLK);
	crg_clr(CRG_GE2D_B18);
	crg_set(CRG_GE2D_B28);
	crg_clr(CRG_GE2D_RST_A);
	crg_clr(CRG_GE2D_RST_B);
	usleep_range(2000, 3000);
	crg_set(CRG_GE2D_RST_A);
	crg_set(CRG_GE2D_RST_B);
	usleep_range(2000, 3000);

	wr(R_78, 0x20000000);
	set(R_CTRL, 0x7f);
	usleep_range(2000, 3000);
	clr(R_CTRL, 0x7f);
	wr(R_2C, 0);
	set(R_30, 1);
	clr(R_30, 0xc);
	clr(R_30, 2);
	wr(R_64, 0xffff0000);
	wr(R_68, 0xffff0000);
	wr(R_6C, 0xffff0000);
	wr(R_70, 0xffff0000);
	wr(R_74, 0xf);
	wr(R_B8, 0);
	wr(R_08, rd(R_08) & 0xffff0000);
	set(R_10, 1);
	set(R_18, 1);
	set(R_18, 8);
	wr(R_STATUS, rd(R_STATUS));
	g.ready = true;
}

/* The engine off its clock or held in reset (by anything): bring it up again. */
static void ge2d_hw_check(void)
{
	if (!g.ready || (readl(g.crg + CRG_DC) & CRG_GE2D_ON) != CRG_GE2D_ON) {
		if (g.ready)
			pr_warn("engine lost its clock or reset state, re-initialising\n");
		ge2d_hw_init();
	}
}

static void map_drop(struct ge2d_map *m)
{
	dma_buf_unmap_attachment_unlocked(m->attach, m->sgt, DMA_BIDIRECTIONAL);
	dma_buf_detach(m->dmabuf, m->attach);
	dma_buf_put(m->dmabuf);
	memset(m, 0, sizeof(*m));
}

/* The fd's dma-buf as one DMA segment, from the client's cache or mapped now.
 * Bidirectional for every buffer: a frame is a destination in one job and a
 * source in the next. With g.lock held.
 */
static struct ge2d_map *map_fd(struct ge2d_client *cl, int fd)
{
	struct dma_buf *db = dma_buf_get(fd);
	struct dma_buf_attachment *at;
	struct sg_table *sgt;
	struct ge2d_map *m;
	int i, slot = -1;
	u64 oldest = U64_MAX;

	if (IS_ERR(db))
		return ERR_CAST(db);

	for (i = 0; i < CACHE_ENTRIES; i++) {
		m = &cl->ent[i];
		if (m->dmabuf == db) {
			dma_buf_put(db);
			m->stamp = ++cl->tick;
			return m;
		}
	}
	for (i = 0; i < CACHE_ENTRIES; i++) {
		if (!cl->ent[i].dmabuf) {
			slot = i;
			break;
		}
		if (cl->ent[i].stamp < oldest) {
			oldest = cl->ent[i].stamp;
			slot = i;
		}
	}
	m = &cl->ent[slot];
	if (m->dmabuf)
		map_drop(m);

	at = dma_buf_attach(db, g.dev);
	if (IS_ERR(at)) {
		dma_buf_put(db);
		return ERR_CAST(at);
	}
	sgt = dma_buf_map_attachment_unlocked(at, DMA_BIDIRECTIONAL);
	if (IS_ERR(sgt)) {
		dma_buf_detach(db, at);
		dma_buf_put(db);
		return ERR_CAST(sgt);
	}
	if (sgt->nents != 1) {
		/* The engine takes base addresses, not scatter lists. */
		dma_buf_unmap_attachment_unlocked(at, sgt, DMA_BIDIRECTIONAL);
		dma_buf_detach(db, at);
		dma_buf_put(db);
		return ERR_PTR(-EOPNOTSUPP);
	}
	m->dmabuf = db;
	m->attach = at;
	m->sgt = sgt;
	m->base = sg_dma_address(sgt->sgl);
	m->size = sg_dma_len(sgt->sgl);
	m->stamp = ++cl->tick;
	return m;
}

/* A frame resolved for the command words: plane addresses and the strides
 * in the engine's units (8 pixels).
 */
struct ge2d_resolved {
	u32 addr[3];
	u32 units[2];	/* luma or packed, chroma */
	int planes;
};

static int frame_resolve(struct ge2d_client *cl, const struct ge2d_frame *f,
			 struct ge2d_resolved *r)
{
	struct ge2d_map *m;
	u64 end[3] = {0};
	u32 bpp = 0, cw, ch;
	int i;

	if (!f->width || !f->height || f->width > 4096 || f->height > 4096)
		return -EINVAL;

	cw = DIV_ROUND_UP(f->width, 2);
	ch = DIV_ROUND_UP(f->height, 2);
	switch (f->format) {
	case GE2D_FMT_ARGB8888:
		bpp = 4;
		fallthrough;
	case GE2D_FMT_PACKED16_1:
	case GE2D_FMT_PACKED16_2:
		if (!bpp)
			bpp = 2;
		if (f->stride[0] < f->width * bpp || f->stride[0] % (8 * bpp))
			return -EINVAL;
		r->planes = 1;
		r->units[0] = f->stride[0] / (8 * bpp);
		r->units[1] = 0;
		end[0] = (u64)f->offset[0] + (u64)f->stride[0] * f->height;
		break;
	case GE2D_FMT_I420:
		if (f->stride[0] < f->width || f->stride[0] % 8 ||
		    f->stride[1] != f->stride[2] || f->stride[1] < cw || f->stride[1] % 4)
			return -EINVAL;
		r->planes = 3;
		r->units[0] = f->stride[0] / 8;
		r->units[1] = f->stride[1] / 4;
		end[0] = (u64)f->offset[0] + (u64)f->stride[0] * f->height;
		end[1] = (u64)f->offset[1] + (u64)f->stride[1] * ch;
		end[2] = (u64)f->offset[2] + (u64)f->stride[2] * ch;
		break;
	case GE2D_FMT_NV12:
		if (f->stride[0] < f->width || f->stride[0] % 8 ||
		    f->stride[1] < 2 * cw || f->stride[1] % 8)
			return -EINVAL;
		r->planes = 2;
		r->units[0] = f->stride[0] / 8;
		r->units[1] = f->stride[1] / 8;
		end[0] = (u64)f->offset[0] + (u64)f->stride[0] * f->height;
		end[1] = (u64)f->offset[1] + (u64)f->stride[1] * ch;
		break;
	default:
		return -EINVAL;
	}

	m = map_fd(cl, f->fd);
	if (IS_ERR(m))
		return PTR_ERR(m);
	for (i = 0; i < r->planes; i++) {
		if (end[i] > m->size)
			return -EINVAL;
		r->addr[i] = (u32)(m->base + f->offset[i]);
	}
	return 0;
}

static long ge2d_run(struct ge2d_client *cl, struct ge2d_job *job,
		     const struct ge2d_blit *blits)
{
	struct ge2d_resolved dst, src;
	u32 *w = g.cmd;
	u32 n = 0, i, st, idx;
	ktime_t t0;
	unsigned long deadline;
	int ret;

	if (job->dst.format != GE2D_FMT_I420 || job->csc > 3)
		return -EINVAL;
	ret = frame_resolve(cl, &job->dst, &dst);
	if (ret)
		return ret;

	w[n++] = CMD_START | (job->dst.format << 8) | (job->csc << 15);
	w[n++] = (job->dst.width - 1) | (job->dst.height - 1) << 16;
	w[n++] = dst.units[0] | dst.units[1] << 16;
	w[n++] = dst.addr[0];
	w[n++] = dst.addr[1];
	w[n++] = dst.addr[2];

	for (i = 0; i < job->n_blits; i++) {
		const struct ge2d_blit *b = &blits[i];
		const bool global = b->flags & GE2D_BLIT_GLOBAL_ALPHA;
		int p;

		if (!b->width || !b->height || b->alpha > 255 ||
		    (u32)b->src_x + b->width > b->src.width ||
		    (u32)b->src_y + b->height > b->src.height ||
		    (u32)b->dst_x + b->width > job->dst.width ||
		    (u32)b->dst_y + b->height > job->dst.height)
			return -EINVAL;
		ret = frame_resolve(cl, &b->src, &src);
		if (ret)
			return ret;

		w[n++] = CMD_BLIT | (b->src.format << 8) | (global ? BIT(13) : 0) |
			 ((global ? b->alpha >> 1 : 0) << 17);
		w[n++] = b->dst_x | BIT(13) | (u32)b->dst_y << 16 | job->csc << 29;
		w[n++] = (b->dst_x + b->width - 1) | (u32)(b->dst_y + b->height - 1) << 16;
		w[n++] = ((b->src_x + b->width - 1) & 0xfff) | (u32)(b->src_y + b->height - 1) << 16;
		w[n++] = src.units[0] | src.units[1] << 16;
		w[n++] = b->src_x | (u32)b->src_y << 16;
		for (p = 0; p < src.planes; p++)
			w[n++] = src.addr[p];
	}
	w[n++] = CMD_END;

	ge2d_hw_check();
	wr(R_STATUS, rd(R_STATUS));	/* stale done/error bits */

	idx = g.frame++;
	wr(R_FRAME, (rd(R_FRAME) & ~0x1ffffu) | 0x82u << 8 | idx);
	wmb();
	wr(R_CMD_START, (u32)g.cmd_dma);
	wr(R_CMD_END, (u32)g.cmd_dma + n * 4 - (end_inclusive ? 4 : 0));
	t0 = ktime_get();
	wr(R_KICK, idx);

	deadline = jiffies + msecs_to_jiffies(job->timeout_ms ? job->timeout_ms : timeout_ms);
	for (;;) {
		st = rd(R_STATUS);
		if (st & (ST_DONE | ST_ERRORS))
			break;
		if (time_after(jiffies, deadline)) {
			pr_warn("job %u timed out (status 0x%08x, done idx 0x%02x, %u words)\n",
				idx, st, rd(R_DONE_IDX) & 0xff, n);
			g.ready = false;	/* reset before the next job */
			return -ETIMEDOUT;
		}
		usleep_range(100, 200);
	}
	job->busy_us = (u32)ktime_us_delta(ktime_get(), t0);
	wr(R_STATUS, st);
	if (st & ST_ERRORS) {
		pr_warn_ratelimited("job %u: error status 0x%08x\n", idx, st);
		g.ready = false;
		return -EIO;
	}
	return 0;
}

static long ge2d_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct ge2d_client *cl = f->private_data;
	struct ge2d_blit *blits;
	struct ge2d_job job;
	long ret;

	if (cmd != GE2D_IOC_RUN)
		return -ENOTTY;
	if (copy_from_user(&job, (void __user *)arg, sizeof(job)))
		return -EFAULT;
	if (!job.n_blits || job.n_blits > GE2D_MAX_BLITS)
		return -EINVAL;
	blits = kvmalloc_array(job.n_blits, sizeof(*blits), GFP_KERNEL);
	if (!blits)
		return -ENOMEM;
	if (copy_from_user(blits, u64_to_user_ptr(job.blits), job.n_blits * sizeof(*blits))) {
		kvfree(blits);
		return -EFAULT;
	}

	mutex_lock(&g.lock);
	ret = ge2d_run(cl, &job, blits);
	mutex_unlock(&g.lock);
	kvfree(blits);

	if (!ret && copy_to_user((void __user *)arg, &job, sizeof(job)))
		ret = -EFAULT;
	return ret;
}

static int ge2d_open(struct inode *inode, struct file *f)
{
	struct ge2d_client *cl = kzalloc(sizeof(*cl), GFP_KERNEL);

	if (!cl)
		return -ENOMEM;
	f->private_data = cl;
	return 0;
}

static int ge2d_release(struct inode *inode, struct file *f)
{
	struct ge2d_client *cl = f->private_data;
	int i;

	mutex_lock(&g.lock);
	for (i = 0; i < CACHE_ENTRIES; i++)
		if (cl->ent[i].dmabuf)
			map_drop(&cl->ent[i]);
	mutex_unlock(&g.lock);
	kfree(cl);
	return 0;
}

static const struct file_operations ge2d_fops = {
	.owner		= THIS_MODULE,
	.open		= ge2d_open,
	.release	= ge2d_release,
	.unlocked_ioctl	= ge2d_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
};

static struct miscdevice ge2d_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "ge2d",
	.fops	= &ge2d_fops,
};

static int __init ge2d_init(void)
{
	int ret;

	mutex_init(&g.lock);
	g.regs = ioremap(GE2D_PHYS, GE2D_SIZE);
	/* Shared with the VO driver, which maps the same page. */
	g.crg = ioremap(CRG_PHYS, CRG_SIZE);
	if (!g.regs || !g.crg) {
		ret = -ENOMEM;
		goto err_map;
	}

	g.pdev = platform_device_register_simple("artosyn-ge2d", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(g.pdev)) {
		ret = PTR_ERR(g.pdev);
		goto err_map;
	}
	g.dev = &g.pdev->dev;
	ret = dma_coerce_mask_and_coherent(g.dev, DMA_BIT_MASK(32));
	if (ret)
		goto err_pdev;

	g.cmd = dma_alloc_coherent(g.dev, CMD_BYTES, &g.cmd_dma, GFP_KERNEL);
	if (!g.cmd) {
		ret = -ENOMEM;
		goto err_pdev;
	}

	mutex_lock(&g.lock);
	ge2d_hw_init();
	mutex_unlock(&g.lock);

	ret = misc_register(&ge2d_misc);
	if (ret)
		goto err_cmd;
	pr_info("ready: /dev/ge2d, command list at %pad\n", &g.cmd_dma);
	return 0;

err_cmd:
	dma_free_coherent(g.dev, CMD_BYTES, g.cmd, g.cmd_dma);
err_pdev:
	platform_device_unregister(g.pdev);
err_map:
	if (g.crg)
		iounmap(g.crg);
	if (g.regs)
		iounmap(g.regs);
	return ret;
}

static void __exit ge2d_exit(void)
{
	misc_deregister(&ge2d_misc);
	dma_free_coherent(g.dev, CMD_BYTES, g.cmd, g.cmd_dma);
	platform_device_unregister(g.pdev);
	iounmap(g.crg);
	iounmap(g.regs);
}

module_init(ge2d_init);
module_exit(ge2d_exit);

MODULE_DESCRIPTION("Artosyn AR9311 GE2D 2D engine (blend/blit command lists)");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("DMA_BUF");
