#!/bin/sh
# Turn a Tolino firmware update.zip into the android_root directory that
# build.sh patches.
#
#   ./build/extract_vendor_root.sh update.zip ~/tolino/android_root
#
# The update carries the two halves separately: /system as plain files, and
# the root filesystem (init, init.rc, the board rc, fstab) inside boot.img's
# ramdisk. This merges them and applies the modes from META/filesystem_config
# so the result matches what the device would have had.
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$BUILD_DIR/lib.sh"

[ $# -eq 2 ] || die "usage: $(basename "$0") <update.zip> <output android_root dir>"
ZIP=$1
OUT=$2
need unzip python3 cpio gzip

[ -f "$ZIP" ] || die "no such file: $ZIP"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
	die "$OUT exists and is not empty"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Unpacking the update"
unzip -q "$ZIP" -d "$TMP" || die "not a readable zip: $ZIP"
[ -d "$TMP/system" ] || die "no system/ in the update -- is this a Tolino ereader update.zip?"
[ -f "$TMP/boot.img" ] || die "no boot.img in the update"
info "system/ and boot.img found"

say "Extracting the ramdisk from boot.img"
python3 - "$TMP/boot.img" "$TMP/ramdisk.gz" <<'PY'
# Standard Android boot image: 8-byte magic, then kernel/ramdisk sizes; each
# section starts on a page boundary.
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    img = f.read()
if img[:8] != b'ANDROID!':
    sys.exit('boot.img does not start with ANDROID! -- unexpected format')
(kernel_size, _kernel_addr, ramdisk_size, _ramdisk_addr,
 _second_size, _second_addr, _tags_addr, page_size) = struct.unpack('<8I', img[8:40])


def pages(n):
    return (n + page_size - 1) // page_size


start = pages(1) * page_size + pages(kernel_size) * page_size
with open(dst, 'wb') as f:
    f.write(img[start:start + ramdisk_size])
print('    ramdisk: %d bytes (page size %d)' % (ramdisk_size, page_size))
PY

mkdir -p "$OUT"
( cd "$OUT" && gzip -dc "$TMP/ramdisk.gz" | cpio -idm --quiet ) \
	|| die "could not unpack the ramdisk"
[ -f "$OUT/init.rc" ] || die "no init.rc in the ramdisk"
info "root filesystem unpacked"

say "Merging /system"
# The ramdisk already has an empty /system mount point, so merge into it.
mkdir -p "$OUT/system"
cp -a "$TMP/system/." "$OUT/system/"
[ -f "$OUT/system/build.prop" ] || die "no system/build.prop after merge"

say "Applying file modes"
python3 - "$OUT" "$TMP/META" <<'PY'
# filesystem_config.txt lines: <path> <uid> <gid> <mode> [selabel=..] [caps=..]
# Only the mode is applied: building the image as an ordinary user cannot set
# ownership, and the image build fixes up the few files where it matters.
import os
import sys

root, meta = sys.argv[1], sys.argv[2]
applied = missing = 0
for name in ('filesystem_config.txt', 'boot_filesystem_config.txt'):
    path = os.path.join(meta, name)
    if not os.path.exists(path):
        continue
    for line in open(path, errors='replace'):
        parts = line.split()
        if len(parts) < 4:
            continue
        rel, _uid, _gid, mode = parts[0], parts[1], parts[2], parts[3]
        target = os.path.join(root, rel)
        if not os.path.lexists(target) or os.path.islink(target):
            missing += 1
            continue
        try:
            os.chmod(target, int(mode, 8))
            applied += 1
        except OSError:
            missing += 1
print('    %d modes applied, %d entries not present' % (applied, missing))
PY

say "Done"
info "android_root: $OUT"
info "build with: BUILD_VENDOR_ROOT=$OUT ./build/build.sh"
