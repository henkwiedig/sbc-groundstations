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

# The rootfs volume is 34 MiB. Nothing here links libgfortran or libgomp,
# the toolchain installs its libraries into /lib and /usr/lib as two copies
# each, and msposd's cairo and sqlite bring their command line tools.
rm -f lib/libgfortran.so* usr/lib/libgfortran.so* lib/libgomp.so* usr/lib/libgomp.so* \
	lib/libstdc++.so.*-gdb.py usr/lib/libstdc++.so.*-gdb.py usr/bin/fc-* usr/bin/sqlite3
for f in lib/*.so*; do
	[ -f "$f" ] && [ ! -L "$f" ] && [ -f "usr/$f" ] && [ ! -L "usr/$f" ] &&
		cmp -s "$f" "usr/$f" && ln -sf "../usr/$f" "$f"
done

# Python is there for wfb-server (wfb-ng's ground side; wfb_ng imports
# twisted.internet, .protocols and .python only): no test suites, no Twisted
# protocols it doesn't use, no setuptools (its entry scripts import wfb_ng
# directly) or ensurepip -- half of the 51 MB.
PY=$(ls -d usr/lib/python3.* 2>/dev/null | head -n 1)
if [ -n "$PY" ]; then
	find "$PY" -depth -type d \( -name test -o -name tests \) -exec rm -rf {} +
	rm -rf "$PY"/ensurepip "$PY"/site-packages/setuptools* "$PY"/site-packages/pkg_resources \
		"$PY"/site-packages/_distutils_hack "$PY"/site-packages/distutils-precedence.pth
	for p in conch mail words names web trial spread positioning pair runner news; do
		rm -rf "$PY/site-packages/twisted/$p"
	done
fi

# DVR re-encode at 20 Mbit/s (stock records at 8 or 20): the package's 50
# with the OSD running saturates both cores and the recording stays empty.
# And at 30 fps: decoding a 20 Mbit/s 1080p60 stream and encoding 1080p60
# on the one wave5 core drops the live video every few seconds (30 s
# recording: 11 dropouts at 60 fps, 2 at 30).
# The link is the AR8030 (no WiFi): the menu's link pages and the link
# widgets come from lifecycled.
[ ! -f etc/default/pixelpilot ] ||
	sed -i -e 's/^PIXELPILOT_DVR_BITRATE=.*/PIXELPILOT_DVR_BITRATE="20000"/' \
		-e 's/^PIXELPILOT_DVR_FPS=.*/PIXELPILOT_DVR_FPS="30"/' \
		-e 's/^PIXELPILOT_RX_MODE=.*/PIXELPILOT_RX_MODE="artosyn"/' etc/default/pixelpilot

# Artosyn is the receiver mode at boot: wfb-ng and adaptive-link start only
# once the menu switches to wfb (its rx_mode setter flips these).
for f in etc/default/wifibroadcast etc/default/adaptive-link; do
	[ ! -f $f ] || sed -i 's/^\(WIFIBROADCAST\|ADAPTIVE_LINK\)_ENABLED=.*/\1_ENABLED=false/' $f
done

grep -q "betafpv-vr04 /init" init || { echo "post-build: /init is not the VR04 one"; exit 1; }
[ ! -e boot/Image ] || { echo "post-build: the kernel Image is in the rootfs"; exit 1; }

missing=
for m in artosyn_gpio dw_mci-artosyn artosyn_adc artosyn_protemp artosyn_pwm \
	artosyn_vo artosyn_dsi panel-qy45043a0 fat vfat wave5 artosyn_drv; do
	find lib/modules -name "$m.ko*" | grep -q . || missing="$missing $m"
done
[ -z "$missing" ] || { echo "post-build: kernel modules missing:$missing"; exit 1; }
