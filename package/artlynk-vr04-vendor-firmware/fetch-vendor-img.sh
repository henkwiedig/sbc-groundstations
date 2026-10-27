#!/bin/bash
#
# Fetch a stock image extract.py needs from Google Drive into the vendor
# image cache, when the cache lacks it (CI, a fresh checkout):
#
#   fetch-vendor-img.sh FILE_ID OUT [ZIP_MEMBER]
#
# BetaFPV publishes its P1 GND releases as plain .img files; CADDX publishes
# the Ascent images only as one zip of all of them, ZIP_MEMBER names the one
# to keep (e.g. Ascent_L_Gnd_18_21_10.img). Small files download directly
# with confirm=t; for large ones Google serves its "can't scan this file for
# viruses" page instead, and this hands its hidden uuid back the way
# package/ascent-vendor-firmware/fetch-vendor-img.sh does. If Google changes
# that page, download the file by hand from
# https://drive.google.com/file/d/FILE_ID/view and put the image into the
# cache under OUT's name.

set -euo pipefail

usage="usage: fetch-vendor-img.sh FILE_ID OUT [ZIP_MEMBER]"
FILE_ID="${1:?$usage}"
OUT="${2:?$usage}"
MEMBER="${3:-}"
URL="https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t"

if [ -s "$OUT" ]; then
	echo "Using cached vendor image: $OUT"
	exit 0
fi

fail() {
	echo "fetch-vendor-img.sh: $1" >&2
	echo "Download https://drive.google.com/file/d/${FILE_ID}/view by hand${MEMBER:+, take $MEMBER out of the zip,}" >&2
	echo "and put it at $OUT" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DL="$WORK/download"

is_page() {
	head -c 512 "$1" | grep -qai '<html'
}

curl -sL --cookie-jar "$WORK/cookies" "$URL" -o "$DL" || fail "download failed"
if is_page "$DL"; then
	UUID=$(grep -ao 'name="uuid" value="[^"]*"' "$DL" | sed -E 's/.*value="([^"]*)"/\1/' || true)
	[ -n "$UUID" ] || fail "neither the file nor a download confirmation token came back"
	curl -sL --cookie "$WORK/cookies" "$URL&uuid=${UUID}" -o "$DL" || fail "download failed"
	! is_page "$DL" || fail "Google Drive answered with a page again"
fi

if [ -n "$MEMBER" ]; then
	# List first, then pick: unzip piped straight into a grep that exits early
	# can die of SIGPIPE, which pipefail turns into a failure.
	LISTING=$(unzip -Z1 "$DL") || fail "the download is not a zip"
	ENTRY=$(awk -v m="$MEMBER" '$0 == m || substr($0, length($0) - length(m)) == "/" m' <<<"$LISTING" | head -1)
	[ -n "$ENTRY" ] || fail "no $MEMBER in the zip"
	unzip -p "$DL" "$ENTRY" > "$WORK/image"
else
	mv "$DL" "$WORK/image"
fi
[ -s "$WORK/image" ] || fail "empty image"

mkdir -p "$(dirname "$OUT")"
mv "$WORK/image" "$OUT"
echo "Downloaded vendor image to: $OUT"
