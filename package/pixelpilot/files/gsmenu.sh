#!/bin/sh
set -o pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

REMOTE_IP="${REMOTE_IP:-10.5.0.10}"
AIR_FIRMWARE_TYPE="${AIR_FIRMWARE_TYPE:-wfb}"
SSH_PASS="12345"
CACHE_DIR="/tmp/gsmenu_cache"
CACHE_TTL=10 # seconds
MAJESTIC_YAML="/etc/majestic.yaml"
WFB_YAML="/etc/wfb.yaml"
ALINK_CONF="/etc/alink.conf"
AALINK_CONF="/etc/aalink.conf"
TXPROFILES_CONF="/etc/txprofiles.conf"

# ══════════════════════════════════════════════════════════════════════════════
# SSH / SCP setup
# ══════════════════════════════════════════════════════════════════════════════

SSH="timeout -k 1 11 sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/run/ssh_control:%h:%p:%r -o ControlPersist=15s -o ServerAliveInterval=3 -o ServerAliveCountMax=2 root@$REMOTE_IP"
SCP="timeout -k 1 11 sshpass -p $SSH_PASS scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/run/ssh_control:%h:%p:%r -o ControlPersist=15s -o ServerAliveInterval=3 -o ServerAliveCountMax=2"

# ══════════════════════════════════════════════════════════════════════════════
# Helper functions
# ══════════════════════════════════════════════════════════════════════════════

mkdir -p "$CACHE_DIR"

# Emit the record separator followed by allowed values (for dropdowns/sliders).
# Called after the current value has been printed.
#   emit_values "1\n20\n25\n30"        – static list / range
#   emit_values_cmd <command> [args]   – dynamic values from a command
emit_values()     { printf '\x1e'"$1"; }
emit_values_cmd() { printf '\x1e'; "$@"; }

# Refresh cached config files from the air unit (10s TTL)
refresh_cache() {
    local current_time=$(date +%s)
    local last_refresh=$((current_time - CACHE_TTL))

    if [[ ! -f "$CACHE_DIR/last_refresh" ]] || [[ $(cat "$CACHE_DIR/last_refresh") -lt $last_refresh ]]; then
        files="$MAJESTIC_YAML $WFB_YAML $ALINK_CONF $TXPROFILES_CONF $AALINK_CONF"
        $SSH "tar cf - $files" 2>/dev/null | tar xf - --strip-components 1 -C /tmp/gsmenu_cache/ 2>/dev/null
        $SSH "find /etc/sensors/ -type f -name \"*\$(ipcinfo -s)*.bin\"" | sed 's/^\/etc\/sensors\///' | sed 's/\.bin$//' > /tmp/gsmenu_cache/sensor.txt
        echo "$current_time" > "$CACHE_DIR/last_refresh"
    fi
}

get_majestic_value() {
    local key="$1"
    yaml-cli -i "$CACHE_DIR/majestic.yaml" -g "$key" 2>/dev/null
}

get_wfb_value() {
    local key="$1"
    yaml-cli -i "$CACHE_DIR/wfb.yaml" -g "$key" 2>/dev/null
}

get_alink_value() {
    local key="$1"
    grep $key= "$CACHE_DIR/alink.conf" | cut -d "=" -f 2 2>/dev/null
}

get_aalink_value() {
    local key="$1"
    grep ^$key= "$CACHE_DIR/aalink.conf" | cut -d "=" -f 2 2>/dev/null
}

# Helper: list available wifi channels (used by air and gs)
list_wifi_channels() {
    iw list | grep MHz | grep -v disabled | grep -v "radar detection" | grep \* | tr -d '[]' | awk '{print $4 " (" $2 " " $3 ")"}' | grep '^[1-9]' | sort -n | uniq | head -c -1
}

# Remove the network stanza for <ssid> from wpa_supplicant.conf (no-op if absent).
wpa_conf_remove_network() {
    local ssid="$1"
    local conf="/etc/wpa_supplicant.conf"
    local tmpfile
    [ -f "$conf" ] || return 0
    tmpfile=$(mktemp)
    awk -v ssid="$ssid" '
        /network=\{/ { in_block=1; block="" }
        in_block { block = block $0 "\n" }
        in_block && /\}/ {
            if (index(block, "ssid=\"" ssid "\"") == 0)
                printf "%s", block
            in_block=0; block=""
            next
        }
        !in_block { print }
    ' "$conf" > "$tmpfile"
    mv "$tmpfile" "$conf"
}

# Add or update a network stanza in wpa_supplicant.conf.
# Usage: wpa_conf_update_network <ssid> <psk>  (psk may be empty for open networks)
wpa_conf_update_network() {
    local ssid="$1"
    local psk="$2"
    local conf="/etc/wpa_supplicant.conf"

    # Drop any existing stanza for this SSID, then append the updated one
    wpa_conf_remove_network "$ssid"

    if [ -z "$psk" ]; then
        printf 'network={\n    ssid="%s"\n    key_mgmt=NONE\n}\n' "$ssid" >> "$conf"
    else
        printf 'network={\n    ssid="%s"\n    psk="%s"\n}\n' "$ssid" "$psk" >> "$conf"
    fi
}

send_cmd() {
    echo "$1" | nc -w 11 $REMOTE_IP 12355
}

# waybeam_venc's REST API (Artosyn mode, air unit at $REMOTE_IP:80 over the
# ar8030 ar_net0 TUN bridge). Protocol confirmed live against a running unit
# (see web/dashboard.html's own "API Reference" tab in OpenIPC/waybeam_venc):
#   GET /api/v1/get?<key>       -> {"ok":true,"data":{"field":"<key>","value":<v>}}
#   GET /api/v1/set?<key>=<val> -> {"ok":true,"data":{"field":"<key>","value":<v>,"reinit_pending":bool}}
# <key> is the dotted camelCase path into /api/v1/config's "config" object
# (e.g. "video0.bitrate", "isp.sensorBin"), NOT the snake_case name
# /api/v1/capabilities itself uses to describe the same field.
WAYBEAM_TIMEOUT=5

get_waybeam_value() {
    local key="$1"
    curl -s -m "$WAYBEAM_TIMEOUT" "http://$REMOTE_IP/api/v1/get?$key" 2>/dev/null \
        | jq -r '.data.value // empty' 2>/dev/null
}

set_waybeam_value() {
    local key="$1" val="$2" enc
    enc=$(jq -rn --arg v "$val" '$v|@uri')
    curl -s -m "$WAYBEAM_TIMEOUT" "http://$REMOTE_IP/api/v1/set?${key}=${enc}" >/dev/null 2>&1
}

# sensor.mode is a bare pad/mode index with no inherent meaning on its own --
# /api/v1/modes is what turns it into something a human can read ("OS02K10
# 1080p100 RAW10"). Only pad 0 is offered; multi-pad (dual-sensor) boards would
# need a pad picker of their own.
waybeam_modes_json() {
    curl -s -m "$WAYBEAM_TIMEOUT" "http://$REMOTE_IP/api/v1/modes" 2>/dev/null
}
waybeam_mode_desc_for_index() {
    local idx="$1"
    [ "$idx" = "-1" ] && { echo "Auto"; return; }
    waybeam_modes_json | jq -r --arg i "$idx" \
        '.data.pads[0].modes[] | select((.index|tostring)==$i) | .desc'
}
waybeam_mode_descs() {
    printf 'Auto\n'
    waybeam_modes_json | jq -r '[.data.pads[0].modes[].desc] | join("\n")'
}
waybeam_mode_index_for_desc() {
    local desc="$1"
    [ "$desc" = "Auto" ] && { echo -1; return; }
    waybeam_modes_json | jq -r --arg d "$desc" \
        '.data.pads[0].modes[] | select(.desc==$d) | .index' | head -1
}

# isp.sensorBin is a full path (e.g. /etc/sensors/cam_os02k10_100fps_xg1_day.bin)
# with no listing endpoint of its own -- unlike majestic's sensor_file, waybeam's
# REST API doesn't expose the air unit's filesystem, so this still goes over the
# same SSH ($SSH, root/$SSH_PASS) the majestic camera section above uses,
# confirmed reachable on a live CV610 waybeam unit the same as any other OpenIPC
# air unit. Not part of refresh_cache()'s periodic pull -- listed on demand only,
# since swapping calibration bins is rare compared to how often this page opens.
list_waybeam_sensor_bins() {
    $SSH "find /etc/sensors/ -type f -name '*.bin'" 2>/dev/null \
        | sed 's/^\/etc\/sensors\///' | sed 's/\.bin$//' | sort
}

