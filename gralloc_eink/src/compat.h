/* strlcpy isn't in glibc (it's a BSD/bionic extension); ashmem-dev.c uses
 * it once, so provide the standard semantics ourselves rather than pull
 * in a compat library. */
#ifndef _EINK_COMPAT_H
#define _EINK_COMPAT_H

#include <string.h>

static inline size_t strlcpy(char *dst, const char *src, size_t size)
{
	size_t srclen = strlen(src);
	if (size != 0) {
		size_t copylen = srclen < size - 1 ? srclen : size - 1;
		memcpy(dst, src, copylen);
		dst[copylen] = '\0';
	}
	return srclen;
}

#endif
