#!/system/bin/sh
# The diagnostic composer appends to /gralloc_eink_log.txt on the root
# filesystem (see gralloc_eink/src/cutils/log.h). This device has no tail/wc,
# so copy it somewhere adb can pull from and read it on the host.
cat /gralloc_eink_log.txt > /data/local/tmp/ge.txt
chmod 666 /data/local/tmp/ge.txt
