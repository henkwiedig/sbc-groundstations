# SinYine F1 VRX (sinyine_f1_vrx)

The ground unit of SinYine's F1 system, a StartRC VT5 VRX board (carrier
TC001_MAIN V0.3, castellated core module SUN-GND V1.1): an Artosyn PROXIMA
9311 with the AR8030 on SDIO, SPI-NAND, an SD card, two FEMs (GSR5755) on two
antennas, six buttons on two ADC ladders, a power button, a fan, a buzzer,
mini HDMI out and UART2 on a JST. It is the BetaFPV P1's design (same SoC
board base, NAND layout, DDR training, SPL code, AR8030 wiring) with its own
display end: an ITE **IT66122** HDMI transmitter on the VO's **parallel video
port** (DVP), where the P1 HD VRX has an LT9611EX on DSI. SinYine's air unit,
the F1 TX, is the P1 SKY air unit and runs OpenIPC/builder's P1 image
(`SinYine_F1_TX_99991231_OpenIPC.bin`).

Everything but the display, buttons, power and fan is the BetaFPV units' and
lives in `board/betafpv/p1-gnd/` (flash layout, slots, SD-card update,
sysupgrade, RAM boot; see the VR04's README).

**State: runs on a user's F1 VRX (2026-11-10): HDMI picture, video from the
paired TX and the buttons work.** Every board fact below comes from
SinYine's stock image `SinYine_F1_VRX_20260914_V1.0.0.bin`: static analysis
of its SPL, kernel DT, `ar_lowdelay`, `libmpp_service.so` and
`libpn_hdmitx_it6612x.so`, and those libraries' own code run under qemu (the
VO's DVP register words, the IT66122's register sequence). Not tried yet:
the RAM boot, the power button, the fan, the DVR; open: whether the SD card
mounts (the support package did not show up on it).

## The hardware, from stock

- Video: VO interface DVP, sub-interface BT1120: YCbCr 4:2:2 on 16 data
  lines with separate HSYNC/VSYNC/DE, one pixel per clock, the CEA timing
  (1080p60 at 148.5 MHz). The SPL muxes GPIO 45-64 to it (function 1; the
  VO driver does it too if an SPL did not). VO words: 0x1f70 0x000c0101 then
  0x001c0101, 0x1418 0x111, 0x1f40 0x00110211, 0x14b8 5.
- IT66122 at 7-bit 0x4d on **i2c0** (with the DS1307 RTC 0x68 and an INA226
  0x40). The panel library's own default is bus 3 (Artosyn's reference;
  i2c3 is off in the DT): `ar_lowdelay`'s "hdmi" device init sets bus 0.
  Input YUV422 with input clock delay 1, YUV->RGB with stock's ITU601 matrix
  (full range kept, full-range AVI infoframe), no IRQ line (stock polls).
  Reset: stock's panel library pulses GPIO 43, its boot script drives GPIO
  107 high and SinYine's own helper pulses 107: here 107 is the driver's
  reset line, 43 a hog driven high. GPIO 42 high (stock: "LT9711_EN", the
  LT9711 on the back is unused).
- Keys: ADC channel 0 right 469 / enter 946 / up 1378 mV, channel 1 down
  465 / left 952 / bind 1374 mV (stock's adc-keys thresholds). No back key:
  left steps back in the menu.
- Power: button GPIO 105, low while pressed. Stock: a short press beeps and
  toggles the recording, 2 s beep three times and drive GPIO 68 low, which
  cuts the power; nothing drives 68 high.
- Supply monitor: INA226 at 0x40 on i2c0 (stock's `libina226.so`: config
  0x45ff, calibration 0x0a00, 0.02 mA current LSB, which means a 0.1 ohm
  shunt). Stock only reads the bus voltage (its log, the low-voltage
  buzzer), so the shunt value is unconfirmed until a current is checked
  against a meter.
- Fan: GPIO 106, stock runs a 200 Hz software PWM at 60 % (fan_proxy, which
  takes 10-100 %), no temperature control.
- Buzzer: PWM 0x1000000 channel 3.
- Radio: the Ascent ground baseband firmware (as on the VR04) with SinYine's
  own ground power setup and PA calibration (stock bb_config_gnd.json), and
  its front-end pins: those of SinYine's VRX baseband, the VR04's script with
  pin 2.4 on its function 73 (as on the P1 air unit) instead of GPIO low.

## This directory

- `device.env`: dtb, file names (`sinyine-vrx-*`), update image name
  `SinYine_F1_VRX_99991231_OpenIPC_<sha>.bin`, display modules
- `dts/artosyn/proxima-9311-sinyine-vrx.dts`: ml-kernel's goggle DT without
  panel, DSI, backlight and the VR04's ladder; the IT66122 on i2c0 (port 0
  from the VO, bus-width 16; port 1 to an hdmi-connector), two adc-keys,
  gpio-keys "power-button", gpio-poweroff on GPIO 68, pwm-gpio on GPIO 106,
  the INA226 (`ti,ina226`, 100000 µΩ shunt; ina2xx built in, hwmon "ina226"),
  UART2, the hogs above
