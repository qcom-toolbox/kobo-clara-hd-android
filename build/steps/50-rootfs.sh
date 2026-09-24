#!/bin/sh
# Assemble the root filesystem: a copy of the vendor android_root with this
# port's files dropped in and its config edited.
. "$BUILD_DIR/lib.sh"

say "Root filesystem"
rm -rf "$OVERLAY"
info "copying the vendor android_root (this takes a minute)"
cp -a "$VENDOR_ROOT" "$OVERLAY"

# --- graphics --------------------------------------------------------------
install -m 644 "$WORK/hw/hwcomposer.imx6.so" "$OVERLAY/system/lib/hw/hwcomposer.imx6.so"
# The vendor gralloc becomes .real.so; our wrapper takes its place.
if [ ! -f "$OVERLAY/system/lib/hw/gralloc.default.real.so" ]; then
	cp "$OVERLAY/system/lib/hw/gralloc.default.so" "$OVERLAY/system/lib/hw/gralloc.default.real.so"
fi
install -m 644 "$WORK/hw/gralloc.default.so" "$OVERLAY/system/lib/hw/gralloc.default.so"
# Vivante/GPU HALs cannot work on the SLL (no GPU); keep them out of the way.
for f in gralloc.imx6.so gralloc_viv.imx6.so hwcomposer_fsl.imx6.so hwcomposer_viv.imx6.so; do
	[ -f "$OVERLAY/system/lib/hw/$f" ] && mv "$OVERLAY/system/lib/hw/$f" "$OVERLAY/system/lib/hw/$f.disabled"
done

# SwiftShader provides GLES 2.0; the 4.4 loader picks libEGL_*/libGLESv*_* out
# of /system/lib/egl, so the built-in GLES 1.x renderer moves aside.
mkdir -p "$OVERLAY/system/lib/egl_android_disabled"
if [ -f "$OVERLAY/system/lib/egl/libGLES_android.so" ]; then
	mv "$OVERLAY/system/lib/egl/libGLES_android.so" "$OVERLAY/system/lib/egl_android_disabled/"
fi
install -m 644 "$WORK/egl"/*.so "$OVERLAY/system/lib/egl/"

# --- wifi ------------------------------------------------------------------
mkdir -p "$OVERLAY/system/wifi" "$OVERLAY/system/lib/modules"
install -m 644 "$WORK/8189fs.ko" "$OVERLAY/system/wifi/8189fs.ko"
install -m 644 "$WORK/sdio_wifi_pwr.ko" "$OVERLAY/system/lib/modules/sdio_wifi_pwr.ko"

# --- servicemanager --------------------------------------------------------
install -m 755 "$WORK/servicemanager_new" "$OVERLAY/servicemanager_new"
install -m 755 "$ROOT/tolino-fw/android_root/svcmgr_wrapper.sh" "$OVERLAY/svcmgr_wrapper.sh"

# --- usb adb (configfs + FunctionFS) --------------------------------------
install -m 755 "$ROOT/tolino-fw/android_root/usb_adb_setup.sh" "$OVERLAY/usb_adb_setup.sh"
install -m 755 "$ROOT/tolino-fw/android_root/usb_adb_watch.sh" "$OVERLAY/usb_adb_watch.sh"

# --- apps ------------------------------------------------------------------
install -m 644 "$WORK/apps/SystemUI.apk"  "$OVERLAY/system/priv-app/SystemUI.apk"
install -m 644 "$WORK/apps/Keyguard.apk"  "$OVERLAY/system/priv-app/Keyguard.apk"
install -m 644 "$WORK/apps/Launcher2.apk" "$OVERLAY/system/priv-app/Launcher2.apk"
rm -f "$OVERLAY/system/priv-app/SystemUI.odex" "$OVERLAY/system/priv-app/Keyguard.odex" \
	"$OVERLAY/system/priv-app/Launcher2.odex"
install -m 644 "$WORK/apps/CalendarProvider.apk" "$OVERLAY/system/priv-app/CalendarProvider.apk"
# Stock AOSP apps this device can actually use. No Music, SoundRecorder or
# PicoTts: the Clara HD has no audio hardware at all.
for a in Browser FrontLight GhostCommander ShatteredPixelDungeon \
         Calculator DeskClock Calendar Email Gallery; do
	install -m 644 "$WORK/apps/$a.apk" "$OVERLAY/system/app/$a.apk"
done
# The vendor reader app spins forever waiting for storage it never gets, and
# it is the default home app; drop it so the launcher comes up.
rm -f "$OVERLAY/system/priv-app/EPubProd.apk" "$OVERLAY/system/priv-app/EPubProd.odex" \
	"$OVERLAY/system/app/SystemCrashReporter.apk" "$OVERLAY/system/app/SystemCrashReporter.odex"

# Do NOT remove MsgE6 (com.ntx.msg). It looks like a messaging app for a
# device with no telephony, but the vendor's ShutdownThread draws the
# power-off screen from it:
#
#   android.content.ActivityNotFoundException: Unable to find explicit
#   activity class {com.ntx.msg/com.ntx.msg.MsgPowerOffActivity}
#       at com.android.server.power.ShutdownThread.ShowPowerOffScreen(...)
#
# Without it every shutdown crashes system_server, so the device restarts
# instead of powering off -- an unkillable reboot loop from the outside.
# ntx.PowerEnhance stays for the same class of reason: it is part of how this
# board sleeps. Vendor apps on this image are load-bearing until proven
# otherwise.

# --- root shell for adb ----------------------------------------------------
install -m 755 "$WORK/su" "$OVERLAY/system/xbin/su"   # ownership fixed in 70-image.sh

# --- boot scripts ----------------------------------------------------------
install -m 755 "$ROOT/patches/device/disable_anim.sh" "$OVERLAY/system/bin/disable_anim.sh"
install -m 755 "$ROOT/patches/device/oom_protect.sh" "$OVERLAY/system/bin/oom_protect.sh"

# --- config ----------------------------------------------------------------
say "Config"
python3 "$BUILD_DIR/patch/config.py" "$OVERLAY"
