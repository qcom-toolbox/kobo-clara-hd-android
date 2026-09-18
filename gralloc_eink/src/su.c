/* Minimal su for adb debugging on the Kobo (this adbd never runs as root).
 * Installed as /system/xbin/su, owner root, group shell, mode 4750: only
 * the adb shell user (group 2000) can execute it; apps cannot.
 *   su            -> root shell
 *   su -c "cmd"   -> run cmd as root */
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <grp.h>

int main(int argc, char **argv)
{
	if (setgid(0) || setuid(0)) {
		perror("su: setuid");
		return 1;
	}
	setgroups(0, NULL);
	if (argc >= 3 && strcmp(argv[1], "-c") == 0)
		execl("/system/bin/sh", "sh", "-c", argv[2], (char *)NULL);
	else
		execl("/system/bin/sh", "sh", (char *)NULL);
	perror("su: exec");
	return 1;
}