# ar8030-lifecycled's HTTP control API (ar8030-transport/lifecycled/,
# lifecycle_http.c) -- runs on BOTH ends of the link, same binary/port, one
# per side ($REMOTE_IP:8899 for the air unit's own radio, 127.0.0.1:8899 for
# this ground unit's own radio -- ar8030-transport-rx's own
# S98ar8030-transport-rx runs it locally here). "side" below is "air" or
# "gs". Responses are flat JSON (no "data" wrapper, unlike waybeam's API):
#   GET  /api/v1/status                       -> {"ok":true,"role":...,"state":...,"bandwidth_mhz":N,"paired":bool,...}
#   POST /api/v1/bandwidth?mhz=<1|2|5|10|20|40> -> persisted, survives reconnects
#   GET  /api/v1/channel                      -> {"channel":"auto"|N|null,...,"table_mhz":[...]}
#   POST /api/v1/channel?chan=<index|auto>    -> persisted on the air unit (AP), which owns the channel
#   GET  /api/v1/power                        -> {"power":"auto"|mW|null,"power_dbm":N,"power_levels":[...]}
#   POST /api/v1/power?level=<mW|auto>        -> persisted, per side
#   POST /api/v1/linkctl?cmd=<c>&args=<...>   -> {"ok":true,"exit_code":0,"output":"..."}, one-shot passthrough
LIFECYCLED_TIMEOUT=5

lifecycled_url() {
    [ "$1" = "air" ] && echo "http://$REMOTE_IP:8899" || echo "http://127.0.0.1:8899"
}

lifecycled_status_json() {
    curl -s -m "$LIFECYCLED_TIMEOUT" "$(lifecycled_url "$1")/api/v1/status" 2>/dev/null
}

get_lifecycled_bandwidth() {
    lifecycled_status_json "$1" | jq -r '.bandwidth_mhz // empty' 2>/dev/null
}

set_lifecycled_bandwidth() {
    local side="$1" mhz="$2"
    curl -s -m "$LIFECYCLED_TIMEOUT" -X POST "$(lifecycled_url "$side")/api/v1/bandwidth?mhz=${mhz}" >/dev/null 2>&1
}

# Output power: a level in mW or "auto" (ground only), persisted per side by
# that side's own lifecycled. Shown as "500 mW"/"auto"; the level set comes
# from the API (power_levels), since air and ground offer different ones.
lifecycled_power_json() {
    curl -s -m "$LIFECYCLED_TIMEOUT" "$(lifecycled_url "$1")/api/v1/power" 2>/dev/null
}

get_lifecycled_power() {
    lifecycled_power_json "$1" | jq -r \
        '.power | if . == null then empty elif . == "auto" then "auto" else (tostring + " mW") end' 2>/dev/null
}

list_lifecycled_power_levels() {
    lifecycled_power_json "$1" | jq -r \
        '.power_levels[] | if . == "auto" then "auto" else (tostring + " mW") end' 2>/dev/null
}

# The dropdown hands over the whole option ("100 mW", "32 (6075 MHz)") as one
# argument -- only its first word is the value.
first_word() { echo "$1" | awk '{print $1}'; }

set_lifecycled_power() {
    local side="$1" level
    level=$(first_word "$2")
    curl -s -m "$LIFECYCLED_TIMEOUT" -X POST "$(lifecycled_url "$side")/api/v1/power?level=${level}" >/dev/null 2>&1
}

# Channel: owned and persisted by the air unit's lifecycled (the AP); a
# change there retunes both ends together over the live link. Shown as
# "auto" or "<index> (<MHz> MHz)" from the chip's own channel table
# (table_mhz), so the picker always matches the table ar8030.json defines.
lifecycled_channel_json() {
    curl -s -m "$LIFECYCLED_TIMEOUT" "$(lifecycled_url "$1")/api/v1/channel" 2>/dev/null
}

get_lifecycled_channel() {
    lifecycled_channel_json "$1" | jq -r \
        '.channel as $c | if $c == null then empty elif $c == "auto" then "auto"
         else ($c|tostring) + " (" + ((.table_mhz[$c] // "?")|tostring) + " MHz)" end' 2>/dev/null
}

list_lifecycled_channels() {
    lifecycled_channel_json "$1" | jq -r \
        '"auto", (.table_mhz | to_entries[] | (.key|tostring) + " (" + (.value|tostring) + " MHz)")' 2>/dev/null
}

set_lifecycled_channel() {
    local side="$1" chan
    chan=$(first_word "$2")
    curl -s -m "$LIFECYCLED_TIMEOUT" -X POST "$(lifecycled_url "$side")/api/v1/channel?chan=${chan}" >/dev/null 2>&1
}

lifecycled_status_summary() {
    local j
    j=$(lifecycled_status_json "$1")
    if [ -z "$j" ]; then
        echo "unreachable"
        return
    fi
    echo "$j" | jq -r \
        '.state + " slot=" + (.connected_slot|tostring) + " bw=" + (.bandwidth_mhz|tostring) + "MHz" +
         (if .power == null then "" elif .power == "auto" then " pwr=auto" else " pwr=" + (.power|tostring) + "mW" end) +
         (if .paired then " (paired)" else " (not paired)" end)' 2>/dev/null
}


# ══════════════════════════════════════════════════════════════════════════════
# Cache refresh (only for air get commands)
# ══════════════════════════════════════════════════════════════════════════════

case "$@" in
  "get air waybeam"*|"get air artosyn"*)
    # None of these fields read $CACHE_DIR/{majestic,wfb,alink,aalink}.* or
    # sensor.txt's ipcinfo-filtered listing -- waybeam has its own REST API
    # (get_waybeam_value) and its own on-demand SSH bin-file listing
    # (list_waybeam_sensor_bins) below, and ar8030's radio params are neither
    # of those either. Skip the refresh so opening these pages doesn't pull a
    # cache nothing here uses.
    ;;
  "get air"*)
    refresh_cache
    ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Main command dispatch
# ══════════════════════════════════════════════════════════════════════════════

case "$@" in

# ── Air: WFB-NG ─────────────────────────────────────────────────────────────

    "get air wfbng power")
        get_wfb_value '.wireless.txpower'
        emit_values "1\n20\n25\n30\n35\n40\n45\n50\n55\n58"
        ;;
    "get air wfbng air_channel")
        channel=$(get_wfb_value '.wireless.channel' | tr -d '\n')
        iw list | grep "\[$channel\]" | tr -d '[]' | awk '{print $4 " (" $2 " " $3 ")"}' | sort -n | uniq | tr -d '\n'
        emit_values_cmd list_wifi_channels
        ;;
    "get air wfbng width")
        get_wfb_value '.wireless.width'
        emit_values "20\n40"
        ;;
    "get air wfbng mcs_index")
        get_wfb_value '.broadcast.mcs_index'
        emit_values "0 10"
        ;;
    "get air wfbng stbc")
        get_wfb_value '.broadcast.stbc'
        ;;
    "get air wfbng ldpc")
        get_wfb_value '.broadcast.ldpc'
        ;;
    "get air wfbng fec_k")
        get_wfb_value '.broadcast.fec_k'
        emit_values "0 15"
        ;;
    "get air wfbng fec_n")
        get_wfb_value '.broadcast.fec_n'
        emit_values "0 15"
        ;;
    "get air wfbng mlink")
        get_wfb_value '.wireless.mlink'
        emit_values "1500\n1600\n1700\n1800\n1900\n2000\n2100\n2200\n2300\n2400\n2500\n2600\n2700\n2800\n2900\n3000\n3100\n3200\n3300\n3400\n3500\n3600\n3700\n3800\n3900\n4000"
        ;;
    "get air wfbng adaptivelink")
        $SSH grep ^alink_drone /etc/rc.local | grep -q 'alink_drone' && echo 1 || echo 0
        ;;

    "set air wfbng power"*)
        $SSH wifibroadcast cli -s .wireless.txpower $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng air_channel"*)
        channel=$(echo $5 | awk '{print $1}')
        $SSH wifibroadcast cli -s .wireless.channel $channel
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        sed -i "s/^wifi_channel =.*/wifi_channel = $channel/" /etc/wifibroadcast.cfg
        /etc/init.d/S98wifibroadcast restart
        ;;
    "set air wfbng width"*)
        $SSH wifibroadcast cli -s .wireless.width $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng mcs_index"*)
        $SSH wifibroadcast cli -s .broadcast.mcs_index $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng stbc"*)
        if [ "$5" = "on" ]; then
            $SSH wifibroadcast cli -s .broadcast.stbc 1
        else
            $SSH wifibroadcast cli -s .broadcast.stbc 0
        fi
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng ldpc"*)
        if [ "$5" = "on" ]; then
            $SSH wifibroadcast cli -s .broadcast.ldpc 1
        else
            $SSH wifibroadcast cli -s .broadcast.ldpc 0
        fi
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng fec_k"*)
        $SSH wifibroadcast cli -s .broadcast.fec_k $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng fec_n"*)
        $SSH wifibroadcast cli -s .broadcast.fec_n $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng mlink"*)
        $SSH wifibroadcast cli -s .wireless.mlink $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air wfbng adaptivelink"*)
        if [ "$5" = "on" ]; then
            $SSH 'sed -i "/alink_drone &/d" /etc/rc.local && sed -i -e "\$i alink_drone &" /etc/rc.local && cli -s .video0.qpDelta -12 && killall -1 majestic && (nohup alink_drone >/dev/null 2>&1 &)'
        else
            $SSH 'killall -q -9 alink_drone;  sed -i "/alink_drone &/d" /etc/rc.local  ; cli -d .video0.qpDelta && killall -1 majestic'
        fi
        ;;

