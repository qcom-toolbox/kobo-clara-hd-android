/*
 * Minimal, raw ioctl(BINDER_WRITE_READ) probe -- bypasses libbinder/Dalvik
 * entirely. Isolates exactly how a process ends up talking to servicemanager
 * (handle 0, the special "context manager" target) and whether that round
 * trip can hang, without any Zygote/Dalvik/ActivityThread complexity in the
 * way -- since a real Zygote-forked app process has been observed to hang
 * forever making this exact call.
 *
 * Modes (argv[1]):
 *   (no args)         -- open+mmap+transact directly, stay root.
 *   <uid>              -- open+mmap as root, setuid(uid), then transact.
 *   fork               -- open+mmap as root, fork(), CHILD transacts using
 *                          the INHERITED fd/mapping (no fresh open() in the
 *                          child) -- tests whether a fork()-inherited binder
 *                          connection can complete this round trip at all.
 *   forkuid <uid>      -- same as fork, but the CHILD also setuid(uid)
 *                          before transacting -- matches the real Zygote
 *                          scenario (root parent, fork, child drops to an
 *                          app uid, reuses the inherited binder fd) as
 *                          closely as a native-only test can.
 *   mtfork <uid>       -- same as forkuid, but the PARENT first spawns
 *                          several idle background pthreads (mimicking
 *                          Zygote's real state at fork time: GC, JIT/
 *                          Compiler, Signal Catcher, JDWP, etc. all alive)
 *                          before calling fork() -- since POSIX fork()
 *                          only carries the calling thread into the child,
 *                          this tests whether stale per-thread binder
 *                          driver state left behind by the vanished
 *                          sibling threads can cause a reply to get
 *                          misrouted/lost for the surviving child thread.
 *   bpoolfork <uid>    -- same as forkuid, but the PARENT first spawns a
 *                          REAL binder threadpool worker (BC_ENTER_LOOPER
 *                          then a blocking ioctl(BINDER_WRITE_READ) read,
 *                          exactly like IPCThreadState::joinThreadPool())
 *                          on the INHERITED fd before forking -- unlike
 *                          mtfork's binder-unaware idle threads, this
 *                          worker is genuinely registered with the kernel
 *                          driver's binder_proc thread table at fork time,
 *                          closely matching what a real Zygote (which
 *                          calls ProcessState::self() and typically has an
 *                          active thread pool) actually looks like when it
 *                          forks a new app process.
 *   postfork <uid>     -- fork() first (no pre-fork threads at all), THEN
 *                          in the CHILD (using the inherited fd) setuid(),
 *                          spawn a binder threadpool worker (BC_ENTER_LOOPER
 *                          + blocking read), and only then have the ORIGINAL
 *                          (main) thread issue the transact()+wait -- this
 *                          is the one combination not yet tested: a second,
 *                          genuinely-registered binder thread coexisting
 *                          *in the same post-fork process* as the thread
 *                          making the blocking transaction, exactly
 *                          matching Zygote's real order of operations
 *                          (fork, then onZygoteInit() -> startThreadPool(),
 *                          then much later ActivityThread.attach()) --
 *                          since a real Binder_1 pool thread was confirmed
 *                          alive via tombstone dumps of the actual hang.
 */
#define BINDER_IPC_32BIT 1
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <poll.h>
#include <pthread.h>
#include <linux/android/binder.h>

#define LOGF "/binder_probe_output.txt"

static FILE *g_log;

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	if (g_log) {
		vfprintf(g_log, fmt, ap);
		fprintf(g_log, "\n");
		fflush(g_log);
	}
	va_end(ap);
}

/* Sends one BC_TRANSACTION to handle 0 on fd, then polls (with a 30s
 * timeout) until a final reply command is seen or time runs out. */
