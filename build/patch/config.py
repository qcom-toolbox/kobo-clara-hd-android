#!/usr/bin/env python3
"""Apply this port's config changes to a copy of the vendor android_root.

Everything here is idempotent and asserts on what it expects to find, so
re-running is safe and a different firmware revision fails loudly.

usage: config.py <android_root>
"""
import os
import re
import sys

ROOT = None


def path(*parts):
    return os.path.join(ROOT, *parts)


def read(p):
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        return f.read()


def write(p, text):
    with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(text)


def sub(p, old, new, what):
    """Replace unique text, or report that it is already applied."""
    text = read(p)
    if new in text:
        print('  = %s (already)' % what)
        return
    if text.count(old) != 1:
        sys.exit('! %s: expected exactly one match for:\n%s' % (p, old))
    write(p, text.replace(old, new))
    print('  + %s' % what)


def append_once(p, marker, block, what):
    text = read(p)
    if marker in text:
        print('  = %s (already)' % what)
        return
    write(p, text.rstrip('\n') + '\n' + block)
    print('  + %s' % what)


def default_prop():
    p = path('default.prop')
    text = read(p)
    out = []
    for line in text.split('\n'):
        if line.startswith('ro.secure='):
            line = 'ro.secure=0'
        elif line.startswith('ro.debuggable='):
            line = 'ro.debuggable=1'
        elif line.startswith('persist.sys.usb.config=') or line.startswith('sys.usb.config='):
            key = line.split('=', 1)[0]
            line = '%s=none' % key
        out.append(line)
    text = '\n'.join(out)
    for key, value in (('ro.secure', '0'), ('ro.debuggable', '1'),
                       ('persist.sys.usb.config', 'none'), ('sys.usb.config', 'none')):
        # Match at the start of a line: "sys.usb.config=" is a substring of
        # "persist.sys.usb.config=", so a plain `in text` test thinks it is
        # already set and sys.usb.config never gets written at all.
        if not re.search(r'^%s=' % re.escape(key), text, re.M):
            text = text.rstrip('\n') + '\n%s=%s\n' % (key, value)
    write(p, text)
    print('  + default.prop: ro.secure=0, ro.debuggable=1, usb config none')


def build_prop():
    p = path('system', 'build.prop')
    text = read(p)
    if 'qemu.hw.mainkeys' not in text:
        text = text.rstrip('\n') + '\n\n# Force the on-screen navigation bar (no hardware keys on this device).\nqemu.hw.mainkeys=0\n'
    if 'ro.product.model=Kobo Clara HD' not in text:
        out = []
        for line in text.split('\n'):
            if line.startswith('ro.product.model='):
                # The vendor firmware calls every device of this family
                # "tolino", which is what Settings shows as the model number.
                line = 'ro.product.model=Kobo Clara HD'
            out.append(line)
        text = '\n'.join(out)
    if 'ro.opengles.version' not in text:
        text = text.rstrip('\n') + ('\n\n# SwiftShader provides GLES 2.0 (it advertises 3.0; 2.0 is the level apps\n'
                 '# actually gate on). Without this property\n'
                 '# ActivityManager.getDeviceConfigurationInfo() reports no GLES at all and\n'
                 '# apps refuse to start ("your device does not support OpenGL ES 2.0").\n'
                 '# The vendor firmware set it for the GPU the Shine 3 has and this one\n'
                 '# does not.\n'
                 'ro.opengles.version=131072\n')
    if 'hw.backlight.dev' not in text:
        text += ('\n# Front light: LM3630A bank B drives the Clara HD front light (bank A is\n'
                 '# unused). The vendor lights HAL reads this property and writes\n'
                 '# /sys/class/backlight/<dev>/brightness (max_brightness 255 = Android range).\n'
                 'hw.backlight.dev=lm3630a_ledb\n')
    write(p, text)
    print('  + build.prop: qemu.hw.mainkeys=0, hw.backlight.dev=lm3630a_ledb,\n            ro.opengles.version=131072, ro.product.model=Kobo Clara HD')