# ── Air: Camera ──────────────────────────────────────────────────────────────

    "get air camera mirror")
        [ "$(get_majestic_value '.image.mirror')" = "true" ] && echo 1 || echo 0
        ;;
    "get air camera flip")
        [ "$(get_majestic_value '.image.flip')" = "true" ] && echo 1 || echo 0
        ;;
    "get air camera contrast")
        get_majestic_value '.image.contrast'
        emit_values "0 100"
        ;;
    "get air camera hue")
        get_majestic_value '.image.hue'
        emit_values "0 100"
        ;;
    "get air camera saturation")
        get_majestic_value '.image.saturation'
        emit_values "0 100"
        ;;
    "get air camera luminace")
        get_majestic_value '.image.luminance'
        emit_values "0 100"
        ;;
    "get air camera size")
        get_majestic_value '.video0.size'
        emit_values "1280x720\n1456x816\n1920x1080\n1440x1080\n1920x1440\n2104x1184\n2208x1248\n2240x1264\n2312x1304\n2436x1828\n2512x1416\n2560x1440\n2560x1920\n2720x1528\n2944x1656\n3200x1800\n3840x2160"
        ;;
    "get air camera video_mode")
        send_cmd get_current_video_mode
        emit_values_cmd send_cmd get_all_video_modes
        ;;
    "get air camera fps")
        get_majestic_value '.video0.fps'
        emit_values "60\n90\n120"
        ;;
    "get air camera bitrate")
        get_majestic_value '.video0.bitrate'
        emit_values "1000\n2000\n3000\n4000\n5000\n6000\n7000\n8000\n9000\n10000\n11000\n12000\n13000\n14000\n15000\n16000\n17000\n18000\n19000\n20000\n21000\n22000\n23000\n24000\n25000\n26000\n27000\n28000\n29000\n30000"
        ;;
    "get air camera codec")
        get_majestic_value '.video0.codec'
        emit_values "h264\nh265"
        ;;
    "get air camera gopsize")
        get_majestic_value '.video0.gopSize'
        emit_values "0 10"
        ;;
    "get air camera rc_mode")
        get_majestic_value '.video0.rcMode'
        emit_values "vbr\navbr\ncbr"
        ;;
    "get air camera rec_enable")
        [ "$(get_majestic_value '.records.enabled')" = "true" ] && echo 1 || echo 0
        ;;
    "get air camera rec_split")
        get_majestic_value '.records.split'
        emit_values "0 60"
        ;;
    "get air camera rec_maxusage")
        get_majestic_value '.records.maxUsage'
        emit_values "0 100"
        ;;
    "get air camera exposure")
        get_majestic_value '.isp.exposure'
        emit_values "5 50"
        ;;
    "get air camera antiflicker")
        get_majestic_value '.isp.antiFlicker'
        emit_values "disabled\n50\n60"
        ;;
    "get air camera sensor_file")
        basename -s .bin $(basename $(get_majestic_value '.isp.sensorConfig'))
        emit_values "$(cat /tmp/gsmenu_cache/sensor.txt)"
        ;;
    "get air camera fpv_enable")
        get_majestic_value '.fpv.enabled' | grep -q true && echo 1 || echo 0
        ;;
    "get air camera noiselevel")
        get_majestic_value '.fpv.noiseLevel'
        emit_values "0 1"
        ;;
    "get air camera audio_enabled")
        get_majestic_value '.audio.enabled' | grep -q true && echo 1 || echo 0
        ;;
    "get air camera audio_volume")
        get_majestic_value '.audio.volume'
        emit_values "0 100"
        ;;
    "get air camera audio_srate")
        get_majestic_value '.audio.srate'
        emit_values "8000\n16000\n32000\n48000"
        ;;

    "set air camera mirror"*)
        if [ "$5" = "on" ]; then
            $SSH 'cli -s .image.mirror true && killall -1 majestic'
        else
            $SSH 'cli -s .image.mirror false && killall -1 majestic'
        fi
        ;;
    "set air camera flip"*)
        if [ "$5" = "on" ]; then
            $SSH 'cli -s .image.flip true && killall -1 majestic'
        else
            $SSH 'cli -s .image.flip false && killall -1 majestic'
        fi
        ;;
    "set air camera contrast"*)
        $SSH "cli -s .image.contrast $5 && killall -1 majestic"
        ;;
    "set air camera hue"*)
        $SSH "cli -s .image.hue $5 && killall -1 majestic"
        ;;
    "set air camera saturation"*)
        $SSH "cli -s .image.saturation $5 && killall -1 majestic"
        ;;
    "set air camera luminace"*)
        $SSH "cli -s .image.luminance $5 && killall -1 majestic"
        ;;
    "set air camera size"*)
        $SSH "cli -s .video0.size $5 && killall -1 majestic"
        ;;
    "set air camera video_mode"*)
        echo set_simple_video_mode "$5" | nc -w 11 $REMOTE_IP 12355
        ;;
    "set air camera fps"*)
        $SSH "cli -s .video0.fps $5 && killall -1 majestic"
        ;;
    "set air camera bitrate"*)
        $SSH "cli -s .video0.bitrate $5 && killall -1 majestic"
        ;;
    "set air camera codec"*)
        $SSH "cli -s .video0.codec $5 && killall -1 majestic"
        ;;
    "set air camera gopsize"*)
        $SSH "cli -s .video0.gopSize $5 && killall -1 majestic"
        ;;
    "set air camera rc_mode"*)
        $SSH "cli -s .video0.rcMode $5 && killall -1 majestic"
        ;;
    "set air camera rec_enable"*)
        if [ "$5" = "on" ]; then
            $SSH 'cli -s .records.enable true && killall -1 majestic'
        else
            $SSH 'cli -s .records.enable false && killall -1 majestic'
        fi
        ;;
    "set air camera rec_split"*)
        $SSH "cli -s .records.split $5 && killall -1 majestic"
        ;;
    "set air camera rec_maxusage"*)
        $SSH "cli -s .records.maxUsage $5 && killall -1 majestic"
        ;;
    "set air camera exposure"*)
        $SSH "cli -s .isp.exposure $5 && killall -1 majestic"
        ;;
    "set air camera antiflicker"*)
        $SSH "cli -s .isp.antiFlicker $5 && killall -1 majestic"
        ;;
    "set air camera sensor_file"*)
        $SSH "cli -s .isp.sensorConfig /etc/sensors/${5}.bin && killall -1 majestic"
        ;;
    "set air camera fpv_enable"*)
        if [ "$5" = "on" ]; then
            $SSH 'cli -s .fpv.enabled true && killall -1 majestic'
        else
            $SSH 'cli -s .fpv.enabled false && killall -1 majestic'
        fi
        ;;
    "set air camera noiselevel"*)
        $SSH "cli -s .fpv.noiseLevel $5 && killall -1 majestic"
        ;;
    "set air camera audio_enabled"*)
        if [ "$5" = "on" ]; then
            $SSH 'cli -s .audio.enabled true && killall -1 majestic'
        else
            $SSH 'cli -s .audio.enabled false && killall -1 majestic'
        fi
        ;;
    "set air camera audio_volume"*)
        $SSH "cli -s .audio.volume $5 && killall -1 majestic"
        ;;
    "set air camera audio_srate"*)
        $SSH "cli -s .audio.srate $5 && killall -1 majestic"
        ;;

