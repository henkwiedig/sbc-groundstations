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
