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
#   BUILD_VENDOR_ROOT=... BUILD_BASE_IMAGE=... BUILD_CARD_SECTORS=... ./build/build.sh
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
ask BUILD_OUT          "Output image path" "$ROOT/Kobo_clara-hd.img"
ask BUILD_WORK         "Scratch directory" "$ROOT/build/work"

VENDOR_ROOT=$BUILD_VENDOR_ROOT
BASE_IMAGE=$BUILD_BASE_IMAGE
CARD_SECTORS=$BUILD_CARD_SECTORS
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

mkdir -p "$WORK" "$DEPS"
export BUILD_DIR ROOT WORK DEPS VENDOR_ROOT BASE_IMAGE CARD_SECTORS OUT_IMAGE OVERLAY

# Each step is a separate script so a failed build can be resumed with
# BUILD_STEPS="50-rootfs 60-framework 70-image" ./build/build.sh
STEPS=${BUILD_STEPS:-"10-deps 20-kernel 30-native 40-apps 50-rootfs 60-framework 70-image"}
for step in $STEPS; do
	# shellcheck disable=SC1090
	. "$BUILD_DIR/steps/$step.sh"
done
