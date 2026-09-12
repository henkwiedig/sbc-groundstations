################################################################################
#
# ar8030
#
################################################################################

# No releases and no tags upstream, so pin the commit. Same commit as
# OpenIPC/builder's air-side ar8030 package -- keep the two in sync.
AR8030_VERSION = 3bb948de118b94d2ede751d55f1b28b7e0b9ab62
AR8030_SITE = http://git.topxgun.com/czdu/yz_host_drv.git
AR8030_SITE_METHOD = git
AR8030_LICENSE = GPL-2.0 (kernel driver), PROPRIETARY (host SDK)
AR8030_INSTALL_STAGING = YES

# cjson: bb_pair (0005-*.patch) links libcjson via pkg-config to persist a
# paired peer into the on-disk baseband config. ascent-vendor-firmware:
# fetches+extracts bb_demo_cx485_2PA.img into BINARIES_DIR before this
# package's own AR8030_FETCH_VENDOR_FIRMWARE hook (below) runs -- see that
# package's extract.py for the full unpack story.
AR8030_DEPENDENCIES = host-pkgconf libusb \
	$(if $(BR2_PACKAGE_AR8030_PAIR_TOOL),cjson) \
	$(if $(BR2_PACKAGE_AR8030_FIRMWARE),ascent-vendor-firmware)

ifeq ($(BR2_PACKAGE_AR8030_TUNTAP),y)
# tuntap_bb's vendored libtuntap (FetchContent'd from a tarball at
# CMake-configure time, not something a 000N-*.patch against this
# package's own git checkout can reach -- see the AR8030_INSTALL_TUNTAP
# comment below) hardcodes /usr/include and /usr/local/include as public
# include dirs unconditionally on ALL Unix, host-native-build assumption
# that predates ever being used in a cross toolchain. Buildroot's
# compiler wrapper refuses those on principle ("unsafe header/library
# path used in cross-compilation" -- exactly the class of bug that
# wrapper exists to catch, since a real host header masking the
# cross-sysroot's one would fail bafflingly later instead of here).
# Strip just those two lines from the tarball's CMakeLists.txt before
# CMake ever unpacks it, rather than patching the resulting build files
# after the fact (FetchContent re-extracts on every configure).
define AR8030_FIX_LIBTUNTAP_TARBALL
	rm -rf $(@D)/third_package/.libtuntap-fix
	mkdir -p $(@D)/third_package/.libtuntap-fix
	tar -xf $(@D)/third_package/libtuntap.tar \
		-C $(@D)/third_package/.libtuntap-fix
	sed -i -e '\|^[[:space:]]*/usr/include/[[:space:]]*$$|d' \
		-e '\|^[[:space:]]*/usr/local/include/[[:space:]]*$$|d' \
		$(@D)/third_package/.libtuntap-fix/libtuntap/CMakeLists.txt
	tar -cf $(@D)/third_package/libtuntap.tar \
		-C $(@D)/third_package/.libtuntap-fix libtuntap
	rm -rf $(@D)/third_package/.libtuntap-fix
endef
AR8030_PRE_CONFIGURE_HOOKS += AR8030_FIX_LIBTUNTAP_TARBALL
endif

#
# Kernel driver (driver/linux, out-of-tree, built by the kernel's own kbuild).
#
# This board's AR8030 is USB-attached only -- no SDIO wiring exists or is
# planned, so this is hardcoded rather than exposed as a choice.
AR8030_MODULE_SUBDIRS = driver/linux

AR8030_MODULE_MAKE_OPTS = \
	DRV_DIR=$(@D)/driver/linux \
	CONFIG_BUS_USB=y \
	CONFIG_BUS_SDIO=n

# Everything the driver links against has to be built *in*, not modular --
# request_firmware()/release_firmware() are called unconditionally, and a
# =m CONFIG_FW_LOADER means those symbols are missing from the kernel's
# Module.symvers (modpost only warns; the failure surfaces later as an
# insmod-time "Unknown symbol").
define AR8030_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_SET_OPT,CONFIG_FW_LOADER,y)
	$(call KCONFIG_SET_OPT,CONFIG_PROC_FS,y)
	$(call KCONFIG_SET_OPT,CONFIG_NET,y)
	$(call KCONFIG_SET_OPT,CONFIG_USB,y)
endef

