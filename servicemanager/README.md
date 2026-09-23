# servicemanager

Android's `servicemanager` (the binder name registry every other service
registers with), built from AOSP `android-4.4.2_r2` — the same version as the
vendor firmware — rather than using the vendor's prebuilt binary, which died
repeatedly during bring-up and could not be debugged. See `ROADMAP.md`
section 2.32.

`service_manager.c`, `binder.c` and `binder.h` are the AOSP originals
(Apache-2.0, `frameworks/native/cmds/servicemanager`) with three local
changes so they build standalone against bionic, outside the AOSP build
system:

- `#include <string.h>`, which AOSP's build provided indirectly
- `ALOGI`/`ALOGE` defined as `fprintf(stderr, ...)` instead of liblog, so a
  failure is visible without a working logger
- the debug dump enabled (`#if 1`), for the same reason

It must be compiled with `-DBINDER_IPC_32BIT=1`: this kernel is built with
`CONFIG_ANDROID_BINDER_IPC_32BIT=y`, and that flag decides the size of
`struct binder_write_read`, which is baked into the `BINDER_WRITE_READ` ioctl
number itself. Without it every call fails with `EINVAL` before the kernel
looks at the payload.

The build compiles this and installs it as `/servicemanager_new`, started by
`/svcmgr_wrapper.sh`, which keeps its stderr in a file on the device.
