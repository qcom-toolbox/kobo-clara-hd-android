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

## `EPubProd.apk` — `EpubApplicationInitializer$1$1.run()`

Spun forever waiting for `Environment.getExternalStorageState()` to become
`"mounted"`, which never happens in this image (the vendor user-data
partition it expects is not provisioned), logging
`waiting for internal storage to be mounted... is:removed` every 500 ms
and blocking the app's first-run flow behind a "please wait" screen.
Patched to branch straight to the success path.

Superseded in practice: the Tolino app was later removed from the image
entirely in favour of the stock AOSP `Launcher2`.
