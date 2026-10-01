#!/system/bin/sh
# Runs our servicemanager (see servicemanager/README.md) and keeps whatever it
# says on the way out, because the vendor's prebuilt one died repeatedly during
# bring-up and this is how that was traced.
#
# The logs go in /data, not /. init starts this service as `user system`, and
# the root directory of the image this build produces is root:root 0755, so a
# redirect into / fails with EACCES -- the shell then exits before it ever
# execs servicemanager, init restarts it forever, and with no binder running
# zygote, surfaceflinger, media and netd all crash-loop behind it. The screen
# stays white and nothing says why. /data is system:system 0771, which this
# service can write.
/servicemanager_new 2>> /data/svcmgr_stderr.txt
echo "servicemanager_new exited: code=$? at $(date)" >> /data/svcmgr_exit.txt
sync
