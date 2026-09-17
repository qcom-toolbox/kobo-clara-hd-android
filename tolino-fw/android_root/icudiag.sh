#!/system/bin/sh
{
echo "=== date ==="
date
echo "=== ICU_DATA env var ==="
echo "ICU_DATA=$ICU_DATA"
echo "=== ANDROID_ROOT env var ==="
echo "ANDROID_ROOT=$ANDROID_ROOT"
echo "=== ls -la /system/usr/icu ==="
ls -la /system/usr/icu
echo "=== ls -la /system/usr ==="
ls -la /system/usr
echo "=== file size check via wc ==="
wc -c /system/usr/icu/icudt51l.dat
echo "=== first 64 bytes ==="
dd if=/system/usr/icu/icudt51l.dat bs=1 count=64 2>/dev/null | toolbox hexdump 2>&1
} > /icudiag_output.txt 2>&1
sync
