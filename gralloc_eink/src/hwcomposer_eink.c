/*
 * Custom e-ink hwcomposer: claims every real layer as HWC_OVERLAY so
 * SurfaceFlinger's hasGlesComposition() stays false and it never calls
 * eglSwapBuffers() on the primary display -- sidestepping a fatal bug in
 * this vendor build's software EGL/GLES implementation (libGLES_android.so
 * dereferences a NULL ANativeWindow inside eglSwapBuffers whenever it's
 * actually invoked; see tombstones from surfaceflinger crashes).
 *
 * Composition itself is done here in plain software: each layer's pixel
 * buffer is mapped via the gralloc module's lock()/unlock() and memcpy'd
 * into the real framebuffer, respecting displayFrame placement. Scaling
 * are not implemented (rare for this device's simple
 * fullscreen UI); anything requesting them is still copied unscaled/opaque
 * rather than dropped, since a visually-imperfect frame beats none at all.
 *
 * Buffer geometry (width/height/stride/format) isn't present in the opaque
 * buffer_handle_t at the HWC interface level and the real vendor gralloc's
 * private handle layout is unknown to us, so gralloc.default.so (loaded in
 * the same process) tracks it at alloc() time and exposes it here via the
 * exported eink_gralloc_query() function.
 *
 * NOTE: this is the last known-good version (screen renders correctly,
 * boots all the way to real app UI) from before a 90-degree portrait
 * rotation was attempted. The panel's native framebuffer is landscape
 * (1448x1072) while the device is physically held in portrait, so the
 * screen displays sideways with this version -- that's a known, accepted
 * limitation for now, reverted back to after the rotation attempt caused
 * a reproducible hard reset/reboot loop that several rounds of diagnosis
 * (memory-safety fixes, shadow-buffer double-copy, update throttling, a
 * post-update settle delay) did not resolve. Revisit the rotation once
 * ADB is available for faster, non-destructive iteration.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>

#define gettid() syscall(__NR_gettid)
#include <errno.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <linux/fb.h>
#include <linux/mxcfb.h>

#include <hardware/hardware.h>
#include <hardware/gralloc.h>
#include <hardware/hwcomposer.h>

#include "cutils/log.h"

#define GRALLOC_MODULE_PATH "/system/lib/hw/gralloc.default.so"

typedef int (*eink_gralloc_query_fn)(buffer_handle_t handle, int *w, int *h, int *stride, int *format);

typedef struct {
	hwc_composer_device_1_t device; /* must be first */

	const gralloc_module_t *gralloc;
	eink_gralloc_query_fn query_fn;

	int fb_fd;
	void *fb_mem;
	/* Composition writes here rather than into fb_mem directly: rotated
	 * layers are written in a transposed (column-strided) pattern, and
	 * fb_mem is real framebuffer/DMA memory. shadow is ordinary malloc'd
	 * RAM with the same layout as fb_mem; hwc_set() does one sequential
	 * bulk memcpy(fb_mem, shadow, fb_size) per frame. */
	void *shadow;
	/* What the panel is currently showing, in ordinary cached RAM. The
	 * comparison that decides whether a frame is worth an e-ink refresh
	 * used to read fb_mem, and reading back framebuffer memory is
	 * punishingly slow (measured: 208 ms of a 329 ms frame, ~15 MB/s).
	 * Keeping a cached copy makes that comparison a RAM-to-RAM one and
	 * leaves fb_mem write-only. */
	void *panel;
	size_t fb_size;
	/* All of these are the PHYSICAL panel/framebuffer dimensions, straight
	 * from fb0's vinfo.xres/yres (1448x1072 landscape scan order).
	 *
	 * Rotation is deliberately NOT done here any more. This vendor's
	 * SurfaceFlinger takes the display size from the gralloc fb0 device,
	 * not from our getDisplayAttributes() (confirmed: DisplayManagerService
	 * logged "Built-in Screen": 1448 x 1072 even while we reported
	 * 1072x1448), so WindowManager treats the panel as landscape-natural
	 * and rotates the UI itself -- InputReader logged the matching
	 * "orientation 3" viewport, i.e. it is already rotating touch input to
	 * match too. SurfaceFlinger folds that display rotation into each
	 * layer's transform field and hands us displayFrame in this physical
	 * space. Previously we ignored transform and clipped displayFrame
	 * against a 1072-wide "logical portrait" screen, which threw away
	 * everything past x=1072 -- 376 unwritten pixels showing up as a black
	 * band along one edge. Honouring transform instead fixes that and
	 * keeps what is drawn consistent with where touches land. */
	int width, height;
	int fb_width, fb_height, stride_bytes, bpp;

	hwc_procs_t const *procs;
	pthread_t vsync_thread;
	volatile int vsync_enabled;
	volatile int vsync_requested;
	int stop_vsync;
} eink_hwc_t;

/*
 * The rate SurfaceFlinger schedules the display at, and the rate the vsync
 * thread ticks at -- they must agree. They did not: the attribute said one
 * second (SurfaceFlinger duly reported "refresh-rate: 1.000000 fps") while
 * the thread ticked every 66 ms, so SurfaceFlinger's timing model never
 * settled and it stopped compositing altogether. An app rendering
 * continuously then filled its buffer queue and blocked, and only an app
 * switch -- which forces a transaction -- let a single frame through.
 *
 * 100 ms is about what this panel can actually show: a full EPDC update
 * takes a few hundred ms, so scheduling faster only queues work in the
 * driver.
 */
#define EINK_VSYNC_PERIOD_NS 100000000L   /* 10 Hz */

/*
 * How often a full (flashing) update is forced to clear accumulated
 * ghosting. Every update used to be UPDATE_MODE_FULL over the whole panel,
 * which is the black/white inversion flash: tolerable when the screen
 * changed once in a while, unbearable once anything animates.
 */
#define EINK_FULL_UPDATE_EVERY 60

/*
 * The nudge in the vsync thread: how long after the last visible change to
 * keep asking SurfaceFlinger to recomposite, and how recently it must have
 * composited for a nudge to be pointless. See the comment there.
 */
#define EINK_NUDGE_IDLE_US  3000000UL
#define EINK_NUDGE_QUIET_US  200000UL

