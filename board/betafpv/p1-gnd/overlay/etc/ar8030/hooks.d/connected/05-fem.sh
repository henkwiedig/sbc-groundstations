#!/bin/sh
# The VR04's front end on every link (see /usr/sbin/vr04-fem): covers a
# lifecycled start that links at once (no "idle") and a chip that reset under a
# running lifecycled. Already set up, it changes nothing.
exec /usr/sbin/vr04-fem
