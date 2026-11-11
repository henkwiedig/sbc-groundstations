#!/usr/bin/env python3
"""
Boot the BetaFPV VR04 goggles (P1 GND, Artosyn PROXIMA 9311) over USB from
the chip's mask-ROM download mode: no serial console, nothing written to the
NAND. (ar9311-usbboot.py of OpenIPC builder's devices/ar9311_artosyn_artlynk-p1,
for the goggles.)

  vr04-usbboot.py ram [--images DIR] [--bundle DIR] [--no-drm] [--args ARGS]
                      [--serial TTY]
      patched stock SPL + U-Boot, then this build's RAM boot: uImage, the one
      *.dtb and initrd.xz (else initrd.gz) of IMAGES/<unit>-testboot (the
      one *-testboot there), the bundle vr04-uboot-boot.py ram sends. U-Boot
      boots it on its own; this waits for SSH on the unit (root password
      12345, the RAM image has no key). --serial shows the console meanwhile.
      The P1 HD VRX (betafpv_p1_vrx) boots the same way, with --images
      output/betafpv_p1_vrx_defconfig/images: same board, and its stock
      VRX 2.0.8 image has the same SPL code and DDR firmware (vendor.img
      payload) as the VR04 2.1.3 one these blobs come from.
  vr04-usbboot.py hid
      patched SPL, the stock U-Boot as it is: booted over USB it goes
      straight into its USB upgrade mode (1d6b:0100), so
      `vr04-usbburn.py flash IMAGE` (without --from-*) can flash a unit that
      boots no Linux.
  --dry-run  builds and checks everything, sends nothing.

Getting into the mask-ROM mode: the boot ROM takes its boot device from the
straps (0x0a10602c bits 2:0) and tries USB download (and UART) only after
the NAND boot failed. A unit with a readable SPL therefore needs the SPI-NAND
CLK line held to ground while powering on, released once 5343:0200 "SCA200
usb gadget" has enumerated (pliers on the P1 SKY; on MissingLynk's goggles
the SoC and the flash sit under a soldered shield, so the line has to be
reached outside it). A unit without a readable SPL lands there on its own.
The ROM enumerates, drops off and enumerates again; this script waits for it.
Host: pyusb, access to 5343:0200 (and 1d6b:0100 for hid), e.g.
/etc/udev/rules.d/80-artosyn.rules:
  SUBSYSTEM=="usb", ATTRS{idVendor}=="5343", ATTRS{idProduct}=="0200", MODE="0660", GROUP="plugdev"
and board/betafpv/vr04/host/80-betafpv-vr04.rules for the RAM system's RNDIS.

The chain (in detail in builder's script; verified there on P1 SKY units, on
the goggles not yet):
  session 1  ROM download: a virtual flash (GPT + vendor.img at 0x180000), a
             fake SPI-NAND device struct and the stock SPL, patched to train
             DDR from that virtual flash and then call the ROM's usb_download
             (0x52f8) once more;
  session 2  stock U-Boot (patched for ram) and the RAM boot straight into
             DDR, reg 0x0a10613c = U-Boot's address; the SPL's USB path
             copies U-Boot to its entry and jumps.
The stock blobs come from output/images/artlynk-vr04 (package
artlynk-vr04-vendor-firmware, out of the stock P1_GND image). The goggles'
SPL (0x21978 bytes) is the P1 air's SPL code byte for byte (checked by CRC
over its first 0x20640 bytes); only the data appended to it is 0x18 bytes
longer. So the stub goes to the goggles' SPL end instead of the air's
0x131960, and the branches into and out of it are re-encoded. vendor.img is
the air's; U-Boot differs only in its build date and appended dtb.

U-Boot, booted from USB (0x100056 == 0x40), calls usb_booting() (the HID
upgrade loop) first. For ram that call becomes a nop and its built-in
default environment (it runs on that: no flash env is read) gets bootcmd,
bootargs and bootdelay=0:
  setenv initrd_high/fdt_high (U-Boot leaves initrd and dtb in place);
  mtd read of 2 KiB of the NAND (without a NAND access in U-Boot the kernel's
  spi-nand probe fails, "unknown raw ID"); bootm kernel initrd:size dtb.
The command line carries no "ubi.mtd=": with it, U-Boot regenerates its
bootcmd to boot the active slot instead.

Load map: kernel 0x21800000, initrd 0x23000000 (at most 24 MiB), dtb
0x24800000 -- the air's map. Here everything is in DDR before U-Boot starts,
so it stays below U-Boot's HID upgrade buffer at 0x24900000
(vr04-uboot-boot.py's 0x24000000.. is loaded only after U-Boot left its
upgrade mode), and far below the goggles' ramoops/MMZ at 0x29100000.
"""
import argparse
import os
import socket
import struct
import sys
import time
import uuid
import zlib

