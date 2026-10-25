#!/bin/sh

# Drives a goggle's PWM buzzer via the sysfs PWM interface.
#
# Which PWM and which tone come from /etc/default/beeper (the board's):
#   BEEPER_PWMCHIP    the PWM controller, e.g. /sys/class/pwm/pwmchip4
#   BEEPER_CHANNEL    its channel (default 0)
#   BEEPER_PERIOD_NS  the tone's period (default 250000 ns, ~4 kHz)
# Without that file there is no buzzer and this does nothing.
#
# Caddx VRX Pro ("vrx pro2"): pwmchip4/pwm0 (fe700010.pwm), mirroring the
# vendor's own ar8030soc/pwm_ctl.sh + ar_fpv_upgrade beep_pwm_ctrl() logic
# (250000ns period / 50% duty = ~4kHz tone), confirmed against the live
# sysfs nodes on hardware. BetaFPV VR04: pwmchip1/pwm0 (pwm@1002000),
# 260000ns as the vendor's device tree has it.
#
# Usage: beep.sh [duration_ms] [duty_percent]
#   duration_ms  - how long to sound the buzzer, in milliseconds (default: 100)
#   duty_percent - PWM duty cycle, 1-99 (default: 50, louder ~= higher)

[ -r /etc/default/beeper ] && . /etc/default/beeper
[ -n "${BEEPER_PWMCHIP}" ] || exit 0

PWMCHIP="${BEEPER_PWMCHIP}"
CHANNEL="${BEEPER_CHANNEL:-0}"
PWM="${PWMCHIP}/pwm${CHANNEL}"
PERIOD_NS="${BEEPER_PERIOD_NS:-250000}"

DURATION_MS="${1:-100}"
DUTY_PERCENT="${2:-50}"

if [ ! -e "${PWM}" ]; then
	echo "${CHANNEL}" > "${PWMCHIP}/export"
	# give the kernel a moment to create the pwm0 sysfs node
	for i in 1 2 3 4 5; do
		[ -e "${PWM}" ] && break
		sleep 0.05
	done
fi

if [ ! -e "${PWM}" ]; then
	echo "beep.sh: ${PWM} not available" >&2
	exit 1
fi

duty_ns=$(( PERIOD_NS * DUTY_PERCENT / 100 ))

echo "${PERIOD_NS}" > "${PWM}/period"
echo "${duty_ns}" > "${PWM}/duty_cycle"
echo normal > "${PWM}/polarity"

echo 1 > "${PWM}/enable"
sleep_s=$(awk "BEGIN { printf \"%.3f\", ${DURATION_MS}/1000 }")
sleep "${sleep_s}"
echo 0 > "${PWM}/enable"