static void do_transact_and_wait(int fd, const char *tag)
{
	struct binder_transaction_data txn;
	memset(&txn, 0, sizeof(txn));
	txn.target.handle = 0;
	txn.code = 0;
	txn.flags = 0;
	txn.data_size = 0;
	txn.offsets_size = 0;

	uint32_t writebuf[1 + (sizeof(txn) + 3) / 4];
	writebuf[0] = BC_TRANSACTION;
	memcpy(&writebuf[1], &txn, sizeof(txn));
	size_t write_size = sizeof(uint32_t) + sizeof(txn);

	uint32_t readbuf[256];
	struct binder_write_read bwr;
	memset(&bwr, 0, sizeof(bwr));
	bwr.write_size = write_size;
	bwr.write_buffer = (binder_uintptr_t)(uintptr_t)writebuf;
	bwr.read_size = sizeof(readbuf);
	bwr.read_buffer = (binder_uintptr_t)(uintptr_t)readbuf;

	logmsg("[%s] issuing BC_TRANSACTION to handle 0, pid=%d uid=%d ...",
		tag, getpid(), getuid());

	int ret = ioctl(fd, BINDER_WRITE_READ, &bwr);
	logmsg("[%s] ioctl#1 ret=%d errno=%d(%s) write_consumed=%u read_consumed=%u",
		tag, ret, errno, strerror(errno),
		(unsigned)bwr.write_consumed, (unsigned)bwr.read_consumed);
	for (unsigned i = 0; i * 4 < bwr.read_consumed && i < 256; i++)
		logmsg("[%s]   read[%u] = 0x%08x", tag, i, readbuf[i]);

	int got_final = 0;
	time_t start = time(NULL);
	while (!got_final && (time(NULL) - start) < 30) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int pr = poll(&pfd, 1, 5000);
		logmsg("[%s] poll() = %d errno=%d(%s) revents=0x%x elapsed=%lds",
			tag, pr, errno, strerror(errno), pfd.revents,
			(long)(time(NULL) - start));
		if (pr <= 0)
			continue;

		memset(&bwr, 0, sizeof(bwr));
		bwr.write_size = 0;
		bwr.read_size = sizeof(readbuf);
		bwr.read_buffer = (binder_uintptr_t)(uintptr_t)readbuf;
		ret = ioctl(fd, BINDER_WRITE_READ, &bwr);
		logmsg("[%s] ioctl#N ret=%d errno=%d(%s) read_consumed=%u",
			tag, ret, errno, strerror(errno), (unsigned)bwr.read_consumed);
		for (unsigned i = 0; i * 4 < bwr.read_consumed && i < 256; i++) {
			logmsg("[%s]   read[%u] = 0x%08x", tag, i, readbuf[i]);
			uint32_t cmd = readbuf[i];
			if (cmd == BR_REPLY || cmd == BR_DEAD_REPLY || cmd == BR_FAILED_REPLY) {
				logmsg("[%s] *** got final reply command 0x%08x ***", tag, cmd);
				got_final = 1;
			}
		}
	}
	if (!got_final)
		logmsg("[%s] *** TIMED OUT after 30s waiting for a final reply ***", tag);
}

static volatile int g_stop_idle;

static void *idle_thread_main(void *arg)
{
	(void)arg;
	while (!g_stop_idle)
		usleep(50000);
	return NULL;
}

/* Mimics IPCThreadState::joinThreadPool(): registers as a looper thread,
 * then blocks in a real ioctl(BINDER_WRITE_READ) read -- exactly what a
 * genuine binder threadpool worker does while idle, waiting for incoming
 * transactions. This thread is a real entry in the kernel driver's
 * binder_proc thread table at the moment the parent calls fork(). */
static void *binder_pool_thread_main(void *arg)
{
	int fd = *(int *)arg;
	uint32_t enter_looper = BC_ENTER_LOOPER;
	struct binder_write_read bwr;
	memset(&bwr, 0, sizeof(bwr));
	bwr.write_size = sizeof(enter_looper);
	bwr.write_buffer = (binder_uintptr_t)(uintptr_t)&enter_looper;
	int ret = ioctl(fd, BINDER_WRITE_READ, &bwr);
	logmsg("[bpool] BC_ENTER_LOOPER ioctl ret=%d errno=%d(%s)",
		ret, errno, strerror(errno));

	uint32_t readbuf[64];
	while (!g_stop_idle) {
		memset(&bwr, 0, sizeof(bwr));
		bwr.read_size = sizeof(readbuf);
		bwr.read_buffer = (binder_uintptr_t)(uintptr_t)readbuf;
		ioctl(fd, BINDER_WRITE_READ, &bwr); /* blocks until work or a signal */
	}
	return NULL;
}

