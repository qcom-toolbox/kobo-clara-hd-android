#!/bin/sh
# Kernel: apply this port's patches to the Kobo 4.1.15 GPL tree, build zImage
# and the Clara HD DTB, and wrap both in the NTX header format U-Boot expects.
. "$BUILD_DIR/lib.sh"

say "Kernel"
K="$DEPS/kernel"
[ -f "$K/Makefile" ] || die "no kernel tree at $K"

# Our kernel changes are kept as whole files under patches/kernel (the GPL
# tree itself is not vendored in this repo).
info "applying kernel patches"
cp "$ROOT/patches/kernel/binder.c"              "$K/drivers/android/binder.c"
cp "$ROOT/patches/kernel/logger.c"              "$K/drivers/staging/android/logger.c"
cp "$ROOT/patches/kernel/logger.h"              "$K/drivers/staging/android/logger.h"
cp "$ROOT/patches/kernel/genhd.c"               "$K/block/genhd.c"
cp "$ROOT/patches/kernel/partition-generic.c"   "$K/block/partition-generic.c"
cp "$ROOT/patches/kernel/proc-base.c"           "$K/fs/proc/base.c"
cp "$ROOT/patches/kernel/compiler.h"            "$K/arch/arm/include/asm/compiler.h"
# The logger driver itself is logger.c above; these two are what give it a
# Kconfig symbol and a build rule. Without them olddefconfig silently drops
# CONFIG_ANDROID_LOGGER and the kernel comes up with no /dev/log/*, so
# logcat is empty while everything else runs.
cp "$ROOT/patches/kernel/staging-android-Kconfig"  "$K/drivers/staging/android/Kconfig"
cp "$ROOT/patches/kernel/staging-android-Makefile" "$K/drivers/staging/android/Makefile"
cp "$ROOT/patches/kernel/imx6sll-e60k02.dts"    "$K/arch/arm/boot/dts/imx6sll-e60k02.dts"

# The config builds the EPDC waveform into the kernel
# (CONFIG_EXTRA_FIRMWARE="imx/epdc/epdc_PENG060D.fw"); without it the build
# stops with "No rule to make target firmware/imx/epdc/epdc_PENG060D.fw".
# It is Netronix/E-Ink data, not ours to redistribute, and the firmware you
# downloaded already carries it.
# Where the waveform sits in the raw card: 2686464 bytes at sector 14336.
EPDC_SECTOR=14336
EPDC_SECTORS=5247
info "installing the EPDC waveform"
mkdir -p "$K/firmware/imx/epdc"
FW=
for c in "$VENDOR_ROOT/lib/firmware/imx/epdc/epdc_PENG060D.fw" \
         "$VENDOR_ROOT/system/etc/firmware/imx/epdc/epdc_PENG060D.fw" \
         "$VENDOR_ROOT/system/vendor/firmware/imx/epdc/epdc_PENG060D.fw" \
         "$VENDOR_ROOT/system/lib/firmware/imx/epdc/epdc_PENG060D.fw" \
         "${BUILD_EPDC_FW:-/nonexistent}"; do
	[ -f "$c" ] && { FW=$c; break; }
done
if [ -z "$FW" ] && [ -f "$BASE_IMAGE" ]; then
	# It is in no firmware archive at all -- not the Tolino update, not the
	# Kobo GPL tarball, not the stock rootfs. On this hardware the waveform
	# lives in a raw region of the card itself, at sector 14336, ahead of the
	# first partition, and that is where the stock kernel reads it from. Carve
	# it out of the base image: it is that device's own panel data, which also
	# makes it the correct copy rather than merely an available one.
	info "carving the EPDC waveform out of $BASE_IMAGE (sector $EPDC_SECTOR)"
	dd if="$BASE_IMAGE" of="$WORK/epdc_PENG060D.fw" bs=512 \
		skip=$EPDC_SECTOR count=$EPDC_SECTORS status=none
	if [ -s "$WORK/epdc_PENG060D.fw" ] &&
			[ "$(tr -d '\0' < "$WORK/epdc_PENG060D.fw" | wc -c)" -gt 0 ]; then
		FW="$WORK/epdc_PENG060D.fw"
	else
		rm -f "$WORK/epdc_PENG060D.fw"
		warn "nothing but zeros at sector $EPDC_SECTOR of $BASE_IMAGE"
	fi
