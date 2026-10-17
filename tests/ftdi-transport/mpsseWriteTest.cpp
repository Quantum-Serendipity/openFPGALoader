// SPDX-License-Identifier: Apache-2.0

#include <cstdio>
#include <cstring>

#include <ftdi.h>
#include <libusb.h>

#include "ftdipp_mpsse.hpp"

static int failures = 0;
static int write_reply = -1;
static struct ftdi_context ctx;

#define CHECK(cond) do { \
	if (!(cond)) { \
		printf("FAIL %s:%d %s\n", __func__, __LINE__, #cond); \
		failures++; \
	} \
} while (0)

extern "C" {
struct ftdi_context *ftdi_new(void)
{
	memset(&ctx, 0, sizeof(ctx));
	ctx.max_packet_size = 512;
	return &ctx;
}
int ftdi_set_interface(struct ftdi_context *, enum ftdi_interface)
{
	return 0;
}
int ftdi_usb_open_desc_index(struct ftdi_context *, int, int, const char *,
	const char *, unsigned int)
{
	return 0;
}
int ftdi_set_baudrate(struct ftdi_context *, int)
{
	return 0;
}
int ftdi_write_data(struct ftdi_context *, const unsigned char *, int size)
{
	return (write_reply == -1) ? size : write_reply;
}
const char *ftdi_get_error_string(struct ftdi_context *)
{
	return "stub";
}
libusb_device *LIBUSB_CALL libusb_get_device(libusb_device_handle *)
{
	return reinterpret_cast<libusb_device *>(&ctx);
}
int LIBUSB_CALL libusb_get_device_descriptor(libusb_device *,
	struct libusb_device_descriptor *desc)
{
	memset(desc, 0, sizeof(*desc));
	return 0;
}
int LIBUSB_CALL libusb_get_string_descriptor_ascii(libusb_device_handle *,
	uint8_t, unsigned char *, int)
{
	return -1;
}
}

class Probe: public FTDIpp_MPSSE {
	public:
		Probe(const cable_t &cable): FTDIpp_MPSSE(cable, "", "", 6000000) {}
		int store(int n)
		{
			unsigned char b[16] = {0};
			return mpsse_store(b, n);
		}
		int write() { return mpsse_write(); }
		int pending() { return _num; }
};

int main()
{
	cable_t cable = {};
	Probe *p = new Probe(cable);

	write_reply = -1;
	CHECK(p->store(10) == 0);
	CHECK(p->write() == 10);
	CHECK(p->pending() == 0);

	CHECK(p->store(10) == 0);
	write_reply = 5;
	CHECK(p->write() < 0);
	write_reply = 0;
	CHECK(p->write() < 0);
	write_reply = -4;
	CHECK(p->write() < 0);

	printf("mpsse_write: %s\n", failures ? "FAILED" : "passed");
	return failures ? 1 : 0;
}
