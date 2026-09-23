#!/bin/sh
# Fetch every freely redistributable dependency into $DEPS.
#
# Nothing here is vendor firmware: toolchains and SDKs from Google/ARM, the
# Kobo GPL kernel, SwiftShader, the Realtek driver, and two F-Droid apps.
# The parts that cannot be redistributed (Tolino's system image, the Kobo SD
# image) are supplied by the person running the build -- see build/README.md.
. "$BUILD_DIR/lib.sh"

say "Dependencies"
mkdir -p "$DEPS"

# --- toolchains ------------------------------------------------------------
fetch "https://developer.arm.com/-/media/Files/downloads/gnu-a/8.3-2019.03/binrel/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf.tar.xz" \
	"$DEPS/arm-gcc-8.3.tar.xz"
if [ ! -d "$DEPS/arm-gcc-8.3" ]; then
	info "unpacking arm gcc 8.3 (kernel + module toolchain)"
	mkdir -p "$DEPS/arm-gcc-8.3"
	tar -xf "$DEPS/arm-gcc-8.3.tar.xz" -C "$DEPS/arm-gcc-8.3" --strip-components=1
fi

fetch "https://dl.google.com/android/repository/android-ndk-r21e-linux-x86_64.zip" "$DEPS/ndk-r21e.zip"
unpack_zip "$DEPS/ndk-r21e.zip" "$DEPS/ndk" "android-ndk-r21e/README.md"

fetch "https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip" "$DEPS/ndk-r10e.zip"
unpack_zip "$DEPS/ndk-r10e.zip" "$DEPS/ndk10" "android-ndk-r10e/README.md"

# --- Android SDK bits (API 19 platform + build-tools) ----------------------
fetch "https://dl.google.com/android/repository/android-19_r04.zip" "$DEPS/platform-19.zip"
unpack_zip "$DEPS/platform-19.zip" "$DEPS/sdk" "android-4.4.2/android.jar"
fetch "https://dl.google.com/android/repository/build-tools_r28.0.3-linux.zip" "$DEPS/build-tools.zip"
unpack_zip "$DEPS/build-tools.zip" "$DEPS/sdk" "android-9/aapt"

# --- stock 4.4.2 system image (SystemUI, Keyguard, Browser) ---------------
fetch "https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-19_r05.zip" "$DEPS/sysimg19.zip"
unpack_zip "$DEPS/sysimg19.zip" "$DEPS/sysimg19" "armeabi-v7a/system.img"

# --- smali/baksmali and its dependencies ----------------------------------
M=https://repo1.maven.org/maven2
fetch "$M/org/smali/baksmali/2.5.2/baksmali-2.5.2.jar"          "$DEPS/jars/baksmali.jar"
fetch "$M/org/smali/smali/2.5.2/smali-2.5.2.jar"                "$DEPS/jars/smali.jar"
fetch "$M/org/smali/dexlib2/2.5.2/dexlib2-2.5.2.jar"            "$DEPS/jars/dexlib2.jar"
fetch "$M/org/smali/util/2.5.2/util-2.5.2.jar"                  "$DEPS/jars/util.jar"
fetch "$M/com/google/guava/guava/31.1-jre/guava-31.1-jre.jar"   "$DEPS/jars/guava.jar"
fetch "$M/com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1.jar" "$DEPS/jars/failureaccess.jar"
fetch "$M/com/beust/jcommander/1.82/jcommander-1.82.jar"        "$DEPS/jars/jcommander.jar"
fetch "$M/org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2.jar" "$DEPS/jars/antlr-runtime.jar"

# --- sources ---------------------------------------------------------------
git_at https://swiftshader.googlesource.com/SwiftShader "$DEPS/swiftshader" ae0f75063
git_at https://github.com/jwrdegoede/rtl8189ES_linux.git "$DEPS/rtl8189fs" rtl8189fs

if [ ! -d "$DEPS/kernel" ]; then
	info "fetching the Kobo Clara HD GPL kernel"
	fetch "https://github.com/kobolabs/Kobo-Reader/raw/master/hw/imx6sll-clara/kernel.tar.bz2" \
		"$DEPS/kobo-kernel.tar.bz2"
	mkdir -p "$DEPS/kernel"
	tar -xf "$DEPS/kobo-kernel.tar.bz2" -C "$DEPS/kernel" --strip-components=1
fi

# --- preloaded third-party apps (F-Droid) ---------------------------------
fetch "https://f-droid.org/archive/com.ghostsq.commander_420.apk" "$DEPS/apks/GhostCommander.apk"
fetch "https://f-droid.org/archive/com.shatteredpixel.shatteredpixeldungeon_340.apk" \
	"$DEPS/apks/ShatteredPixelDungeon.apk"

# Exported for the later steps.
export SMALI_CP="$DEPS/jars/baksmali.jar:$DEPS/jars/smali.jar:$DEPS/jars/dexlib2.jar:$DEPS/jars/util.jar:$DEPS/jars/guava.jar:$DEPS/jars/failureaccess.jar:$DEPS/jars/jcommander.jar:$DEPS/jars/antlr-runtime.jar"
export CROSS="$DEPS/arm-gcc-8.3/bin/arm-none-linux-gnueabihf-"
export NDK21="$DEPS/ndk/android-ndk-r21e"
export NDK10="$DEPS/ndk10/android-ndk-r10e"
export SDK="$DEPS/sdk/android-4.4.2"
export BUILD_TOOLS="$DEPS/sdk/android-9"
info "dependencies ready"
