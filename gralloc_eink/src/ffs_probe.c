/*
 * One-shot FunctionFS probe.
 *
 * adbd runs, /dev/usb-ffs/adb/ep0 exists and is shell-owned, yet ep1/ep2
 * never appear -- meaning adbd never gets its descriptors accepted, so
 * f_fs keeps desc_ready false and binding the gadget to the UDC fails
 * with -ENODEV ("configfs-gadget ci_hdrc.0: failed to start g1: -19").
 * As an init service adbd's stderr goes nowhere and its own tracing is
 * too expensive to leave on (it cost 27% CPU for a whole boot), so this
 * does exactly what adbd's init_functionfs() does -- open ep0, write the
 * legacy v1 descriptor block, then the strings block -- and reports the
 * exact errno for each step.
 *
 * Diagnostic only: it closes ep0 again immediately. f_fs tears the
 * function's state down when the last ep0 holder closes, so this cannot
 * stand in for adbd; it only proves whether the kernel accepts what adbd
 * is sending. It must also run BEFORE adbd, since f_fs allows a single
 * ep0 opener (a second one gets -EBUSY).
 *
 * The descriptor layout is deliberately byte-identical to KitKat adbd's
 * (bionic/adb usb_linux_client.c): magic FUNCTIONFS_DESCRIPTORS_MAGIC=1,
 * 3 full-speed + 3 high-speed descriptors, interface class/subclass/
 * protocol 0xff/0x42/0x01, two bulk endpoints.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>

#define LOGF "/ffs_probe_output.txt"
#define EP0  "/dev/usb-ffs/adb/ep0"

#define FUNCTIONFS_DESCRIPTORS_MAGIC 1
#define FUNCTIONFS_STRINGS_MAGIC     2

#define MAX_PACKET_SIZE_FS 64
#define MAX_PACKET_SIZE_HS 512

#define USB_DT_INTERFACE 0x04
#define USB_DT_ENDPOINT  0x05
#define USB_DIR_OUT      0x00
#define USB_DIR_IN       0x80
#define USB_ENDPOINT_XFER_BULK 0x02

struct usb_interface_descriptor_p {
	uint8_t bLength;
	uint8_t bDescriptorType;
	uint8_t bInterfaceNumber;
	uint8_t bAlternateSetting;
	uint8_t bNumEndpoints;
	uint8_t bInterfaceClass;
	uint8_t bInterfaceSubClass;
	uint8_t bInterfaceProtocol;
	uint8_t iInterface;
} __attribute__((packed));

struct usb_endpoint_descriptor_p {
	uint8_t bLength;
	uint8_t bDescriptorType;
	uint8_t bEndpointAddress;
	uint8_t bmAttributes;
	uint16_t wMaxPacketSize;
	uint8_t bInterval;
} __attribute__((packed));

struct func_desc {
	struct usb_interface_descriptor_p intf;
	struct usb_endpoint_descriptor_p source;
	struct usb_endpoint_descriptor_p sink;
} __attribute__((packed));

static struct {
	uint32_t magic;
	uint32_t length;
	uint32_t fs_count;
	uint32_t hs_count;
	struct func_desc fs_descs, hs_descs;
} __attribute__((packed)) descriptors = {
	.magic = FUNCTIONFS_DESCRIPTORS_MAGIC,
	.length = sizeof(descriptors),
	.fs_count = 3,
	.hs_count = 3,
	.fs_descs = {
		.intf = {
			.bLength = sizeof(descriptors.fs_descs.intf),
			.bDescriptorType = USB_DT_INTERFACE,
			.bInterfaceNumber = 0,
			.bNumEndpoints = 2,
			.bInterfaceClass = 0xff,
			.bInterfaceSubClass = 0x42,
			.bInterfaceProtocol = 1,
			.iInterface = 1,
		},
		.source = {
			.bLength = sizeof(descriptors.fs_descs.source),
			.bDescriptorType = USB_DT_ENDPOINT,
			.bEndpointAddress = 1 | USB_DIR_OUT,
			.bmAttributes = USB_ENDPOINT_XFER_BULK,
			.wMaxPacketSize = MAX_PACKET_SIZE_FS,
		},
		.sink = {
			.bLength = sizeof(descriptors.fs_descs.sink),
			.bDescriptorType = USB_DT_ENDPOINT,
			.bEndpointAddress = 2 | USB_DIR_IN,
			.bmAttributes = USB_ENDPOINT_XFER_BULK,
			.wMaxPacketSize = MAX_PACKET_SIZE_FS,
		},
	},
	.hs_descs = {
		.intf = {
			.bLength = sizeof(descriptors.hs_descs.intf),
			.bDescriptorType = USB_DT_INTERFACE,
			.bInterfaceNumber = 0,
			.bNumEndpoints = 2,
			.bInterfaceClass = 0xff,
			.bInterfaceSubClass = 0x42,
			.bInterfaceProtocol = 1,
			.iInterface = 1,
		},
		.source = {
			.bLength = sizeof(descriptors.hs_descs.source),
			.bDescriptorType = USB_DT_ENDPOINT,
			.bEndpointAddress = 1 | USB_DIR_OUT,
			.bmAttributes = USB_ENDPOINT_XFER_BULK,
			.wMaxPacketSize = MAX_PACKET_SIZE_HS,
		},
		.sink = {
			.bLength = sizeof(descriptors.hs_descs.sink),
			.bDescriptorType = USB_DT_ENDPOINT,
			.bEndpointAddress = 2 | USB_DIR_IN,
			.bmAttributes = USB_ENDPOINT_XFER_BULK,
			.wMaxPacketSize = MAX_PACKET_SIZE_HS,
		},
	},
};

#define STR_INTERFACE "ADB Interface"

static struct {
	uint32_t magic;
	uint32_t length;
	uint32_t str_count;
	uint32_t lang_count;
	struct {
		uint16_t code;
		char str1[sizeof(STR_INTERFACE)];
	} __attribute__((packed)) lang0;
} __attribute__((packed)) strings = {
	.magic = FUNCTIONFS_STRINGS_MAGIC,
	.length = sizeof(strings),
	.str_count = 1,
	.lang_count = 1,
	.lang0 = { 0x0409, STR_INTERFACE },
};

int main(void)
{
	FILE *log = fopen(LOGF, "a");
	int fd;
	ssize_t n;

	if (!log)
		return 1;
	setvbuf(log, NULL, _IONBF, 0);

	fprintf(log, "=== ffs_probe: uid=%d gid=%d, descriptors=%zu bytes, strings=%zu bytes ===\n",
		getuid(), getgid(), sizeof(descriptors), sizeof(strings));

	fd = open(EP0, O_RDWR);
	if (fd < 0) {
		fprintf(log, "open(%s) FAILED: errno=%d (%s)\n", EP0, errno, strerror(errno));
		fclose(log);
		return 1;
	}
	fprintf(log, "open(%s) ok, fd=%d\n", EP0, fd);

	n = write(fd, &descriptors, sizeof(descriptors));
	if (n < 0)
		fprintf(log, "write(descriptors) FAILED: errno=%d (%s)\n", errno, strerror(errno));
	else
		fprintf(log, "write(descriptors) ok, wrote %zd of %zu\n", n, sizeof(descriptors));

	n = write(fd, &strings, sizeof(strings));
	if (n < 0)
		fprintf(log, "write(strings) FAILED: errno=%d (%s)\n", errno, strerror(errno));
	else
		fprintf(log, "write(strings) ok, wrote %zd of %zu\n", n, sizeof(strings));

	/* If both writes landed, f_fs has moved to FFS_ACTIVE and created the
	 * endpoint files -- the very thing that never happens under adbd. */
	fprintf(log, "ep1 present: %s, ep2 present: %s\n",
		access("/dev/usb-ffs/adb/ep1", F_OK) == 0 ? "yes" : "no",
		access("/dev/usb-ffs/adb/ep2", F_OK) == 0 ? "yes" : "no");

	close(fd);
	fprintf(log, "closed ep0 (function state torn down again; adbd starts next)\n");
	fclose(log);
	return 0;
}