/*
 * Push a region of the framebuffer to the panel.
 *
 * UPDATE_MODE_PARTIAL redraws without the inversion flash, which is what
 * should happen for nearly every frame; the periodic UPDATE_MODE_FULL is
 * what keeps ghosting from building up. The region is the part that
 * actually changed, so a game redrawing its window does not repaint the
 * status and navigation bars along with it.
 */
static void eink_send_update(int fd, int panel_width, int left, int top,
		int width, int height, int full)
{
	struct mxcfb_update_data update;

	if (width <= 0 || height <= 0)
		return;

	/* The EPDC wants x/width on 8-pixel boundaries; grow the region
	 * outwards rather than handing the driver something it has to round
	 * for us. Rounding left down moves the right edge too, so recompute
	 * the width from the edge we actually want to keep, and never let the
	 * result run past the panel -- the driver rejects an out-of-range
	 * region outright, which would mean no update at all. */
	{
		int right = left + width;

		left &= ~7;
		width = ((right - left) + 7) & ~7;
		if (left + width > panel_width)
			width = panel_width - left;
		if (width <= 0)
			return;
	}

	memset(&update, 0, sizeof(update));
	update.update_region.left = left;
	update.update_region.top = top;
	update.update_region.width = width;
	update.update_region.height = height;
	update.waveform_mode = WAVEFORM_MODE_AUTO;
	update.update_mode = full ? UPDATE_MODE_FULL : UPDATE_MODE_PARTIAL;
	update.temp = TEMP_USE_AMBIENT;
	update.flags = 0;
	if (ioctl(fd, MXCFB_SEND_UPDATE, &update) == -1)
		ALOGE("hwcomposer_eink: MXCFB_SEND_UPDATE failed: %s", strerror(errno));
}

static volatile int g_prepare_count;
static volatile int g_set_count;
static unsigned long g_frames_composed, g_updates_sent, g_frames_identical;
static unsigned long g_compose_us, g_update_us;
static unsigned long g_clear_us, g_layers_us, g_diff_us;
static unsigned long g_vsync_events, g_eventcontrol_count, g_nudges;
static unsigned long g_blank_count, g_prepare_composites;
static int g_last_blank = -1, g_last_prepare_layers;
/* When a composed frame last changed the panel, and when set() last ran. */
static unsigned long g_last_change_us, g_last_set_us;

/*
 * A file descriptor handed to SurfaceFlinger as the display's retire fence.
 *
 * SurfaceFlinger re-enables hardware vsync only from postComposition():
 *
 *     if (presentFence->isValid()) {
 *         if (mPrimaryDispSync.addPresentFence(presentFence))
 *             enableHardwareVsync();
 *         else
 *             disableHardwareVsync(false);
 *     }
 *
 * With retireFenceFd left at -1 that whole branch is skipped. SurfaceFlinger
 * disables hardware vsync once at boot (it needs no events while nothing is
 * listening) and then has no path back: our vsync samples are ignored because
 * mPrimaryHWVsyncEnabled is false, DispSync's timing model never forms, no
 * software vsync is generated, and every app's Choreographer falls back to
 * EventThread's 1000 ms fake-vsync timeout. That is the one-frame-per-second
 * "frozen" display, and why any window that forces a WindowManager
 * transaction made it move again.
 *
 * The right fence comes from the sync framework; this kernel is not built
 * with CONFIG_SW_SYNC_USER, so /dev/sw_sync does not exist (see ROADMAP).
 * Until it is, this is a plain descriptor: valid, so the branch runs, and not
 * a sync fence, so Fence::getSignalTime() fails and DispSync treats the frame
 * as having an unknown present time. The consequence is that it keeps asking
 * for hardware vsync, which on this device is exactly right -- the composer's
 * own 10 Hz thread is the only clock there is.
 */
static int g_fence_src = -1;

static unsigned long now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long)ts.tv_sec * 1000000UL + (unsigned long)ts.tv_nsec / 1000UL;
}

/* How long set() may be missing before prepare() composes the frame itself. */
#define EINK_SET_MISSING_US 300000UL

static int hwc_compose(hwc_composer_device_1_t *dev, size_t numDisplays,
		hwc_display_contents_1_t **displays, int from_set);

static int hwc_prepare(hwc_composer_device_1_t *dev, size_t numDisplays,
		hwc_display_contents_1_t **displays)
{
	g_last_prepare_layers = (numDisplays > 0 && displays[0]) ?
			(int)displays[0]->numHwLayers : -1;
	(void)dev;
	g_prepare_count++;
	if (g_prepare_count <= 10 || (g_prepare_count % 25) == 0) {
		{
			static unsigned long last_prep_us;
			unsigned long nowu = now_us();

			ALOGI("hwcomposer_eink: prepare #%d pid=%d tid=%d sets=%d "
				"caller=%p dt=%lums set_age=%lums",
				g_prepare_count, (int)getpid(), (int)gettid(), g_set_count,
				__builtin_return_address(0),
				last_prep_us ? (nowu - last_prep_us) / 1000 : 0,
				g_last_set_us ? (nowu - g_last_set_us) / 1000 : 0);
			last_prep_us = nowu;
		}
		for (size_t d = 0; d < numDisplays; d++) {
			if (!displays[d]) {
				ALOGI("hwcomposer_eink:   disp %zu = NULL", d);
				continue;
			}
			ALOGI("hwcomposer_eink:   disp %zu flags=0x%08x numHwLayers=%zu retireFd=%d",
				d, displays[d]->flags, displays[d]->numHwLayers,
				displays[d]->retireFenceFd);
			for (size_t i = 0; i < displays[d]->numHwLayers; i++) {
				hwc_layer_1_t *ly = &displays[d]->hwLayers[i];

				ALOGI("hwcomposer_eink:     layer %zu type=%d flags=0x%x handle=%p "
					"frame=(%d,%d)-(%d,%d)", i, ly->compositionType, ly->flags,
					(void*)ly->handle, ly->displayFrame.left, ly->displayFrame.top,
					ly->displayFrame.right, ly->displayFrame.bottom);
			}
		}
	}
	if (g_prepare_count <= 10 || (g_prepare_count % 100) == 0) {
		for (size_t d = 0; d < numDisplays; d++) {
			if (displays[d])
				ALOGI("hwcomposer_eink: prepare() #%d disp=%zu numHwLayers=%zu",
					g_prepare_count, d, displays[d]->numHwLayers);
		}
	}
	for (size_t d = 0; d < numDisplays; d++) {
		hwc_display_contents_1_t *list = displays[d];
		if (!list)
			continue;
		for (size_t i = 0; i < list->numHwLayers; i++) {
			hwc_layer_1_t *l = &list->hwLayers[i];
			if (l->compositionType == HWC_FRAMEBUFFER_TARGET)
				continue;
			if (l->compositionType == HWC_BACKGROUND)
				continue;
			l->compositionType = HWC_OVERLAY;
			l->hints = 0;
		}
	}

	/* See hwc_compose(): SurfaceFlinger goes through long stretches of
	 * calling prepare() without ever calling set(), which leaves the panel
	 * showing the last frame it did compose while an app renders on. When
	 * that happens, compose here instead of letting the display sit dead. */
	if (g_last_set_us && now_us() - g_last_set_us > EINK_SET_MISSING_US)
		hwc_compose(dev, numDisplays, displays, 0);

	return 0;
}

