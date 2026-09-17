/*
 * Thin wrapper gralloc module: dlopen()s the REAL vendor gralloc.default.so
 * (renamed to gralloc.default.real.so) and delegates everything to it
 * completely unchanged, EXCEPT the framebuffer device's function pointers,
 * which get trampolined so we can fire the e-ink MXCFB_SEND_UPDATE refresh
 * after every real post() -- without reimplementing any of the vendor's own
 * allocator/mapper/framebuffer-mapping logic ourselves.
 *
 * Every trampoline substitutes the REAL device pointer before calling
 * through, so vendor code only ever sees its own, correctly-laid-out
 * private struct -- never our wrapper's memory.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <pthread.h>

#include <hardware/hardware.h>
#include <hardware/gralloc.h>
#include <hardware/fb.h>
#include <linux/mxcfb.h>

#include "cutils/log.h"

#define REAL_MODULE_PATH "/system/lib/hw/gralloc.default.real.so"

static void *g_real_handle;
static const hw_module_t *g_real_module;

/*
 * Buffer geometry side-table: hwc_layer_1_t only carries an opaque
 * buffer_handle_t, with no width/height/stride/format. The real vendor
 * gralloc's private handle layout is unknown to us, so instead we record
 * geometry ourselves at alloc() time (where w/h/format are inputs and
 * stride is a real output) and expose it to hwcomposer.imx6.so (loaded
 * into the same process) via a plain exported query function.
 */
#define EINK_MAX_BUFS 64

typedef struct {
	buffer_handle_t handle;
	int width, height, stride, format;
} eink_buf_info_t;

static eink_buf_info_t g_bufs[EINK_MAX_BUFS];
static pthread_mutex_t g_bufs_lock = PTHREAD_MUTEX_INITIALIZER;

static void eink_buf_record(buffer_handle_t handle, int w, int h, int stride, int format)
{
	pthread_mutex_lock(&g_bufs_lock);
	int slot = -1;
	for (int i = 0; i < EINK_MAX_BUFS; i++) {
		if (g_bufs[i].handle == handle) { slot = i; break; }
		if (slot < 0 && g_bufs[i].handle == NULL) slot = i;
	}
	if (slot >= 0) {
		g_bufs[slot].handle = handle;
		g_bufs[slot].width = w;
		g_bufs[slot].height = h;
		g_bufs[slot].stride = stride;
		g_bufs[slot].format = format;
	}
	pthread_mutex_unlock(&g_bufs_lock);
}

static void eink_buf_forget(buffer_handle_t handle)
{
	pthread_mutex_lock(&g_bufs_lock);
	for (int i = 0; i < EINK_MAX_BUFS; i++) {
		if (g_bufs[i].handle == handle) {
			memset(&g_bufs[i], 0, sizeof(g_bufs[i]));
			break;
		}
	}
	pthread_mutex_unlock(&g_bufs_lock);
}

int eink_gralloc_query(buffer_handle_t handle, int *w, int *h, int *stride, int *format);
int eink_gralloc_query(buffer_handle_t handle, int *w, int *h, int *stride, int *format)
{
	int ret = -1;
	pthread_mutex_lock(&g_bufs_lock);
	for (int i = 0; i < EINK_MAX_BUFS; i++) {
		if (g_bufs[i].handle == handle) {
			if (w) *w = g_bufs[i].width;
			if (h) *h = g_bufs[i].height;
			if (stride) *stride = g_bufs[i].stride;
			if (format) *format = g_bufs[i].format;
			ret = 0;
			break;
		}
	}
	pthread_mutex_unlock(&g_bufs_lock);
	return ret;
}

static int ensure_real_loaded(void)
{
	if (g_real_module)
		return 0;
	g_real_handle = dlopen(REAL_MODULE_PATH, RTLD_NOW);
	if (!g_real_handle) {
		ALOGE("eink_wrapper: dlopen(%s) failed: %s", REAL_MODULE_PATH, dlerror());
		return -1;
	}
	g_real_module = (const hw_module_t *)dlsym(g_real_handle, HAL_MODULE_INFO_SYM_AS_STR);
	if (!g_real_module) {
		ALOGE("eink_wrapper: dlsym(%s) failed: %s", HAL_MODULE_INFO_SYM_AS_STR, dlerror());
		return -1;
	}
	return 0;
}

