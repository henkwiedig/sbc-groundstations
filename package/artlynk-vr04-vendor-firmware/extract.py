#!/usr/bin/env python3
"""
BUILD_CMDS for artlynk-vr04-vendor-firmware (see the sibling .mk).

  extract.py OUT_DIR HOST_DIR CACHE_DIR RELEASE

Extracts the proprietary blobs betafpv_vr04 needs from BetaFPV's stock P1 GND
OTA image (P1_GND_*.img, Artosyn "ARTO" container) into OUT_DIR
(BINARIES_DIR/artlynk-vr04/):

  loader.bin, vendor.img, env0.img, uboot0.img
                        stock SPL, DDR training firmware, env and U-Boot: the
                        OpenIPC update image is packed on them, and sysupgrade
                        refuses an image whose SPL/vendor differ from the NAND's
  kernel0.img, gnd.dtb  stock kernel (OTRA container) and DT, for reference
  wave521c_k3_codec_fw.bin
                        Wave521C codec firmware (stock /usr/bin/chagall.bin.gz),
                        requested by the wave5 V4L2 driver as cnm/...
  bb_demo_gnd.img, bb_demo_gnd_d.img, bb_config_gnd*.json
                        stock AR8030 ground firmware and RF configs, kept for
                        later (nothing installs them yet)
  stock-image           the stock image's path and release name, one per line

The image is GND's if its header product is "P1_GND_VR04" (2.0.x) or "IGNORE"
(2.1.x); the VR04 PRO and SKY/AIO images are refused. Lookup order:
$ARTLYNK_VR04_VENDOR_IMG, CACHE_DIR/RELEASE.img, the newest CACHE_DIR/P1_GND_*.img.

Best-effort throughout, same contract as ascent-vendor-firmware: a missing
image or host tool prints a warning and leaves the artifact out; this script
never fails the build. Host prerequisites (not Buildroot packages):
python-lzo (pip install python-lzo), ubi_reader (pip install ubi_reader);
unsquashfs comes from HOST_DIR (host-squashfs).
"""
import glob
import gzip
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
ARTO_MAGIC = b"OTRA"  # 0x4152544f little-endian
GND_PRODUCTS = (b"P1_GND_VR04", b"IGNORE")

# stock rootfs path -> output name
ROOTFS_FILES = {
    "usr/bin/chagall.bin.gz": "chagall.bin.gz",
    "usr/usrdata/ar813x/bb_demo_gnd.img": "bb_demo_gnd.img",
    "usr/usrdata/ar813x/bb_config_gnd.json": "bb_config_gnd.json",
    "usr/usrdata/ar813x/bb_config_gnd_5m.json": "bb_config_gnd_5m.json",
    "usr/usrdata/product/ar813x/bb_demo_gnd_d.img": "bb_demo_gnd_d.img",
}


def warn(msg):
    print(f"artlynk-vr04-vendor-firmware: WARNING: {msg}", file=sys.stderr)


def product(img):
    with open(img, "rb") as f:
        hdr = f.read(0xc0)
    if hdr[:4] != ARTO_MAGIC:
        return None
    return hdr[0x80:0xc0].split(b"\0")[0]


def find_image(cache, release):
    env = os.environ.get("ARTLYNK_VR04_VENDOR_IMG")
    if env:
        return Path(env) if Path(env).is_file() else None
    pinned = Path(cache, f"{release}.img")
    if pinned.is_file():
        return pinned
    hits = sorted(glob.glob(str(Path(cache, "P1_GND_*.img"))), key=os.path.getmtime)
    return Path(hits[-1]) if hits else None


def extract_rootfs_files(userapp_img, out, tmp, host_dir):
    if not shutil.which("ubireader_extract_images"):
        warn("ubireader_extract_images not found (pip install ubi_reader) - no rootfs blobs")
        return
    unsquashfs = Path(host_dir, "bin/unsquashfs")
    unsquashfs = str(unsquashfs) if unsquashfs.exists() else shutil.which("unsquashfs")
    if not unsquashfs:
        warn("unsquashfs not found - no rootfs blobs")
        return
    ubi_out = tmp / "ubi"
    subprocess.run(["ubireader_extract_images", "-o", str(ubi_out), str(userapp_img)],
                   check=True, stdout=subprocess.DEVNULL)
    vols = [p for p in ubi_out.rglob("*") if p.is_file() and p.read_bytes()[:4] == b"hsqs"]
    if not vols:
        warn("no squashfs volume in the stock userapp UBI image")
        return
    root = tmp / "root"
    subprocess.run([unsquashfs, "-no-xattrs", "-d", str(root), str(vols[0]), *ROOTFS_FILES],
                   check=True, stdout=subprocess.DEVNULL)
    for src, name in ROOTFS_FILES.items():
        if (root / src).is_file():
            shutil.copy(root / src, out / name)
        else:
            warn(f"stock rootfs has no {src}")
    gz = out / "chagall.bin.gz"
    if gz.is_file():
        (out / "wave521c_k3_codec_fw.bin").write_bytes(gzip.decompress(gz.read_bytes()))
        gz.unlink()


def main():
    out, host_dir, cache, release = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    out.mkdir(parents=True, exist_ok=True)

    img = find_image(cache, release)
    if img is None:
        warn(f"stock P1_GND_*.img not found (set ARTLYNK_VR04_VENDOR_IMG or put {release}.img "
             f"in {cache}/) - building without codec firmware and without the update image")
        return 0
    prod = product(img)
    if prod not in GND_PRODUCTS:
        warn(f"{img}: product {prod!r} is not a VR04 goggle image {GND_PRODUCTS} - not used")
        return 0
    print(f"artlynk-vr04-vendor-firmware: using {img} (product {prod.decode()})")
    (out / "stock-image").write_text(f"{img.resolve()}\n{img.stem}\n")

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        parts = tmp / "parts"
        r = subprocess.run([sys.executable, str(HERE / "p1_ota_extract.py"), str(img), str(parts)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0 or not parts.is_dir():
            warn(f"OTA extraction failed (python-lzo installed?): {r.stderr.strip()[-300:]}")
            return 0

        for name in ("loader.bin", "vendor.img", "env0.img", "uboot0.img", "kernel0.img"):
            if (parts / name).is_file():
                shutil.copy(parts / name, out / name)
        if (parts / "dtb0.img").is_file():
            d = (parts / "dtb0.img").read_bytes()
            i = d.find(FDT_MAGIC)
            if i >= 0:
                (out / "gnd.dtb").write_bytes(d[i:i + struct.unpack_from(">I", d, i + 4)[0]])
        if (parts / "userapp0.img").is_file():
            try:
                extract_rootfs_files(parts / "userapp0.img", out, tmp, host_dir)
            except subprocess.CalledProcessError as e:
                warn(f"stock rootfs extraction failed: {e}")

    for f in sorted(out.iterdir()):
        print(f"  {f.name}: {f.stat().st_size} B")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never fail the build
        warn(f"unexpected error: {e}")
        sys.exit(0)
