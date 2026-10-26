#!/usr/bin/env python3
"""
Flash the BetaFPV VR04 goggles (P1 GND, Artosyn PROXIMA 9311) through their
stock U-Boot's USB upgrade -- no serial console, no opening the case, no RAM
boot -- with any update image in BetaFPV's format: their P1_GND_*.img, or this
build's P1_GND_*_OpenIPC_*.img.
(ar9311-usbburn.py of OpenIPC builder's devices/ar9311_artosyn_artlynk-p1,
for the goggles)

  vr04-usbburn.py flash IMAGE [--from-stock [TTY] | --from-openipc [HOST]] [--debug]
  vr04-usbburn.py info IMAGE
  vr04-usbburn.py probe [--from-stock [TTY] | --from-openipc [HOST]]
      U-Boot's status channel only: a 64-byte image without the ARTO magic,
      which U-Boot rejects before writing anything; every report it sends
      back is printed raw

Getting there: the stock firmware reboots into U-Boot's upgrade mode on a
10-byte command over its USB serial gadget (--from-stock sends it, default
/dev/ttyACM0 at 1152000 baud); this build does with /usr/sbin/vr04-uboot
(--from-openipc runs it over SSH, root password from $VR04_PASSWORD, default
12345). U-Boot then enumerates as 1d6b:0100 "USB download gadget" (HID) and
takes one image.

Stock's own SD-card upgrade (bind held 2-10 s with artosyn-upgrade-ars31.img
on the card) is no way in: its Linux-side artosyn_upgrade enforces the RSA
signature.

What U-Boot does with the image (the goggles' stock U-Boot of v2.1.3, as on
the P1 air unit): it checks the RSA signature but does not enforce it
("signature verification fail", then "Verify upgrade image success"), so
OpenIPC images go in too. It writes the slot that is not active -- env,
uboot, kernel, dtb, userapp (ubiformat, bad blocks skipped), plus the shared
vendor partition -- rewrites all four SPL copies from the image's loader and
the GPT into the other copy (gpt0/gpt1, the old one erased), making that slot
the active one, verifies, and asks for a reset. Nothing carries over: an
OpenIPC slot comes up with an empty overlay (root password 12345, unpaired).
The upload runs at about 27 KiB/s (28 bytes per HID report, one report per
USB frame): ~18 min for an OpenIPC image of 30 MB, ~23 for stock 2.1.3; the
write after it about 12 s. Then a power cycle boots the new slot.

Protocol (reversed from the U-Boot binary; the packet layout is Henk Wiedig's
FreeArtLynk usbflasher.py): every HID report starts with a 36-byte header --
magic FF 55 FF AA "ARTO", +0x10 u32 inner size (<= 64, U-Boot's MTU), +0x14
u32 chunk count, +0x18 u32 chunk index, +0x1c sub-protocol 1 -- and the first
chunk of a message then a 12-byte inner header (u16 port 0, u16 header length
12, u32 payload size). The start command is one 56-byte message, "upgd" + the
image size; the image is one message of 64-byte reports, 16 bytes of it in the
first and 28 in every following one. U-Boot answers in the same framing with
text. A message spans several reports (U-Boot's MTU), of which only the
first ever arrives, and after a full upload not even that: U-Boot logs "Hid
send timeout!" for every report while a read is pending here (no read,
reads that time out, a read always pending: the same). Its write takes
about 12 s after the upload, so flash waits a minute for a "upgrade complete"
/ "upgrade failed!(" that arrives in short sessions (probe) and then says
to power-cycle.

U-Boot's report descriptor declares numbered reports (input 3 and 4, output
1 and 2), but its packets start with the FF 55 magic: the kernel's HID core
takes 0xff for an undeclared report ID and drops every report U-Boot sends,
so its status only arrives through libusb (pyusb), which detaches the HID
driver and reads endpoint 0x81 itself. Without access to the USB device the
tool falls back to /dev/hidrawN: the upload works, the status does not come.

Access (and the serial gadget for --from-stock), e.g.
/etc/udev/rules.d/80-artosyn.rules:
  SUBSYSTEM=="usb", ATTRS{idVendor}=="1d6b", ATTRS{idProduct}=="0100", MODE="0660", GROUP="plugdev"
  SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1d6b", ATTRS{idProduct}=="0100", MODE="0660", GROUP="plugdev"
"""
import argparse
import glob
import hashlib
import math
import os
import queue
import re
import select
import struct
import subprocess
import sys
import threading
import time

