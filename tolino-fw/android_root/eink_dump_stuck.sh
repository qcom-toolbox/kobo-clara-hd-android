#!/system/bin/sh
# Watches for any zygote-forked process still stuck at the "<pre-initialized>"
# placeholder name (set by zygote immediately post-fork, before the app
# renames itself) and sends it SIGQUIT so its own runtime dumps a full
# thread/stack trace to /data/anr/traces.txt -- the same mechanism
# system_server's own ANR handler already uses, just aimed at an
# app process instead.
#
# Also SIGQUITs system_server itself on every scan once boot has reached
# it. binder_trace.log showed system_server's own binder thread (the one
# that receives the incoming attachApplication() transaction) simply never
# calls ioctl() again for the rest of the boot -- i.e. system_server itself
# hangs handling attachApplication(), which is why the newly-forked app
# process never gets a reply. We need system_server's own Dalvik stack at
# that moment to see exactly what it's stuck on.
i=0
while true; do
	i=$((i+1))
	{
		echo "=== scan $i $(date) ==="
		ps | grep "pre-initialized" | while read -r user pid rest; do
			echo "found stuck pid=$pid: $user $pid $rest"
			kill -3 "$pid"
			echo "sent SIGQUIT to $pid"
		done
		ps | grep "system_server" | while read -r user pid rest; do
			echo "dumping system_server pid=$pid: $user $pid $rest"
			kill -3 "$pid"
			echo "sent SIGQUIT to system_server $pid"
		done
	} >> /eink_dump_stuck.log 2>&1
	sync
	sleep 15
done
