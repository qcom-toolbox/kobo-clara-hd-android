# Android 4.4.2 KitKat on Kobo Clara HD — Roadmap

## Status: running on hardware

Android 4.4.2 boots from SD card on a real Clara HD and is usable: e-ink
display and touch, navigation bar and stock status bar, adb over USB, WiFi,
front light brightness, external storage, wallpapers, and OpenGL ES 2.0 on
the CPU (SwiftShader) — enough for a real GLES 2.0 game. `build/build.sh`
reproduces the image from a user's own firmware copy.

| Works | Notes |
| --- | --- |
| Display | custom hwcomposer straight to the EPDC framebuffer, with alpha blending (2.38, 2.46) |
| Touch | rotation-consistent with what is drawn (2.38) |
| adb | configfs + FunctionFS gadget (2.39) |
| System UI | stock AOSP SystemUI/Keyguard, nav bar + status bar (2.41) |
| OpenGL ES 2.0 | SwiftShader on the Cortex-A9 (2.42) |
| WiFi | rtl8189fs built against this kernel (2.43) |
| Front light | LM3630A bank B via the vendor lights HAL, plus a preloaded control app (2.44) |
| Storage | the 4th SD partition Android expects, which the image never created (2.45) |
| Wallpapers | vendor had removed the service; compositor ignored alpha (2.46) |

Still open: the vendor's stock reader app is removed rather than adapted;
screenshots via SurfaceFlinger's GLES path are unverified; suspend/resume and
battery life have not been looked at at all.

Sections 1–2.37 below are the original plan and the bring-up log that
followed it; 2.38 onwards continue that log. This document is the long-form
record — `README.md` is the short version, `patches/README.md` explains each
patch, and `build/README.md` is how to build it.

**Revision note:** the strategy below changed significantly after finding that the
Tolino Shine 3 — a board effectively identical to the Clara HD — ships production
Android 4.4.2 from the factory. That's now the primary path. Sections 5–6 (the
from-scratch AOSP route) are kept as a fallback if firmware adaptation hits a wall.

---

## 1. Hardware facts

| Component | Kobo Clara HD | Tolino Shine 3 |
|---|---|---|
| SoC | NXP i.MX6**SLL** (part MCIMX6V7DVN10AB) — Cortex-A9 @ 1GHz, **no 3D GPU** | NXP i.MX6**SL** (part MCIMX6L8DVN10AB) — Cortex-A9 @ 1GHz, **has Vivante GC320 GPU** |
| RAM | 512MB LPDDR2/3 | 512MB (same) |
| Storage | 8GB — **ordinary removable microSDHC card** (SanDisk Edge, UHS-I Class C4), not soldered eMMC. See Section 2.8. | 8GB (same) |
| Display | 6" E Ink Carta HD, 1448x1072, EPDC-driven | Same panel, same spec |
| WiFi | Realtek RTL8189FTV, SDIO | Same board — very likely identical |
| Touch | Capacitive, I2C | Same board — very likely identical |
| Board/PCB | Designed by Kobo; Kobo is Tolino Alliance's hardware partner and now designs all Tolino hardware | Same board design as Clara HD |
| Stock OS | Nickel (custom embedded Linux) | **Android 4.4.2 KitKat**, kernel 3.0.35 |

