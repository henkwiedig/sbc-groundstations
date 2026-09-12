#!/usr/bin/env python3
"""
BUILD_CMDS for the ascent-vendor-firmware package (see the sibling .mk).
Fetches CADDX's stock "Ascent VRX Pro" OTA image (this board's own ground-
station firmware, an RK3568 Rockchip RKFW container -- NOT the ASW-format
image OpenIPC/builder's air-side ascent-vendor-firmware package unpacks)
and extracts the CX486-RF-2PA baseband demo firmware ar8030 needs out of
it, straight into BINARIES_DIR (images/bb_demo_cx485_2PA.img), the same
directory sdcard.img/u-boot.bin/etc already live in for this build.

Unpack chain (verified by hand against 00_tools/rkunpack.py in the
project's own unpacked_VRX_Pro reference dump -- see
[[caddx-vrxpro-external-resources]] memory -- before being ported here):

  RKFW container (whole vendor .img)
    -> carve out the embedded RKAF "update.img" (offset/size at fixed
       0x19 in the RKFW header: struct.unpack_from('<IIII', h, 0x19)
       gives loader_off/len, update_off/len)
    -> RKAF's own 0x2000-byte header lists each partition's name, and
       its offset/size *within update.img* (NOT the "flash_off/
       flash_size" columns -- those are eMMC/NAND placement, meaningless
       here); find the one named "rootfs"
    -> carve that slice out -- it is itself a raw UBI image (starts
       'UBI#', confirmed via `file`), not a further Rockchip container
    -> `ubireader_extract_files` on that slice reads the full rootfs
       tree, including usr/lib/firmware/bb_demo_cx485_2PA.img

No use for a full RKFW/RKAF parser (loader entries, other partitions,
RC4 decryption) the way 00_tools/rkunpack.py has -- this only ever needs
the one rootfs slice, so the header parsing here is the minimum subset
that gets to it.

Best-effort throughout, same contract as builder's own extract.py: no
network, Google Drive's scrape breaking (see fetch-vendor-img.sh), no
`ubireader_extract_files` on PATH, or the vendor's partition table
changing shape -- any failure here just leaves BINARIES_DIR without
bb_demo_cx485_2PA.img and prints a warning; it must never fail the build
(this board's S97ar8030 does not gracefully degrade without it at
runtime -- see package/ar8030/ar8030.mk's own AR8030_INSTALL_FIRMWARE
comment -- but failing the *build* over a flaky vendor download would be
worse: it would block every unrelated change until Google Drive
cooperates again).

`ubireader_extract_files` is a plain host prerequisite here, NOT a
Buildroot dependency: install it with `pip install --user ubi_reader` if
you want bb_demo_cx485_2PA.img fetched automatically. Missing it just
means this build skips the artifact.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

RKFW_MAGIC = b"RKFW"
RKAF_MAGIC = b"RKAF"
RKAF_HDR_SIZE = 0x2000
RKAF_PART_TABLE_OFF = 0x8C
RKAF_PART_ENTRY_SIZE = 0x70
RKAF_PART_NAME_OFF = 0x5C  # within each entry: <IIIII> nand_size,pos,nand_addr,padded,size

VENDOR_FIRMWARE_FILE = "bb_demo_cx485_2PA.img"
ROOTFS_PARTITION_NAME = "rootfs"


def warn(msg: str) -> None:
    print(f"ascent-vendor-firmware: {msg}", file=sys.stderr)


def cstr(b: bytes) -> str:
    return b.split(b"\x00")[0].decode("utf-8", "replace").strip()


def slice_rootfs_ubi(vendor_img: Path, out_path: Path) -> None:
    data = vendor_img.read_bytes()
    if data[:4] != RKFW_MAGIC:
        raise ValueError(f"bad RKFW magic {data[:4]!r}")

    _ld_off, _ld_len, update_off, update_len = struct.unpack_from("<IIII", data, 0x19)
    update = data[update_off:update_off + update_len]
    if update[:4] != RKAF_MAGIC:
        raise ValueError(f"bad RKAF magic {update[:4]!r} at offset {update_off:#x}")

    nparts, = struct.unpack_from("<I", update, 0x88)
    for i in range(nparts):
        entry = RKAF_PART_TABLE_OFF + i * RKAF_PART_ENTRY_SIZE
        name = cstr(update[entry:entry + 0x20])
        if name != ROOTFS_PARTITION_NAME:
            continue
        _nand_size, pos, _nand_addr, _padded, size = struct.unpack_from(
            "<IIIII", update, entry + RKAF_PART_NAME_OFF)
        rootfs = update[pos:pos + size]
        if rootfs[:4] != b"UBI#":
            raise ValueError(f"'{ROOTFS_PARTITION_NAME}' partition isn't a UBI image "
                              f"(magic {rootfs[:4]!r})")
        out_path.write_bytes(rootfs)
        return
    raise ValueError(f"no '{ROOTFS_PARTITION_NAME}' partition in the RKAF table "
                      f"({nparts} partitions)")


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: extract.py <binaries-dir> <vendor-file-id> <cache-dir>", file=sys.stderr)
        return 0

    binaries_dir = Path(sys.argv[1])
    vendor_file_id = sys.argv[2]
    cache_dir = Path(sys.argv[3])

    fetch_script = Path(__file__).parent / "fetch-vendor-img.sh"
    vendor_img = cache_dir / "Ascent_VRX_Pro.img"

    ubireader = shutil.which("ubireader_extract_files")
    if ubireader is None:
        warn("ubireader_extract_files not found on PATH (pip install --user ubi_reader)")
        return 0

    try:
        subprocess.run(
            [str(fetch_script), str(vendor_img)],
            check=True, env={**os.environ, "FILE_ID": vendor_file_id},
        )
    except subprocess.CalledProcessError:
        warn("could not fetch the vendor image")
        return 0

    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        rootfs_ubi = work / "rootfs.img"
        try:
            slice_rootfs_ubi(vendor_img, rootfs_ubi)
        except (ValueError, IndexError, struct.error) as e:
            warn(f"could not parse the vendor image ({e})")
            return 0

        extracted = work / "extracted"
        try:
            subprocess.run(
                [ubireader, "-o", str(extracted), str(rootfs_ubi)],
                check=True, capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as e:
            warn(f"ubireader_extract_files failed ({e.stderr.strip()[-200:]})")
            return 0

        matches = list(extracted.rglob(VENDOR_FIRMWARE_FILE))
        if not matches:
            warn(f"{VENDOR_FIRMWARE_FILE} not found in the extracted rootfs volume")
            return 0

        binaries_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(matches[0], binaries_dir / VENDOR_FIRMWARE_FILE)
        print(f"ascent-vendor-firmware: wrote {binaries_dir}/{VENDOR_FIRMWARE_FILE}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
