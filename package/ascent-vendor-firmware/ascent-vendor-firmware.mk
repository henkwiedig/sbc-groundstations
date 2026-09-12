################################################################################
#
# ascent-vendor-firmware
#
################################################################################

# No real upstream source -- this package exists purely so ar8030 gets a
# real, Buildroot-scheduler-enforced guarantee that CADDX's VRX Pro vendor
# OTA image has already been fetched and its baseband demo firmware
# extracted before ar8030 starts building -- see extract.py's docstring for
# the full story.
ASCENT_VENDOR_FIRMWARE_SITE_METHOD = local
# PKGDIR always carries a trailing slash; SITE (unlike PKGDIR-derived paths
# used elsewhere, e.g. BUILD_CMDS below) rejects one outright.
ASCENT_VENDOR_FIRMWARE_SITE = $(patsubst %/,%,$(ASCENT_VENDOR_FIRMWARE_PKGDIR))
ASCENT_VENDOR_FIRMWARE_LICENSE = PROPRIETARY (fetches CADDX vendor firmware; nothing here is committed)

# Google Drive file id of CADDX's "Ascent V<ver>" OTA image zip -- same
# bundle OpenIPC/builder's own ascent-vendor-firmware package uses (it
# ships all four Ascent variants' .img files together, air and ground
# alike; this package just extracts a different member,
# Ascent_VRX_Pro_*.img). Bumping to a newer CADDX release, or repointing
# at a different vendor image entirely, only ever means editing this one
# line.
ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID = 1_IXl5OaJPVny78kg80CSn3FpWzYXQg3U

# Only the raw vendor zip/img is worth persisting across builds -- it's the
# genuinely expensive part (a ~180MB Google Drive fetch). Cached under the
# external tree itself (not BINARIES_DIR, which is per-O= and typically
# wiped/recreated across builds) so it survives across `-o` output dirs.
ASCENT_VENDOR_FIRMWARE_CACHE_DIR = $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/cache/vendor-images

# No Buildroot dependency for reading the UBI rootfs volume -- extract.py
# just shells out to `ubireader_extract_files` if it happens to be on PATH
# (pip install --user ubi_reader) and best-effort skips if it isn't. See
# extract.py's docstring for why this isn't a hermetic host-* package
# dependency.

define ASCENT_VENDOR_FIRMWARE_BUILD_CMDS
	python3 $(ASCENT_VENDOR_FIRMWARE_PKGDIR)/extract.py \
		$(BINARIES_DIR) $(ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID) \
		$(ASCENT_VENDOR_FIRMWARE_CACHE_DIR)
endef

# Nothing installs to the target from this package directly -- ar8030
# copies what it needs out of $(BINARIES_DIR) (see extract.py) into its own
# build dir and installs it itself.
define ASCENT_VENDOR_FIRMWARE_INSTALL_TARGET_CMDS
endef

$(eval $(generic-package))
