#!/bin/sh

# Support Data Collection Script for Buildroot Devices
# Creates a zip file with system information for troubleshooting
#
# Runs from the OSD menu (gsmenu: GS -> Actions) while the video is live, so
# it must neither stop half way nor disturb what it is recording:
# - no `set -e`: every step is best-effort, and the archive is always written.
#   (A failed sed on a WiFi passphrase with a '/' in it, or a missing applet,
#   used to abort the whole collection.)
# - the time-critical data first: the logs (they rotate) and the air unit's
#   snapshot (it needs the link), then everything else.
# - lowest CPU priority, and nothing that reads the NAND (blkid on mtdblock)
#   or walks /sys, /proc or the SD card (find /, du /). On the AR9311
#   goggles the old collection starved ar8030d and the receiver for half a
#   minute: frames lost, the vsync lock lost, once a wedged ground link.
# - one collection at a time.
# Exit status: 0 when the archive is on the SD card; 1 when it is not (no
# card: it is left in /tmp, see the message), so the menu shows an error.

# Configuration
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COLLECTION_DIR="/tmp/support_data_${TIMESTAMP}"
OUTPUT_DIR="/media/dvr"
SCRIPT_NAME="collect_support_data.sh"
OUTPUT_PREFIX="openipc_support_data"
MAX_LOG_SIZE=1048576  # 1MB max per log file
LOCK=/tmp/collect_support_data.lock

# Colors for output (if supported)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_colored() {
    echo -e "${2}${1}${NC}"
}

if ! mkdir "$LOCK" 2>/dev/null; then
    echo_colored "A support data collection is already running (lock: $LOCK)" "$RED" >&2
    exit 1
fi

# Children inherit it: the receiver, ar8030d and PixelPilot keep the CPU.
renice -n 19 -p $$ >/dev/null 2>&1