#
# Userspace (CMake).
#
# USING_8030USB is this board's real runtime transport: once artosyn_drv.ko
# has pushed firmware+config into the chip over USB and it re-enumerates
# with its real firmware running, the module is unloaded (see
# files/etc/init.d/S97ar8030) and ar8030d talks to it directly over USB.
# USING_8030DRV stays on too -- daemon/main.c's /dev/ar_mdev0 path is what
# the driver-push handshake itself rides on before that unload -- so both
# have to be compiled in (0002-*.patch and 0003-*.patch fix build failures
# specific to having USING_8030DRV alongside USING_8030USB).
#
AR8030_CONF_OPTS = \
	-DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
	-DUSING_8030USB=ON \
	-DUSING_8030SDIO=OFF \
	-DUSING_8030UART=OFF \
	-DUSING_8030DRV=ON \
	-DUSING_XDS_HDR=ON \
	-DENABLE_UDS=ON \
	-DENABLE_PYTHON=OFF \
	-DENABLE_JAVA=OFF \
	-DDAEMON_STATIC_LIB=OFF \
	-DAPP_STATIC_LIB=OFF \
	-DBUILD_ARTOSYN_EXAMPLE=OFF \
	-DBUILD_RAM_INIT=ON \
	-DBUILD_TUNTAP=$(if $(BR2_PACKAGE_AR8030_TUNTAP),ON,OFF) \
	-DBUILD_BW_UPDATE_DEMO=OFF \
	-DBUILD_IMG_UPGRADE=OFF \
	-DBUILD_XDATA_TEST=OFF \
	-DBUILD_REPEATER_TEST=OFF \
	-DBUILD_BB_TEST=OFF \
	-DBUILD_WORK_MODE_CFG=OFF \
	-DBUILD_UART_CFG_TEST=OFF \
	-DBUILD_BB_PAIR=$(if $(BR2_PACKAGE_AR8030_PAIR_TOOL),ON,OFF) \
	-DBUILD_USB_TEST_TOOL=$(if $(BR2_PACKAGE_AR8030_USB_LOADER),ON,OFF) \
	-DBUILD_CMD_DBG=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_OTA_UPGRADE=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_TEST_APP=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_NET_DEV_DEMO=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF)

