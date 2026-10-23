#!/usr/bin/env python3
"""
Boot the BetaFPV VR04 goggles (P1 GND, Artosyn PROXIMA 9311) through their
stock U-Boot over the serial console, without writing the NAND.

  vr04-uboot-boot.py probe                     what this U-Boot can load from
  vr04-uboot-boot.py ram --source sd|ymodem    this build in RAM (initramfs)
  vr04-uboot-boot.py slot-a                    slot A's kernel0/dtb0 from NAND,
                                               without making it the active slot

Getting to the prompt: with stock running, the reboot-to-U-Boot command on
its control port (--trigger stock, /dev/ttyACM0); with this build running,
`vr04-uboot` on the goggles over SSH (--trigger openipc, root password from
$VR04_PASSWORD, default 12345); or by hand (--trigger none). U-Boot then sits
in its USB download gadget; Ctrl-C on the console gives the prompt.

ram: uImage, vr04.dtb and initrd.xz (else initrd.gz) of
output/images/vr04-testboot (--bundle)
come from the first partition of a FAT SD card (--source sd, copy the
bundle's files there) or over the console with YMODEM (--source ymodem,
needs lrzsz's sb; about a minute per 6 MB). Every load is checked by U-Boot's
crc32 against the file's. The command line carries no "ubi.mtd=": with it,
U-Boot regenerates its bootcmd to boot the active slot instead.

slot-a: the gate test before activating slot A -- its kernel and dtb read
from the NAND, booted with the dtb's own command line (bootargs unset), as
the SPL will once slot A is active.

Safety: never saveenv, never a NAND/MMC/SF write or erase, never the USB
upgrade: commands matching DENY are refused here. A power cycle always gets
back to the active slot.

Load map (below the MMZ carveout at 0x29200000, MissingLynk's device.mk):
uImage 0x24000000, initrd 0x26000000 (at most 32 MiB), dtb 0x28000000.
"""
import argparse
import fcntl
import os
import re
import subprocess
import sys
import time
import zlib

import serial

KADDR, RDADDR, DTADDR = 0x24000000, 0x26000000, 0x28000000
RD_MAX = DTADDR - RDADDR
# slot A in the stock layout
KERNEL0, DTB0 = (0x0a40000, 0x600000), (0x1640000, 0x60000)
ARGS = "earlycon console=ttyS0,1152000"
NO_DRM = "modprobe.blacklist=artosyn_vo,artosyn_dsi,panel_qy45043a0"
MAGIC = b"\xAA\x05\x00\x1D\x00\x00\xCC\xEB\xAA\x00"
DENY = re.compile(r"\b(saveenv|env\s+save|env\s+erase|(nand|mtd|sf|mmc|ubi)\s+(write|erase|update|scrub)"
                  r"|gpt\s+write|fatwrite|ext4write|artosyn_hid_upgrade|usb_booting|ums|fastboot|dfu)\b")
DEFAULT_BUNDLE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                               "../../../../output/betafpv_vr04_defconfig/images/vr04-testboot"))