static int g_post_count;

static void eink_send_update(int fd, int xres, int yres)
{
	struct mxcfb_update_data update;
	memset(&update, 0, sizeof(update));
	update.update_region.left = 0;
	update.update_region.top = 0;
	update.update_region.width = xres;
	update.update_region.height = yres;
	update.waveform_mode = WAVEFORM_MODE_AUTO;
	update.update_mode = UPDATE_MODE_FULL;
	update.temp = TEMP_USE_AMBIENT;
	update.flags = 0;
	int ret = ioctl(fd, MXCFB_SEND_UPDATE, &update);
	if (ret == -1)
		ALOGE("eink_wrapper: MXCFB_SEND_UPDATE failed: %s", strerror(errno));
	else if (g_post_count <= 5 || (g_post_count % 50) == 0)
		ALOGI("eink_wrapper: MXCFB_SEND_UPDATE #%d ok fd=%d %dx%d", g_post_count, fd, xres, yres);
}

typedef struct {
	framebuffer_device_t device;   /* must be first: doubles as hw_device_t* */
	framebuffer_device_t *real_dev;
	int eink_fd;
} eink_fb_wrapper_t;

static int eink_fb_setSwapInterval(struct framebuffer_device_t *dev, int interval)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	if (!w->real_dev->setSwapInterval)
		return 0;
	return w->real_dev->setSwapInterval(w->real_dev, interval);
}

static int eink_fb_setUpdateRect(struct framebuffer_device_t *dev, int l, int t, int wd, int h)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	if (!w->real_dev->setUpdateRect)
		return -EINVAL;
	return w->real_dev->setUpdateRect(w->real_dev, l, t, wd, h);
}

static int eink_fb_post(struct framebuffer_device_t *dev, buffer_handle_t buffer)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	g_post_count++;
	if (g_post_count <= 5)
		ALOGI("eink_wrapper: post() #%d called, w=%p buffer=%p", g_post_count, (void*)w, (void*)buffer);
	int ret = w->real_dev->post(w->real_dev, buffer);
	if (g_post_count <= 5)
		ALOGI("eink_wrapper: post() #%d real post returned %d", g_post_count, ret);
	if (ret == 0 && w->eink_fd >= 0)
		eink_send_update(w->eink_fd, w->device.width, w->device.height);
	return ret;
}

static int eink_fb_compositionComplete(struct framebuffer_device_t *dev)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	if (!w->real_dev->compositionComplete)
		return 0;
	return w->real_dev->compositionComplete(w->real_dev);
}

static void eink_fb_dump(struct framebuffer_device_t *dev, char *buf, int len)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	if (w->real_dev->dump)
		w->real_dev->dump(w->real_dev, buf, len);
}

static int eink_fb_enableScreen(struct framebuffer_device_t *dev, int enable)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	if (!w->real_dev->enableScreen)
		return 0;
	return w->real_dev->enableScreen(w->real_dev, enable);
}

static int eink_fb_close(struct hw_device_t *dev)
{
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)dev;
	int ret = 0;
	if (w->eink_fd >= 0)
		close(w->eink_fd);
	if (w->real_dev)
		ret = w->real_dev->common.close(&w->real_dev->common);
	free(w);
	return ret;
}

typedef struct {
	alloc_device_t device;   /* must be first: doubles as hw_device_t* */
	alloc_device_t *real_dev;
} eink_alloc_wrapper_t;