try:
    import usb.core
    import usb.util
except ImportError:
    usb = None

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_IMAGES = os.path.normpath(os.path.join(HERE, "../../../../output/betafpv_vr04_defconfig/images"))

# ---------------------------------------------------------------- ROM protocol

ROM_VID, ROM_PID = 0x5343, 0x0200
HID_VID, HID_PID = 0x1D6B, 0x0100
MAX_XFER = 0x1000
HDR_ADDR = 0x100040


def find_rom(timeout=10.0, not_addr=None, settle=0.5):
    """Wait for a stable ROM device; not_addr=(bus, address) skips a stale instance."""
    end = time.time() + timeout
    while time.time() < end:
        dev = usb.core.find(idVendor=ROM_VID, idProduct=ROM_PID)
        if dev is not None and settle:
            time.sleep(settle)
            again = usb.core.find(idVendor=ROM_VID, idProduct=ROM_PID)
            if again is None or (again.bus, again.address) != (dev.bus, dev.address):
                continue
        if dev is not None and (not_addr is None or (dev.bus, dev.address) != not_addr):
            try:
                if dev.is_kernel_driver_active(0):
                    dev.detach_kernel_driver(0)
            except Exception:
                pass
            try:
                dev.set_configuration()
            except usb.core.USBError:
                pass
            return dev
        time.sleep(0.1)
    return None


def _pkt(addr, data):
    return b"US" + struct.pack("<HQ", len(data), addr) + data


def write_mem(dev, addr, data, label):
    step = MAX_XFER - 12
    t0 = time.time()
    for off in range(0, len(data), step):
        dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(addr + off, data[off:off + step]), timeout=5000)
    rate = len(data) / max(time.time() - t0, 1e-3) / 1024
    print(f"  {label:10s} {addr:#010x} {len(data):8d} B  {rate:6.0f} KiB/s")


def run_session(writes, timeout, not_addr=None, regs=()):
    """Feed one ROM download session and start it; returns the device's (bus, addr)."""
    skip = not_addr
    for _ in range(4):
        dev = find_rom(timeout=timeout, not_addr=skip)
        if dev is None:
            sys.exit("ROM device 5343:0200 not found: power the goggles up with the NAND's CLK grounded")
        where = (dev.bus, dev.address)
        try:
            for addr, data, label in writes:
                write_mem(dev, addr, data, label)
            for addr, value in regs:
                dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(addr, struct.pack("<I", value)), timeout=5000)
        except usb.core.USBError as e:
            print(f"  ROM device dropped off ({e}), retrying on its next enumeration")
            usb.util.dispose_resources(dev)
            skip = where
            continue
        try:
            dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(0, b""), timeout=2000)
        except usb.core.USBError:
            pass  # the ROM may jump before completing the status stage
        usb.util.dispose_resources(dev)
        return where
    sys.exit("ROM device kept dropping off")

# ---------------------------------------------------------------- IMGI loader header

IMGI_MAGIC = 0x494D4711


