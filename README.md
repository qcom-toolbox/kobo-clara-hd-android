# Android 4.4.2 on the Kobo Clara HD

Porting Android 4.4.2 (KitKat) to a Kobo Clara HD e-reader — i.MX6SLL,
1448x1072 e-ink panel, no GPU. Boots from SD card, leaving the stock
firmware on internal storage untouched.

Current state: boots to the stock AOSP `Launcher2` home screen on the
e-ink panel, with touch input.

## What's here

This repo holds **only the work that is ours**. The build tree it lives in
also contains a full Linux 4.1.15 kernel source tree, the Android NDK,
~8 GB raw SD-card images and extracted Kobo/Tolino vendor firmware; the
`.gitignore` is deny-by-default so none of that is published.

| path | what |
| --- | --- |
| `gralloc_eink/src/hwcomposer_eink.c` | the e-ink hwcomposer — software compositor writing straight to the EPDC framebuffer |
| `gralloc_eink/src/eink_wrapper.c` | gralloc shim wrapping the vendor module, adding e-ink updates + buffer geometry tracking |
| `gralloc_eink/src/binder_trace_shim.c` | `LD_PRELOAD` shim tracing every `ioctl(BINDER_WRITE_READ)` out of zygote and everything it forks |
| `gralloc_eink/src/binder_probe.c` | standalone raw binder probe, no libbinder/Dalvik involved |
| `tolino-fw/android_root/*.sh` | boot-time scripts on the device (USB/adb gadget setup, stuck-process dumper, boot logger) |
| `kobo-kernel/kernel/...` | the kernel files we changed or added |
| `patches/` | framework (`services.jar`) smali patches, as snippets rather than vendor jars |
| `ROADMAP.md` | the long-form log of how each problem was found and fixed |

## Notable fixes

Graphics, on a device whose vendor GLES stack is unusable:

- The vendor software EGL dereferences a NULL `ANativeWindow` inside
  `eglSwapBuffers`. Worked around by a custom hwcomposer that claims every
  layer as `HWC_OVERLAY`, so SurfaceFlinger never takes the GLES path.
- The vendor gralloc's `GRALLOC_USAGE_HW_FB` path has a hardcoded 2-slot
  pool and returns `-ENOMEM` on the third framebuffer allocation, which
  AOSP asks for. The wrapper strips that flag so allocations go through
  the generic ashmem path.
- SurfaceFlinger takes the display size from gralloc's `fb0`, not from the
  hwcomposer's `getDisplayAttributes`, so Android treats the panel as
  landscape-natural and rotates the UI itself. The compositor honours the
  per-layer `transform` rather than rotating on its own — doing both
  clipped 376 px off one edge and left touch inconsistent with what was
  drawn.
- Layer buffers are 32-bit `RGBX_8888`, not the framebuffer's `RGB565`;
  the compositor converts, and uses the source's own stride.

Kernel:

- Two real bugs in `drivers/android/binder.c`, including a stale
  `ptr - buffer == 4` retry check left behind by the `BR_NOOP` removal,
  which silently dropped transactions for single-threaded non-blocking
  clients like `healthd`.
- The Android logger driver (`/dev/log/*`) is absent from this kernel
  entirely — not vendor-stripped, genuinely never present in 4.1. Ported
  from mainline v3.18 to make `logcat` work at all.

Framework: an AB-BA deadlock between `PowerManagerService` and
`ActivityManagerService` that hangs system_server outright — see
[`patches/README.md`](patches/README.md).

## Building

Native pieces are built with the standalone NDK r10e bionic toolchain
(`arm-linux-androideabi-gcc`, sysroot `android-19`). A glibc ARM toolchain
will produce binaries that link `libc.so.6` with versioned symbols, which
bionic's linker can never satisfy.

```sh
NDK=.../android-ndk-r10e
TOOLCHAIN=$NDK/toolchains/arm-linux-androideabi-4.8/prebuilt/linux-x86_64/bin
SYSROOT=$NDK/platforms/android-19/arch-arm

$TOOLCHAIN/arm-linux-androideabi-gcc -c -O2 -Wall -fPIC -std=gnu99 \
  --sysroot=$SYSROOT -mfloat-abi=softfp -mfpu=neon \
  -I myinclude -I gralloc_eink/src \
  -o hwcomposer_eink.o gralloc_eink/src/hwcomposer_eink.c

$TOOLCHAIN/arm-linux-androideabi-gcc -shared -O2 \
  --sysroot=$SYSROOT -mfloat-abi=softfp -mfpu=neon \
  -o hwcomposer.imx6.so hwcomposer_eink.o -ldl -lc -llog
```

Kernel: `ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- make HOSTCFLAGS=-fcommon zImage`,
then wrap with `kobo-kernel/mk_ntx_image.py` for the NTX header U-Boot expects.

## SD card layout

Raw sector offsets the Kobo/Netronix U-Boot reads (see
`board/freescale/common/ntx_comm.c`):

| sector | contents |
| --- | --- |
| 1285 / 1286 | DTB header / payload |
| 2047 / 2048 | kernel header / payload |
| 1097730 | `android_root` ext4 partition (1 GB) |

The filesystem must be built without features a 4.1 kernel's ext4 driver
does not understand:

```sh
mke2fs -F -t ext4 -O ^has_journal,^metadata_csum,^64bit,^metadata_csum_seed \
  -d tolino-fw/android_root android_root_new.img 1024M
```
