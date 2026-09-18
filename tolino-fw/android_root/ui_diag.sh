#!/system/bin/sh
# UI state dump, taken once boot has settled.
#
# The first version fired on a fixed 240 s timer, which on this device was
# before SystemUI had even registered its status bar, so it showed no
# system bars at all. Wait for boot_completed instead, then dump twice so
# a SystemUI restart in between shows up.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
	sleep 10
done
for pass in 1 2; do
	sleep 120
	{
		echo "=== pass $pass: getprop qemu.hw.mainkeys: $(getprop qemu.hw.mainkeys)"
		echo "=== ps systemui"
		ps | grep -i systemui
		echo "=== dumpsys window policy"
		dumpsys window policy
		echo "=== dumpsys window windows"
		dumpsys window windows | grep -E "Window #|mFrame=|mHasSurface|mViewVisibility"
	} >> /ui_diag.txt 2>&1
	sync
done