def imgi_header(load_addr, payload, hdr_size=0x40, version=1):
    if len(payload) % 8:
        payload += b"\0" * (8 - len(payload) % 8)
    h = bytearray(hdr_size)
    struct.pack_into("<IHH", h, 0, IMGI_MAGIC, version, hdr_size)
    struct.pack_into("<II", h, 0x18, load_addr, len(payload))
    struct.pack_into("<Q", h, 0x34, sum(struct.unpack(f"<{len(payload) // 8}Q", payload)) & (2**64 - 1))
    struct.pack_into("<I", h, 0x08, sum(struct.unpack(f"<{hdr_size // 4}I", h)) & 0xFFFFFFFF)
    return bytes(h), payload


def parse_loader(path):
    """(header, payload, load_addr) of a stock loader.bin (payload at file offset 0x200)."""
    d = read(path)
    magic, _ver, hs = struct.unpack_from("<IHH", d, 0)
    if magic != IMGI_MAGIC:
        sys.exit(f"{path}: not an IMGI loader")
    load, size = struct.unpack_from("<II", d, 0x18)
    poff = (hs + 0x1FF) & ~0x1FF
    return d[:hs], d[poff:poff + size], load

# ---------------------------------------------------------------- SPL patch + virtual flash

SPL_LOAD = 0x110000
SPL_CODE_LEN, SPL_CODE_CRC = 0x20640, 0x66F5BE5F   # P1 air v2.0.5-v2.1.2 = goggles 2.1.3
VFLASH_BASE, VFLASH_SIZE = 0x180000, 0x7E000
FAKE_DEV = 0x1FF800
ERASE_SIZE = 0x20000
VENDOR_OFF = 0x10000          # LBA 0x80
UBOOT_PTR_REG = 0x0A10613C

# builder's stub, assembled for 0x131960 (the end of the air's SPL): snapshot
# the ROM state 0x101000..0x102120 to 0x1fe000, zero it, bl dram_init
# (0x110118), restore, bl usb_download (0x52f8, the ROM), ret; vread at +0x84
STUB_AIR_BASE, STUB_VREAD = 0x131960, 0x84
SPL_STUB = bytes.fromhex(
    "fd7bbea9fd030091000082d20002a0f201009cd2e103a0f2022482d2038440f8238400f8422000f1"
    "a1ffff54000082d20002a0f2022482d21f8400f8422000f1c1ffff54dd79ff9700009cd2e003a0f2"
    "010082d20102a0f2022482d2038440f8238400f8422000f1a1ffff54f20b00f900008052494efb97"
    "f20b40f9fd7bc2a8c0035fd6e103012ae203022a2400028b05009cd2e500a0f29f0005eb68010054"
    "050080d20503a0f22100058ba20000b42614403866140038420400d1fcffff1700008052c0035fd6"
    "80008012c0035fd6")
SNAPSHOT_END = 0x1FE000       # the stub's snapshot buffer: the stub must end below it


def branch(pc, target, link=False):
    """A64 B/BL from pc to target."""
    off = target - pc
    if off % 4 or not -(1 << 27) <= off < (1 << 27):
        raise ValueError(f"no branch from {pc:#x} to {target:#x}")
    return struct.pack("<I", (0x94000000 if link else 0x14000000) | ((off >> 2) & 0x3FFFFFF))


def relocate_stub(base):
    """The stub at base: its B/BL out of the stub re-encoded (all other
    PC-relative instructions in it stay inside it; it has no ADR/ADRP)."""
    s = bytearray(SPL_STUB)
    for o in range(0, len(s), 4):
        w = struct.unpack_from("<I", s, o)[0]
        if w & 0x1F000000 == 0x10000000:
            raise ValueError("stub has an ADR/ADRP")
        if w & 0x7C000000 == 0x14000000:
            off = (((w & 0x3FFFFFF) ^ 0x2000000) - 0x2000000) * 4
            target = STUB_AIR_BASE + o + off
            if not STUB_AIR_BASE <= target < STUB_AIR_BASE + len(s):
                s[o:o + 4] = branch(base + o, target, bool(w & 0x80000000))
    return bytes(s)


