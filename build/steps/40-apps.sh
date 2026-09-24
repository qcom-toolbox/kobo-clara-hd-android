#!/bin/sh
# Apps: the stock AOSP SystemUI/Keyguard/Browser/Launcher2 from Google's
# 4.4.2 emulator image, this port's Front Light app, and two F-Droid apps.
. "$BUILD_DIR/lib.sh"

say "Apps"
mkdir -p "$WORK/apps"
IMG="$DEPS/sysimg19/armeabi-v7a/system.img"
[ -f "$IMG" ] || die "stock system image missing: $IMG"

# The emulator image keeps the APKs' own classes.dex alongside the odex, so
# these run as-is on the device.
for spec in "priv-app/SystemUI.apk:SystemUI.apk" \
            "priv-app/Keyguard.apk:Keyguard.apk" \
            "priv-app/Launcher2.apk:Launcher2.apk" \
            "priv-app/CalendarProvider.apk:CalendarProvider.apk" \
            "app/Browser.apk:Browser.apk" \
            "app/Calculator.apk:Calculator.apk" \
            "app/DeskClock.apk:DeskClock.apk" \
            "app/Calendar.apk:Calendar.apk" \
            "app/Email.apk:Email.apk" \
            "app/Gallery.apk:Gallery.apk"; do
	src=${spec%%:*}; dst=${spec##*:}
	if [ ! -f "$WORK/apps/$dst" ]; then
		debugfs -R "dump /$src $WORK/apps/$dst" "$IMG" >/dev/null 2>&1 \
			|| die "could not extract $src from the stock system image"
		info "extracted $dst"
	fi
done

# SystemUI needs one fix against this vendor framework: Tolino changed
# StorageManager.(un)registerListener to take IStorageEventListener, and their
# StorageEventListener does not implement it (see patches/systemui/).
say "Patching stock SystemUI for the vendor framework"
dex_from_jar "$WORK/apps/SystemUI.apk" "$WORK/systemui-smali"
for cls in 'com/android/systemui/usb/StorageNotification$StorageNotificationEventListener' \
           'com/android/systemui/usb/UsbStorageActivity$2'; do
	python3 "$BUILD_DIR/patch/smali_tool.py" implements \
		"$WORK/systemui-smali/$cls.smali" 'Landroid/os/storage/IStorageEventListener;'
done
for cls in com/android/systemui/usb/StorageNotification com/android/systemui/usb/UsbStorageActivity; do
	f="$WORK/systemui-smali/$cls.smali"
	sed -i 's#StorageManager;->registerListener(Landroid/os/storage/StorageEventListener;)V#StorageManager;->registerListener(Landroid/os/storage/IStorageEventListener;)V#g; s#StorageManager;->unregisterListener(Landroid/os/storage/StorageEventListener;)V#StorageManager;->unregisterListener(Landroid/os/storage/IStorageEventListener;)V#g' "$f"
done
grep -rq 'registerListener(Landroid/os/storage/StorageEventListener;)V' "$WORK/systemui-smali" \
	&& die "storage listener call sites not fully patched"
jar_from_smali "$WORK/systemui-smali" "$WORK/apps/SystemUI.apk" "$WORK/apps/SystemUI-patched.apk"
mv "$WORK/apps/SystemUI-patched.apk" "$WORK/apps/SystemUI.apk"
info "SystemUI patched"

# --- Gallery: give it a shared user id of its own -------------------------
#
# Gallery declares android:sharedUserId="android.media", and Android requires
# every member of a shared user to carry the same signature. This one is
# signed with AOSP's test key and the vendor's MediaProvider with Tolino's
# platform key, so the package manager refuses it outright:
#
#   Package com.android.gallery has no signatures that match those in
#   shared user android.media; ignoring!
#
# Renaming the id (same length, so the binary XML's string pool is untouched)
# leaves Gallery alone in a shared user of its own. It reaches the media
# provider through permissions either way -- the shared uid bought it nothing
# here. The manifest edit voids the APK's signature, so it is signed again
# with the same throwaway key as the Front Light app.
say "Gallery: own shared user id"
python3 - "$WORK/apps/Gallery.apk" "$WORK/apps/Gallery-unsigned.apk" <<'PYEOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
man = zin.read('AndroidManifest.xml')
old, new = 'android.media'.encode('utf-16-le'), 'android.galry'.encode('utf-16-le')
if old not in man:
    sys.exit('Gallery manifest: sharedUserId "android.media" not found')
man = man.replace(old, new)
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename.startswith('META-INF/'):
            continue        # the old signature is void once the manifest changes
        data = man if item.filename == 'AndroidManifest.xml' else zin.read(item.filename)
        zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
        zi.compress_type = item.compress_type
        zi.external_attr = item.external_attr
        zout.writestr(zi, data)
PYEOF
[ -f "$WORK/apps/Gallery-unsigned.apk" ] || die "Gallery manifest patch failed"

# --- Front Light (this repo) ----------------------------------------------
say "Front Light app"
KS="$WORK/frontlight.keystore"
if [ ! -f "$KS" ]; then
	info "generating a signing key (system apps are only checked against their own manifest)"
	keytool -genkeypair -keystore "$KS" -storepass clarahd -keypass clarahd \
		-alias frontlight -keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=Clara HD Front Light, O=clara-hd port" >/dev/null 2>&1 \
		|| die "keytool failed"
fi
A="$ROOT/apps/frontlight"
rm -rf "$WORK/fl" && mkdir -p "$WORK/fl/gen" "$WORK/fl/classes"
"$BUILD_TOOLS/aapt" package -f -m -J "$WORK/fl/gen" -M "$A/AndroidManifest.xml" -S "$A/res" \
	-I "$SDK/android.jar" -F "$WORK/fl/app.unsigned.apk" >/dev/null || die "aapt failed"
javac --release 8 -nowarn -classpath "$SDK/android.jar" -d "$WORK/fl/classes" \
	$(find "$A/src" "$WORK/fl/gen" -name '*.java') >/dev/null 2>&1 || die "javac failed"
"$BUILD_TOOLS/d8" --min-api 19 --lib "$SDK/android.jar" --output "$WORK/fl/" \
	"$WORK/fl/classes/com/claraghd/frontlight/"*.class >/dev/null || die "d8 failed"
cp "$WORK/fl/app.unsigned.apk" "$WORK/fl/FrontLight.apk"
( cd "$WORK/fl" && "$BUILD_TOOLS/aapt" add -f FrontLight.apk classes.dex >/dev/null )
"$BUILD_TOOLS/zipalign" -f 4 "$WORK/fl/FrontLight.apk" "$WORK/fl/FrontLight-a.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$KS" --ks-pass pass:clarahd --key-pass pass:clarahd \
	--ks-key-alias frontlight --v1-signing-enabled true --v2-signing-enabled false \
	--min-sdk-version 19 --out "$WORK/apps/FrontLight.apk" "$WORK/fl/FrontLight-a.apk" \
	>/dev/null || die "apksigner failed"
info "FrontLight.apk built"

"$BUILD_TOOLS/zipalign" -f 4 "$WORK/apps/Gallery-unsigned.apk" "$WORK/apps/Gallery-a.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$KS" --ks-pass pass:clarahd --key-pass pass:clarahd \
	--ks-key-alias frontlight --v1-signing-enabled true --v2-signing-enabled false \
	--min-sdk-version 19 --out "$WORK/apps/Gallery.apk" "$WORK/apps/Gallery-a.apk" \
	>/dev/null || die "apksigner failed on Gallery"
rm -f "$WORK/apps/Gallery-unsigned.apk" "$WORK/apps/Gallery-a.apk"
info "Gallery.apk re-signed"

# --- third-party apps ------------------------------------------------------
cp "$DEPS/apks/GhostCommander.apk" "$WORK/apps/GhostCommander.apk"
cp "$DEPS/apks/ShatteredPixelDungeon.apk" "$WORK/apps/ShatteredPixelDungeon.apk"
info "apps ready: $(ls "$WORK/apps" | tr '\n' ' ')"
