#!/bin/sh
#
# betafpv_vr04 post-image.
#
# uImage.ar9311: the arm64 Image in the container the stock SPL/U-Boot boot
# (it rejects a raw `booti`), same layout as the stock kernel0/kernel1
# partitions (see MissingLynk's glue/flash/mkkernel.py):
#   64 B OTRA header: "OTRA", +0x0c load address, +0x10 size of what
#        follows padded to 256 B, +0x20 byte sum over it (bootm ignores the
#        sum; it is filled in as in the stock kernel0, for the SPL's flash boot)
#   legacy uImage, comp=lz4, load/entry 0x200a0000
#   LZ4 frame with independent 4 MiB blocks and a content checksum -- the
#        lz4 CLI's defaults with -B7; U-Boot rejects linked blocks
#
# Two device trees, MissingLynk's goggle DT with different command lines:
#   vr04-flash.dtb  for a slot (dtb0/dtb1). The stock SPL boots the active
#                   slot itself (Falcon): it loads kernelN and dtbN and takes
#                   the command line from the dtb, rewriting ubi.mtd= to the
#                   slot's userapp (17 for userapp0, 18 for userapp1) in place,
#                   so the number must stay numeric. The rootfs is squashfs on
#                   the "rootfs" UBI volume, through a UBI block device, as in
#                   stock's slots; init=/init puts the rootfs_data overlay
#                   over it.
#   vr04-ram.dtb    for a RAM boot through the stock U-Boot: initramfs, and
#                   no "ubi.mtd=" anywhere -- with that in its bootargs U-Boot
#                   regenerates its bootcmd to boot the active slot instead.
# Both mark spl0-3, vendor and factory read-only: shared by both slots, or
# unique to the unit, and give both SD/SDIO hosts their FIFO depth: without
# fifo-depth, dw_mmc reads it back from the FIFOTH value it programmed at
# its previous bind, half the real 128, and halves it again on every bind.
# And the dwc2 a USB role switch, peripheral by default (the RNDIS gadget),
# that /usr/sbin/usb-host turns to host for WiFi cards (wfb, apfpv).
#
# rootfs.ubi (ubinize.cfg) for userapp0/1; vr04-testboot/ for the RAM boot
# (scripts/vr04-uboot-boot.py: SD card or YMODEM); and on the stock image
# package/artlynk-vr04-vendor-firmware used, the update image
# <stock release>_OpenIPC_<sha>.img that /sbin/sysupgrade and
# scripts/vr04-install.py flash into a slot.

set -e
LOAD=0x200a0000
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)
DTB=proxima-9311.dtb
ARGS="earlycon console=ttyS0,1152000"
FLASH_ARGS="${ARGS} ubi.mtd=17 ubi.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=squashfs rootwait ro init=/init"
RAM_ARGS="${ARGS} rdinit=/init"
PLATFORM=$(sed -n 's|^BR2_DEFCONFIG=".*/\(.*\)_defconfig"$|\1|p' "${BR2_CONFIG}")
# The host's python3, which has python-lzo (a host prerequisite); Buildroot's
# own host-python3 comes first on PATH here when a package pulled it in.
SYSPY=$(PATH=$(echo "${PATH}" | tr : '\n' | grep -v "^${HOST_DIR}" | paste -sd: -) command -v python3)
FDTPUT="${HOST_DIR}/bin/fdtput"
FDTGET="${HOST_DIR}/bin/fdtget"

cd "${BINARIES_DIR}"

"${HOST_DIR}/bin/lz4" -B7 -9 -f -q Image Image.lz4
"${HOST_DIR}/bin/mkimage" -A arm64 -O linux -T kernel -C lz4 \
	-a ${LOAD} -e ${LOAD} -n Sirius -d Image.lz4 uImage.lz4 >/dev/null

size=$(stat -c %s uImage.lz4)
padded=$(( (size + 255) / 256 * 256 ))
head -c $((padded - size)) /dev/zero >> uImage.lz4
python3 - ${LOAD} uImage.lz4 <<'PY' > uImage.ar9311
import struct, sys
load, body = int(sys.argv[1], 0), open(sys.argv[2], "rb").read()
h = bytearray(0x40)
h[0:4] = b"OTRA"
struct.pack_into("<II", h, 0x0c, load, len(body))
struct.pack_into("<I", h, 0x20, sum(body) & 0xFFFFFFFF)
sys.stdout.buffer.write(bytes(h) + body)
PY
rm -f Image.lz4 uImage.lz4

