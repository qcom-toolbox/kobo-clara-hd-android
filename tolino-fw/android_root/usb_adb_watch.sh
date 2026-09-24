#!/system/bin/sh
# Keep adb alive.
#
# The gadget itself is set up once, by usb_adb_setup.sh. What is not stable is
# adbd: init.usb.rc carries
#
#     on property:sys.usb.config=none
#         stop adbd
#
# and this port deliberately sets sys.usb.config=none (the android_usb sysfs
# interface those rules drive does not exist on this kernel). Whether that
# trigger fires before or after the setup script's own "start adbd" is a race,
# decided by how the rest of boot happens to be scheduled -- adding a few
# preloaded apps was enough to lose it. When adbd loses, nothing ever opens
# /dev/usb-ffs/adb/ep0 to write the FunctionFS descriptors, the gadget never
# binds to the UDC, and the device simply does not appear on the host's USB
# bus at all. The same thing happens later if anything stops adbd, such as
# turning "USB debugging" on in Settings.
#
# So do not depend on the ordering: check, and put it back.

while true; do
	if [ "$(getprop init.svc.adbd)" != "running" ]; then
		setprop ctl.start adbd
		sleep 2
	fi

	# ep1 appears only once adbd has written its descriptors. With that done,
	# bind the gadget if the UDC came unbound (it unbinds whenever ep0 is
	# closed, i.e. every time adbd restarts).
	if [ -e /dev/usb-ffs/adb/ep1 ] && [ -z "$(cat /config/usb_gadget/g1/UDC 2>/dev/null)" ]; then
		for udc in $(ls /sys/class/udc/ 2>/dev/null); do
			echo "$udc" > /config/usb_gadget/g1/UDC 2>/dev/null
		done
	fi

	sleep 10
done
