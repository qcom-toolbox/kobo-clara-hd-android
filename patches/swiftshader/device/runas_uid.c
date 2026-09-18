/* runas_uid <uid> <script>: switch to uid/gid and run script with sh.
 * Used from the Kobo's capability-less root shell (it keeps only
 * CAP_SETUID/CAP_SETGID) to act as the owner of /system files (uid 1000). */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <grp.h>
int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: runas_uid uid script\n"); return 1; }
	int id = atoi(argv[1]);
	if (setgroups(0, NULL) || setgid(id) || setuid(id)) { perror("runas_uid"); return 1; }
	execl("/system/bin/sh", "sh", argv[2], (char *)NULL);
	perror("exec");
	return 1;
}
