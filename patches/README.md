# Framework patches

These are applied by disassembling the device's own `services.jar` /
`EPubProd.apk` with baksmali, editing the smali, reassembling, and
repacking. The vendor jars/APKs themselves are deliberately **not** kept
in this repo — only the resulting method bodies, so the change is
reviewable without redistributing vendor binaries.

Anything patched in `/system/framework` must also have its matching
`.odex` deleted, or Dalvik keeps running the stale pre-optimized copy and
the edit silently has no effect.

## `services.jar` — `PowerManagerService`

Three methods, all addressing the same **AB-BA deadlock** between
`PowerManagerService.mLock` and the `ActivityManagerService` monitor. The
inversion is inherent to the vendor build:

- `PowerManagerService.systemReady()` holds `mLock` and then calls
  `Context.registerReceiver()`, which needs the AMS lock.
- Several `PowerManagerService` methods are called *from* WindowManager /
  ActivityManager while the AMS lock is already held, and want `mLock`.

Whenever those two race, system_server deadlocks outright: every binder
thread that needs the AMS lock blocks forever, so newly forked app
processes hang in `ActivityThread.attach()` and the UI never comes up
(observed as a process stuck at `<pre-initialized>`).

Fixed by removing `mLock` from the methods reached from the AMS side:

| method | change |
| --- | --- |
| `isScreenOnInternal()` | reads `mSystemReady` / `mDisplayPowerRequest.screenState` without taking `mLock` |
| `setScreenBrightnessOverrideFromWindowManagerInternal(int)` | no-op |
| `setUserActivityTimeoutOverrideFromWindowManagerInternal(long)` | no-op |

The two overrides only exist to honour a *window-requested* brightness /
screen-off timeout. This panel is e-ink with no backlight driven through
that path, so ignoring them is harmless — and much safer than keeping the
state write and calling `updatePowerStateLocked()` without its lock.
(`setButtonBrightnessOverrideFromWindowManager` was already a no-op in
this build.)

## `services.jar` — `ActivityManagerService.verifyBroadcastLocked()`

Originally threw `IllegalStateException("Cannot broadcast before boot
completed")`. That is survivable when the caller is an app's binder call
into `broadcastIntent()` — the exception is marshalled back to the caller.
But AMS's own `AThread` reaches it too (via `Dialog.show()` ->
`onAttachedToWindow()` -> `sendBroadcast()`), and there it is an uncaught
exception on a Looper thread, which kills system_server.

Patched to return the intent unchanged instead of throwing, matching the
graceful degradation already used a few lines earlier for the sibling
"attempt to launch receivers ... before boot completion" case.

## Device config (`default.prop`, `init.rc`)

These two live in the vendor `android_root` and are not tracked, so the
changes made to them are recorded here.

`init.rc`:

- `import /init.usb.rc` added explicitly. (Correction to an earlier note
  here: `ro.hardware` *is* set, to `E60K00`, so `init.E60K00.rc` and
  `init.E60K00.usb.rc` are imported. The explicit import is harmless and
  the board file's USB rules are no-ops on this kernel anyway, since they
  drive the `android_usb` sysfs interface that configfs replaced.)
- Services added: `usb_adb_up` (`usb_adb_setup.sh`), `uidiag`
  (`ui_diag.sh`), `bootlogger`, `logcatcap`.
- Bring-up instrumentation removed again: the binder
  `debug_mask 65535` write, zygote's `LD_PRELOAD /binder_trace_shim.so`,
  and the `einkdumpstuck` (SIGQUITs system_server on every scan),
  `bprobe_delayed`, `fbtest` and `svcmgrprobe` services. The binder
  mask alone logged every transaction to the kernel log (~100k lines per
  boot), which kept the CPU at ~84% kernel time, made each binder call
  take 150-380 ms, and got SystemUI ANR-killed before it could add the
  navigation bar.
- `einklaunch` and `wifi_on` commented out — both forced an activity to
  the foreground during boot, which stopped any real launcher from ever
  being shown.

- `ro.adb.secure` set to `0` instead of `1`. Key approval is answered by
  UsbDeviceManager's USB-debugging prompt, which only runs with "USB
  debugging" on in Settings, and that stays off here (see below).

`default.prop`:

