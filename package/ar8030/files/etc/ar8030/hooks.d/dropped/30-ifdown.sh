#!/bin/sh
#
# Tears the AR8030 TUN bridge (ar_net0) back down on a real link drop --
# see connected/30-ifup.sh. ifdown is idempotent too (a no-op if already
# down).
#
# Best-effort: a no-op if this board doesn't build ar8030-tun at all.
[ -x /usr/bin/ar8030-tun ] || exit 0
ifdown ar_net0 2>&1 | logger -t ar8030-lifecycled-hook