def spl_patches(stub):
    """addr: (original, patched) for the stub at `stub`."""
    return {
        # USB path: bl stub ; b 0x1104f0 (copy U-Boot + jump)
        0x110720: (bytes.fromhex("2e1e00940400a8d2"),
                   branch(0x110720, stub, link=True) + branch(0x110724, 0x1104f0)),
        # get-spinand-device: mov x0, #FAKE_DEV ; ret
        0x111478: (bytes.fromhex("fd7bbfa9fd0300914e350094"), bytes.fromhex("00009fd2e003a0f2c0035fd6")),
        # spinand_flash_read: b vread (memcpy from the virtual flash)
        0x111918: (bytes.fromhex("fd7bbba9"), branch(0x111918, stub + STUB_VREAD)),
    }


# the relocation reproduces builder's air patch exactly
assert relocate_stub(STUB_AIR_BASE) == SPL_STUB
assert spl_patches(STUB_AIR_BASE)[0x110720][1] == bytes.fromhex("9084009473ffff17")
assert spl_patches(STUB_AIR_BASE)[0x111918][1] == bytes.fromhex("33800014")


def patch_spl(payload, load):
    if load != SPL_LOAD:
        sys.exit(f"SPL loads at {load:#x}, not {SPL_LOAD:#x}")
    if zlib.crc32(payload[:SPL_CODE_LEN]) != SPL_CODE_CRC:
        sys.exit("SPL code differs from the P1 v2.0.5-v2.1.2 / VR04 2.1.3 SPL the patch is for")
    stub = SPL_LOAD + ((len(payload) + 7) & ~7)
    if stub + len(SPL_STUB) > SNAPSHOT_END or stub + len(SPL_STUB) > VFLASH_BASE:
        sys.exit(f"SPL too large ({len(payload):#x})")
    p = bytearray(payload.ljust(stub - SPL_LOAD, b"\0"))
    for addr, (orig, new) in spl_patches(stub).items():
        o = addr - SPL_LOAD
        if p[o:o + len(orig)] != orig:
            sys.exit(f"SPL bytes at {addr:#x} differ")
        p[o:o + len(new)] = new
    return bytes(p) + relocate_stub(stub), stub


def build_gpt(name, first_lba, n_lbas):
    """LBA0 protective MBR, LBA1 header, LBA2.. entries; one partition, attribute bit 47."""
    ent = bytearray(128 * 128)
    e = bytearray(128)
    e[0:16] = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQQ", e, 32, first_lba, first_lba + n_lbas - 1, 1 << 47)
    e[56:56 + 72] = name.encode("utf-16-le").ljust(72, b"\0")
    ent[0:128] = e
    last = 0x3FF
    h = bytearray(0x5C)
    struct.pack_into("<8sII", h, 0, b"EFI PART", 0x10000, 0x5C)
    struct.pack_into("<QQQQ", h, 0x18, 1, last, 34, last - 33)
    h[0x38:0x48] = uuid.uuid4().bytes_le
    struct.pack_into("<QIII", h, 0x48, 2, 128, 128, zlib.crc32(ent))
    struct.pack_into("<I", h, 0x10, zlib.crc32(h))
    mbr = bytearray(512)
    mbr[446 + 4] = 0xEE
    struct.pack_into("<II", mbr, 446 + 8, 1, last)
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr) + bytes(h).ljust(512, b"\0") + bytes(ent)


