#!/bin/sh
#
# Brings up the AR8030 TUN bridge (ar_net0, BR2_PACKAGE_AR8030_TUNTAP)
# now that a real link is up. ar_net0 is deliberately "manual" in
# /etc/network/interfaces.d/ar_net0 (its own pre-up/post-down already
# start/stop ar8030-tun) precisely so nothing brings it up before there
# is an actual link to carry it -- this hook is what actually calls
# ifup now, instead of that being a manual step. ifup is idempotent (a
# no-op if already up), so safe even if this fires more than once.
#
# Best-effort: a no-op if this board doesn't build ar8030-tun at all.
[ -x /usr/bin/ar8030-tun ] || exit 0
ifup ar_net0 2>&1 | logger -t ar8030-lifecycled-hook
