#!/bin/sh
# The VR04's front end after a chip start (see /usr/sbin/vr04-fem). "idle"
# fires when lifecycled starts without a link; when the chip links at once,
# connected/05-fem.sh does the same instead.
exec /usr/sbin/vr04-fem
