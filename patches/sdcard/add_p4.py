#!/usr/bin/env python3
"""Add partition 4 (FAT32) to a Kobo SD image's MBR.

The vendor fstab maps Android's *primary* external storage to
    /devices/platform/sdhci-esdhc-imx.1/mmc_host/mmc0 ... voldmanaged=sdcard1:4
i.e. the 4th partition of the boot SD card, and framework-res's
storage_list.xml marks /storage/sdcard1 primary and non-removable. Our
image only carried 3 partitions, so vold had nothing to mount: every app
using external storage failed (the stock Browser crashes outright with
"Invalid mkdirs path: /mnt/media_rw/sdcard1/...").

usage: add_p4.py <image> <card_size_in_512b_sectors>
       (cat /sys/block/sdX/size, or /sys/class/block/mmcblk0/size on device)
"""
import struct
import sys

START = 15491072  # first 2048-aligned sector after p3 (which ends at 15491070)


def main(path, total):
    with open(path, 'r+b') as f:
        mbr = bytearray(f.read(512))
        if mbr[510:512] != b'\x55\xaa':
            sys.exit('not an MBR: bad signature')
        off = 446 + 16 * 3
        p3_end = struct.unpack('<I', mbr[446 + 16 * 2 + 8:446 + 16 * 2 + 12])[0] + \
            struct.unpack('<I', mbr[446 + 16 * 2 + 12:446 + 16 * 2 + 16])[0]
        if START < p3_end:
            sys.exit('p4 would overlap p3 (ends at %d)' % p3_end)
        if total <= START:
            sys.exit('card too small for p4')
        entry = bytearray(16)
        entry[1:4] = b'\xfe\xff\xff'   # CHS start: LBA-only marker
        entry[4] = 0x0c                # FAT32 (LBA)
        entry[5:8] = b'\xfe\xff\xff'   # CHS end
        entry[8:12] = struct.pack('<I', START)
        entry[12:16] = struct.pack('<I', total - START)
        mbr[off:off + 16] = entry
        f.seek(0)
        f.write(bytes(mbr))
    print('p4: start %d, %d sectors (%.1f GB) -- format after flashing:'
          % (START, total - START, (total - START) * 512 / 1e9))
    print('  sudo mkfs.vfat -F 32 -n KOBO /dev/sdX4')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]))
