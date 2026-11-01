# BetaFPV P1 HD VRX (betafpv_p1_vrx)

The P1 system's box receiver: the VR04 goggles' board (Artosyn PROXIMA 9311,
AR8030 on SDIO, 128 MiB SPI-NAND, SD card, button ladder, 3 WS2812 LEDs,
buzzer) with HDMI out instead of the panel: a Lontium LT9611EX MIPI-DSI ->
HDMI bridge on the same DSI output. Stock runs one image on both (P1_GND
2.1.x; hw_ver V2.3 "haming_vrx_gnd"), with the same device tree. Everything
but the display is the VR04's and lives in `board/betafpv/p1-gnd/` (see the
VR04's README for the flash layout, slots, SD-card update, USB upgrade and
recovery; the host scripts there work for both units).

**State: built, never run on a VRX.** The display path is written from
stock's code and register values (below), and the VRX's userspace and the
bridge driver's no-chip path can be tried on a VR04 (RAM boot). The first
VRX to run it decides the rest; the image is made so that a VRX without
picture is still reachable and goes back to stock from the SD card.

## This directory

- `device.env`: dtb, file names (`p1-vrx-*`), update image tag (`-VRX`),
  display modules, for p1-gnd's post-build/post-image
- `dts/artosyn/proxima-9311-vrx.dts`: ml-kernel's goggle DT minus panel,
  backlight and the GPIO 107 strap hog, plus the bridge on i2c0 (0x41,
  reset GPIO 107 active low, HPD GPIO 67) and `artosyn,timing-from-mode` on
  the VO and DSI nodes
- `linux-patches/` (on ml-kernel's display drivers):
  - 0001 artosyn_vo: timing words from the (adjusted) mode; the pixel clock
    corrected for the CGU model's 1.034654 (`pclk_hz` then speaks true Hz of
    the mode userspace set)
  - 0002 artosyn_dsi: DSI line timing, lane rate and MIPI TX PLL from the
    mode, stock's D-PHY blocks for the LT9611EX's lane rates
  - 0003 lontium-lt9611ex: the bridge driver (EDID modes, stock's DSI-side
    timing per HDMI mode)
- `overlay/`: `/etc/default/p1-gnd` (USB name "BetaFPV P1 HD VRX", stock
  product P1_GND_VRX, display modules, no backlight), update screens
  ("receiver"), `/usr/sbin/p1-vrx-diag`
- `host/80-betafpv-p1-vrx.rules`: names the USB network `vrx-gnd0` on a
  Linux host

Build: `DEFCONFIG=betafpv_p1_vrx_defconfig ./build.sh` -> in
`output/betafpv_p1_vrx_defconfig/images/`:
`P1_GND_<stock release>_OpenIPC-VRX_<sha>.img` (the update image),
`betafpv_p1_vrx.tar.gz` (the release archive), `p1-vrx-testboot/` (RAM boot).

## The display chain

VO (artosyn_vo) -> DSI host (artosyn_dsi + mainline dw-mipi-dsi) ->
LT9611EX -> HDMI. The LT9611EX runs its own firmware: it measures the DSI
video, matches it to a standard HDMI mode and outputs that. From stock's
libpn_lt9611ex.so (2.1.4):

- I2C 7-bit 0x41 on `/dev/i2c-0`, plain 8-bit registers, 0xFF the page. Chip
  ID: 0xFF=0x80, 0xEE=0x01, 0xFF=0xE1, read 0x00/0x01.
- Mailbox on page 0xE0: 0xDE=1, wait 0xAE==1, five command bytes into
  0xB0..0xB4, 0xDE=2, wait 0xAE==2, reply from 0x85. `WH1:E`/`WH1:D` output
  on/off, `WH2:H`/`WH2:D` HDMI/DVI, `RH1:` HPD state, `RH2:`/`RH3:` EDID.
- Stock's VRX 2.0.8 opened a disabled I2C bus, so the chip shows a picture
  without I2C too; the driver carries on without it.
- The SoC does not send the HDMI timing but stock's DSI-side timing for it:
  the same active size and frame rate, longer horizontal blanking. 1080p60:
  VO hfp 117 / hsync 59 / hbp 197 (htotal 2293), vfp 4 / vsync 5 / vbp 36
  (vtotal 1125), 154.7775 MHz; DSI hsa 44 / hbp 148 / line 1720 byte clocks
  at 928.8 Mbps per lane, 4 lanes RGB888. The DSI registers including the
  D-PHY block are stock's own: libmpp_service.so's dsi_set_timing() run
  under qemu-aarch64 with the LT9611EX's attrs (with the VR04 panel's attr
  the same run reproduces the values captured from the VR04's hardware word
  for word).

## Screen modes

As on the other PixelPilot targets: the connector (HDMI-A-1) lists the
sink's modes, read from its EDID through the bridge's mailbox whenever
userspace probes it, with the sink's preferred mode marked; PixelPilot takes
its `--screen-mode` (PIXELPILOT_SCREEN_MODE, the menu) when the list has it,
else the preferred one. Listed are the modes this chain drives:

| HDMI mode | DSI side (stock) | pixel clock | now |
|---|---|---|---|
| 1920x1080@60 | 2293x1125, 928.8 Mbps | 154.78 MHz | yes |
| 1920x1080@50 | 2880x1125, 972 Mbps | 162.0 MHz | no |
| 1280x720@60 | 1772x750, 478.44 Mbps | 79.74 MHz | no |
| 1280x720@50 | 2212x750, 498 Mbps | 82.95 MHz | no |
| 1920x1080@30 | 2293x1125, 464.4 Mbps | 77.39 MHz | no |

