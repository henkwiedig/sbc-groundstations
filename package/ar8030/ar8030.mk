################################################################################
# AR8030 package (external kernel module)
################################################################################

AR8030_VERSION = 3bb948de118b94d2ede751d55f1b28b7e0b9ab62
AR8030_SITE = http://git.topxgun.com/czdu/yz_host_drv.git
AR8030_SITE_METHOD = git
AR8030_LICENSE = GPL-2.0+

AR8030_MODULE_SUBDIRS = driver/linux
# driver/linux/Makefile's KERNELRELEASE-set branch (the one kbuild actually
# uses when invoked the standard buildroot way, M=<dir> modules) does
# "include $(DRV_DIR)/config.mk" but only ever sets/exports DRV_DIR from
# its OWN "else" branch -- the one taken when its Makefile is run directly
# by hand, which buildroot's kernel-module infra doesn't do. Pass it
# explicitly so config.mk resolves; $(AR8030_DIR) is the same path
# pkg-kernel-module.mk itself passes as M=.
# SDIO bus support is unused on this board (USB-attached module) -- drop it
# rather than carry an unbuilt/untested code path.
AR8030_MODULE_MAKE_OPTS = DRV_DIR=$(AR8030_DIR)/driver/linux CONFIG_BUS_SDIO=n

$(eval $(kernel-module))

define AR8030_INSTALL_FIRMWARE
	mkdir -p $(TARGET_DIR)/lib/firmware
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/package/ar8030/files/bb_demo_cx485_2PA.img \
		$(TARGET_DIR)/lib/firmware/bb_demo_cx485_2PA.img
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/package/ar8030/files/bb_config_gnd_pro.json \
		$(TARGET_DIR)/lib/firmware/bb_config_gnd_pro.json
endef
AR8030_POST_INSTALL_TARGET_HOOKS += AR8030_INSTALL_FIRMWARE

define AR8030_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/package/ar8030/files/S97ar8030 \
		$(TARGET_DIR)/etc/init.d/S97ar8030
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/package/ar8030/files/ar8030.default \
		$(TARGET_DIR)/etc/default/ar8030
endef

$(eval $(generic-package))
