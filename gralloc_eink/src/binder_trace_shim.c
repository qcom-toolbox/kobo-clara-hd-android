/*
 * LD_PRELOAD shim: transparently intercepts ioctl(BINDER_WRITE_READ) calls
 * from WITHIN the real, unmodified framework -- no framework binary is
 * touched. Preloaded into zygote's own process (via a `setenv LD_PRELOAD`
 * line on its init.rc service), it is automatically inherited into every
 * process zygote later fork()s (Dalvik does not re-run the dynamic linker
 * or re-apply LD_PRELOAD on fork -- the mapping is simply already there),
 * so it covers zygote itself, system_server, and every real app process
 * -- including the one that hangs -- for free.
 *
 * Logs, for every BINDER_WRITE_READ ioctl on every process: pid/tid, the
 * write buffer's leading command (decoded if it's BC_TRANSACTION/BC_REPLY,
 * including target handle for transactions), write/read sizes and consumed
 * counts before and after the call, and wall-clock elapsed time -- enough
 * to see, from the real hang itself, exactly which command was in flight
 * and for how long, without needing to reproduce anything.
 */
#define BINDER_IPC_32BIT 1
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <linux/android/binder.h>

#define LOGF "/binder_trace.log"

static int (*real_ioctl)(int, int, ...);
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *g_log;

__attribute__((constructor))
static void shim_init(void)
{
	void *libc = dlopen("libc.so", RTLD_NOW);
	if (libc)
		real_ioctl = dlsym(libc, "ioctl");
}

static long long now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static const char *cmd_name(uint32_t cmd)
{
	switch (cmd) {
	case BC_TRANSACTION: return "BC_TRANSACTION";
	case BC_REPLY: return "BC_REPLY";
	case BC_ENTER_LOOPER: return "BC_ENTER_LOOPER";
	case BC_REGISTER_LOOPER: return "BC_REGISTER_LOOPER";
	case BC_EXIT_LOOPER: return "BC_EXIT_LOOPER";
	case BC_FREE_BUFFER: return "BC_FREE_BUFFER";
	case BR_TRANSACTION: return "BR_TRANSACTION";
	case BR_REPLY: return "BR_REPLY";
	case BR_TRANSACTION_COMPLETE: return "BR_TRANSACTION_COMPLETE";
	case BR_NOOP: return "BR_NOOP";
	case BR_DEAD_REPLY: return "BR_DEAD_REPLY";
	case BR_FAILED_REPLY: return "BR_FAILED_REPLY";
	case BR_SPAWN_LOOPER: return "BR_SPAWN_LOOPER";
	case BR_INCREFS: return "BR_INCREFS";
	case BR_ACQUIRE: return "BR_ACQUIRE";
	case BR_RELEASE: return "BR_RELEASE";
	case BR_DECREFS: return "BR_DECREFS";
	default: return "?";
	}
}

int ioctl(int fd, int request, ...)
{
	va_list ap;
	va_start(ap, request);
	void *argp = va_arg(ap, void *);
	va_end(ap);

	if (!real_ioctl) {
		void *libc = dlopen("libc.so", RTLD_NOW);
		real_ioctl = libc ? dlsym(libc, "ioctl") : NULL;
	}

	if (request != BINDER_WRITE_READ || !argp)
		return real_ioctl(fd, request, argp);

	struct binder_write_read *bwr = argp;
	binder_size_t in_write_size = bwr->write_size;
	binder_size_t in_read_size = bwr->read_size;
	uint32_t first_write_cmd = 0;
	uint32_t write_handle = 0xffffffff;
	if (bwr->write_buffer && bwr->write_size >= sizeof(uint32_t)) {
		uint32_t *w = (uint32_t *)(uintptr_t)bwr->write_buffer;
		first_write_cmd = w[0];
		if ((first_write_cmd == BC_TRANSACTION || first_write_cmd == BC_REPLY) &&
		    bwr->write_size >= sizeof(uint32_t) + sizeof(struct binder_transaction_data)) {
			struct binder_transaction_data *tr =
				(struct binder_transaction_data *)(w + 1);
			write_handle = tr->target.handle;
		}
	}

	long long t0 = now_ns();
	int ret = real_ioctl(fd, request, argp);
	int saved_errno = errno;
	long long t1 = now_ns();

	uint32_t first_read_cmd = 0;
	if (bwr->read_buffer && bwr->read_consumed >= sizeof(uint32_t))
		first_read_cmd = ((uint32_t *)(uintptr_t)bwr->read_buffer)[0];

	pthread_mutex_lock(&g_log_lock);
	if (!g_log) {
		g_log = fopen(LOGF, "a");
		if (g_log)
			setvbuf(g_log, NULL, _IONBF, 0);
	}
	if (g_log) {
		fprintf(g_log,
			"[%lld.%03lld] pid=%d tid=%d fd=%d w_in=%u(%s h=%u) r_in=%u "
			"-> ret=%d errno=%d w_consumed=%u r_consumed=%u first_r=%s dur_us=%lld\n",
			t1 / 1000000000LL, (t1 / 1000000LL) % 1000,
			getpid(), gettid(), fd,
			(unsigned)in_write_size, cmd_name(first_write_cmd), write_handle,
			(unsigned)in_read_size,
			ret, ret < 0 ? saved_errno : 0,
			(unsigned)bwr->write_consumed, (unsigned)bwr->read_consumed,
			cmd_name(first_read_cmd), (t1 - t0) / 1000);
	}
	pthread_mutex_unlock(&g_log_lock);

	errno = saved_errno;
	return ret;
}
