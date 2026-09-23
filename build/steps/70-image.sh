#!/bin/sh
# Build the SD card image: ext4 rootfs, kernel and dtb at the offsets Kobo's
# U-Boot loads them from, and the storage partition Android expects.
. "$BUILD_DIR/lib.sh"

say "Image"
ROOTFS_SECTOR=1097730   # start of p3, where android_root lives
KERNEL_SECTOR=2047      # NTX header + zImage
DTB_SECTOR=1285         # NTX header + dtb
P4_SECTOR=15491072      # first 2048-aligned sector after p3

info "building the ext4 root filesystem"
rm -f "$WORK/android_root.img"
mke2fs -F -t ext4 -O ^has_journal,^metadata_csum,^64bit,^metadata_csum_seed \
	-d "$OVERLAY" "$WORK/android_root.img" 1024M >/dev/null 2>&1 \
	|| die "mke2fs failed"

# su must be setuid root but runnable only by the adb shell (group shell).
for f in "uid 0" "gid 2000" "mode 0104750"; do
	debugfs -w -R "set_inode_field /system/xbin/su $f" "$WORK/android_root.img" >/dev/null 2>&1
done
debugfs -R "stat /system/xbin/su" "$WORK/android_root.img" 2>/dev/null | grep -q '04750' \
	|| warn "could not set su permissions; root over adb will not work"
e2fsck -fn "$WORK/android_root.img" >/dev/null 2>&1 || die "the root filesystem is not clean"

info "assembling $OUT_IMAGE"
cp "$BASE_IMAGE" "$OUT_IMAGE"
dd if="$WORK/kernel_with_header.bin" of="$OUT_IMAGE" bs=512 seek=$KERNEL_SECTOR conv=notrunc status=none
dd if="$WORK/dtb_with_header.bin"    of="$OUT_IMAGE" bs=512 seek=$DTB_SECTOR    conv=notrunc status=none
dd if="$WORK/android_root.img"       of="$OUT_IMAGE" bs=512 seek=$ROOTFS_SECTOR conv=notrunc status=none

# Android's primary storage is partition 4 of this very card (see
# fstab.E60K00). Add it, sized to the card the image is going onto.
python3 "$ROOT/patches/sdcard/add_p4.py" "$OUT_IMAGE" "$CARD_SECTORS"

# Stop the image before p4 so flashing never destroys that filesystem.
truncate -s $((P4_SECTOR * 512)) "$OUT_IMAGE"

say "Done"
info "image: $OUT_IMAGE ($(du -h "$OUT_IMAGE" | cut -f1))"
cat <<EOF

    Flash it, then format the storage partition once:

      sudo dd if=$OUT_IMAGE of=/dev/sdX bs=1M conv=fsync
      sudo mkfs.vfat -F 32 -n KOBO /dev/sdX4

    The first boot is slow: Dalvik re-optimizes the patched framework.
EOF
