################################################################################
# AR8030_TOOLS package
#
# Userspace daemon + dev_helper tools from the same yz_host_drv SDK as
# package/ar8030's kernel module (separate buildroot package: this half is
# CMake-native, the kernel module is kbuild -- composing both build systems
# in one buildroot package isn't a well-trodden path, so they're split).
################################################################################

AR8030_TOOLS_VERSION = 3bb948de118b94d2ede751d55f1b28b7e0b9ab62
AR8030_TOOLS_SITE = http://git.topxgun.com/czdu/yz_host_drv.git
AR8030_TOOLS_SITE_METHOD = git
AR8030_TOOLS_LICENSE = GPL-2.0+

AR8030_TOOLS_DEPENDENCIES = host-pkgconf libusb

# "basic support" scope: daemon (RPC service that owns the device) +
# dev_helper/autoload (fw/cfg push helper, BUILD_RAM_INIT despite the name)
# + dev_helper/bb_pair (pairing) + dev_helper/ar8030_usb_test_tool
# (diagnostics). Everything else the SDK can build -- app/* demos, the
# goggle-side GlassesUI/ar_ldy_gnd/ar_fpv_mp_service stack, Android/Python/
# Java wrappers -- is out of scope for this groundstation project.
AR8030_TOOLS_CONF_OPTS = \
	-DUSING_8030USB=ON \
	-DUSING_8030SDIO=OFF \
	-DUSING_8030UART=OFF \
	-DUSING_8030DRV=ON \
	-DBUILD_RAM_INIT=ON \
	-DBUILD_TEST_APP=OFF \
	-DBUILD_ARTOSYN_EXAMPLE=OFF \
	-DBUILD_TUNTAP=OFF \
	-DBUILD_BW_UPDATE_DEMO=OFF \
	-DBUILD_IMG_UPGRADE=OFF \
	-DBUILD_XDATA_TEST=OFF \
	-DBUILD_WORK_MODE_CFG=OFF \
	-DBUILD_BB_TEST=OFF \
	-DBUILD_NET_DEV_DEMO=OFF \
	-DBUILD_REPEATER_TEST=OFF \
	-DBUILD_UART_CFG_TEST=OFF \
	-DENABLE_PYTHON=OFF \
	-DENABLE_JAVA=OFF \
	-DDAEMON_STATIC_LIB=OFF \
	-DAPP_STATIC_LIB=OFF

# "daemon" is too generic a name for /usr/bin in a general-purpose rootfs
# (ps/pgrep collisions, hard to identify) -- rename it; S97ar8030 starts it
# under this name.
define AR8030_TOOLS_RENAME_DAEMON
	mv $(TARGET_DIR)/usr/bin/daemon $(TARGET_DIR)/usr/bin/ar8030-daemon
endef
AR8030_TOOLS_POST_INSTALL_TARGET_HOOKS += AR8030_TOOLS_RENAME_DAEMON

# ar8030-status: our own small addition (files/ar8030-status.c, not part of
# upstream) -- upstream ships pairing (bb_pair) and an AT-style firmware
# debug console (cmd_dbg), but nothing that reports live link/data-channel
# quality. Built directly against the already-built libar8030_client.so and
# headers in the CMake build tree rather than folding it into the CMake
# graph itself, since it's a standalone one-file addition.
define AR8030_TOOLS_BUILD_STATUS_TOOL
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-I$(@D)/com -I$(@D)/app/ar8030 \
		$(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/package/ar8030-tools/files/ar8030-status.c \
		-L$(@D)/app/ar8030 -lar8030_client -lpthread -lm \
		$(TARGET_LDFLAGS) \
		-o $(@D)/ar8030-status
endef
AR8030_TOOLS_POST_BUILD_HOOKS += AR8030_TOOLS_BUILD_STATUS_TOOL

define AR8030_TOOLS_INSTALL_STATUS_TOOL
	$(INSTALL) -D -m 0755 $(@D)/ar8030-status $(TARGET_DIR)/usr/bin/ar8030-status
endef
AR8030_TOOLS_POST_INSTALL_TARGET_HOOKS += AR8030_TOOLS_INSTALL_STATUS_TOOL

$(eval $(cmake-package))
