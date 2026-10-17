// SPDX-License-Identifier: Apache-2.0

#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

#include "xilinxFrameSpace.hpp"

static int failures = 0;

#define CHECK(cond) do { \
	if (!(cond)) { \
		printf("FAIL %s:%d %s\n", __func__, __LINE__, #cond); \
		failures++; \
	} \
} while (0)

static const xil7::FrameSpace &a100t()
{
	static const xil7::FrameSpace *fs = xil7::find_frame_space(0x03631093);
	return *fs;
}

static std::vector<uint32_t> full_sweep(unsigned *crossings)
{
	std::vector<uint32_t> v(1, 0);
	*crossings = 0;
	uint32_t next;
	bool crossed;
	while (xil7::next_far(a100t(), v.back(), &next, &crossed)) {
		*crossings += crossed;
		v.push_back(next);
	}
	return v;
}

static void test_descriptor()
{
	CHECK(xil7::find_frame_space(0x03631093) != NULL);
	CHECK(xil7::find_frame_space(0x0362D093) == NULL);
	std::string err;
	CHECK(xil7::check_frame_space(a100t(), &err));
}

static void test_sweep()
{
	unsigned crossings;
	const std::vector<uint32_t> v = full_sweep(&crossings);
	CHECK(v.size() == a100t().real_frames);
	CHECK(crossings == 7);
	CHECK(v.back() == 0x00C2017F);
	bool ascending = true, valid = true;
	std::string err;
	for (size_t i = 0; i < v.size(); i++) {
		if (i && v[i] <= v[i - 1])
			ascending = false;
		if (!xil7::far_in_space(a100t(), v[i], &err))
			valid = false;
	}
	CHECK(ascending);
	CHECK(valid);
}

static void test_far_in_space()
{
	std::string err;
	CHECK(xil7::far_in_space(a100t(), 0x0000009D, &err));
	CHECK(!xil7::far_in_space(a100t(), 0x0000009E, &err));
	CHECK(err.find("minor") != std::string::npos);
	CHECK(xil7::far_in_space(a100t(), 0x0002199F, &err));
	CHECK(!xil7::far_in_space(a100t(), 0x000219A0, &err));
	CHECK(!xil7::far_in_space(a100t(), 0x00003A00, &err));
	CHECK(err.find("column") != std::string::npos);
	CHECK(!xil7::far_in_space(a100t(), 0x01000000, &err));
	CHECK(!xil7::far_in_space(a100t(), 0x00040000, &err));
	CHECK(!xil7::far_in_space(a100t(), 0x80000000, &err));
	CHECK(xil7::far_in_space(a100t(), 0x00C2017F, &err));
}

static void test_plan()
{
	xil7::ReadbackPlan p;
	std::string err;

	CHECK(xil7::plan_readback(a100t(), 0x00000F00, 100, &p, &err));
	CHECK(p.pad_frames == 0 && p.stream_frames == 100);

	CHECK(xil7::plan_readback(a100t(), 0x00021990, 48, &p, &err));
	CHECK(p.labels[15] == 0x0002199F && p.slots[15] == 15);
	CHECK(p.labels[16] == 0x00400000 && p.slots[16] == 18);
	CHECK(p.labels[47] == 0x0040001F && p.slots[47] == 49);
	CHECK(p.stream_frames == 50 && p.pad_frames == 2);

	CHECK(xil7::plan_readback(a100t(), 0x00401C18, 80, &p, &err));
	CHECK(p.labels[48] == 0x00420000 && p.slots[48] == 50);
	CHECK(p.pad_frames == 2);

	CHECK(xil7::plan_readback(a100t(), 0x00421990, 20, &p, &err));
	CHECK(p.labels[16] == 0x00800000 && p.slots[16] == 18);

	CHECK(xil7::plan_readback(a100t(), 0x0002199F, 1, &p, &err));
	CHECK(p.stream_frames == 1 && p.pad_frames == 0);

	CHECK(xil7::plan_readback(a100t(), 0, a100t().real_frames, &p, &err));
	CHECK(p.pad_frames == 14);
	CHECK(p.stream_frames == a100t().real_frames + 14);
	CHECK(p.labels.back() == 0x00C2017F);

	CHECK(xil7::plan_readback(a100t(), 0x00C2017F, 1, &p, &err));
	CHECK(!xil7::plan_readback(a100t(), 0x00C2017F, 2, &p, &err));
	CHECK(!xil7::plan_readback(a100t(), 0x00000001, a100t().real_frames,
		&p, &err));
	CHECK(!xil7::plan_readback(a100t(), 0, 0, &p, &err));
	CHECK(!xil7::plan_readback(a100t(), 0x0000009E, 1, &p, &err));
	CHECK(!xil7::plan_readback(a100t(), 0, 0xFFFFFFFFu, &p, &err));
}

