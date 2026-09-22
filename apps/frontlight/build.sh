#!/bin/sh
# Builds the Front Light app (preloaded as /system/app/FrontLight.apk).
# Needs ext/sdk: android.jar (API 19, from android-19_r04.zip) and
# build-tools (r28.0.3). Signed with apps/frontlight.keystore (v1 only:
# KitKat has no APK Signature Scheme v2).
set -e
cd "$(dirname "$0")"
SDK=../../ext/sdk
BT=$SDK/build-tools
rm -rf build && mkdir -p build/gen build/classes
$BT/aapt package -f -m -J build/gen -M AndroidManifest.xml -S res -I $SDK/android.jar -F build/app.unsigned.apk
javac --release 8 -nowarn -classpath $SDK/android.jar -d build/classes $(find src build/gen -name '*.java')
$BT/d8 --min-api 19 --lib $SDK/android.jar --output build/ build/classes/com/claraghd/frontlight/*.class
cp build/app.unsigned.apk build/FrontLight.apk
(cd build && $BT/aapt add -f FrontLight.apk classes.dex >/dev/null)
$BT/zipalign -f 4 build/FrontLight.apk build/FrontLight-aligned.apk
$BT/apksigner sign --ks ../frontlight.keystore --ks-pass pass:clarahd \
	--key-pass pass:clarahd --ks-key-alias frontlight \
	--v1-signing-enabled true --v2-signing-enabled false --min-sdk-version 19 \
	--out build/FrontLight-signed.apk build/FrontLight-aligned.apk
echo "built: build/FrontLight-signed.apk"
