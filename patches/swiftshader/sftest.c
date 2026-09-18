/* Mimics SurfaceFlinger's (4.4, HWC 1.1) EGL setup against SwiftShader
 * loaded by absolute path from argv[1] (like the system EGL loader does),
 * with no LD_LIBRARY_PATH help. */
#include <dlfcn.h>
#include <stdio.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#ifndef EGL_RECORDABLE_ANDROID
#define EGL_RECORDABLE_ANDROID 0x3142
#endif
#ifndef EGL_FRAMEBUFFER_TARGET_ANDROID
#define EGL_FRAMEBUFFER_TARGET_ANDROID 0x3147
#endif
#define SYM(n) n##_t n = (n##_t)dlsym(egl, #n); if (!n) { printf("missing " #n "\n"); return 1; }
typedef EGLDisplay (*eglGetDisplay_t)(EGLNativeDisplayType);
typedef EGLBoolean (*eglInitialize_t)(EGLDisplay, EGLint *, EGLint *);
typedef EGLBoolean (*eglChooseConfig_t)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
typedef EGLBoolean (*eglGetConfigAttrib_t)(EGLDisplay, EGLConfig, EGLint, EGLint *);
typedef EGLContext (*eglCreateContext_t)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
typedef EGLSurface (*eglCreatePbufferSurface_t)(EGLDisplay, EGLConfig, const EGLint *);
typedef EGLBoolean (*eglMakeCurrent_t)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
typedef EGLint (*eglGetError_t)(void);
typedef void *(*eglGetProcAddress_t)(const char *);
typedef const unsigned char *(*glGetString_t)(unsigned);

int main(int argc, char **argv)
{
	char p[256];
	snprintf(p, sizeof p, "%s/libEGL_swiftshader.so", argc > 1 ? argv[1] : "/system/lib/egl");
	void *egl = dlopen(p, RTLD_NOW);
	if (!egl) { printf("dlopen: %s\n", dlerror()); return 1; }
	SYM(eglGetDisplay) SYM(eglInitialize) SYM(eglChooseConfig) SYM(eglGetConfigAttrib)
	SYM(eglCreateContext) SYM(eglCreatePbufferSurface) SYM(eglMakeCurrent) SYM(eglGetError)
	SYM(eglGetProcAddress)
	EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (!eglInitialize(d, NULL, NULL)) { printf("init failed 0x%x\n", eglGetError()); return 1; }
	const EGLint a[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID, EGL_TRUE,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_FRAMEBUFFER_TARGET_ANDROID, EGL_TRUE,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE };
	EGLConfig cfgs[64]; EGLint n = 0, i, vis = -1;
	eglChooseConfig(d, a, cfgs, 64, &n);
	EGLConfig cfg = 0;
	for (i = 0; i < n; i++) {
		eglGetConfigAttrib(d, cfgs[i], EGL_NATIVE_VISUAL_ID, &vis);
		if (vis == 1 /* HAL_PIXEL_FORMAT_RGBA_8888 */) { cfg = cfgs[i]; break; }
	}
	printf("SF ES2 query: %d configs, RGBA_8888 framebuffer-target config %s\n", n, cfg ? "FOUND" : "missing");
	if (!cfg) return 1;
	const EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext c = eglCreateContext(d, cfg, EGL_NO_CONTEXT, ca);
	printf("ES2 context: %s (0x%x)\n", c != EGL_NO_CONTEXT ? "OK" : "FAILED", eglGetError());
	if (c == EGL_NO_CONTEXT) return 1;
	const EGLint pa[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
	EGLSurface s = eglCreatePbufferSurface(d, cfg, pa);
	if (!eglMakeCurrent(d, s, s, c)) { printf("makeCurrent failed 0x%x\n", eglGetError()); return 1; }
	glGetString_t gs = (glGetString_t)eglGetProcAddress("glGetString");
	printf("GL_RENDERER=%s GL_VERSION=%s\n", gs ? (const char *)gs(0x1F01) : "?", gs ? (const char *)gs(0x1F02) : "?");
	const EGLint ca1[] = { EGL_CONTEXT_CLIENT_VERSION, 1, EGL_NONE };
	EGLContext c1 = eglCreateContext(d, cfg, EGL_NO_CONTEXT, ca1);
	printf("ES1 context: %s\n", c1 != EGL_NO_CONTEXT ? "OK" : "FAILED");
	printf("RESULT: %s\n", c1 != EGL_NO_CONTEXT ? "OK" : "PARTIAL");
	return 0;
}
