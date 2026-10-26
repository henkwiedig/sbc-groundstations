# BetaFPV VR04 HD goggles (betafpv_vr04)

The P1 system's ground unit: Artosyn PROXIMA 9311 (AR9311, 2x Cortex-A53,
256 MiB), AR8030 on SDIO, 128 MiB SPI-NAND, MIPI-DSI panel, SD card slot,
ADC button ladder. Kernel: mainline 6.18.36 with MissingLynk's ml-kernel BSP
(board `betafpv-vr04-goggle`, `linux/linux-ext-ml-kernel.mk`).

Stage 1 (this state): backup, RAM boot through the stock U-Boot, install into
NAND slot A next to stock. No AR8030 link, video or OSD yet. The display
drivers are MissingLynk's QY45043A0 panel only; units with the nd043fhdm30p
panel need a driver of their own (stock: libpn_nd043fhdm30p.so).

## Flash layout and boot

Same 20 partitions as the P1 air unit (`/proc/mtd`: mtd0 whole chip, gpt0
mtd5, kernel0/1 13/14, dtb0/1 15/16, userapp0/1 17/18). The stock SPL boots
the slot whose env/uboot/kernel/dtb/userapp the GPT marks active (bit 47,
`openipc-bsel`), Falcon-style: kernelN + dtbN, command line from the dtb,
`ubi.mtd=` rewritten to the slot's userapp. U-Boot only runs on the
reboot-to-U-Boot path.

This build: `uImage.ar9311` (OTRA + LZ4 uImage) for kernelN,
`vr04-flash.dtb` for dtbN, `rootfs.ubi` for userappN (squashfs in the
`rootfs` volume, mounted through a UBI block device like stock's, +
`rootfs_data` UBIFS overlay), all three in
`P1_GND_<stock release>_OpenIPC_<sha>.img` (stock's update image format,
packed on the stock image in `cache/vendor-images/`, see
`package/artlynk-vr04-vendor-firmware`). `vr04-testboot/` is the RAM boot:
`uImage`, `vr04.dtb` (`vr04-ram.dtb`), `initrd.gz`.

Network: USB RNDIS + ACM (1d6b:0104), the goggles at 192.168.3.100, root
password 12345; serial console ttyS0 at 1152000 baud. The air units' OpenIPC
gadgets use the same id and the same /24 (.104): `host/80-betafpv-vr04.rules`
(into /etc/udev/rules.d) names the goggles `vr04-gnd0` by their product string
and gives the host 192.168.3.205/32 with a host route to .100, so both can be
plugged in at once (an ascent-vtx0 rule for 1d6b:0104 then needs
`ATTRS{product}!="BetaFPV VR04"`).

## Installing and updating (no serial console, case closed)

Both directions go through the SD card, with the update image as BetaFPV
names theirs: OpenIPC's `P1_GND_<release>_OpenIPC_<sha>.img` (built here), or
BetaFPV's own `P1_GND_<release>.img`. Copy it into the root of the card -- with
a card reader, or over USB while the goggles run stock (stock shows the card
as a media device) -- and:

- **Stock -> OpenIPC**: pick it in stock's update menu. Stock's updater
  (libar_ota) checks the image's SHA-256, not its RSA signature, so it takes
  the OpenIPC image; it writes the slot that is not active, makes it the
  active one and restarts into OpenIPC. The image is still on the card then:
  OpenIPC sees stock's index of the card next to it (`.media_files.json`,
  which stock writes whenever it has the card), renames the image `.skipped`
  instead of installing it a second time into the other slot (the one with
  stock), and deletes the index.
