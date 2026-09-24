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
AR8030_TRANSPORT_RX_VERSION = dd62a75fb2e9633d95b04277b8435ffca704b901
AR8030_TRANSPORT_RX_SITE = https://github.com/henkwiedig/ar8030-transport.git
AR8030_TRANSPORT_RX_SITE_METHOD = git
AR8030_TRANSPORT_RX_LICENSE = MIT
AR8030_TRANSPORT_RX_LICENSE_FILES = LICENSE

# Needs the ar8030 package's already-built libar8030_client.so + headers
# (staged to $(STAGING_DIR)/usr/include/ar8030 and .../usr/lib -- see
# package/ar8030/ar8030.mk's AR8030_INSTALL_STAGING_CMDS) and its 0008
# datagram-mode-symmetry patch (see this package's Config.in help).
# cjson: lifecycled/ (pairing/tuning persistence, lifecycle_pair.c/
# lifecycle_tuning.c) links it directly, same as ar8030's own bb_pair.
AR8030_TRANSPORT_RX_DEPENDENCIES = ar8030 cjson

# rx/Makefile is a standalone Makefile (also usable outside Buildroot --
# see ar8030-transport's own README), so this just invokes it with the
# cross compiler and the ar8030 package's staging paths instead of
# folding the build into Buildroot's own machinery. linkctl/ and
# lifecycled/ (see their own README sections) are built the same way --
# neither is tied to rx specifically, but this package is the natural
# place to build+install the ground-side copies since it already stages
# against this same ar8030 dependency. lifecycled itself is not started
# by this package's own S98ar8030-transport-rx (see that script's own
# comment) -- installed and buildable so a future dedicated verification
# pass on this board's role/interface/reset-backend differences (DEV
# role, USB transport, gpio-sysfs reset vs. air's AP/SDIO/devmem) can
# start without a separate patch round first.
#
# `make clean` before each: when built via AR8030_TRANSPORT_RX_OVERRIDE_
# SRCDIR (see this file's header comment), $(@D) is an `rsync -au` copy of
# the *live* ar8030-transport working tree, mtimes preserved -- and that
# same tree is also the OVERRIDE_SRCDIR for builder's ar8030-transport-tx
# package (ARM air unit, a different repo), built from the same
# linkctl/lifecycled directories with the same default build/ and
# ar8030-linkctl/ar8030-lifecycled output names. Without a clean first, a
# binary/object left over from whichever side built more recently rsyncs
# in looking newer than its .c source, and Make silently reuses it
# unrebuilt for the wrong architecture -- confirmed: an AArch64
# ar8030-linkctl built here survived into an ARM build over there and
# failed Buildroot's post-install arch check.
define AR8030_TRANSPORT_RX_BUILD_CMDS
	$(MAKE) -C $(@D)/rx clean
	$(MAKE) -C $(@D)/rx \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
	$(MAKE) -C $(@D)/linkctl clean
	$(MAKE) -C $(@D)/linkctl \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
	$(MAKE) -C $(@D)/lifecycled clean
	$(MAKE) -C $(@D)/lifecycled \
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
	$(INSTALL) -D -m 0755 $(@D)/lifecycled/ar8030-lifecycled \
		$(TARGET_DIR)/usr/bin/ar8030-lifecycled
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/ar8030/hooks.d/connected/30-ifup.sh \
		$(TARGET_DIR)/etc/ar8030/hooks.d/connected/30-ifup.sh
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/ar8030/hooks.d/dropped/30-ifdown.sh \
		$(TARGET_DIR)/etc/ar8030/hooks.d/dropped/30-ifdown.sh
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/ar8030/hooks.d/connected/10-beep.sh \
		$(TARGET_DIR)/etc/ar8030/hooks.d/connected/10-beep.sh
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/ar8030/hooks.d/dropped/10-beep.sh \
		$(TARGET_DIR)/etc/ar8030/hooks.d/dropped/10-beep.sh
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/init.d/S98ar8030-transport-rx \
		$(TARGET_DIR)/etc/init.d/S98ar8030-transport-rx
	$(INSTALL) -D -m 0644 $(AR8030_TRANSPORT_RX_PKGDIR)/files/etc/default/ar8030-transport-rx \
		$(TARGET_DIR)/etc/default/ar8030-transport-rx
endef

$(eval $(generic-package))