VID_PID = "00001D6B:00000100"
REBOOT_CMD = b"\xAA\x05\x00\x1D\x00\x00\xCC\xEB\xAA\x00"
SERIAL_BAUD = 1152000
IMAGE_MAGIC = 0x4152544F

MAGIC = bytes([0xFF, 0x55, 0xFF, 0xAA]) + b"ARTO"
MTU = 64
OUTER = 36
INNER = 12
FIRST = MTU - OUTER - INNER     # image bytes in the first report
CONT = MTU - OUTER              # image bytes in every following one


def outer(inner_size, chunks, index):
    h = bytearray(OUTER)
    h[0:8] = MAGIC
    struct.pack_into("<III", h, 0x10, inner_size, chunks, index)
    h[0x1C] = 1
    return h


def start_cmd(size):
    cmd = b"upgd" + struct.pack("<I", size)
    return bytes(outer(INNER + len(cmd), 1, 0) + struct.pack("<HHI4x", 0, INNER, len(cmd)) + cmd)


def data_reports(image):
    """The image as one message: 64-byte reports."""
    chunks = math.ceil((INNER + len(image)) / CONT)
    first = image[:FIRST]
    yield bytes((outer(INNER + len(first), chunks, 0) + struct.pack("<HHI4x", 0, INNER, len(image))
                 + first).ljust(MTU, b"\0"))
    for i, pos in enumerate(range(FIRST, len(image), CONT), 1):
        yield bytes((outer(CONT, chunks, i) + image[pos:pos + CONT]).ljust(MTU, b"\0"))


def check_image(data):
    """(product, customer, signed) after checking what U-Boot needs."""
    if len(data) < 0x220 or struct.unpack_from("<I", data, 0)[0] != IMAGE_MAGIC:
        sys.exit("not an ARTO update image")
    hext = struct.unpack_from("<H", data, 8)[0]
    body = 0x100 + hext + 0x120
    if hashlib.sha256(data[body:]).digest() != data[0x100 + hext:0x100 + hext + 32]:
        sys.exit("SHA-256 mismatch: damaged or truncated")
    if data[6] != 2:
        sys.exit(f"flash type {data[6]}, not NAND")
    product = data[0x80:0xc0].split(b"\0")[0].decode(errors="replace")
    # the goggles' images: P1_GND_VR04 up to 2.0.6, IGNORE since 2.1.3
    if product not in ("P1_GND_VR04", "IGNORE"):
        sys.exit(f"product {product!r}, not P1_GND_VR04 (or IGNORE): not a VR04 image")
    customer = data[0x2c:0x40].split(b"\0")[0].decode(errors="replace")
    return product, customer, any(data[0x100 + hext + 32:body])