# ── Air: Waybeam (REST API camera, Artosyn mode) ────────────────────────────
# Talks to waybeam_venc's own REST API on $REMOTE_IP (192.168.100.1 over the
# ar8030 ar_net0 TUN bridge in production) via get_waybeam_value/set_waybeam_value
# above. Field names/enums confirmed against a live unit and against
# web/dashboard.html in OpenIPC/waybeam_venc (its built-in "API Reference" tab
# and ENUMS table are the source of truth here, not this comment).

    "get air waybeam sensor_mode")
        waybeam_mode_desc_for_index "$(get_waybeam_value sensor.mode)"
        emit_values_cmd waybeam_mode_descs
        ;;
    "get air waybeam isp_binfile")
        cur=$(get_waybeam_value isp.sensorBin)
        [ -n "$cur" ] && basename -s .bin "$cur"
        emit_values_cmd list_waybeam_sensor_bins
        ;;
    "get air waybeam image_rotate180")
        # image.rotate isn't supported on this backend -- flip+mirror together
        # is the 180deg-rotation equivalent, always set/read as a pair. Only
        # report "on" when both agree; a mismatch (set some other way) reads
        # as "off" rather than guessing.
        [ "$(get_waybeam_value image.flip)" = "true" ] && [ "$(get_waybeam_value image.mirror)" = "true" ] \
            && echo 1 || echo 0
        ;;
    "get air waybeam video_size")
        get_waybeam_value video0.size
        emit_values "1280x720\n1920x1080"
        ;;
    "get air waybeam video_resilience")
        get_waybeam_value video0.resilience
        emit_values "off\nrescue\nquality\nsprint\nracing\nrally\nendurance\npatrol\nrange\nfpv"
        ;;
    "get air waybeam audio_enabled")
        [ "$(get_waybeam_value audio.enabled)" = "true" ] && echo 1 || echo 0
        ;;

    "set air waybeam sensor_mode"*)
        set_waybeam_value sensor.mode "$(waybeam_mode_index_for_desc "$5")"
        ;;
    "set air waybeam isp_binfile"*)
        set_waybeam_value isp.sensorBin "/etc/sensors/$5.bin"
        ;;
    "set air waybeam image_rotate180"*)
        if [ "$5" = "on" ]; then
            set_waybeam_value image.flip true
            sleep 5
            set_waybeam_value image.mirror true
        else
            set_waybeam_value image.flip false
            sleep 5
            set_waybeam_value image.mirror false
        fi
        ;;
    "set air waybeam video_size"*)
        set_waybeam_value video0.size "$5"
        ;;
    "set air waybeam video_resilience"*)
        set_waybeam_value video0.resilience "$5"
        ;;
    "set air waybeam audio_enabled"*)
        [ "$5" = "on" ] && set_waybeam_value audio.enabled true || set_waybeam_value audio.enabled false
        ;;

# ── Air: Telemetry ───────────────────────────────────────────────────────────

    "get air telemetry serial")
        if [ $AIR_FIRMWARE_TYPE = "wfb" ]; then
            $SSH wifibroadcast cli -g .telemetry.serial
        elif [ $AIR_FIRMWARE_TYPE = "apfpv" ]; then
            tty=$($SSH "fw_printenv -n msposd_tty")
            if [ ! -z $tty ]; then
                basename "$tty"
            else
                echo ttyS2
            fi
        fi
        emit_values "ttyS0\nttyS1\nttyS2\nttyS3"
        ;;
    "get air telemetry router")
        $SSH wifibroadcast cli -g .telemetry.router
        emit_values "mavfwd\nmsposd"
        ;;
    "get air telemetry osd_fps")
        $SSH wifibroadcast cli -g .telemetry.osd_fps
        emit_values "0 60"
        ;;
    "get air telemetry gs_rendering")
        $SSH 'grep "\-z \"\$size\"" /usr/bin/wifibroadcast' | grep -q size && echo 0 || echo 1
        ;;

    "set air telemetry serial"*)
        if [ "$5" = "ttyS0" ]; then
          $SSH "sed -i 's/^console::respawn:\/sbin\/getty -L console 0 vt100/#console::respawn:\/sbin\/getty -L console 0 vt100/' /etc/inittab ; kill -HUP 1"
        else
          $SSH "sed -i 's/^#console::respawn:\/sbin\/getty -L console 0 vt100/console::respawn:\/sbin\/getty -L console 0 vt100/' /etc/inittab ; kill -HUP 1"
        fi
        if [ $AIR_FIRMWARE_TYPE = "wfb" ]; then
            $SSH wifibroadcast cli -s .telemetry.serial $5
            $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        elif [ $AIR_FIRMWARE_TYPE = "apfpv" ]; then
            $SSH "fw_setenv msposd_tty /dev/$5; /etc/init.d/S99msposd stop ; /etc/init.d/S99msposd stop ; sleep 1; /etc/init.d/S99msposd start"
        fi
        ;;
    "set air telemetry router"*)
        $SSH wifibroadcast cli -s .telemetry.router $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air telemetry osd_fps"*)
        $SSH wifibroadcast cli -s .telemetry.osd_fps $5
        $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        ;;
    "set air telemetry gs_rendering"*)
        if [ "$5" = "on" ]; then
            $SSH 'sed -i "s/-o 127\.0\.0\.1:\"\$port_tx\" -z \"\$size\"/-o 10\.5\.0\.1:\"\$port_tx\"/" /usr/bin/wifibroadcast'
            $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        else
            $SSH 'sed -i "s/-o 10\.5\.0\.1:\"\$port_tx\"/-o 127\.0\.0\.1:\"\$port_tx\" -z \"\$size\"/" /usr/bin/wifibroadcast'
            $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        fi
        ;;

# ── Air: Alink ───────────────────────────────────────────────────────────────

    "get air alink power_level_0_to_4")
        get_alink_value power_level_0_to_4
        emit_values "0\n1\n2\n3\n4"
        ;;
    "get air alink fallback_ms")
        get_alink_value fallback_ms
        emit_values "1 2000"
        ;;
    "get air alink hold_fallback_mode_s")
        get_alink_value hold_fallback_mode_s
        emit_values "1 10"
        ;;
    "get air alink min_between_changes_ms")
        get_alink_value min_between_changes_ms
        emit_values "1 10000"
        ;;
    "get air alink hold_modes_down_s")
        get_alink_value hold_modes_down_s
        emit_values "1 10"
        ;;
    "get air alink hysteresis_percent")
        get_alink_value hysteresis_percent
        emit_values "0 100"
        ;;
    "get air alink hysteresis_percent_down")
        get_alink_value hysteresis_percent_down
        emit_values "0 100"
        ;;
    "get air alink exp_smoothing_factor")
        get_alink_value exp_smoothing_factor
        emit_values "0 1.6"
        ;;
    "get air alink exp_smoothing_factor_down")
        get_alink_value exp_smoothing_factor_down
        emit_values "0 1.6"
        ;;
    "get air alink check_xtx_period_ms")
        get_alink_value check_xtx_period_ms
        emit_values "1 5000"
        ;;
    "get air alink request_keyframe_interval_ms")
        get_alink_value request_keyframe_interval_ms
        emit_values "1 5000"
        ;;
    "get air alink osd_level")
        get_alink_value osd_level
        emit_values "0\n1\n2\n3\n4\n5\n6"
        ;;
    "get air alink multiply_font_size_by")
        get_alink_value multiply_font_size_by
        emit_values "0 1.5"
        ;;
    "get air alink"*)
        get_alink_value $4
        ;;

    "set air alink"*)
        if [ "$5" = "off" ]; then
            $SSH 'sed -i "s/'$4'=.*/'$4'=0/" /etc/alink.conf; killall -9 alink_drone ; alink_drone &'
        elif [ "$5" = "on" ]; then
            $SSH 'sed -i "s/'$4'=.*/'$4'=1/" /etc/alink.conf; killall -9 alink_drone ; alink_drone &'
        elif [ "$4" = "txprofiles" ]; then
            $SCP $CACHE_DIR/txprofiles.conf root@$REMOTE_IP:$TXPROFILES_CONF
            $SSH 'killall -9 alink_drone ; alink_drone &'
        else
            $SSH 'sed -i "s/'$4'=.*/'$4'='$5'/" /etc/alink.conf; killall -9 alink_drone ; alink_drone &'
        fi
        ;;