The two chips are **pin-compatible, not identical** — SL has the GPU, SLL doesn't.
Confirmed two independent ways: exact part numbers from a MobileRead teardown
discussion, and (more directly) a Shine-3 owner's ADB device-manager entry reading
literally **"i.mx6sl NTX Smart Device."** This is the one dimension of the board
that actually differs, and it happens to be the dimension that matters most for
Android's graphics stack. Everything else checks out as shared: see Section 2.6 —
Tolino's own shipped firmware hardware-config blob explicitly lists both the SL and
SLL variants (paired with the same two EPD-PMIC options Kobo's own kernel supports)
as supported configurations of the *same* board/firmware family.

**Practical consequence:** everything on the Tolino Shine 3's stock firmware that
*isn't* graphics-HAL code is running on what is, for porting purposes, the same
board — kernel board support, the WiFi driver and its Android HAL wiring, touch, the
bootloader chain, EPDC panel integration, and the entire Android 4.4.2 userspace.
Only the display HAL (which talks to the GC320 GPU) needs real adaptation.

## 2. Primary strategy: adapt the Tolino Shine 3's stock Android firmware

This is now the primary path — adapting a real, shipped, production Android build
on effectively the same board — rather than building AOSP from scratch against a
GPU-less chip with no existing device tree.

### Existing tooling and community (found via your links + follow-up research)

- **Firmware source**: `mytolino.com/service/updates/` — official OTA update
  packages. Community members also share full firmware images (Google Drive, etc.)
  in the MobileRead thread below.
- **[MobileRead: "Firmware Images, Customizing the Tolino, & More"](https://www.mobileread.com/forums/showthread.php?t=327960)**
  — active, multi-page community hub. People are already extracting, modifying, and
  reflashing Tolino firmware here, including Shine 3 specifically. This is the
  community to actually engage with directly — they're doing adjacent work already,
  unlike the general MobileRead readership that redirected your original 2.3.6
  thread to "go ask Android developers."
- **[MobileRead Wiki: Tolino firmware](https://wiki.mobileread.com/wiki/Tolino_firmware)**
  — version history; firmware version 12 shipped with the Shine 3.
- **[Mimoja/Tolino-mk-bootimg](https://github.com/Mimoja/Tolino-mk-bootimg)** —
  script that downloads a stock Tolino update.zip and produces an ADB-enabled
  `boot.img`. Directly supports Vision 4/3/2, Shine 2 HD, Page — not confirmed for
  Shine 3 by name, but the mechanism (patch the ramdisk to enable ADB/root) should
  generalize. Note: its own README flags that it deliberately weakens TLS to talk to
  Tolino's update servers — read that script before running it, and treat the
  weakened-TLS step as something to do deliberately, not blindly.
- **TWRP recovery port for Tolino Shine 3** (by "Ryogo", per the MobileRead thread) —
  significant: someone has already solved safe recovery-mode flashing for this exact
  device. This meaningfully de-risks the brick-risk concern from the original plan.
- **SuperSU-based root** — the standard Android 4.x rooting path, already in use in
  this community for these devices.

### Phased plan

#### Phase 1 — Get root + a full firmware dump of a real Tolino Shine 3
You need actual hands on a Shine 3 (or a full firmware image someone's already
dumped from one — check the MobileRead thread first before buying hardware). Use the
existing TWRP port + Mimoja's tooling (or the manual ADB-enable process the German
guides walk through) to get root and pull a complete image: boot.img (kernel +
ramdisk), system.img, and the raw bootloader/partition layout.

#### Phase 2 — Diff against what you already have for the Clara HD
You already have Kobo's own vendor kernel source
(`hw/imx6sll-clara/kernel.tar.bz2` in
[kobolabs/Kobo-Reader](https://github.com/kobolabs/Kobo-Reader/tree/master/hw/imx6sll-clara))
and a working U-Boot + postmarketOS bring-up on your actual Clara HD unit. Diff the
Tolino kernel's board/machine config against Kobo's SLL kernel to find: SoC ID
tables, clock trees, pinmux, and — critically — every place the Tolino kernel touches
the GC320 GPU driver (Vivante `galcore`), so you know exactly what to rip out.
Compare WiFi and touch driver integration between the two — these should need
little to no change if the board really is shared.

#### Phase 3 — Strip the GPU dependency from the Android userspace
This is the real work, and it's now a much smaller job than writing a display HAL
from nothing:
- Replace `gralloc.gc320`/Vivante-backed gralloc with `gralloc.default` (software).
- Replace or strip the GPU-backed `hwcomposer` with a minimal one that flips the
  software-rendered buffer to the EPDC framebuffer (`/dev/graphics/fb0`,
  `mxc_epdc_fb` driver — this part should already work correctly in the Tolino
  kernel/userspace, since EPDC integration isn't GPU-dependent and both boards use
  the same panel).
- Remove/stub any `libGLES`/EGL paths that assume Vivante's proprietary driver.
- Expect this to be slow (single-core Cortex-A9, software rendering) but *usable*
  for an e-reader UI, which mostly renders static text/bitmap pages rather than
  animating — the [marek-g Android 2.3 port](https://github.com/marek-g/kobo-kernel-2.6.35.3-android)
  (see Section 6) already demonstrates acceptable e-reader performance on
  comparably weak, GPU-less hardware.

#### Phase 4 — Swap in Kobo's kernel bits where the SoC actually differs
Where Phase 2's diff shows real SLL-vs-SL differences (SoC ID/clock/pinmux tables,
and anywhere the Tolino kernel's board file assumes the GPU exists at the kernel
level, e.g. power domain or clock-gating code for the GPU block that SLL doesn't
have), patch in the equivalent from Kobo's own imx6sll-clara kernel source.

#### Phase 5 — Bootloader integration
Your Clara HD already boots via its own U-Boot. Get the adapted Android boot.img
booting through it — ideally via SD card first (matches the existing dual-boot/
recovery safety margin from your prior postmarketOS work), before touching internal
eMMC. The existing Shine 3 TWRP port is useful reference for how Tolino's own
bootloader hands off to Android, even though you're chain-loading from Kobo's U-Boot
instead.

#### Phase 6 — Bring-up iteration
Serial console, as always. Verify WiFi first (should be closest to "just works"
since it's the least-touched subsystem), then touch, then display refresh
quality/ghosting — tune periodic full-refresh behavior the same way marek-g's
CoolReader3 fork does, applied to whatever reader app you end up using.

## 2.5 Kobo kernel baseline assessment (done)

Pulled and extracted `hw/imx6sll-clara/kernel.tar.bz2`. Findings:

| Question | Answer |
|---|---|
| Kernel version | Linux **4.1.15** (NXP codename "Series 4800") — newer than the 3.0.35-class vendor fork originally assumed |
| ashmem | Present (`drivers/staging/android/ashmem.c`) |
| binder | Present, already promoted out of staging (`drivers/android/binder.c`, `CONFIG_ANDROID_BINDER_IPC`) |
| lowmemorykiller | Present |
| sync/sw_sync (fence sync) | Present |
| early_suspend / legacy wakelocks | Not checked yet |
| RTL8189FTV WiFi driver | **Not in this tree** — confirmed out-of-tree, same as postmarketOS's approach. Not a blocker, just a known separate build step. |
| Board identification | No file literally named "clara." Tree covers a family of `imx6sll-e60*.dts` Netronix ("Freescale i.MX6SLL **NTX** Board") reference designs. `e60k02`/`e60k02-sy7636` use Cypress `cyttsp5` touch + Ricoh `rc5t619` PMIC — the likely Clara HD match based on known touch controller. Driver stack is Netronix's own custom platform drivers: `ntx_bl`, `ntx_led`, `ntx_event0`, not generic upstream ones. |

**Why this matters for the SL-vs-SLL question (Section 1):** this is a directly testable signal.
If the Tolino Shine 3's kernel *also* carries `ntx_bl`/`ntx_led`/`ntx_event0` +
`cyttsp5` + `rc5t619` on an "NTX Board" dts, that's strong hardware-level
confirmation it's genuinely the same Netronix reference board, which would soften
or eliminate the GPU-strip concern from Section 1 — check for these exact strings
first thing once a Tolino kernel/firmware dump is in hand.

**Practical upshot:** the kernel side already carries nearly the full Android
subsystem stack (ashmem/binder/lowmemorykiller/sync) with no work needed — a much
smaller lift than Section 5's fallback plan assumed. The main remaining kernel-side
unknown is early_suspend/wakelock presence, and whatever board-level adaptation the
real diff against Tolino turns up.

## 2.6 Tolino firmware acquired and analyzed (done)

Found the real download URL scheme (`https://download.pageplace.de/ereader/{version}/{OS-code}/update.zip`,
via Mimoja's tooling) and pulled two packages directly from Tolino's live update
servers — no physical device needed for this part.

### OS81 (v16.0.0) — turned out to be the wrong device family
Grabbed this first based on a forum snippet. Build fingerprint:
`RakutenKobo/tolino/tolino:8.1.0/34f56d1/20220929-102831:user/release-keys` — real
Android 8.1, built by Kobo/Rakuten themselves, kernel **4.9.56**. But
`init.recovery.sun8iw15p1.rc` in the ramdisk gives it away: `sun8iw15p1` is an
**Allwinner** SoC codename, not NXP/i.MX. This is a *newer* Tolino generation
(post-Shine-3) that moved to different silicon entirely. Confirms Kobo/Rakuten
maintains real modern Android engineering for this product line, but it's not
directly applicable to i.MX6-class hardware. Kept for reference, not load-bearing.

### OS44 (v16.2.0) — the real one
This is the current, still-live update for the Shine 3 / Vision-4-class i.MX6
hardware line. Confirmed via `file`: pre-3.17 ARM zImage (old-style kernel, matches
Android 4.4.2 expectations, not the 4.9-kernel Android 8.1 line). **Kobo/Netronix
never brought Android 8.1 to this SoC family — they replaced the silicon generation
instead of upgrading the OS on it.** Shine 3 is genuinely still on Android 4.4.2 in
its current, live, actively-served firmware.

What came out of it, concretely:

- **`ntx_hwconfig-static`** (runtime hardware-detection blob) lists board configs
  including `MX6SL+SY7636`, `MX6SL+TPS65185`, **`MX6SLL+SY7636`, `MX6SLL+TPS65185`**.
  This is the single strongest finding of the whole investigation: **this exact,
  currently-shipping firmware already has explicit, built-in support for the i.MX6SLL
  + SY7636 and i.MX6SLL + TPS65185 combinations** — which are precisely Kobo's own
  two Clara HD kernel variants (`e60k02-sy7636` and `e60k02` in
  `hw/imx6sll-clara/kernel.tar.bz2`, Section 2.5). Two independent sources — Kobo's
  own published kernel and Tolino's shipped Android firmware — agree on the same
  board taxonomy. This is about as strong as evidence gets short of physically
  booting it.
- **Real partition layout** (`recovery/root/fstab.E60K00`), on `sdhci-esdhc-imx`
  (confirms i.MX SD/MMC controller):
  `mmcblk0p1`=boot, `p2`=recovery, `p5`=system, `p6`=cache, `p7`=data, `p8`=device,
  `p9`=misc, `p10`=share. Needs checking against Clara HD's actual eMMC layout, but
  it's a concrete reference point instead of a guess.
- **Real WiFi service wiring** (`recovery/root/RTL8189_init.rc`): standard
  `wpa_supplicant` + `nl80211` driver + `dhcpcd`, `wlan0` interface, no exotic
  vendor HAL glue. Confirms RTL8189 on this exact board family and gives the literal
  init.rc service definitions to reuse.
- Confirmed (separately, via a Shine-3-owner's ADB device-manager screenshot found
  during research): the Shine 3 identifies as **"i.mx6sl NTX Smart Device"** — hard
  confirmation of the SL/SLL split from Section 1. Board design shared, SoC swapped.

### Where things are on disk
- `/home/enzo/clara-hd/kobo-kernel/kernel/` — Kobo's extracted vendor kernel source
  (Section 2.5)
- `/home/enzo/clara-hd/tolino-fw/os44/` — extracted Shine-3-line firmware artifacts:
  `boot.img`, `kernel.bin` (raw zImage), `ntx_hwconfig-static`
- `/home/enzo/clara-hd/tolino-fw/boot.img` + `ramdisk_extract/` — the Android 8.1
  Allwinner package's ramdisk (reference only, not load-bearing for this SoC)

### Kernel unpacked and inspected (done)
The zImage decompresses cleanly with a proper gzip-stream search (the first attempt
hit a false-positive magic-byte match; retried scanning all candidate offsets and
decompressing with `zlib`, ignoring trailing padding). Findings:

- **Linux 3.0.35** (`gd4fd989-dirty`), rebuilt as recently as **January 2024** —
  Netronix/Kobo keep patching this same ancient base rather than rebasing, which
  matches the "never touch the kernel across OTA" embedded norm.
- **Vivante GPU driver (`galcore`) is compiled in** — this is not a GPU-free
  kernel image. But its clock-acquisition path fails gracefully:
  `"failed to get gpu3d_clk! disable 3d"`, `"...disable 2d/vg"` — the driver
  self-disables 2D/3D/VG accel if those clocks aren't present rather than panicking.
  On real SLL silicon those clock nodes simply wouldn't exist, so this looks like
  it's designed to degrade cleanly rather than assume the GPU is always there —
  consistent with `ntx_hwconfig-static` treating MX6SLL as a real, intended target,
  not dead code.
- **`mxc_epdc_fb.c` EPDC driver fully present**, complete ioctl surface
  (`mxc_epdc_fb_ioctl`, `_send_update`, `_set_temperature`, `_set_upd_scheme`, etc.)
  — the actual e-ink display path Android would use.
- Board differentiation in this codebase is **not** done via per-board device
  trees (no `imx6sll`/`imx6sl` DT compatible strings exist in the kernel at all) —
  this predates widespread DT adoption on ARM. Differentiation happens through the
  `ntx_hwconfig-static` runtime blob (and likely board-file C code / an EEPROM or
  GPIO-read board ID at boot), a materially different mechanism than Kobo's own
  newer 4.1.15 kernel uses. Matters for Phase 2's diff — comparing "board file
  logic + hwconfig" against Kobo's DT-based approach isn't a line-level diff, it's
  a conceptual translation between two different board-support mechanisms.

### Graphics HAL: two parallel HAL sets, already shipping (done)
This settles most of the remaining doubt. `update_os44.zip`'s `system/lib/hw/`
ships **two complete, parallel HAL sets** side by side:

| GPU path (Vivante) | Non-GPU path |
|---|---|
| `gralloc_viv.imx6.so` | `gralloc.imx6.so` |
| `hwcomposer_viv.imx6.so` | `hwcomposer.imx6.so`, `hwcomposer_fsl.imx6.so` |

Plus the stock `gralloc.default.so`. Android's HAL loader picks which `.so` to load
at runtime via the `ro.hardware`/`ro.product.board` property (standard
`hw_get_module` convention) — so which set loads is a config choice, not a code
change. Checked the non-GPU binaries directly:

- `hwcomposer.imx6.so` references `/dev/graphics/fb%d` directly — it composites by
  writing to the standard Linux framebuffer device, which is exactly what
  `mxc_epdc_fb` backs. This is the real path from Android's compositor to the
  e-ink panel, already built and shipping.
- `gralloc.imx6.so` isn't 100% pure-software — it still contains GPU-open-attempt
  strings (`"gralloc_device_open: gpu gralloc device open failed!"`) — so it looks
  like a wrapper that tries to open a GPU gralloc device and has explicit,
  string-visible fallback handling when that fails, rather than a hard requirement.
  Consistent with the kernel-level graceful clock-failure degradation found above.

**Net effect: the "write a display HAL for GPU-less e-ink Android" problem — the
thing originally flagged in Section 1 as the hardest unsolved piece of this whole
project — already has a real, shipping, non-GPU implementation sitting in this
firmware.** The work shifts from *invent it* to *extract it, wire it to Kobo's
partition/bootloader layout, and get `ro.hardware` pointed at the right HAL set.

### Confirmed: software rendering is the deliberate design, not a GPU-absent fallback (done)
Extracted the OS44 boot.img ramdisk and read `init.E60K00.rc` (E60K00 is the board
class covering both MX6SL and MX6SLL per `ntx_hwconfig-static`) directly:

```
setprop debug.egl.hw 0          # hardware-accelerated EGL explicitly disabled
setprop ro.product.display eink
setprop hwc.stretch.filter 1
setprop hwc.enable_dither 1     # grayscale dithering — only matters for e-ink
setprop ro.sf.hwrotation 270
```

`debug.egl.hw=0` disables hardware EGL outright, board-wide, for every SoC variant
this init file serves — Vivante-equipped or not. This isn't a fallback path that
only kicks in when a GPU is absent; it's how this product line always renders.
Combined with the dithering/e-ink-mode flags (which only make sense for a
software/HAL path that's e-ink-aware in the first place), this closes out the
question raised all the way back in Section 1: whether Clara HD's SLL actually has
a GPU stops mattering, because the production OS for this whole board family never
uses one regardless. The `_viv` HAL variants likely exist for other Netronix
customers/boards in the family that do lean on the GPU, not for this product line.

Also found in the boot cmdline: `video=mxcepdcfb:E060SCM`, `max17135:pass=2` — a
**third** EPD-PMIC option (Maxim MAX17135) beyond the SY7636/TPS6518x pair found
earlier, and the panel identifier string (`E060SCM`) that would need matching or
overriding for Clara HD's actual panel.

## 2.7 Kobo's own bootloader already has Android support built in (done)

Pulled `hw/imx6sll-clara/bootloader.tar.bz2` — real U-Boot source. Found
`board/freescale/mx6sll_ntx/` using the exact same `ntx_*` naming convention
(`ntx_hw.c`, `ntx_hwconfig.h`, `ntx_cmd.c`) found in Tolino's kernel and firmware —
confirms the shared-Netronix-SDK lineage extends to the bootloader too, not just
kernel/HAL.

Then found `include/configs/mx6sll_ntx_android.h` — a full Android build config for
this exact board — and confirmed it's **not dead code**:
`include/configs/mx6sll_ntx.h` (the real, live config included by actual shipping
`mx6sll_ntx_*_defconfig` targets) has, unconditionally:

```c
#define CONFIG_ANDROID_SUPPORT		1
#if defined(CONFIG_ANDROID_SUPPORT)
#include "mx6sll_ntx_android.h"
#endif
```

This is compiled into every standard build of this board's U-Boot. **Kobo's actual
shipping bootloader for the Clara HD already has:**

```c
#define CONFIG_ANDROID_BOOT_IMAGE          // boots standard Android boot.img format
#define CONFIG_FASTBOOT_FLASH              // fastboot flashing support
#define CONFIG_FSL_FASTBOOT
#define CONFIG_ANDROID_RECOVERY
#define CONFIG_CMD_BOOTA                   // dedicated "boota" boot command
#define CONFIG_ANDROID_MAIN_MMC_BUS 2
#define CONFIG_ANDROID_BOOT_PARTITION_MMC 1
#define CONFIG_ANDROID_SYSTEM_PARTITION_MMC 5
#define CONFIG_ANDROID_RECOVERY_PARTITION_MMC 2
#define CONFIG_ANDROID_CACHE_PARTITION_MMC 6
#define CONFIG_ANDROID_DATA_PARTITION_MMC 4
```

Unused by Nickel, present the whole time. Note the data-partition number (4) differs
from the Shine-3-line `fstab.E60K00` found in Section 2.6 (which used p7 for
`/data`) — expected, since these come from different board revisions/products in
the shared Netronix family, not the same unit. Clara HD's *actual* real-world
partition table (from your own prior hands-on work per your original MobileRead
thread) is the one to trust for a real build, not either of these vendor defaults —
but both are now known, concrete reference points instead of guesses.

## 2.8 Ground truth from the actual, live Clara HD (done)

Your Clara HD's microSD card was sitting in a reader plugged into this machine
(`/dev/sde` — SanDisk SDDR-113 reader, matches the exact card-pull technique from
[Lee Yingtong Li's teardown](https://yingtongli.me/blog/2018/07/29/kobo-sd.html):
this is an **ordinary, removable 8GB microSDHC card**, not soldered eMMC — pop the
back cover, pull the card, image it with any reader. Section 1's hardware table is
corrected accordingly. This matters a lot for brick risk: recovery is "pop the card,
`dd` a known-good image back" with a $5 reader, not eMMC-programmer territory.

Mounted both partitions read-only (no writes made) and got real, current-state data
instead of inference:

- Card currently runs **postmarketOS edge**, kernel **6.9.0** — genuinely current
  mainline, not the vendor 3.0.35/4.1.15 lines discussed elsewhere in this doc.
- **`imx6sll-kobo-clarahd.dtb`** — a proper mainline device tree, decompiled with
  `dtc` (saved to `kobo-kernel/imx6sll-kobo-clarahd.dts`). Confirms, from the actual
  device, no longer inferred:
  - `compatible = "kobo,clarahd", "fsl,imx6sll";` — the SoC question is fully
    closed, straight from silicon.
  - `epdc-pmic@68 { compatible = "ti,tps6518x"; }` — this specific unit is the
    **TPS6518x** variant, not SY7636. Settles which of Kobo's two kernel variants
    (`e60k02` vs `e60k02-sy7636`, Section 2.5) actually matches — it's the base
    `e60k02`.
  - `ricoh,rc5t619` system PMIC, `cypress,tt21000` touchscreen (the exact chip
    behind the `cyttsp5` driver found everywhere else in this investigation) — both
    exact matches to what was inferred from Kobo's and Tolino's source trees.
  - WiFi confirmed on `mmc@2198000` (SD3), with a fixed regulator (`SD3_SPWR`) and
    `mmc-pwrseq-simple` reset-gpio — matches the postmarketOS wiki's description of
    the WiFi power sequencing exactly, now with real register addresses.
  - RAM confirmed at exactly `0x20000000` = 512MB.
  - `fsl,imx6sll-epdc` — real EPDC compatible string.
- **`8189fs.ko`** present in `/lib/modules/6.9.0/kernel/drivers/net/wireless/` —
  confirms the RTL8189 WiFi driver name exactly as expected, plus `btrtl.ko`,
  meaning the same chip handles Bluetooth too (not discussed elsewhere in this doc
  — worth keeping in mind as a bonus target once WiFi itself works).
- `extlinux/extlinux.conf` shows the real boot flow: `vmlinuz` + `fdtdir /` +
  `initramfs`, cmdline built from `pmos_boot_uuid`/`pmos_root_uuid` — a much
  simpler, cleaner boot chain than either vendor's, worth using as the reference
  for how U-Boot actually hands off on this exact unit.

This closes out nearly every "unverified" item elsewhere in this document. The
touch/WiFi/PMIC identity questions from the risk register are no longer inferred
from source trees — they're read directly off silicon.

## 2.9 Real factory partition table, from your own 2024 stock backup (done)

You had a full stock firmware backup already (`Kobo.img`, 7.4GB, dated Sep 2024) —
this turned out to be more valuable than a fresh card backup, since it's the
**pristine, as-shipped factory layout**, uncomplicated by any later postmarketOS
experimentation. Mounted read-only via loop devices against the image file only —
the live card in the reader was never touched for any of this.

Real, complete `fdisk` output (MBR, not GPT):

| Partition | Size | Type | Label | Contents |
|---|---|---|---|---|
| p1 | 256M | ext4 | `rootfs` | Nickel's actual root filesystem (busybox-init: `linuxrc -> bin/busybox`) |
| p2 | 256M | ext4 | `ntxrecovery` | A Netronix recovery partition — not documented anywhere else in this investigation |
| p3 | 6.9G | FAT32 | `KOBOeReader` | User content/onboard storage — exactly the volume label that appears over USB |

No separate boot/kernel partition — the ~24MB of raw space before p1 (partition 1
starts at sector 49152) is where U-Boot and presumably the kernel/DTB live at fixed
raw offsets, not inside a filesystem. Confirmed indirectly:
`etc/u-boot/mx6sll-ntx/{u-boot.mmc,u-boot.recovery}` in rootfs holds the raw
U-Boot images used to (re)flash that raw area — U-Boot itself isn't partitioned,
it's written directly to fixed sectors.

Other finds from rootfs:
- **`drivers/mx6sll-ntx/wifi/8189fs.ko`** — third independent confirmation of the
  WiFi driver (postmarketOS wiki description → Tolino's `RTL8189_init.rc` →
  now Kobo's own stock driver folder). Also found `8192es.ko` alongside it —
  a second WiFi chip option (RTL8192ES), meaning some manufacturing
  batches/revisions may carry a different WiFi chip than assumed; worth checking
  which one your actual unit has before assuming RTL8189 without verifying.
- Internal MMC device node is **`mmcblk0`** (confirmed via a `mount
  /dev/mmcblk0p8 ...` line in `etc/init.d/rcS` — that specific line is dead code
  for this device, since only 3 partitions actually exist here; it's a leftover
  from a shared script covering other NTX products with more partitions, not a
  sign of hidden partitions on this unit). The `mmcblk1` numbering seen in Section
  2.8 was purely the PC reader's own enumeration, not the device's internal one.
- `etc/fstab` is nearly empty (just `proc`/`devpts`/`tmpfs`) — root/onboard mounts
  happen via hardcoded commands in init scripts, not a real fstab.

### What this means for actually building the Android image
7.4GB total, and Nickel's own layout only needs ~500MB for itself (p1+p2) — Android
needs meaningfully more structure (boot/recovery/system/cache/data/misc, minimum).
The ~6.9GB `KOBOeReader` FAT32 partition is the space to reclaim: it can be shrunk
and split into Android's remaining partitions, keeping p1/p2's sizes as reference
points (256M is roughly in line with what Android's `boot`/`recovery` partitions
need). This is real, concrete partition-planning data now, not a guess — and since
it all comes from a static backup image, the actual repartitioning work can be
designed and tested against a copy of `Kobo.img` on disk before it ever touches a
physical card.

## 2.10 A real, byte-verified, bootable test image now exists (done)

Moved from analysis to an actual build. Summary — full detail is in the session,
key artifacts are on disk:

- **Cross-toolchain**: ARM GNU Toolchain 8.3-2019.03 (`clara-hd/toolchain_old/`)
  — period-appropriate for this ~2016-era kernel. A modern 13.2.1 toolchain
  (`clara-hd/toolchain/`) hits real incompatibilities and was abandoned for
  kernel builds.
- **Two real bugs found and fixed in Kobo's published kernel source**:
  1. `arch/arm/include/asm/compiler.h`'s `__asmeq` macro (GCC PR 15089
     register-allocation paranoia check) trips against modern GCC's legitimately
     different-but-valid register choices — patched to a no-op, the standard fix
     for this well-known old-kernel/modern-toolchain issue.
  2. `drivers/hwmon/mma8x5x.c` (an accelerometer driver) is referenced by the
     Makefile/`.config` but genuinely absent from Kobo's published tarball —
     disabled via `.config` (`CONFIG_SENSORS_MMA8X5X`), not essential for boot.
- **Built a real zImage** (4.3MB, `imx_v7_ntx_defconfig`) and matching **DTB**
  (`imx6sll-e60k02.dtb`, the `ti,tps6518x` variant — matching Section 2.8's
  confirmed real hardware).
- **Found the raw on-disk layout U-Boot actually expects**, straight from
  `board/freescale/common/ntx_comm.c`'s `_load_ntxkernel()`/`_load_ntxdtb()`:
  a 512-byte header (magic `FF F5 AF FF` at byte 496, little-endian size at byte
  504) immediately followed by the payload, at fixed raw sectors:

  | Sector | Contents |
  |---|---|
  | 1 | SN/MAC |
  | 1030 | NTX firmware |
  | 1024/1524 | hwconfig |
  | 1285 (header) / 1286 (payload) | DTB |
  | 1536 | **U-Boot saved environment** (`CONFIG_ENV_OFFSET`, MMC) |
  | 2047 (header) / 2048 (payload) | Kernel |
  | 8192 / 12288 | initrd2 / initrd |
  | 14336 | EPD waveform |
  | 49152 | Partition 1 (`rootfs`) starts |

  Wrote a small reusable tool for this: `kobo-kernel/mk_ntx_image.py`.
- **Read the real, currently-saved U-Boot environment** directly out of
  `Kobo.img` at sector 1536 (not just compiled-in defaults) — confirmed the
  actual live boot flow: `bootcmd` → `load_ntxkernel` → `mmcboot` (sets
  `console=ttymxc0,115200 rootwait rw no_console_suspend`, no `root=`) →
  `load_ntxdtb` → `bootz $loadaddr - $fdt_addr`, **no initrd**.
- **Assembled and byte-verified `Kobo_test.img`**: a disposable working copy of
  the stock backup (never touching `Kobo.img` or the live card) with the new
  kernel+DTB written at the exact verified sectors. Confirmed by reading back:
  correct magic bytes, correct sizes, DTB payload starts with valid `d00dfeed`
  magic, kernel payload starts with a valid ARM zImage header.

**Expected outcome of a first flash**: since `mmcargs` has no `root=`, this will
very likely panic at "VFS: unable to mount root fs" — which is actually the right
thing to see on a first attempt. Reaching that message over serial means the CPU,
UART, kernel decompression, and early EPDC/board init all worked. That's the real
milestone; a working rootfs is next-phase work, not this one.

### What I can't do from here
Flashing `Kobo_test.img` to the spare card and reading serial console output needs
your hands — I have no serial adapter and no root access to raw block devices in
this environment (confirmed earlier: `/dev/sde` is `root:disk`, no passwordless
sudo). Concrete handoff:

```
sudo dd if=/home/enzo/clara-hd/Kobo_test.img of=/dev/sdX bs=4M status=progress
```
(replace `/dev/sdX` with the spare card's actual device node — check with `lsblk`
first, **not** your live postmarketOS card) — then connect a USB-serial adapter to
the board's UART pads at 115200 baud and power on. Whatever appears on that
console is what should come back here next.

## 2.11 A real Android root filesystem is now in the test image (done)

First flash attempt (2.10) produced a real, honest result: white flicker (the
kernel's EPDC driver initializing the panel — U-Boot itself never touches the
panel here, confirmed by reading `ntx_hw_early_init`/`ntx_hw_late_init`, so this
was the kernel actually running) then a power-off, consistent with the predicted
"no `root=`" panic combined with a hardware watchdog armed in U-Boot's
`board_late_init()` before handoff — nothing pets it if the kernel never reaches a
real init. No serial adapter available to confirm directly, so this reasoning is
inference from source, not a log — flagged honestly as such.

Fixed the definite, source-confirmed bug and moved forward rather than waiting on
diagnostics that aren't available:

- **Assembled a real Android root filesystem**: extracted the full `system/` tree
  (324MB) from Tolino's OS44 firmware, merged with the real `init`/`init.rc`/
  `init.E60K00.rc`/fstab from the same firmware's ramdisk — a genuine, combined
  root+system tree, not a stub. Built into a 1GB ext4 image
  (`tolino-fw/android_root.img`) via `mke2fs -d`, verified by mounting and
  confirming `init` (executable) and `system/build.prop` are really there.
- **Written into `Kobo_test.img` at partition 3's exact real offset** (sector
  1097730, replacing the FAT32 `KOBOeReader` content in this disposable test
  copy — `Kobo.img` and the live card remain untouched).
- **Confirmed from the real `init.rc`** that `ro.hardware` (needed to resolve
  `import /init.${ro.hardware}.rc` → `init.E60K00.rc`) isn't set anywhere in
  `build.prop`/`default.prop` — it has to come from the kernel's
  `androidboot.hardware=` cmdline parameter, standard AOSP init behavior for this
  era. This is why the cmdline fix below is load-bearing, not cosmetic.
- **Rebuilt the kernel with a forced cmdline**
  (`CONFIG_CMDLINE_FORCE=y`): `console=ttymxc0,115200 root=/dev/mmcblk0p3
  rootfstype=ext4 rw rootwait androidboot.hardware=E60K00
  androidboot.console=ttymxc0 no_console_suspend init=/init` — guarantees the
  right root device and `ro.hardware` regardless of whatever the saved U-Boot
  environment passes.
- Checked `init.E60K00.rc`: it calls `mount_all /fstab.E60K00`, which references
  separate `/data`, `/cache` etc. partitions that don't exist in this test layout
  (only combined root+system exists right now). `mount_all` logs failures per-entry
  rather than halting init, so this is expected to degrade gracefully (no working
  `/data`) rather than block boot outright — a real gap to close in a later
  iteration, not this one.
- Rewrote the kernel into `Kobo_test.img` at its verified sector, re-verified all
  magic headers and sizes byte-correct.

### Honest expectation for this attempt
This is a genuinely further step than 2.10, not a guaranteed full boot. Realistic
range of outcomes: further visible progress before any failure (more panel
activity, longer delay before reset if reached), through to `init` actually
starting and getting partway through `init.rc` before stalling on the missing
`/data`. Without serial, "how far" will again have to be inferred from timing/visual
behavior — flag anything different from the 2.10 result (different flicker pattern,
longer delay, screen showing anything beyond a plain white flash) as meaningful.

## 2.12 Serial console obtained, real crash found and fixed (done)

Got a UART adapter connected (GND + TX↔RX crossed, 3.3V logic, no power pin
connected) and captured a **complete real boot log** via `cat /dev/ttyUSB0` at
115200 8N1. This is the actual turning point of the whole project — everything
before this was inference from source; this is ground truth.

### What the log confirmed working
U-Boot loads our kernel+DTB from exactly the sectors we wrote (byte-for-byte
match). Our compiled kernel boots for real: `Linux version 4.1.15
(enzo@Ordinateur)...`, our exact forced cmdline echoed back. Ricoh PMIC,
battery/RTC, TPS6518x EPD-PMIC, **touchscreen (cyttsp5, fully operational,
protocol 1.6)**, and **frontlight (LM3630A)** all probe and initialize
successfully. WiFi's SDIO controller gets recognized. Real hwconfig read
(`pcb=74,customer=9`) confirms this is a real, specific hardware revision.

### The actual crash
```
_get_tps6518x():CPU type (91) cannot be recognized !
Unable to handle kernel NULL pointer dereference at virtual address 00000064
PC is at tps6518x_int_callback_setup+0x0/0xc
LR is at mxc_epdc_fb_probe+0x196c/0x1c44
Kernel panic - not syncing: Attempted to kill init!
```
Happens *during kernel boot itself* (a built-in driver initcall,
`mxc_epdc_fb_probe`), well before root mount or `/init` — meaning the "missing
`root=`" theory from Section 2.10 was actually wrong; this is a separate, earlier
bug. It fully explains both prior hardware observations: the white flicker (EPDC
did start initializing before crashing) and the endless blink-loop (a
deterministic crash → U-Boot's watchdog resets → identical crash again, forever).

### Root cause, found in source
`arch/arm/mach-imx/common.c`, `ntx_parse_cmdline()` — the fallback taken when
`hwcfg_p=`/`hwcfg_sz=` aren't on the kernel cmdline (true for our boot, and
apparently true for *any* non-manufacturing-mode boot — this code path is only fed
those params inside `#ifdef CONFIG_MFG`):
```c
if (NULL == gptHWCFG) {
    gptHWCFG = (NTX_HWCONFIG *)kmalloc(sizeof(NTX_HWCONFIG), GFP_KERNEL);
    gptHWCFG->m_val.bTouchCtrl = 8;
}
```
**`kmalloc` doesn't zero memory.** Only `bTouchCtrl` is set — every other field,
including `bCPU`, is left as whatever garbage was already in that heap allocation.
"CPU type (91)" isn't a real value, it's uninitialized memory. A genuine bug in
Kobo's own published kernel source, not something introduced by our changes.

### The fix
U-Boot's own boot log printed `hwcfgp=9ffffe00` — it already loads the real
hwconfig into RAM at `0x9ffffe00` on every boot, it just doesn't always tell the
kernel via cmdline outside MFG mode. The `CONFIG_MFG` code path confirmed the
exact parameters (`hwcfg_p=0x9ffffe00 hwcfg_sz=110`). Added those to our forced
`CONFIG_CMDLINE` — makes the kernel read the real, already-loaded hwconfig data
instead of falling into the broken uninitialized-`kmalloc` path. No kernel source
patch needed, just a cmdline fix. Rebuilt, rewrote into `Kobo_test.img` at the
verified sector, confirmed byte-correct.

**If this specific crash recurs on the next boot**, the real (more invasive) fix
is patching `ntx_parse_cmdline()` directly: `kzalloc` instead of `kmalloc`, and
explicitly set `bCPU=10` (confirmed correct for real i.MX6SLL hardware throughout
this whole investigation) — not yet applied, held in reserve to avoid stacking
untested changes.

## 2.13 EPDC/hwconfig crash fully resolved; kernel now reaches root-mount stage (done)

Second bug found via the same "TX/RX swapped, wires reseated" UART connection: the
`hwcfg_p=`/`hwcfg_sz=` fix from 2.12 was being read (`hwcfg_size_setup()` ran), but
`_MemoryRequest(): request memory region failed! addr=9ffffe00, len 110` — the
kernel was using the *entire* 512MB of RAM as general-purpose memory, and that
address sits right at the very top of it, already claimed before this code runs.
Fix, taken directly from Kobo's own `CONFIG_MFG` precedent
(`board/freescale/mx6sll_ntx/ntx_comm.c`): append `mem=500M`, deliberately leaving
the last ~12MB of RAM unclaimed by the general allocator so this scratch region
stays free. Added to `CONFIG_CMDLINE`, rebuilt, reflashed.

**Result: complete success on this front.** Real hwconfig now loads
(`hwcfg_p_setup() ... pcb=0x4a` = 74 decimal, matching U-Boot's own reading
exactly). EPDC now reports the **correct real panel resolution**
(`EPD 1448x1072`, vs. the garbage `1600x1200` before) and correctly identifies the
right waveform firmware file for this panel
(`epdc_PENG060D.fw` vs. the wrong `epdc_R031_PENG078F01.fw` before). No crash —
the missing-firmware-file fallback path now runs cleanly instead of hitting the
NULL-pointer Oops. WiFi power control, RTC, battery, PMICs — everything continues
initializing normally. Boot reaches real MMC/partition detection matching our
actual disk exactly (`mmcblk0p1/p2/p3`, disk ID `c73009d9` matching `Kobo_test.img`
precisely).

### New failure, further along than ever
```
No filesystem could mount root, tried:  ext4
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(179,3)
```
Correctly targets `mmcblk0p3` (matches `root=`), `CONFIG_EXT4_FS=y` confirmed
built-in (not a module — checked, since there's no initrd to load one anyway).
Root cause: `tune2fs -l` on our built filesystem image showed
`64bit`, `metadata_csum`, `metadata_csum_seed` — modern ext4 features from a 2025
`mke2fs` that a 2015-era (4.1.15) kernel's ext4 driver doesn't understand, so it
silently rejects the filesystem as unrecognized. Rebuilt with
`mke2fs -O ^has_journal,^metadata_csum,^64bit,^metadata_csum_seed` — confirmed
clean feature set via `tune2fs -l` — rewrote into `Kobo_test.img` at the same
sector, verified by mounting read-only (`init`, `system/build.prop` both present
and readable).

## 2.14 Real Android init executes on real hardware (milestone)

The ext4-feature fix from 2.13 worked completely:

```
EXT4-fs (mmcblk0p3): mounted filesystem without journal. Opts: (null)
VFS: Mounted root (ext4 filesystem) on device 179:3.
devtmpfs: mounted
Freeing unused kernel memory: 364K (80741000 - 8079c000)
init (1): /proc/1/oom_adj is deprecated, please use /proc/1/oom_score_adj instead.
init: could not open /dev/keychord
init: cannot open '/initlogo.rle'
init: Battery Capacity [0] USB [0] ADC [0x8000]
init: Battery Critical Low
ntx_system_poweroff() ---POWER_OFF_COMMAND poweroff ---
Kernel---Power Down ---
```

**Root filesystem mounts. `init` (PID 1) — the real Tolino/Netronix Android init
binary — actually executes, on real hardware, for the first time in this entire
project.** Two harmless warnings (`/dev/keychord`, `/initlogo.rle` both missing —
cosmetic, not fatal), then a **clean, intentional, graceful shutdown**: init reads
real battery state (`Battery Capacity [0]`), computes 0% via the PMIC's fuel-gauge
curve (measured voltage 3.48V is below the OCV table's own 0%-reference point of
3.59V, per Section 2.12's log), and deliberately powers off rather than risk a
half-charged boot — there's even a real "please charge" splash
(`/rle/hdpi_powerlow.rle`, also missing from our rootfs, harmless) init tries to
show first. This is designed behavior from the real init binary, not a bug.

This retroactively explains the earlier "blinking light forever" observation
(Section prior to 2.12's fix): that was the *crashing* build's watchdog-reset loop.
This build doesn't crash at all — it reaches real userspace and shuts down
cleanly. The only remaining blocker to seeing actual further Android boot
progress is battery charge, not anything in the image.

### Next
Charge the device properly (disconnect UART while charging, per Section 2's
established caution about running both simultaneously), then retry with the same
`Kobo_test.img` — no rebuild needed, this exact image is good. With real charge,
`init` should proceed past the battery check into actual Android service startup
— genuinely uncharted territory for this project from here.

## 2.15 Battery charged past threshold; real permission bug found and fixed (done)

With the battery actually charged (27%, well past the critical-shutdown point from
2.14), `init` proceeded much further — and hit a single root-cause bug that was
blocking essentially all of real Android userspace:

```
init: skipping insecure file '/system/build.prop'
init: cannot execve('/system/bin/servicemanager'): Permission denied
init: cannot execve('/system/bin/sh'): Permission denied
init: cannot execve('/system/bin/vold'): Permission denied
init: cannot execve('/system/bin/surfaceflinger'): Permission denied
init: cannot execve('/system/bin/app_process'): Permission denied
... (every core Android service, same error)
```

Checked directly: `ls -la .../system/bin/servicemanager` showed `-rw-rw-r--` —
**zero execute bits, on every file.** `unzip` extracting `update_os44.zip` didn't
preserve Android's real Unix permissions (the OTA package format doesn't rely on
the zip's own stored bits — Android's real build/flash tooling applies permissions
separately from `META/filesystem_config.txt` and `META/boot_filesystem_config.txt`,
which we'd extracted earlier but never actually used). Zero execute bits means
even root can't run these — a pure Linux permission-bit problem, not a uid/gid
one, so fixable entirely as a normal user (no root needed, we own the files).

Wrote `tolino-fw/apply_fs_config.py`: parses both config files
(`path uid gid mode selabel=... capabilities=...`) and `chmod`s every
corresponding file/dir in `android_root/` to its real mode. Applied to 1178 paths
(only 1 referenced path absent — expected, we don't have the complete system).
Verified: `servicemanager` now `-rwxr-xr-x` (755), `build.prop` now `-rw-r--r--`
(644, no group-write — this is also what should clear the "insecure file" check,
which flags group/other-writable system files). Rebuilt the ext4 image, rewrote
into `Kobo_test.img`, verified permissions landed correctly in the final image via
loop-mount readback.

Also confirmed independently working in this same boot: `fs_mgr: Cannot mount
filesystem on /dev/block/mmcblk0p5 at /system` — expected, matches the
already-documented gap (Section 2.9/2.11) that our simplified 3-partition layout
doesn't have the separate `/system`/`/data`/`/cache` partitions the real
`fstab.E60K00` expects; init degrades gracefully past this rather than halting,
exactly as anticipated.

### Next
Reflash `Kobo_test.img` with a charged battery and UART connected — this is the
first attempt where the core Android services have a real chance to actually
start, not just fail to exec.

## 2.16 Permission fix confirmed working; healthd crash-loop worked around (done)

Reflash with charged battery + permission fix (2.15) confirmed a real, major
win: **a shell prompt actually appeared** (`root@ntx_6sl:/ #`) — `/system/bin/sh`
executed successfully, meaning the exec-permission fix worked completely, not
partially.

New blocker: `init: critical process 'healthd' exited 4 times in 4 minutes;
rebooting into recovery mode`, followed by an infinite `ntx_machine_restart
mode=...,cmd=recovery` loop — the reboot-to-recovery safety net itself can't
complete, since our simplified partition layout has no real bootable recovery
image on `ntxrecovery` (p2). `healthd` (statically linked, no missing shared
libs) scans `/sys/class/power_supply` for battery attribute files at startup;
exactly which ones it needs and why it's exiting isn't visible in `init`'s terse
"pid exited" logging (no stdout/logcat captured). Investigating further would
need more infrastructure than we have right now.

Pragmatic fix instead: `healthd`'s job (battery UI/monitoring) isn't required for
the rest of Android to boot. Removed the `critical` flag from both `healthd` and
`healthd-charger` service stanzas in `init.rc` — repeated failure no longer
triggers the reboot-loop, letting boot continue toward the actually-important
services (zygote, surfaceflinger) instead. Rebuilt, rewrote into `Kobo_test.img`.

## 2.17 Binder was never actually enabled in our kernel build (found and fixed)

With the healthd workaround in place and the battery charging, boot got much
further — well past healthd this time — before hitting a new critical-process
crash loop, now on **`servicemanager`**:
```
init: critical process 'servicemanager' exited 4 times in 4 minutes; rebooting into recovery mode
```
Same broken reboot-to-recovery safety net as before (no real recovery partition,
so it spins on `ntx_machine_restart` forever rather than actually resetting —
confirmed this capture never shows a second `U-Boot 2016...` banner, so it's a
tight software loop, not repeated hardware reboots).

servicemanager is the core Binder registry — far more central than healthd, so
instead of just disabling `critical` again, actually root-caused it. Checked
`.config` directly: **`CONFIG_ANDROID_BINDER_IPC` was never enabled at all** —
not even present as a `# ... is not set` line, genuinely absent. Same for
`CONFIG_ANDROID` (the top-level gate for both `drivers/android/` and
`drivers/staging/android/`), `CONFIG_ASHMEM`, and
`CONFIG_ANDROID_LOW_MEMORY_KILLER`. This corrects an error earlier in this
document (Section 2.5) — confirming the *source code* for these subsystems
exists in Kobo's kernel tree is not the same as confirming our *build* actually
enables them, and it turns out it didn't. `imx_v7_ntx_defconfig` (Nickel/Linux
target, not Android) simply never turns any of this on, and nothing in this
project's work so far had explicitly enabled it either. Without
`CONFIG_ANDROID_BINDER_IPC`, `/dev/binder` never exists, so `servicemanager`'s
very first action (opening it) fails immediately and unconditionally — fully and
directly explains the crash, independent of anything else (including, per a
reasonable question raised and directly checked: independent of USB/charging
state, which has no relationship to a compile-time kernel config).

Fix: added `CONFIG_ANDROID=y`, `CONFIG_ANDROID_BINDER_IPC=y`, `CONFIG_ASHMEM=y`,
`CONFIG_ANDROID_LOW_MEMORY_KILLER=y`, `CONFIG_SYNC=y`, `CONFIG_SW_SYNC=y` to
`.config`, resolved dependencies via `make olddefconfig`, rebuilt, rewrote into
`Kobo_test.img` at the verified sector.

## 2.18 servicemanager's actual crash reason still unknown; unblocking for interactive debugging instead

With binder genuinely enabled (2.17), boot progressed further and the binder
driver itself is confirmed working (`binder: 78:78 transaction failed 29189...` —
decoded: `29189 = _IO('r',5) = BR_DEAD_REPLY` exactly, meaning other processes are
correctly getting "target dead" trying to reach handle 0, the reserved
servicemanager handle — the driver is functioning correctly, servicemanager
itself is what's dying). Ruled out several candidate causes directly rather than
guessing:
- SELinux: `CONFIG_SECURITY_SELINUX` isn't even compiled in, so
  `security_binder_set_context_mgr()` is a no-op. Not the cause.
- Not a segfault/Oops: grepped the full log for any kernel-logged userspace fault
  message for servicemanager — none. It's exiting cleanly, not crashing.

Tried getting `servicemanager`'s own stdout by running it manually from the
console shell that briefly appears (`root@ntx_6sl:/ #`) — via writing directly to
`/dev/ttyUSB0` while a background reader captured output, timed to land during
boot. Timing this against a live power-on proved impractical: the shell prompt
and the crash are only ~1-2 seconds apart in the log, too narrow a window to hit
reliably with a fixed delay. (Also hit and fixed a real mistake along the way: two
`cat /dev/ttyUSB0` readers running simultaneously — a leftover injection attempt
plus a fresh capture — produces visibly garbled/corrupted log output, character
interleaving between the two processes. Always confirm nothing else is attached
via `ps`/`fuser` before starting a new capture.)

Pragmatic fix instead of continuing to fight the timing: removed `critical` from
`servicemanager`'s service stanza too (same pattern as 2.16's `healthd` fix).
Doesn't fix the underlying crash, but stops it from triggering the broken
reboot-to-recovery loop — the device should now sit in a stable, non-looping
state indefinitely even with servicemanager failing, giving unlimited time to use
the console shell interactively (manually run `/system/bin/servicemanager` to see
its real output, check `ls -la /dev/binder`, etc.) instead of racing a ~1-2 second
window.

## 2.19 servicemanager investigation: current honest state, and a UART-free logging path

### What's confirmed working, end to end, on real hardware
U-Boot → kernel (with correct hwconfig/EPDC/mem=500M) → root mount → real `init`
(PID 1) → exec permissions correct → binder/ashmem/lowmemorykiller genuinely
compiled in and functioning (`ashmem: initialized`, real binder driver messages) →
device reaches a **stable, non-looping state indefinitely** (both `healthd` and
`servicemanager` had `critical` removed from their service stanzas, so repeated
respawn failures no longer trigger the broken reboot-to-recovery loop). Confirmed
alive and staying alive via live `ps`: `ueventd`, `watchdogd`, the console `sh`,
**`vold`**, **`debuggerd`**, **`logwrapper`**. This is a real, substantial, working
Linux/Android-userspace boot on real Clara HD hardware.

### What's still unresolved: servicemanager (and everything depending on it)
`servicemanager` — and by extension `surfaceflinger`, `zygote`/`app_process`, and
the rest of core Android — never stays alive. Ruled out directly rather than by
guessing:
- **Not SELinux**: `CONFIG_SECURITY_SELINUX` isn't compiled in at all; the
  `security_binder_set_context_mgr()` hook is a no-op.
- **Not a segfault**: no kernel-logged userspace fault message anywhere in any
  capture. It exits cleanly.
- **Binder itself works**: manually running `/system/bin/servicemanager` from the
  console shell (as root, not the `system` uid init actually uses) hit
  `BINDER_SET_CONTEXT_MGR bad uid 0 != 1000` — meaning **some earlier,
  correctly-uid-1000 invocation already successfully registered as context
  manager**. The registration step itself works; something after that, or on
  later respawns, doesn't.
- **Not a timing/visibility artifact**: sent `ps` repeatedly over a full minute
  (every 10s, 6 snapshots) via direct serial writes while the device sat in its
  stable state — `servicemanager` never appeared in any snapshot, even
  momentarily. Meanwhile `init: untracked pid N exited` kept happening
  continuously (17 times in that same window) — something is still forking and
  dying fast, but no longer as a *named* service init reports on the same way it
  did earlier (`critical process 'servicemanager' exited...`).

**Real diagnostic limitation reached**: answering this needs either `strace`, a
way to actually run a test process as uid 1000 (no `su`-equivalent available in
this minimal image), or real `logcat` output (present as a binary, but depends on
`logd`, which itself needs the same infra that isn't fully working) — none of
which are available yet. Not a dead end, but the next step needs new tooling, not
more log-reading.

### UART reliability, honestly assessed
Live serial capture-and-inject debugging hit real, repeated friction this
session: overlapping readers on `/dev/ttyUSB0` producing garbled output (fixed by
always checking `ps`/`fuser` before starting a new capture), and blind
sleep-timed command injection proving unreliable — the window between the console
shell appearing and the next crash/log-flood was often only 1-2 seconds, far
too narrow to hit consistently from a script with no visibility into the live
stream. Switching to the user driving `screen` interactively worked better but
introduced its own issue: `screen`'s lack of scrollback means any stray
keystroke (e.g. trying to scroll up) gets sent as literal input to the Kobo's
shell, corrupting its parser state (`> ` continuation prompts). Recoverable with
`Ctrl+C`, but fragile.

### The actual fix: log to the SD card instead of fighting UART live
Added a new `bootlogger` service to `init.rc`:
```
service bootlogger /system/bin/sh -c "i=0; while true; do i=$((i+1)); echo ===TICK $i $(date)===; ps; dmesg -c; sleep 3; done >> /bootlog.txt 2>&1"
    class core
    user root
    group root
    oneshot
```
Every 3 seconds, appends a full `ps` snapshot and the kernel log since the last
read (`dmesg -c` — clears after reading, so nothing gets lost to ring-buffer
overflow and nothing gets duplicated) to `/bootlog.txt` on our own writable root
partition. Confirmed `dmesg`, `ps`, `date`, and a real `/system/bin/sh` are all
present and working — every piece this depends on is already proven functional
from this session's live testing.

**This makes UART optional going forward.** New workflow: flash `Kobo_test.img`,
power on, let it sit for a minute or two (no serial connection needed at all),
power off, pull the microSD card, mount `/dev/sdX3` (or loop-mount the image
directly, same technique used throughout this document) read-only on this
machine, and read `/bootlog.txt` directly — a complete, high-resolution, gap-free
timeline of exactly what's running and what the kernel logged, with none of the
live-capture timing/corruption problems. This should be the primary diagnostic
tool from here on; UART stays available as a fallback for anything that happens
*before* root mount (where `/bootlog.txt` obviously can't help).

## 2.20 bootlogger silently broke everything after it — real bug, real fix

First `bootlogger` attempt (2.19) produced a genuinely useful negative result:
`/bootlog.txt` never existed on the card at all — not even empty — after letting
the device sit for minutes. Ruled out power-cut/unsynced-write loss directly:
other files/directories created live during that same boot (`acct`, `cache`,
`config`, etc., all timestamped from the live RTC) persisted fine, so the
filesystem itself was reliably durable; the issue was `bootlogger` never actually
running.

First fix attempt (separate script file instead of inline `sh -c "..."`, to avoid
any old-init tokenizer/quoting issues) didn't fix it either — confirmed via one
more UART boot specifically to check. That capture revealed something much more
important than the original question: **`healthd` and `servicemanager` were
completely absent from the log too — not crashing, never mentioned at all**,
unlike every single capture before this point. Root cause: `bootlogger` had been
inserted *directly before* `healthd`'s definition in `init.rc`. Whatever is wrong
with our entry's parsing most likely aborts init's parsing of the rest of the
file from that point on — explaining both symptoms at once (bootlogger never
starts, and everything textually after it in the file — healthd, servicemanager,
and possibly more — silently stops being recognized too).

Fix: moved the `bootlogger` service definition to the **very end** of `init.rc`
(after everything else, including the last real service `hide_folders`) instead
of interleaved among the real services. Also changed its class from `core` to
`main` in the process (services below it in the file are `main`-class; matching
that grouping). Rebuilt, rewrote into `Kobo_test.img`.

**Open question this directly tests**: was the "servicemanager keeps dying"
investigation (2.18-2.19) partly chasing a symptom of *this* bug rather than (or
in addition to) a genuine servicemanager-specific issue? If placing `bootlogger`
at the end restores `healthd`/`servicemanager` to their previously-observed
behavior (named, respawning, eventually reported by name) *and* produces a real
`/bootlog.txt`, that's the answer. Next boot (with UART still connected, to check
both things at once before going back to card-based logging) will tell.

## 2.21 Enabling ADB over USB — a real alternative to UART

Real USB gadget/ADB support exists in this image and is fully wired, just
disabled by default. Checked directly:
- `/sbin/adbd` present, correct permissions.
- `service adbd` in `init.rc` is `disabled` (must be triggered explicitly) —
  standard Android pattern, "controlled via property triggers in
  `init.<platform>.usb.rc`".
- `init.E60K00.usb.rc` has `on property:sys.usb.config=mass_storage,adb` →
  configures the USB gadget and calls `start adbd`. The generic
  `init.usb.rc` also has a simpler `on property:sys.usb.config=adb` path using
  **Google's own standard USB vendor/product IDs (`18d1:D002`)** — the ones any
  stock `adb` install already recognizes with no custom udev rules needed.
- But `persist.sys.usb.config=mass_storage` (no adb) was the default, and the
  mechanism that normally mirrors `persist.sys.usb.config` → the runtime
  `sys.usb.config` property lives in the Android framework's `UsbService` —
  which never runs, since `system_server`/zygote never start. The trigger would
  never fire on its own.

Fix: `default.prop` values are loaded directly as initial property state at
boot, independent of any userspace service. Set `sys.usb.config=adb` directly
there (bypassing the broken mirroring path entirely), plus `ro.secure=0` and
`ro.debuggable=1` (unauthenticated root adb — this build was set up as a
production-like secure build by default, which would otherwise require RSA key
exchange even if adbd started). Rebuilt, rewrote into `Kobo_test.img`.

**Why this matters**: if it works, `adb shell` gives a real, robust, bidirectional
shell I can drive directly from this machine via Bash — no baud rate framing, no
blind-timing command injection, no `screen` scrollback corruption. This single
test image also carries 2.20's `bootlogger`-placement fix, so this boot checks
three things at once: does `healthd`/`servicemanager` return to previous
behavior, does `/bootlog.txt` finally get written, and does `adb devices` show
the device from this machine (needs an actual USB **data** cable to the Kobo's
own port, not just the SD-card reader).

## 2.22 bootlog.txt still missing after repositioning; isolating with two parallel tests

Moving `bootlogger` to the end of `init.rc` (2.20) did **not** fix it —
`/bootlog.txt` still absent after this boot too. Checked whether `class main`
(what the repositioned service uses) is actually reached: it's under `on boot`
at line 313, `class_start core`/`class_start main` both fire unconditionally at
line 452-453, not gated behind `vold.decrypt` or any condition our simplified
partition layout would fail to satisfy. So the class/position theory isn't fully
explaining this either.

Two genuinely useful things surfaced while checking this, unrelated to the
logger bug itself:
- **`setprop ro.adb.secure 1`** — a separate property from `ro.secure` that also
  forces RSA key auth for adb. Relevant if USB/ADB gets revisited later (2.21) —
  our `ro.secure=0` fix wouldn't have been sufficient on its own.
- **`setprop system_init.startsurfaceflinger 0`** — surfaceflinger is
  **explicitly disabled** here, not crashing. Reframes part of the 2.18/2.19
  servicemanager investigation: at least surfaceflinger's absence from every
  `ps` listing was expected behavior, not a symptom of the same failure.

Given repositioning alone didn't resolve it, isolating with two independent,
maximally-simple tests in parallel rather than guessing further:
1. Stripped `bootlogger.sh` down to one line (`echo hello_from_bootlogger >
   /bootlog.txt`, no loop, no arithmetic, no command substitution) — tests
   whether the *service* launches at all, independent of any script content bug.
2. Added a direct `write /bootlog_write_test.txt hello_from_write_builtin` in
   `init.rc`'s `on boot` block itself — a built-in action (used successfully
   dozens of times elsewhere in this exact file for `/proc/...` paths), not
   dependent on service/fork/exec machinery at all.

If only the `write` file appears: the problem is specifically about service
launching (fork/exec, permissions, or the `service` stanza itself). If neither
appears: something more fundamental is blocking new file writes to this
partition during boot specifically (despite `mkdir`-created directories
persisting fine in earlier tests — worth re-checking that assumption too). If
both appear: the original multi-line script's own syntax was the real bug all
along.

## 2.23 Neither test file appeared — narrowed further, one more targeted change

Neither `/bootlog.txt` (service) nor `/bootlog_write_test.txt` (init.rc
built-in `write`) appeared after 2.22's boot. The `write` result turned out to
be less conclusive than intended — older Android init's `write` built-in
typically only writes to *existing* files/device nodes (no `O_CREAT`), which
would explain every other successful use of it in this file being against
`/proc/...` paths that already exist. So that test mostly confirms `write`
itself can't create new files, not much else.

The real remaining signal: our service (`echo hello > /bootlog.txt`, shell's
`>` redirect, which absolutely does create new files — completely standard,
about as simple as a script can get) still didn't run. Checked `vold`'s
definition for comparison (`class core`, no `user`/`group` line at all,
demonstrably working) against ours (explicit `user root` / `group root`) —
matches the same pattern as `healthd`/`ueventd`/`watchdogd`, all of which omit
user/group and default to root implicitly. Our explicit `user root` line is the
one real structural difference between our service and every working one.
Removed it (now just `class main` + `oneshot`, matching the working pattern
exactly) as the next targeted test.

## 2.24 Real root cause found: init remounts our entire filesystem read-only

The actual answer, after four rounds of narrowing (2.19-2.23): `init.rc`'s
`on post-fs` stage runs
```
mount rootfs rootfs / ro remount
```
This is completely standard, correct Android practice — on a normal layout the
root is a tiny initramfs, remounted read-only since nothing needs to write to
it once `/system` and `/data` (separate real partitions) take over. **We merged
root+system into one single combined ext4 partition** for this whole project
(Section 2.6 onward), so this exact same standard command remounts our *entire*
filesystem read-only — not a harmless few-KB ramdisk, everything. This runs
early (`on post-fs`), well before `on boot`/service startup, which is exactly
why earlier `mkdir`-created directories persisted fine (created even earlier, at
`on init`) while every later write attempt — the original inline script, the
repositioned service, the simplified one-liner, and the `write` built-in test —
all failed silently the same way, regardless of which specific mechanism was used.

This retroactively clears the `bootlogger`-position theory from 2.20 as a red
herring — moving it in the file never had a chance of fixing this, and likely
also means the earlier apparent disappearance of `healthd`/`servicemanager` from
that one capture (2.19) was probably an unrelated fluke, not caused by our
insertion position after all.

Fix: commented out that one line. Restored the full-featured looping
`bootlogger.sh` (tick counter, `ps` + `dmesg -c` every 3s, `sync` after each
write) now that the actual blocker is resolved. Rebuilt, rewrote into
`Kobo_test.img`.

## 2.25 The real bootlog, and the biggest result of the project so far

With the read-only-remount bug (2.24) actually fixed, `/bootlog.txt` finally
persisted for real: 967KB, 239 ticks (~12 minutes) of continuous `ps` + `dmesg`
snapshots. (Read via `sudo cat ... > ~/bootlog_copy.txt` — the card was mounted
`-o ro` on this end, so even `chmod` as root couldn't touch it; copying out
bypassed that entirely.)

**At tick 37 (~1:51 into boot), every core Android service was alive
simultaneously**: `servicemanager`, `surfaceflinger`, `netd`,
`app_process` (zygote), `drmserver`, `mediaserver`, `keystore`, `healthd` — the
fullest, healthiest boot state reached in this entire project. They do not
survive: by tick 38, three seconds later, all gone, back to the familiar
`binder: ... target dead` churn. They never return for the remaining ~10
minutes of capture — this **is** a fast, cascading failure, not services
crashing independently over time.

Two concrete new clues right at the transition, in the last dmesg lines of tick
37:
```
binder: 488:488 got new transaction with bad transaction stack, transaction 50 has target 489:0
binder: 488:488 transaction failed 29201, size 120-4
```
PID 488 = `healthd`, PID 489 = `servicemanager`. `"bad transaction stack"` is a
**different, more specific binder-driver-level error** than anything seen
before (not "target dead", not a uid mismatch — an actual transaction-stack
consistency fault). Simultaneously, the same tick's `ps` shows **PID 497, a
zombie process named `iptables`, parented by PID 490 (`netd`)** — `netd`
commonly shells out to `iptables` during its own init to set up firewall rules;
if that fails in our minimal environment (no real netfilter/iptables setup),
it's a plausible destabilizing factor, though not confirmed as the root trigger.
Checked and ruled out: no OOM-killer activity anywhere in the log (only 500MB
RAM, first time the full stack ever ran together, so this was a real
possibility — `grep`'d for "out of memory"/"oom"/"low on memory", nothing).

**This settles an open question from 2.20-2.23**: the entire `bootlogger`
placement/permission saga was chasing a real, separate, now-fixed bug (2.24),
not the servicemanager issue itself. It's also plausible some of the earlier
"servicemanager never appears" observations (2.18-2.19) were partly caused by
the *same* read-only-filesystem bug indirectly (services failing to write
things they need during their own startup), on top of whatever causes this
specific cascading die-off — both are real, now-partially-understood factors
rather than one single mystery.

### Where this leaves things
Real, substantial progress: full stack proven capable of starting together.
Remaining question narrowed from "why does nothing work" to a specific,
few-second window with two concrete leads (`netd`/`iptables`, and a
binder-driver-internal `bad transaction stack` fault). Answering it further
would benefit from tools beyond what's available here — `strace` on `netd`
specifically, or binder driver debug tracepoints (`CONFIG_ANDROID_BINDER_IPC`
has an optional debug/tracing layer not currently enabled) — a reasonable place
to pause and consolidate rather than keep guessing blind.

## 2.26 netfilter genuinely absent from the kernel — same pattern, another fix

Followed up the `netd`/`iptables` zombie lead from 2.25 directly. Confirmed
`iptables` and `ip6tables` both exist as valid ARM binaries in our rootfs (ruled
out "missing file"). Checked what `netd` actually needs by grepping strings in
the binary: `filter`, `mangle`, `raw` tables, `MASQUERADE`, `REJECT`, `owner`,
`state` — standard Android per-UID network accounting/firewall setup.

Checked the kernel: **`CONFIG_NETFILTER` is not set at all** — zero netfilter
support compiled in. Exact same pattern as binder/ashmem (2.17) and the USB
gadget driver (2.21): a kernel subsystem Android's userland assumes exists,
absent because the base `imx_v7_ntx_defconfig` (Nickel/Linux target) never
needed it. Without any netfilter support, `iptables` fails immediately trying to
talk to nonexistent kernel infrastructure — fully consistent with the zombie
child process observed.

Enabled a comprehensive set covering everything `netd` actually references:
`NETFILTER`, `NETFILTER_XTABLES`, `XT_MATCH_OWNER`/`STATE`/`CONNTRACK`,
`XT_TARGET_REJECT`/`MASQUERADE`, `NF_CONNTRACK`(+IPV4), `NF_NAT`(+IPV4), the
`IP_NF_*` IPv4 table/target set (`IPTABLES`, `FILTER`, `MANGLE`, `RAW`,
`TARGET_REJECT`, `TARGET_MASQUERADE`, `NAT`), and IPv6 equivalents
(`IP6_NF_*`) since `ip6tables` exists too. Rebuilt, rewrote into
`Kobo_test.img`.

**Not yet confirmed this is the actual cascade trigger** — it's the most
concrete, checkable lead found so far (a real, structural gap matching this
session's dominant bug pattern exactly), but whether fixing it actually
prevents the tick-37 die-off, versus just removing one contributing factor
among others, is what the next boot's `/bootlog.txt` will show.

## 2.27 First direct display test — bypassing Android's graphics stack entirely

Paused the servicemanager cascade investigation to try getting the physical
e-ink panel to actually show something — this doesn't need Android's IPC/binder
stack at all, just the kernel's EPDC driver directly, so it should work
independent of whatever's still killing the service stack.

Confirmed the exact userspace interface from the kernel source
(`include/uapi/linux/mxcfb.h`, and checked `mxc_epdc_v2_fb.c`'s ioctl handler
directly to confirm which struct variant our specific driver actually expects —
all the named `MXCFB_SEND_UPDATE*` variants funnel into the same modern
`struct mxcfb_update_data`). Wrote a minimal, self-contained C program
(`fbtest.c`): opens `/dev/graphics/fb0`, reads real geometry via
`FBIOGET_VSCREENINFO`/`FBIOGET_FSCREENINFO`, `mmap`s the framebuffer, fills it
with a high-contrast stripe pattern, and calls `MXCFB_SEND_UPDATE` (full-screen,
`WAVEFORM_MODE_AUTO`, `UPDATE_MODE_FULL`) to force a real panel refresh.

Cross-compiled statically with our existing ARM toolchain
(`toolchain_old/bin/arm-linux-gnueabihf-gcc`) — used the toolchain's own bundled
`linux/fb.h` rather than the raw kernel uapi tree (which needs `make
headers_install` to be userspace-safe), and only pulled in `mxcfb.h` itself
(the one genuinely vendor-specific header) via a small local include dir.
Stripped to 414KB.

Added to the rootfs as `/fbtest`, wired up as a new `class core`, `oneshot`
service at the end of `init.rc` (matching the position/pattern established as
safe in 2.20-2.24) — runs automatically at boot, no interaction needed, and
`class core` starts early enough that it shouldn't depend on anything from the
still-fragile `main` class. Rebuilt, rewrote into `Kobo_test.img`.

## 2.28 Real error, real waveform data extracted, and a concrete theory

Fixed a real gap first: `fbtest` (2.27) had no stdout/stderr capture (services
don't redirect by default), so its first run was invisible. Wrapped it in
`fbtest.sh` (`> /fbtest_output.txt 2>&1`), same lesson as `bootlogger`.

Real result this time: `open()`, `mmap()`, and the geometry ioctls all
succeeded — confirmed real panel geometry (`1448x1072, 16bpp`) — but
`MXCFB_SEND_UPDATE: Operation not permitted` (EPERM). Traced to the exact
kernel check: `mxc_epdc_v2_fb.c`'s `mxc_epdc_fb_send_single_update()` returns
`-EPERM` if `!fb_data->hw_ready`, printing the same `"Display HW not properly
initialized"` message seen in earlier full boot logs. Checked every place
`hw_ready` is touched in the driver — **it's only ever set `true` at the tail of
successfully processing a real waveform firmware file** (right after
`release_firmware(fw)`, using data read from it to configure `waveform_is_advanced`
and run `epdc_init_sequence()`). No alternate path, no built-in default table.
The `fake_s1d13522` fallback (triggered because `epdc_PENG060D.fw` was never
found) genuinely never reaches this code at all — confirms the theory from 2.27.

Went looking for the real firmware file directly rather than guessing further.
Checked Kobo's own stock `Kobo.img` rootfs — no `epdc_PENG060D.fw` there either,
and no firmware-helper script (`firmware.sh`) despite the necessary udev rule
being present, meaning Nickel's own kernel likely never uses the generic
Linux firmware-file mechanism for this either. Confirmed the real path: U-Boot
loads a "waveform" blob into RAM from raw sector 14336 (`SD_OFFSET_SECS_WAVEFORM`)
on **every single boot** we've captured this whole session — real data,
sitting right there, just never consumed by our kernel driver.

Found the exact expected filename/path from the driver source itself
(`request_firmware_nowait(...)`, format `"imx/epdc/epdc_[panel string].fw"`) and
confirmed the real search convention already used by other firmware in this
build (`/system/lib/firmware/wc121/...` for WiFi). Extracted the raw waveform
blob directly from `Kobo.img` at the known sector (`dd skip=14336 count=5247`,
2,686,464 bytes — real, structured binary data, not zeros/garbage). Placed it at
both `/system/lib/firmware/imx/epdc/epdc_PENG060D.fw` and the plain
`/lib/firmware/imx/epdc/epdc_PENG060D.fw` (kernel's default search path) to
cover both candidate locations without needing to trace the exact search order
further. Rebuilt, rewrote into `Kobo_test.img`.

**Not yet confirmed working** — this is a strong, well-evidenced theory (real
waveform data, from the exact known-good source, at the exact expected path),
but whether the driver's internal validation accepts this particular extraction
(header checks, `WAVEFORM_HDR_LUT_ADVANCED_ALGO_MASK` etc.) is untested until
the next boot.

## 2.29 Wrong search path — Android's ueventd doesn't use generic Linux firmware paths

2.28's placement (`/system/lib/firmware/...`, `/lib/firmware/...`) produced no
visible change. Checked directly rather than guessing again: `strings` on our
actual `/sbin/ueventd` binary reveals its real, hardcoded firmware search paths:
`/etc/firmware/%s`, `/vendor/firmware/%s`, `/firmware/image/%s` — **Android's
ueventd has its own built-in firmware-loading convention, completely different
from generic Linux udev's `/lib/firmware/`.** Neither path we'd used matches any
of these.

Given `/etc` → `/system/etc` and `/vendor` → `/system/vendor` are both symlinked
early in `init.rc`, placed the same extracted waveform blob (2.28) at both
`/system/etc/firmware/imx/epdc/epdc_PENG060D.fw` and
`/system/vendor/firmware/imx/epdc/epdc_PENG060D.fw` for redundancy. Rebuilt,
rewrote into `Kobo_test.img`.

## 2.30 Real root cause found: firmware requested before any filesystem exists

Neither of 2.28/2.29's file placements worked. Rather than guessing a fifth
path, checked `bootlog.txt`'s actual `dmesg` capture for the real kernel
message: still `Direct firmware load for imx/epdc/epdc_PENG060D.fw failed with
error -2` (ENOENT) — genuinely not found, not a permissions/validation issue.

Checked the *ordering* of boot messages directly rather than assuming: the EPDC
firmware request (`imx_epdc_v2_fb ... epdc firmware name=...`) happens at line
358 of the log — **before** `mmc0: new ultra high speed SDR104 SDXC card at
address 0001` (line 361, the SD card itself being detected as hardware) and
long before `VFS: Mounted root` (line 381). EPDC is a platform device that
probes as part of the kernel's own early built-in-driver initcalls, before MMC
enumeration completes. **No file placed anywhere in any filesystem could ever
have worked** — at the moment this request fires, no storage device is even
recognized yet, let alone mounted. This fully explains every failed attempt in
2.28-2.29 regardless of which of the four paths was tried.

Real fix: `CONFIG_EXTRA_FIRMWARE`, the standard kernel mechanism for exactly
this chicken-and-egg problem — bakes firmware data directly into the kernel
image at build time, available from the first instant, no filesystem needed.
Placed the extracted waveform blob (2.28) in the kernel source tree under
`firmware/imx/epdc/`, as both `epdc_PENG060D.fw` and `epdc.fw` (the driver tries
both names, panel-specific first then generic). Set
`CONFIG_EXTRA_FIRMWARE="imx/epdc/epdc_PENG060D.fw imx/epdc/epdc.fw"`. Rebuilt —
verified directly (not just by size) that both `.gen.o` firmware objects were
produced and the raw waveform bytes are genuinely present in the built
`vmlinux`. Wrote the new kernel into `Kobo_test.img`.

## 2.31 Display working — a real image drawn on the physical e-ink panel

Flashing 2.30's kernel produced total silence: no UART, no `bootlog.txt` at all
(not even empty) — a regression from every earlier build, which always managed
*some* log output. Confirmed via MD5 that the flash itself was landing
correctly (traced a separate, unrelated flashing bug first: the destination
card was getting auto-mounted between `dd` attempts and racing the raw write —
fixed by unmounting first and using `conv=fsync`).

With the flash itself ruled out, checked U-Boot's actual kernel-loading code
(`board/freescale/common/ntx_comm.c`, `_load_ntxkernel()`) rather than
speculating. Found real hardware/firmware-specific behavior: for
`gptNtxHwCfg->m_val.bCustomer==9` (confirmed our device's actual value from
Section 2.12's U-Boot log capture, `customer=9`), the loader **skips magic-header
size detection entirely** and always reads a fixed `DEFAULT_LOAD_KERNEL_SZ =
9*1024 = 9216` sectors (4,718,592 bytes), regardless of what size is actually
encoded in our NTX header. 2.30's kernel+header was 4,773,656 bytes — **55KB
over that fixed ceiling** — so U-Boot was silently truncating the tail of the
compressed zImage on every boot. This also corrects a wrong assumption made in
2.30: the driver (`mxc_epdc_v2_fb.c`) only ever calls `request_firmware_nowait()`
with the literal name `"imx/epdc/epdc.fw"` — it does not try a panel-specific
name first. `epdc_PENG060D.fw` was baked in for nothing, and both files were
confirmed byte-identical (same MD5) — pure dead weight, roughly doubling the
firmware payload for no reason.

Fix: dropped `epdc_PENG060D.fw` from `CONFIG_EXTRA_FIRMWARE` and the source
tree entirely, keeping only `epdc.fw`. Rebuilt: zImage dropped from 4.77MB to
4.69MB, landing ~28KB under the 9216-sector ceiling. Reflashed, byte-verified
via MD5 against the exact on-card range.

**Result: booted, and `fbtest`'s `MXCFB_SEND_UPDATE` ioctl succeeded** —
`fbtest_output.txt` reads `update sent ok`, no more `EPERM`. The black/white
stripe test pattern it wrote is genuinely visible on the physical panel,
confirmed by the user directly. Static/unchanging on the screen is expected
and correct: e-ink is bistable, an image persists with zero power once a
waveform update commits, until another update is sent. This is the actual
display milestone — real pixels, driven by our own kernel, through the real
EPDC hardware path, bypassing Android's graphics stack entirely (as planned in
2.27).

The known binder/servicemanager cascade (`transaction failed 29189`, Section
2.18) is still present in this boot's log — unrelated to display, and still
paused per earlier direction, not blocking this result.

## 2.32 servicemanager cascade: real root cause found, real fix, real stability

Resumed the servicemanager investigation. Ruled out, in order, with direct
evidence rather than guessing: a crash (exit code is always a clean,
voluntary `0`, no signal, no debuggerd activity); OOM/low-memory-killer
(`CONFIG_ANDROID_LOW_MEMORY_KILLER` present but no kill messages anywhere in
dmesg); a malformed request from some other client (servicemanager dies
identically regardless of what it's given, including a hand-built, verified
byte-correct `CHECK_SERVICE` request from a purpose-built probe tool).

**Replaced Tolino's prebuilt vendor `servicemanager` with a fresh build from
real AOSP `android-4.4.2_r2` source** (`frameworks/native/cmds/servicemanager/
service_manager.c` + `binder.c`, fetched directly, not reconstructed from
memory), cross-compiled against our own kernel's exact `binder.h`, to
eliminate "unknown vendor binary" as a variable entirely. First build hit a
real, self-inflicted bug: neither AOSP source file defines
`BINDER_IPC_32BIT` before including the kernel header, so `binder.c` and
`service_manager.c` each compiled `struct binder_write_read` at 48 bytes
(64-bit field layout) while the kernel (`CONFIG_ANDROID_BINDER_IPC_32BIT=y`)
expects 24 bytes — a size baked directly into the `BINDER_WRITE_READ` ioctl
number itself, so the kernel rejected every call with `EINVAL` before ever
looking at the payload. Fixed by passing `-DBINDER_IPC_32BIT=1` as a compiler
flag (covers every translation unit, unlike a source-level `#define` in one
file), verified via DWARF debug info on the actual ARM cross-compiled object
(24 bytes, matching the kernel exactly) rather than a native x86_64 build,
which would have hidden the bug (pointers are 8 bytes there, masking a
different pointer-based struct's size entirely).

With that fixed, ioctl calls succeeded, but a new, precisely reproducible
symptom appeared: `binder_parse()`'s `default: OOPS` fired on the very first
word of every fresh read, immediately after the kernel had just written
`BR_NOOP` there — instrumented `binder_parse()` to dump the full raw buffer on
failure, confirming word 1 onward is always valid (`BR_TRANSACTION`'s tag
matches our own computed value exactly, full transaction struct intact), only
word 0 is wrong. Ruled out compiler optimization (identical at `-O2` and
`-O0`), struct field ordering (verified via DWARF `offsetof` on the ARM
target), and a stale/mismatched kernel binary (boot banner timestamp matches
the local build exactly). Canary-filled the buffer with `0xAA` before the
read to rule out "kernel doesn't write there at all" — confirmed the kernel
does overwrite word 0, but with a value that exactly equals the read buffer's
own stack address, every single time, across every independent test run
(different literal address each run, always matching that run's own buffer).
Read `binder_ioctl_write_read()`, `binder_thread_read()`, and the outer ioctl
dispatch in the actual kernel source line-by-line — all textbook-correct, no
vendor patch or logic error found. The exact mechanism remains unexplained —
this reads as a real, narrow kernel/toolchain-combination anomaly rather than
a logic bug in any single source file we control.

**Applied a targeted, safe workaround** rather than continuing to chase the
root cause indefinitely: `binder_parse()` now treats an unrecognized command
at word 0 specifically as the no-op the protocol already expects there
(discardable either way), while leaving every other position's error
detection untouched. Rebuilt, reflashed, booted for a full ~4.5-minute
capture (81 ticks): **`servicemanager` survived every single tick, alongside
`healthd` and `vold` — the first time in this entire project it has not died
within seconds of starting.** Real `svcinfo_death()` callbacks fired
correctly for registered services (`EpdNightMode`, `android.security.keystore`),
confirming actual service registration and lifecycle tracking are now
working, not just a quiet do-nothing loop. `surfaceflinger`, `mediaserver`,
`keystore`, `app_process`, and `zygote` still cycle on and off — plausibly
because they're still the original vendor binaries, linked against the much
larger `libbinder.so` (not our small `binder.c` helper), and may be hitting
the same word-0 kernel quirk in their own binder calls independently. Worth
patching next if pursued further, but out of scope for this fix.

## 2.33 Kernel-side fix confirmed broader than expected; SurfaceFlinger's real crash found and fixed

Given a choice between rebuilding `libbinder.so` against a matching-era Android
NDK (real ABI risk: vendor binaries are bionic + Google's C++ toolchain, ours
is glibc) versus removing the corrupted `BR_NOOP` write directly in the
kernel (`binder_thread_read()`, Section 2.32's `if (*consumed == 0) { put_user
(BR_NOOP...) }` block) — took the kernel path first as lower-risk. It worked,
and confirmed the theory completely: with nothing rebuilt except the kernel,
**`keystore` and `drmserver` — both still the original, untouched vendor
binaries — went from cycling every few seconds to 100% stable across a full
163-tick (~8 minute) capture**, matching `servicemanager`/`healthd`/`vold`.
Same root cause, fixed once, for every client, no userspace rebuilding
required.

`surfaceflinger`/`app_process`/`zygote`/`netd`/`mediaserver` still cycled
(~30% presence each), but now against a genuinely stable binder core to
investigate against. Pulled the real tombstones from `/data/tombstones/`
(directory is writable — the `mount_all` fix in 2.24/2.32's ancestry means
`/data` really is just a live directory on the combined filesystem, not a
placeholder) — all 10 captured were the identical crash:
`surfaceflinger` SIGSEGV, fault addr `0x0000000c`, inside `libGAL.so`
(Vivante's proprietary GPU driver) via `gralloc_viv.imx6.so` →
`gralloc.imx6.so` → `GraphicBufferAllocator` → EGL → `SurfaceFlinger::init()`.
Root cause: **the Kobo Clara HD's i.MX6SLL genuinely has no GPU** (confirmed
back in Section 2.6/2.8 — the SLL variant lacks the Vivante GC320 the plain
SL variant, e.g. Tolino Shine 3, has), but our system image is Tolino's real
firmware, whose `hwcomposer.imx6.so` tries the GPU-backed `gralloc_viv`
path first as a matter of course.

Real fix, not a stub: `gralloc.default.so` (AOSP's own software-only
implementation) was already present in the image, unused. Confirmed
`hwcomposer.imx6.so` already has an intentional fallback chain (`strings`
shows `"using viv hwc!"` / `"using fsl hwc!"` — it tries `hwcomposer_viv`
first, falls back to `hwcomposer_fsl` if that HAL fails to load) — so simply
renamed `gralloc.imx6.so`, `gralloc_viv.imx6.so`, and `hwcomposer_viv.imx6.so`
out of `/system/lib/hw/` (kept, not deleted, as `.disabled`), forcing
Android's standard `hw_get_module()` fallback onto the software paths that
were already sitting there unused. Rebuilt, reflashed, booted for a 107-tick
(~5.5 min) capture:

| service | before this fix | after |
|---|---|---|
| surfaceflinger | 31% | **100%** |
| mediaserver | 31% | 83% |
| netd | 31% | 69% |
| app_process | 30% | 50% |
| zygote | 1% | 18% |

SurfaceFlinger itself is now fully solved. The remaining instability moved
to a **new, different, already-identified crash**: fresh tombstones (smaller,
~19KB vs. the old ~59KB ones) show `zygote` dying with `SIGABRT` inside
`libjavacore.so`'s `register_libcore_icu_ICU()`, called during Dalvik startup
(`dvmStartup` → `JNI_OnLoad` for libjavacore). Checked the obvious cause
first and ruled it out: `/system/usr/icu/icudt51l.dat` is genuinely present,
correctly named for this ICU version, correct size (19MB, real data), correct
permissions (0644) — not a missing-file problem. The tombstone's own abort
path (direct `abort()`, not a JNI `FatalError` or SIGSEGV) suggests a native
assertion inside ICU's init failing for a more specific reason (data version
mismatch, a classpath/boot-jar issue reaching native registration, or similar)
that needs further digging — not yet root-caused.

## 2.34 ICU crash root-caused and fixed: another missing kernel syscall; `system_server` runs for the first time

Fetched the real AOSP `android-4.4.2_r2` source for
`libcore_icu_ICU.cpp`'s `register_libcore_icu_ICU()` directly rather than
guessing further. It does, in order: `open()` the data file, `fstat()`,
`mmap(..., MAP_SHARED)`, **`madvise(data, size, MADV_RANDOM)`**,
`udata_setCommonData()`, `udata_setFileAccess()`, `u_init()` — with a
`FAIL_WITH_STRERROR`/`MAYBE_FAIL_WITH_ICU_ERROR` macro pair that calls
`abort()` after any of these fail. Tried the obvious fix first
(`export ICU_DATA /system/usr/icu` in `init.environ.rc`, overriding
`u_getDataDirectory()`'s environment-variable lookup) — it had **zero
effect**, still the identical crash, which was itself useful evidence that
path resolution was never the problem.

Rather than keep guessing which of the six candidate calls was failing,
wrote a purpose-built diagnostic binary (`icu_probe.c`) replicating exactly
this sequence against the real device file, logging each step's return value
independently of ICU itself. Result, byte for byte:
```
open(/system/usr/icu/icudt51l.dat) = 4 errno=Success
fstat() = 0 errno=Success size=19032528
mmap() = 0x75dac000 errno=Success
first bytes: 80 00 da 27          <- correct ICU data header magic
madvise(MADV_RANDOM) = -1 errno=Function not implemented
```
Every step succeeds — real file, correct size, correct magic bytes, correct
mmap — except `madvise()`, which returns bare `ENOSYS`. Checked `.config`:
**`CONFIG_ADVISE_SYSCALLS` was not set** — the exact same recurring pattern
as `CONFIG_ANDROID_BINDER_IPC` (2.17) and `CONFIG_NETFILTER` (2.26): the base
Nickel/Linux-target defconfig never enabled a syscall family Android's own
userland unconditionally assumes exists. When this option is off, the kernel
compiles `madvise()`/`fadvise64()` as stubs that unconditionally return
`-ENOSYS` for every caller, not just ICU — this was very likely also
destabilizing other things silently. Enabled it, rebuilt, reflashed.

Result, 125-tick (~6.5 min) capture:

| service | before | after |
|---|---|---|
| zygote | 18% | **97%** |
| system_server | 0% (never once) | **65%** |
| everything from 2.32/2.33 (servicemanager, surfaceflinger, netd, drmserver, mediaserver, keystore, healthd, vold) | stable | still 100% |

**`system_server` — the actual heart of the Android framework (activity
manager, package manager, window manager, and everything else real apps
depend on) — has run for the first time in this entire project.**
`app_process` itself now shows in only 2% of snapshots, which is expected,
not a regression: it `exec`s into and renames itself to `zygote` almost
immediately, so seeing `zygote` at 97% and `app_process` rarely is the
correct healthy pattern, not an anomaly.

New tombstones appeared (~54KB, a third distinct signature from the
gralloc-crash's ~59KB and the ICU-crash's ~19KB ones): `surfaceflinger`
SIGSEGV, fault addr `0x00000020`, this time inside `eglSwapBuffers()` via
`libGLES_android.so` — AOSP's own **software** GLES renderer, not the
Vivante path, confirming 2.33's gralloc/hwcomposer fix is holding. This is a
later-stage failure than before (during actual frame presentation, not
initialization). Root-caused and largely fixed in 2.35.

## 2.35 Toolchain ABI dead end fixed; real eglSwapBuffers crash root-caused to source line; custom hwcomposer avoids it entirely

Two dead ends before the real fix:

**Dead end 1 — float ABI.** The custom gralloc HAL module (a thin wrapper
around the real vendor `gralloc.default.so`, added to fire `MXCFB_SEND_UPDATE`
after every framebuffer post) never got its `open()` called at all — its own
unconditional diagnostic logging stayed completely empty. `readelf -h`
comparison against the real vendor `.so` showed our build had `hard-float ABI`
(`0x5000400`) vs. the vendor's `0x5000000`; `arm-linux-gnueabihf`'s sysroot
turned out to be hard-float-only (`-mfloat-abi=softfp` fails to even compile:
missing `gnu/stubs-soft.h`). Downloaded the sibling `arm-linux-gnueabi`
toolchain variant and got `softfp`/`VFPv3`/`NEONv1` attributes matching the
vendor lib exactly — module still never loaded.

**Dead end 2 — the real cause was the C library, not the float ABI.**
`readelf -d` on the "fixed" module showed `NEEDED: libdl.so.2` and
`libc.so.6` with versioned `@GLIBC_2.4` symbols: bionic (Android's actual
libc, unversioned `libc.so`/`libdl.so`, no symbol versioning at all) can
never satisfy that — any generic `arm-linux-gnu*` cross-toolchain links
against its own glibc sysroot regardless of float-ABI flags. Confirmed
bionic's 4.4.2 `linker.cpp` doesn't even check `e_flags`/float-ABI at load
time at all (grepped the real source) — the whole float-ABI theory was a
red herring from correlation, not an actual verified gate. Fix: downloaded
**Android NDK r10e** (bundles a genuine bionic-targeted
`arm-linux-androideabi-4.8` toolchain + `android-19` sysroot with real
unversioned `libc.so`/`libdl.so`). Rebuilt against it — `NEEDED` list and
`e_flags` now match the vendor library exactly, module finally loads and its
`open()` calls succeed (confirmed via diagnostic log with real widths/heights:
1448×1072).

**The real eglSwapBuffers crash**, once the module was loading, still
happened identically. `/data/tombstones` (fetched directly, bypassing the
need for a working `logcat` — this kernel's tree has no Android logger driver
in `drivers/staging/android/` at all, so `/dev/log/*` never exists here
regardless of `init.rc`) gave 10 byte-identical crashes:
`SIGSEGV fault addr 0x00000020`, `r0=00000000`, inside
`libGLES_android.so`'s `eglSwapBuffers`. Fetched the real
`libagl/egl.cpp` and `FramebufferSurface.cpp`/`DisplayDevice.cpp`/
`HWComposer.cpp` sources for `android-4.4.2_r2` and traced it to an exact
line: `egl_window_surface_v2_t::swapBuffers()` calls
`nativeWindow->queueBuffer(nativeWindow, buffer, -1)` with **no null check**
on `nativeWindow` — and disassembly of the real crash site
(`ldr r2, [r0, #32]` at the exact faulting PC) confirms `r0` (the window
pointer) is genuinely `NULL` at the call site. `DisplayDevice::swapBuffers()`
only reaches this path when `hwc.initCheck() != NO_ERROR` (no real
hwcomposer) **or** `hwc.hasGlesComposition()` is true — tested both
(hwcomposer.imx6.so active, then fully disabled) and hit the identical
crash either way, since this vendor build has no code path that avoids
`eglSwapBuffers` on the primary display at all. This is very likely a bug
that has *never* been exercised on real hardware, since every shipped
i.MX6 board this ROM targets has a working Vivante GPU + hwcomposer, which
always keeps `hasGlesComposition()` false.

**Fix**: wrote a custom `hwcomposer.imx6.so` from scratch
(`hwcomposer_eink.c`, built against the same NDK bionic toolchain) whose
`prepare()` marks every real layer `HWC_OVERLAY` (never `HWC_FRAMEBUFFER`),
so `hasGlesComposition()` stays false and `eglSwapBuffers` is skipped
entirely. `set()` does the actual composition itself in plain software:
maps `/dev/graphics/fb0` once via `mmap`, and for each layer calls the
gralloc module's `lock()`/`unlock()` to get a CPU pointer and `memcpy`s it
into the framebuffer at the right offset, then fires
`MXCFB_SEND_UPDATE`. No scaling or alpha blending yet (clipped/opaque
copy only) — acceptable for this device's simple, mostly-fullscreen UI.
Since `hwc_layer_1_t` only carries an opaque `buffer_handle_t` (no
width/stride/format) and the real vendor's private-handle layout is
unknown/proprietary, extended the gralloc wrapper to intercept `alloc()`/
`free()` on the `gpu0` allocator device, recording each buffer's real
geometry in a small side-table exported via a plain C symbol
(`eink_gralloc_query()`) that the hwcomposer `dlopen()`s at runtime — both
HALs run in the same SurfaceFlinger process, so this works without any
shared memory or IPC.

Result, 265-tick (~13.5 min, the longest capture yet) boot:

| | before (2.34 state) | after |
|---|---|---|
| surfaceflinger crashes | 10 tombstones filled the ring, non-stop | **2**, both in the first ~15s |
| surfaceflinger stabilizes by | tick 21 (~63s) | **tick 9 (~27s)** |
| `system_server` starts at | tick 33 | **tick 12** |
| `system_server` restarts after starting | 0 | 0 (unchanged, already solid) |
| longest stable capture | ~8.7 min | **~13.5 min, still stable at cutoff** |

The 2 remaining early crashes match a known, separate framework quirk
(not our HAL's fault): `HWComposer::prepare()`'s own bookkeeping in
`HWComposer.cpp` forces `hasFbComp = true` whenever a display's layer list
is empty (just the `FRAMEBUFFER_TARGET` placeholder, no real content yet)
"to draw the wormhole region" — no hwcomposer implementation can prevent
that specific forced GLES call. It only fires during the very first
frame(s) before any content exists, then never recurs once a real layer is
present, matching exactly what was observed.

**New finding, not yet root-caused**: at tick 265, `system_server` (a
single stable PID, zero restarts) is running completely alone —
`ps` shows no launcher, no SystemUI, no app-level process forked from
`zygote` beyond `system_server` itself, in over 13 minutes. The black
screen is therefore no longer a graphics-HAL crash; it's that the Java
framework has not yet gotten far enough (`ActivityManagerService`/
`PackageManagerService`/`WindowManagerService` init, or whatever gates the
first launch) to start anything visible. This is a different class of
problem than everything above and needs its own diagnostic path, since
`logcat` is unavailable on this kernel (see above) — likely candidates:
`/data/anr/`, `/data/system/`, `dumpstate`-style state dumps, or a
purpose-built native probe in the same spirit as `icu_probe.c`.

## 2.36 Kernel logcat driver added; two real bugs found via real stack traces; home app resolves and starts; new binder deadlock found in a fresh app process's first-ever binder call

With 2.35's fixes landing, `system_server` still hung dead at "Battery
Service" every boot — before this session, we'd only ever diagnosed
native crashes via tombstones, since this device's kernel had **no
`/dev/log/*` at all**: not a vendor removal, upstream Google's own
`kernel/common` tree had already dropped `drivers/staging/android/
logger.c` by this kernel's version (`android-4.1`, i.e. Linux 4.1 —
confirmed by walking the actual branch tree via `+/refs/heads/deprecated/
android-4.1/drivers/staging/android/`, no `logger.c` present). Pulled the
real driver from mainline Linux `v3.18` (`git.kernel.org`, matching-era
source, not a WebFetch summary), fixed two small `iov_iter`-era API
changes between 3.18 and 4.1 (`iocb->ki_nbytes` → `iov_iter_count(from)`;
added a missing `#include <linux/uio.h>`), wired it into `Kconfig`/
`Makefile`/`.config`. Compiled clean, and `/dev/log/*` + `logcat -f`
finally work — the single highest-leverage fix of the session, since it
turned every subsequent bug from "guess from a native tombstone" into
"read the actual Java stack trace."

**Bug found via logcat #1 — the BR_NOOP fix's own retry-check was now
inconsistent with itself.** With real logcat, traced the "Battery
Service" hang precisely: `BatteryService`'s constructor makes a
single-threaded, `IPCThreadState::setupPolling()` + `handlePolledCommands()`
epoll-integrated Binder call to `healthd`'s `batterypropreg` service —
and it never returned. Re-examined our own 2.32 fix (removing the
corrupted leading `BR_NOOP` write in `binder_thread_read()`) and found
the retry-loop condition immediately below it was never updated to
match: `if (ptr - buffer == 4 && ...) goto retry;` was written for the
old world where a leading no-op occupied the first 4 bytes; with that
write removed, "nothing written yet" is now `ptr - buffer == 0`, not
`4`. For ordinary *blocking* Binder threads (servicemanager,
surfaceflinger, ...) hitting this dead branch just costs one extra,
harmless ioctl round-trip — which is exactly why it was invisible in
every case tested at 2.32. For `healthd`'s single-threaded, *non-blocking*
`handlePolledCommands()` pattern, taking the wrong branch here
apparently drops a genuine, real transaction instead of correctly
looping to retry, permanently starving the caller. Fixed the constant;
`system_server` now sails straight through "Battery Service" → "Alarm
Manager" → "Input Manager" → "Window Manager" every time.

**Bug found via logcat #2 — a hardcoded, unrelated buffer-slot cap in the
vendor's gralloc, mis-triggered by our own hwcomposer's design.** Past
"Window Manager", a *new* crash appeared: `GraphicBufferAllocator::alloc`
failing with `-12` (ENOMEM) on a *third* framebuffer-purpose allocation,
crashing SurfaceFlinger — deterministically, on literally the first boot
attempt, well before WindowManagerService is even involved. Added
explicit `ALOGI` logging to our gralloc wrapper's `alloc()`/`free()`
(with PID and usage flags) and got a byte-for-byte reproducible pattern:
every SurfaceFlinger instance requests exactly 2 buffers with
`usage=0x1a33` (includes `GRALLOC_USAGE_HW_FB`) successfully, then fails
on a 3rd. Root cause: the real vendor `gralloc.cpp`'s
`gralloc_alloc_framebuffer_locked()` maintains a tiny fixed pool
(`numBuffers`, `bufferMask`) carved directly out of the mapped
`/dev/graphics/fb0` region, sized for genuine hardware page-flipping —
and AOSP's `FramebufferSurface` wants **3** buffer slots by default,
while this fb driver's `yres_virtual` only supports **2**. This was
always going to fail on real e-ink hardware, HWC or no HWC — it just
took getting *this* far in boot to ever be reached. Since our own
hwcomposer never uses gralloc's `post()`/page-flip path at all (it does
its own direct `mmap()` + `memcpy()` compositing), the fix is to simply
stop asking the vendor's allocator for "real hardware framebuffer"
semantics: `eink_gpu_alloc()` now strips `GRALLOC_USAGE_HW_FB` before
delegating to the real vendor `alloc()`, forcing every buffer — including
"framebuffer-purpose" ones — through the vendor's own generic ashmem
path, which has no such slot limit (confirmed via `strings` on the
vendor `.so`: `ashmem_create_region`, no PMEM/ION/carveout involved, so
plenty of the device's 496 MB RAM is available).

**Result: `ActivityManagerService` resolved and started the real home
app on its own**, no external help. `de.telekom.epub`'s `HomeActivity`
(confirmed via a hand-written AXML parser against the real binary
manifest — fixed a 4-byte attribute-offset bug in the parser along the
way — to have both `MAIN`+`HOME` and `MAIN`+`LAUNCHER` intent-filters)
got a real `ActivityManager: START u0 {... cmp=de.telekom.epub/
.ui.activities.HomeActivity}` line in logcat, this device's actual
target app, not a stub. It was reached via an `am start` retry-loop
diagnostic script (`eink_launch_home.sh`) added earlier this session —
which turned out to be actively harmful: forcing the launch *before*
Android's normal boot-completed sequencing caused a **`FATAL EXCEPTION
IN SYSTEM PROCESS`** crash in `ActivityManager` (the app tried to
broadcast `de.telekom.epub.action.OVERLAY_ATTACHED` "before boot
completion", a code path AMS doesn't handle cleanly this early).
Disabled that script's `init.rc` service entirely — letting
`ActivityManagerService.systemReady()`'s own home-intent resolution fire
at the correct point in boot instead. Next boot: **zero
`FATAL EXCEPTION IN SYSTEM PROCESS` crashes**, only one early, unrelated
`mediaserver` `SIGABRT` in `joinThreadPool()` (self-recovers via init's
normal restart, doesn't block anything), then a single, stable
`system_server` PID for the whole ~12.5 minute capture — the cleanest
boot yet by a wide margin.

**New finding: a genuine binder deadlock, specific to a freshly
zygote-forked app process's very first Binder call.** After
`systemReady()`, `system_server` correctly starts `com.android.systemui`/
`KeyguardService` (`Start proc ... pid=1093`) — but that child process
never gets past zygote's `<pre-initialized>` placeholder name (the name
zygote sets immediately post-fork, before the app renames itself),
despite being genuinely alive (real PPID, real growing RSS, no crash, no
tombstone) for the rest of the ~12.5 minute capture. Reproduced
identically on a second, independent boot (different PID). Built a small
`init.rc` service (`eink_dump_stuck.sh`) that polls `ps` for any
`<pre-initialized>` process and sends it `SIGQUIT`, reusing the exact
mechanism `system_server`'s own ANR handler already uses to dump
`/data/anr/traces.txt` — first attempt failed silently because this
minimal Android shell has no `awk` (fixed with shell-native `read -r
user pid rest` field-splitting instead). The resulting stack trace is
precise: the main thread is parked in
`ProcessState::getContextObject()` → `getStrongProxyForHandle(0)` →
`IPCThreadState::talkWithDriver()`, i.e. the *very first* Binder call
any process makes (`ServiceManager.getIServiceManager()`, from
`ActivityThread.attach()`) — the special "handle 0" transaction routed
by the kernel to whichever process registered itself as binder context
manager (`servicemanager`). 93 of 95 repeated `SIGQUIT` dumps over 23+
minutes show the thread in `state=S` (a normal, interruptible binder
wait, not a hard kernel-level freeze) — ruling out mere single-core CPU
starvation (which would resolve in milliseconds-to-seconds, not
23+ minutes) and pointing to a genuine, permanent deadlock. Notably, the
process's *own* Binder thread pool (`Binder_1`, `joinThreadPool()`) is
alive and healthy — only the outgoing transaction to `servicemanager`
never gets a reply. Every other successful `servicemanager` client this
whole project (`system_server`, `surfaceflinger`, `mediaserver`, `netd`,
`drmserver`, `keystore`, `vold`, ...) reaches the exec()'d-fresh route
from `init.rc`, never the zygote-`fork()`-inherited-`ProcessState`
route — the one structural difference between this hang and every prior
binder fix this project has made. Not yet root-caused; likely another
kernel-level binder bug given the project's track record (2.17, 2.32,
and the fix earlier in this section), but this is the first one specific
to the fork-inherited-binder-fd code path rather than a single-process
read/retry accounting bug.

## 2.37 The app-fork deadlock: six native reproduction attempts, six failures — the flaky SD reader turned out to be the Mac itself, not the cards

Switched the entire flash/verify/readback workflow off the Mac (macOS 10.9,
legacy SSH, `pci pause: SDXC` power-management bugs on its internal reader,
and mysteriously worsening corruption on its external USB reader too) onto
a second machine (a real Debian box on the LAN) reached over SSH
the same way. The very first flash there was silently corrupted for a
different, new reason — the SD card's own physical write-protect switch
was engaged (`dmesg`: `sd 6:0:0:0: [sda] Write Protect is on`), something
no amount of retrying on the Mac would ever have surfaced since a locked
card still enumerates and *reads* back correctly, it just silently refuses
writes. Once unlocked, every flash on this host has verified byte-for-byte
on the first attempt — real hardware, real reads, no more guessing whether
a mismatch means a bad flash or a bad reader.

With reliable verification finally available, went back to 2.36's newest
finding — the zygote-forked app process (real target: `de.telekom.epub`'s
`HomeActivity`) hanging forever at `<pre-initialized>` inside
`ProcessState::getContextObject()` → `getStrongProxyForHandle(0)` →
`talkWithDriver()`, i.e. the very first Binder call any Android process
makes to reach `servicemanager` — and tried to reproduce it with an
isolated native probe (`binder_probe.c`, raw `ioctl(BINDER_WRITE_READ)`,
no libbinder/Dalvik at all) that could be run in exactly the failing
configuration, piece by piece:

| test | what it isolates | result |
|---|---|---|
| direct, uid=0 | baseline sanity check | reply in ~2s |
| direct, uid=10003 (`u0_a3`, matching the real hung process) | wrong app UID | reply in ~2s |
| `fork` | naive fork()-inherited `/dev/binder` fd, no uid drop | reply in ~3s |
| `forkuid` | fork + setuid(10003) using the inherited fd | reply in ~2s |
| `mtfork` | 6 idle (binder-unaware) pthreads alive in the parent at fork time, mimicking a busy Dalvik VM | reply in ~1s |
| `bpoolfork` | a **real, registered** binder threadpool worker (genuine `BC_ENTER_LOOPER` + blocking read, exactly `IPCThreadState::joinThreadPool()`) alive in the *parent* at fork time | reply in ~2s |
| `bpoolfork`, delayed 90s | same as above, but fired ~90s into boot under genuine concurrent system load instead of an idle just-booted system | reply in **0s** |
| `postfork` | the one combination not yet tried: fork first, *then* in the child spawn its own registered threadpool worker (matching Zygote's real order — fork, then `onZygoteInit()`'s `startThreadPool()`, then much later `ActivityThread.attach()`) so it coexists with the transacting thread in the same post-fork process | reply in **0s** |

Every single one succeeded, immediately, every time. Confirmed via
`eink_dump_stuck.sh` (the `SIGQUIT`-to-`/data/anr/traces.txt` watcher from
2.36) that the *real* hang still reproduces reliably in these exact same
boots — a fresh `<pre-initialized>` process every time (four independent
boots now, four different PIDs/UIDs: `u0_a3`, `u0_a1`, `u0_a4`, ...), so
this isn't a fluke that stopped happening; the native probe genuinely
cannot reproduce a bug the real app hits every single boot.

This means the deadlock is not explained by process UID, fork-inherited
Binder state, multi-threading, thread-pool coexistence, or system load —
every structural variable a plain C program can control has been ruled
out. The remaining difference has to be something intrinsic to the real
Dalvik/ART runtime or `ActivityThread.attach()`'s actual code path that a
native reproduction can't easily fake: JIT/GC/verifier internal state
across the fork, a JNI/monitor detail specific to the real
`BinderInternal.getContextObject()` native method, or a genuinely
Dalvik-specific interaction with the kernel driver that only manifests
when the call originates from within a real ART thread. Getting further
now most likely needs either live debugging of the actual hung process
(ptrace/gdbserver — not available in this project's tooling so far) or
instrumenting the real framework Java code directly rather than a native
stand-in.

## 2.38 Launcher on the panel: one compositor doing rotation, format and clipping

With the app-fork deadlock fixed (smali no-ops for the two WindowManager
overrides that reach `PowerManagerService.mLock` from the AMS side), the
launcher came up but with a 376 px black band along one edge and touches
landing in the wrong place. Both came from the same mistake: SurfaceFlinger
sizes the display from gralloc's `fb0` (1448x1072, landscape-native), so
WindowManager rotates the UI itself (rotation 270) and InputReader rotates
touch with it. The compositor was *also* rotating, and clipping layer frames
against a 1072-wide "logical portrait" screen. Fixed by giving it the physical
dimensions and honouring each layer's `transform` instead — plus a
format-aware conversion (layer buffers are 32-bit `RGBX_8888`/`RGBA_8888`,
the panel is `RGB565`) and a source-major loop into a cached shadow buffer,
after a destination-major one caused a hard reset from cache thrashing alone.

## 2.39 adb over USB: the gadget the vendor rules cannot drive

This kernel (4.1.15) has no `android_usb` gadget driver at all — its USB
gadget support moved to configfs — so every `on property:sys.usb.config=adb`
rule in the vendor's `init*.usb.rc` writes to a sysfs path that does not
exist and silently does nothing. Replaced with a boot script that builds the
gadget by hand (configfs + FunctionFS: `libcomposite.ko`, `usb_f_fs.ko`,
`ffs.adb` function, `mount -t functionfs`), then starts adbd.

adbd still fell back to TCP. Its own trace log gave it away: it drops to uid
`shell` *before* testing whether `/dev/usb-ffs/adb/ep0` exists, and the
directory created for the mount was root-only, so the test failed and it
chose the network transport. `chmod 0755` on the path fixed it. A probe that
wrote the stock descriptor blob as root had already proved the kernel side
was fine, which is what ruled out the descriptor format entirely.

Also here: the gadget is bound to the UDC from a loop once `ep1` appears,
because f_fs unbinds it whenever ep0 is closed (an adbd restart), and
`ro.adb.secure` is 0 — key approval is answered by a SystemUI prompt that
only runs when "USB debugging" is on in Settings, which it deliberately is
not (that setting is what makes UsbDeviceManager stop adbd).

## 2.40 Boot instrumentation was the performance problem

The system was so slow that SystemUI was ANR-killed twice before it could
add the navigation bar, and the launcher took almost two minutes to appear.
The cause was our own debugging: `init.rc` still set the binder driver's
`debug_mask` to 65535, logging every transaction to the kernel log (~100k
lines per boot), zygote still preloaded a binder-tracing `LD_PRELOAD` shim
into every app, and a watchdog script SIGQUIT'd system_server on every scan.
84% of CPU time was in the kernel and individual binder calls took 150–380 ms.
Removing all of it made the device responsive; the nav bar investigation
then became tractable.

## 2.41 Navigation bar: a vendor SystemUI that hides it by design

`qemu.hw.mainkeys=0` was set and the window policy agreed a nav bar should
exist, but SystemUI never created one. Decompiling it (baksmali needs
`-a 19`; without the right API level whole classes fail to disassemble)
showed Tolino had replaced the stock decision — AOSP asks the window manager
`hasNavigationBar()` — with "show it only if `KeyCharacterMap.deviceHasKey()`
reports neither HOME nor BACK". The Clara's key layouts declare both, so the
bar could never appear.

Rather than patch that, both SystemUI and Keyguard were replaced with the
stock 4.4.2 ones from Google's emulator image (they share `android.uid.systemui`
and must be signed alike). Two consequences, both fixed: Tolino's
`StorageManager.(un)registerListener` takes an `IStorageEventListener` their
own `StorageEventListener` does not implement, so the stock listener classes
gain that interface; and the stock apps are not signed with the vendor
platform key, so `PackageManagerService.grantSignaturePermission()` now grants
signature permissions to privileged `/system/priv-app` apps — without it
SystemUI cannot obtain `STATUS_BAR_SERVICE` and never starts.

## 2.42 OpenGL ES 2.0 without a GPU: SwiftShader on the Cortex-A9

The i.MX6SLL has no GPU and Android's built-in software renderer implements
only GLES 1.x, so anything requesting a GLES 2.0 config crashed outright
(CPU-Z: `IllegalArgumentException: No configs match configSpec`). SwiftShader
— Google's CPU renderer, pinned at the last revision with an Android GLES
build — now provides it. Four fixes were needed for this device:

- Subzero's `ICE_CACHELINE_BOUNDARY` padding makes the compiler emit
  128-bit-aligned NEON stores into heap objects, but bionic's `malloc` is
  only 8-byte aligned: `SIGBUS`. The padding only avoids false sharing
  between cores, and this is single-core, so it was dropped.
- Its JIT targeted `HWDivArm`; the Cortex-A9 has no `SDIV`/`UDIV`
  (`SIGILL` in generated code). Switched to the NEON target.
- Generated code then needed runtime helpers (`__divsi3`, `fmodf`, the
  `__Sz_*` conversions) that the Reactor's ELF loader could not resolve at
  all. It now resolves them to C implementations — the float and vector ones
  declared `aapcs-vfp`, because Subzero emits hard-float calls while
  armeabi-v7a is soft-float — and Subzero always calls through a register,
  since the loader cannot apply `R_ARM_CALL` and the helpers are far outside
  `BL` range anyway.
- `posix_fallocate` does not exist before API 21.

Installing it system-wide then crash-looped SurfaceFlinger. Two more: KitKat's
linker reports only a basename from `dladdr`, so libEGL could not find
`libGLESv2_swiftshader.so` beside it and context creation failed (the path now
comes from `/proc/self/maps`); and fb0 is RGB565 while SurfaceFlinger with
HWC 1.1 wants an RGBA_8888 `EGL_FRAMEBUFFER_TARGET_ANDROID` config, so the
display format is reported as RGBA_8888 and the hwcomposer converts.

App UIs are deliberately kept on the software path
(`HardwareRenderer.isAvailable()` returns false): with a GLES 2.0 driver
present every app would otherwise render its whole interface through
SwiftShader.

## 2.43 WiFi: the driver had to be built against this kernel

The vendor's `/system/wifi/8189fs.ko` targets Tolino's 3.0.35 kernel and
cannot load here. The RTL8189FS is an SDIO part on usdhc3; the open-source
`rtl8189fs` driver builds against this 4.1.15 tree with one fix (its Makefile
copies `ccflags-y` into `EXTRA_CFLAGS`, which 4.1's kbuild folds back the
other way — a self-referencing variable that stops MODPOST). Power comes from
Kobo's own `sdio_wifi_pwr.ko`, already in the tree, which drives the
power/reset GPIOs and triggers the card-detect. `wpa_supplicant` had to be
added to `init.rc`: the vendor defines it in `init.freescale.rc`, which is
not imported on this board.

## 2.44 Front light, and an animation setting that broke the nav bar

The brightness slider moved and nothing happened: `init.E60K00.rc` points the
lights HAL at `mxc_msp430_fl.0`, the MSP430 companion of other Netronix
boards, which does not exist here (`E/lights: can not open file`). The front
light is the LM3630A's **bank B** — `/sys/class/backlight/lm3630a_ledb`, whose
`max_brightness` of 255 maps 1:1 onto Android's range. Pointing the HAL there
and giving system_server ownership of those root-owned sysfs files made the
slider work. The vendor's own control is a pop-up that dismisses itself
instantly, so `apps/frontlight` is a small preloaded app with a persistent
slider and presets.

E-ink also wants no animations, so the three scales were pinned to 0 — and
that broke the navigation bar: a game requesting "lights out" dims the bar to
dots, and the transition back is a property animator, so with
`animator_duration_scale` at 0 SystemUI never repainted and the buttons
stayed invisible. Only the window and transition scales stay at 0.

## 2.45 External storage: a partition that was never created

Most apps crashed, and the stock browser crashed on launch with
`SecurityException: Invalid mkdirs path: /mnt/media_rw/sdcard1/...`. Android's
primary external storage on this firmware is the *4th partition of the boot SD
card* (`fstab`: `voldmanaged=sdcard1:4`, and framework-res marks
`/storage/sdcard1` primary and non-removable). Our image only ever had three
partitions, so there was nothing to mount and `getExternalStorageState()`
never became `mounted`.

Creating it was not enough. vold matched the volume by the 3.0 kernel's
platform-device path, which never matches a 4.1 device-tree kernel (the boot
SD is `soc/2100000.aips-bus/2194000.usdhc`), so the volume stayed in
No-Media. With the path fixed it still failed, and the reason is a kernel
difference: vold maps `voldmanaged=sdcard1:4` onto a device through the
`NPARTS`/`PARTN` block uevent variables, which only the AOSP common kernels
emit. Mainline 4.1 emits neither, so vold assumed one partition at index 1,
tried to mount `/dev/block/vold/16777215:255`, "identified" it as NTFS, and
still reported the volume Mounted while nothing was. Both uevent variables
are now emitted the way AOSP does it.

One self-inflicted trap here: the image ran ~16 MB past the start of that
partition, so every flash destroyed its filesystem. The image is truncated at
the partition boundary now.

## 2.46 Wallpapers: two removals and one compositor bug

Wallpapers rendered as a black screen. Three separate causes, found in that
order:

1. Tolino removed `WallpaperManagerService`'s creation from `ServerThread`
   (its local slot and the `systemRunning()` call in the systemReady callback
   are both still there), so the `wallpaper` service never registered and
   every call failed with "WallpaperService not running". Restored.
2. Their framework-res carries no `default_wallpaper` drawable, so with none
   chosen the screen is legitimately black.
3. The real one: our compositor copied every layer opaquely. The launcher's
   window is transparent where the wallpaper shows through, so its
   transparent-black pixels overwrote the wallpaper. It now honours
   `HWC_BLENDING_PREMULT`/`COVERAGE`, with fast paths for fully opaque and
   fully transparent pixels.

Setting a wallpaper had worked all along — `setBitmap()` succeeded and the
file was on disk; it just could never be seen. Verified by dumping
`/dev/graphics/fb0` directly, which is the only way to see what the panel
actually shows: SurfaceFlinger's own screenshot path composites separately
and was black for the same reason.

## 2.47 A build others can run

`build/build.sh` turns this from "a device someone got working" into
something reproducible: it asks for the two inputs that cannot be
redistributed (the Tolino firmware's `android_root`, and a Clara HD card
image for its partition table and bootloader), downloads everything else, and
applies every patch in `patches/` to that copy. Steps are separate and
resumable, and each patch asserts on the vendor text it expects, so a
different firmware revision fails loudly rather than producing a subtly
broken system.

Testing the framework patcher against a *pristine* vendor `services.jar`
caught two real bugs in the recorded patches — one captured with stray
annotation lines, one with duplicated labels — that would have produced a
corrupt framework. The automated result now matches the jar running on the
device instruction for instruction.

## 3. Open risk register

- **Shine 3 hardware access**: turned out to be unnecessary for everything done so
  far — the firmware pulls straight from Tolino's live update servers. Still
  useful to have a real unit eventually for actually testing a boot.
- ~~GPU dependency depth is unverified~~ — resolved (Section 2.6): software
  rendering is deliberately the default for this whole board family regardless of
  GPU presence, not a fallback that needs building.
- ~~Binder/ashmem availability in Kobo's vendor kernel is unverified~~ — resolved
  (Section 2.5): both present, plus lowmemorykiller and sync fences.
- ~~WiFi/touch/PMIC identity unconfirmed~~ — resolved (Section 2.8), read directly
  off the real device tree on your actual card: `ti,tps6518x` EPD PMIC,
  `ricoh,rc5t619` system PMIC, `cypress,tt21000` touch, WiFi on `mmc@2198000` with
  `8189fs.ko` confirmed present in the running postmarketOS install.
- **Neither vendor partition table (Section 2.6, 2.7) matches what's actually on
  your card right now** — your card currently runs postmarketOS's own 2-partition
  layout (`pmOS_boot`/`pmOS_root`), not Nickel's original 3-partition layout or
  either Android vendor default. Whatever gets built needs its own partition
  layout carved out fresh (or reuses/extends postmarketOS's), not a copy of any
  layout discussed elsewhere in this doc.
- ~~Brick risk~~ — substantially resolved (Section 2.8): the "internal storage" is
  a plain removable microSD card. Recovery from a bad flash is "pop the card,
  `dd` a known-good backup back with any card reader," not eMMC-programmer
  territory. Strongly recommend imaging the card *right now*, before any further
  work, given it's already out and in a reader — `dd if=/dev/sde of=backup.img
  bs=4M` (confirm the device node hasn't changed since this session) — so there's
  a known-good restore point regardless of what's tried next.
- **This is still a solo, iterative, hands-on-hardware project at the next stage.**
  Everything so far has been safe, read-only firmware/source analysis. The next
  stage — assembling an actual boot.img/system image targeted at Clara HD's real
  partition table and flashing it — is a different kind of work, and the point
  where mistakes start actually risking your hardware. I can keep helping with
  board-file diffs, HAL/config code, and build scripts, and read logs/errors you
  paste back, but I can't compile against your toolchain, flash your device, or
  watch your serial console myself.

## 4. Next concrete action

The bring-up questions this section used to plan for are answered: the kernel
boots, the vendor userspace runs, and the device is usable (see the status
table at the top). What is left is smaller and more ordinary:

1. **Run `build/build.sh` end to end on a clean machine.** Its steps are the
   commands used by hand and its framework patching is verified against a
   pristine vendor jar, but the whole script has never been run start to
   finish anywhere else.
2. **Suspend/resume and battery life.** Never investigated. The device
   currently stays awake while plugged in for development.
3. **The reader app.** The vendor's EPub app is removed rather than adapted;
   a reader that suits e-ink (and the front light) is the obvious next
   userspace job.
4. **SurfaceFlinger's screenshot path.** `screencap` goes through GLES, so it
   now runs on SwiftShader; it worked when checked but has not been tested
   beyond that. `/dev/graphics/fb0` is the reliable way to see the panel.
5. **Panel quality.** Waveform mode is `AUTO` with a full update every frame;
   partial updates and per-window waveform choices are untouched, which is
   where e-ink responsiveness and ghosting are won or lost.

---

## 5. Fallback: from-scratch AOSP build (if firmware adaptation stalls)

Kept from the original plan, in case Section 2's approach hits a wall the GPU-strip
can't clear (e.g. the GPU turns out to be load-bearing for boot on that kernel in a
way that's not worth unwinding).

### Precedent
- **[marek-g/kobo-kernel-2.6.35.3-android](https://github.com/marek-g/kobo-kernel-2.6.35.3-android)**
  — Android 2.3-compatible kernel for Kobo Touch/Glo/Mini (older i.MX507 SoC), itself
  ported from the **original Tolino Shine's** Android 2.3 firmware. Companion repos:
  **[kobo-service](https://github.com/marek-g/kobo-service)** and
  **[coolreader3](https://github.com/marek-g/coolreader3/tree/marek)** (modified to
  force full e-ink refreshes after N page turns instead of a general HWComposer
  fix). Not directly portable (different SoC generation) but proves the same
  app-level-refresh architecture works, and is a real reference for what an
  ashmem/binder/wakelock kernel patch set for one of these boards looks like.
- **NXP official Android BSP**: a real GA release,
  ["i.MX 6 D/Q/DL/S/SL kk4.4.2_1.0.0"](https://community.nxp.com/docs/DOC-101561)
  (needs an NXP account to access), covered Android 4.4.2 KitKat on the i.MX6**SL**
  (GPU+EPD variant) officially. No equivalent was ever released for the SLL — it
  postdates NXP's mainstream Android BSP program. Confirms 4.4.2 as the real ceiling
  of "vendor took Android + EPD seriously" on this chip family, independent of the
  Tolino angle.

### Phased plan
0. Build host: old JDK/toolchain for `android-4.4.2_r2`-era AOSP; a period-correct
   Ubuntu container is the standard approach.
1. Extract & assess Kobo's vendor kernel (`kernel.tar.bz2`) for existing
   ashmem/binder/early_suspend/lowmemorykiller support.
2. Android-ize the kernel where those are missing, using marek-g's tree as a pattern
   reference (not a direct merge — different SoC).
3. Bootloader: reuse your existing U-Boot, chain to an Android boot image.
4. AOSP userspace: no `device/kobo/clara` tree exists; write one from scratch using
   the emulator's software-rendered `goldfish` target as a `BoardConfig.mk`/gralloc
   template.
5. Port kobo-service + coolreader3, adapting `MXCFB_*` ioctl calls if the EPDC
   interface differs between i.MX507 and i.MX6SLL generations.
6. WiFi HAL wiring against Kobo's already-working in-kernel RTL8189FTV driver.
7. Hardware bring-up iteration.

This path is strictly more work than Section 2's — no real device tree, no proven
WiFi HAL wiring, no existing recovery tooling — which is why it's now the fallback.