MOUNTED_DEBUGFS=0
cleanup() {
    cd /
    rm -rf "${COLLECTION_DIR}"
    # Leave the system as we found it: only unmount debugfs if this script
    # was the one that mounted it (section 2a).
    [ "$MOUNTED_DEBUGFS" = "1" ] && umount /sys/kernel/debug 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

mkdir -p "${COLLECTION_DIR}" && cd "${COLLECTION_DIR}" || {
    echo_colored "Cannot create ${COLLECTION_DIR}" "$RED" >&2
    exit 1
}

START_TIME=$(date)
START_UPTIME=$(cut -d' ' -f1 /proc/uptime)
# Where the logs of the other services show this collection begin.
logger -t collect_support_data "support data collection started" 2>/dev/null

collect_file() {
    local src="$1"
    local dest="$2"

    if [ -e "$src" ]; then
        cp "$src" "$dest" 2>/dev/null || {
            echo "Warning: Could not copy $src" >&2
            echo "Permission denied or file busy" > "$dest.access_error"
        }
    else
        echo "File not found: $src" > "$dest.not_found"
    fi
}

collect_log() {
    local log_path="$1"
    local dest_name="$2"

    if [ -f "$log_path" ]; then
        local size=$(wc -c < "$log_path" 2>/dev/null || echo "0")
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            echo "Log truncated (original: ${size} bytes)" > "${dest_name}"
            tail -c "${MAX_LOG_SIZE}" "$log_path" >> "${dest_name}"
            echo "" >> "${dest_name}"
            echo "... [truncated] ..." >> "${dest_name}"
            head -c 10240 "$log_path" >> "${dest_name}"
        else
            cp "$log_path" "${dest_name}" 2>/dev/null || {
                echo "Could not copy log: $log_path" > "${dest_name}.error"
            }
        fi
    fi
}

echo_colored "Starting support data collection..." "$GREEN"

# 1. LOG FILES (first: they rotate, and the rest of the collection loads the
# system enough to show up in them)
echo_colored "Collecting log files..." "$GREEN"
mkdir -p logs

# System logs
collect_log "/var/log/messages" "logs/messages.log"
collect_log "/var/log/syslog" "logs/syslog.log"
collect_log "/var/log/dmesg" "logs/dmesg.log"
collect_log "/var/log/auth.log" "logs/auth.log"
collect_log "/var/log/daemon.log" "logs/daemon.log"

# Application logs (common locations)
for log in /var/log/*.log; do
    if [ -f "$log" ]; then
        base_name=$(basename "$log")
        collect_log "$log" "logs/${base_name}"
    fi
done

# PixelPilot (rotated backups are named pixelpilot.1.log, pixelpilot.2.log, ...
# by spdlog's rotating file sink) -- already picked up by the glob above if
# /var/log/pixelpilot.log exists, this just makes sure the current and every
# rotated backup are collected even if the glob pattern above ever changes.
for log in /var/log/pixelpilot.log /var/log/pixelpilot.*.log; do
    if [ -f "$log" ]; then
        base_name=$(basename "$log")
        collect_log "$log" "logs/${base_name}"
    fi
done

# 2. AR8030 LINK + AIR UNIT
# Both lifecycled HTTP APIs (--http-port 8899 in /etc/default/ar8030-transport-rx
# and on the air unit), ar8030d's own logs, and -- while the link is still up --
# the air unit's full snapshot over ssh on ar_net0. Run this BEFORE powering
# the air unit off: its logs live in RAM only.
echo_colored "Collecting AR8030 link and air unit data..." "$GREEN"
mkdir -p ar8030/ground ar8030/air

# The receiver's log (ar8030-transport-rx.log + its .1/.2), ar8030d's logs:
# capped at 2 MB each by ar8030d itself, so copied whole.
for f in /tmp/ar8030/*; do
    if [ -f "$f" ]; then collect_log "$f" "ar8030/ground/$(basename "$f")"; fi
done
mkdir -p ar8030/ground/daemon_log
for f in /tmp/ar8030/daemon_log/*; do
    if [ -f "$f" ]; then collect_file "$f" "ar8030/ground/daemon_log/$(basename "$f")"; fi
done

# The air unit's snapshot. The ground carries its own copy of the air's
# collect_air_logs (package ar8030-transport-rx) and pipes it in, so air
# images without the script (the P1's before it moved into
# ar8030-transport-tx) or with an older one (no waybeam log) give it all
# too; it only falls back to the air's own copy without ours.
# Same root password and sshpass as gsmenu.sh's $SSH.
AIR=192.168.100.1
AIR_SSH_PASS="${AIR_SSH_PASS:-12345}"
AIR_COLLECTOR="${AIR_COLLECTOR:-/usr/share/ar8030/collect_air_logs}"
air_ssh() {
    timeout -k 1 60 sshpass -p "$AIR_SSH_PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@${AIR} "$@"
}
if ip link show ar_net0 >/dev/null 2>&1; then
    if [ -r "$AIR_COLLECTOR" ]; then
        air_ssh 'nice -n 19 sh -s -- -' < "$AIR_COLLECTOR" > ar8030/air/air_logs.tar.gz 2> ar8030/air/ssh.err
    else
        air_ssh 'nice -n 19 collect_air_logs -' < /dev/null > ar8030/air/air_logs.tar.gz 2> ar8030/air/ssh.err
    fi
    AIR_RC=$?
else
    echo "no ar_net0 (link down?)" > ar8030/air/ssh.err
    AIR_RC=255
fi
if [ "$AIR_RC" = 0 ] && gzip -dc < ar8030/air/air_logs.tar.gz 2>/dev/null | tar -tf - >/dev/null 2>&1; then
    rm -f ar8030/air/ssh.err
else
    # No ssh access (link down, different root password): at least its API view.
    echo "exit status $AIR_RC" >> ar8030/air/ssh.err
    rm -f ar8030/air/air_logs.tar.gz
    for ep in status link batt rf-temp channel power; do
        curl -s -m 3 "http://${AIR}:8899/api/v1/$ep" > "ar8030/air/api_${ep}.json" 2>&1 || echo "unreachable" > "ar8030/air/api_${ep}.json"
    done
fi

for ep in status link peers batt rf-temp channel power frame-change; do
    curl -s -m 3 "http://127.0.0.1:8899/api/v1/$ep" > "ar8030/ground/api_${ep}.json" 2>&1 || echo "unreachable" > "ar8030/ground/api_${ep}.json"
done
for f in /etc/default/ar8030 /etc/default/ar8030-transport-rx; do
    collect_file "$f" "ar8030/ground/$(basename "$f")"
done
ls -la /lib/firmware/ar8030/ > ar8030/ground/firmware_dir.txt 2>&1
ip addr show ar_net0 > ar8030/ground/ar_net0.txt 2>&1

# The current ar8030-flightlog session (the recorder keeps writing to the
# original on /media/dvr; this is a point-in-time copy).
FLIGHTLOG_SESSION=$(ls -1d /media/dvr/flightlog/[0-9]*_* 2>/dev/null | sort | tail -n 1)
if [ -n "$FLIGHTLOG_SESSION" ]; then
    mkdir -p ar8030/flightlog
    cp -r "$FLIGHTLOG_SESSION" ar8030/flightlog/ 2>/dev/null
fi

# 3. VIDEO PIPELINE STATE
# What a stutter report needs besides the logs: who gets the CPU (the
# receiver, ar8030d and PixelPilot's threads: policy, priority, and CPU use
# over one second), clocks and temperatures, and which binaries actually run
# (test builds copied into the overlay shadow the image's).
echo_colored "Collecting video pipeline state..." "$GREEN"
mkdir -p video

# The DRM/VOP2, RGA, wave5 and clock debug nodes live under debugfs, which
# not every board mounts. Mount it ourselves if needed and remember to undo
# that in the cleanup step, so the collector doesn't leave the system in a
# different state than it found it.
if ! grep -q " /sys/kernel/debug debugfs " /proc/mounts; then
    if mount -t debugfs none /sys/kernel/debug 2>/dev/null; then
        MOUNTED_DEBUGFS=1
    fi
fi

VIDEO_PIDS=$(pidof pixelpilot ar8030-transport-rx ar8030d ar8030-tun msposd wfb_rx 2>/dev/null)
# Each thread's CPU ticks with the time they were read (/proc/uptime, in
# centiseconds), all with shell builtins: with a cat per file a pass over
# PixelPilot's ~60 threads took over a second on a loaded 2-core box, and
# dividing by the nominal 1 s blew every figure up ~2.5x (the threads summed
# to 257 % of a 2-core box once).
thread_times() {
    for p in $VIDEO_PIDS; do
        for t in /proc/$p/task/*; do
            read -r s 2>/dev/null < "$t/stat" || continue
            read -r c 2>/dev/null < "$t/comm"
            read -r up _ < /proc/uptime
            s=${s##*) }
            # after the comm: $1 = field 3 (state), so field N is $((N-2))
            set -- $s
            echo "$p ${t##*/} $(( ${12} + ${13} )) ${up%.*}${up#*.} ${39} ${38} $c"
        done
    done
}
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
thread_times > video/.t0
cat /proc/interrupts > video/interrupts_t0.txt 2>&1
sleep 1
thread_times > video/.t1
cat /proc/interrupts > video/interrupts_t1.txt 2>&1
{
    echo "# CPU per thread over ~1 s, each thread over its own measured window (100 = one core);"
    echo "# policy 0 OTHER, 1 FIFO, 2 RR"
    echo "# pid tid cpu% policy rtprio comm"
    awk -v hz="$CLK_TCK" 'NR == FNR { t0[$2] = $3; u0[$2] = $4; next }
        ($2 in t0) && $4 > u0[$2] {
            printf "%s %s %.0f %s %s", $1, $2, ($3 - t0[$2]) * 100 / hz / (($4 - u0[$2]) / 100), $5, $6
            for (i = 7; i <= NF; i++) printf " %s", $i; print "" }' \
        video/.t0 video/.t1 | sort -k3 -n -r
} > video/threads.txt 2>&1
rm -f video/.t0 video/.t1