# ── Air: Aalink ──────────────────────────────────────────────────────────────

    "get air aalink SHOW_SIGNAL_BARS")
        [ "$(get_aalink_value 'SHOW_SIGNAL_BARS')" = "true" ] && echo 1 || echo 0
        ;;
    "get air aalink channel")
        send_cmd get_current_ap_channel
        emit_values_cmd send_cmd get_all_ap_channels
        ;;
    "get air aalink SCALE_TX_POWER")
        get_aalink_value SCALE_TX_POWER
        emit_values "0.2 1.2"
        ;;
    "get air aalink THRESH_SHIFT")
        get_aalink_value THRESH_SHIFT
        emit_values "-50 50"
        ;;
    "get air aalink OSD_SCALE")
        get_aalink_value OSD_SCALE
        emit_values "0.2 2"
        ;;
    "get air aalink OSD_LEVEL")
        get_aalink_value OSD_LEVEL
        emit_values "0\n1\n2\n3"
        ;;
    "get air aalink THROUGHPUT_PCT")
        get_aalink_value THROUGHPUT_PCT
        emit_values "0 100"
        ;;
    "get air aalink HIGH_TEMP")
        get_aalink_value HIGH_TEMP
        emit_values "70 100"
        ;;
    "get air aalink MCS_SOURCE")
        get_aalink_value MCS_SOURCE
        emit_values "lowest\ndownlink"
        ;;
    "get air aalink"*)
        get_aalink_value $4
        ;;

    "set air aalink channel"*)
        echo "set_ap_channel $5" | nc -w 11 $REMOTE_IP 12355
        ;;
    "set air aalink SHOW_SIGNAL_BARS"*)
        case "$5" in
        on|true|1|yes)  val=true  ;;
        *)              val=false ;;
        esac
        $SSH "sed -i 's/^SHOW_SIGNAL_BARS=.*/SHOW_SIGNAL_BARS=$val/' /etc/aalink.conf && kill -SIGHUP \$(pidof aalink)"
        ;;
    "set air aalink"*)
        $SSH 'sed -i "s/^'$4'=.*/'$4'='$5'/" /etc/aalink.conf; kill -SIGHUP $(pidof aalink)'
        ;;

# ── Air: Artosyn ─────────────────────────────────────────────────────────────
# ar8030-lifecycled's HTTP control API on the air unit ($REMOTE_IP:8899, see
# lifecycled_url() above). All three are lifecycled-persisted: bandwidth and
# output power per side, the channel by the air unit alone (it owns it --
# changing it here retunes both ends together over the live link).

    "get air artosyn bandwidth")
        get_lifecycled_bandwidth air
        emit_values "1\n2\n5\n10\n20\n40"
        ;;
    "get air artosyn power")
        get_lifecycled_power air
        emit_values_cmd list_lifecycled_power_levels air
        ;;
    "get air artosyn channel")
        get_lifecycled_channel air
        emit_values_cmd list_lifecycled_channels air
        ;;

    "set air artosyn bandwidth"*)
        set_lifecycled_bandwidth air "$5"
        ;;
    "set air artosyn power"*)
        set_lifecycled_power air "$5"
        ;;
    "set air artosyn channel"*)
        set_lifecycled_channel air "$5"
        ;;

# ── GS: WFB-NG ──────────────────────────────────────────────────────────────

    "get gs wfbng gs_channel")
        channel=$(grep wifi_channel /etc/wifibroadcast.cfg | cut -d ' ' -f 3)
        iw list | grep "\[$channel\]" | tr -d '[]' | awk '{print $4 " (" $2 " " $3 ")"}' | sort -n | uniq | head -c -1
        emit_values_cmd list_wifi_channels
        ;;
    "get gs wfbng bandwidth")
        grep ^bandwidth /etc/wifibroadcast.cfg | cut -d ' ' -f 3
        emit_values "20\n40"
        ;;
    "get gs wfbng txpower")
        wifi_txpower=$(grep ^wifi_txpower /etc/wifibroadcast.cfg)
        if [ -z "$wifi_txpower" ]; then
            echo "50"
        else
            read first_card first_card_power < <(
                echo "$wifi_txpower" | cut -d = -f 2 | jq -r '"\(to_entries[0].key) \(to_entries[0].value)"'
            )
            first_card_type=$(udevadm info /sys/class/net/${first_card} | grep -E 'ID_USB_DRIVER=(rtl88xxau_wfb|rtl88x2eu|rtl88x2cu)'| cut -d = -f2)
            case "$first_card_type" in
            "rtl88xxau_wfb") min_phy_txpower=-1000; max_phy_txpower=-3000 ;;
            "rtl88x2eu"|"rtl88x2cu") min_phy_txpower=1000; max_phy_txpower=2900 ;;
            esac
            range=$((max_phy_txpower - min_phy_txpower))
            position=$((first_card_power - min_phy_txpower))
            percentage=$(( (position * 100) / range ))
            echo $percentage
        fi
        emit_values "1\n100"
        ;;
    "get gs wfbng adaptivelink")
        . /etc/default/adaptive-link
        if [ x$ADAPTIVE_LINK_ENABLED = x"false" ]; then
           echo "0"
        else
            echo "1"
        fi
        ;;

    "set gs wfbng gs_channel"*)
        channel=$(echo $5 | awk '{print $1}')
        if [ "$GSMENU_VTX_DETECTED" -eq "1" ]; then
            $SSH wifibroadcast cli -s .wireless.channel $channel
            $SSH "(wifibroadcast stop ;wifibroadcast stop; sleep 1;  wifibroadcast start) >/dev/null 2>&1 &"
        fi
        sed -i "s/^wifi_channel =.*/wifi_channel = $channel/" /etc/wifibroadcast.cfg
        /etc/init.d/S98wifibroadcast restart
        ;;
    "set gs wfbng bandwidth"*)
        sed -i "s/^bandwidth = .*/bandwidth = $5/" /etc/wifibroadcast.cfg
        /etc/init.d/S98wifibroadcast restart
        ;;
    "set gs wfbng txpower"*)
        .  /etc/default/wifibroadcast
        wifi_txpower=""
        for nic in $WFB_NICS
        do
            card_type=$(udevadm info /sys/class/net/${nic} | grep -E 'ID_USB_DRIVER=(rtl88xxau_wfb|rtl88x2eu|rtl88x2cu)'| cut -d = -f2)
            case "$card_type" in
            "rtl88xxau_wfb") min_phy_txpower=-1000; max_phy_txpower=-3000 ;;
            "rtl88x2eu"|"rtl88x2cu") min_phy_txpower=1000; max_phy_txpower=2900 ;;
            esac
            range=$((max_phy_txpower - min_phy_txpower))
            percentage=$5
            power_value=$(( min_phy_txpower + (percentage * range) / 100 ))
            [ ! -z "$wifi_txpower" ] && wifi_txpower=$wifi_txpower,
            wifi_txpower=$wifi_txpower" \"$nic\": $power_value"
        done
        if ! grep -A 20 "\[common\]" /etc/wifibroadcast.cfg | grep -q "^wifi_txpower = "; then
            sed -i "/^\[common\]/a\wifi_txpower = {$wifi_txpower}" /etc/wifibroadcast.cfg
        else
            sed -i "s/^wifi_txpower = .*/wifi_txpower = {$wifi_txpower}/" /etc/wifibroadcast.cfg
        fi
        /etc/init.d/S98wifibroadcast restart
        ;;
    "set gs wfbng adaptivelink"*)
        if [ "$5" = "on" ]; then
            sed -i 's/ADAPTIVE_LINK_ENABLED.*/ADAPTIVE_LINK_ENABLED=true/' /etc/default/adaptive-link
            /etc/init.d/S98adaptive-link start
        else
            /etc/init.d/S98adaptive-link stop
            sed -i 's/ADAPTIVE_LINK_ENABLED.*/ADAPTIVE_LINK_ENABLED=false/' /etc/default/adaptive-link
        fi
        ;;

# ── GS: Artosyn ──────────────────────────────────────────────────────────────
# ar8030-lifecycled's HTTP control API, GS unit's own copy -- always local
# (http://127.0.0.1:8899, ar8030-transport-rx's own S98ar8030-transport-rx
# runs it on this same box), so unlike the air-side "artosyn"/"waybeam" pages
# this one is NOT gated on drone detection: it's the ground radio's own local
# state, queryable/settable whether or not the air unit is currently linked.
# No channel here: the air unit owns it (see the Air: Artosyn page).

    "get gs artosyn status")
        lifecycled_status_summary gs
        ;;
    "get gs artosyn bandwidth")
        get_lifecycled_bandwidth gs
        emit_values "1\n2\n5\n10\n20\n40"
        ;;
    "get gs artosyn power")
        get_lifecycled_power gs
        emit_values_cmd list_lifecycled_power_levels gs
        ;;

    "set gs artosyn bandwidth"*)
        set_lifecycled_bandwidth gs "$5"
        ;;
    "set gs artosyn power"*)
        set_lifecycled_power gs "$5"
        ;;