static void test_parse_u32()
{
	struct { const char *s; bool ok; uint32_t v; } cases[] = {
		{"0", true, 0}, {"1", true, 1}, {"0x0", true, 0},
		{"0X1f", true, 0x1F}, {"0xFFFFFFFF", true, 0xFFFFFFFFu},
		{"4294967295", true, 0xFFFFFFFFu}, {"0x000000001", true, 1},
		{"4294967296", false, 0}, {"0x100000000", false, 0},
		{"-1", false, 0}, {"-0", false, 0}, {"+1", false, 0},
		{" 1", false, 0}, {"1 ", false, 0}, {"010", false, 0},
		{"0x", false, 0}, {"", false, 0}, {"0x1g", false, 0},
		{"1e3", false, 0}, {"99999999999999999999", false, 0},
	};
	for (const auto &c : cases) {
		uint32_t v = 0xA5A5A5A5u;
		const bool ok = xil7::parse_u32(c.s, &v);
		if (ok != c.ok || (ok && v != c.v)) {
			printf("FAIL parse_u32(\"%s\") -> %d 0x%08x\n", c.s, ok, v);
			failures++;
		}
	}
}

static bool far_list_of(const std::string &text, std::vector<uint32_t> *v,
	std::string *err)
{
	std::istringstream in(text);
	return xil7::read_far_list(in, "t.far", v, err);
}

static void test_read_far_list()
{
	std::vector<uint32_t> v;
	std::string err;
	CHECK(far_list_of("# h\n\n  0x00000000\r\n1 \n# t\n", &v, &err));
	CHECK(v.size() == 2 && v[0] == 0 && v[1] == 1);
	CHECK(!far_list_of("0x0\n0x0\n", &v, &err));
	CHECK(err.find("ascending") != std::string::npos);
	CHECK(!far_list_of("0x1\n0x0\n", &v, &err));
	CHECK(!far_list_of("0x100000000\n", &v, &err));
	CHECK(err.find("t.far:1") != std::string::npos);
	CHECK(!far_list_of("-1\n", &v, &err));
	CHECK(!far_list_of("0x0 0x1\n", &v, &err));
	CHECK(!far_list_of("# nothing\n\n", &v, &err));
}

static void test_check_far_list()
{
	xil7::ReadbackPlan p;
	std::string err;
	unsigned crossings;
	const std::vector<uint32_t> all = full_sweep(&crossings);

	CHECK(xil7::plan_readback(a100t(), 0x00021990, 48, &p, &err));
	CHECK(xil7::check_far_list(a100t(), all, p, &err));
	CHECK(xil7::check_far_list(a100t(), p.labels, p, &err));

	std::vector<uint32_t> gap = p.labels;
	gap.erase(gap.begin() + 16);
	gap.push_back(0x00400020);
	CHECK(!xil7::check_far_list(a100t(), gap, p, &err));
	CHECK(err.find("sweep") != std::string::npos);

	std::vector<uint32_t> foreign = p.labels;
	foreign.push_back(0x01000000);
	CHECK(!xil7::check_far_list(a100t(), foreign, p, &err));

	std::vector<uint32_t> shorter(p.labels.begin(), p.labels.end() - 1);
	CHECK(!xil7::check_far_list(a100t(), shorter, p, &err));

	std::vector<uint32_t> later(p.labels.begin() + 1, p.labels.end());
	CHECK(!xil7::check_far_list(a100t(), later, p, &err));
}

int main()
{
	test_descriptor();
	test_sweep();
	test_far_in_space();
	test_plan();
	test_parse_u32();
	test_read_far_list();
	test_check_far_list();
	printf("xilinxFrameSpaceTest: %d failures\n", failures);
	return failures ? 1 : 0;
}