class Gadget:
    """U-Boot's upgrade gadget: libusb if allowed (status readable), else hidraw."""

    def __init__(self, timeout, debug=False):
        deadline = time.time() + timeout
        self.usb = self.fd = None
        self.text = bytearray()
        self.debug = debug
        while not self.open():
            if time.time() > deadline:
                sys.exit("no 1d6b:0100 (U-Boot's upgrade mode) appeared")
            time.sleep(0.5)

    def open(self):
        try:
            import usb.core
            import usb.util
        except ImportError:
            usb = None
        if usb:
            dev = usb.core.find(idVendor=0x1D6B, idProduct=0x0100)
            if dev is None:
                return False
            try:
                if dev.is_kernel_driver_active(0):
                    dev.detach_kernel_driver(0)
                usb.util.claim_interface(dev, 0)
                self.usb = dev
                # A read is kept pending on endpoint 0x81 all the time, as
                # hidapi does: U-Boot's report goes out only while one is.
                self.queue = queue.Queue()
                threading.Thread(target=self.reader, daemon=True).start()
                print(f"U-Boot upgrade gadget on USB bus {dev.bus} device {dev.address} (libusb)")
                return True
            except usb.core.USBError as e:
                print(f"libusb: {e}; using hidraw, without U-Boot's status (udev rule, see --help)")
        for uevent in glob.glob("/sys/class/hidraw/hidraw*/device/uevent"):
            if f"HID_ID=0003:{VID_PID}" in open(uevent).read():
                dev = "/dev/" + uevent.split("/")[4]
                try:
                    self.fd = os.open(dev, os.O_RDWR)
                except PermissionError:
                    sys.exit(f"{dev}: permission denied (udev rule, see --help)")
                print(f"U-Boot upgrade gadget at {dev} (hidraw: no status from U-Boot)")
                return True
        return False

    def write(self, report):
        if self.usb:
            self.usb.write(0x02, report, timeout=1000)
        else:
            os.write(self.fd, b"\0" + report)   # report ID 0, stripped by the kernel

    def reader(self):
        # No timeout: a read that times out is cancelled, and after a few
        # thousand cancels during an upload U-Boot can no longer send a single
        # report ("Hid send timeout!" for every one).
        import usb.core
        while True:
            try:
                self.queue.put(bytes(self.usb.read(0x81, MTU, timeout=0)))
            except usb.core.USBTimeoutError:
                continue
            except usb.core.USBError:
                self.queue.put(None)   # gone: U-Boot reset, or unplugged
                return

    def read(self, timeout):
        """One report from U-Boot, None after timeout seconds."""
        if self.usb:
            try:
                raw = self.queue.get(timeout=timeout) if timeout else self.queue.get_nowait()
            except queue.Empty:
                return None
            if raw is None:
                raise OSError("the gadget is gone")
            return raw
        if select.select([self.fd], [], [], timeout)[0]:
            return os.read(self.fd, MTU)
        return None

    def poll(self, timeout=0.0):
        """Reads what U-Boot sent; returns the messages completed."""
        done = []
        while True:
            raw = self.read(timeout)
            if raw is None:
                return done
            timeout = 0
            if self.debug:
                print(f"\n  IN {len(raw):2d}: {raw.hex()}", end="")
            # A leading report ID (the descriptor declares numbered reports)
            # shifts the frame by one byte.
            if raw[1:5] == MAGIC[:4] and raw[:4] != MAGIC[:4]:
                raw = raw[1:]
            if len(raw) < OUTER:
                continue
            chunks, index = struct.unpack_from("<II", raw, 0x14)
            if index == 0:
                # The first 16 characters say enough on their own ("upgrade
                # failed!(", "upgrade complete"): taken now, in case the rest
                # of the message never comes.
                self.text = bytearray(raw[OUTER + INNER:])
                head = self.text.split(b"\0")[0].decode(errors="replace").strip()
                if head and chunks > 1:
                    done.append(head)
            else:
                self.text += raw[OUTER:]
            if index + 1 >= chunks:
                msg = self.text.split(b"\0")[0].decode(errors="replace").strip()
                if msg and (chunks > 1 or index == 0):
                    done.append(msg)
            else:
                timeout = 0.2   # the rest follows the read of this one


def report(msgs, state):
    for m in msgs:
        if m == state.get("last"):
            continue
        state["last"] = m
        p = re.search(r"percent\D*(\d+)", m)
        if p:
            if p.group(1) != state.get("pct"):
                state["pct"] = p.group(1)
                print(f"\n  U-Boot: writing, {p.group(1)}%", end="", flush=True)
        elif not (state.get("pct") and m.lower().startswith("upgrade status")):
            print(f"\n  U-Boot: {m}", end="", flush=True)
        low = m.lower().replace("_", " ")
        if "upgrade complete" in low:
            state["result"] = True
        elif "upgrade fail" in low:
            state["result"] = False