def init_rc():
    p = path('init.rc')

    sub(p, '    setprop ro.adb.secure 1',
        '    # Not 1: key approval is answered by UsbDeviceManager\'s debugging\n'
        '    # prompt, which only runs with "USB debugging" enabled in Settings --\n'
        '    # and that setting stays off here (persist.sys.usb.config=none).\n'
        '    setprop ro.adb.secure 0',
        'init.rc: ro.adb.secure 0')

    # USB rules: the board file's rules drive the android_usb sysfs interface
    # that configfs replaced, so import the generic one too.
    text = read(p)
    if 'import /init.usb.rc' not in text:
        sub(p, 'import /init.trace.rc',
            'import /init.trace.rc\nimport /init.usb.rc',
            'init.rc: import /init.usb.rc')

    # The vendor remounts / read-only early in boot. On a normal Android
    # layout that is a small ramdisk root; here root, /system and /data are
    # one ext4 partition, so it makes the *whole filesystem* read-only and
    # nothing can boot -- the panel flashes once and stays white.
    sub(p, '    mount rootfs rootfs / ro remount',
        '    # (disabled: root and /system are one partition in this port, so this\n'
        '    # remount made the whole filesystem read-only rather than a small\n'
        '    # ramdisk root as it would on a normal Android layout.)\n'
        '    # mount rootfs rootfs / ro remount',
        'init.rc: do not remount / read-only')

    # on boot: wifi power + front light permissions
    text = read(p)
    if 'sdio_wifi_pwr.ko' not in text:
        sub(p, 'on boot\n',
            'on boot\n'
            '    # WiFi chip power (Kobo/Netronix ntx_wifi_power_ctrl: power + reset\n'
            '    # GPIOs, then an SDIO card-detect so the RTL8189FS enumerates).\n'
            '    insmod /system/lib/modules/sdio_wifi_pwr.ko\n'
            '\n'
            '    # Front light: the lights HAL runs in system_server (uid system) but\n'
            '    # the LM3630A sysfs files are root-owned.\n'
            '    chown system system /sys/class/backlight/lm3630a_ledb/brightness\n'
            '    chown system system /sys/class/backlight/lm3630a_ledb/bl_power\n'
            '    chmod 0664 /sys/class/backlight/lm3630a_ledb/brightness\n'
            '    chmod 0664 /sys/class/backlight/lm3630a_ledb/bl_power\n',
            'init.rc: wifi power + front light permissions')

    # servicemanager: our AOSP build, with its stderr captured (the vendor
    # prebuilt died repeatedly during bring-up, see ROADMAP 2.32).
    sub(p, 'service servicemanager /system/bin/servicemanager',
        'service servicemanager /system/bin/sh /svcmgr_wrapper.sh',
        'init.rc: servicemanager from AOSP source')

    services = '''
# --- Clara HD port ---------------------------------------------------------

# USB adb over configfs/FunctionFS (this kernel has no android_usb gadget).
service usb_adb_up /system/bin/sh /usb_adb_setup.sh
    class main
    user root
    group root system
    oneshot

# WiFi: the vendor defines wpa_supplicant in init.freescale.rc, which is not
# imported on this board (ro.hardware=E60K00). The driver itself is loaded by
# libhardware_legacy from /system/wifi/8189fs.ko.
service wpa_supplicant /system/bin/wpa_supplicant \\
    -iwlan0 -Dnl80211 -c/data/misc/wifi/wpa_supplicant.conf \\
    -I/system/etc/wifi/wpa_supplicant_overlay.conf \\
    -O/data/misc/wifi/sockets \\
    -e/data/misc/wifi/entropy.bin -g@android:wpa_wlan0
    socket wpa_wlan0 dgram 660 wifi wifi
    class main
    disabled
    oneshot

# Keep the OOM killer off watchdogd: killing it resets the device.
service oomprotect /system/bin/sh /system/bin/oom_protect.sh
    class main
    user root

# Keep adb alive: init.usb.rc stops adbd on sys.usb.config=none, which is
# what this port sets, and whether that fires before or after
# usb_adb_setup.sh's own "start adbd" is a race. See usb_adb_watch.sh.
service usb_adb_watch /system/bin/sh /usb_adb_watch.sh
    class main
    user root

# E-ink: pin the animation scales once boot has settled.
service noanim /system/bin/sh /system/bin/disable_anim.sh
    class main
    user root
    oneshot
'''
    append_once(p, 'service usb_adb_up', services, 'init.rc: usb_adb_up, wpa_supplicant, noanim services')


