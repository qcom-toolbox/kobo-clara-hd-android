#!/bin/sh
# Builds 8189fs.ko (RTL8189FS SDIO WiFi) against the Kobo 4.1.15 kernel
# tree. Output goes to /system/wifi/8189fs.ko, where libhardware_legacy
# loads it from when WiFi is switched on.
#
# Source: https://github.com/jwrdegoede/rtl8189ES_linux branch rtl8189fs,
# cloned to ext/rtl8189fs, + rtl8189fs-kobo-4.1.patch.
# Toolchain: the one the kernel was built with (toolchain_old, GCC 8.3).
set -e
cd "$(dirname "$0")/../../ext/rtl8189fs"
make -j"$(nproc)" ARCH=arm \
	CROSS_COMPILE="$PWD/../../toolchain_old/bin/arm-linux-gnueabihf-" \
	KSRC="$PWD/../../kobo-kernel/kernel" \
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN -Wno-error" modules
