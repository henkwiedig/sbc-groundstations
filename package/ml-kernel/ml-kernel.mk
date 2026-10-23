################################################################################
#
# ml-kernel
#
################################################################################

# Source only: applied to the kernel tree by linux/linux-ext-ml-kernel.mk.
# ml-kernel-modules shares this download.
ML_KERNEL_VERSION = e3885c6394a7025eacd3a23f473276d9823beb25
ML_KERNEL_SITE = $(call github,Missing-Lynk,ml-kernel,$(ML_KERNEL_VERSION))
ML_KERNEL_LICENSE = GPL-2.0
ML_KERNEL_LICENSE_FILES = COPYING
ML_KERNEL_BOARD = $(call qstrip,$(BR2_PACKAGE_ML_KERNEL_BOARD))
# Proxima-9311 bootloaders only boot an LZ4 uImage; the board's post-image
# script packs the Image with host lz4 (no Kconfig symbol of its own).
ML_KERNEL_DEPENDENCIES = host-lz4

$(eval $(generic-package))