fi
[ -n "$FW" ] || die "no EPDC waveform (epdc_PENG060D.fw) found.
    The kernel config builds it in, and it is Netronix/E-Ink data this
    repository cannot ship. A pristine Tolino android_root does not contain
    it either -- it comes off the device: mount your Kobo's own card and copy
    /lib/firmware/imx/epdc/epdc_PENG060D.fw out of it, then either drop it in
    \$VENDOR_ROOT/lib/firmware/imx/epdc/ or point BUILD_EPDC_FW at it."
cp "$FW" "$K/firmware/imx/epdc/epdc_PENG060D.fw"
info "waveform from $FW (md5 $(md5sum < "$FW" | cut -d' ' -f1))"

cd "$K"
# The Kobo GPL tarball ships defconfigs (imx_v7_kobo_defconfig and friends)
# but no .config, and this port's kernel is not any of them: it needs binder,
# ashmem, the logger, lowmemorykiller and SDIO_WIFI_PWR=m. The configuration
# the running kernel was built from is kept in patches/kernel/config, so use
# that and let olddefconfig fill in anything the tree expects.
if [ ! -f .config ] || [ "$ROOT/patches/kernel/config" -nt .config ]; then
	cp "$ROOT/patches/kernel/config" .config
	make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig >/dev/null 2>&1 \
		|| die "olddefconfig failed on patches/kernel/config"
	info "installed patches/kernel/config"
fi

# Rebuild when the config is newer than the image, not just when the image is
# missing. Keeping a stale zImage while `make modules` picks up a changed
# .config gives you a kernel and modules built from different configurations,
# and CONFIG_MODVERSIONS then makes insmod reject the modules at boot -- the
# same silent failure that once cost us WiFi and the adb gadget.
if [ ! -f arch/arm/boot/zImage ] || [ .config -nt arch/arm/boot/zImage ] ||
		[ "${BUILD_FORCE_KERNEL:-0}" = 1 ]; then
	info "building zImage (this takes a while)"
	make ARCH=arm CROSS_COMPILE="$CROSS" HOSTCFLAGS=-fcommon -j"$(nproc)" zImage \
		>"$WORK/kernel-build.log" 2>&1 || die "kernel build failed, see $WORK/kernel-build.log"
fi
info "building the device tree"
make ARCH=arm CROSS_COMPILE="$CROSS" HOSTCFLAGS=-fcommon -j"$(nproc)" imx6sll-e60k02.dtb \
	>>"$WORK/kernel-build.log" 2>&1 || die "dtb build failed, see $WORK/kernel-build.log"

# WiFi power module: built in-tree as CONFIG_SDIO_WIFI_PWR=m.
info "building sdio_wifi_pwr.ko"
make ARCH=arm CROSS_COMPILE="$CROSS" HOSTCFLAGS=-fcommon -j"$(nproc)" modules \
	>>"$WORK/kernel-build.log" 2>&1 || die "module build failed, see $WORK/kernel-build.log"

python3 "$ROOT/patches/kernel/mk_ntx_image.py" arch/arm/boot/zImage "$WORK/kernel_with_header.bin"
python3 "$ROOT/patches/kernel/mk_ntx_image.py" arch/arm/boot/dts/imx6sll-e60k02.dtb "$WORK/dtb_with_header.bin"
cp drivers/mmc/card/sdio_wifi_pwr.ko "$WORK/"
# The USB gadget modules usb_adb_setup.sh insmods. This kernel has no
# android_usb driver, so adb comes up through configfs + FunctionFS instead,
# and without these three there is no gadget at all: the device never appears
# on the host's USB bus.
cp fs/configfs/configfs.ko                  "$WORK/"
cp drivers/usb/gadget/libcomposite.ko       "$WORK/"
cp drivers/usb/gadget/function/usb_f_fs.ko  "$WORK/"
info "kernel, dtb and sdio_wifi_pwr.ko ready"