static void compose_background(eink_hwc_t *hw, hwc_layer_1_t *l)
{
	uint8_t r = l->backgroundColor.r, g = l->backgroundColor.g, b = l->backgroundColor.b;
	uint8_t gray = (uint8_t)((r + g + b) / 3);
	memset(hw->shadow, gray, hw->fb_size);
}

/* Layer buffers are NOT the framebuffer's format: SurfaceFlinger hands us
 * 32-bit RGBX_8888/RGBA_8888 (confirmed from the alloc() log -- format=2
 * and format=1 respectively) while this panel's framebuffer is 16-bit
 * RGB565. Using the framebuffer's bytes-per-pixel for the source, as this
 * compositor did originally, both halves the source row stride (so every
 * row is read from the wrong offset) and reinterprets 32-bit pixels as
 * 16-bit ones -- the image could never have been assembled correctly. */
static int src_bytes_per_pixel(int format)
{
	switch (format) {
	case HAL_PIXEL_FORMAT_RGBA_8888:
	case HAL_PIXEL_FORMAT_RGBX_8888:
	case HAL_PIXEL_FORMAT_BGRA_8888:
		return 4;
	case HAL_PIXEL_FORMAT_RGB_888:
		return 3;
	case HAL_PIXEL_FORMAT_RGB_565:
		return 2;
	default:
		return 0;
	}
}

