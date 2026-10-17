// SPDX-License-Identifier: Apache-2.0

#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

#include "ftdiJtagMPSSE.hpp"
#include "ftdipp_mpsse.hpp"

static int failures = 0;
static int fail_read_at = -1;
static int fail_write_at = -1;
static int reads = 0;
static int writes = 0;
static unsigned char store_buf[65536];

#define CHECK(cond) do { \
	if (!(cond)) { \
		printf("FAIL %s:%d %s\n", __func__, __LINE__, #cond); \
		failures++; \
	} \
} while (0)

FTDIpp_MPSSE::FTDIpp_MPSSE(const cable_t &cable, const std::string &,
		const std::string &, uint32_t clkHZ, int8_t verbose):
	_verbose(verbose > 1), _cable(cable.config), _vid(0), _pid(0), _index(0),
	_bus(0), _addr(0), _bitmode(0), _interface(0), _clkHZ(clkHZ),
	_ftdi(nullptr), _buffer_size(4096), _num(0), _buffer(store_buf)
{
	memset(_product, 0, sizeof(_product));
	memset(_iproduct, 0, sizeof(_iproduct));
	memset(_imanufacturer, 0, sizeof(_imanufacturer));
	memset(_iserialnumber, 0, sizeof(_iserialnumber));
}

FTDIpp_MPSSE::~FTDIpp_MPSSE() {}

int FTDIpp_MPSSE::init(unsigned char, unsigned char, unsigned char)
{
	return 0;
}

int FTDIpp_MPSSE::setClkFreq(uint32_t clkHZ)
{
	_clkHZ = clkHZ;
	return clkHZ;
}

int FTDIpp_MPSSE::mpsse_store(unsigned char c)
{
	return mpsse_store(&c, 1);
}

int FTDIpp_MPSSE::mpsse_store(unsigned char *, int len)
{
	if (_num + len > _buffer_size && mpsse_write() < 0)
		return -1;
	_num += len;
	return 0;
}

int FTDIpp_MPSSE::mpsse_write()
{
	if (writes++ == fail_write_at)
		return -1;
	int n = _num;
	_num = 0;
	return n;
}

int FTDIpp_MPSSE::mpsse_read(unsigned char *rx_buff, int len)
{
	if (mpsse_write() < 0)
		return -1;
	if (reads++ == fail_read_at)
		return -1;
	memset(rx_buff, 0x5a, len);
	return len;
}

extern "C" {
int ftdi_read_data(struct ftdi_context *, unsigned char *, int size)
{
	return size;
}
const char *ftdi_get_error_string(struct ftdi_context *)
{
	return "stub";
}
}

static bool shift(FtdiJtagMPSSE &j, uint32_t nbits, bool with_tdo, bool last)
{
	unsigned char tx[64] = {0}, rx[64] = {0};
	try {
		return j.writeTDI(tx, with_tdo ? rx : nullptr, nbits, last) >= 0;
	} catch (const std::exception &) {
		return false;
	}
}

static void reset(int read_at, int write_at)
{
	reads = writes = 0;
	fail_read_at = read_at;
	fail_write_at = write_at;
}

int main()
{
	cable_t cable = {};
	FtdiJtagMPSSE j(cable, "", "", 6000000, false, 0);

	reset(-1, -1);
	CHECK(shift(j, 256, true, true));
	CHECK(shift(j, 13, true, false));
	CHECK(shift(j, 256, false, false));

	reset(0, -1);
	CHECK(!shift(j, 256, true, true));
	reset(0, -1);
	CHECK(!shift(j, 13, true, false));
	reset(1, -1);
	CHECK(!shift(j, 13, true, true));
	reset(-1, 0);
	CHECK(!shift(j, 256, true, true));
	reset(-1, 0);
	CHECK(!shift(j, 256, false, false));

	reset(-1, -1);
	printf("ftdiJtagMPSSE: %s\n", failures ? "FAILED" : "passed");
	return failures ? 1 : 0;
}