PARTS=/soc/spi@1e00000/flash@0/partitions
for variant in flash ram; do
	cp ${DTB} vr04-${variant}.dtb
	[ ${variant} = flash ] && args=${FLASH_ARGS} || args=${RAM_ARGS}
	"${FDTPUT}" -t s vr04-${variant}.dtb /chosen bootargs "${args}"
	for p in 0 40000 80000 c0000 180000 200000; do
		"${FDTPUT}" vr04-${variant}.dtb ${PARTS}/partition@${p} read-only
	done
	for mmc in mmc@1b00000 mmc@1c00000; do
		"${FDTPUT}" -t i vr04-${variant}.dtb /soc/${mmc} fifo-depth 128
	done
	"${FDTPUT}" vr04-${variant}.dtb /soc/usb@8000000 usb-role-switch
	"${FDTPUT}" -t s vr04-${variant}.dtb /soc/usb@8000000 role-switch-default-mode peripheral
done
[ "$("${FDTGET}" vr04-flash.dtb /chosen bootargs | grep -o 'ubi\.mtd=[0-9]*')" = ubi.mtd=17 ] ||
	{ echo "post-image: vr04-flash.dtb has no single ubi.mtd=17"; exit 1; }
! "${FDTGET}" vr04-ram.dtb /chosen bootargs | grep -q 'ubi\.mtd=' ||
	{ echo "post-image: vr04-ram.dtb must not say ubi.mtd="; exit 1; }
[ "$("${FDTGET}" vr04-flash.dtb ${PARTS}/partition@200000 label)" = factory ] ||
	{ echo "post-image: ${PARTS} is not the stock layout"; exit 1; }

"${HOST_DIR}/sbin/ubinize" -o rootfs.ubi -p 0x20000 -m 2048 -s 2048 \
	"${BOARD_DIR}/ubinize.cfg"

# Against the slot partitions. userapp holds 360 PEBs; UBI keeps 24 of them
# (see ubinize.cfg), and a bad block takes one more. The rootfs volume is
# 28 MiB. The initramfs has the RAM boot's window from 0x26000000 to the dtb
# at 0x28000000.
check() {
	file=$1 limit=$2
	size=$(stat -c %s "$file")
	echo "- $file: [$((size / 1024))KB/$((limit / 1024))KB, $((size * 100 / limit))%]"
	if [ "$size" -gt "$limit" ]; then
		echo "-- does not fit by $((size - limit)) bytes"
		exit 1
	fi
	if [ $((limit - size)) -lt 65536 ]; then
		echo "-- headroom warning: $(((limit - size) / 1024))KB left"
	fi
}
check uImage.ar9311 $((0x600000))
check vr04-flash.dtb $((0x60000))
check rootfs.squashfs $((28 * 1024 * 1024))
check rootfs.ubi $((336 * 0x20000))

