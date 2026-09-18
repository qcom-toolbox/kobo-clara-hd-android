#!/system/bin/sh
# Sets up real USB adb using the modern configfs + FunctionFS gadget
# mechanism. This kernel (4.1.15) already migrated its USB gadget
# subsystem entirely to configfs (drivers/usb/gadget/legacy/android.c,
# the classic sysfs-based composite driver every "on property:sys.usb.
# config=adb" rule in init.usb.rc/init.common.usb.rc was written against,
# was never even present) -- so those existing init.rc rules just silently
# no-op (the /sys/class/android_usb path they write to doesn't exist) and
# were never going to work, no matter how the sys.usb.config property was
# wired up. This script sets up the gadget by hand instead, and our
# specific adbd binary (checked via `strings`) already knows how to talk
# to a FunctionFS-mounted endpoint, exactly what configfs's "ffs" function
# type provides -- so no new adbd, and no android_usb-style kernel driver
# porting, were needed; libcomposite.ko/usb_f_fs.ko/configfs.ko (all
# already enabled in this kernel's .config, just never actually built
# before now) are the only new pieces.
exec 2>>/usb_adb_setup.log
set -x

insmod /system/lib/modules/configfs.ko
insmod /system/lib/modules/libcomposite.ko
insmod /system/lib/modules/usb_f_fs.ko

mkdir -p /config
mount -t configfs none /config

mkdir -p /config/usb_gadget/g1
echo 0x18d1 > /config/usb_gadget/g1/idVendor   # Google
echo 0x4ee7 > /config/usb_gadget/g1/idProduct  # "Android ADB Interface"
echo 0x0100 > /config/usb_gadget/g1/bcdDevice
echo 0x0200 > /config/usb_gadget/g1/bcdUSB

mkdir -p /config/usb_gadget/g1/strings/0x409
echo "0123456789ABCDEF" > /config/usb_gadget/g1/strings/0x409/serialnumber
echo "clara-hd" > /config/usb_gadget/g1/strings/0x409/manufacturer
echo "Kobo Clara HD (adb)" > /config/usb_gadget/g1/strings/0x409/product

mkdir -p /config/usb_gadget/g1/functions/ffs.adb

mkdir -p /config/usb_gadget/g1/configs/c.1/strings/0x409
echo "adb" > /config/usb_gadget/g1/configs/c.1/strings/0x409/configuration
echo 500 > /config/usb_gadget/g1/configs/c.1/MaxPower

ln -s /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/c.1/ffs.adb

mkdir -p /dev/usb-ffs/adb
# adbd runs as uid/gid "shell" (2000), but a plain functionfs mount creates
# ep0 as root:root mode 0600 -- adbd's own open() on ep0 then fails
# permission checks and it can never write descriptors (confirmed: adbd
# was alive and running, but ep0 never gained ep1/ep2 siblings, which only
# appear once descriptors are successfully written). uid=/gid= are real
# f_fs.c mount options for exactly this. AID_SHELL is a fixed Android
# constant (2000) across every version.
mount -t functionfs -o uid=2000,gid=2000 adb /dev/usb-ffs/adb

echo "diag: /dev/usb-ffs/adb right after mount:" >> /usb_adb_setup.log
ls -la /dev/usb-ffs/adb >> /usb_adb_setup.log 2>&1

# Why binding the UDC has been failing with "configfs-gadget ci_hdrc.0:
# failed to start g1: -19": f_fs.c's bind() returns -ENODEV unless
# something has opened ep0 and written the FunctionFS descriptors and
# strings. /ffs_probe (run here on an earlier boot) proved the kernel
# accepts the exact descriptor blob adbd embeds, so the problem is on
# adbd's side: on the last boot it was not even running 5 s after
# "start adbd". The probe is no longer run, so adbd is the first and only
# ep0 opener.
#
# adbd's own trace log goes to /data/adb/adb-<time>-<pid> when
# persist.adb.trace_mask is set, which is how to see why it exits.
# (Do NOT capture it via logwrapper instead: that spun at 27% CPU for a
# whole boot.)
mkdir -p /data/adb
chmod 0777 /data/adb
setprop persist.adb.trace_mask 0xffff

start adbd

# Timeline: init's own view of the service (running / restarting /
# stopped), the process, the endpoint files and the usb config property.
for t in 1 2 3 4 5 6 7 8; do
	sleep 2
	echo "diag t=$((t*2))s init.svc.adbd=$(getprop init.svc.adbd)" \
		"sys.usb.config=$(getprop sys.usb.config)" >> /usb_adb_setup.log
	ps | grep adbd >> /usb_adb_setup.log 2>&1
	ls -la /dev/usb-ffs/adb >> /usb_adb_setup.log 2>&1
done
for p in $(ps | grep adbd | while read -r u pid rest; do echo $pid; done); do
	echo "diag: adbd pid $p" >> /usb_adb_setup.log
	cat /proc/$p/status >> /usb_adb_setup.log 2>&1
	ls -l /proc/$p/fd >> /usb_adb_setup.log 2>&1
	cat /proc/$p/wchan >> /usb_adb_setup.log 2>&1
	echo >> /usb_adb_setup.log
done
getprop | grep -iE "adb|usb|secure|debuggable" >> /usb_adb_setup.log 2>&1

# No `head` binary in this shell environment (same gap hit earlier with
# `awk`) -- there's only ever one UDC on this SoC, so just take the whole
# (single-line) `ls` output directly instead.
UDC_NAME=$(ls /sys/class/udc/)
echo "$UDC_NAME" > /config/usb_gadget/g1/UDC

echo "adb gadget setup done, UDC=$UDC_NAME" >> /usb_adb_setup.log
sync