def enter(a):
    """Into U-Boot's upgrade mode: stock's command, or vr04-uboot on OpenIPC."""
    if a.from_stock:
        try:
            import serial
        except ImportError:
            sys.exit("--from-stock needs pyserial")
        with serial.Serial(a.from_stock, SERIAL_BAUD, timeout=1) as s:
            s.write(REBOOT_CMD)
        print(f"sent the upgrade command on {a.from_stock}")
    elif a.from_openipc:
        # the goggles reset under the command, so its SSH session never returns
        subprocess.Popen(["sshpass", "-p", os.environ.get("VR04_PASSWORD", "12345"), "ssh",
                          "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                          "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
                          f"root@{a.from_openipc}", "/usr/sbin/vr04-uboot"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"vr04-uboot started on {a.from_openipc}")


def cmd_flash(a):
    data = open(a.image, "rb").read()
    product, customer, signed = check_image(data)
    print(f"{os.path.basename(a.image)}: {product}, customer {customer!r}, "
          f"{'signed' if signed else 'unsigned'}, {len(data)} bytes")
    enter(a)
    g = Gadget(a.timeout, a.debug)
    state = {}

    g.write(start_cmd(len(data)))
    report(g.poll(0.5), state)
    total = math.ceil((INNER + len(data)) / CONT)
    t0 = time.time()
    for i, r in enumerate(data_reports(data)):
        g.write(r)
        if i % 256 == 0:
            report(g.poll(), state)
            sent = min(len(data), FIRST + i * CONT)
            rate = sent / max(time.time() - t0, 1e-3)
            print(f"\r  uploading {sent * 100 // len(data):3d}%  {rate / 1024:5.1f} KiB/s  "
                  f"{(len(data) - sent) / rate / 60:4.1f} min left ", end="", flush=True)
    print(f"\r  uploaded {len(data)} bytes in {(time.time() - t0) / 60:.1f} min" + " " * 20, end="")

    deadline = time.time() + a.write_timeout
    while state.get("result") is None and time.time() < deadline:
        print(f"\r  waiting for U-Boot's write, {deadline - time.time():3.0f} s ", end="", flush=True)
        try:
            report(g.poll(1.0), state)
        except Exception:
            break   # gadget gone: U-Boot finished and reset
    print()
    if state.get("result") is False:
        sys.exit("U-Boot reports the upgrade failed; the active slot is unchanged")
    if state.get("result") is None:
        print("U-Boot reports nothing over USB after a full upload, but writes in about 12 s "
              "(\"upgrade complete!\" on its serial console): power-cycle the board now")
    else:
        print("done: power-cycle the board, it boots the slot just written")


def cmd_probe(a):
    """64 bytes without the ARTO magic: rejected before any write; its answer raw."""
    enter(a)
    g = Gadget(a.timeout, debug=True)
    junk = bytes(64)
    g.write(start_cmd(len(junk)))
    msgs = g.poll(1.0)
    for r in data_reports(junk):
        g.write(r)
    deadline = time.time() + 20
    while time.time() < deadline:
        msgs += g.poll(1.0)
    print()
    for m in dict.fromkeys(msgs):
        print(f"  U-Boot: {m}")
    print(f"{len(msgs)} message(s); U-Boot rejected the probe, nothing was written. "
          "Power-cycle the board to leave the upgrade mode.")


def cmd_info(a):
    data = open(a.image, "rb").read()
    product, customer, signed = check_image(data)
    print(f"{product}, customer {customer!r}, {'signed' if signed else 'unsigned'}, "
          f"{len(data)} bytes, ~{len(data) / 27.5 / 1024 / 60:.0f} min upload")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("flash", help="flash an update image through U-Boot's USB upgrade")
    p.add_argument("image", help="P1_GND_*.img (stock) or P1_GND_*_OpenIPC_*.img")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--from-stock", nargs="?", const="/dev/ttyACM0", metavar="TTY",
                   help="send stock's upgrade command first (default /dev/ttyACM0)")
    g.add_argument("--from-openipc", nargs="?", const="192.168.3.100", metavar="HOST",
                   help="run vr04-uboot on this build first, over SSH (default 192.168.3.100)")
    p.add_argument("--timeout", type=float, default=60, help="seconds to wait for the gadget")
    p.add_argument("--write-timeout", type=float, default=60,
                   help="seconds to wait for U-Boot's write after the upload (it takes ~12)")
    p.add_argument("--debug", action="store_true", help="print every report U-Boot sends, raw")
    p.set_defaults(fn=cmd_flash)
    p = sub.add_parser("probe", help="U-Boot's status channel, with an image it rejects")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--from-stock", nargs="?", const="/dev/ttyACM0", metavar="TTY",
                   help="send stock's upgrade command first (default /dev/ttyACM0)")
    g.add_argument("--from-openipc", nargs="?", const="192.168.3.100", metavar="HOST",
                   help="run vr04-uboot on this build first, over SSH (default 192.168.3.100)")
    p.add_argument("--timeout", type=float, default=60, help="seconds to wait for the gadget")
    p.set_defaults(fn=cmd_probe)
    p = sub.add_parser("info", help="check an image as flash would")
    p.add_argument("image")
    p.set_defaults(fn=cmd_info)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
