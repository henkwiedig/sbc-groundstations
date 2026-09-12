#!/bin/bash
#
# Fetch the stock CADDX "Ascent V<ver>" OTA zip and cache just the
# Ascent_VRX_Pro_*.img (ground station ("VRX Pro") ) member locally, so
# extract.py has something to unpack CX486-RF-2PA's baseband demo firmware
# out of. Adapted from OpenIPC/builder's own package/ascent-vendor-firmware/
# fetch-vendor-img.sh (same vendor zip, different member) -- see that
# script for the full story of why this walks Google Drive's virus-scan
# interstitial by hand.
#
# The vendor only publishes this as a zip bundling all four Ascent
# variants' .img files plus CADDX_PCTool itself (Ascent_H_Sky_*.img,
# Ascent_L_Gnd_*.img, Ascent_G_Gnd_*.img, Ascent_VRX_Pro_*.img,
# CADDX_PCTool_*_win_Setup.exe) -- this downloads the whole zip and
# extracts just the VRX Pro (ground station) image we need, then discards
# the rest.

set -euo pipefail

# Overridable via the environment -- the sibling .mk owns the canonical
# value (ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID) and passes it through
# extract.py; this default is only for standalone/manual use.
FILE_ID="${FILE_ID:-1_IXl5OaJPVny78kg80CSn3FpWzYXQg3U}"
DRIVE_URL="https://drive.google.com/file/d/${FILE_ID}/view"

OUT="${1:?usage: fetch-vendor-img.sh <output-path>}"

if [ -s "$OUT" ]; then
    echo "Using cached vendor image: $OUT"
    exit 0
fi

fail() {
    echo "$1" >&2
    echo "Google Drive's download page probably changed -- download the zip by hand from:" >&2
    echo "  $DRIVE_URL" >&2
    echo "extract the Ascent_VRX_Pro_*.img inside, and place it at:" >&2
    echo "  $OUT" >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
COOKIES="$WORK/cookies.txt"
INTERSTITIAL="$WORK/interstitial.html"
ZIP="$WORK/vendor.zip"

curl -sL --cookie-jar "$COOKIES" \
    "https://drive.google.com/uc?export=download&id=${FILE_ID}" \
    -o "$INTERSTITIAL"

UUID=$(grep -o 'name="uuid" value="[^"]*"' "$INTERSTITIAL" | sed -E 's/.*value="([^"]*)"/\1/')
[ -n "$UUID" ] || fail "Could not find the download confirmation token."

curl -sL --cookie "$COOKIES" \
    "https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t&uuid=${UUID}" \
    -o "$ZIP"

unzip -l "$ZIP" >/dev/null 2>&1 || fail "Downloaded file isn't a valid zip."

IMG_ENTRY=$(unzip -Z1 "$ZIP" | grep -m1 '/Ascent_VRX_Pro_.*\.img$') \
    || fail "No Ascent_VRX_Pro_*.img found inside the downloaded zip."

mkdir -p "$WORK/extracted" "$(dirname "$OUT")"
unzip -j -o "$ZIP" "$IMG_ENTRY" -d "$WORK/extracted"

EXTRACTED="$WORK/extracted/$(basename "$IMG_ENTRY")"
MAGIC=$(head -c4 "$EXTRACTED" | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "524b4657" ] || fail "Extracted file has bad magic (${MAGIC:-empty}), not an RKFW image."

mv "$EXTRACTED" "$OUT"
echo "Downloaded vendor image to: $OUT"
