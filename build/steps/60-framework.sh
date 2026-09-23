#!/bin/sh
# Framework: patch the vendor's own services.jar and framework.jar.
#
# The patched method bodies live in patches/framework/ so the change is
# reviewable without redistributing vendor binaries. Each edit asserts on the
# vendor text it expects, so a different firmware revision fails loudly.
. "$BUILD_DIR/lib.sh"

say "Framework patches"
FW="$OVERLAY/system/framework"
P="$ROOT/patches/framework"
T="$BUILD_DIR/patch/smali_tool.py"

# --- services.jar ----------------------------------------------------------
info "disassembling services.jar"
dex_from_jar "$FW/services.jar" "$WORK/services-smali"
S="$WORK/services-smali/com/android/server"

info "PowerManagerService: break the AB-BA deadlock with ActivityManager"
python3 "$T" replace-method "$S/power/PowerManagerService.smali" \
	"$P/PowerManagerService.patched-methods.smali"

info "ActivityManagerService: do not throw before boot completion"
python3 "$T" replace-method "$S/am/ActivityManagerService.smali" \
	"$P/ActivityManagerService.patched-methods.smali"

info "PackageManagerService: grant signature permissions to privileged apps"
python3 "$T" insert-prologue "$S/pm/PackageManagerService.smali" \
	"$P/PackageManagerService.grantSignaturePermission.patched-prologue.smali"

info "ServerThread: re-register the wallpaper service the vendor removed"
# Anchor including its indentation, so the inserted block lines up.
printf '    invoke-virtual/range {v150 .. v150}, Lcom/android/server/wm/WindowManagerService;->detectSafeMode()Z\n' \
	>"$WORK/wallpaper-anchor.txt"
python3 "$T" insert-before "$S/ServerThread.smali" "$WORK/wallpaper-anchor.txt" \
	"$P/ServerThread.wallpaper.patched-excerpt.smali"

jar_from_smali "$WORK/services-smali" "$FW/services.jar" "$WORK/services.jar"
mv "$WORK/services.jar" "$FW/services.jar"
rm -f "$FW/services.odex"
info "services.jar rebuilt (services.odex removed so Dalvik uses it)"

# --- framework.jar ---------------------------------------------------------
info "disassembling framework.jar"
dex_from_jar "$FW/framework.jar" "$WORK/framework-smali"

info "HardwareRenderer.isAvailable(): keep app UIs on the software path"
python3 "$T" replace-method "$WORK/framework-smali/android/view/HardwareRenderer.smali" \
	"$P/HardwareRenderer.isAvailable.patched-method.smali"

jar_from_smali "$WORK/framework-smali" "$FW/framework.jar" "$WORK/framework.jar"
mv "$WORK/framework.jar" "$FW/framework.jar"
rm -f "$FW/framework.odex"
info "framework.jar rebuilt (framework.odex removed)"
