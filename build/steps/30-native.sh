#!/bin/sh
# Native pieces: WiFi driver, SwiftShader (GLES 2.0 on the CPU), the e-ink
# hwcomposer/gralloc, and the adb-shell-only su.
. "$BUILD_DIR/lib.sh"

say "WiFi driver (RTL8189FS)"
D="$DEPS/rtl8189fs"
# Its Makefile copies ccflags-y into EXTRA_CFLAGS, which 4.1's kbuild folds
# back the other way -- a self-referencing variable that stops MODPOST.
python3 - "$D/Makefile" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'EXTRA_CFLAGS += $(ccflags-y)\n'
new = '# (Kobo 4.1 kbuild: Makefile.lib already folds EXTRA_CFLAGS into ccflags-y)\n'
if old in s:
    open(p, 'w').write(s.replace(old, new))
    print('    patched rtl8189fs Makefile')
PY
if [ ! -f "$D/8189fs.ko" ]; then
	make -C "$D" -j"$(nproc)" ARCH=arm CROSS_COMPILE="$CROSS" KSRC="$DEPS/kernel" \
		USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN -Wno-error" modules \
		>"$WORK/wifi-build.log" 2>&1 || die "wifi driver build failed, see $WORK/wifi-build.log"
fi
cp "$D/8189fs.ko" "$WORK/"
info "8189fs.ko built"

say "SwiftShader (OpenGL ES 2.0 on the CPU)"
S="$DEPS/swiftshader"
if ! git -C "$S" diff --quiet; then
	info "port patch already applied"
else
	git -C "$S" apply "$ROOT/patches/swiftshader/ss2019-kitkat.patch" || die "SwiftShader patch failed"
fi
mkdir -p "$WORK/ss-src"
cp "$ROOT/patches/swiftshader/CMakeLists.txt" "$WORK/ss-src/"
# The CMakeLists expects ../ss2019, ../kitkat and ../ndk next to its directory.
ln -sfn "$S" "$WORK/ss2019"
ln -sfn "$DEPS/ndk" "$WORK/ndk"
mkdir -p "$WORK/kitkat"
for pair in "system/core:system_core" "hardware/libhardware:libhardware"; do
	repo=${pair%%:*}; dir=${pair##*:}
	if [ ! -d "$WORK/kitkat/$dir" ]; then
		info "fetching AOSP 4.4.2 headers: $repo"
		mkdir -p "$WORK/kitkat/$dir"
		curl -sSfL "https://android.googlesource.com/platform/$repo/+archive/refs/tags/android-4.4.2_r1/include.tar.gz" \
			| tar xz -C "$WORK/kitkat/$dir" || die "header download failed: $repo"
	fi
done
mkdir -p "$WORK/kitkat/devlibs"
for l in libcutils.so libhardware.so; do
	cp "$VENDOR_ROOT/system/lib/$l" "$WORK/kitkat/devlibs/" || die "missing $l in the vendor image"
done
if [ ! -f "$WORK/ss-build/libGLESv2_swiftshader.so" ]; then
	cmake -S "$WORK/ss-src" -B "$WORK/ss-build" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$NDK21/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI=armeabi-v7a -DANDROID_ARM_NEON=ON -DANDROID_PLATFORM=android-19 \
		-DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release >"$WORK/ss-cmake.log" 2>&1 \
		|| die "SwiftShader configure failed, see $WORK/ss-cmake.log"
	ninja -C "$WORK/ss-build" >>"$WORK/ss-cmake.log" 2>&1 \
		|| die "SwiftShader build failed, see $WORK/ss-cmake.log"
fi
mkdir -p "$WORK/egl"
for f in "$WORK/ss-build"/*.so; do
	"$NDK21/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-unneeded \
		-o "$WORK/egl/$(basename "$f")" "$f"
done
info "$(ls "$WORK/egl" | tr '\n' ' ')"

say "e-ink hwcomposer / gralloc and su"
# linux/mxcfb.h comes from the Kobo kernel (the EPDC update ioctl), the
# hardware/* headers from the AOSP 4.4.2 tarballs fetched above.
TC="$NDK10/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64/bin"
SR="$NDK10/platforms/android-19/arch-arm"
INC="-I $DEPS/kernel/include/uapi -I $WORK/kitkat/libhardware -I $WORK/kitkat/system_core"
mkdir -p "$WORK/hw"

# hwcomposer: composes all layers itself into the RGB565 panel buffer.
"$TC/arm-linux-androideabi-gcc" -c -O2 -Wall -fPIC -std=gnu99 --sysroot="$SR" \
	-mfloat-abi=softfp -mfpu=neon $INC \
	-o "$WORK/hw/hwcomposer_eink.o" "$ROOT/gralloc_eink/src/hwcomposer_eink.c" \
	2>>"$WORK/native.log" || die "compile failed: hwcomposer_eink.c (see $WORK/native.log)"
"$TC/arm-linux-androideabi-gcc" -shared -O2 --sysroot="$SR" -mfloat-abi=softfp -mfpu=neon \
	-o "$WORK/hw/hwcomposer.imx6.so" "$WORK/hw/hwcomposer_eink.o" -ldl -lc -llog \
	2>>"$WORK/native.log" || die "link failed: hwcomposer (see $WORK/native.log)"

# gralloc wrapper: forwards to the vendor gralloc (renamed .real.so) and
# fixes up the framebuffer geometry the e-ink panel reports.
"$TC/arm-linux-androideabi-gcc" -c -O2 -Wall -fPIC -std=gnu99 --sysroot="$SR" \
	-mfloat-abi=softfp -mfpu=neon $INC \
	-o "$WORK/hw/eink_wrapper.o" "$ROOT/gralloc_eink/src/eink_wrapper.c" \
	2>>"$WORK/native.log" || die "compile failed: eink_wrapper.c (see $WORK/native.log)"
"$TC/arm-linux-androideabi-gcc" -shared -O2 --sysroot="$SR" -mfloat-abi=softfp -mfpu=neon \
	-o "$WORK/hw/gralloc.default.so" "$WORK/hw/eink_wrapper.o" -ldl -lc -llog \
	2>>"$WORK/native.log" || die "link failed: gralloc wrapper (see $WORK/native.log)"
info "hwcomposer.imx6.so and gralloc.default.so built"

# su: root for the adb shell only (owner root, group shell, mode 4750 later).
"$NDK21/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi19-clang" \
	-O2 -fPIE -pie -o "$WORK/su" "$ROOT/gralloc_eink/src/su.c" \
	2>>"$WORK/native.log" || die "su build failed (see $WORK/native.log)"
info "su built"
