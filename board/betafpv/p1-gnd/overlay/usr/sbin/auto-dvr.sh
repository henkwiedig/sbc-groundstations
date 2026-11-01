#!/bin/sh
# autofs program map for /media (replaces board/common/overlay/usr/sbin/auto-dvr.sh,
# which looks for the Rockchip boards' partitions): the goggles' SD card slot
# is mmc@1c00000; its first partition, or the whole card if it has none.

for b in /sys/block/mmcblk*; do
	readlink -f "$b" | grep -q '/1c00000\.mmc/' || continue
	d=/dev/${b##*/}
	[ -b ${d}p1 ] && d=${d}p1
	t=$(blkid "$d" 2>/dev/null | sed -n 's/.* TYPE="\([^"]*\)".*/\1/p')
	case "$t" in
	vfat | exfat) echo "-fstype=$t :$d"; exit 0 ;;
	esac
done
exit 1
