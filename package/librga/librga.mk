# nyanmisaka's linux-rga-multi branch as we have always built it. Its gitee
# repo now asks for a login (CI 11-13: the VRX Pro and Radxa builds died on
# the download); the GitHub mirror has the same commit, pinned so a branch
# move can't change the code under us.
LIBRGA_VERSION = ca16a702c76eb784e870772c948012c4c27076da
LIBRGA_SITE = https://github.com/nyanmisaka/rk-mirrors.git
LIBRGA_SITE_METHOD = git
LIBRGA_INSTALL_STAGING = YES
LIBRGA_INSTALL_TARGET = YES

#$(eval $(cmake-package))
$(eval $(meson-package))