The bridge puts the DSI-side timing of the chosen mode into the adjusted
mode, the VO and DSI host scan that, the chip outputs the HDMI mode (59.94
and 60 Hz variants both map to the 60 Hz row, at their own rate). A mode is
listed when the VO's pixel clock reaches its rate: ml-kernel's CGU driver
keeps the pixel PLL within +-5 % of its boot rate (~141-156 MHz true), so
today that is 1080p60 only; the other rows (and their D-PHY sets) are there
for when the clock goes further (stock clocks them from the MIPI TX PLL).
The VO's video planes do not scale: 1080p video on a 720p mode would show
a 1280x720 cut of it. When the sink's preferred mode is not drivable the
first drivable row becomes the preferred one; with no EDID (no sink at boot,
no I2C answer) the list is the drivable rows, 1080p60 preferred. The
connector stays "connected" (PixelPilot needs that; the chip follows the
sink's hot plug itself): a sink plugged in later gets its modes at the next
probe (PixelPilot restart).

## First install (stock VRX)

1. The VRX on stock **2.1.x** (2.0.8 has another SPL and vendor partition;
   update it with BetaFPV's stock 2.1.4 first).
2. `P1_GND_<release>_OpenIPC-VRX_<sha>.img` into the root of a FAT/exFAT SD
   card, card into the VRX, the update in stock's menu (on the HDMI output).
   Stock writes the other slot and restarts into OpenIPC. (The name keeps
   BetaFPV's `P1_GND_v` prefix, which the VR04's stock menu took; the VRX's
   stock menu is untried.)
3. OpenIPC comes up whether or not HDMI shows a picture:
   - LED: slow green blink = searching for the air unit, solid green =
     connected (pairing as on the VR04: bind button or
     `curl -X POST http://192.168.3.100:8899/api/v1/pair`)
   - USB to a PC: a network device "BetaFPV P1 HD VRX" (RNDIS, Windows binds
     it without a driver), the PC gets an address by DHCP, the VRX is
     **192.168.3.100**, `ssh root@192.168.3.100`, password `12345`

## When there is no picture

    ssh root@192.168.3.100 p1-vrx-diag > vrx-diag.tar.gz

(or `p1-vrx-diag -o /media/dvr` onto the SD card) collects the kernel log,
DRM state, the bridge's I2C answer, `i2cdetect` of bus 0, GPIOs, the VO/DSI
registers, the pixel clock and the vsync rate. The bridge at
`/sys/bus/i2c/devices/0-0041/`: `chip_id`, `i2c_ok`, `hpd` (GPIO 67 and
`RH1:`'s reply), `mailbox` (`echo WH1:E > mailbox; cat mailbox`), `reset`
(`echo 1 > reset`).

Knobs, as module options in `/etc/modprobe.d/p1-vrx-test.conf`, then a power
cycle (not `reboot`: the SPL can hang after a warm reset):

    options lontium_lt9611ex skip_i2c=1      # never touch the chip's I2C
    options lontium_lt9611ex use_edid=0      # the table's modes, not the sink's
    options lontium_lt9611ex hdmi_mode=0     # DVI instead of HDMI
    options lontium_lt9611ex reset_ms=1000   # longer wait after reset
    options lontium_lt9611ex dsi_mode=1      # DSI sync pulses instead of events (2: burst)
    options artosyn_vo pclk_scale_ppm=1000000 # pixel clock as the CGU model says

`modprobe.blacklist=lontium_lt9611ex` (U-Boot `bootargs`, or a RAM boot's
`--args`) keeps the bridge driver out.

## Back to stock

Stock's `P1_GND_v<release>.img` (2.1.x) into the root of the SD card, power
on: OpenIPC installs it into the other slot before it starts (one beep, two
when done, a long one when it failed: `sysupgrade.log` on the card), no
picture needed. Or over SSH: `openipc-bsel switch`, then a power cycle (the
previous slot, stock after a first install). Without either: the stock
U-Boot's USB upgrade (`../p1-gnd/scripts/vr04-usbburn.py`, VR04 README).

An OpenIPC image carries its unit's device tree: sysupgrade (SD card or
`--image`) refuses the VR04's on a VRX and the other way round
(`--any-device` flashes it anyway).

## Open

- I2C bus 0 for the bridge (stock 2.1.4; 2.0.8 said bus 3) and its
  autonomous mode are read from stock's code, not seen.
- GPIO 107 (reset, active low) and 67 (HPD) likewise.
- Whether the bridge locks to this DSI timing and keeps the picture under
  the vsync lock's +-1000 ppm pixel clock trims (`--vsync-lock` is on, as on
  the VR04).
- The pixel clock: 154.7775 MHz true = 160.14 MHz in the CGU model, close
  to the top of its +-5 % band around the boot rate (161.3 MHz). The other
  modes need the CGU driver to go further (another divider tap or stock's
  MIPI TX PLL source); that can be tried on a VR04 (same CGU) by its vsync
  rate.
- The EDID read (RH2:/RH3:) is from stock's code, not seen.
- Which buttons the VRX has (the ladder is the goggles', stock's DT is the
  same; 2.1.x adds a "res" key at 1.7 V).
