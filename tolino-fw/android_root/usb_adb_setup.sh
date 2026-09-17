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

# The real bug behind "configfs-gadget ci_hdrc.0: failed to start g1: -19":
# f_fs.c's bind() unconditionally returns -ENODEV unless ffs_opts->dev->
# desc_ready is true, which only becomes true once adbd has opened ep0 and
# written its FunctionFS descriptors/strings -- so binding the UDC before
# that happens can never work, no matter what else is configured correctly.
# adbd may already be running (started earlier via the sys.usb.config=adb
# property in default.prop) and stuck in its own retry/backoff loop from
# before /dev/usb-ffs/adb/ep0 existed -- stop and restart it fresh here so
# it opens ep0 immediately instead of waiting out a stale backoff timer.
# ep0 is now correctly shell-owned (the uid=/gid= mount options above
# fixed that), but ep1/ep2 still never appear, so adbd is failing either
# the open or the descriptor write -- still unresolved.
#
# Running it under logwrapper with persist.adb.trace_mask set was an
# attempt to capture adbd's own D() output; do NOT do that again. It spun
# hard enough to take 27% CPU through the whole boot (visible in an ANR
# CPU breakdown as "27% 199/logwrapper"), starving a boot that is already
# slow and making the system markedly worse. Left as a plain service start.
stop adbd
start adbd

# Give adbd time to actually open ep0 and write descriptors (near-instant
# once ep0 exists, but leave real margin rather than guessing tightly).
sleep 5

echo "diag: is adbd running?" >> /usb_adb_setup.log
ps | grep adbd >> /usb_adb_setup.log 2>&1
echo "diag: /dev/usb-ffs/adb after adbd start (ep1/ep2 should exist if" \
	"adbd wrote descriptors successfully):" >> /usb_adb_setup.log
ls -la /dev/usb-ffs/adb >> /usb_adb_setup.log 2>&1

# No `head` binary in this shell environment (same gap hit earlier with
# `awk`) -- there's only ever one UDC on this SoC, so just take the whole
# (single-line) `ls` output directly instead.
UDC_NAME=$(ls /sys/class/udc/)
echo "$UDC_NAME" > /config/usb_gadget/g1/UDC

echo "adb gadget setup done, UDC=$UDC_NAME" >> /usb_adb_setup.log
sync