# Upstream's install rules scatter binaries over bin/ and a dev_helper/ prefix
# and call them "daemon", "app" and "ota", so pick the artifacts out of the
# build tree by hand instead.
define AR8030_INSTALL_STAGING_CMDS
	$(INSTALL) -d -m 0755 $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -m 0644 $(@D)/com/bb_api.h $(@D)/com/bb_config.h \
		$(@D)/com/list.h $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -m 0644 $(@D)/app/ar8030/*.h $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/ar8030/libar8030_client.so \
		$(STAGING_DIR)/usr/lib/libar8030_client.so
endef

ifeq ($(BR2_PACKAGE_AR8030_PAIR_TOOL),y)
define AR8030_INSTALL_PAIR_TOOL
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/bb_pair/bb_pair \
		$(TARGET_DIR)/usr/bin/ar8030-pair
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_USB_LOADER),y)
define AR8030_INSTALL_USB_LOADER
	$(INSTALL) -D -m 0755 \
		$(AR8030_BUILDDIR)/dev_helper/ar8030_usb_test_tool/ar8030_usb_test_tool \
		$(TARGET_DIR)/usr/bin/ar8030-usb-loader
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_TOOLS),y)
define AR8030_INSTALL_TOOLS
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/cmd_dbg/cmd_dbg \
		$(TARGET_DIR)/usr/bin/ar8030-cmd-dbg
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/ota_upgrade/ota \
		$(TARGET_DIR)/usr/bin/ar8030-ota
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/test/app \
		$(TARGET_DIR)/usr/bin/ar8030-test
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/net_dev_demo/net_dev_demo \
		$(TARGET_DIR)/usr/bin/ar8030-netdev-demo
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_TUNTAP),y)
# tuntap_bb links a vendored libtuntap/libtuntap++ (FetchContent'd from
# third_package/libtuntap.tar at CMake-configure time,
# not part of this package's own git checkout, so it can't be reached by a
# 000N-*.patch) as shared libs -- Buildroot's cmake-package always forces
# -DBUILD_SHARED_LIBS=ON, and unlike the bundled libusb copy
# (0004-*.patch), this one actually has working install() rules, just not
# ones that run: AR8030_INSTALL_TARGET_CMDS below replaces CMake's own
# install step entirely (same reason libar8030_client.so and the daemon
# are hand-copied instead of relying on `make install`), so they need the
# same explicit treatment.
define AR8030_INSTALL_TUNTAP
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/tuntap_bb/tuntap_bb \
		$(TARGET_DIR)/usr/bin/ar8030-tun
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/_deps/libtuntap-build/lib/libtuntap.so.2.2 \
		$(TARGET_DIR)/usr/lib/libtuntap.so.2.2
	ln -sf libtuntap.so.2.2 $(TARGET_DIR)/usr/lib/libtuntap.so
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/_deps/libtuntap-build/lib/libtuntap++.so.2.1 \
		$(TARGET_DIR)/usr/lib/libtuntap++.so.2.1
	ln -sf libtuntap++.so.2.1 $(TARGET_DIR)/usr/lib/libtuntap++.so
	$(INSTALL) -D -m 0644 $(AR8030_PKGDIR)/files/etc/network/interfaces.d/ar_net0 \
		$(TARGET_DIR)/etc/network/interfaces.d/ar_net0
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_FIRMWARE),y)
# ascent-vendor-firmware's own BUILD_CMDS (a real dependency edge, see
# AR8030_DEPENDENCIES above) has already written bb_demo_cx485_2PA.img
# into BINARIES_DIR by the time this package builds -- copy it into this
# package's own build dir here rather than reading BINARIES_DIR directly
# from AR8030_INSTALL_FIRMWARE below, so a build re-run after BINARIES_DIR
# gets cleaned doesn't silently change this package's install output.
define AR8030_FETCH_VENDOR_FIRMWARE
	mkdir -p $(@D)/vendor-firmware
	if [ -f $(BINARIES_DIR)/bb_demo_cx485_2PA.img ]; then \
		cp $(BINARIES_DIR)/bb_demo_cx485_2PA.img $(@D)/vendor-firmware/; \
	fi
endef
AR8030_PRE_BUILD_HOOKS += AR8030_FETCH_VENDOR_FIRMWARE

# bb_config_gnd_pro.json (plain baseband tuning config) is committed and
# always installed. bb_demo_cx485_2PA.img is an unlicensed vendor binary
# blob -- not committed -- so it's only installed when
# AR8030_FETCH_VENDOR_FIRMWARE (above) managed to fetch one this build;
# see BR2_PACKAGE_AR8030_FIRMWARE's own Config.in help for why a missing
# fetch means no downlink at all on THIS board (unlike a from-flash
# AR8030), not just a soft degradation -- warn loudly rather than
# failing the build outright, so a flaky vendor download doesn't block
# every unrelated change.
define AR8030_INSTALL_FIRMWARE
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/lib/firmware/ar8030
	$(INSTALL) -m 0644 $(AR8030_PKGDIR)/files/lib/firmware/ar8030/bb_config_gnd_pro.json \
		$(TARGET_DIR)/lib/firmware/ar8030
	if [ -f $(@D)/vendor-firmware/bb_demo_cx485_2PA.img ]; then \
		$(INSTALL) -m 0644 $(@D)/vendor-firmware/bb_demo_cx485_2PA.img $(TARGET_DIR)/lib/firmware/ar8030; \
	else \
		echo "ar8030: WARNING -- no vendor bb_demo_cx485_2PA.img fetched this build -- this unit will have NO RF downlink until rebuilt with it present" >&2; \
	fi
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_INIT),y)
define AR8030_INSTALL_INIT
	$(INSTALL) -D -m 0755 $(AR8030_PKGDIR)/files/etc/init.d/S97ar8030 \
		$(TARGET_DIR)/etc/init.d/S97ar8030
	$(INSTALL) -D -m 0644 $(AR8030_PKGDIR)/files/etc/default/ar8030 \
		$(TARGET_DIR)/etc/default/ar8030
endef
endif

# ar8030-status: this project's own addition (files/ar8030-status.c, not part
# of upstream) -- upstream ships pairing (bb_pair) and an AT-style firmware
# debug console (cmd_dbg), but nothing that reports live link/data-channel
# quality. Built directly against the already-built libar8030_client.so and
# headers in the CMake build tree rather than folding it into the CMake
# graph itself, since it's a standalone one-file addition.
define AR8030_BUILD_STATUS_TOOL
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-I$(@D)/com -I$(@D)/app/ar8030 \
		$(AR8030_PKGDIR)/files/ar8030-status.c \
		-L$(AR8030_BUILDDIR)/app/ar8030 -lar8030_client -lpthread -lm \
		$(TARGET_LDFLAGS) \
		-o $(@D)/ar8030-status
endef
AR8030_POST_BUILD_HOOKS += AR8030_BUILD_STATUS_TOOL

define AR8030_INSTALL_STATUS_TOOL
	$(INSTALL) -D -m 0755 $(@D)/ar8030-status $(TARGET_DIR)/usr/bin/ar8030-status
endef

define AR8030_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/ar8030/libar8030_client.so \
		$(TARGET_DIR)/usr/lib/libar8030_client.so
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/daemon/daemon \
		$(TARGET_DIR)/usr/bin/ar8030d
	$(AR8030_INSTALL_PAIR_TOOL)
	$(AR8030_INSTALL_USB_LOADER)
	$(AR8030_INSTALL_TOOLS)
	$(AR8030_INSTALL_TUNTAP)
	$(AR8030_INSTALL_FIRMWARE)
	$(AR8030_INSTALL_INIT)
	$(AR8030_INSTALL_STATUS_TOOL)
endef

$(eval $(kernel-module))
$(eval $(cmake-package))