# ── GS: System ──────────────────────────────────────────────────────────────

    "get gs system rx_codec")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_CODEC
        emit_values "h264\nh265\nauto"
        ;;
    "get gs system rx_mode")
        . /etc/default/wifibroadcast
        . /etc/default/pixelpilot
        if [ x$PIXELPILOT_RX_MODE = x"artosyn" ]; then
            echo "artosyn"
        elif [ x$WIFIBROADCAST_ENABLED = x"false" ]; then
            echo "apfpv"
        else
            echo "wfb"
        fi
        emit_values "wfb\napfpv\nartosyn"
        ;;
    "get gs system gs_rendering")
        . /etc/default/msposd
        [ x$MSPOSD_ENABLED = x"false" ] && echo 0 || echo 1
        ;;
    "get gs system connector")
        echo HDMI
        emit_values "HDMI"
        ;;
    "get gs system resolution")
        drm_info -j /dev/dri/card0 2>/dev/null | jq -r '."/dev/dri/card0".crtcs[0].mode| .name + "@" + (.vrefresh|tostring)'
        printf '\x1e'
        drm_info -j /dev/dri/card0 2>/dev/null | jq -r '."/dev/dri/card0".connectors[1].modes[] | select(.name | contains("i") | not) | .name + "@" + (.vrefresh|tostring)' | sort | uniq | head -c -1
        ;;
    "get gs system video_scale")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_VIDEO_SCALE
        emit_values "0.5 1.0"
        ;;
    "get gs system gs_live_colortrans")
        . /etc/default/pixelpilot
        [ x$PIXELPILOT_LIVE_COLORTRANS = x"" ] && echo 0 || echo 1
        ;;
    "get gs system dvr_mode")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_DVR_MODE
        emit_values "raw\nreencode\nboth"
        ;;
    "get gs system dvr_max_size")
        . /etc/default/pixelpilot
        echo $(( $PIXELPILOT_DVR_MAX_SIZE / 100 ))
        emit_values "1 40"
        ;;
    "get gs system dvr_reenc_codec")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_DVR_CODEC
        emit_values "h264\nh265"
        ;;
    "get gs system dvr_reenc_resolution")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_DVR_RESOLUTION
        emit_values "720p\n1080p"
        ;;
    "get gs system dvr_reenc_fps")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_DVR_FPS
        emit_values "30\n60"
        ;;
    "get gs system dvr_reenc_bitrate")
        . /etc/default/pixelpilot
        echo $PIXELPILOT_DVR_BITRATE
        emit_values "5000\n10000\n15000\n20000\n25000\n30000\n35000\n40000\n45000\n50000"
        ;;
    "get gs system rec_enabled"*)
        echo 0
        ;;
    "get gs system dvr_osd"*)
        . /etc/default/pixelpilot
        [ x$PIXELPILOT_DVR_OSD = x"" ] && echo 0 || echo 1
        ;;
    "get gs system audio_device"*)
        . /etc/default/pixelpilot
        cur="$PIXELPILOT_AUDIO_DEVICE"
        [ -z "$cur" ] && cur="default"
        echo "$cur"
        # Options: "default" + the card ids from /proc/asound/cards (e.g. rockchiphdmi, HEADSET)
        opts="default"
        for c in $(awk -F'[][]' '/^ *[0-9]+ \[/{gsub(/ /,"",$2); print $2}' /proc/asound/cards); do
            opts="$opts\n$c"
        done
        emit_values "$opts"
        ;;
    "get gs system audio_volume"*)
        . /etc/default/pixelpilot
        v="$PIXELPILOT_AUDIO_VOLUME"
        [ -z "$v" ] && v=100
        echo "$v"
        emit_values "0 100"
        ;;
    "get gs system audio"*)
        . /etc/default/pixelpilot
        [ x$PIXELPILOT_AUDIO = x"" ] && echo 0 || echo 1
        ;;
    "set gs system rx_codec"*)
        sed -i "s/^PIXELPILOT_CODEC=.*/PIXELPILOT_CODEC=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system rx_mode"*)
        EXCLUDE_IFACE="wlan0"
        SSID="${6:-OpenIPC}"
        PASSWORD="${7:-12345678}"
        sed -i "s/^PIXELPILOT_RX_MODE=.*/PIXELPILOT_RX_MODE=\"$5\"/" /etc/default/pixelpilot
        if [ "$5" = "apfpv" ]; then
            # Leaving artosyn (if it was active): tear the ar8030 RF link back down.
            [ -f /etc/default/ar8030 ] && sed -i 's/AR8030_ENABLED.*/AR8030_ENABLED=false/' /etc/default/ar8030
            [ -x /etc/init.d/S97ar8030 ] && /etc/init.d/S97ar8030 stop
            ifdown ar_net0 2>/dev/null
            /etc/init.d/S98adaptive-link stop
            /etc/init.d/S98wifibroadcast stop
            sed -i 's/WIFIBROADCAST_ENABLED.*/WIFIBROADCAST_ENABLED=false/' /etc/default/wifibroadcast
            sed -i 's/ADAPTIVE_LINK_ENABLED.*/ADAPTIVE_LINK_ENABLED=false/' /etc/default/adaptive-link
            rmmod 8812eu
            rmmod 88XXau_wfb
            modprobe 8812eu
            modprobe 88XXau_wfb
            cat <<EOF > /etc/wpa_supplicant.apfpv.conf
network={
    ssid="$SSID"
    psk="$PASSWORD"
}

EOF
            WIFI_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wlx' | grep -v "^$EXCLUDE_IFACE$")
            INDEX=0
            for IFACE in $WIFI_IFACES; do
cat <<EOF > /etc/network/interfaces.d/$IFACE
$( [ $INDEX -eq 0 ] && echo "auto $IFACE" || echo "#auto $IFACE")
iface $IFACE inet dhcp
  wpa-conf /etc/wpa_supplicant.apfpv.conf
  udhcpc_opts -s /etc/udhcpc/udhcpc.apfpv.script

