# U-Boot patches for the Caddx VRX Pro

Applied by buildroot on top of mainline U-Boot (`BR2_TARGET_UBOOT_PATCH`,
currently U-Boot 2025.07). This board currently builds on the generic
`evb-rk3568` reference target and devicetree — there is no dedicated
upstream board support for it.

## 0001 — local patch

`0001-rockchip-evb_rk3568-disable-spurious-download-key.patch` is our own
patch, not upstream, keep indefinitely.

`arch/arm/mach-rockchip/boot_mode.c`'s `rockchip_dnl_key_pressed()` reads an
ADC channel (SARADC channel 1) and treats a low reading (0-30) as a physical
"download/recovery key" press, then deliberately reboots into Maskrom. This
is a Rockchip EVB reference-board convenience feature for a button wired as
a resistor-divider on that ADC pin. The Caddx VRX Pro doesn't have that
button wired the same way, so the floating/unconnected channel reads a
spuriously low value on *every* boot, forcing an unwanted reset before
U-Boot proper ever gets a chance to run.

Confirmed via serial console: without this patch, U-Boot proper fully
initializes (DRAM, PMIC, console) then immediately prints
`download key pressed, entering download mode...resetting ...` and reboots,
in a tight loop, every time. With it, U-Boot boots and runs completely
normally.

The fix adds `board/rockchip/evb_rk3568/{Makefile,evb-rk3568.c}` (this board
directory previously had no custom board code at all — just `Kconfig` and
`MAINTAINERS`) providing a strong (non-weak) override of
`rockchip_dnl_key_pressed()` that always returns 0, rather than patching the
shared vendor file directly — keeps the fix board-scoped instead of
affecting every other board built from this same generic Rockchip code.

## 0003 — local patch

`0003-uboot-replicate-rp_power-gpios-in-board-late-init.patch` is our own
patch, not upstream, keep indefinitely.

Adds a strong `rk_board_late_init()` override (weak default just returns 0,
nothing lost) to the same `evb-rk3568.c` from 0001. Two things bundled into
it, both found by decompiling Ascent's real stock U-Boot binary and
cross-checked against a real serial capture of stock booting
(`stockboot.cap`, kept alongside this repo during the investigation):

**PMIC register init.** Stock's `rk8xx_probe()` does substantial raw RK817
register configuration beyond what mainline's generic `rk8xx.c`
regulator/pmic drivers ever touch — `RK817_PMIC_CHRG_TERM`,
`RK817_POWER_EN_SAVE0/1` (rebuilt live from the chip's own OTP/trim
registers), a 5-entry raw register table, an unconditional
`RK817_PMIC_CHRG_IN` write, and bits in an unnamed register (`0xf7`). This
is the fix that actually resolved the real bug this patch series was
chasing: an intermittent SoC brownout/reset under wifi/USB load. The PMIC
is an external I2C chip, so unlike SoC-internal state its registers
survive a warm SoC reset — which is exactly why the one boot sequence
confirmed reliable on real hardware even without `cpufreq.off=1` was: halt
stock U-Boot at its own prompt (its `rk8xx_probe()` already ran in full),
insert the SD card, `reset` — our own U-Boot and kernel then boot against a
PMIC stock already finished configuring, not a freshly power-on-reset one.
Confirmed fixed on real hardware: three stable cold boots, wifi up, H265
decode under load, `cpufreq.off=1` since removed as unnecessary too.

**`rp_power`/wifi-chip GPIOs.** Stock's vendor "rp_power" board-support
code drives `usb_pwr`/`hub_rst`/`otg_mode`/`sd_pwren`/`spk_en`/`spk_mute`
from *within U-Boot itself*, seconds into power-on ("buzzer on"
immediately followed by "rp_power: ... gpio set output", well before
"Starting kernel..."), holding them stable through the whole U-Boot +
kernel boot — our kernel replicates these same pins itself (`rp_power`'s
actual out-of-tree driver isn't ported), so this didn't fix the brownout
bug on its own, but moves pin configuration seconds earlier than the old
`/init`-based approach, matching stock's own timing. Each GPIO is
requested by its controller devicetree node name + offset (not a global
GPIO number, to avoid depending on U-Boot's driver-model gpiochip
base-allocation order) and driven to the raw level `rp_power`'s devicetree
node specifies. `led` (gpio_function 3) is intentionally skipped — stock's
own U-Boot port skips it too (the capture shows it's not implemented
there). Also bundled in the same table: `wifi_pwr` (gpio105, i.e. gpio3
offset 9) is the RTL8188FTV companion wifi chip's own power-enable pin —
not part of `rp_power`'s devicetree node at all, previously toggled from
`board/caddx/vrxpro/overlay/etc/init.d/S99zwifi-enable` (now removed
entirely). That script also power-cycled the chip and retried up to 5
times to work around intermittent USB firmware-download failures on
power-on; that retry is now handled at the actual failure point instead,
inside the kernel's own `rtl8xxxu_download_firmware()` (see
`linux-patches/0002-rtl8xxxu-retry-firmware-download-on-error.patch`), so
a single one-time power-on here is enough.

## Rockchip VOP2 display support — shared with the Radxa Zero 3

Not copied here: `BR2_TARGET_UBOOT_PATCH` lists
`board/radxa/zero3/uboot-patches` first, then this directory, so the
"Rockchip VOP2 support" series (Radxa `0002`–`0013`, see that README for
sources and status) applies before our board patches. It gives U-Boot a
VOP2 framebuffer and RK3568 HDMI output, so `uboot.fragment`'s PREBOOT
shows the boot splash (`/usr/share/splash*.bmp`) early, as on the
Radxa-based boards. The Radxa directory's own `0001` only touches the Radxa
board file, which this `evb-rk3568` build doesn't compile.

The series' only devicetree change (Radxa `0009`) marks `&vop` pre-relocation in
`rk356x-u-boot.dtsi`. Our board dts is decompiled from stock and only
carries the labels that file needs, so `0002` labels `vop: vop@fe040000`
for it. The VOP2/HDMI drivers find everything else through the stock node
layout (`regs` first, `dclk_vpN` clocks, the ports/remote-endpoint graph).

One more U-Boot-only DT fix (`rk3568-caddx-vrxpro-u-boot.dtsi`, carried in
`0002`): the stock dts lists every possible VP0 output as endpoint@0..3
(DSI0, DSI1, eDP, HDMI), but the VOP2 driver only follows each port's
*first* endpoint. It tried the disabled DSI0, the VOP never probed, and the
splash never showed (`bdinfo`: "Video = vop@fe040000 inactive"). Deleting
endpoint@0..2 of port@0 leaves HDMI first, as in upstream board dts.
Verified on hardware: VOP + HDMI probed, 1920x1080x32 framebuffer, splash
visible before the kernel starts.

## 0004 — local patch

`0004-adc-rockchip-saradc-add-RK3568-with-8-channels.patch`: U-Boot matched
the RK3568 SARADC only through its `rockchip,rk3399-saradc` fallback, which
declares 6 channels, so `adc single saradc@fe720000 6` failed with -EINVAL.
The RK3568 is the same v1 block with 8 channels (as in Linux). Channel 6 is
the button ladder the boot menu reads (`overlay/boot/uboot-buttons.env`).
Candidate for upstreaming.