class UBoot:
    def __init__(self, port, log):
        self.s = serial.Serial(port, 1152000, timeout=0.1)
        self.log = open(log, "ab")
        self.prompt = None

    def read(self, t):
        d = self.s.read(65536)
        if d:
            self.log.write(d)
            self.log.flush()
        return d

    def attach(self, timeout=90):
        """Ctrl-C until a prompt shows, and take it as U-Boot's once `version`
        says U-Boot there -- the stock shell still prompts while it goes down."""
        t0, buf = time.time(), b""
        while time.time() - t0 < timeout:
            self.s.write(b"\x03")
            buf = (buf + self.read(0.1))[-4096:]
            m = re.search(rb"\n([^\n]*[=#>] )$", buf.replace(b"\r", b""))
            if not m:
                continue
            self.prompt, buf = m.group(1), b""
            self.s.write(b"version\n")
            out, t1 = b"", time.time()
            while time.time() - t1 < 1.5:
                out += self.read(0.1)
            if b"U-Boot 20" in out:
                self.cmd("")  # settle on the prompt
                print(re.search(rb"U-Boot 20[^\r\n]*", out).group(0).decode())
                return
        sys.exit("no U-Boot prompt on the console")

    def cmd(self, c, timeout=30, echo=True):
        if DENY.search(c):
            sys.exit(f"refused: `{c}` could write the flash")
        self.s.reset_input_buffer()
        self.s.write(c.encode() + b"\n")
        buf, t0 = b"", time.time()
        while time.time() - t0 < timeout:
            buf += self.read(0.1)
            flat = buf.replace(b"\r", b"")
            if flat.endswith(b"\n" + self.prompt) or flat.endswith(self.prompt) and b"\n" in flat:
                out = flat[:-len(self.prompt)].decode(errors="replace")
                out = out.split("\n", 1)[1] if "\n" in out else ""  # drop the echo
                if echo:
                    print(f"=> {c}\n{out}", end="" if out.endswith("\n") or not out else "\n")
                return out
        sys.exit(f"`{c}`: no prompt within {timeout} s")

    def boot(self, c, timeout):
        """Send the boot command and follow the console to a login prompt."""
        if DENY.search(c):
            sys.exit(f"refused: `{c}`")
        print(f"=> {c}")
        self.s.write(c.encode() + b"\n")
        t0, tail = time.time(), b""
        while time.time() - t0 < timeout:
            d = self.read(0.1)
            if d:
                sys.stdout.write(d.decode(errors="replace"))
                sys.stdout.flush()
                tail = (tail + d)[-256:]
                if b"login:" in tail:
                    print("\n-- login prompt")
                    return True
        print(f"\n-- no login prompt within {timeout} s")
        return False


def crc(path):
    with open(path, "rb") as f:
        return zlib.crc32(f.read()) & 0xffffffff


def check_crc(ub, addr, path):
    size = os.path.getsize(path)
    out = ub.cmd(f"crc32 {addr:#x} {size:#x}")
    m = re.search(r"==>\s*([0-9a-fA-F]{8})", out)
    if not m or int(m.group(1), 16) != crc(path):
        sys.exit(f"{os.path.basename(path)}: crc32 in RAM {m and m.group(1)}, file {crc(path):08x}")


def load_sd(ub, dev, part, addr, path):
    name = os.path.basename(path)
    out = ub.cmd(f"fatload mmc {dev}:{part} {addr:#x} {name}", timeout=120)
    m = re.search(r"(\d+) bytes read", out)
    if not m or int(m.group(1)) != os.path.getsize(path):
        sys.exit(f"{name}: not read from mmc {dev}:{part} as built ({out.strip()!r})")
    check_crc(ub, addr, path)


def load_ymodem(ub, addr, path):
    print(f"=> loady {addr:#x}   ({os.path.basename(path)}, {os.path.getsize(path)} B)")
    ub.s.reset_input_buffer()
    ub.s.write(f"loady {addr:#x}\n".encode())
    time.sleep(1)
    # sb gets the console's fd itself; pyserial keeps it non-blocking
    fd = ub.s.fileno()
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    t0 = time.time()
    r = subprocess.run(["sb", "-q", "-k", "--ymodem", path], stdin=fd, stdout=fd)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags)
    if r.returncode:
        sys.exit(f"sb failed ({r.returncode})")
    dt = time.time() - t0
    print(f"   {os.path.getsize(path) / dt / 1024:.0f} KiB/s, {dt:.0f} s")
    time.sleep(1)
    ub.cmd("", timeout=10)
    check_crc(ub, addr, path)


def nand_touch(ub):
    """Without a NAND access in U-Boot the kernel's spi-nand probe fails
    ("unknown raw ID"); a 2 KiB read into the dtb's slot (loaded later)."""
    ub.cmd(f"mtd read spi-nand0 {DTADDR:#x} 0x100000 0x800")