- kernel patches, after the P1 ground units' (`../../betafpv/p1-gnd/linux-patches/`)
  and the P1 HD VRX's (`../../betafpv/p1-vrx/linux-patches/`, for its pixel
  clock patch):
  - 0001 artosyn_vo: `artosyn,dvp-bt1120`, the parallel output with stock's
    words; the bridge attached without a connector and a bridge connector,
    polled
  - 0002 ite-it66121: the IT66122 with a YCbCr 4:2:2 16-bit input, stock's
    init table, AFE extras and CSC; `ite,force-hpd`: always connected, and
    1080p60/720p60/1080p50/720p50 when the sink gives no EDID
  - 0003 ite-it66121: the IT66122's init table at attach, before the
    power-up and without mainline's second REF reset, which put the
    registers back to their defaults (the HDMI link dropped every few
    seconds)
- `overlay/`: `/etc/default/p1-gnd` (USB name "SinYine F1 VRX", stock image
  check, update file name, display modules, FEM pin), `/etc/default/beeper`,
  `/etc/pixelpilot.yaml` (two ladders: PixelPilot's `vrx_adc` with a
  `device` per key; the INA226 as the `vrx` power sensor: the shared OSD's
  supply voltage, plus current and power on the same row; the fan's duty),
  `/etc/default/gs-fan` (the fan for `board/common/gs-fan`'s control loop:
  pwm-gpio `fan-pwm` at 200 Hz, the SoC temperature from artosyn_protemp,
  1 s full-speed start; System -> Fan in PixelPilot), `S96sinyine-power` +
  `/usr/sbin/sinyine-power` (the power button), update screens
- `host/80-sinyine-f1-vrx.rules`: names the USB network `vrx-gnd0` on a Linux
  host

PixelPilot needs the per-key `device` of its ADC ladder reader and the
`name`/optional `hwmon_id` of an `ina226` power entry (changes on top of its
v4l2-wave5 branch); until those are in the pinned commit, build with
`PIXELPILOT_OVERRIDE_SRCDIR=<PixelPilot_rk checkout>`.

Build: `DEFCONFIG=sinyine_f1_vrx_defconfig ./build.sh`, with SinYine's
`SinYine_F1_VRX_20260914_V1.0.0.bin` in `cache/vendor-images/` (the update
image is packed on it: its SPL, vendor, env and U-Boot) next to BetaFPV's
P1_GND image (the codec firmware) and the Ascent L Gnd image (the AR8030
firmware). In `output/sinyine_f1_vrx_defconfig/images/`:
`SinYine_F1_VRX_99991231_OpenIPC_<sha>.bin` (the update image),
`sinyine_f1_vrx.tar.gz` (the release archive), `sinyine-vrx-testboot/` (RAM
boot).

## Trying it

1. **RAM boot** (nothing written): a 3.3 V USB-UART on the console pads
   T0/R0/G (1152000 baud, `/dev/ttyUSB0`), the unit running stock with its
   USB-C on the host (`/dev/ttyACM0`), then from the sbc-groundstations
   checkout:

       python3 board/betafpv/p1-gnd/scripts/vr04-uboot-boot.py ram --source ymodem \
           --bundle output/sinyine_f1_vrx_defconfig/images/sinyine-vrx-testboot

   (`--bundle` is needed, the default is the VR04's; YMODEM takes about
   2.5 min.) The default `--trigger stock` sends the reboot-to-U-Boot
   command to stock's USB serial port: the VRX's stock runs the same
   `ota_upgrade` listener on ttyGS0 as the TX (gadget rndis+uart+mtp,
   `/etc/fb_reboot 9311`). If that fails, `--trigger none` and a power cycle
   while the script sends Ctrl-C. It shows whether the kernel finds the
   NAND (mainline spi-nand; the chip is not known), the IT66122 (`dmesg |
   grep -i it6612`, `cat /sys/class/drm/*/status /sys/class/drm/*/modes`)
   and the link, before anything is installed. The RAM boot has no
   PixelPilot (it is left out to fit), so no picture or menu: a monitor
   only shows whether an HDMI signal comes. A power cycle boots stock again.
2. **Install, the stock way**: both images in the SD card's root,
   `SinYine_F1_TX_99991231_OpenIPC.bin` (builder's P1 image) and
   `SinYine_F1_VRX_99991231_OpenIPC_<sha>.bin`, then the stock upgrade: the
   VRX updates the linked TX over the link first, then itself
   (`rxUpgradeRxImgthread`, libar_ota: no signature check, partition table
   and vendor unchanged, the SPL rewritten with SinYine's own). It flashes
   the slot not running, so SinYine's firmware stays in the other one. The
   file stays on the card; OpenIPC's first boot renames it `.skipped`
   instead of installing it into the other slot too (sysupgrade
   `--skip-running`).
3. **Back to stock**: `openipc-bsel switch` and a power cycle (the other slot
   still has stock), or SinYine's `SinYine_F1_VRX_*.bin` in the card's root
   (OpenIPC's boot installs it into the other slot, sysupgrade checks it is
   a VRX image: product 0.17.11-00, `adc1-keys` in its dtb), or
   `sysupgrade --image=SinYine_F1_VRX_20260914_V1.0.0.bin`.

Without a picture the unit is still on USB: RNDIS + console, 192.168.3.100,
`ssh root@192.168.3.100`.
