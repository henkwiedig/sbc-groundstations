#!/bin/sh
# ar_net0 is artosyn_drv's native netdev here (no ar8030-tun, which
# package/ar8030-transport-rx's own hook waits for).
ifdown ar_net0 2>&1 | logger -t ar8030-lifecycled-hook