top -b -n 1 > video/top.txt 2>&1
# Which CPU serves which interrupt (SDIO, the VPU, the display).
for i in /proc/irq/[0-9]*; do
    [ -r "$i/smp_affinity_list" ] || continue
    echo "${i##*/} allowed $(cat "$i/smp_affinity_list") effective $(cat "$i/effective_affinity_list" 2>/dev/null) $(ls "$i" | grep -v '^\(smp_affinity\|smp_affinity_list\|affinity_hint\|effective_affinity\|effective_affinity_list\|node\|spurious\)$' | tr '\n' ' ')"
done > video/irq_affinity.txt 2>&1
cat /proc/softirqs > video/softirqs.txt 2>&1
cat /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory > video/pressure.txt 2>/dev/null || rm -f video/pressure.txt

{
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        echo "${p##*/}: cur $(cat "$p/scaling_cur_freq" 2>/dev/null) min $(cat "$p/scaling_min_freq" 2>/dev/null) max $(cat "$p/scaling_max_freq" 2>/dev/null) governor $(cat "$p/scaling_governor" 2>/dev/null)"
        [ -r "$p/stats/time_in_state" ] && sed 's/^/  /' "$p/stats/time_in_state"
    done
} > video/cpufreq.txt 2>&1

# Temperatures and supply: thermal zones (Rockchip), hwmon, IIO (the AR9311's
# protemp, the goggles' battery ADC).
{
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] && echo "thermal $(cat "$z/type" 2>/dev/null): $(cat "$z/temp" 2>/dev/null)"
    done
    for f in /sys/class/hwmon/hwmon*/*_input; do
        [ -r "$f" ] && echo "hwmon $(cat "${f%/*}/name" 2>/dev/null) ${f##*/}: $(cat "$f" 2>/dev/null)"
    done
    for d in /sys/bus/iio/devices/iio:device*; do
        [ -d "$d" ] || continue
        for f in "$d"/in_*; do
            [ -f "$f" ] || continue
            case "$f" in *_raw|*_input|*_scale) echo "iio $(cat "$d/name" 2>/dev/null) ${f##*/}: $(cat "$f" 2>/dev/null)" ;; esac
        done
    done
} > video/sensors.txt 2>&1