# The RAM boot only installs: its initramfs is the rootfs without the video
# stack (PixelPilot, msposd, GStreamer, the codec firmware), the WiFi
# receiving (wfb-ng, wpa_supplicant, the drivers), the menu's air access
# (OpenSSH client and its OpenSSL), the DVR share and the time zones. It
# unpacks into a tmpfs limited to half the RAM the kernel gets (61 MB next
# to the MMZ carveout and the ramoops area).
"${SYSPY}" "${BOARD_DIR}/cpio-filter.py" rootfs.cpio ramboot.cpio \
	usr/bin/pixelpilot usr/bin/pixelpilot.sh etc/init.d/S99pixelpilot \
	usr/share/pixelpilot/ etc/pixelpilot/ lib/firmware/cnm/ \
	usr/lib/gstreamer-1.0/ usr/libexec/gstreamer-1.0/ usr/bin/gst-\* \
	usr/share/gstreamer-1.0/ usr/share/gst-plugins-base/ 'usr/lib/libgst*' \
	'usr/lib/libglib-2.0*' 'usr/lib/libgio-2.0*' 'usr/lib/libgobject-2.0*' \
	'usr/lib/libgmodule-2.0*' 'usr/lib/libgthread-2.0*' usr/lib/gio/ \
	'usr/lib/liblvgl*' 'usr/lib/libspdlog*' 'usr/lib/libfmt*' 'usr/lib/libyaml-cpp*' \
	'usr/lib/libpng*' 'usr/lib/libmsgpack*' 'usr/lib/liborc*' 'usr/lib/libpcre2*' \
	'usr/lib/libffi*' '*/libgfortran.so*' '*/libgomp.so*' \
	usr/bin/msposd etc/init.d/S98msposd usr/share/fonts/ 'usr/lib/libcairo*' \
	'usr/lib/libpixman*' 'usr/lib/libsqlite3*' 'usr/lib/libevent*' \
	usr/share/zoneinfo/ 'usr/bin/wfb*' 'usr/sbin/wpa_*' 'lib/modules/*/updates/88*.ko' \
	'lib/modules/*/updates/8812*.ko' 'lib/modules/*/kernel/net/wireless/*' \
	'usr/lib/libnl*' usr/sbin/iw 'usr/lib/libpcap*' 'usr/lib/libsodium*' \
	'usr/lib/libcrypto*' 'usr/lib/libssl*' usr/lib/ossl-modules/ usr/lib/engines-3/ \
	usr/bin/openssl usr/bin/ssh usr/bin/scp usr/bin/sshpass usr/bin/yaml-cli \
	etc/init.d/S91smb etc/ksmbd/ usr/libexec/ksmbd.tools 'usr/sbin/ksmbd.*' \
	'lib/modules/*/kernel/fs/smb/*'
gzip -9 -n -c ramboot.cpio > ramboot.cpio.gz
check ramboot.cpio.gz $((0x2000000))
check ramboot.cpio $((28 * 1024 * 1024))

# RAM boot bundle: copy the directory's files onto a FAT SD card, or let
# vr04-uboot-boot.py send them with YMODEM
rm -rf vr04-testboot
mkdir vr04-testboot
cp uImage.ar9311 vr04-testboot/uImage
cp vr04-ram.dtb vr04-testboot/vr04.dtb
cp ramboot.cpio.gz vr04-testboot/initrd.gz
# a third smaller than the gzip one: YMODEM over the console is ~37 KiB/s.
# The kernel's unxz wants CRC32 and allocates the whole dictionary.
"${HOST_DIR}/bin/xz" -9e --check=crc32 --lzma2=preset=9e,dict=8MiB -T1 -c ramboot.cpio > vr04-testboot/initrd.xz
(cd vr04-testboot && md5sum uImage vr04.dtb initrd.gz initrd.xz > MD5SUMS)
tar -C vr04-testboot -cf "${PLATFORM}_testboot.tar" .

# On the stock image package/artlynk-vr04-vendor-firmware used (its path and
# release name in artlynk-vr04/stock-image). Best-effort like those blobs:
# without the stock image or python-lzo there is no update image.
rm -f P1_GND_*_OpenIPC_*.img
sha=$(git -C "${BR2_EXTERNAL_OPENIPC_SBC_GS_PATH}" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "${BR2_EXTERNAL_OPENIPC_SBC_GS_PATH}" diff --quiet HEAD 2>/dev/null || sha=${sha}-dirty
if [ -f artlynk-vr04/stock-image ]; then
	img="$(sed -n 2p artlynk-vr04/stock-image)_OpenIPC_${sha}.img"
	if "${SYSPY}" "${BOARD_DIR}/scripts/ar9311-image.py" pack \
		--base "$(sed -n 1p artlynk-vr04/stock-image)" --kernel uImage.ar9311 \
		--dtb vr04-flash.dtb --userapp rootfs.ubi --out "${img}"; then
		md5sum "${img}" > "${img}.md5sum"
		tar -czf "${PLATFORM}.tar.gz" "${img}" "${img}.md5sum"
	else
		echo "post-image: WARNING: no OpenIPC update image (python-lzo installed?)"
	fi
else
	echo "post-image: WARNING: no stock P1_GND image to build the OpenIPC update image on"
fi
