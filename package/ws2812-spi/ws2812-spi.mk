################################################################################
#
# ws2812-spi
#
################################################################################

WS2812_SPI_SITE_METHOD = local
WS2812_SPI_SITE = $(WS2812_SPI_PKGDIR)/src
WS2812_SPI_LICENSE = GPL-2.0+

define WS2812_SPI_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" -C $(@D)
endef

define WS2812_SPI_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ws2812-spi $(TARGET_DIR)/usr/bin/ws2812-spi
endef

$(eval $(generic-package))