def build_vflash(vendor):
    """GPT @0, vendor.img @VENDOR_OFF, zeros where the SPL looks for GPT copy 1."""
    v = bytearray(max(VENDOR_OFF + len(vendor), 2 * ERASE_SIZE + 0x4400))
    gpt = build_gpt("vendor", VENDOR_OFF // 512, (len(vendor) + 511) // 512)
    v[0:len(gpt)] = gpt
    v[VENDOR_OFF:VENDOR_OFF + len(vendor)] = vendor
    if len(v) > VFLASH_SIZE:
        sys.exit("vendor.img too large for the virtual flash")
    return bytes(v)


def fake_dev():
    """The two fields the SPL's GPT code reads: +0x10 erase size, +0x14 GPT start LBA."""
    d = bytearray(0x40)
    struct.pack_into("<II", d, 0x10, ERASE_SIZE, 0)
    return bytes(d)

# ---------------------------------------------------------------- U-Boot autoboot patch

UBOOT_ADDR = 0x21000000
UBOOT_TEXT = 0x20001000       # uboot0.img: OTRA 0x40 + uImage header 0x40, payload linked here
UBOOT_PAYLOAD = 0x80
UBOOT_PATCHES = {  # addr: (original, patched)
    0x2001a790: ("eaad0094", "1f2003d5"),   # bl usb_booting -> nop
}
ENV_FIRST = b"bootargs=console=ttyS0,115200"
HID_BUF = 0x24900000          # U-Boot's upgrade buffer


def check_uboot(u):
    if u[:4] != b"OTRA":
        sys.exit("uboot0.img: not the OTRA container")
    for addr, (orig, _new) in UBOOT_PATCHES.items():
        o = addr - UBOOT_TEXT + UBOOT_PAYLOAD
        if u[o:o + 4] != bytes.fromhex(orig):
            sys.exit(f"U-Boot bytes at {addr:#x} differ: not the P1 v2.0.5-v2.1.3 U-Boot")


def patch_uboot(img, env):
    """Skip the HID upgrade trap and replace entries of the built-in default env."""
    u = bytearray(img)
    for addr, (orig, new) in UBOOT_PATCHES.items():
        o = addr - UBOOT_TEXT + UBOOT_PAYLOAD
        u[o:o + 4] = bytes.fromhex(new)
    start = u.find(ENV_FIRST)
    end = u.find(b"\0\0", start)
    if start < 0 or end < 0:
        sys.exit("U-Boot default environment not found")
    new = dict(e.split(b"=", 1) for e in bytes(u[start:end]).split(b"\0"))
    for k, v in env.items():
        new[k.encode()] = v.encode()
    blob = b"\0".join(k + b"=" + v for k, v in new.items())
    if len(blob) > end - start:
        sys.exit(f"patched U-Boot env too long ({len(blob)} > {end - start} B)")
    u[start:end] = blob.ljust(end - start, b"\0")
    # legacy uImage header at 0x40: data CRC over the payload, then header CRC
    size = struct.unpack_from(">I", u, 0x40 + 12)[0]
    struct.pack_into(">I", u, 0x40 + 24, zlib.crc32(u[UBOOT_PAYLOAD:UBOOT_PAYLOAD + size]))
    struct.pack_into(">I", u, 0x40 + 4, 0)
    struct.pack_into(">I", u, 0x40 + 4, zlib.crc32(u[0x40:0x80]))
    # OTRA header: +0x10 uImage size, +0x20 byte sum over it
    n = struct.unpack_from("<I", u, 0x10)[0]
    struct.pack_into("<I", u, 0x20, sum(u[0x40:0x40 + n]) & 0xFFFFFFFF)
    return bytes(u)

# ---------------------------------------------------------------- commands

KADDR, RDADDR, DTADDR = 0x21800000, 0x23000000, 0x24800000
NAND_TOUCH = 0x26000000       # scratch for the 2 KiB NAND read
ARGS = "earlycon console=ttyS0,1152000 rdinit=/init"
NO_DRM = "modprobe.blacklist=artosyn_vo,artosyn_dsi,panel_qy45043a0,lontium_lt9611ex"


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        sys.exit(f"{path}: {e.strerror} (built betafpv_vr04?)")


def boot_uboot(a, extra=(), env=None):
    """Session 1: patched SPL + virtual flash; session 2: U-Boot (+ extra) into DDR."""
    _, payload, load = parse_loader(os.path.join(a.blobs, "loader.bin"))
    spl, stub = patch_spl(payload, load)
    hdr, spl = imgi_header(load, spl)
    vflash = build_vflash(read(os.path.join(a.blobs, "vendor.img")))
    uboot = read(os.path.join(a.blobs, "uboot0.img"))
    check_uboot(uboot)
    if env:
        uboot = patch_uboot(uboot, env)
    if UBOOT_ADDR + len(uboot) > min([addr for addr, _, _ in extra] + [HID_BUF]):
        sys.exit("U-Boot overlaps the images")

    s1 = [(VFLASH_BASE, vflash, "vflash"), (FAKE_DEV, fake_dev(), "fake dev"),
          (load, spl, "spl"), (HDR_ADDR, hdr, "imgi hdr")]
    s2 = [(UBOOT_ADDR, uboot, "u-boot"), *extra]
    if a.dry_run:
        print(f"SPL {len(payload):#x} B, stub at {stub:#x}")
        for n, s in (("session 1", s1), ("session 2", s2)):
            print(n)
            for addr, data, label in s:
                print(f"  {label:10s} {addr:#010x} {len(data):8d} B")
        print(f"  reg {UBOOT_PTR_REG:#010x} = {UBOOT_ADDR:#x}")
        for k, v in (env or {}).items():
            print(f"env {k}={v}")
        return False
    if usb is None:
        sys.exit("needs pyusb: pip install pyusb")
    print("session 1: patched SPL + virtual flash")
    old = run_session(s1, timeout=a.wait)
    print("DDR training, waiting for the ROM to come back ...")
    print("session 2: U-Boot into DDR")
    run_session(s2, timeout=20, not_addr=old, regs=[(UBOOT_PTR_REG, UBOOT_ADDR)])
    return True


def bundle_files(bundle):
    if not os.path.isdir(bundle):
        sys.exit(f"{bundle} missing (build betafpv_vr04, or --bundle)")
    dtbs = sorted(n for n in os.listdir(bundle) if n.endswith(".dtb"))
    if len(dtbs) != 1:
        sys.exit(f"{bundle}: needs exactly one .dtb, has {dtbs}")
    rd = "initrd.xz" if os.path.isfile(os.path.join(bundle, "initrd.xz")) else "initrd.gz"
    return [os.path.join(bundle, n) for n in ("uImage", rd, dtbs[0])]


def wait_ssh(host, timeout, console):
    """Until the goggles' sshd answers; the console, if any, is shown meanwhile."""
    t0, last = time.time(), 0.0
    while time.time() - t0 < timeout:
        if console is not None:
            d = console.read(65536)
            if d:
                sys.stdout.write(d.decode(errors="replace").replace("\r", ""))
                sys.stdout.flush()
        if time.time() - last >= 1:
            last = time.time()
            try:
                socket.create_connection((host, 22), timeout=0.5).close()
                return time.time() - t0
            except OSError:
                pass
    return None


def cmd_ram(a):
    kpath, rpath, dpath = bundle_files(a.bundle)
    kernel, initrd, dtb = read(kpath), read(rpath), read(dpath)
    if kernel[:4] != b"OTRA":
        sys.exit(f"{kpath}: not the OTRA kernel container")
    if KADDR + len(kernel) > RDADDR:
        sys.exit("kernel larger than its window")
    if RDADDR + len(initrd) > DTADDR:
        sys.exit(f"{os.path.basename(rpath)} larger than its window ({(DTADDR - RDADDR) >> 20} MiB)")
    if DTADDR + len(dtb) > HID_BUF:
        sys.exit("dtb larger than its window")
    args = " ".join(x for x in (ARGS, NO_DRM if a.no_drm else "", a.args) if x)
    if "ubi.mtd=" in args:
        sys.exit("the RAM boot's command line must not say ubi.mtd=")
    bootcmd = ("setenv initrd_high 0xffffffffffffffff; setenv fdt_high 0xffffffffffffffff; "
               f"mtd read spi-nand0 {NAND_TOUCH:#x} 0x100000 0x800; "
               f"bootm {KADDR:#x} {RDADDR:#x}:{len(initrd):#x} {DTADDR:#x}")
    extra = [(KADDR, kernel, "kernel"), (RDADDR, initrd, "initrd"), (DTADDR, dtb, "dtb")]
    t0 = time.time()
    if not boot_uboot(a, extra=extra, env={"bootcmd": bootcmd, "bootargs": args, "bootdelay": "0"}):
        return
    print(f"sent in {time.time() - t0:.0f} s; U-Boot boots it, waiting for SSH on {a.host} ...")
    console = None
    if a.serial:
        import serial  # opened only now: opening the port toggles DTR/RTS
        console = serial.Serial(a.serial, 1152000, timeout=0.1)
    up = wait_ssh(a.host, a.timeout, console)
    if up is None:
        sys.exit(f"\nno SSH on {a.host} within {a.timeout} s (host rule for the RNDIS gadget? "
                 "board/betafpv/vr04/host/80-betafpv-vr04.rules)")
    print(f"\nup after {up:.0f} s: sshpass -p 12345 ssh root@{a.host}")


def cmd_hid(a):
    if not boot_uboot(a):
        return
    print("waiting for U-Boot's USB upgrade mode (1d6b:0100) ...")
    end = time.time() + 30
    while time.time() < end:
        if usb.core.find(idVendor=HID_VID, idProduct=HID_PID) is not None:
            print("U-Boot is in its upgrade mode: vr04-usbburn.py flash IMAGE (VR04 or VRX image)")
            return
        time.sleep(0.5)
    sys.exit("1d6b:0100 did not show up")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn, help_ in (("ram", cmd_ram, "this build's RAM boot, autobooted by U-Boot"),
                            ("hid", cmd_hid, "stock U-Boot in its USB upgrade mode, for vr04-usbburn.py")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("--images", default=DEFAULT_IMAGES,
                       help=f"build output/images, VR04 or VRX (default {DEFAULT_IMAGES})")
        p.add_argument("--blobs", help="stock loader.bin/vendor.img/uboot0.img (default IMAGES/artlynk-vr04)")
        p.add_argument("--wait", type=float, default=60, help="seconds to wait for the ROM device")
        p.add_argument("--dry-run", action="store_true", help="build and check everything, send nothing")
        p.set_defaults(fn=fn)
        if name == "ram":
            p.add_argument("--bundle", help="RAM boot files (default the one IMAGES/*-testboot)")
            p.add_argument("--no-drm", action="store_true", help="keep the display drivers out")
            p.add_argument("--args", default="", help="more kernel command line")
            p.add_argument("--host", default="192.168.3.100", help="the unit, for the SSH wait")
            p.add_argument("--timeout", type=int, default=120, help="seconds from sent to SSH")
            p.add_argument("--serial", help="console TTY to show meanwhile (optional)")
    a = ap.parse_args()
    a.blobs = a.blobs or os.path.join(a.images, "artlynk-vr04")
    if a.cmd == "ram" and not a.bundle:
        tbs = sorted(n for n in os.listdir(a.images) if n.endswith("-testboot")) if os.path.isdir(a.images) else []
        if len(tbs) != 1:
            sys.exit(f"{a.images}: needs exactly one *-testboot, has {tbs} (--images, --bundle)")
        a.bundle = os.path.join(a.images, tbs[0])
    a.fn(a)


if __name__ == "__main__":
    main()
