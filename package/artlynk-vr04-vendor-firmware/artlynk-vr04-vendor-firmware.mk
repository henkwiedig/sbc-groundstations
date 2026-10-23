################################################################################
#
# artlynk-vr04-vendor-firmware
#
################################################################################

# No upstream source: BUILD_CMDS extracts from a local stock P1 GND image in
# cache/vendor-images/ (see extract.py), same pattern as ascent-vendor-firmware.
ARTLYNK_VR04_VENDOR_FIRMWARE_SITE_METHOD = local
ARTLYNK_VR04_VENDOR_FIRMWARE_SITE = $(patsubst %/,%,$(ARTLYNK_VR04_VENDOR_FIRMWARE_PKGDIR))
ARTLYNK_VR04_VENDOR_FIRMWARE_LICENSE = PROPRIETARY (extracts BetaFPV/Artosyn vendor firmware; nothing here is committed)
# unsquashfs for reading the stock rootfs
ARTLYNK_VR04_VENDOR_FIRMWARE_DEPENDENCIES = host-squashfs

ARTLYNK_VR04_VENDOR_FIRMWARE_OUT = $(BINARIES_DIR)/artlynk-vr04
ARTLYNK_VR04_VENDOR_FIRMWARE_CACHE = $(BR2_EXTERNAL_OPENIPC_SBC_GS_PATH)/cache/vendor-images

# The stock release the OpenIPC update image is packed on (its SPL, vendor and
# U-Boot); preferred over any other P1_GND_*.img in the cache.
ARTLYNK_VR04_VENDOR_FIRMWARE_VENDOR_RELEASE = P1_GND_v2.1.3_20260825_7bad614

# The host's python3, which has python-lzo (a host prerequisite), not
# Buildroot's host-python3 should a package have pulled it in.
define ARTLYNK_VR04_VENDOR_FIRMWARE_BUILD_CMDS
	PATH=$$(echo "$$PATH" | tr : '\n' | grep -v '^$(HOST_DIR)' | paste -sd: -) \
	python3 $(ARTLYNK_VR04_VENDOR_FIRMWARE_PKGDIR)/extract.py $(ARTLYNK_VR04_VENDOR_FIRMWARE_OUT) \
		$(HOST_DIR) $(ARTLYNK_VR04_VENDOR_FIRMWARE_CACHE) $(ARTLYNK_VR04_VENDOR_FIRMWARE_VENDOR_RELEASE)
endef

define ARTLYNK_VR04_VENDOR_FIRMWARE_INSTALL_TARGET_CMDS
	if [ -f $(ARTLYNK_VR04_VENDOR_FIRMWARE_OUT)/wave521c_k3_codec_fw.bin ]; then \
		$(INSTALL) -D -m 0644 $(ARTLYNK_VR04_VENDOR_FIRMWARE_OUT)/wave521c_k3_codec_fw.bin \
			$(TARGET_DIR)/lib/firmware/cnm/wave521c_k3_codec_fw.bin; \
	fi
endef

$(eval $(generic-package))
