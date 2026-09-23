# Android 4.4.2 on the Kobo Clara HD

Porting Android 4.4.2 (KitKat) to a Kobo Clara HD e-reader — i.MX6SLL,
1448x1072 e-ink panel, no GPU. Boots from SD card, leaving the stock
firmware on internal storage untouched.

**Current state: usable.** Boots to the stock AOSP launcher with a working
navigation and status bar, touch, adb over USB, WiFi, front light control,
external storage, wallpapers, and OpenGL ES 2.0 on the CPU — enough for a
real GLES 2.0 game.

| | |
| --- | --- |
| Display | custom hwcomposer writing straight to the EPDC framebuffer, with alpha blending |
| Touch | consistent with the rotation Android draws at |
| adb | over USB, via a configfs + FunctionFS gadget |
| System UI | stock AOSP SystemUI and Keyguard (the vendor's hides the nav bar by design) |
| OpenGL ES 2.0 | SwiftShader on the Cortex-A9; app UIs stay on the software path |
| WiFi | `rtl8189fs` built against this kernel |
| Front light | LM3630A bank B, plus a preloaded control app |
| Storage | the SD card partition Android expects, which the image never created |
| Battery | level and charging state report correctly |
| Preloaded | AOSP Browser, Ghost Commander, Front Light, a test game |

Not done: suspend/resume, a reader app (the vendor's is removed rather than
adapted), and e-ink refresh tuning (every frame is a full update).

## Building it yourself

```sh
./build/build.sh
```

You provide two things it cannot redistribute — the Tolino Shine 3
firmware's `android_root` (the Android system this port patches) and a Kobo
Clara HD card image (for its partition table and bootloader) — and it
downloads everything else. See [`build/README.md`](build/README.md).

```sh
sudo dd if=Kobo_clara-hd.img of=/dev/sdX bs=1M conv=fsync
sudo mkfs.vfat -F 32 -n KOBO /dev/sdX4     # first time only
```

## What's here

This repo holds **only the work that is ours**. The tree it is developed in
also contains a Linux 4.1.15 kernel source tree, NDKs, ~8 GB raw SD-card
images and extracted Kobo/Tolino vendor firmware; `.gitignore` is
deny-by-default so none of that is published.

| path | what |
| --- | --- |
| `build/` | the image build: `build.sh`, its steps, and the patch tooling |
| `patches/` | every change, as snippets and notes rather than vendor binaries — see [`patches/README.md`](patches/README.md) |
| `patches/kernel/` | the kernel files we changed (binder, logger, block uevents, DTS) |
| `patches/framework/` | patched `services.jar` / `framework.jar` method bodies |
| `patches/swiftshader/` | SwiftShader port patch, build, and its smoke tests |
| `patches/wifi/` | `rtl8189fs` build for this kernel |
| `patches/sdcard/` | the storage partition the vendor fstab expects |
| `gralloc_eink/src/` | the e-ink hwcomposer, gralloc shim, `su`, and the native debug probes |
| `apps/frontlight/` | the preloaded front light app (source) |
| `tolino-fw/android_root/*.sh` | boot-time scripts on the device |
| `ROADMAP.md` | the long-form log: how each problem was found and fixed |

## Notable fixes

Each of these is a section in [`ROADMAP.md`](ROADMAP.md).

**Graphics.** The vendor software EGL dereferences a NULL `ANativeWindow`
inside `eglSwapBuffers`, so the compositor claims every layer as
`HWC_OVERLAY` and SurfaceFlinger never takes the GLES path. It honours each
layer's `transform` rather than rotating itself (doing both clipped 376 px
off one edge), converts 32-bit layer buffers to the panel's RGB565, and
blends translucent layers — without that last part wallpapers rendered black,
because the launcher's transparent window overwrote them.

**OpenGL ES 2.0 without a GPU.** SwiftShader, with four fixes for this
CPU/OS: over-aligned members vs. bionic's 8-byte `malloc` (SIGBUS), a JIT
targeting hardware divide the Cortex-A9 lacks (SIGILL), runtime helpers its
ELF loader could not resolve at all, and KitKat's `dladdr` returning only a
basename so libEGL could not find its own GLES library.

**Storage.** Android's primary storage here is the 4th partition of the boot
SD card. Creating it was not enough: vold maps it to a device through the
`NPARTS`/`PARTN` block uevents that only AOSP kernels emit, so mainline 4.1
made it mount a nonexistent device, call it NTFS, and report success while
nothing was mounted.

**Kernel.** Two real bugs in `drivers/android/binder.c`, including a stale
`ptr - buffer == 4` retry check that silently dropped transactions for
single-threaded clients like `healthd`. The Android logger driver
(`/dev/log/*`) is absent from 4.1 entirely and was ported from v3.18 to make
`logcat` work.

**Framework.** An AB-BA deadlock between `PowerManagerService` and
`ActivityManagerService` that hangs system_server outright; a vendor
SystemUI that hides the navigation bar whenever the device declares HOME/BACK
keys; and a `WallpaperManagerService` the vendor deleted from system_server
startup.

## SD card layout

Raw sector offsets the Kobo/Netronix U-Boot reads (see
`board/freescale/common/ntx_comm.c`):

| sector | contents |
| --- | --- |
| 1285 / 1286 | DTB header / payload |
| 2047 / 2048 | kernel header / payload |
| 1097730 | `android_root` ext4 partition (1 GB) |
| 15491072 | Android's storage (FAT32, fills the card) |

The image stops before the storage partition, so re-flashing keeps whatever
is on it. The root filesystem must be built without features a 4.1 kernel's
ext4 driver does not understand:

```sh
mke2fs -F -t ext4 -O ^has_journal,^metadata_csum,^64bit,^metadata_csum_seed \
  -d tolino-fw/android_root android_root_new.img 1024M
```

Native pieces are built with the NDK r10e bionic toolchain (sysroot
`android-19`); a glibc ARM toolchain produces binaries linking `libc.so.6`
with versioned symbols that bionic's linker can never satisfy.
