################################################################################
#
# openipc-bsel
#
################################################################################

OPENIPC_BSEL_SITE_METHOD = local
OPENIPC_BSEL_SITE = $(OPENIPC_BSEL_PKGDIR)/src
OPENIPC_BSEL_LICENSE = GPL-2.0+

define OPENIPC_BSEL_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" -C $(@D)
endef

define OPENIPC_BSEL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/openipc-bsel $(TARGET_DIR)/usr/bin/openipc-bsel
endef

$(eval $(generic-package))