static inline uint16_t to_rgb565(const uint8_t *p, int sbpp, int format)
{
	uint8_t r, g, b;

	if (sbpp == 2)
		return *(const uint16_t *)p;

	if (format == HAL_PIXEL_FORMAT_BGRA_8888) {
		b = p[0]; g = p[1]; r = p[2];
	} else {
		r = p[0]; g = p[1]; b = p[2];
	}
	return (uint16_t)(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
}

/* Does this source format carry a meaningful alpha channel? */
static inline int format_has_alpha(int format)
{
	return format == HAL_PIXEL_FORMAT_RGBA_8888 ||
	       format == HAL_PIXEL_FORMAT_BGRA_8888;
}

/*
 * Blend one source pixel into the RGB565 shadow.
 *
 * Without this every layer was copied opaquely, so a translucent window
 * (the launcher's, whose background is transparent so the wallpaper shows
 * through) overwrote what was underneath with its own transparent-black
 * pixels -- which is why wallpapers rendered as a black screen.
 *
 * HWC_BLENDING_PREMULT carries premultiplied colour, COVERAGE does not;
 * planeAlpha scales the whole layer. Fully opaque and fully transparent
 * pixels take the cheap paths, which is the overwhelming majority.
 */
static inline void blend_px(uint16_t *dst, const uint8_t *p, int sbpp, int format,
		int blending, unsigned plane_alpha)
{
	unsigned r, g, b, a;

	if (blending == HWC_BLENDING_NONE || !format_has_alpha(format))
		a = 255;
	else
		a = p[3];

	if (plane_alpha < 255)
		a = (a * plane_alpha + 127) / 255;

	if (a == 0)
		return;

	if (a == 255 && plane_alpha == 255) {
		*dst = to_rgb565(p, sbpp, format);
		return;
	}

	if (sbpp == 2) {
		uint16_t v = *(const uint16_t *)p;
		r = ((v >> 11) & 0x1f) << 3;
		g = ((v >> 5) & 0x3f) << 2;
		b = (v & 0x1f) << 3;
	} else if (format == HAL_PIXEL_FORMAT_BGRA_8888) {
		b = p[0]; g = p[1]; r = p[2];
	} else {
		r = p[0]; g = p[1]; b = p[2];
	}

	if (plane_alpha < 255) {
		r = (r * plane_alpha + 127) / 255;
		g = (g * plane_alpha + 127) / 255;
		b = (b * plane_alpha + 127) / 255;
	}

	if (blending == HWC_BLENDING_COVERAGE) {
		r = (r * a + 127) / 255;
		g = (g * a + 127) / 255;
		b = (b * a + 127) / 255;
	}

	{
		uint16_t d = *dst;
		unsigned dr = ((d >> 11) & 0x1f) << 3;
		unsigned dg = ((d >> 5) & 0x3f) << 2;
		unsigned db = (d & 0x1f) << 3;
		unsigned inv = 255 - a;

		r += (dr * inv + 127) / 255;
		g += (dg * inv + 127) / 255;
		b += (db * inv + 127) / 255;
		if (r > 255) r = 255;
		if (g > 255) g = 255;
		if (b > 255) b = 255;
		*dst = (uint16_t)(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
	}
}

static int compose_layer(eink_hwc_t *hw, hwc_layer_1_t *l)
{
	if (!l->handle || !hw->query_fn || !hw->gralloc)
		return -1;

	int sw = 0, sh = 0, sstride = 0, sformat = 0;
	if (hw->query_fn(l->handle, &sw, &sh, &sstride, &sformat) != 0) {
		ALOGE("hwcomposer_eink: no geometry for handle %p, skipping layer", (void*)l->handle);
		return -1;
	}

	int dleft = l->displayFrame.left, dtop = l->displayFrame.top;
	int dw = l->displayFrame.right - l->displayFrame.left;
	int dh = l->displayFrame.bottom - l->displayFrame.top;
	int cleft = l->sourceCropi.left, ctop = l->sourceCropi.top;
	int cw = l->sourceCropi.right - l->sourceCropi.left;
	int ch = l->sourceCropi.bottom - l->sourceCropi.top;

	/* transform says how the layer buffer maps onto displayFrame;
	 * SurfaceFlinger folds the whole display rotation into it. Scaling is
	 * still unsupported -- a crop/frame size mismatch just copies 1:1 from
	 * the crop origin. */
	uint32_t xform = l->transform;

	if (dw <= 0 || dh <= 0 || cw <= 0 || ch <= 0)
		return -1;

	void *vaddr = NULL;
	int rc = hw->gralloc->lock((gralloc_module_t const *)hw->gralloc, l->handle,
			GRALLOC_USAGE_SW_READ_OFTEN, cleft, ctop, cw, ch, &vaddr);
	if (rc != 0 || !vaddr) {
		ALOGE("hwcomposer_eink: gralloc lock failed for handle %p: rc=%d", (void*)l->handle, rc);
		return -1;
	}

	/*
	 * planeAlpha only exists from HWC 1.2 on, and SurfaceFlinger leaves it
	 * unset below that; we advertise 1.1, so per-layer alpha is all there
	 * is to honour.
	 */
	const unsigned plane_alpha = 255;

	int sbpp = src_bytes_per_pixel(sformat);
	int dbpp = hw->bpp;
	size_t src_row_stride = (size_t)sstride * sbpp;
	size_t dst_row_stride = (size_t)hw->stride_bytes;
	const uint8_t *src = (const uint8_t *)vaddr;

	if (sbpp == 0 || dbpp != 2) {
		ALOGE("hwcomposer_eink: unsupported formats (src format=%d sbpp=%d, dst bpp=%d)",
			sformat, sbpp, dbpp);
		hw->gralloc->unlock((gralloc_module_t const *)hw->gralloc, l->handle);
		return -1;
	}

	/*
	 * Fast path for the common case: no rotation, and a layer that is
	 * opaque (no alpha channel, or blending switched off). That covers
	 * every full-screen app and game, and it is worth a special case --
	 * the general loop below costs a function call and two bounds checks
	 * per pixel, which measured 400 ms for one 1448x1072 frame, i.e. it
	 * was the single thing limiting the whole device to about one frame
	 * per second. Clipping once per layer instead of once per pixel and
	 * copying whole rows brings that down to a row-at-a-time blit.
	 */
	if (xform == 0 && (l->blending == HWC_BLENDING_NONE || !format_has_alpha(sformat))) {
		/* Source columns that land inside both buffers. */
		int sx0 = 0, sx1 = cw, sy0 = 0, sy1 = ch;

		if (cleft + sx0 < 0)       sx0 = -cleft;
		if (dleft + sx0 < 0)       sx0 = -dleft;
		if (cleft + sx1 > sw)      sx1 = sw - cleft;
		if (dleft + sx1 > hw->width)  sx1 = hw->width - dleft;
		if (ctop + sy0 < 0)        sy0 = -ctop;
		if (dtop + sy0 < 0)        sy0 = -dtop;
		if (ctop + sy1 > sh)       sy1 = sh - ctop;
		if (dtop + sy1 > hw->height) sy1 = hw->height - dtop;

		for (int sy = sy0; sy < sy1; sy++) {
			const uint8_t *srow = src + (size_t)(ctop + sy) * src_row_stride
					+ (size_t)(cleft + sx0) * sbpp;
			uint16_t *drow = (uint16_t *)((uint8_t *)hw->shadow
					+ (size_t)(dtop + sy) * dst_row_stride
					+ (size_t)(dleft + sx0) * 2);

			if (sbpp == 2) {
				memcpy(drow, srow, (size_t)(sx1 - sx0) * 2);
				continue;
			}
			for (int n = sx1 - sx0; n > 0; n--, srow += sbpp)
				*drow++ = to_rgb565(srow, sbpp, sformat);
		}
		hw->gralloc->unlock((gralloc_module_t const *)hw->gralloc, l->handle);
		return 0;
	}

	/* Iterate SOURCE-major so source reads run sequentially along a row.
	 * A rotation is a transpose, so one side of the copy has to be
	 * strided; keeping the strided side on the destination (the shadow
	 * buffer, plain cached RAM) is what the earlier working builds did,
	 * and reading the source sequentially avoids a cache miss on every
	 * single pixel. The transform only affects where a source row lands
	 * and which way it advances, so resolve it once per row rather than
	 * per pixel: (i0,j0) is where this row's first pixel goes and
	 * (di,dj) is the step taken per source pixel. */
	for (int sy = 0; sy < ch; sy++) {
		int srcy = ctop + sy;
		int i0, j0, di, dj, dx, dy;
		const uint8_t *srow;

		if (srcy < 0 || srcy >= sh)
			continue;
		srow = src + (size_t)srcy * src_row_stride;

		switch (xform) {
		case HWC_TRANSFORM_ROT_90:
			i0 = ch - 1 - sy; j0 = 0;            di =  0; dj =  1; break;
		case HWC_TRANSFORM_ROT_180:
			i0 = cw - 1;      j0 = ch - 1 - sy;  di = -1; dj =  0; break;
		case HWC_TRANSFORM_ROT_270:
			i0 = sy;          j0 = cw - 1;       di =  0; dj = -1; break;
		case HWC_TRANSFORM_FLIP_H:
			i0 = cw - 1;      j0 = sy;           di = -1; dj =  0; break;
		case HWC_TRANSFORM_FLIP_V:
			i0 = 0;           j0 = ch - 1 - sy;  di =  1; dj =  0; break;
		default:
			i0 = 0;           j0 = sy;           di =  1; dj =  0; break;
		}

		dx = dleft + i0;
		dy = dtop + j0;

		for (int sx = 0; sx < cw; sx++, dx += di, dy += dj) {
			int srcx = cleft + sx;

			if (srcx < 0 || srcx >= sw)
				continue;
			if (dx < 0 || dx >= hw->width || dy < 0 || dy >= hw->height)
				continue;

			blend_px((uint16_t *)((uint8_t *)hw->shadow
						+ (size_t)dy * dst_row_stride + (size_t)dx * 2),
					srow + (size_t)srcx * sbpp, sbpp, sformat,
					l->blending, plane_alpha);
		}
	}

	hw->gralloc->unlock((gralloc_module_t const *)hw->gralloc, l->handle);
	return 0;
}

/*
 * The body of set(), also reachable from prepare().
 *
 * SurfaceFlinger is supposed to call prepare() and set() as a pair, and for
 * long stretches on this device it calls only prepare(): the display then
 * holds whatever was last composed while an app renders away (measured:
 * hundreds of prepares, set_age climbing past 35 s). Rather than leave the
 * panel frozen, compose from prepare() when set() has gone missing --
 * `from_set` says which caller we are, because only a real set() may hand
 * SurfaceFlinger a retire fence and count towards the frame statistics.
 */
static int hwc_compose(hwc_composer_device_1_t *dev, size_t numDisplays,
		hwc_display_contents_1_t **displays, int from_set)
{
	eink_hwc_t *hw = (eink_hwc_t *)dev;
	/* Log the full layer list for the first few frames and again whenever
	 * the layer count changes, capped so a busy UI cannot flood the SD
	 * card. The first frames alone are all boot animation; the status
	 * bar, nav bar and launcher only show up much later as a change in
	 * the layer set, which is exactly what this catches. */
	static size_t last_num_layers;
	static int layer_set_logs;
	size_t num_primary = (numDisplays > 0 && displays[0]) ? displays[0]->numHwLayers : 0;
	int verbose;

	unsigned long t_enter = now_us();

	if (from_set)
		g_set_count++;
	else
		g_prepare_composites++;
	if (from_set && (g_set_count <= 10 || (g_set_count % 25) == 0))
		ALOGI("hwcomposer_eink: set #%d pid=%d tid=%d caller=%p",
			g_set_count, (int)getpid(), (int)gettid(),
			__builtin_return_address(0));
	verbose = g_set_count <= 10 ||
		(num_primary != last_num_layers && layer_set_logs < 40);
	if (num_primary != last_num_layers) {
		last_num_layers = num_primary;
		if (g_set_count > 10)
			layer_set_logs++;
	}
	for (size_t d = 0; d < numDisplays; d++) {
		hwc_display_contents_1_t *list = displays[d];
		if (!list)
			continue;
		if (d != HWC_DISPLAY_PRIMARY) {
			list->retireFenceFd = -1;
			continue;
		}
		int dirty = 0, composed = 0, failed = 0;
		/* Union of what this frame actually touches, in panel
		 * coordinates, so the update can be a partial one. */
		int dx0 = hw->width, dy0 = hw->height, dx1 = 0, dy1 = 0;

		/* Every frame recomposites the whole layer list, so start from a
		 * known state rather than leaving whatever was here before. White,
		 * because that is what an e-ink panel idles at -- an uninitialized
		 * or stale buffer would leave any region no layer covers reading
		 * as a black band. */
		{
			unsigned long t_clear = now_us();

			memset(hw->shadow, 0xff, hw->fb_size);
			g_clear_us += now_us() - t_clear;
		}
		unsigned long t_layers = now_us();

		for (size_t i = 0; i < list->numHwLayers; i++) {
			hwc_layer_1_t *l = &list->hwLayers[i];
			l->releaseFenceFd = -1;
			if (verbose) {
				int qw = 0, qh = 0, qs = 0, qf = -1;

				if (l->handle && hw->query_fn)
					hw->query_fn(l->handle, &qw, &qh, &qs, &qf);
				ALOGI("hwcomposer_eink: set() #%d layer %zu type=%d transform=%d "
					"blending=0x%x format=%d buf=%dx%d "
					"frame=(%d,%d)-(%d,%d) crop=(%d,%d)-(%d,%d)",
					g_set_count, i, l->compositionType, l->transform,
					l->blending, qf, qw, qh,
					l->displayFrame.left, l->displayFrame.top,
					l->displayFrame.right, l->displayFrame.bottom,
					l->sourceCropi.left, l->sourceCropi.top,
					l->sourceCropi.right, l->sourceCropi.bottom);
			}
			if (l->compositionType == HWC_FRAMEBUFFER_TARGET)
				continue;
			if (l->compositionType == HWC_BACKGROUND) {
				compose_background(hw, l);
				dirty = 1;
				dx0 = 0; dy0 = 0; dx1 = hw->width; dy1 = hw->height;
				continue;
			}
			if (compose_layer(hw, l) == 0) {
				const hwc_rect_t *f = &l->displayFrame;

				dirty = 1;
				composed++;
				if (f->left   < dx0) dx0 = f->left;
				if (f->top    < dy0) dy0 = f->top;
				if (f->right  > dx1) dx1 = f->right;
				if (f->bottom > dy1) dy1 = f->bottom;
			} else {
				failed++;
			}
		}
		g_layers_us += now_us() - t_layers;
		if (verbose)
			ALOGI("hwcomposer_eink: set() #%d numHwLayers=%zu composed=%d failed=%d dirty=%d",
				g_set_count, list->numHwLayers, composed, failed, dirty);
		if (dirty) {
			static int updates;
			/* What the previous frame painted. A layer that goes away
			 * (the nav bar hiding) leaves no displayFrame behind, so
			 * without this its area would never be repainted and a
			 * ghost of it would stay on the panel. */
			static int px0, py0, px1, py1;
			int full, changed;

			if (dx0 < 0) dx0 = 0;
			if (dy0 < 0) dy0 = 0;
			if (dx1 > hw->width)  dx1 = hw->width;
			if (dy1 > hw->height) dy1 = hw->height;
			if (dx1 <= dx0 || dy1 <= dy0) {
				dx0 = 0; dy0 = 0; dx1 = hw->width; dy1 = hw->height;
			}
			if (px1 > px0 && py1 > py0) {
				if (px0 < dx0) dx0 = px0;
				if (py0 < dy0) dy0 = py0;
				if (px1 > dx1) dx1 = px1;
				if (py1 > dy1) dy1 = py1;
			}
			px0 = dx0; py0 = dy0; px1 = dx1; py1 = dy1;

			/* The shadow is cleared to white and recomposed every
			 * frame, so anything the update leaves out keeps its old
			 * contents on the panel; a periodic full update also
			 * clears the ghosting partial updates leave behind. */
			full = (updates % EINK_FULL_UPDATE_EVERY) == 0;
			if (full) {
				dx0 = 0; dy0 = 0; dx1 = hw->width; dy1 = hw->height;
			}

			/* Copy row by row over the update region and notice
			 * whether any of it actually differs from what the panel
			 * is already showing. An app that redraws an unchanged
			 * screen (a game sitting on its menu, a video that is
			 * paused) otherwise costs a full e-ink refresh per frame
			 * for no visible change at all. This is the only place
			 * fb_mem is ever written. */
			changed = 0;
			unsigned long t_diff = now_us();
			for (int y = dy0; y < dy1; y++) {
				size_t off = (size_t)y * hw->stride_bytes + (size_t)dx0 * 2;
				size_t len = (size_t)(dx1 - dx0) * 2;
				const uint8_t *src = (const uint8_t *)hw->shadow + off;
				uint8_t *seen = (uint8_t *)hw->panel + off;

				/* Compare in RAM, never against fb_mem. */
				if (memcmp(seen, src, len) == 0)
					continue;
				memcpy(seen, src, len);
				memcpy((uint8_t *)hw->fb_mem + off, src, len);
				changed = 1;
			}

			g_diff_us += now_us() - t_diff;
			g_frames_composed++;
			g_compose_us += now_us() - t_enter;
			g_last_set_us = now_us();
			if (!changed) {
				g_frames_identical++;
			} else {
				unsigned long t_upd = now_us();

				g_last_change_us = t_upd;
				updates++;
				g_updates_sent++;
				eink_send_update(hw->fb_fd, hw->width, dx0, dy0,
						dx1 - dx0, dy1 - dy0, full);
				g_update_us += now_us() - t_upd;
			}
			/* Heartbeat: enough to tell "nothing reaches the
			 * composer" from "frames arrive and are identical",
			 * which look the same on a panel that is not changing. */
			if ((g_set_count % 64) == 0) {
				static unsigned long last_log_us, last_composed;
				unsigned long nowu = now_us();
				unsigned long dt = nowu - last_log_us;
				unsigned long dn = g_frames_composed - last_composed;

				ALOGI("hwcomposer_eink: set #%d composed=%lu updates=%lu identical=%lu "
					"rect=(%d,%d)-(%d,%d) full=%d | %lu.%02lu fps in, "
					"compose avg %lums, ioctl avg %lums",
					g_set_count, g_frames_composed, g_updates_sent,
					g_frames_identical, dx0, dy0, dx1, dy1, full,
					dt ? dn * 1000000UL / dt : 0,
					dt ? (dn * 100000000UL / dt) % 100 : 0,
					g_frames_composed ? g_compose_us / g_frames_composed / 1000 : 0,
					g_updates_sent ? g_update_us / g_updates_sent / 1000 : 0);
				last_log_us = nowu;
				last_composed = g_frames_composed;
			}
		}
		/* dup per frame: SurfaceFlinger owns and closes what it gets. It
		 * only reads this after set(), so never leave one behind when
		 * composing from prepare() -- that descriptor would leak. */
		if (from_set)
			list->retireFenceFd = (g_fence_src >= 0) ? dup(g_fence_src) : -1;
	}
	return 0;
}

static int hwc_eventControl(hwc_composer_device_1_t *dev, int disp, int event, int enabled)
{
	eink_hwc_t *hw = (eink_hwc_t *)dev;
	/* Only on a change: SurfaceFlinger toggles this many times a second. */
	if (enabled != hw->vsync_enabled)
		ALOGI("hwcomposer_eink: eventControl(disp=%d, event=%d, enabled=%d)",
			disp, event, enabled);
	if (event != HWC_EVENT_VSYNC)
		return -EINVAL;
	hw->vsync_enabled = enabled;
	/*
	 * Latch the request. SurfaceFlinger turns vsync on to get a single
	 * event, waits for it, then turns it off again; if that whole
	 * sequence fell between two of this thread's ticks the event was
	 * never delivered and SurfaceFlinger waited forever -- the display
	 * froze until something else (the navigation bar appearing, an app
	 * switch) forced a transaction. The latch guarantees one event per
	 * enable, whenever it arrived.
	 */
	if (enabled)
		hw->vsync_requested = 1;
	g_eventcontrol_count++;
	return 0;
}

static int hwc_set(hwc_composer_device_1_t *dev, size_t numDisplays,
		hwc_display_contents_1_t **displays)
{
	return hwc_compose(dev, numDisplays, displays, 1);
}

static int hwc_blank(hwc_composer_device_1_t *dev, int disp, int blank)
{
	(void)dev;
	/* SurfaceFlinger stops compositing a display it believes is blanked,
	 * so record it: a stuck blank looks exactly like a frozen screen. */
	if (disp == HWC_DISPLAY_PRIMARY) {
		g_blank_count++;
		g_last_blank = blank;
	}
	return 0;
}

static int hwc_query(hwc_composer_device_1_t *dev, int what, int *value)
{
	(void)dev;
	switch (what) {
	case HWC_BACKGROUND_LAYER_SUPPORTED:
		*value = 1;
		return 0;
	case HWC_VSYNC_PERIOD:
		*value = 1000000000; /* e-ink: no real vsync, 1Hz placeholder */
		return 0;
	default:
		return -EINVAL;
	}
}

static void hwc_registerProcs(hwc_composer_device_1_t *dev, hwc_procs_t const *procs)
{
	eink_hwc_t *hw = (eink_hwc_t *)dev;
	hw->procs = procs;
	ALOGI("hwcomposer_eink: registerProcs called, procs=%p invalidate=%p vsync=%p hotplug=%p",
		(void*)procs, procs ? (void*)procs->invalidate : NULL,
		procs ? (void*)procs->vsync : NULL, procs ? (void*)procs->hotplug : NULL);
}

static int hwc_getDisplayConfigs(hwc_composer_device_1_t *dev, int disp,
		uint32_t *configs, size_t *numConfigs)
{
	(void)dev;
	if (disp != HWC_DISPLAY_PRIMARY)
		return -EINVAL;
	if (*numConfigs == 0)
		return 0;
	configs[0] = 0;
	*numConfigs = 1;
	return 0;
}

static int hwc_getDisplayAttributes(hwc_composer_device_1_t *dev, int disp,
		uint32_t config, const uint32_t *attributes, int32_t *values)
{
	eink_hwc_t *hw = (eink_hwc_t *)dev;
	(void)config;
	if (disp != HWC_DISPLAY_PRIMARY)
		return -EINVAL;
	for (int i = 0; attributes[i] != HWC_DISPLAY_NO_ATTRIBUTE; i++) {
		switch (attributes[i]) {
		case HWC_DISPLAY_VSYNC_PERIOD: values[i] = EINK_VSYNC_PERIOD_NS; break;
		case HWC_DISPLAY_WIDTH: values[i] = hw->width; break;
		case HWC_DISPLAY_HEIGHT: values[i] = hw->height; break;
		case HWC_DISPLAY_DPI_X: values[i] = 212000; break;
		case HWC_DISPLAY_DPI_Y: values[i] = 212000; break;
		default: values[i] = 0; break;
		}
	}
	return 0;
}

static void *vsync_thread_main(void *arg)
{
	eink_hwc_t *hw = (eink_hwc_t *)arg;
	struct timespec ts;
	int tick = 0;
	int loops = 0;
	int logged_wait = 0;
	while (!hw->stop_vsync) {
		usleep(EINK_VSYNC_PERIOD_NS / 1000);
		/* Timestamp the event when it is delivered, not a period earlier:
		 * SurfaceFlinger builds its model out of these. */
		clock_gettime(CLOCK_MONOTONIC, &ts);
		int64_t now_ns = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
		/*
		 * Free-running: deliver every tick, whether or not SurfaceFlinger
		 * currently has vsync "enabled".
		 *
		 * Waiting to be asked deadlocked the display. SurfaceFlinger's
		 * DispSync builds its timing model out of these samples and then
		 * generates the software vsync that drives both composition and
		 * every app's Choreographer. With delivery gated on eventControl
		 * it got one sample in a whole boot (eventControl was called
		 * twice), so the model never formed, no software vsync was ever
		 * generated, and nothing asked for hardware vsync either --
		 * each waiting for the other. The panel then only moved when a
		 * WindowManager transaction forced a composite, which is why a
		 * game froze unless the notification shade was on screen.
		 *
		 * An unconditional 10 Hz tick is what a composer without real
		 * vsync hardware is supposed to provide, and it costs one
		 * wakeup per 100 ms.
		 */
		if (hw->procs && hw->procs->vsync) {
			hw->vsync_requested = 0;
			hw->procs->vsync(hw->procs, HWC_DISPLAY_PRIMARY, now_ns);
			tick++;
			g_vsync_events++;
			if (tick <= 5 || (tick % 150) == 0)
				ALOGI("hwcomposer_eink: vsync thread delivered callback #%d", tick);
		} else if (!logged_wait && (tick == 0)) {
			/* Log once, ~2s in, if we're still waiting for eventControl/registerProcs. */
			static int waited_ticks = 0;
			waited_ticks++;
			if (waited_ticks == 30) {
				ALOGI("hwcomposer_eink: vsync thread still idle after ~2s: enabled=%d procs=%p vsync_fn=%p",
					hw->vsync_enabled, (void*)hw->procs, hw->procs ? (void*)hw->procs->vsync : NULL);
				logged_wait = 1;
			}
		}
		/*
		 * Keep the pump primed while something is animating.
		 *
		 * A layer queueing a buffer is supposed to wake SurfaceFlinger
		 * (onFrameAvailable -> signalLayerUpdate -> invalidate), and on
		 * this port it does not: a full-screen app renders frame after
		 * frame and the screen stays on the one SurfaceFlinger last
		 * composed. It comes alive the moment any system window is on
		 * screen, because WindowManager's transactions then drive
		 * composition instead -- pull the notification shade down over a
		 * game and the game animates behind it.
		 *
		 * Until the cause is found, ask SurfaceFlinger to recomposite
		 * while the screen is known to be changing: for up to
		 * EINK_NUDGE_IDLE_US after the last update that actually altered
		 * the panel, and only if it has not composited very recently. An
		 * animating app keeps renewing that window; a still screen stops
		 * producing changes, the window lapses, and this goes quiet, so
		 * an idle device is not woken at all.
		 */
		if (hw->procs && hw->procs->invalidate && g_last_change_us) {
			unsigned long nowu = now_us();

			if (nowu - g_last_change_us < EINK_NUDGE_IDLE_US &&
					nowu - g_last_set_us > EINK_NUDGE_QUIET_US) {
				g_nudges++;
				hw->procs->invalidate(hw->procs);
			}
		}

		/* Status even when nothing is composing: "frames stopped" and
		 * "frames are identical" look the same on an e-ink panel. Count
		 * loop iterations, not delivered vsyncs -- a stall stops the
		 * deliveries, which is precisely when this needs to report. */
		if ((++loops % 50) == 0)
			ALOGI("hwcomposer_eink: status sets=%d composed=%lu updates=%lu "
				"identical=%lu vsyncs=%lu eventControl=%lu nudges=%lu enabled=%d "
				"prepares=%lu prep_composites=%lu | avg ms: total=%lu clear=%lu "
				"layers=%lu diff=%lu ioctl=%lu",
				g_set_count, g_frames_composed, g_updates_sent,
				g_frames_identical, g_vsync_events, g_eventcontrol_count,
				g_nudges, hw->vsync_enabled,
				(unsigned long)g_prepare_count, g_prepare_composites,
				g_frames_composed ? g_compose_us / g_frames_composed / 1000 : 0,
				g_frames_composed ? g_clear_us / g_frames_composed / 1000 : 0,
				g_frames_composed ? g_layers_us / g_frames_composed / 1000 : 0,
				g_frames_composed ? g_diff_us / g_frames_composed / 1000 : 0,
				g_updates_sent ? g_update_us / g_updates_sent / 1000 : 0);
	}
	return NULL;
}

static int hwc_close(struct hw_device_t *dev)
{
	eink_hwc_t *hw = (eink_hwc_t *)dev;
	hw->stop_vsync = 1;
	pthread_join(hw->vsync_thread, NULL);
	if (hw->fb_mem && hw->fb_mem != MAP_FAILED)
		munmap(hw->fb_mem, hw->fb_size);
	free(hw->shadow);
	free(hw->panel);
	if (hw->fb_fd >= 0)
		close(hw->fb_fd);
	free(hw);
	return 0;
}

static int hwc_device_open(const hw_module_t *module, const char *name, hw_device_t **device)
{
	if (strcmp(name, HWC_HARDWARE_COMPOSER) != 0)
		return -EINVAL;

	ALOGI("hwcomposer_eink: device_open called");

	eink_hwc_t *hw = (eink_hwc_t *)malloc(sizeof(*hw));
	if (!hw)
		return -ENOMEM;
	memset(hw, 0, sizeof(*hw));

	hw->fb_fd = open("/dev/graphics/fb0", O_RDWR);
	if (hw->fb_fd < 0) {
		ALOGE("hwcomposer_eink: open(/dev/graphics/fb0) failed: %s", strerror(errno));
		free(hw);
		return -ENODEV;
	}

	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	if (ioctl(hw->fb_fd, FBIOGET_VSCREENINFO, &vinfo) == -1 ||
	    ioctl(hw->fb_fd, FBIOGET_FSCREENINFO, &finfo) == -1) {
		ALOGE("hwcomposer_eink: FBIOGET_*SCREENINFO failed: %s", strerror(errno));
		close(hw->fb_fd);
		free(hw);
		return -ENODEV;
	}

	/* One coordinate space now: the panel's own. Rotation belongs to
	 * WindowManager/SurfaceFlinger, which already do it (and already
	 * rotate touch input to match); we just honour the per-layer
	 * transform they hand us. See the comment on width/height above. */
	hw->fb_width = vinfo.xres;
	hw->fb_height = vinfo.yres;
	hw->width = vinfo.xres;
	hw->height = vinfo.yres;
	hw->stride_bytes = finfo.line_length;
	hw->bpp = vinfo.bits_per_pixel / 8;
	hw->fb_size = (size_t)finfo.line_length * vinfo.yres;

	hw->fb_mem = mmap(NULL, hw->fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, hw->fb_fd, 0);
	if (hw->fb_mem == MAP_FAILED) {
		ALOGE("hwcomposer_eink: mmap fb failed: %s", strerror(errno));
		close(hw->fb_fd);
		free(hw);
		return -ENODEV;
	}

	hw->shadow = malloc(hw->fb_size);
	hw->panel = malloc(hw->fb_size);
	if (!hw->shadow || !hw->panel) {
		ALOGE("hwcomposer_eink: failed to allocate %zu-byte shadow buffers", hw->fb_size);
		free(hw->shadow);
	free(hw->panel);
		free(hw->panel);
		munmap(hw->fb_mem, hw->fb_size);
		close(hw->fb_fd);
		free(hw);
		return -ENOMEM;
	}
	/* Start from what fb0 holds, so the first frame does not repaint the
	 * whole panel just because this copy was empty. */
	memcpy(hw->panel, hw->fb_mem, hw->fb_size);

	void *gr_handle = dlopen(GRALLOC_MODULE_PATH, RTLD_NOW);
	if (gr_handle) {
		hw->gralloc = (const gralloc_module_t *)dlsym(gr_handle, HAL_MODULE_INFO_SYM_AS_STR);
		hw->query_fn = (eink_gralloc_query_fn)dlsym(gr_handle, "eink_gralloc_query");
	}
	if (!hw->gralloc || !hw->query_fn) {
		ALOGE("hwcomposer_eink: failed to bind gralloc module/query fn (gralloc=%p query_fn=%p)",
			(void*)hw->gralloc, (void*)hw->query_fn);
	}

	ALOGI("hwcomposer_eink: fb %dx%d stride=%d bpp=%d size=%zu (no HWC-side rotation; "
		"honouring per-layer transform instead)",
		hw->width, hw->height, hw->stride_bytes, hw->bpp, hw->fb_size);

	hw->device.common.tag = HARDWARE_DEVICE_TAG;
	hw->device.common.version = HWC_DEVICE_API_VERSION_1_1;
	hw->device.common.module = (hw_module_t *)module;
	hw->device.common.close = hwc_close;
	hw->device.prepare = hwc_prepare;
	hw->device.set = hwc_set;
	hw->device.eventControl = hwc_eventControl;
	hw->device.blank = hwc_blank;
	hw->device.query = hwc_query;
	hw->device.registerProcs = hwc_registerProcs;
	hw->device.getDisplayConfigs = hwc_getDisplayConfigs;
	hw->device.getDisplayAttributes = hwc_getDisplayAttributes;

	/* See g_fence_src: SurfaceFlinger needs a valid retire fence to keep
	 * hardware vsync alive. Prefer the real thing if this kernel has it. */
	g_fence_src = open("/dev/sw_sync", O_RDWR);
	if (g_fence_src < 0)
		g_fence_src = open("/dev/null", O_RDONLY);
	if (g_fence_src < 0)
		ALOGE("hwcomposer_eink: no retire fence fd: %s", strerror(errno));

	pthread_create(&hw->vsync_thread, NULL, vsync_thread_main, hw);

	*device = &hw->device.common;
	ALOGI("hwcomposer_eink: device_open succeeded, hw=%p", (void*)hw);
	return 0;
}

static struct hw_module_methods_t hwc_module_methods = {
	.open = hwc_device_open
};

hwc_module_t HAL_MODULE_INFO_SYM = {
	.common = {
		.tag = HARDWARE_MODULE_TAG,
		.version_major = 1,
		.version_minor = 1,
		.id = HWC_HARDWARE_MODULE_ID,
		.name = "E-ink software HWComposer",
		.author = "clara-hd project",
		.methods = &hwc_module_methods,
	}
};
