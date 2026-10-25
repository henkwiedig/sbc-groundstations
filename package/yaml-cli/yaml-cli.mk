YAML_CLI_VERSION=15886c31f4979d10cd176e92fe7ded113134e790
YAML_CLI_SITE=https://github.com/OpenIPC/yaml-cli.git
YAML_CLI_SITE_METHOD = git
YAML_CLI_INSTALL_STAGING = NO
YAML_CLI_INSTALL_TARGET = YES
# Its own libyaml (a subdirectory) linked in: as a shared library it is not
# installed, and yaml-cli only ran where another package's libyaml.so was
YAML_CLI_CONF_OPTS = -DBUILD_SHARED_LIBS=OFF

$(eval $(cmake-package))