EOF
            [ $INDEX -eq 0 ] && ifup $IFACE
            INDEX=$((INDEX + 1))
            done
        elif [ "$5" = "wfb" ]; then
            # Leaving artosyn (if it was active): tear the ar8030 RF link back down.
            [ -f /etc/default/ar8030 ] && sed -i 's/AR8030_ENABLED.*/AR8030_ENABLED=false/' /etc/default/ar8030
            [ -x /etc/init.d/S97ar8030 ] && /etc/init.d/S97ar8030 stop
            ifdown ar_net0 2>/dev/null
            WIFI_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlx' | grep -v "^$EXCLUDE_IFACE$")
            INDEX=0
            for IFACE in $WIFI_IFACES; do
                ifdown $IFACE
                rm /etc/network/interfaces.d/$IFACE
            done
            rmmod 8812eu
            rmmod 88XXau_wfb
            modprobe 8812eu
            modprobe 88XXau_wfb
            sed -i 's/WIFIBROADCAST_ENABLED.*/WIFIBROADCAST_ENABLED=true/' /etc/default/wifibroadcast
            sed -i 's/ADAPTIVE_LINK_ENABLED.*/ADAPTIVE_LINK_ENABLED=true/' /etc/default/adaptive-link
            /etc/init.d/S98adaptive-link start
            /etc/init.d/S98wifibroadcast start
        elif [ "$5" = "artosyn" ]; then
            # wfb-ng/adaptive-link off, same as the apfpv branch above.
            /etc/init.d/S98adaptive-link stop
            /etc/init.d/S98wifibroadcast stop
            sed -i 's/WIFIBROADCAST_ENABLED.*/WIFIBROADCAST_ENABLED=false/' /etc/default/wifibroadcast
            sed -i 's/ADAPTIVE_LINK_ENABLED.*/ADAPTIVE_LINK_ENABLED=false/' /etc/default/adaptive-link
            # Tear down any apfpv wlx interfaces, same as the wfb branch above.
            WIFI_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlx' | grep -v "^$EXCLUDE_IFACE$")
            for IFACE in $WIFI_IFACES; do
                ifdown $IFACE
                rm -f /etc/network/interfaces.d/$IFACE
            done
            # Bring the ar8030 RF link up: AR8030_ENABLED gates S97ar8030's
            # GPIO/firmware-push sequence (see files/etc/init.d/S97ar8030), and
            # ar_net0 is the TUN bridge to the air unit's REST API (192.168.100.1,
            # see files/etc/network/interfaces.d/ar_net0 / the matching air-side
            # overlay in OpenIPC/builder).
            [ -f /etc/default/ar8030 ] && sed -i 's/AR8030_ENABLED.*/AR8030_ENABLED=true/' /etc/default/ar8030
            [ -x /etc/init.d/S97ar8030 ] && /etc/init.d/S97ar8030 restart
            ifup ar_net0 2>/dev/null
        fi
        ;;
    "set gs system gs_rendering"*)
        if [ "$5" = "off" ]; then
            /etc/init.d/S98msposd stop
            sed -i 's/MSPOSD_ENABLED.*/MSPOSD_ENABLED=false/' /etc/default/msposd
        else
            sed -i 's/MSPOSD_ENABLED.*/MSPOSD_ENABLED=true/' /etc/default/msposd
            /etc/init.d/S98msposd start
        fi
        ;;
    "set gs system connector"*)             : ;;
    "set gs system resolution"*)
        sed -i "s/^PIXELPILOT_SCREEN_MODE=.*/PIXELPILOT_SCREEN_MODE=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system video_scale"*)
        sed -i "s/^PIXELPILOT_VIDEO_SCALE=.*/PIXELPILOT_VIDEO_SCALE=$5/" /etc/default/pixelpilot
        ;;
    "set gs system gs_live_colortrans"*)
        if [ "$5" = "on" ]
        then
            sed -i "s/^PIXELPILOT_LIVE_COLORTRANS=.*/PIXELPILOT_LIVE_COLORTRANS=\"--live-colortrans\"/" /etc/default/pixelpilot
        else
            sed -i "s/^PIXELPILOT_LIVE_COLORTRANS=.*/PIXELPILOT_LIVE_COLORTRANS=\"\"/" /etc/default/pixelpilot
        fi
        ;;
    "set gs system rec_enabled"*)
        if [ "$5" = "off" ]; then
            : #noop
        else
            : #noop
        fi
        ;;
    "set gs system dvr_mode"*)
        sed -i "s/^PIXELPILOT_DVR_MODE=.*/PIXELPILOT_DVR_MODE=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_max_size"*)
        sed -i "s/^PIXELPILOT_DVR_MAX_SIZE=.*/PIXELPILOT_DVR_MAX_SIZE=\"$(( $5 * 100 ))\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_reenc_resolution"*)
        sed -i "s/^PIXELPILOT_DVR_RESOLUTION=.*/PIXELPILOT_DVR_RESOLUTION=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_reenc_codec"*)
        sed -i "s/^PIXELPILOT_DVR_CODEC=.*/PIXELPILOT_DVR_CODEC=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_reenc_fps"*)
        sed -i "s/^PIXELPILOT_DVR_FPS=.*/PIXELPILOT_DVR_FPS=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_reenc_bitrate"*)
        sed -i "s/^PIXELPILOT_DVR_BITRATE=.*/PIXELPILOT_DVR_BITRATE=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system dvr_osd"*)
        if [ "$5" = "on" ]; then
            sed -i "s/^PIXELPILOT_DVR_OSD=.*/PIXELPILOT_DVR_OSD=\"--dvr-osd\"/" /etc/default/pixelpilot
        else
            sed -i "s/^PIXELPILOT_DVR_OSD=.*/PIXELPILOT_DVR_OSD=\"\"/" /etc/default/pixelpilot
        fi
        ;;
    "set gs system audio_device"*)
        val="$5"
        [ "$val" = "default" ] && val=""
        sed -i "s|^PIXELPILOT_AUDIO_DEVICE=.*|PIXELPILOT_AUDIO_DEVICE=\"$val\"|" /etc/default/pixelpilot
        ;;
    "set gs system audio_volume"*)
        sed -i "s/^PIXELPILOT_AUDIO_VOLUME=.*/PIXELPILOT_AUDIO_VOLUME=\"$5\"/" /etc/default/pixelpilot
        ;;
    "set gs system audio"*)
        if [ "$5" = "on" ]; then
            sed -i "s/^PIXELPILOT_AUDIO=.*/PIXELPILOT_AUDIO=\"--audio\"/" /etc/default/pixelpilot
        else
            sed -i "s/^PIXELPILOT_AUDIO=.*/PIXELPILOT_AUDIO=\"\"/" /etc/default/pixelpilot
        fi
        ;;

# ── GS: APFPV ───────────────────────────────────────────────────────────────

    "get gs apfpv ssid")
        grep ssid /etc/wpa_supplicant.apfpv.conf  | cut -d \" -f 2
        ;;
    "get gs apfpv password")
        grep psk /etc/wpa_supplicant.apfpv.conf  | cut -d \" -f 2
        ;;
    "get gs apfpv wlx"*)
        grep -q "^auto $4" /etc/network/interfaces.d/$4 && echo 1 || echo 0
        ;;
    "get gs apfpv status wlx"*)
        iw dev $5 link | grep -q "Not connected." && echo Disconnected || echo Connected
        ;;

    "set gs apfpv ssid"*)
        if [ "$GSMENU_VTX_DETECTED" -eq "1" ]; then
            $SSH 'fw_setenv wlanssid "'$5'"'
            $SSH '(hostapd_cli -i wlan0 set ssid "'$5'"; hostapd_cli -i wlan0 reload)  >/dev/null 2>&1 &'
        fi
        sed -i "s/ssid=.*/ssid=\""$5"\"/" /etc/wpa_supplicant.apfpv.conf
        WIFI_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wlx')
        INDEX=0
        for IFACE in $WIFI_IFACES; do
            if [ $($0 get gs apfpv $IFACE) = 1 ]; then
                ifdown $IFACE
                sleep 1
                ifup $IFACE
            fi
            INDEX=$((INDEX + 1))
        done
        ;;
    "set gs apfpv password"*)
        if [ "$GSMENU_VTX_DETECTED" -eq "1" ]; then
            $SSH 'fw_setenv wlanpass "'$5'"'
            $SSH '(hostapd_cli -i wlan0 set wpa_passphrase "'$5'"; hostapd_cli -i wlan0 reload)  >/dev/null 2>&1 &'
        fi
        sed -i "s/psk=.*/psk=\""$5"\"/" /etc/wpa_supplicant.apfpv.conf
        WIFI_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wlx')
        INDEX=0
        for IFACE in $WIFI_IFACES; do
            if [ $($0 get gs apfpv $IFACE) = 1 ]; then
                ifdown $IFACE
                sleep 1
                ifup $IFACE
            fi
            INDEX=$((INDEX + 1))
        done
        ;;
    "set gs apfpv wlx"*)
        if [ $5 = "on" ]; then
            sed -i "s/^#auto/auto/" /etc/network/interfaces.d/$4
            ifup $4
        else
            sed -i "s/^auto/#auto/" /etc/network/interfaces.d/$4
            ifdown $4
            DRV_PATH=$(readlink -f /sys/class/net/$4/device/driver 2>/dev/null || true)
            DEV_PATH=$(readlink -f /sys/class/net/$4/device 2>/dev/null || true)
            DRV_NAME=$(basename "$DRV_PATH")
            DEV_NAME=$(basename "$DEV_PATH")
            echo -n "$DEV_NAME" > /sys/bus/usb/drivers/$DRV_NAME/unbind >/dev/null
            sleep 1
            echo -n "$DEV_NAME" > /sys/bus/usb/drivers/$DRV_NAME/bind >/dev/null
            sleep 1
        fi
        ;;
    "set gs apfpv reset")
        for CONN in /etc/network/interfaces.d/wlx*; do
            ifdown $(basename $CONN)
            rm $CONN
        done
        ;;

