#!/bin/sh

# Drives the Caddx VRX Pro buzzer via the sysfs PWM interface.
#
# The buzzer sits on pwmchip4/pwm0 (fe700010.pwm) on the "vrx pro2"
# hardware variant. This mirrors the vendor's own
# ar8030soc/pwm_ctl.sh + ar_fpv_upgrade beep_pwm_ctrl() logic
# (250000ns period / 50% duty = ~4kHz tone), confirmed against the
# live sysfs nodes on hardware.
#
# Usage: beep.sh [duration_ms] [duty_percent]
#   duration_ms  - how long to sound the buzzer, in milliseconds (default: 100)
#   duty_percent - PWM duty cycle, 1-99 (default: 50, louder ~= higher)

PWMCHIP="/sys/class/pwm/pwmchip4"
PWM="${PWMCHIP}/pwm0"
PERIOD_NS=250000

DURATION_MS="${1:-100}"
DUTY_PERCENT="${2:-50}"

if [ ! -e "${PWM}" ]; then
	echo 0 > "${PWMCHIP}/export"
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