static int eink_gpu_alloc(struct alloc_device_t *dev, int w, int h, int format,
		int usage, buffer_handle_t *handle, int *stride)
{
	eink_alloc_wrapper_t *aw = (eink_alloc_wrapper_t *)dev;
	/* The real vendor gralloc's GRALLOC_USAGE_HW_FB path allocates from a
	 * tiny fixed pool sized for real hardware page-flipping (numBuffers
	 * slots carved out of the mapped /dev/graphics/fb0 region) and fails
	 * with ENOMEM once that pool -- typically just 2 slots -- is
	 * exhausted, even though the system has hundreds of MB of RAM free.
	 * Our own hwcomposer never uses gralloc's fb0 post()/page-flip path
	 * at all (it composites directly via its own mmap of /dev/graphics/fb0
	 * instead), so these buffers only ever need plain CPU lock()/unlock()
	 * access. Strip the flag so every allocation -- "framebuffer-purpose"
	 * ones included -- goes through the real vendor's generic ashmem
	 * path instead, which has no such slot limit. */
	int real_usage = usage & ~GRALLOC_USAGE_HW_FB;
	int ret = aw->real_dev->alloc(aw->real_dev, w, h, format, real_usage, handle, stride);
	ALOGI("eink_wrapper: alloc(w=%d h=%d format=%d usage=0x%x) pid=%d -> ret=%d handle=%p stride=%d",
		w, h, format, usage, getpid(), ret, handle ? (void*)*handle : NULL,
		(ret == 0 && stride) ? *stride : -1);
	if (ret == 0 && handle && *handle)
		eink_buf_record(*handle, w, h, stride ? *stride : w, format);
	return ret;
}

static int eink_gpu_free(struct alloc_device_t *dev, buffer_handle_t handle)
{
	eink_alloc_wrapper_t *aw = (eink_alloc_wrapper_t *)dev;
	ALOGI("eink_wrapper: free(handle=%p) pid=%d", (void*)handle, getpid());
	eink_buf_forget(handle);
	return aw->real_dev->free(aw->real_dev, handle);
}

static void eink_gpu_dump(struct alloc_device_t *dev, char *buf, int len)
{
	eink_alloc_wrapper_t *aw = (eink_alloc_wrapper_t *)dev;
	if (aw->real_dev->dump)
		aw->real_dev->dump(aw->real_dev, buf, len);
}

static int eink_gpu_close(struct hw_device_t *dev)
{
	eink_alloc_wrapper_t *aw = (eink_alloc_wrapper_t *)dev;
	int ret = aw->real_dev->common.close(&aw->real_dev->common);
	free(aw);
	return ret;
}

static int eink_device_open(const hw_module_t *module, const char *name, hw_device_t **device)
{
	ALOGI("eink_wrapper: device_open(name=\"%s\") called", name ? name : "(null)");

	if (ensure_real_loaded() != 0) {
		ALOGE("eink_wrapper: ensure_real_loaded failed, returning -EINVAL");
		return -EINVAL;
	}
	ALOGI("eink_wrapper: real module loaded ok, g_real_module=%p methods=%p open=%p",
		(void*)g_real_module, (void*)g_real_module->methods,
		(void*)g_real_module->methods->open);

	hw_device_t *real_device = NULL;
	int status = g_real_module->methods->open(g_real_module, name, &real_device);
	ALOGI("eink_wrapper: real open(\"%s\") returned status=%d real_device=%p",
		name, status, (void*)real_device);
	if (status != 0 || !real_device) {
		ALOGE("eink_wrapper: real open(\"%s\") failed, propagating status=%d", name, status);
		return status ? status : -EINVAL;
	}

	if (strcmp(name, GRALLOC_HARDWARE_GPU0) == 0) {
		/* Wrap alloc()/free() just enough to record each buffer's
		 * width/height/stride/format for hwcomposer.imx6.so's software
		 * compositor -- everything else still goes straight to the
		 * real vendor device. */
		alloc_device_t *real_alloc = (alloc_device_t *)real_device;
		eink_alloc_wrapper_t *aw = (eink_alloc_wrapper_t *)malloc(sizeof(*aw));
		if (!aw) {
			real_alloc->common.close(&real_alloc->common);
			return -ENOMEM;
		}
		memset(aw, 0, sizeof(*aw));
		memcpy(&aw->device, real_alloc, sizeof(*real_alloc));
		aw->real_dev = real_alloc;
		aw->device.alloc = eink_gpu_alloc;
		aw->device.free = eink_gpu_free;
		aw->device.dump = real_alloc->dump ? eink_gpu_dump : NULL;
		aw->device.common.close = eink_gpu_close;
		*device = &aw->device.common;
		ALOGI("eink_wrapper: gpu0 wrapped for buffer tracking, aw=%p *device=%p", (void*)aw, (void*)*device);
		return 0;
	}

	if (strcmp(name, GRALLOC_HARDWARE_FB0) != 0) {
		/* anything else: pure passthrough, zero reimplementation. */
		*device = real_device;
		ALOGI("eink_wrapper: passthrough device set for \"%s\": *device=%p", name, (void*)*device);
		return 0;
	}

	framebuffer_device_t *real_fb = (framebuffer_device_t *)real_device;
	eink_fb_wrapper_t *w = (eink_fb_wrapper_t *)malloc(sizeof(*w));
	if (!w) {
		real_fb->common.close(&real_fb->common);
		return -ENOMEM;
	}
	memset(w, 0, sizeof(*w));

	/* Start from a byte-for-byte copy of the real device (correct public
	 * geometry fields: width/height/stride/format/xdpi/ydpi/fps/etc, and
	 * the module pointer callers expect at common.module). */
	memcpy(&w->device, real_fb, sizeof(*real_fb));
	w->real_dev = real_fb;
	w->eink_fd = open("/dev/graphics/fb0", O_RDWR);
	if (w->eink_fd < 0)
		ALOGE("eink_wrapper: open(/dev/graphics/fb0) failed: %s", strerror(errno));

	/* Every hook that reaches vendor code must go through a trampoline
	 * substituting real_dev, since vendor code will cast the passed-in
	 * dev pointer back to its OWN private struct layout, which our
	 * wrapper's memory does not match beyond the public fields above. */
	w->device.setSwapInterval = eink_fb_setSwapInterval;
	w->device.setUpdateRect = real_fb->setUpdateRect ? eink_fb_setUpdateRect : NULL;
	w->device.post = eink_fb_post;
	w->device.compositionComplete = real_fb->compositionComplete ? eink_fb_compositionComplete : NULL;
	w->device.dump = real_fb->dump ? eink_fb_dump : NULL;
	w->device.enableScreen = real_fb->enableScreen ? eink_fb_enableScreen : NULL;
	w->device.common.close = eink_fb_close;

	*device = &w->device.common;
	ALOGI("eink_wrapper: fb0 wrapped, w=%p *device=%p width=%u height=%u eink_fd=%d",
		(void*)w, (void*)*device, w->device.width, w->device.height, w->eink_fd);
	return 0;
}