# The wave5 VPU (AR9311: decoder + DVR encoder): the driver's own state
# node (instances, job timeouts, firmware faults; read only -- never write
# its "recover" neighbour, that kills every instance), and the clocks.
collect_file /sys/kernel/debug/wave5/state video/wave5_state.txt
collect_file /sys/kernel/debug/clk/clk_summary video/clk_summary.txt
collect_file /sys/kernel/debug/ar9311_pixclk_rate video/ar9311_pixclk_rate.txt
for d in /sys/class/video4linux/video*; do
    [ -r "$d/name" ] && echo "${d##*/}: $(cat "$d/name")"
done > video/v4l2_devices.txt 2>&1

{
    for b in /usr/bin/pixelpilot /usr/bin/ar8030-transport-rx /usr/bin/ar8030d \
            /usr/bin/ar8030-lifecycled /usr/bin/gsmenu.sh /usr/bin/pixelpilot.sh; do
        [ -f "$b" ] || continue
        img=
        [ -f "/rom$b" ] && img=" (image: $(md5sum "/rom$b" | cut -d' ' -f1))"
        echo "$(md5sum "$b" | cut -d' ' -f1)  $b$img"
    done
    echo "# files in the overlay (they shadow the image's):"
    [ -d /overlay ] && find /overlay -xdev -type f 2>/dev/null | head -n 1000
} > video/binaries_overlay.txt 2>&1

# The SD card: recordings (was the DVR running?), free space.
ls -la /media/dvr/ > video/media_dvr.txt 2>&1