def board_rc():
    """init.E60K00.rc: the front light device, and its sysfs permissions."""
    p = path('init.E60K00.rc')
    if not os.path.exists(p):
        print('  ! %s missing, skipping board rc' % p)
        return
    sub(p, '    setprop hw.backlight.dev "mxc_msp430_fl.0"',
        '    # Clara HD: the front light is LM3630A bank B. mxc_msp430_fl.0 is the\n'
        '    # MSP430 companion of other NTX boards and does not exist here, so the\n'
        '    # lights HAL could not open its brightness file.\n'
        '    setprop hw.backlight.dev "lm3630a_ledb"',
        'init.E60K00.rc: backlight device')
    sub(p, '    chown system system /sys/class/backlight/mxc_msp430_fl.0/brightness',
        '    chown system system /sys/class/backlight/lm3630a_ledb/brightness\n'
        '    chown system system /sys/class/backlight/lm3630a_ledb/bl_power',
        'init.E60K00.rc: backlight owner')
    sub(p, '    chmod 0660 /sys/class/backlight/mxc_msp430_fl.0/brightness',
        '    chmod 0660 /sys/class/backlight/lm3630a_ledb/brightness\n'
        '    chmod 0660 /sys/class/backlight/lm3630a_ledb/bl_power',
        'init.E60K00.rc: backlight mode')


def board_rc_mount_all():
    """init.E60K00.rc: do not run mount_all.

    fstab.E60K00 describes a real 10-partition Android layout
    (mmcblk0p5=/system, p6=/cache, p7=/data, p8=/device, p10=/share). None of
    it exists here -- root, /system and /data are one combined ext4 partition
    -- so mount_all fails on the very first entry and aborts the action,
    taking the rest of boot with it. The panel flashes once and stays white,
    and adb never comes up.
    """
    p = path('init.E60K00.rc')
    if not os.path.exists(p):
        print('  ! %s missing, skipping mount_all' % p)
        return
    sub(p, '    mount_all /fstab.E60K00',
        '# mount_all disabled: fstab.E60K00 lists a real 10-partition Android\n'
        '# layout (mmcblk0p5=/system, p6=/cache, p7=/data, p8=/device,\n'
        '# p10=/share) that does not exist on our card -- root, /system and\n'
        '# /data are one combined ext4 partition already, mounted by the\n'
        '# kernel. mount_all fails on the first entry and aborts.\n'
        '#    mount_all /fstab.E60K00',
        'init.E60K00.rc: no mount_all')


def uncritical():
    """init.rc: drop "critical" from the services that cannot keep it.

    init reboots into recovery when a critical service dies four times in
    four minutes. On this port that is a trap rather than a safety net:
    servicemanager is our own wrapper script, and healthd talks to a battery
    HAL that is not the one this board has. A reboot into the Kobo's recovery
    partition looks exactly like a hang -- white screen, no adb -- so the
    flag comes off everything but ueventd.
    """
    p = path('init.rc')
    for name, block in (
            ('healthd', 'service healthd /sbin/healthd\n'
                        '    class core\n'
                        '    critical\n'),
            ('healthd-charger', 'service healthd-charger /sbin/healthd -n\n'
                                '    class charger\n'
                                '    critical\n'),
            ('servicemanager', '    group system\n'
                               '    critical\n'
                               '    onrestart restart healthd\n'),
    ):
        # Not sub(): the patched block is a prefix of the unpatched one, so
        # an "is the new text already there" test always says yes.
        text = read(p)
        if block not in text:
            print('  = init.rc: %s is not critical (already)' % name)
            continue
        write(p, text.replace(block, block.replace('    critical\n', '')))
        print('  + init.rc: %s is not critical' % name)


def fstab():
    """vold matches the volume by sysfs path; the vendor's is the 3.0 one."""
    p = path('fstab.E60K00')
    if not os.path.exists(p):
        print('  ! %s missing, skipping fstab' % p)
        return
    old = '/devices/platform/sdhci-esdhc-imx.1/mmc_host/mmc0 auto vfat defaults voldmanaged=sdcard1:4,noemulatedsd'
    new = ('# Kobo Clara HD, kernel 4.1 device tree: the boot SD is usdhc2 ->\n'
           '# /devices/platform/soc/2100000.aips-bus/2194000.usdhc/mmc_host/mmc0.\n'
           '# The vendor path below is the 3.0 platform-device name, which never\n'
           '# matches here, so vold left sdcard1 in No-Media and external storage\n'
           '# was never mounted.\n'
           '#' + old + '\n'
           '/devices/platform/soc/2100000.aips-bus/2194000.usdhc/mmc_host/mmc0 auto vfat defaults voldmanaged=sdcard1:4,noemulatedsd')
    sub(p, old, new, 'fstab.E60K00: vold sysfs path')


def main(argv):
    global ROOT
    if len(argv) != 2:
        sys.exit(__doc__)
    ROOT = argv[1]
    if not os.path.exists(path('init.rc')):
        sys.exit('%s does not look like an android_root (no init.rc)' % ROOT)
    default_prop()
    build_prop()
    init_rc()
    uncritical()
    board_rc()
    board_rc_mount_all()
    fstab()


if __name__ == '__main__':
    main(sys.argv)
