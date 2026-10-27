#!/usr/bin/env python3
"""
BUILD_CMDS for artlynk-vr04-vendor-firmware (see the sibling .mk).

  extract.py OUT_DIR HOST_DIR CACHE_DIR RELEASE [ASCENT_GND_CFG
             [FILE_ID ASCENT_RELEASE ASCENT_FILE_ID]]

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
                        stock AR8030 ground firmware and RF configs, for
                        reference (the goggles run the Ascent ground firmware)
  ascent_gnd.img, ascent_gnd.json
                        the Ascent ground baseband firmware and config of the
                        Caddx Ascent L Gnd (another AR9311 SDIO ground), from
                        its stock image -- see extract_ascent_gnd()
  vr04_gnd.json         the goggles' baseband config, see make_gnd_config()
  stock-image           the stock image's path and release name, one per line

The image is GND's if its header product is "P1_GND_VR04" (2.0.x) or "IGNORE"
(2.1.x); the VR04 PRO and SKY/AIO images are refused. Lookup order:
$ARTLYNK_VR04_VENDOR_IMG, CACHE_DIR/RELEASE.img, fetched to that name from
Google Drive (FILE_ID, fetch-vendor-img.sh), the newest CACHE_DIR/P1_GND_*.img.
The Ascent one: $ASCENT_L_GND_IMG, CACHE_DIR/ASCENT_RELEASE.img, fetched to
that name out of CADDX's Ascent bundle zip (ASCENT_FILE_ID, the one
package/ascent-vendor-firmware downloads), the newest
CACHE_DIR/Ascent_L_Gnd_*.img.

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


def fetch(file_id, out, member=None):
    """Fetch a stock image from Google Drive into the cache; True when it is there."""
    if not file_id:
        return False
    cmd = [str(HERE / "fetch-vendor-img.sh"), file_id, str(out)] + ([member] if member else [])
    if subprocess.run(cmd).returncode == 0 and out.is_file():
        return True
    warn(f"could not fetch {out.name}")
    return False


def find_image(cache, release, file_id=None):
    env = os.environ.get("ARTLYNK_VR04_VENDOR_IMG")
    if env:
        return Path(env) if Path(env).is_file() else None
    pinned = Path(cache, f"{release}.img")
    if pinned.is_file() or fetch(file_id, pinned):
        return pinned
    hits = sorted(glob.glob(str(Path(cache, "P1_GND_*.img"))), key=os.path.getmtime)
    return Path(hits[-1]) if hits else None


# Ascent L Gnd usr_data: fpv/boot_ar8030/<name> -> output name
ASCENT_GND_FILES = {"bb_demo_gnd_3v3.img": "ascent_gnd.img", "bb_config_gnd.json": "ascent_gnd.json"}


def find_ascent_gnd(cache, release=None, file_id=None):
    env = os.environ.get("ASCENT_L_GND_IMG")
    if env:
        return Path(env) if Path(env).is_file() else None
    if release:
        pinned = Path(cache, f"{release}.img")
        if pinned.is_file() or fetch(file_id, pinned, pinned.name):
            return pinned
    hits = sorted(glob.glob(str(Path(cache, "Ascent_L_Gnd_*.img"))), key=os.path.getmtime)
    return Path(hits[-1]) if hits else None


def extract_ascent_gnd(img, out, tmp):
    """ascent_gnd.img/.json: the AR8030 firmware for the goggles.

    The goggles' AR8030 sits on SDIO and has to run an SDIO firmware of the
    Ascent generation the air units run (BetaFPV's own uses an older MAC frame
    header). The VRX Pro's ground images (bb_demo_cx485_2PA.img, ...) only
    speak USB to their host: on SDIO the chip boots them and never comes back.
    The Caddx Ascent L Gnd is an AR9311 ground with the AR8030 on SDIO like the
    goggles; its stock image is a 128-byte CADDX "ASW" header in front of an
    Artosyn ARTO image whose usr_data0 UBI volume holds fpv/boot_ar8030/.
    """
    d = img.read_bytes()
    i = d.find(ARTO_MAGIC, 0, 4096)
    if d[:4] != b"ASW\0" or i < 0:
        warn(f"{img}: not an Ascent ASW+ARTO image - no Ascent ground firmware")
        return
    arto = tmp / "ascent-gnd.arto"
    arto.write_bytes(d[i:])
    parts = tmp / "ascent-gnd"
    r = subprocess.run([sys.executable, str(HERE / "p1_ota_extract.py"), str(arto), str(parts)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    usr = parts / "usr_data0.img"
    if r.returncode != 0 or not usr.is_file():
        warn(f"{img}: no usr_data0 ({r.stderr.strip()[-200:]}) - no Ascent ground firmware")
        return
    if not shutil.which("ubireader_extract_files"):
        warn("ubireader_extract_files not found (pip install ubi_reader) - no Ascent ground firmware")
        return
    files = tmp / "ascent-gnd-usr"
    subprocess.run(["ubireader_extract_files", "-o", str(files), str(usr)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for name, outname in ASCENT_GND_FILES.items():
        hits = [p for p in files.rglob(name) if p.parent.name == "boot_ar8030"]
        if hits:
            shutil.copy(hits[0], out / outname)
        else:
            warn(f"{img}: no fpv/boot_ar8030/{name}")


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


def make_gnd_config(out, ascent_cfg):
    """vr04_gnd.json: the Ascent ground config with the goggles' own power setup.

    The goggles run the Ascent ground firmware (ascent_gnd.img, see
    extract_ascent_gnd()): BetaFPV's own baseband firmware uses an older MAC
    frame header and cannot link with the Ascent air firmware the P1 air unit
    and the Ascent air units run. So the Ascent ground config is the base --
    DEV role, link parameters, the full 42-entry channel table the air units
    share -- the Ascent L Gnd's own (ascent_gnd.json), else package/ar8030's
    VRX Pro one (ascent_cfg); only the goggles' own PA setup comes from the
    stock ground config: the power section and the PA calibration, the same
    split OpenIPC/builder makes for the P1 air unit. The stock "board" key is
    not carried over: the Ascent firmware has no board profiles.
    """
    import json

    stock = out / "bb_config_gnd.json"
    if (out / "ascent_gnd.json").is_file():
        ascent_cfg = out / "ascent_gnd.json"
    if not (ascent_cfg and Path(ascent_cfg).is_file() and stock.is_file()):
        warn("no Ascent ground config or stock bb_config_gnd.json - no vr04_gnd.json")
        return
    vr04, cfg = json.loads(stock.read_text()), json.loads(Path(ascent_cfg).read_text())
    cfg["baseband"]["power_calibration"] = vr04["baseband"]["power_calibration"]
    cfg["baseband"]["basic"]["power"] = vr04["baseband"]["basic"]["power"]
    (out / "vr04_gnd.json").write_text(json.dumps(cfg, indent=1))


def main():
    out, host_dir, cache, release = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    ascent_cfg = sys.argv[5] if len(sys.argv) > 5 else None
    file_id, ascent_release, ascent_file_id = (sys.argv[6:9] + [None] * 3)[:3]
    out.mkdir(parents=True, exist_ok=True)

    img = find_image(cache, release, file_id)
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

    gnd = find_ascent_gnd(cache, ascent_release, ascent_file_id)
    if gnd is None:
        warn(f"no Ascent_L_Gnd_*.img in {cache}/ (set ASCENT_L_GND_IMG) - no AR8030 firmware for the goggles")
    else:
        print(f"artlynk-vr04-vendor-firmware: using {gnd}")
        with tempfile.TemporaryDirectory() as t:
            try:
                extract_ascent_gnd(gnd, out, Path(t))
            except subprocess.CalledProcessError as e:
                warn(f"Ascent ground firmware extraction failed: {e}")
    make_gnd_config(out, ascent_cfg)
    for f in sorted(out.iterdir()):
        print(f"  {f.name}: {f.stat().st_size} B")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never fail the build
        warn(f"unexpected error: {e}")
        sys.exit(0)