def trigger(how, ctl, host):
    if how == "openipc":
        # the goggles reset under the command, so its SSH session never returns
        subprocess.Popen(["sshpass", "-p", os.environ.get("VR04_PASSWORD", "12345"), "ssh",
                          "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                          "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", f"root@{host}",
                          "/usr/sbin/vr04-uboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("vr04-uboot started on the goggles")
    elif how == "stock":
        if not os.path.exists(ctl):
            sys.exit(f"{ctl} missing: is stock running? (--trigger none if U-Boot is up already)")
        with serial.Serial(ctl, 1152000, timeout=1) as c:
            c.write(MAGIC)
        print("reboot-to-U-Boot sent to stock")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("probe", "ram", "slot-a"))
    ap.add_argument("--serial", default="/dev/ttyUSB0")
    ap.add_argument("--trigger", choices=("stock", "openipc", "none"), default="stock",
                    help="how U-Boot is reached (default: stock's control port)")
    ap.add_argument("--host", default="192.168.3.100", help="the goggles, for --trigger openipc")
    ap.add_argument("--ctl", default="/dev/ttyACM0", help="stock's control port")
    ap.add_argument("--source", choices=("sd", "ymodem"), default="sd")
    ap.add_argument("--mmc", default=None, help="SD card as DEV:PART for U-Boot (default: from probe)")
    ap.add_argument("--bundle", default=DEFAULT_BUNDLE)
    ap.add_argument("--no-drm", action="store_true", help="keep the display drivers out")
    ap.add_argument("--args", default="", help="more kernel command line")
    ap.add_argument("--log", default="vr04-uboot.log", help="console log (appended)")
    ap.add_argument("--timeout", type=int, default=180, help="seconds to a login prompt")
    a = ap.parse_args()

    files = {}
    if a.mode == "ram":
        rd = "initrd.xz" if os.path.isfile(os.path.join(a.bundle, "initrd.xz")) else "initrd.gz"
        for n in ("uImage", "vr04.dtb", rd):
            files[n] = os.path.join(a.bundle, n)
            if not os.path.isfile(files[n]):
                sys.exit(f"missing {files[n]}")
        files["initrd"] = files[rd]
        if os.path.getsize(files["initrd"]) > RD_MAX:
            sys.exit("initrd.gz is larger than the RAM boot's window")

    ub = UBoot(a.serial, a.log)
    trigger(a.trigger, a.ctl, a.host)
    ub.attach()

    if a.mode == "probe":
        for c in ("bdinfo", "printenv", "mmc list", "help mtd", "mtd list"):
            ub.cmd(c)
        for dev in re.findall(r":\s*(\d+)", ub.cmd("mmc list", echo=False)):
            ub.cmd(f"mmc dev {dev}")
            ub.cmd("mmc rescan")
            ub.cmd("mmc info")
            ub.cmd("mmc part")
            ub.cmd(f"fatls mmc {dev}:1")
        print(f"console log: {a.log}; the goggles stay in U-Boot (power-cycle for stock)")
        return

    ub.cmd("setenv initrd_high 0xffffffffffffffff")
    ub.cmd("setenv fdt_high 0xffffffffffffffff")
    nand_touch(ub)

    if a.mode == "slot-a":
        ub.cmd(f"mtd read spi-nand0 {KADDR:#x} {KERNEL0[0]:#x} {KERNEL0[1]:#x}", timeout=60)
        ub.cmd(f"mtd read spi-nand0 {DTADDR:#x} {DTB0[0]:#x} {DTB0[1]:#x}")
        ub.cmd("setenv bootargs")
        ub.boot(f"bootm {KADDR:#x} - {DTADDR:#x}", a.timeout)
        return

    if a.source == "sd":
        if not a.mmc:
            sys.exit("--mmc DEV:PART (see `probe`)")
        dev, part = a.mmc.split(":")
        ub.cmd(f"mmc dev {dev}")
        ub.cmd("mmc rescan")
        load_sd(ub, dev, part, DTADDR, files["vr04.dtb"])
        load_sd(ub, dev, part, KADDR, files["uImage"])
        load_sd(ub, dev, part, RDADDR, files["initrd"])
    else:
        load_ymodem(ub, DTADDR, files["vr04.dtb"])
        load_ymodem(ub, KADDR, files["uImage"])
        load_ymodem(ub, RDADDR, files["initrd"])

    args = " ".join(x for x in (ARGS, "rdinit=/init", NO_DRM if a.no_drm else "", a.args) if x)
    if "ubi.mtd=" in args:
        sys.exit("the RAM boot's command line must not say ubi.mtd=")
    ub.cmd(f"setenv bootargs {args}")
    rd = os.path.getsize(files["initrd"])
    ub.boot(f"bootm {KADDR:#x} {RDADDR:#x}:{rd:#x} {DTADDR:#x}", a.timeout)


if __name__ == "__main__":
    main()
