#!/system/bin/sh
# Keep the kernel's OOM killer away from the daemons that must not die.
#
# Under real memory pressure (a benchmark, several apps) the kernel OOM
# killer picks small processes with a low badness score, and on this port it
# picked init's own helpers -- ueventd, healthd, and watchdogd. Killing
# watchdogd is fatal: it is the only thing petting the i.MX2 hardware
# watchdog (60 s), so the SoC resets a minute later. The kernel even says so:
#
#   Out of memory: Kill process 71 (watchdogd) score 0 or sacrifice child
#   watchdog watchdog0: watchdog did not stop!
#
# The OOM killer skips anything at OOM_SCORE_ADJ_MIN (-1000), so pin these
# there. init respawns them with fresh pids, hence the loop rather than a
# one-shot; the cost is one pass over /proc every 15 seconds.
#
# This is a guard, not the cure. The underlying problem is that ordinary app
# processes never get their oom_score_adj set at all (system_server can only
# write it for processes sharing its own uid), so the OOM killer cannot tell
# a 200 MB benchmark from a 500 kB daemon. See ROADMAP.md.

PROTECT="watchdogd healthd ueventd servicemanager_new vold"

while true; do
	for pid in $(ls /proc); do
		case "$pid" in
			*[!0-9]*|'') continue ;;
		esac
		comm=$(cat "/proc/$pid/comm" 2>/dev/null)
		for name in $PROTECT; do
			if [ "$comm" = "$name" ]; then
				cur=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
				[ "$cur" = "-1000" ] || echo -1000 > "/proc/$pid/oom_score_adj" 2>/dev/null
			fi
		done
	done
	sleep 15
done
