#!/bin/sh

while true
do
  test -r /etc/default/pixelpilot && . /etc/default/pixelpilot
  # Receiver mode artosyn: the video comes from ar8030-transport-rx's frame-shm
  # ring (S98ar8030-transport-rx starts rx with -R gnd_frames), not RTP on the
  # UDP port. Here and not in /etc/default/pixelpilot, whose gsmenu-edited
  # overlay copies would keep an older image's arguments.
  FRAME_SHM=""
  [ "$PIXELPILOT_RX_MODE" = "artosyn" ] && FRAME_SHM="--frame-shm gnd_frames --frame-shm-audio gnd_audio"
  # The menu's Smoothness level (gsmenu.sh), same reason.
  SMOOTHNESS=""
  [ -n "$PIXELPILOT_VSYNC_SMOOTHNESS" ] && SMOOTHNESS="--vsync-lock-smoothness $PIXELPILOT_VSYNC_SMOOTHNESS"
  /usr/bin/pixelpilot $PIXELPILOT_ARGS $FRAME_SHM $SMOOTHNESS "$@"
  rc=$?
  if [ $rc = 2 -o $rc = 143 -o $rc = 137 ]
  then
    echo "Pixelpilot exited: $rc, skip restart ...."
    exit 2
  fi
  echo "Pixelpilot exited: $rc, restart ...."
  sleep 1
done