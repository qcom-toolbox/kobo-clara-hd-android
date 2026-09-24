# Device-side helper scripts

Small scripts that are pushed to `/data/local/tmp` and run on the Kobo. They
exist because the shell on this image is missing most of what you would reach
for -- no `tail`, `wc`, `cp`, `pidof`, `timeout` -- and because `su` here has
no capabilities beyond setuid/setgid, so anything touching `/system` has to go
through `runas_uid 1000` (uid `system` owns `/system` in this image).

| script | what it does |
| --- | --- |
| `hwc_install.sh` | installs a new `hwcomposer.imx6.so` |
| `hwc_wrap.sh` | runs the installer as uid 1000 (`su -c` takes a single argument, hence the wrapper) |
| `readlog.sh` | copies the composer's diagnostic log somewhere `adb pull` can reach |

## Installing the composer: always by rename

`hwc_install.sh` stages `hwcomposer.imx6.so.new` and renames it over the
target. **Never** write the file in place: SurfaceFlinger has it mmap'd, so
rewriting the same inode swaps its code underneath a running process. That
segfaults SurfaceFlinger; init restarts it, `bootanimation` starts again, and
because `sys.boot_completed` is already 1 nothing ever tells the animation to
exit -- the device then sits on the boot screen until it is power-cycled.

```sh
adb push hwcomposer.imx6.so /data/local/tmp/
adb shell 'su -c /data/local/tmp/hwc_wrap.sh'
adb reboot          # SurfaceFlinger is a core service; "stop; start" will not reload it
```

## The diagnostic build

`gralloc_eink/src/cutils/log.h` is a local stand-in for the real liblog that
writes to `/gralloc_eink_log.txt` instead of logcat, so the composer can be
traced without the log buffer rotating. The composer's vsync thread prints a
status line every five seconds, from its own loop rather than from anything
SurfaceFlinger drives -- so it still reports when composition has stopped
entirely, which is the case worth debugging:

```
status sets=216 composed=216 updates=35 identical=181 vsyncs=1 eventControl=2 \
       nudges=526 enabled=0 prepares=306 prep_layers=2 blanks=1 last_blank=0
```

That one line is what found both display bugs: `vsyncs=1` (SurfaceFlinger had
disabled vsync at boot and could never re-enable it) and `prepares` climbing
while `sets` stood still (SurfaceFlinger calling `prepare()` without ever
calling `set()`). See ROADMAP.md.

The build the port ships uses the real liblog headers, so none of this touches
the SD card in normal use.
