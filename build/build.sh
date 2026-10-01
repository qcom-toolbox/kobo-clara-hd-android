#!/bin/sh
# Build a bootable Android 4.4.2 SD card image for the Kobo Clara HD.
#
# You supply the two things that cannot be redistributed:
#   * the Tolino Shine 3 firmware's android_root (its Android system), and
#   * a Kobo Clara HD SD card image to use as the base (partition table,
#     bootloader and recovery).
# Everything else -- toolchains, SDK, the GPL kernel, SwiftShader, the WiFi
# driver, the stock AOSP apps -- is downloaded.
#
# See build/README.md for how to obtain the two inputs.
#
# Non-interactive use: set the variables and run.
#   BUILD_VENDOR_ROOT=... BUILD_BASE_IMAGE=... BUILD_CARD_SECTORS=... \
#   [BUILD_ROOTFS_MIB=4096] ./build/build.sh
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$BUILD_DIR")
. "$BUILD_DIR/lib.sh"

say "Kobo Clara HD / Android 4.4.2 image build"

need java javac keytool python3 curl unzip zip tar git make cmake ninja \
	mke2fs debugfs e2fsck dd truncate

ask BUILD_VENDOR_ROOT  "Path to the Tolino firmware's android_root directory"
ask BUILD_BASE_IMAGE   "Path to the base Kobo SD card image"
ask BUILD_CARD_SECTORS "Size of the target SD card in 512-byte sectors (cat /sys/block/sdX/size)"
ask BUILD_ROOTFS_MIB   "Size of the Android root filesystem in MiB (blank = fill p3)" "fill"
ask BUILD_VENDOR_APPS  "Tolino's own apps: remove or keep" "remove"
ask BUILD_OUT          "Output image path" "$ROOT/Kobo_clara-hd.img"
ask BUILD_WORK         "Scratch directory" "$ROOT/build/work"

VENDOR_ROOT=$BUILD_VENDOR_ROOT
BASE_IMAGE=$BUILD_BASE_IMAGE
CARD_SECTORS=$BUILD_CARD_SECTORS
ROOTFS_MIB=$BUILD_ROOTFS_MIB
VENDOR_APPS=$BUILD_VENDOR_APPS
OUT_IMAGE=$BUILD_OUT
WORK=$BUILD_WORK
DEPS=${BUILD_DEPS:-$ROOT/build/deps}
OVERLAY=$WORK/android_root

[ -f "$VENDOR_ROOT/init.rc" ] || die "$VENDOR_ROOT has no init.rc -- that is not an android_root"
[ -f "$VENDOR_ROOT/system/build.prop" ] || die "$VENDOR_ROOT has no system/build.prop"
[ -f "$BASE_IMAGE" ] || die "base image not found: $BASE_IMAGE"
case "$CARD_SECTORS" in
	''|*[!0-9]*) die "card size must be a number of 512-byte sectors" ;;
esac
[ "$CARD_SECTORS" -gt 15491072 ] || die "the card is too small (needs to be larger than ~8 GB)"

# The root filesystem: "fill" (the default) uses all of p3, or give a size in
# MiB to leave the rest of the partition unused -- a smaller image is quicker
# to write and to copy about, at the cost of space for apps and their dexopt
# output. p3 holds 7027 MiB; /system is about 700 MB of whatever you pick.
case "$ROOTFS_MIB" in
	fill|'') ROOTFS_MIB=fill ;;
	*[!0-9]*) die "root filesystem size must be a number of MiB, or \"fill\"" ;;
	*)
		[ "$ROOTFS_MIB" -ge 900 ] \
			|| die "$ROOTFS_MIB MiB is too small: /system alone is about 700 MB"
		[ "$ROOTFS_MIB" -le 7027 ] \
			|| die "$ROOTFS_MIB MiB does not fit in p3 (7027 MiB)"
		;;
esac

# Tolino's own apps (the reader and the crash reporter). "keep" leaves them
# installed; removing them is also what leaves AOSP's Launcher2 as the only
# home app. MsgE6 and PowerEnhance are never removed -- see 50-rootfs.sh.
case "$VENDOR_APPS" in
	''|remove) VENDOR_APPS=remove ;;
	keep) ;;
	*) die "BUILD_VENDOR_APPS must be \"remove\" or \"keep\"" ;;
esac

mkdir -p "$WORK" "$DEPS"

# Where 10-deps puts what it fetches. Defined here rather than there so that
# resuming with BUILD_STEPS works -- picking up at 20-kernel used to die with
# "CROSS: parameter not set", which made the documented resume useless.
SMALI_CP="$DEPS/jars/baksmali.jar:$DEPS/jars/smali.jar:$DEPS/jars/dexlib2.jar:$DEPS/jars/util.jar:$DEPS/jars/guava.jar:$DEPS/jars/failureaccess.jar:$DEPS/jars/jcommander.jar:$DEPS/jars/antlr-runtime.jar"
CROSS="$DEPS/arm-gcc-8.3/bin/arm-linux-gnueabihf-"
NDK21="$DEPS/ndk/android-ndk-r21e"
NDK10="$DEPS/ndk10/android-ndk-r10e"
SDK="$DEPS/sdk/android-4.4.2"
BUILD_TOOLS="$DEPS/sdk/android-9"

export BUILD_DIR ROOT WORK DEPS VENDOR_ROOT BASE_IMAGE CARD_SECTORS ROOTFS_MIB VENDOR_APPS OUT_IMAGE OVERLAY
export SMALI_CP CROSS NDK21 NDK10 SDK BUILD_TOOLS

# Each step is a separate script so a failed build can be resumed with
# BUILD_STEPS="50-rootfs 60-framework 70-image" ./build/build.sh
STEPS=${BUILD_STEPS:-"10-deps 20-kernel 30-native 40-apps 50-rootfs 60-framework 70-image"}
for step in $STEPS; do
	# shellcheck disable=SC1090
	. "$BUILD_DIR/steps/$step.sh"
done
