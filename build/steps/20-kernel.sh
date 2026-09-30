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
cp "$ROOT/patches/kernel/imx6sll-e60k02.dts"    "$K/arch/arm/boot/dts/imx6sll-e60k02.dts"

# The config builds the EPDC waveform into the kernel
# (CONFIG_EXTRA_FIRMWARE="imx/epdc/epdc_PENG060D.fw"); without it the build
# stops with "No rule to make target firmware/imx/epdc/epdc_PENG060D.fw".
# It is Netronix/E-Ink data, not ours to redistribute, and the firmware you
# downloaded already carries it.
info "installing the EPDC waveform from the vendor firmware"
mkdir -p "$K/firmware/imx/epdc"
cp "$VENDOR_ROOT/lib/firmware/imx/epdc/epdc_PENG060D.fw" "$K/firmware/imx/epdc/" \
	|| die "no EPDC waveform at $VENDOR_ROOT/lib/firmware/imx/epdc/epdc_PENG060D.fw"

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
