#!/bin/sh
#
# betafpv_vr04 post-build, after board/common/post-build-script.sh: drops what
# the common overlay brings for the Rockchip boards' U-Boot/display, and stops
# the build if what the goggles need to come up is missing.

set -e
cd "${TARGET_DIR}"

rm -rf boot/extlinux boot/uboot-menu.env usr/share/splash.bmp usr/share/splash-bg.bmp \
	usr/share/splash.png etc/network/interfaces.d/eth0

# eudev's hardware database (17 MB, nothing here looks names up in it):
# a RAM boot unpacks the rootfs into a tmpfs of half the RAM, about 30 MB.
# Also when BR2_PACKAGE_EUDEV_ENABLE_HWDB was switched off in an existing
# output tree, which keeps the files.
rm -rf etc/udev/hwdb.d lib/udev/hwdb.d lib/udev/hwdb.bin etc/udev/hwdb.bin

# DVR re-encode at 20 Mbit/s (stock records at 8 or 20): the package's 50
# with the OSD running saturates both cores and the recording stays empty.
[ ! -f etc/default/pixelpilot ] ||
	sed -i 's/^PIXELPILOT_DVR_BITRATE=.*/PIXELPILOT_DVR_BITRATE="20000"/' etc/default/pixelpilot

grep -q "betafpv-vr04 /init" init || { echo "post-build: /init is not the VR04 one"; exit 1; }
[ ! -e boot/Image ] || { echo "post-build: the kernel Image is in the rootfs"; exit 1; }

missing=
for m in artosyn_gpio dw_mci-artosyn artosyn_adc artosyn_protemp artosyn_pwm \
	artosyn_vo artosyn_dsi panel-qy45043a0 fat vfat wave5 artosyn_drv; do
	find lib/modules -name "$m.ko*" | grep -q . || missing="$missing $m"
done
[ -z "$missing" ] || { echo "post-build: kernel modules missing:$missing"; exit 1; }
