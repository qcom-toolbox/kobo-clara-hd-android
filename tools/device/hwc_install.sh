#!/system/bin/sh
# Install by RENAME, never in place: SurfaceFlinger has this library mmap'd,
# and rewriting the same inode swaps its code underneath it (SIGSEGV, then an
# orphaned bootanimation that never exits -- a hung device).
cat /data/local/tmp/hwcomposer.imx6.so > /system/lib/hw/hwcomposer.imx6.so.new
chmod 644 /system/lib/hw/hwcomposer.imx6.so.new
sync
mv /system/lib/hw/hwcomposer.imx6.so.new /system/lib/hw/hwcomposer.imx6.so
sync
ls -l /system/lib/hw/hwcomposer.imx6.so
