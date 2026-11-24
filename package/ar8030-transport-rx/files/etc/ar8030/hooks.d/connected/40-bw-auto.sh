#!/bin/sh
#
# The air unit's bandwidth setting "auto" (its ar8030-lifecycled then sets
# no bandwidth) needs this ground's chip to run its bandwidth policy: in a
# fade it halves the video's bandwidth instead of stepping below MCS 3 and
# doubles it again later (the radio config's mcs bw_auto block; a config
# paired before 11-24 still has the stock 0/0 thresholds, which lifecycled
# refuses until a factory reset brings the image's back). This
# reads the air unit's setting after every connect and passes it to this
# side's ar8030-lifecycled, which keeps it across link drops and re-applies
# it at every relink. The menu sets both sides when the setting changes;
# this covers a reconnect, a reboot and another air unit. An air unit
# without the setting reads as not auto. In the background: the IP link
# comes up with 30-ifup.sh.
AIR_API=${AR8030_AIR_API:-http://192.168.100.1:8899/api/v1}
LOCAL_API=${AR8030_LOCAL_API:-http://127.0.0.1:8899/api/v1}
command -v curl > /dev/null 2>&1 && command -v jq > /dev/null 2>&1 || exit 0
(
	i=0
	while [ $i -lt 30 ]; do
		a=$(curl -s -m 3 "$AIR_API/status" 2> /dev/null |
			jq -r 'if type == "object" and .ok then (.bandwidth_auto // false) else empty end' 2> /dev/null)
		if [ -n "$a" ]; then
			[ "$a" = true ] && on=1 || on=0
			r=$(curl -s -m 3 -X POST "$LOCAL_API/bandwidth?auto=$on" 2> /dev/null)
			logger -t ar8030-lifecycled-hook "bw-auto: air unit's bandwidth auto=$a -> $r"
			exit 0
		fi
		sleep 2
		i=$((i + 1))
	done
	logger -t ar8030-lifecycled-hook "bw-auto: no answer from $AIR_API, the bandwidth policy stays as it was"
) < /dev/null > /dev/null 2>&1 &
