#!/bin/sh

# Plays RTTTL (RingTone Text Transfer Language) melodies on the Caddx VRX
# Pro buzzer (pwmchip4/pwm0).
#
# RTTTL is the classic Nokia composer ringtone format:
#   Name:d=<default duration>,o=<default octave>,b=<bpm>:<notes,separated,by,commas>
# e.g. "Twinkle:d=4,o=4,b=150:c,c,g,g,a,a,2g,f,f,e,e,d,d,2c"
# Each note is [duration]note[#][.][octave][.], where duration is a divisor
# of a whole note (1=whole,2=half,4=quarter,8=eighth,16=sixteenth,...), '#'
# is sharp, '.' is dotted (1.5x length), and 'p' is a rest. Anything omitted
# falls back to the song's default duration/octave.
#
# This is the de-facto standard text format for simple single-tone buzzer
# melodies -- there are large public archives of ready-made RTTTL songs
# (search "rtttl ringtones") that can be dropped straight into a file and
# played here, no conversion needed.
#
# Usage: playsong.sh <file.rtttl|->
#   The file may contain one song per line (played back to back); blank
#   lines and lines starting with '#' are ignored. Use '-' or omit the
#   argument to read from stdin.

PWMCHIP="/sys/class/pwm/pwmchip4"
PWM="${PWMCHIP}/pwm0"
GAP_PERCENT=10   # fraction of each note's duration left silent, for articulation

FILE="${1:--}"

if [ ! -e "${PWM}" ]; then
	echo 0 > "${PWMCHIP}/export"
	for i in 1 2 3 4 5; do
		[ -e "${PWM}" ] && break
		sleep 0.05
	done
fi
if [ ! -e "${PWM}" ]; then
	echo "playsong.sh: ${PWM} not available" >&2
	exit 1
fi

echo 0 > "${PWM}/enable" 2>/dev/null
echo 0 > "${PWM}/duty_cycle" 2>/dev/null

cleanup() {
	echo 0 > "${PWM}/duty_cycle" 2>/dev/null
	echo 0 > "${PWM}/enable" 2>/dev/null
}
trap cleanup INT TERM EXIT

# musl/uclibc usleep() is unhappy with very large microsecond counts, so
# split anything over a second into whole-second sleeps plus a remainder.
sleep_ms() {
	ms=$1
	if [ "${ms}" -ge 1000 ]; then
		sleep $(( ms / 1000 ))
		ms=$(( ms % 1000 ))
	fi
	[ "${ms}" -gt 0 ] && usleep $(( ms * 1000 ))
}

play_note() {
	freq=$1
	dur_ms=$2
	if [ "${freq}" -le 0 ]; then
		echo 0 > "${PWM}/duty_cycle"
	else
		period=$((1000000000 / freq))
		duty=$((period / 2))
		# duty_cycle must never exceed the current period, so clear it
		# before switching to a new (possibly shorter) period.
		echo 0 > "${PWM}/enable"  2>/dev/null
		echo 0 > "${PWM}/duty_cycle" 2>/dev/null
		echo "${period}" > "${PWM}/period"
		echo "${duty}" > "${PWM}/duty_cycle"
		echo 1 > "${PWM}/enable"
	fi
	on_ms=$(( dur_ms * (100 - GAP_PERCENT) / 100 ))
	off_ms=$(( dur_ms - on_ms ))
	[ "${on_ms}" -gt 0 ] && sleep_ms "${on_ms}"
	echo 0 > "${PWM}/duty_cycle"
	[ "${off_ms}" -gt 0 ] && sleep_ms "${off_ms}"
}

awk '
BEGIN {
	# 2^(k/12) for k=0..11 (equal-temperament semitone ratios), precomputed
	# since this busybox awk has no libm (no pow()/"^" support).
	ratio[0]=1.000000; ratio[1]=1.059463; ratio[2]=1.122462; ratio[3]=1.189207
	ratio[4]=1.259921; ratio[5]=1.334840; ratio[6]=1.414214; ratio[7]=1.498307
	ratio[8]=1.587401; ratio[9]=1.681793; ratio[10]=1.781797; ratio[11]=1.887749
}
function pow2i(e,    r, i) {
	r = 1
	if (e >= 0) { for (i = 0; i < e; i++) r = r * 2 }
	else { for (i = 0; i < -e; i++) r = r / 2 }
	return r
}
function freq(note, sharp, octave,    semitone, n, k, octshift) {
	if (note == "p") return 0
	if (note == "c") semitone = 0
	else if (note == "d") semitone = 2
	else if (note == "e") semitone = 4
	else if (note == "f") semitone = 5
	else if (note == "g") semitone = 7
	else if (note == "a") semitone = 9
	else if (note == "b") semitone = 11
	else return -1
	if (sharp) semitone++
	n = (octave - 4) * 12 + (semitone - 9)
	k = n % 12
	if (k < 0) k += 12
	octshift = (n - k) / 12
	return int(440 * ratio[k] * pow2i(octshift) + 0.5)
}
{
	line = $0
	gsub(/[ \t\r]/, "", line)
	if (line == "" || substr(line, 1, 1) == "#") next
	fn = split(line, parts, ":")
	if (fn < 3) next
	name = parts[1]
	defs = parts[2]
	song = parts[3]
	dur = 4; oct = 6; bpm = 63
	dn = split(defs, dparts, ",")
	for (i = 1; i <= dn; i++) {
		kv = dparts[i]
		if (substr(kv, 1, 2) == "d=") dur = substr(kv, 3) + 0
		else if (substr(kv, 1, 2) == "o=") oct = substr(kv, 3) + 0
		else if (substr(kv, 1, 2) == "b=") bpm = substr(kv, 3) + 0
	}
	whole = 60000.0 / bpm * 4
	print "T " name
	m = split(song, ntoks, ",")
	for (i = 1; i <= m; i++) {
		tok = ntoks[i]
		if (tok == "") continue
		p = 1; L = length(tok)
		dstr = ""
		while (p <= L && substr(tok, p, 1) ~ /[0-9]/) { dstr = dstr substr(tok, p, 1); p++ }
		noted = (dstr == "") ? dur : dstr + 0
		nl = tolower(substr(tok, p, 1)); p++
		sharp = 0
		if (p <= L && substr(tok, p, 1) == "#") { sharp = 1; p++ }
		dotted = 0
		if (p <= L && substr(tok, p, 1) == ".") { dotted = 1; p++ }
		ostr = ""
		while (p <= L && substr(tok, p, 1) ~ /[0-9]/) { ostr = ostr substr(tok, p, 1); p++ }
		noteoct = (ostr == "") ? oct : ostr + 0
		if (p <= L && substr(tok, p, 1) == ".") dotted = 1
		f = freq(nl, sharp, noteoct)
		if (f < 0) continue
		d = whole / noted
		if (dotted) d = d * 1.5
		printf "N %d %d\n", f, d
	}
}
' "${FILE}" | while read -r tag rest; do
	case "${tag}" in
		T) echo "Now playing: ${rest}" ;;
		N) set -- ${rest}; play_note "$1" "$2" ;;
	esac
done