# ── GS: WiFi ────────────────────────────────────────────────────────────────

    "get gs wifi hotspot")
        if [ -f /etc/wpa_supplicant.hotspot.conf ] && ip addr show wlan0 2>/dev/null | grep -q "inet "; then
            echo 1
        else
            echo 0
        fi
        ;;
    "get gs wifi wlan")
        [ ! -d /sys/class/net/wlan0 ] && { echo 0; exit 0; }
        # Hotspot uses wlan0 in AP mode — not a managed client connection
        [ -f /etc/wpa_supplicant.hotspot.conf ] && { echo 0; exit 0; }
        iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && echo 1 || echo 0
        ;;
    "get gs wifi ssid")
        [ ! -d /sys/class/net/wlan0 ] && { echo -n ""; exit 0; }
        [ -f /etc/wpa_supplicant.hotspot.conf ] && { echo -n ""; exit 0; }
        iw dev wlan0 link 2>/dev/null | awk '/SSID:/ { sub(/.*SSID: /, ""); print; exit }'
        ;;
    "get gs wifi password")
        if [ -f /etc/wpa_supplicant.conf ]; then
            grep psk /etc/wpa_supplicant.conf | cut -d = -f 2 | cut -d \" -f 2
        else
            echo -n ""
        fi
        ;;
    "get gs wifi IP")
        ip -4 addr show | grep "inet " | awk '{print $2}'
        ;;
    "get gs wifi savednetworks")
        # Read saved networks from wpa_supplicant.conf (multi-stanza, one per known network)
        if [ -f /etc/wpa_supplicant.conf ]; then
            awk -F'"' '
                /ssid=/  { ssid=$2 }
                /psk=/   { psk=$2  }
                /}/      {
                    if (ssid != "" && psk != "") {
                        s = ssid; gsub(/:/, "\\:", s)
                        print s ":" psk
                    }
                    ssid=""; psk=""
                }
            ' /etc/wpa_supplicant.conf
        fi
        ;;
    "get gs wifi networks")
        [ ! -d /sys/class/net/wlan0 ] && exit 0
        ip link set wlan0 up 2>/dev/null || true
        # Trigger a fresh scan via iw and parse the BSS list
        iw dev wlan0 scan 2>/dev/null | awk '
            BEGIN { ssid=""; sec="--"; sig_pct=0 }
            /^BSS / {
                if (ssid != "") {
                    s = ssid; gsub(/:/, "\\:", s)
                    printf "%s:%s:%d\n", s, sec, sig_pct
                }
                ssid=""; sec="--"; sig_pct=0
            }
            /SSID: / {
                idx = index($0, "SSID: ")
                if (idx > 0) ssid = substr($0, idx + 6)
            }
            /signal: / {
                sig = $2 + 0
                sig_pct = int(2 * (sig + 100))
                if (sig_pct < 0) sig_pct = 0
                if (sig_pct > 100) sig_pct = 100
            }
            /RSN:/ || /WPA:/ { sec = "WPA" }
            END {
                if (ssid != "") {
                    s = ssid; gsub(/:/, "\\:", s)
                    printf "%s:%s:%d\n", s, sec, sig_pct
                }
            }
        ' || true
        ;;
    "set gs wifi connect"*)
        [ ! -d /sys/class/net/wlan0 ] && exit 0
        SSID="$5"
        PASSWORD="$6"
        # Save/update this network in the persistent multi-network conf
        wpa_conf_update_network "$SSID" "$PASSWORD"
        # Tear down hotspot if active
        if [ -f /etc/wpa_supplicant.hotspot.conf ]; then
            ifdown wlan0 2>/dev/null || true
            rm -f /etc/wpa_supplicant.hotspot.conf
        fi
        # Write a single-network conf so wpa_supplicant only connects to the target
        if [ -z "$PASSWORD" ]; then
            printf 'network={\n    ssid="%s"\n    key_mgmt=NONE\n}\n' "$SSID" > /etc/wpa_supplicant.conf.single
        else
            printf 'network={\n    ssid="%s"\n    psk="%s"\n}\n' "$SSID" "$PASSWORD" > /etc/wpa_supplicant.conf.single
        fi
        # Swap in single-network conf, reconnect, then restore full conf
        # (wpa_supplicant reads conf at startup only; stays on target after restore)
        cp /etc/wpa_supplicant.conf /etc/wpa_supplicant.conf.bak 2>/dev/null || true
        cp /etc/wpa_supplicant.conf.single /etc/wpa_supplicant.conf
        printf 'auto wlan0\niface wlan0 inet dhcp\n    wpa-conf /etc/wpa_supplicant.conf\n' > /etc/network/interfaces.d/wlan0
        ifdown wlan0 2>/dev/null || true
        ifup wlan0
        # Restore full multi-network conf on disk (wpa_supplicant keeps in-memory config)
        [ -f /etc/wpa_supplicant.conf.bak ] && mv /etc/wpa_supplicant.conf.bak /etc/wpa_supplicant.conf
        rm -f /etc/wpa_supplicant.conf.single
        ;;
    "set gs wifi disconnect"*)
        [ ! -d /sys/class/net/wlan0 ] && exit 0
        ifdown wlan0 2>/dev/null || true
        # Remove interfaces entry to disable auto-reconnect at boot
        rm -f /etc/network/interfaces.d/wlan0
        ;;
    "set gs wifi forget"*)
        # Forget/remove the saved network ($5 = SSID). If it's the network we're
        # currently on, tear the connection down first (as with disconnect).
        [ -z "$5" ] && exit 0
        if [ -d /sys/class/net/wlan0 ]; then
            current=$(iw dev wlan0 link 2>/dev/null | awk '/SSID:/ { sub(/.*SSID: /, ""); print; exit }')
            if [ "$current" = "$5" ]; then
                ifdown wlan0 2>/dev/null || true
                rm -f /etc/network/interfaces.d/wlan0
            fi
        fi
        wpa_conf_remove_network "$5"
        ;;
    "set gs wifi wlan"*)
        [ ! -d /sys/class/net/wlan0 ] && exit 0
        if [ "$5" = "on" ]; then
            # Tear down hotspot if active
            if [ -f /etc/wpa_supplicant.hotspot.conf ]; then
                ifdown wlan0 2>/dev/null || true
                rm -f /etc/wpa_supplicant.hotspot.conf
            fi
            wpa_conf_update_network "$6" "$7"
            printf 'auto wlan0\niface wlan0 inet dhcp\n    wpa-conf /etc/wpa_supplicant.conf\n' > /etc/network/interfaces.d/wlan0
            ifdown wlan0 2>/dev/null || true
            ifup wlan0
        else
            ifdown wlan0 2>/dev/null || true
            rm -f /etc/network/interfaces.d/wlan0
        fi
        ;;
    "set gs wifi hotspot"*)
        [ ! -d /sys/class/net/wlan0 ] && exit 0
        if [ "$5" = "on" ]; then
            [ -f /etc/wpa_supplicant.hotspot.conf ] && ip addr show wlan0 2>/dev/null | grep -q "inet " && exit 0  # already on, nothing to do
            ifdown wlan0 2>/dev/null || true
            rm -f /etc/network/interfaces.d/wlan0
            cat <<EOF > /etc/wpa_supplicant.hotspot.conf
network={
    mode=2
    frequency=2412
    ssid="OpenIPC GS"
    psk="12345678"
}
EOF
            cat <<EOF > /etc/network/interfaces.d/wlan0
iface wlan0 inet static
    address 192.168.4.1
    netmask 255.255.255.0
    post-up udhcpd -S
    pre-down killall -q udhcpd
    wpa-conf /etc/wpa_supplicant.hotspot.conf
EOF
            ifup wlan0
        else
            [ ! -f /etc/wpa_supplicant.hotspot.conf ] && exit 0  # already off, nothing to do
            ifdown wlan0 2>/dev/null || true
            rm -f /etc/network/interfaces.d/wlan0
            rm -f /etc/wpa_supplicant.hotspot.conf
        fi
        ;;

# ── GS: Main page (info labels) ─────────────────────────────────────────────

    "get gs main Channel")
        gsmenu.sh get gs wfbng gs_channel | head -1
        ;;
    "get gs main HDMI-OUT")
        gsmenu.sh get gs system resolution | head -1
        ;;
    "get gs main Version")
        . /etc/os-release
        echo $PRETTY_NAME $VERSION
        ;;
    "get gs main Disk")
        df -h /media/dvr | awk 'NR==2 {print $2, $4, $5}' | while read -r size avail pcent
        do
            echo -e "\n   Size: $size\n   Available: $avail\n   Pct: $pcent\c"
            exit 0
        done
        ;;
    "get gs main WFB_NICS")
        . /etc/default/wifibroadcast
        echo $WFB_NICS
        ;;

# ── Buttons / Actions ───────────────────────────────────────────────────────

    "button air actions Reboot")
        $SSH 'reboot &'
        ;;
    "button gs actions Reboot")
        reboot
        ;;
    "search channel")
        echo "Not implmented"
        echo "Not implmented" >&2
        exit 1
        ;;

# ── Unknown command ──────────────────────────────────────────────────────────

    *)
        echo "Unknown $@"
        exit 1
        ;;
esac
rc=$?

case "$1" in
    set|button) sync ;;
esac

case $rc in
    0) ;;
    1) exit 0 ;;
    *) exit $rc ;;
esac