# A crash of the previous boot, where the kernel keeps one.
if [ -d /sys/fs/pstore ] && [ -n "$(ls /sys/fs/pstore 2>/dev/null)" ]; then
    mkdir -p kernel/pstore
    cp /sys/fs/pstore/* kernel/pstore/ 2>/dev/null
fi

# 4. SYSTEM INFORMATION
echo_colored "Collecting system information..." "$GREEN"
mkdir -p system_info

# Basic system info
uname -a > system_info/uname.txt 2>&1
cat /proc/version > system_info/proc_version.txt 2>&1
cat /etc/os-release 2>/dev/null > system_info/os_release.txt || echo "No os-release found" > system_info/os_release.txt
cat /etc/issue 2>/dev/null > system_info/issue.txt || echo "No issue file found" > system_info/issue.txt

# CPU/Memory info
cat /proc/cpuinfo > system_info/cpuinfo.txt 2>&1
cat /proc/meminfo > system_info/meminfo.txt 2>&1
free -h > system_info/free.txt 2>&1 || free > system_info/free.txt 2>&1

# Uptime and load
uptime > system_info/uptime.txt 2>&1
cat /proc/loadavg > system_info/loadavg.txt 2>&1

# 5. HARDWARE INFORMATION
echo_colored "Collecting hardware information..." "$GREEN"
mkdir -p hardware

# PCI and USB devices
lspci 2>/dev/null > hardware/lspci.txt || echo "lspci not available" > hardware/lspci.txt
lsusb 2>/dev/null > hardware/lsusb.txt || echo "lsusb not available" > hardware/lsusb.txt

# Block devices and mounts. blkid only on disks: probing every mtdblock
# reads the NAND (seconds on the AR9311 goggles, while the video runs).
BLOCKDEVS=$(ls /dev/mmcblk* /dev/sd* /dev/nvme* 2>/dev/null | grep -v 'boot[0-9]*$\|rpmb$')
if [ -n "$BLOCKDEVS" ]; then
    blkid $BLOCKDEVS > hardware/blkid.txt 2>&1 || echo "blkid not available" > hardware/blkid.txt
else
    echo "no disks" > hardware/blkid.txt
fi
df -h > hardware/df.txt 2>&1 || df > hardware/df.txt 2>&1
mount > hardware/mount.txt 2>&1
cat /proc/mounts > hardware/proc_mounts.txt 2>&1

# Network interfaces
ip link show > hardware/network_interfaces.txt 2>&1
ip addr show > hardware/ip_addr.txt 2>&1

# 5a. DISPLAY / ROCKCHIP HARDWARE (DRM, RGA, MPP)
echo_colored "Collecting DRM/Rockchip/RGA/MPP diagnostics..." "$GREEN"
mkdir -p display_rockchip/drm display_rockchip/rockchip display_rockchip/rga display_rockchip/mpp

# (debugfs: mounted in section 3)

# DRM: connector/plane/crtc enumeration plus the rockchip VOP2 debugfs dump
# (mode timings, window/plane state, GEM buffer map, register snapshot).
# Directly relevant to the padding/stride class of bugs investigated on this
# pipeline (DVR reencode colortrans/RGA corruption).
modetest -c > display_rockchip/drm/modetest_connectors.txt 2>&1 || echo "modetest not available" > display_rockchip/drm/modetest_connectors.txt
modetest -p > display_rockchip/drm/modetest_planes.txt 2>&1 || echo "modetest not available" > display_rockchip/drm/modetest_planes.txt
collect_file "/sys/class/drm/version" "display_rockchip/drm/drm_version.txt"

for summary in /sys/kernel/debug/dri/*/summary; do
    [ -e "$summary" ] || continue
    carddir=$(dirname "$summary")
    card=$(basename "$carddir")
    for f in summary clients framebuffer state name mm_dump regs active_regs; do
        collect_file "$carddir/$f" "display_rockchip/drm/card${card}_${f}.txt"
    done
done

# Rockchip SoC identification + clock/thermal state (GPU/DDR/VDEC/VENC
# devfreq scaling directly matters for transient RGA/GPU hiccups -- a
# throttled or just-woken-up device is a plausible trigger).
tr '\0' '\n' < /sys/firmware/devicetree/base/compatible > display_rockchip/rockchip/soc_compatible.txt 2>/dev/null || echo "not available" > display_rockchip/rockchip/soc_compatible.txt

collect_file "/sys/kernel/debug/devfreq/devfreq_summary" "display_rockchip/rockchip/devfreq_summary.txt"

