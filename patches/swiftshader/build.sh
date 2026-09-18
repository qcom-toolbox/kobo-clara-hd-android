#!/bin/sh
# Builds SwiftShader's OpenGL ES 1.1/2.0 + EGL for the Kobo's KitKat EGL
# loader (armeabi-v7a, API 19, Subzero JIT). Output: build-kk/out/*.so,
# installed to /system/lib/egl/.
#
# Inputs, all under ext/ (not tracked):
#   ss2019/   SwiftShader at ae0f75063 (last with the Android GLES build)
#             + ss2019-kitkat.patch
#   kitkat/   AOSP android-4.4.2_r1 headers: system/core/include ->
#             system_core/, hardware/libhardware/include -> libhardware/;
#             devlibs/ = libcutils.so, libhardware.so from the image
#   ndk/android-ndk-r21e
#   ss-kk/CMakeLists.txt  (this directory's copy)
set -e
cd "$(dirname "$0")/../../ext"
NDK=$PWD/ndk/android-ndk-r21e
cmake -S ss-kk -B build-kk -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
	-DANDROID_ABI=armeabi-v7a -DANDROID_ARM_NEON=ON \
	-DANDROID_PLATFORM=android-19 -DANDROID_STL=c++_static \
	-DCMAKE_BUILD_TYPE=Release
ninja -C build-kk
mkdir -p build-kk/out
for f in build-kk/*.so; do
	$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip \
		--strip-unneeded -o build-kk/out/$(basename $f) $f
done
