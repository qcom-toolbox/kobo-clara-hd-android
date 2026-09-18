/* Offscreen OpenGL ES 2.0 smoke test for SwiftShader on the Kobo.
 * Linked directly against libEGL_swiftshader.so / libGLESv2_swiftshader.so;
 * run with LD_LIBRARY_PATH pointing at them (no system install needed).
 * Renders a shaded triangle into a pbuffer and checks pixels. */
#include <stdio.h>
#include <time.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv)
{

	EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint maj, min;
	if (!eglInitialize(d, &maj, &min)) { printf("eglInitialize failed 0x%x\n", eglGetError()); return 1; }
	printf("EGL %d.%d vendor=%s\n", maj, min, eglQueryString(d, EGL_VENDOR));
	const EGLint ca[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_DEPTH_SIZE, 16, EGL_NONE };
	EGLConfig cfg; EGLint n = 0;
	if (!eglChooseConfig(d, ca, &cfg, 1, &n) || n < 1) { printf("no ES2 config (0x%x)\n", eglGetError()); return 1; }
	const EGLint sa[] = { EGL_WIDTH, 256, EGL_HEIGHT, 256, EGL_NONE };
	EGLSurface s = eglCreatePbufferSurface(d, cfg, sa);
	const EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext c = eglCreateContext(d, cfg, EGL_NO_CONTEXT, xa);
	if (s == EGL_NO_SURFACE || c == EGL_NO_CONTEXT || !eglMakeCurrent(d, s, s, c)) {
		printf("surface/context failed 0x%x\n", eglGetError()); return 1;
	}


	printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\nGLSL=%s\n", glGetString(GL_VENDOR),
		glGetString(GL_RENDERER), glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));

	const char *vs = "attribute vec2 p; varying vec2 v; void main(){ v = p*0.5+0.5; gl_Position = vec4(p,0.0,1.0); }";
	const char *fs = "precision mediump float; varying vec2 v; void main(){ gl_FragColor = vec4(v.x, v.y, 1.0-v.x, 1.0); }";
	GLuint sh[2]; const char *srcs[2] = { vs, fs }; GLenum types[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
	for (int i = 0; i < 2; i++) {
		GLint ok; sh[i] = glCreateShader(types[i]); glShaderSource(sh[i], 1, &srcs[i], NULL); glCompileShader(sh[i]);
		glGetShaderiv(sh[i], GL_COMPILE_STATUS, &ok);
		if (!ok) { char log[512]; glGetShaderInfoLog(sh[i], sizeof log, NULL, log); printf("shader %d: %s\n", i, log); return 1; }
	}
	GLuint prog = glCreateProgram(); glAttachShader(prog, sh[0]); glAttachShader(prog, sh[1]);
	glBindAttribLocation(prog, 0, "p"); glLinkProgram(prog);
	GLint linked; glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked) { printf("link failed\n"); return 1; }
	glUseProgram(prog);
	static const GLfloat tri[] = { -1, -1, 1, -1, 0, 1 };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri); glEnableVertexAttribArray(0);
	glViewport(0, 0, 256, 256);

	double t0 = now();
	glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLES, 0, 3); glFinish();
	double t1 = now();
	for (int i = 0; i < 20; i++) { glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLES, 0, 3); }
	glFinish();
	double t2 = now();

	unsigned char px[4 * 4];
	glReadPixels(128, 64, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	glReadPixels(2, 250, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px + 4);
	printf("first frame (incl. JIT) %.0f ms, then %.1f ms/frame at 256x256\n", (t1 - t0) * 1000, (t2 - t1) * 1000 / 20);
	printf("center-low pixel rgba=%u,%u,%u,%u (expect ~128,~96,~127,255)\n", px[0], px[1], px[2], px[3]);
	printf("corner pixel     rgba=%u,%u,%u,%u (expect 0,0,0,255 outside triangle)\n", px[4], px[5], px[6], px[7]);
	printf("glGetError=0x%x\n", glGetError());
	int good = px[2] > 60 && px[3] == 255 && px[4] == 0;
	printf("%s\n", good ? "RESULT: OK" : "RESULT: WRONG PIXELS");
	return good ? 0 : 2;
}
