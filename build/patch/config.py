#!/usr/bin/env python3
"""Apply this port's config changes to a copy of the vendor android_root.

Everything here is idempotent and asserts on what it expects to find, so
re-running is safe and a different firmware revision fails loudly.

usage: config.py <android_root>
"""
import os
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
        if '%s=' % key not in text:
            text = text.rstrip('\n') + '\n%s=%s\n' % (key, value)
    write(p, text)
    print('  + default.prop: ro.secure=0, ro.debuggable=1, usb config none')


def build_prop():
    p = path('system', 'build.prop')
    text = read(p)
    if 'qemu.hw.mainkeys' not in text:
        text = text.rstrip('\n') + '\n\n# Force the on-screen navigation bar (no hardware keys on this device).\nqemu.hw.mainkeys=0\n'
    if 'hw.backlight.dev' not in text:
        text += ('\n# Front light: LM3630A bank B drives the Clara HD front light (bank A is\n'
                 '# unused). The vendor lights HAL reads this property and writes\n'
                 '# /sys/class/backlight/<dev>/brightness (max_brightness 255 = Android range).\n'
                 'hw.backlight.dev=lm3630a_ledb\n')
    write(p, text)
    print('  + build.prop: qemu.hw.mainkeys=0, hw.backlight.dev=lm3630a_ledb')


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
    board_rc()
    fstab()


if __name__ == '__main__':
    main(sys.argv)