static int eink_registerBuffer(gralloc_module_t const *module, buffer_handle_t handle)
{
	(void)module;
	if (ensure_real_loaded() != 0)
		return -EINVAL;
	return ((gralloc_module_t *)g_real_module)->registerBuffer((gralloc_module_t const *)g_real_module, handle);
}

static int eink_unregisterBuffer(gralloc_module_t const *module, buffer_handle_t handle)
{
	(void)module;
	if (ensure_real_loaded() != 0)
		return -EINVAL;
	return ((gralloc_module_t *)g_real_module)->unregisterBuffer((gralloc_module_t const *)g_real_module, handle);
}

static int eink_lock(gralloc_module_t const *module, buffer_handle_t handle,
		int usage, int l, int t, int w, int h, void **vaddr)
{
	(void)module;
	if (ensure_real_loaded() != 0)
		return -EINVAL;
	return ((gralloc_module_t *)g_real_module)->lock((gralloc_module_t const *)g_real_module,
		handle, usage, l, t, w, h, vaddr);
}

static int eink_unlock(gralloc_module_t const *module, buffer_handle_t handle)
{
	(void)module;
	if (ensure_real_loaded() != 0)
		return -EINVAL;
	return ((gralloc_module_t *)g_real_module)->unlock((gralloc_module_t const *)g_real_module, handle);
}

static struct hw_module_methods_t eink_module_methods = {
	.open = eink_device_open
};

struct gralloc_module_t HAL_MODULE_INFO_SYM = {
	.common = {
		.tag = HARDWARE_MODULE_TAG,
		.version_major = 1,
		.version_minor = 0,
		.id = GRALLOC_HARDWARE_MODULE_ID,
		.name = "E-ink-aware Graphics Memory Allocator wrapper",
		.author = "clara-hd project",
		.methods = &eink_module_methods,
	},
	.registerBuffer = eink_registerBuffer,
	.unregisterBuffer = eink_unregisterBuffer,
	.lock = eink_lock,
	.unlock = eink_unlock,
	/* perform/lock_ycbcr/reserved_proc left NULL: the real AOSP-era
	 * reference gralloc.default implementation this vendor module is
	 * derived from doesn't populate them either, so well-behaved
	 * callers null-check before use. */
};
