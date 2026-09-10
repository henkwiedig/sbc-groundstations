################################################################################
#
# ar8030-transport-rx
#
################################################################################

# ar8030-transport is not pushed yet, so this download will 404 until
# `git push origin master` to https://github.com/henkwiedig/ar8030-transport.
# To build against a working tree instead (no push needed, picks up
# uncommitted edits), same OVERRIDE_SRCDIR mechanism builder's waybeam
# package uses:
#
#   echo 'AR8030_TRANSPORT_RX_OVERRIDE_SRCDIR = /home/henk/Dokumente/fpv/OpenIPC/ar8030-transport' \
#       >> $(O)/local.mk
#
# or as a plain environment variable to make.
AR8030_TRANSPORT_RX_VERSION = master
AR8030_TRANSPORT_RX_SITE = https://github.com/henkwiedig/ar8030-transport.git
AR8030_TRANSPORT_RX_SITE_METHOD = git
AR8030_TRANSPORT_RX_LICENSE = MIT
AR8030_TRANSPORT_RX_LICENSE_FILES = LICENSE

# Needs the ar8030 package's already-built libar8030_client.so + headers
# (staged to $(STAGING_DIR)/usr/include/ar8030 and .../usr/lib -- see
# package/ar8030/ar8030.mk's AR8030_INSTALL_STAGING_CMDS) and its 0008
# datagram-mode-symmetry patch (see this package's Config.in help).
AR8030_TRANSPORT_RX_DEPENDENCIES = ar8030

# rx/Makefile is a standalone Makefile (also usable outside Buildroot --
# see ar8030-transport's own README), so this just invokes it with the
# cross compiler and the ar8030 package's staging paths instead of
# folding the build into Buildroot's own machinery. linkctl/ (see its
# own README section) is built the same way -- it's a separate binary,
# not tied to rx specifically, but this package is the natural place to
# build+install the ground-side copy since it already stages against
# this same ar8030 dependency.
define AR8030_TRANSPORT_RX_BUILD_CMDS
	$(MAKE) -C $(@D)/rx \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
	$(MAKE) -C $(@D)/linkctl \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
endef

define AR8030_TRANSPORT_RX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rx/ar8030-transport-rx \
		$(TARGET_DIR)/usr/bin/ar8030-transport-rx
	$(INSTALL) -D -m 0755 $(@D)/linkctl/ar8030-linkctl \
		$(TARGET_DIR)/usr/bin/ar8030-linkctl
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/init.d/S98ar8030-transport-rx \
		$(TARGET_DIR)/etc/init.d/S98ar8030-transport-rx
	$(INSTALL) -D -m 0644 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/default/ar8030-transport-rx \
		$(TARGET_DIR)/etc/default/ar8030-transport-rx
endef

$(eval $(generic-package))