int main(int argc, char **argv)
{
	g_log = fopen(LOGF, "a");
	if (!g_log)
		return 1;
	setvbuf(g_log, NULL, _IONBF, 0);

	const char *mode = (argc > 1) ? argv[1] : "direct";
	logmsg("=== binder_probe start pid=%d starting_uid=%d mode=%s ===",
		getpid(), getuid(), mode);

	int fd = open("/dev/binder", O_RDWR | O_CLOEXEC);
	logmsg("open(/dev/binder) = %d errno=%d(%s)", fd, errno, strerror(errno));
	if (fd < 0)
		return 1;

	size_t mapsize = 128 * 1024;
	void *vm = mmap(NULL, mapsize, PROT_READ, MAP_PRIVATE | MAP_NORESERVE, fd, 0);
	logmsg("mmap() = %p errno=%d(%s)", vm, errno, strerror(errno));
	if (vm == MAP_FAILED)
		return 1;

	if (strcmp(mode, "fork") == 0 || strcmp(mode, "forkuid") == 0 ||
	    strcmp(mode, "mtfork") == 0 || strcmp(mode, "bpoolfork") == 0 ||
	    strcmp(mode, "postfork") == 0) {
		uid_t child_uid = (uid_t)-1;
		if ((strcmp(mode, "forkuid") == 0 || strcmp(mode, "mtfork") == 0 ||
		     strcmp(mode, "bpoolfork") == 0 || strcmp(mode, "postfork") == 0) && argc > 2)
			child_uid = (uid_t)atoi(argv[2]);

		if (strcmp(mode, "mtfork") == 0) {
			pthread_t threads[6];
			int nthreads = 0;
			for (int i = 0; i < 6; i++) {
				if (pthread_create(&threads[i], NULL, idle_thread_main, NULL) == 0)
					nthreads++;
			}
			logmsg("spawned %d idle background threads before forking (mimicking a busy Dalvik VM)",
				nthreads);
			usleep(200000); /* let them actually start running first */
		}

		if (strcmp(mode, "bpoolfork") == 0) {
			pthread_t pool_thread;
			int rc = pthread_create(&pool_thread, NULL, binder_pool_thread_main, &fd);
			logmsg("pthread_create(binder pool worker) = %d", rc);
			usleep(300000); /* let it actually reach the blocking read */
		}

		logmsg("about to fork(); parent pid=%d, will use INHERITED fd=%d in child",
			getpid(), fd);
		pid_t pid = fork();
		if (pid < 0) {
			logmsg("fork() failed errno=%d(%s)", errno, strerror(errno));
			return 1;
		}
		if (pid == 0) {
			/* child: reuse the INHERITED fd/mapping, no fresh open(). */
			if (child_uid != (uid_t)-1) {
				int rc = setuid(child_uid);
				logmsg("[child] setuid(%d) = %d errno=%d(%s) now uid=%d",
					(int)child_uid, rc, errno, strerror(errno), getuid());
			}
			if (strcmp(mode, "postfork") == 0) {
				/* Spawn the child's OWN binder threadpool worker
				 * AFTER fork+setuid (matching Zygote's real order:
				 * fork/specialize, then onZygoteInit() -> startThreadPool(),
				 * then much later ActivityThread.attach()) so it
				 * coexists with the main thread's blocking transact
				 * call in the SAME post-fork process, instead of
				 * vanishing at fork like bpoolfork's pre-fork worker. */
				pthread_t pool_thread;
				int rc = pthread_create(&pool_thread, NULL, binder_pool_thread_main, &fd);
				logmsg("[child] pthread_create(post-fork binder pool worker) = %d", rc);
				usleep(300000); /* let it actually reach the blocking read */
			}
			do_transact_and_wait(fd, "child-inherited-fd");
			logmsg("=== binder_probe (child) end ===");
			fclose(g_log);
			_exit(0);
		}
		/* parent: just wait for the child, don't touch fd ourselves. */
		int status = 0;
		waitpid(pid, &status, 0);
		logmsg("[parent] child pid=%d exited status=0x%x", pid, status);
		logmsg("=== binder_probe (parent) end ===");
		fclose(g_log);
		return 0;
	}

	if (strcmp(mode, "direct") != 0) {
		uid_t want_uid = (uid_t)atoi(mode);
		int rc = setuid(want_uid);
		logmsg("setuid(%d) = %d errno=%d(%s) now uid=%d",
			(int)want_uid, rc, errno, strerror(errno), getuid());
	}

	do_transact_and_wait(fd, "direct");
	logmsg("=== binder_probe end ===");
	fclose(g_log);
	return 0;
}
