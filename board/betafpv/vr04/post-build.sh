#!/bin/sh
#
# betafpv_vr04 post-build, after board/common/post-build-script.sh: drops what
# the common overlay brings for the Rockchip boards' U-Boot/display, and stops
# the build if what the goggles need to come up is missing.

set -e
cd "${TARGET_DIR}"

rm -rf boot/extlinux boot/uboot-menu.env usr/share/splash.bmp usr/share/splash-bg.bmp \
	etc/network/interfaces.d/eth0

# eudev's hardware database (17 MB, nothing here looks names up in it):
# a RAM boot unpacks the rootfs into a tmpfs of half the RAM, about 30 MB.
# Also when BR2_PACKAGE_EUDEV_ENABLE_HWDB was switched off in an existing
# output tree, which keeps the files.
rm -rf etc/udev/hwdb.d lib/udev/hwdb.d lib/udev/hwdb.bin etc/udev/hwdb.bin

# The rootfs volume is 28 MiB. Nothing here links libgfortran or libgomp,
# the toolchain installs its libraries into /lib and /usr/lib as two copies
# each, and msposd's cairo and sqlite bring their command line tools.
rm -f lib/libgfortran.so* usr/lib/libgfortran.so* lib/libgomp.so* usr/lib/libgomp.so* \
	lib/libstdc++.so.*-gdb.py usr/lib/libstdc++.so.*-gdb.py usr/bin/fc-* usr/bin/sqlite3
# OpenSSH is here for the menu's ssh/scp to the air unit only
rm -f usr/bin/sftp usr/bin/ssh-add usr/bin/ssh-agent usr/bin/ssh-copy-id \
	usr/libexec/ssh-keysign usr/libexec/ssh-pkcs11-helper usr/libexec/sftp-server
for f in lib/*.so*; do
	[ -f "$f" ] && [ ! -L "$f" ] && [ -f "usr/$f" ] && [ ! -L "usr/$f" ] &&
		cmp -s "$f" "usr/$f" && ln -sf "../usr/$f" "$f"
done

# DVR re-encode at 20 Mbit/s (stock records at 8 or 20): the package's 50
# with the OSD running saturates both cores and the recording stays empty.
# And at 30 fps: decoding a 20 Mbit/s 1080p60 stream and encoding 1080p60
# on the one wave5 core drops the live video every few seconds (30 s
# recording: 11 dropouts at 60 fps, 2 at 30).
# The link is the AR8030 (no WiFi): the menu's link pages and the link
# widgets come from lifecycled.
# Vsync lock on, as on the VRX Pro: artosyn_vo's pclk_hz trims the panel's
# pixel clock (+-1000 ppm measured exact, no DSI errors), so the panel
# follows the camera.
[ ! -f etc/default/pixelpilot ] ||
	sed -i -e 's/^PIXELPILOT_DVR_BITRATE=.*/PIXELPILOT_DVR_BITRATE="20000"/' \
		-e 's/^PIXELPILOT_DVR_FPS=.*/PIXELPILOT_DVR_FPS="30"/' \
		-e 's/^PIXELPILOT_RX_MODE=.*/PIXELPILOT_RX_MODE="artosyn"/' \
		-e 's/^PIXELPILOT_VSYNC_LOCK=.*/PIXELPILOT_VSYNC_LOCK="--vsync-lock"/' etc/default/pixelpilot
grep -q '^PIXELPILOT_VSYNC_LOCK="--vsync-lock"' etc/default/pixelpilot ||
	{ echo "post-build: no PIXELPILOT_VSYNC_LOCK in etc/default/pixelpilot"; exit 1; }

# Artosyn is the receiver mode at boot: wfb-ng (this board's own lean
# S98wifibroadcast) starts only once the menu switches to wfb.
[ ! -f etc/default/wifibroadcast ] ||
	sed -i 's/^WIFIBROADCAST_ENABLED=.*/WIFIBROADCAST_ENABLED=false/' etc/default/wifibroadcast

grep -q "betafpv-vr04 /init" init || { echo "post-build: /init is not the VR04 one"; exit 1; }
[ ! -e boot/Image ] || { echo "post-build: the kernel Image is in the rootfs"; exit 1; }

missing=
for m in artosyn_gpio dw_mci-artosyn artosyn_adc artosyn_protemp artosyn_pwm \
	artosyn_vo artosyn_dsi panel-qy45043a0 fat vfat wave5 artosyn_drv; do
	find lib/modules -name "$m.ko*" | grep -q . || missing="$missing $m"
done
[ -z "$missing" ] || { echo "post-build: kernel modules missing:$missing"; exit 1; }