- `ro.secure=0`, `ro.debuggable=1`.
- `sys.usb.config` / `persist.sys.usb.config` set to `none`, **not**
  `adb`. Setting them to `adb` makes init.usb.rc's
  `on property:sys.usb.config=adb` rule start adbd very early, before
  `usb_adb_setup.sh` has mounted functionfs. adbd picks its transport once
  at startup — FunctionFS only if `/dev/usb-ffs/adb/ep0` already exists,
  otherwise the legacy `/dev/android_adb`, which cannot exist on this
  kernel (no `android_usb` gadget driver; that sysfs interface was
  replaced by configfs). Leaving it unset means `usb_adb_setup.sh` is the
  only thing that starts adbd, after `ep0` is in place.

## `SystemUI.apk` / `Keyguard.apk` — stock AOSP instead of Tolino's

Tolino's SystemUI has a custom status bar, and it only shows the nav bar
if `KeyCharacterMap.deviceHasKey()` reports neither HOME nor BACK. The
Clara's key layouts declare both, so the nav bar never appeared. Both
apps are replaced with the stock ones from Google's
`armeabi-v7a-19_r05` (4.4.2) system image. Keyguard has to go too,
because the two share `android.uid.systemui` and must be signed with the
same key.

Checked against the vendor framework (every method/field reference and
every abstract method the apps must implement): the only mismatch is
`StorageManager.registerListener`/`unregisterListener`, which Tolino
changed to take `IStorageEventListener`. Their `StorageEventListener`
does not implement that interface. In stock SystemUI, the two listener
subclasses gain `.implements IStorageEventListener` and the call sites use
the vendor signature (`systemui/storage-listener.patch.md`).

The stock apps are not signed with the vendor platform key, so
`services.jar`'s `PackageManagerService.grantSignaturePermission()` is
patched to grant signature permissions to privileged (`/system/priv-app`)
apps. Without it SystemUI cannot get `STATUS_BAR_SERVICE`,
`MANAGE_APP_TOKENS` etc. Modifying `classes.dex` inside a signed system APK
is fine: for system-image packages `PackageParser` only verifies the
certificate on `AndroidManifest.xml`.

Their `.odex` files are deleted so Dalvik optimizes the APKs' own dex.

## OpenGL ES 2.0: SwiftShader (`/system/lib/egl`)

The i.MX6SLL has no GPU, and Android's built-in `libGLES_android.so` only
implements GLES 1.x, so any app asking for a GLES 2.0 config crashed
(CPU-Z: `IllegalArgumentException: No configs match configSpec`).
SwiftShader's legacy GLES/EGL implementation is built for the KitKat EGL
loader (`patches/swiftshader/`: `build.sh`, `CMakeLists.txt`, source patch,
`sstest.c` offscreen smoke test). Fixes needed for this CPU/OS:

- Subzero `ICE_CACHELINE_BOUNDARY` padding dropped: bionic `malloc` is only
  8-byte aligned, and the over-aligned members produced 128-bit-aligned
  NEON stores into heap objects (SIGBUS `BUS_ADRALN`).
- JIT target `ARM32InstructionSet_Neon` instead of `HWDivArm`: the
  Cortex-A9 has no `SDIV`/`UDIV` (SIGILL in JIT code).
- The Reactor's ELF loader resolves Subzero's runtime helpers
  (`__divsi3`, `fmodf`, `__Sz_*` conversions, ...) to C implementations
  (float/vector ones `aapcs-vfp`, since Subzero emits hard-float calls and
  armeabi-v7a is soft-float), and Subzero always calls through a register
  (`MOVW/MOVT` + `BLX`) because the loader cannot apply `R_ARM_CALL` and the
  helpers are out of `BL` range anyway.
- `llvm-subzero` Android config: no `posix_fallocate` before API 21.
- `getModuleDirectory()`: the KitKat linker reports only a basename from
  `dladdr`, so libEGL could not find `libGLESv2_swiftshader.so` next to it
  and `eglCreateContext` failed (SurfaceFlinger aborted with
  "EGLContext creation failed"). The full path now comes from
  `/proc/self/maps`.
- Display format reported as RGBA_8888 on API 19: fb0 is RGB565, but
  SurfaceFlinger (HWC 1.1) wants an RGBA_8888 `EGL_FRAMEBUFFER_TARGET_ANDROID`
  config.