for dev in /sys/class/devfreq/*; do
    [ -d "$dev" ] || continue
    name=$(basename "$dev")
    {
        echo "device: $name"
        echo "governor: $(cat "$dev/governor" 2>/dev/null || echo N/A)"
        echo "cur_freq_hz: $(cat "$dev/cur_freq" 2>/dev/null || echo N/A)"
        echo "min_freq_hz: $(cat "$dev/min_freq" 2>/dev/null || echo N/A)"
        echo "max_freq_hz: $(cat "$dev/max_freq" 2>/dev/null || echo N/A)"
        echo "available_frequencies_hz: $(cat "$dev/available_frequencies" 2>/dev/null || echo N/A)"
    } > "display_rockchip/rockchip/devfreq_${name}.txt" 2>&1
done

: > display_rockchip/rockchip/thermal_zones.txt
for zone in /sys/class/thermal/thermal_zone*; do
    [ -d "$zone" ] || continue
    echo "$(cat "$zone/type" 2>/dev/null || echo N/A): $(cat "$zone/temp" 2>/dev/null || echo N/A)" >> display_rockchip/rockchip/thermal_zones.txt
done

# RGA (2D blit/scale/CSC engine used for DVR reencode copy/resize/padding).
if [ -d /sys/kernel/debug/rkrga ]; then
    for f in driver_version hardware load scheduler_status mm_session request_manager debug dump_image dump_path; do
        collect_file "/sys/kernel/debug/rkrga/$f" "display_rockchip/rga/${f}.txt"
    done
else
    echo "rkrga not available" > display_rockchip/rga/not_available.txt
fi

# MPP (rockchip-mpp video codec service): dump every stat file it exposes
# under /proc, per hardware block (rkvdec/rkvenc/vdpu/vepu/iep/jpegd/...).
if [ -d /proc/mpp_service ]; then
    find /proc/mpp_service -type f 2>/dev/null | while read -r f; do
        relname=$(echo "$f" | sed 's#/proc/mpp_service/##; s#/#_#g')
        cat "$f" > "display_rockchip/mpp/${relname}.txt" 2>/dev/null || echo "could not read $f" > "display_rockchip/mpp/${relname}.txt"
    done
else
    echo "mpp_service not available" > display_rockchip/mpp/not_available.txt
fi

# 6. KERNEL AND DRIVERS
echo_colored "Collecting kernel and driver information..." "$GREEN"
mkdir -p kernel

# Kernel modules
lsmod 2>/dev/null > kernel/lsmod.txt || echo "lsmod not available" > kernel/lsmod.txt
cat /proc/modules 2>/dev/null > kernel/proc_modules.txt || echo "No /proc/modules" > kernel/proc_modules.txt

# Kernel messages
dmesg > kernel/dmesg.txt 2>&1
tail -n 1000 /var/log/kern.log 2>/dev/null > kernel/kern_log.txt || echo "No kern.log" > kernel/kern_log.txt

# Kernel parameters
cat /proc/cmdline > kernel/cmdline.txt 2>&1
sysctl -a 2>/dev/null > kernel/sysctl.txt || echo "sysctl not available" > kernel/sysctl.txt

# 7. NETWORK INFORMATION
echo_colored "Collecting network information..." "$GREEN"
mkdir -p network

# Network configuration
ip route show > network/route.txt 2>&1
cat /etc/resolv.conf 2>/dev/null > network/resolv.conf || echo "No resolv.conf" > network/resolv.conf
cat /etc/hosts 2>/dev/null > network/hosts || echo "No hosts file" > network/hosts

# Network connections
ss -tulnp 2>/dev/null > network/ss.txt || netstat -tulnp 2>/dev/null > network/netstat.txt || echo "No network stat tool" > network/netstat.txt

# Firewall rules
iptables -L -n -v 2>/dev/null > network/iptables.txt || echo "iptables not available" > network/iptables.txt

# Wlan devices
iw dev 2>/dev/null > network/iw.txt || echo "iw not available" > network/iw.txt

# 8. PROCESS INFORMATION
echo_colored "Collecting process information..." "$GREEN"
mkdir -p processes

ps aux > processes/ps_aux.txt 2>&1 || ps > processes/ps_aux.txt 2>&1
top -b -n 1 > processes/top.txt 2>&1

# Service status (if systemd or init.d)
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service > processes/services.txt 2>&1
    systemctl status > processes/systemctl_status.txt 2>&1
elif [ -d "/etc/init.d" ]; then
    ls -la /etc/init.d/ > processes/initd_services.txt 2>&1
fi

# 9. CONFIGURATION FILES
echo_colored "Collecting configuration files..." "$GREEN"
mkdir -p configs

# Common config files
collect_file "/etc/fstab" "configs/fstab"
collect_file "/etc/network/interfaces" "configs/network_interfaces"
for file in /etc/network/interfaces.d/*; do
    [ -f "$file" ] || continue
    mkdir -p configs/network_interfaces.d/
    collect_file "$file" "configs/network_interfaces.d/$(basename $file)"
done
# WiFi passphrases only as their SHA-256. The value never goes into a sed
# expression: a '/' or '&' in it broke the substitution (and, under the old
# set -e, the whole collection) or left it in plain text.
for file in /etc/*wpa*.conf; do
    [ -f "$file" ] || continue   # no match: the glob stays literal
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        *psk=* | *password=*)
            key=${line%%=*}
            v=${line#*=}; v=${v#\"}; v=${v%\"}
            printf '%s="sha256sum(%s)"\n' "$key" "$(printf %s "$v" | sha256sum | cut -d' ' -f1)" ;;
        *) printf '%s\n' "$line" ;;
        esac
    done < "$file" > "configs/$(basename $file)"
done
collect_file "/etc/hostname" "configs/hostname"
collect_file "/etc/timezone" "configs/timezone"
collect_file "/etc/passwd" "configs/passwd"
collect_file "/etc/group" "configs/group"
collect_file "/etc/shadow" "configs/shadow"
collect_file "/etc/shells" "configs/shells"

# Buildroot specific
collect_file "/etc/buildroot-version" "configs/buildroot_version"
collect_file "/etc/buildroot-build" "configs/buildroot_build"

# PixelPilot: the effective args/config in force for the run(s) captured in
# logs/pixelpilot*.log above. Config can be overridden from the SD card, so
# collect whichever copy is actually active (matches PIXELPILOT_ARGS logic
# in /etc/default/pixelpilot).
collect_file "/etc/default/pixelpilot" "configs/pixelpilot_defaults"
if [ -f /media/dvr/pixelpilot.yaml ]; then
    collect_file "/media/dvr/pixelpilot.yaml" "configs/pixelpilot.yaml"
else
    collect_file "/etc/pixelpilot.yaml" "configs/pixelpilot.yaml"
fi
if [ -f /media/dvr/osd.json ]; then
    collect_file "/media/dvr/osd.json" "configs/pixelpilot_osd.json"
else
    collect_file "/etc/pixelpilot/osd.json" "configs/pixelpilot_osd.json"
fi

# 10. PACKAGE INFORMATION
echo_colored "Collecting package information..." "$GREEN"
mkdir -p packages

# 11. ENVIRONMENT VARIABLES
echo_colored "Collecting environment information..." "$GREEN"
mkdir -p environment

env > environment/env.txt 2>&1
set > environment/set.txt 2>&1
printenv > environment/printenv.txt 2>&1

# 12. CUSTOM CHECKS
echo_colored "Running custom checks..." "$GREEN"
mkdir -p custom_checks

# Disk usage of what can grow (the root's own is in hardware/df.txt). Not
# `du /`: that walks /proc, /sys and the whole SD card.
du -sh /overlay /tmp /var/log 2>/dev/null > custom_checks/disk_usage.txt

# Inode usage
# busybox df without FEATURE_DF_FANCY (images without coreutils) has no -i.
df -i > custom_checks/inode_usage.txt 2>&1

# List filesystem: the root's own (-xdev: not /proc, /sys, /tmp or the SD
# card; the overlay's files are in video/binaries_overlay.txt).
find / -xdev 2>/dev/null > custom_checks/file_list.txt

# 13. CREATE SUMMARY REPORT
echo_colored "Creating summary report..." "$GREEN"
cat > summary_report.txt << EOF
SUPPORT DATA COLLECTION REPORT
=============================
Collection Time: ${START_TIME} - $(date) (uptime ${START_UPTIME} s at the start)
Hostname: $(hostname 2>/dev/null || echo 'unknown')
Kernel: $(uname -r)
Architecture: $(uname -m)

SYSTEM OVERVIEW:
- Uptime: $(uptime -p 2>/dev/null || cat /proc/uptime | awk '{print int($1/86400)" days "int(($1%86400)/3600)" hours "int(($1%3600)/60)" minutes"}')
- Load Average: $(cat /proc/loadavg 2>/dev/null || echo 'N/A')
- Memory: $(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')
- Storage: $(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')

NETWORK:
- Interfaces: $(ip link show | grep -c '^[0-9]*:')
- IP Addresses: $(ip addr show | grep -c 'inet ')

PROCESSES:
- Total: $(ps | wc -l)

COLLECTED DATA:
- System Info: $(ls -1 system_info/ 2>/dev/null | wc -l) files
- Hardware Info: $(ls -1 hardware/ 2>/dev/null | wc -l) files
- Display/Rockchip Info: $(find display_rockchip/ -type f 2>/dev/null | wc -l) files
- Kernel Info: $(ls -1 kernel/ 2>/dev/null | wc -l) files
- Network Info: $(ls -1 network/ 2>/dev/null | wc -l) files
- Log Files: $(ls -1 logs/ 2>/dev/null | wc -l) files
- Video pipeline: $(ls -1 video/ 2>/dev/null | wc -l) files
- Configuration: $(ls -1 configs/ 2>/dev/null | wc -l) files
- AR8030/Air: $(find ar8030/ -type f 2>/dev/null | wc -l) files$( [ -f ar8030/air/air_logs.tar.gz ] && echo " (incl. air unit snapshot)" || echo " (NO air unit snapshot, see ar8030/air/ssh.err)")

NOTES:
This archive contains troubleshooting data from your device.
Share this file with support for assistance.
The collection itself loads the system: in the logs it starts at the
"support data collection started" line (logs/messages.log).

EOF

# 14. CREATE README
cat > README.txt << 'EOF'
DEVICE SUPPORT DATA COLLECTION
==============================

This archive contains system information collected for troubleshooting purposes.

CONTENTS:
1. logs/             - System and application logs (includes pixelpilot.log)
2. ar8030/           - AR8030 link state (ground + air lifecycled API),
                       receiver and ar8030d logs, air unit snapshot
                       (air/air_logs.tar.gz) and the current flight log
                       session (flightlog/)
3. video/            - Video pipeline state: per-thread CPU and scheduling
                       of the receiver/ar8030d/PixelPilot, top, interrupts,
                       cpufreq, temperatures, binaries + overlay files,
                       the SD card's recordings
4. system_info/      - Basic system information
5. hardware/         - Hardware and device information
5a. display_rockchip/ - DRM/VOP2 display state, Rockchip devfreq/thermal,
                         RGA and MPP (video codec) diagnostics
6. kernel/           - Kernel and driver information
7. network/          - Network configuration and status
8. processes/        - Running processes and services
9. configs/          - Configuration files (includes pixelpilot config)
10. packages/        - Installed package information
11. environment/     - Environment variables
12. custom_checks/   - Additional diagnostic checks

FILES:
- summary_report.txt - Overview of collected data
- collection_script.sh - Copy of the collection script

SECURITY NOTES:
- This archive may contain sensitive information
- Review contents before sharing
- The script does not collect:
  * Personal user files
  * Browser history
  * Passwords (except hashed from /etc/shadow)
  * Encryption keys

EOF

# 15. SAVE THE SCRIPT ITSELF
cp "$0" "${COLLECTION_DIR}/collection_script.sh"

# 16. CREATE THE ARCHIVE
# On the SD card; without one (or a read-only one) in /tmp, and the exit
# status says so.
OUT_OK=1
if ! { [ -d "$OUTPUT_DIR" ] && touch "$OUTPUT_DIR/.collect_support_data" 2>/dev/null; }; then
    OUT_OK=0
    OUTPUT_DIR=/tmp
fi
rm -f "$OUTPUT_DIR/.collect_support_data"
OUTPUT_FILE="${OUTPUT_DIR}/${OUTPUT_PREFIX}_${TIMESTAMP}.zip"
echo_colored "Creating archive: ${OUTPUT_FILE}" "$GREEN"
cd "${COLLECTION_DIR}/.."
ARCHIVE_RC=1
if command -v zip >/dev/null 2>&1; then
    zip -rq "${OUTPUT_FILE}" "$(basename ${COLLECTION_DIR})" && ARCHIVE_RC=0
else
    echo_colored "zip command not found. Creating tar archive instead." "$YELLOW"
    OUTPUT_FILE="${OUTPUT_FILE%.zip}.tar.gz"
    tar -cf - "$(basename ${COLLECTION_DIR})" | gzip > "${OUTPUT_FILE}" && ARCHIVE_RC=0
fi
sync

if [ "$ARCHIVE_RC" != 0 ]; then
    rm -f "${OUTPUT_FILE}"
    echo_colored "Could not write ${OUTPUT_FILE}" "$RED" >&2
    exit 1
fi

# 17. FINAL INSTRUCTIONS
echo_colored "Archive created: ${OUTPUT_FILE} ($(du -h "${OUTPUT_FILE}" | cut -f1))" "$GREEN"
if [ "$OUT_OK" != 1 ]; then
    echo "No SD card at /media/dvr: the archive is in RAM, at ${OUTPUT_FILE}," >&2
    echo "and is lost at power-off. Insert a card and run this again, or copy" >&2
    echo "it off now (scp, or the USB network)." >&2
    exit 1
fi
cat << EOF

============================================
SUPPORT DATA COLLECTION COMPLETE
============================================
Archive created: ${OUTPUT_FILE}

NEXT STEPS:
1. Check the file size is reasonable (typically 1-10MB)
2. Review the contents if privacy is a concern
3. Upload to your support portal
4. Provide this filename with your support request

EOF

exit 0
