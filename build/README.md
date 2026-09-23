# Building the image yourself

```sh
./build/build.sh
```

It asks for a few paths, downloads everything that may be redistributed,
patches your own firmware copy, and writes an SD card image.

## What you have to provide

Two inputs cannot be shipped here, so the build asks for them:

| Input | What it is | Where it comes from |
| --- | --- | --- |
| `android_root` directory | The Tolino Shine 3's Android 4.4.2 system: its framework jars, HALs, `init.rc`, and the whole `/system` tree. Everything this port does is a patch **on top of it**. | Tolino's own firmware update (`mytolino.com` service/update downloads for the Shine 3). Unpack the update and extract its Android root filesystem image, then mount or unpack it into a directory. |
| base SD card image | A Kobo Clara HD card image, used for its partition table, U-Boot and recovery. The build overwrites the kernel, device tree and root filesystem inside it. | An image of your own device's card, taken before you modify it. |

Neither is redistributed by this repository: the Tolino system is
proprietary vendor software, and the Kobo image contains Kobo's bootloader
and firmware. You are patching **your own copy** of software for a device
you own.

You also need the target card's size in 512-byte sectors, because Android's
storage partition is created to fill it:

```sh
cat /sys/block/sdX/size        # e.g. 124735488 for a 64 GB card
```

## What the build downloads

All of it freely redistributable, into `build/deps`:

- ARM GNU toolchain 8.3 (kernel and WiFi driver)
- Android NDK r21e and r10e (SwiftShader, `su`; the e-ink HALs)
- Android SDK platform 19 and build-tools 28 (the Front Light app)
- The Kobo Clara HD GPL kernel source (`kobolabs/Kobo-Reader`)
- Google's stock 4.4.2 emulator system image, for AOSP SystemUI, Keyguard,
  Launcher2 and Browser (this firmware ships no browser, and its own
  SystemUI hides the navigation bar)
- SwiftShader at the last revision with an Android GLES build, plus this
  port's patches for the Cortex-A9
- The `rtl8189fs` WiFi driver source
- Ghost Commander and Shattered Pixel Dungeon from F-Droid

It needs roughly 15 GB of disk and, on a normal laptop, the better part of
an hour — the kernel and SwiftShader dominate.

## Host requirements

Debian/Ubuntu:

```sh
sudo apt install build-essential git curl unzip zip default-jdk python3 \
                 cmake ninja-build e2fsprogs dosfstools bc
```

## Flashing

```sh
sudo dd if=Kobo_clara-hd.img of=/dev/sdX bs=1M conv=fsync
sudo mkfs.vfat -F 32 -n KOBO /dev/sdX4     # first time only
```

`/dev/sdX4` is Android's storage. The image deliberately stops before it, so
re-flashing a new build keeps whatever is on it. The first boot after any
framework change is slow: Dalvik re-optimizes everything once.

## Steps, and resuming

The build runs these in order; any subset can be re-run with `BUILD_STEPS`:

| Step | Does |
| --- | --- |
| `10-deps` | download and unpack dependencies |
| `20-kernel` | patch and build the kernel, DTB and `sdio_wifi_pwr.ko` |
| `30-native` | WiFi driver, SwiftShader, e-ink hwcomposer/gralloc, `su` |
| `40-apps` | extract stock apps, patch SystemUI, build Front Light |
| `50-rootfs` | copy the vendor root, drop our files in, patch its config |
| `60-framework` | patch `services.jar` and `framework.jar` |
| `70-image` | build the ext4 rootfs and assemble the image |

```sh
BUILD_STEPS="50-rootfs 60-framework 70-image" ./build/build.sh
```

Unattended:

```sh
BUILD_VENDOR_ROOT=~/tolino/android_root \
BUILD_BASE_IMAGE=~/kobo-clara.img \
BUILD_CARD_SECTORS=124735488 \
./build/build.sh
```

## If a step fails

Every patch asserts on the vendor text it expects, so a firmware revision
other than the one this was developed against stops the build with the file
and the text it could not find, rather than producing a subtly broken
system. `patches/README.md` explains what each change does and why, which is
the starting point for adapting it.

The framework patching was verified to reproduce, instruction for
instruction, the `services.jar` running on the development device. The
script as a whole has not been run end to end on a clean machine.