The 4.4 loader searches `/system/lib/egl` for `libEGL_*`/`libGLESv1_CM_*`/
`libGLESv2_*`, so `libGLES_android.so` is moved to
`/system/lib/egl_android_disabled/` (move it back to revert).

`framework.jar`: `HardwareRenderer.isAvailable()` returns false (and
`framework.odex` is deleted so the change is used). With a GLES 2.0 driver
present every app would otherwise render its UI through HWUI on the CPU.

`/system/xbin/su` (`gralloc_eink/src/su.c`): owner root, group shell, mode
4750 (set with `debugfs` after `mke2fs`), so only the adb shell can use it.
This adbd never runs as root, and this makes it possible to swap the EGL
driver back without reflashing.
That root has no capabilities beyond setuid/setgid (adbd drops the
bounding set), so `/system` edits go through `runas_uid 1000` (the owner
of `/system` in this image): see `swiftshader/device/` for the
enable/revert scripts (`su -c` takes a single argument, so each is wrapped
in a one-line script).

## WiFi (RTL8189FS)

The vendor `/system/wifi/8189fs.ko` targets Tolino's 3.0.35 kernel. It is
replaced by the open-source `rtl8189fs` driver built against this 4.1.15
tree (`patches/wifi/`: `build.sh`, and a one-line Makefile patch: its
`EXTRA_CFLAGS += $(ccflags-y)` makes kbuild's variables circular on 4.1).
It loads with the vendor HAL's leftover Broadcom module arguments, which
4.1 ignores with a warning.

`init.rc` (untracked, see above):

- `on boot`: `insmod /system/lib/modules/sdio_wifi_pwr.ko` (built in the
  kernel tree, `CONFIG_SDIO_WIFI_PWR=m`). It calls Kobo's
  `ntx_wifi_power_ctrl(1)`, which drives the power/reset GPIOs from the
  DT's `wifi_regulator` node and triggers the usdhc3 card-detect so the
  chip enumerates.
- `service wpa_supplicant`: copied from `init.freescale.rc` (not imported;
  `ro.hardware` is `E60K00`, and `init.E60K00.rc` has it commented out),
  with `class main`. `dhcpcd_wlan0` was
  already defined. No `android.hardware.wifi.direct` feature is declared,
  so Android uses this service rather than `p2p_supplicant`.

The IPv6 privacy-extension error from netd on enable is harmless (no IPv6
sysctls for `wlan0` in this kernel config).

## Front light (brightness) and animations

`init.E60K00.rc` (imported, `ro.hardware=E60K00`) pointed the lights HAL at
`mxc_msp430_fl.0`, the MSP430 companion of other NTX boards, which does not
exist on the Clara HD — so the brightness slider moved but nothing happened
(`E/lights: can not open file .../brightness`). The front light is the
LM3630A's **bank B**: `/sys/class/backlight/lm3630a_ledb` (bank A is
unused; `lm3630a_led` is Kobo's 0-100 wrapper). Changed there:

- `setprop hw.backlight.dev "lm3630a_ledb"` (the vendor HAL reads this and
  writes `/sys/class/backlight/<dev>/brightness`; `max_brightness` is 255,
  matching Android's range 1:1).
- `chown system system` + `chmod 0660` on that `brightness` and `bl_power`
  (the HAL runs inside system_server, the sysfs files are root-owned).

`init.rc` also gets a `noanim` oneshot service running
`/system/bin/disable_anim.sh`, which waits for `sys.boot_completed` and
pins `window_animation_scale`, `transition_animation_scale` and
`animator_duration_scale` to 0. On e-ink the animations only add ghosting
and latency, and the settings live in `/data`, so this re-applies them
after a wipe.

## `EPubProd.apk` — `EpubApplicationInitializer$1$1.run()`

Spun forever waiting for `Environment.getExternalStorageState()` to become
`"mounted"`, which never happens in this image (the vendor user-data
partition it expects is not provisioned), logging
`waiting for internal storage to be mounted... is:removed` every 500 ms
and blocking the app's first-run flow behind a "please wait" screen.
Patched to branch straight to the success path.

Superseded in practice: the Tolino app was later removed from the image
entirely in favour of the stock AOSP `Launcher2`.
