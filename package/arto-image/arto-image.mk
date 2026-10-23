################################################################################
#
# arto-image
#
################################################################################

ARTO_IMAGE_SITE_METHOD = local
ARTO_IMAGE_SITE = $(ARTO_IMAGE_PKGDIR)/src
ARTO_IMAGE_LICENSE = GPL-2.0+
ARTO_IMAGE_DEPENDENCIES = lzo

define ARTO_IMAGE_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" -C $(@D)
endef

define ARTO_IMAGE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/arto $(TARGET_DIR)/usr/sbin/arto
endef

$(eval $(generic-package))
