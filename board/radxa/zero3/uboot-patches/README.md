# U-Boot patches for Radxa Zero 3 based boards

Applied by buildroot on top of mainline U-Boot (`BR2_TARGET_UBOOT_PATCH`,
currently U-Boot 2025.07).

## 0001 — local patch

`0001-select-dtb-based-on-board-models.patch` is our own patch (DTB selection
by board model). Not upstream, keep indefinitely.

## 0002 – 0013 — Rockchip VOP2 display support (out-of-tree upstream series)

These twelve patches are the **"Rockchip VOP2 support" v6 series by
Dang Huynh** (plus two patches by Ondrej Jirman), taken unmodified from the
U-Boot mailing list. They add the VOP2 display controller driver and RK3568
HDMI support that mainline U-Boot is still missing for RK3566/RK3568 — this
is what gives us a framebuffer/vidconsole (splash + boot menu) in U-Boot on
the Zero 3W.

- Patchwork series (v6, 2025-11-08):
  <https://patchwork.ozlabs.org/project/uboot/list/?series=481393>
- Series mbox (what these files were generated from, mail headers stripped):
  <http://patchwork.ozlabs.org/series/481393/mbox/>
- Cover letter on lore:
  <https://lore.kernel.org/u-boot/20251108-vop2-pt2-v6-0-d04c699262fb@mainlining.org/>

| Patch | Content |
|-------|---------|
| 0002–0005 | dw-mipi-dsi preparation (VIDEO_BRIDGE dependency, pixel clock, external PHY, get_display_timing) |
| 0006 | BOE TH101MB31IG002-28A MIPI-DSI panel (PineTab2, unused by us) |
| 0007 | **video: rockchip: Add VOP2 support** (rk_vop2.c, rk3568_vop.c) |
| 0008 | VOP2 video bridge support |
| 0009 | rk356x DT: prerelocate VOP in U-Boot proper |
| 0010 | quartz64 defconfig: enable vidconsole (upstream board, kept for series integrity) |
| 0011 | **video: rockchip: Add HDMI support for RK3568** (rk3568_hdmi.c) |
| 0012 | pinetab2 defconfig: enable video + USB keyboard (upstream board, kept for series integrity) |
| 0013 | clk rk3568: use assigned VPLL clock when possible (HDMI pixel clock) |

Status when imported (2026-07): **not merged** — patchwork state "new",
delegated to Kever Yang (Rockchip custodian). v1 was posted 2025-01, v6 is
from 2025-11/12. Applies to 2025.07 with small offsets only.

### Tracking mainline

- Check whether `drivers/video/rockchip/rk_vop2.c` exists in
  <https://github.com/u-boot/u-boot/tree/master/drivers/video/rockchip>
- Series state: patchwork link above (state changes to "Accepted" on merge)
- Newer revisions (v7+): search <https://lore.kernel.org/u-boot/?q=VOP2>

### When the series lands in mainline

Once buildroot's U-Boot version contains VOP2 support: delete `0002-*` …
`0013-*` from this directory and rebuild; keep `0001` and `uboot.fragment`
(the fragment options — VIDEO, VIDEO_ROCKCHIP, DISPLAY_ROCKCHIP_HDMI,
VIDEO_REMOVE, BMP/CMD_BMP/CMD_CLS, CONSOLE_MUX, SYS_CONSOLE_IS_IN_ENV,
PREBOOT — stay valid; only verify the Kconfig symbol names didn't change in
the merged version).
