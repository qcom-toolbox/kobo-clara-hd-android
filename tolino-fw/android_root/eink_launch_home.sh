#!/system/bin/sh
i=0
while true; do
	i=$((i+1))
	{
		echo "=== attempt $i $(date) ==="
		/system/bin/am start -n de.telekom.epub/de.telekom.epub.ui.activities.HomeActivity
		echo "exit=$?"
	} >> /eink_launch_home.log 2>&1
	sync
	sleep 5
done
