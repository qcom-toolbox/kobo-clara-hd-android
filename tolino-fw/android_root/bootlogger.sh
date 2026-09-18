#!/system/bin/sh
i=0
while true; do
    i=$((i+1))
    { echo "===TICK $i $(date)==="; ps; dmesg -c; } >> /bootlog.txt 2>&1
    sync
    sleep 10
done
