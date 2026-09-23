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
cp "$ROOT/patches/kernel/imx6sll-e60k02.dts"    "$K/arch/arm/boot/dts/imx6sll-e60k02.dts"

cd "$K"
[ -f .config ] || die "the Kobo tree ships its own .config; none found in $K"

if [ ! -f arch/arm/boot/zImage ] || [ "${BUILD_FORCE_KERNEL:-0}" = 1 ]; then
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
info "kernel, dtb and sdio_wifi_pwr.ko ready"