- **OpenIPC -> OpenIPC, OpenIPC -> stock**: just power on. OpenIPC installs
  one update from the root of the card before the system starts
  (`/usr/sbin/vr04-sdupdate` from `/init`): an update image as above, or the
  release archive `betafpv_vr04.tar.gz` (the image and its md5sum, as
  published). sysupgrade writes the slot that is not running (OpenIPC with
  this system's settings and pairing), makes it the active one, and the
  goggles restart into it. The panel shows it (update screen with a progress
  bar), and the buzzer: one beep when it starts, two when it is done (the file
  is then deleted), a long one when it failed: the file is renamed `.failed`,
  `sysupgrade.log` on the card says why, and the goggles boot on as they were;
  so does more than one update on the card. Stock 2.1.3 and 2.1.4 go in this
  way; 2.0.6 brings another SPL and vendor partition, which sysupgrade does not
  write (stock's own updater or the USB upgrade below does). No card: no delay
  (the slot's card detect is read first).

The update screens are made from the splash by `scripts/make-update-screens.py`
(`overlay/usr/share/update*.png`, the bar's place in `update-bar.ini`).

Stock's other SD-card upgrade, bind held 2-10 s with
`artosyn-upgrade-ars31.img` on the card, goes through artosyn_upgrade, which
(from its code, not tried) enforces the RSA signature.

Without the SD card, the stock U-Boot's USB upgrade takes the image too (it
checks the RSA signature but does not enforce it):

    scripts/vr04-usbburn.py flash P1_GND_<release>_OpenIPC_<sha>.img --from-stock
    scripts/vr04-usbburn.py flash P1_GND_<release>_OpenIPC_<sha>.img --from-openipc

with the goggles on USB to this host (and its udev rule for 1d6b:0100, see
the script). `--from-stock` sends stock's reboot-to-U-Boot command on
/dev/ttyACM0, `--from-openipc` runs `vr04-uboot` over SSH. U-Boot writes the
slot that is not active, makes it the active one, and waits for a power cycle;
the upload takes ~18 minutes, the write ~12 s. The new slot starts with an
empty overlay: re-pair. On Windows the gadget needs the WinUSB driver (Zadig):
Windows' HID driver puts a report ID in front of every report, which U-Boot
does not take.

## Procedure

Every unit needs its own backup first (factory = RF calibration, unique).
Never activate a slot that has not booted once through U-Boot. Power-cycle
rather than reboot: the SPL can hang after a warm reset.

1. Backup from running stock (reads only; serial console + RNDIS):
   `scripts/vr04-backup.py ../betafpv/rev/backup-vr04-gnd-<factory md5>-<date>`
2. What the stock U-Boot can load from: `scripts/vr04-uboot-boot.py probe`.
   The 2.1.3 U-Boot has no `mmc` command, so no SD card: loady/loadx/loadb,
   `usb` (host), network (no PHY on the goggles) and `mtd read` only.
3. RAM boot (stock untouched): `scripts/vr04-uboot-boot.py ram --source ymodem`
   sends `vr04-testboot/*` over the console (YMODEM, ~37 KiB/s: about 7
   minutes for kernel + initramfs; every 1 KiB block waits for its ACK over
   the USB-serial adapter). `--no-drm` keeps the display drivers out.
4. Into slot A, from the RAM-booted system:
   `scripts/vr04-install.py --dry-run install <img> --backup <dir>`, then
   without `--dry-run`. Stock's slot B stays active.
5. Gate test: power-cycle (stock), then `scripts/vr04-uboot-boot.py slot-a`
6. `scripts/vr04-install.py activate a --backup <dir>` (`--dry-run` first),
   power-cycle. Back to stock: `openipc-bsel set 1`, power-cycle.

If an active slot does not come up (the SPL boots it on its own, without
U-Boot), the way back is MissingLynk's boot-ROM UART writer
(`Missing-Lynk/MissingLynk/glue/recovery/RECOVERY.md`: 115200 baud on the
console wires, magic "0123456" in the ~45 s after power-on, a bare-metal
payload that rewrites gpt0), so a slot is activated only after it booted
through U-Boot (step 5).

`/usr/sbin/vr04-uboot` drops a running OpenIPC into U-Boot: 0x3 into
0x0A106138 (stock's /etc/fb_reboot; bit 0 alone, as in MissingLynk's
uboot-trigger, boots normally here), then a watchdog reset. U-Boot's `reset`
boots the active slot again. `vr04-uboot-boot.py --trigger openipc` uses it.

Updating the active slot A in place: `vr04-uboot-boot.py ram --source ymodem
--trigger openipc`, then `vr04-install.py install IMAGE --backup DIR` (writes
slot A from RAM; B keeps stock), then power-cycle. Userspace-only changes can
go straight into the running system's overlay (`cat > /path` over SSH).

The panel comes up early in /init: vr04-splash loads the display drivers
(udev would only seconds later), draws /usr/share/splash.png with fbv and
switches the backlight on (BRIGHTNESS in /etc/default/vr04-display). The
kernel shows the splash again whenever PixelPilot exits. ml-kernel's
QY45043A0 init also drives the nd043fhdm30p.

## RF front end

The AR8030 runs the Caddx Ascent L_Gnd baseband, which only knows the Ascent
Lite goggles' board: it never enables the pads of GPIO port 2 (0x0A10A000
bit 1), where the VR04's FEM control lines are, and puts its own pin
functions on them, so PA and LNA barely work. BetaFPV's baseband (the same
binary as the P1 air unit's) sets them up from its config's `"board":
"c401"` with the broadcast in `1TX`, its board type c401_1t2r: port 2 pads
on, pin 2.4 a GPIO driven low. `/usr/sbin/vr04-fem` does that after every
chip start (lifecycled hooks `idle` and `connected`). Bench, linked to a P1:
uplink SNR 3-9 -> 15.5 dB at 23 dBm (the P1's AGC gain 98 -> 35), the
goggles' own AGC gain 69/93 -> 32/36. The L_Gnd firmware reads the stock
VR04 PA calibration's layout (four values per row, no sub-bands) as is.

lifecycled runs with `--max-power 200`: 23 dBm, BetaFPV's maximum for the
VR04. 500 mW and "auto" would go to 27 dBm; at 23 the PA already costs
~4.5 dB uplink SNR against 20 dBm.

## Unit log

| unit | factory md5 | backup | notes |
|---|---|---|---|
| bench goggles (hw V2.0; slot A stock 2.1.3 again since 2026-10-26 (SD-card update test); slot B OpenIPC (U-Boot USB upgrade from stock, cold boot verified), ACTIVE; GPT in gpt0; boot-ROM recovery images in the backup: recovery-gpt0-B-active.bin, gpt-after-activate-a/) | 0e398546c8f382ca7bbfdcd8944fa297 | betafpv/rev/backup-vr04-gnd-0e398546-2026-10-23 (+ -pass1) | panel nd043fhdm30p (stock's QY45043A0 detection fails; factory cfg says VoDevice lt9711); bad blocks: kernel1 1, userapp0 3, userapp1 3, usr_data 1 |
