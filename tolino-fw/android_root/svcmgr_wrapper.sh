#!/system/bin/sh
/servicemanager_new 2>> /svcmgr_new_stderr.txt
echo "servicemanager_new exited: code=$? at $(date)" >> /svcmgr_exit.txt
sync
