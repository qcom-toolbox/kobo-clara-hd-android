# Getting the files you need

The build needs two things this repository cannot ship, plus one number.
Both come from software you are entitled to have: Tolino's own public
firmware download, and an image of **your own** Kobo's SD card.

Before starting, be clear about what this is: an unofficial port. It runs
from a **separate SD card**; your Kobo's original card, with its books and
stock firmware, stays untouched as long as you follow the card instructions
below. You need a spare microSD card (8 GB minimum, 16 GB or more is
sensible) and a card reader.

---

## 1. The Tolino firmware (the Android system)

The Clara HD never shipped Android. This port adapts the Android 4.4.2
firmware from the **Tolino Shine 3**, a device built by Kobo on effectively
the same board — same panel, same WiFi part, same touch controller; the only
significant difference is the SoC (the Shine 3's i.MX6SL has a GPU, the
Clara's i.MX6SLL does not, which is why this port needs its own graphics
work). That firmware's own hardware-detection blob already lists the
Clara's i.MX6SLL as a supported configuration.

Tolino still serves it publicly:

```sh
curl -O https://download.pageplace.de/ereader/16.2.0/OS44/update.zip
```

`OS44` is the i.MX6 device line and `16.2.0` its current version (about
210 MB). The URL scheme comes from
[Mimoja/Tolino-mk-bootimg](https://github.com/Mimoja/Tolino-mk-bootimg); if
you use that project's scripts rather than plain `curl`, read them first —
they deliberately weaken TLS to talk to the update servers.

Turn it into the directory the build wants:

```sh
./build/extract_vendor_root.sh update.zip ~/tolino/android_root
```

The update carries the system in two halves — `/system` as plain files, and
the root filesystem (`init`, `init.rc`, the board's `init.E60K00.rc`,
`fstab.E60K00`) inside `boot.img`'s ramdisk — so the script merges them and
applies the file modes recorded in the update's own `META/filesystem_config`.
It refuses to run if the zip is not what it expects.

Check it worked:

```sh
ls ~/tolino/android_root/init.rc ~/tolino/android_root/system/build.prop
```

Nothing here is redistributed by this project: you download Tolino's
firmware yourself and patch your own copy of it.

## 2. The base SD card image (partition table and bootloader)

The build writes a kernel, a device tree and a root filesystem into a copy
of a Kobo Clara HD card image. It needs that base for the partition layout,
Kobo's U-Boot in the first sectors, and the recovery partition.

**Make it from your own Clara HD.** Do not use someone else's image: it
carries that device's bootloader and firmware, and possibly their data.

1. Power the Kobo off, open the back cover, and take out the microSD card.
   (This is the fiddly part — it is a normal card in a slot, but the cover
   is a friction fit. Plenty of teardown photos exist online.)
2. Put it in a reader and find its device node (`lsblk`). Be certain: the
   next command reads a whole disk, and you will use similar commands to
   *write* later.
3. Copy the first 7.6 GB — everything up to and including the Kobo data
   partition, which is all the build needs:

```sh
sudo dd if=/dev/sdX of=~/kobo-clara-base.img bs=1M count=7564 status=progress
```

4. Put the original card back in the Kobo and check it still boots normally.
   Keep that card as your way back to stock.

The Android image is then flashed to your **spare** card, never to this one.

If you would rather not open the device at all, you cannot do this part —
Kobo does not publish full card images, and community ones are other
people's devices. Opening it and imaging the card is the honest route.

## 3. Your spare card's size

Android's storage is created to fill the card the image is flashed to, so
the build needs its size in 512-byte sectors:

```sh
cat /sys/block/sdX/size        # e.g. 124735488 for a 64 GB card
```

Use the **spare** card here (the one you will flash), not the Kobo's
original.

---

## Building and flashing

```sh
BUILD_VENDOR_ROOT=~/tolino/android_root \
BUILD_BASE_IMAGE=~/kobo-clara-base.img \
BUILD_CARD_SECTORS=124735488 \
./build/build.sh
```

It downloads the rest (toolchains, SDK, the Kobo GPL kernel, SwiftShader,
the WiFi driver, stock AOSP apps) — roughly 15 GB and an hour. See
[`README.md`](README.md) in this directory for the host packages, the
individual steps, and how to resume a failed one.

Then, with the **spare** card in the reader:

```sh
sudo dd if=Kobo_clara-hd.img of=/dev/sdX bs=1M conv=fsync status=progress
sudo mkfs.vfat -F 32 -n KOBO /dev/sdX4     # first time only
```

Put that card in the Kobo and power on.

## What to expect on first boot

- **It is slow.** Android re-optimizes the patched framework once; the first
  boot can take several minutes with the screen apparently doing nothing.
  Later boots are much quicker.
- Then the stock Android launcher, with a navigation bar at the bottom.
- WiFi is off: Settings → Wi-Fi to join a network.
- The **Front Light** app in the launcher controls brightness.
- adb works over USB (`adb devices`). Leave "USB debugging" in Settings
  **off** — this build starts adb itself, and turning that setting on
  interferes with it.

## If it does not boot

Nothing is written to the Kobo's internal storage, so the fix is to power
off, swap the original card back in, and you are on stock firmware again.

A serial console is the only way to see early boot problems. The
[MobileRead Tolino thread](https://www.mobileread.com/forums/showthread.php?t=327960)
is where people doing this kind of work on these devices are.

Every patch in the build asserts on the vendor text it expects, so a
firmware revision other than OS44 16.2.0 stops the build with the file and
text it could not find rather than producing a broken system. If that
happens, [`patches/README.md`](../patches/README.md) explains what each
change does, which is the starting point for adapting it.
