/*
 * Directly test whether /system/lib/hw/gralloc.default.so can even be
 * dlopen()'d and its HMI symbol found, independent of surfaceflinger's own
 * complex startup context -- to isolate "our .so doesn't load at all" from
 * "it loads fine but something inside its open() call fails".
 */
#include <stdio.h>
#include <dlfcn.h>
#include <string.h>
#include <hardware/hardware.h>
#include <hardware/gralloc.h>

int main(void)
{
	FILE *log = fopen("/dlopen_probe_output.txt", "w");
	if (!log)
		return 1;
	setvbuf(log, NULL, _IONBF, 0);

	const char *path = "/system/lib/hw/gralloc.default.so";
	void *handle = dlopen(path, RTLD_NOW);
	fprintf(log, "dlopen(%s) = %p\n", path, handle);
	if (!handle) {
		fprintf(log, "dlerror: %s\n", dlerror());
		fclose(log);
		return 1;
	}

	const hw_module_t *hmi = (const hw_module_t *)dlsym(handle, HAL_MODULE_INFO_SYM_AS_STR);
	fprintf(log, "dlsym(%s) = %p\n", HAL_MODULE_INFO_SYM_AS_STR, (void*)hmi);
	if (!hmi) {
		fprintf(log, "dlerror: %s\n", dlerror());
		fclose(log);
		return 1;
	}

	fprintf(log, "hmi->tag=0x%x version_major=%d version_minor=%d id=%s name=%s methods=%p open=%p\n",
		hmi->tag, hmi->version_major, hmi->version_minor,
		hmi->id ? hmi->id : "(null)", hmi->name ? hmi->name : "(null)",
		(void*)hmi->methods, hmi->methods ? (void*)hmi->methods->open : NULL);

	if (!hmi->methods || !hmi->methods->open) {
		fprintf(log, "methods or open is NULL, cannot proceed\n");
		fclose(log);
		return 1;
	}

	hw_device_t *dev = NULL;
	int status = hmi->methods->open(hmi, GRALLOC_HARDWARE_GPU0, &dev);
	fprintf(log, "open(GRALLOC_HARDWARE_GPU0) status=%d dev=%p\n", status, (void*)dev);

	fprintf(log, "=== probe completed without crashing ===\n");
	fclose(log);
	return 0;
}
