#!/usr/bin/env python3
"""
Build an OpenIPC update image for the BetaFPV P1 / VR04 goggles (Artosyn
PROXIMA 9311) in the layout of BetaFPV's stock ones (P1_SKY_*.img,
P1_GND_*.img, Artosyn "ARTO"):

  ar9311-image.py pack --base P1_GND_v2.1.3_20260825_7bad614.img \\
      --kernel uImage.ar9311 --dtb vr04-flash.dtb --userapp rootfs.ubi \\
      --out P1_GND_v2.1.3_20260825_7bad614_OpenIPC_<sha>.img

(copied from OpenIPC builder's devices/ar9311_artosyn_artlynk-p1/scripts)

The stock image gives the header, the loader (the SPL), the partition table
and the vendor, env and uboot segments, its stored bytes unchanged: the SPL
and the signed stock U-Boot go on as they are. The kernel, dtb and userapp
segments are this build's, LZO1X-compressed like the stock ones, in segments
of at most 4 MiB as there. The header's customer version says "OpenIPC" (stock:
"haming"), which is how /usr/sbin/sysupgrade tells the two apart; the SHA-256
is this image's own and the RSA signature stays empty, so the stock flasher
(U-Boot's USB upgrade) rejects it -- sysupgrade and ar9311-install.py take it.

Format: package/arto-image/src/arto.c. Host prerequisite: python-lzo (as for
package/artlynk-vr04-vendor-firmware).
"""
import argparse
import hashlib
import struct
import sys

import lzo

MAGIC = 0x4152544F
BASE_HDR = 0x100
PART_ENTRY = 0x34
SEG_ENTRY = 0x20
# No stock segment unpacks to more than 4 MiB (userapp comes in 4 MiB pieces,
# the kernel is 4.16 MB): U-Boot's USB upgrade may size its buffer for that.
SEGMENT = 0x400000
CUSTOMER = b"OpenIPC"


def parse(data):
    if struct.unpack_from("<I", data, 0)[0] != MAGIC:
        sys.exit("base: not an ARTO image")
    hext = struct.unpack_from("<H", data, 8)[0]
    rom, loader = struct.unpack_from("<II", data, 0x18)
    nparts, nsegs = struct.unpack_from("<HH", data, 0x20)
    body = BASE_HDR + hext + 0x120
    if hashlib.sha256(data[body:]).digest() != data[BASE_HDR + hext:BASE_HDR + hext + 32]:
        sys.exit("base: SHA-256 mismatch")
    ptab = body + rom + loader
    parts = {}
    for i in range(nparts):
        e = data[ptab + i * PART_ENTRY:ptab + (i + 1) * PART_ENTRY]
        off, size = struct.unpack_from("<QQ", e, 0x20)
        parts[e[:0x20].split(b"\0")[0].decode()] = (off, size)
    stab = ptab + nparts * PART_ENTRY
    segs = [struct.unpack_from("<QQQQ", data, stab + i * SEG_ENTRY) for i in range(nsegs)]
    return {"hext": hext, "body": body, "rom": rom, "loader": loader, "ptab": ptab,
            "nparts": nparts, "parts": parts, "segs": segs, "compressed": data[5]}


def part_of(parts, flash_off):
    for name, (off, size) in parts.items():
        if off <= flash_off < off + size:
            return name
    return None


def cmd_pack(a):
    base = open(a.base, "rb").read()
    b = parse(base)
    if not b["compressed"]:
        sys.exit("base: uncompressed segments (a stock image has LZO ones)")
    kernel = open(a.kernel, "rb").read()
    dtb = open(a.dtb, "rb").read()
    userapp = open(a.userapp, "rb").read()
    for name, blob, magic in (("kernel", kernel, b"OTRA"), ("dtb", dtb, b"\xd0\x0d\xfe\xed"),
                              ("userapp", userapp, b"UBI#")):
        if blob[:4] != magic:
            sys.exit(f"--{name}: wrong magic")
    for part, blob in (("kernel0", kernel), ("dtb0", dtb), ("userapp0", userapp)):
        if part not in b["parts"] or len(blob) > b["parts"][part][1]:
            sys.exit(f"{part}: missing in the base, or the image does not fit it")

    # (flash offset, stored bytes, size): the base's own for vendor/env/uboot,
    # ours for kernel/dtb/userapp.
    segs = []
    for file_off, flash_off, stored, size in b["segs"]:
        if part_of(b["parts"], flash_off) in ("vendor", "env0", "uboot0"):
            segs.append((flash_off, base[file_off:file_off + stored], size))
    for part, blob in (("kernel0", kernel), ("dtb0", dtb), ("userapp0", userapp)):
        off = b["parts"][part][0]
        for i in range(0, len(blob), SEGMENT):
            chunk = blob[i:i + SEGMENT]
            stored = lzo.compress(chunk, 9, False)
            if lzo.decompress(stored, False, len(chunk)) != chunk:
                sys.exit(f"{part}: LZO round trip failed")
            segs.append((off + i, stored, len(chunk)))
    segs.sort()

    loader = base[b["body"] + b["rom"]:b["body"] + b["rom"] + b["loader"]]
    rom = base[b["body"]:b["body"] + b["rom"]]
    ptable = base[b["ptab"]:b["ptab"] + b["nparts"] * PART_ENTRY]
    body = BASE_HDR + b["hext"] + 0x120
    data_off = body + len(rom) + len(loader) + len(ptable) + len(segs) * SEG_ENTRY
    stab, blobs, pos = b"", [], data_off
    for flash_off, stored, size in segs:
        stab += struct.pack("<QQQQ", pos, flash_off, len(stored), size)
        blobs.append(stored)
        pos += len(stored)
    after_sig = rom + loader + ptable + stab + b"".join(blobs)

    hdr = bytearray(base[:BASE_HDR + b["hext"]])
    hdr[0x2c:0x40] = CUSTOMER.ljust(0x14, b"\0")
    struct.pack_into("<Q", hdr, 0x10, len(after_sig))
    struct.pack_into("<H", hdr, 0x22, len(segs))
    out = bytes(hdr) + hashlib.sha256(after_sig).digest() + bytes(0x100) + after_sig
    parse(out)  # its own hash and tables
    with open(a.out, "wb") as f:
        f.write(out)
    print(f"{a.out}: {len(out)} bytes, {len(segs)} segments")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack", help="build an OpenIPC image on a stock one")
    p.add_argument("--base", required=True, help="stock P1_SKY_*.img / P1_GND_*.img")
    p.add_argument("--kernel", required=True, help="uImage.ar9311 (OTRA)")
    p.add_argument("--dtb", required=True, help="the flash dtb")
    p.add_argument("--userapp", required=True, help="rootfs.ubi")
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_pack)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
