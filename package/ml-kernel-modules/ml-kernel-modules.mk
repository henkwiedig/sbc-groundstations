################################################################################
#
# ml-kernel-modules
#
################################################################################

# Same source as package/ml-kernel, same download. Keep the version in sync
# with ML_KERNEL_VERSION: it cannot be referenced here, this file is parsed
# before ml-kernel.mk ("ml-kernel-modules/" sorts before "ml-kernel/").
ML_KERNEL_MODULES_VERSION = e3885c6394a7025eacd3a23f473276d9823beb25
ML_KERNEL_MODULES_SITE = $(call github,Missing-Lynk,ml-kernel,$(ML_KERNEL_MODULES_VERSION))
ML_KERNEL_MODULES_SOURCE = ml-kernel-$(ML_KERNEL_MODULES_VERSION).tar.gz
ML_KERNEL_MODULES_DL_SUBDIR = ml-kernel
ML_KERNEL_MODULES_LICENSE = GPL-2.0
ML_KERNEL_MODULES_LICENSE_FILES = COPYING

ML_KERNEL_MODULES_MODULE_SUBDIRS = modules

# Reference-only upstream (compile-checked, never loaded): see ml-kernel's
# STATUS.md "RF module" and modules/stage.sh.
# artosyn_mmc is an alternate SD host for the same controllers as
# dw_mci-artosyn: only one of them may bind, so it is not installed either.
ML_KERNEL_MODULES_REFERENCE_ONLY = \
	ar_osal ar_vb ar_sys ar_sysctl ar_mpp_drv ar_mpp_proc_ctrl ar_mpp_overlay \
	artosyn_mmc

# artosyn_sdio is MissingLynk's AR8030 driver (for ml-linkd). It claims the
# same SDIO ids (4152:8030/8031) as package/ar8030's artosyn_drv, so it is
# only installed when that one is not.
ifeq ($(BR2_PACKAGE_AR8030),y)
ML_KERNEL_MODULES_REFERENCE_ONLY += artosyn_sdio
endif

# Both steps run at target-finalize, on the merged target: with per-package
# directories, files deleted from a package's own copy (e.g. linux's
# in-tree modules) come back when the final target is assembled. They run
# after Buildroot's own depmod (LINUX_RUN_DEPMOD, registered earlier) and
# re-run it.
define ML_KERNEL_MODULES_FINALIZE
	cd $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED) && \
	for m in $(ML_KERNEL_MODULES_REFERENCE_ONLY); do \
		find . -name "$$m.ko" -delete; \
	done
	$(if $(BR2_PACKAGE_ML_KERNEL_MODULES_PRUNE),$(ML_KERNEL_MODULES_PRUNE_INTREE))
	$(HOST_DIR)/sbin/depmod -a -b $(TARGET_DIR) $(LINUX_VERSION_PROBED)
endef

# Keep only the in-tree modules ml-kernel's own modules/stage.sh ships
# (media: V4L2, videobuf2, wave5, the Artosyn camera drivers; pstore;
# reed_solomon), plus everything
# these and the out-of-tree modules depend on (closure over modules.dep).
# arm64 defconfig leaves several hundred other drivers =m that nothing on
# this SoC loads.
ML_KERNEL_MODULES_KEEP_DIRS = \
	kernel/drivers/media/v4l2-core kernel/drivers/media/common/videobuf2 \
	kernel/drivers/media/platform/chips-media/wave5 kernel/drivers/media/artosyn \
	kernel/fs/pstore kernel/lib/reed_solomon \
	$(call qstrip,$(BR2_PACKAGE_ML_KERNEL_MODULES_KEEP_EXTRA))

define ML_KERNEL_MODULES_PRUNE_INTREE
	cd $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED) && \
	$(HOST_DIR)/sbin/depmod -a -b $(TARGET_DIR) $(LINUX_VERSION_PROBED) && \
	keep=$$(find $(ML_KERNEL_MODULES_KEEP_DIRS) updates extra -name '*.ko' 2>/dev/null | sort -u); \
	while :; do \
		next=$$( { printf '%s\n' $$keep; \
			for k in $$keep; do grep "^$$k:" modules.dep | cut -d: -f2; done | tr ' ' '\n'; } | \
			grep . | sort -u); \
		[ "$$next" = "$$keep" ] && break; \
		keep=$$next; \
	done; \
	find kernel -name '*.ko' | while read -r m; do \
		printf '%s\n' $$keep | grep -qxF "$$m" || rm -f "$$m"; \
	done; \
	find kernel -type d -empty -delete
endef

$(eval $(kernel-module))
$(eval $(generic-package))

ifeq ($(BR2_PACKAGE_ML_KERNEL_MODULES),y)
TARGET_FINALIZE_HOOKS += ML_KERNEL_MODULES_FINALIZE
endif
