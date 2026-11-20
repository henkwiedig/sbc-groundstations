################################################################################
#
# artosyn-ge2d
#
################################################################################

ARTOSYN_GE2D_SITE_METHOD = local
ARTOSYN_GE2D_SITE = $(ARTOSYN_GE2D_PKGDIR)/src
ARTOSYN_GE2D_LICENSE = GPL-2.0

$(eval $(kernel-module))
$(eval $(generic-package))
