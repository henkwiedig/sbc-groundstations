################################################################################
#
# ml-kernel kernel extension
#
# Applies MissingLynk's Proxima-9311 BSP (package/ml-kernel) to a mainline
# 6.18.36 tree, reproducing ml-kernel's scripts/container-build.sh:
#   1. copy overlay/ (Artosyn drivers) in and register their Kconfig/Makefile
#   2. apply patches/ (series order == file name order)
#   3. write arch/arm64/configs/ml_defconfig = arm64 defconfig + artosyn +
#      trim + the board's fragments list, in order (a later assignment wins
#      when kconfig loads it, the same result as merge_config.sh +
#      olddefconfig). Select it with BR2_LINUX_KERNEL_DEFCONFIG="ml";
#      board-local additions go in BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES,
#      board-local kernel patches in BR2_LINUX_KERNEL_PATCH (applied after
#      this hook).
#   4. install the board's DTS as arch/arm64/boot/dts/artosyn/<name>.dts, for
#      BR2_LINUX_KERNEL_INTREE_DTS_NAME="artosyn/<name>".
#
# linux.mk adds the ml-kernel patch dependency and this pre-patch hook for
# BR2_LINUX_KERNEL_EXT_ML_KERNEL.
#
################################################################################

LINUX_EXTENSIONS += ml-kernel

define ML_KERNEL_PREPARE_KERNEL
	for d in $(ML_KERNEL_DIR)/overlay/*/; do cp -r $$d $(@D)/; done
	grep -q "drm/artosyn/Kconfig" $(@D)/drivers/gpu/drm/Kconfig || \
		echo 'source "drivers/gpu/drm/artosyn/Kconfig"' >> $(@D)/drivers/gpu/drm/Kconfig
	grep -q "obj-y += artosyn/" $(@D)/drivers/gpu/drm/Makefile || \
		echo "obj-y += artosyn/" >> $(@D)/drivers/gpu/drm/Makefile
	grep -q "media/artosyn/Kconfig" $(@D)/drivers/media/Kconfig || \
		sed -i 's|^source "drivers/media/i2c/Kconfig"$$|&\nsource "drivers/media/artosyn/Kconfig"|' \
			$(@D)/drivers/media/Kconfig
	grep -q "obj-y += artosyn/" $(@D)/drivers/media/Makefile || \
		echo "obj-y += artosyn/" >> $(@D)/drivers/media/Makefile
	grep -q "clk-ar9311-cgu.o" $(@D)/drivers/clk/Makefile || \
		echo "obj-y += clk-ar9311-cgu.o" >> $(@D)/drivers/clk/Makefile
	grep -q "spi-ar9301.o" $(@D)/drivers/spi/Makefile || \
		echo "obj-y += spi-ar9301.o" >> $(@D)/drivers/spi/Makefile

	$(APPLY_PATCHES) $(@D) $(ML_KERNEL_DIR)/patches \*.patch

	cat $(@D)/arch/arm64/configs/defconfig \
		$(ML_KERNEL_DIR)/configs/artosyn.config \
		$(ML_KERNEL_DIR)/configs/trim.config \
		$$(sed -e 's/#.*//' $(ML_KERNEL_DIR)/devices/$(ML_KERNEL_BOARD)/fragments | \
			awk 'NF { print "$(ML_KERNEL_DIR)/configs/" $$1 ".config" }') \
		> $(@D)/arch/arm64/configs/ml_defconfig

	mkdir -p $(@D)/arch/arm64/boot/dts/artosyn
	cp $(ML_KERNEL_DIR)/devices/$(ML_KERNEL_BOARD)/*.dts $(@D)/arch/arm64/boot/dts/artosyn/
	for f in $(ML_KERNEL_DIR)/devices/$(ML_KERNEL_BOARD)/*.dts; do \
		echo "dtb-y += $$(basename $$f .dts).dtb"; \
	done > $(@D)/arch/arm64/boot/dts/artosyn/Makefile
	grep -q "subdir-y += artosyn" $(@D)/arch/arm64/boot/dts/Makefile || \
		echo "subdir-y += artosyn" >> $(@D)/arch/arm64/boot/dts/Makefile
endef
