// SPDX-License-Identifier: Apache-2.0

#include "xilinxFrameSpace.hpp"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace xil7 {

#define FAR_RSVD(f)   (((f) >> 26) & 0x3Fu)
#define FAR_BLOCK(f)  (((f) >> 23) & 0x07u)
#define FAR_HALF(f)   (((f) >> 22) & 0x01u)
#define FAR_ROW(f)    (((f) >> 17) & 0x1Fu)
#define FAR_COL(f)    (((f) >>  7) & 0x3FFu)
#define FAR_MINOR(f)  ( (f)        & 0x7Fu)

static uint32_t make_far(uint32_t block, uint32_t half, uint32_t row,
	uint32_t col, uint32_t minor)
{
	return (block << 23) | (half << 22) | (row << 17) | (col << 7) | minor;
}

static const uint8_t xc7a100t_clb_row0[58] = {
	42, 30, 36, 36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 36,
	36, 36, 30, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 30,
	36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 28, 36, 36, 36,
	28, 36, 36, 28, 36, 36, 36, 36, 30, 42,
};
static const uint8_t xc7a100t_clb_row1[52] = {
	42, 30, 36, 36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 36,
	36, 36, 30, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 30,
	36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 28, 36, 36, 36,
	28, 36, 36, 32,
};
static const uint8_t xc7a100t_bram[4] = {128, 128, 128, 128};

static const FrameSpace frame_spaces[] = {
	{0x03631093, "xc7a100t", 101, 2, 2,
		{{58, 52}, {4, 3}},
		{{xc7a100t_clb_row0, xc7a100t_clb_row1},
		 {xc7a100t_bram, xc7a100t_bram}},
		2, 9448, 9464},
};

bool parse_u32(const std::string &tok, uint32_t *out)
{
	uint64_t v = 0;
	size_t i = 0;
	unsigned base = 10;
	if (tok.size() > 2 && tok[0] == '0' && (tok[1] == 'x' || tok[1] == 'X')) {
		base = 16;
		i = 2;
	} else if (tok.empty() || (tok[0] == '0' && tok.size() > 1)) {
		return false;
	}
	for (; i < tok.size(); i++) {
		const char c = tok[i];
		unsigned d;
		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (base == 16 && c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (base == 16 && c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return false;
		v = v * base + d;
		if (v > 0xFFFFFFFFull)
			return false;
	}
	*out = static_cast<uint32_t>(v);
	return true;
}

bool read_far_list(std::istream &in, const std::string &name,
	std::vector<uint32_t> *out, std::string *err)
{
	char buf[160];
	std::string line;
	unsigned lineno = 0;
	out->clear();
	while (std::getline(in, line)) {
		lineno++;
		const size_t a = line.find_first_not_of(" \t\r\n");
		if (a == std::string::npos || line[a] == '#')
			continue;
		const size_t b = line.find_last_not_of(" \t\r\n");
		const std::string tok = line.substr(a, b - a + 1);
		uint32_t v;
		if (!parse_u32(tok, &v)) {
			*err = name + ":" + std::to_string(lineno) + ": '" + tok +
				"' is not a frame address (0x-prefixed hex or decimal, "
				"32 bits)";
			return false;
		}
		if (!out->empty() && v <= out->back()) {
			snprintf(buf, sizeof(buf), "%s:%u: 0x%08x after 0x%08x: the "
				"addresses must be strictly ascending, which is the order "
				"the device sweeps them in", name.c_str(), lineno, v,
				out->back());
			*err = buf;
			return false;
		}
		out->push_back(v);
	}
	if (in.bad()) {
		*err = name + ": read error";
		return false;
	}
	if (out->empty()) {
		*err = name + " carries no frame addresses";
		return false;
	}
	return true;
}

const FrameSpace *find_frame_space(uint32_t idcode)
{
	for (const FrameSpace &fs : frame_spaces)
		if (fs.idcode == idcode)
			return &fs;
	return NULL;
}

bool check_frame_space(const FrameSpace &fs, std::string *err)
{
	uint32_t real = 0, groups = 0;
	for (uint32_t b = 0; b < fs.blocks; b++) {
		for (uint32_t r = 0; r < fs.rows; r++) {
			for (uint32_t c = 0; c < fs.cols[b][r]; c++) {
				const uint32_t n = fs.col_frames[b][r][c];
				if (n == 0 || n > 128) {
					*err = std::string(fs.name) + ": a column with " +
						std::to_string(n) + " frames";
					return false;
				}
				real += FS_HALVES * n;
			}
			groups += FS_HALVES;
		}
	}
	if (real != fs.real_frames ||
			real + groups * fs.pads_per_group != fs.total_frames) {
		*err = std::string(fs.name) + ": columns sum to " +
			std::to_string(real) + " frames and " +
			std::to_string(real + groups * fs.pads_per_group) +
			" with pads, but the descriptor declares " +
			std::to_string(fs.real_frames) + " and " +
			std::to_string(fs.total_frames);
		return false;
	}
	return true;
}

bool far_in_space(const FrameSpace &fs, uint32_t far, std::string *err)
{
	const uint32_t blk = FAR_BLOCK(far), half = FAR_HALF(far);
	const uint32_t row = FAR_ROW(far), col = FAR_COL(far);
	const uint32_t minor = FAR_MINOR(far);
	const char *why = NULL;
	if (FAR_RSVD(far))
		why = "bits [31:26] are reserved and must be zero";
	else if (blk >= fs.blocks)
		why = "block type is not a frame-carrying block type on this part";
	else if (row >= fs.rows)
		why = "row address is past the last row of a half on this part";
	else if (col >= fs.cols[blk][row])
		why = "column address is past the last column of that block type "
		      "in that row";
	else if (minor >= fs.col_frames[blk][row][col])
		why = "minor address is past the last frame of that column";
	if (!why)
		return true;
	char buf[400];
	snprintf(buf, sizeof(buf), "FAR 0x%08x is outside %s's frame space -- "
		"%s. Decoded: block %u, %s half, row %u, column %u, minor %u.",
		far, fs.name, why, blk, half ? "bottom" : "top", row, col, minor);
	*err = buf;
	return false;
}

bool next_far(const FrameSpace &fs, uint32_t far, uint32_t *next,
	bool *crossed)
{
	uint32_t blk = FAR_BLOCK(far), half = FAR_HALF(far);
	uint32_t row = FAR_ROW(far), col = FAR_COL(far);
	const uint32_t minor = FAR_MINOR(far);
	*crossed = false;
	if (minor + 1u < fs.col_frames[blk][row][col]) {
		*next = far + 1;
		return true;
	}
	if (col + 1u < fs.cols[blk][row]) {
		*next = make_far(blk, half, row, col + 1, 0);
		return true;
	}
	*crossed = true;
	if (row + 1u < fs.rows) {
		row++;
	} else if (half == 0) {
		half = 1;
		row = 0;
	} else if (blk + 1u < fs.blocks) {
		blk++;
		half = 0;
		row = 0;
	} else {
		return false;
	}
	*next = make_far(blk, half, row, 0, 0);
	return true;
}

bool plan_readback(const FrameSpace &fs, uint32_t far, uint32_t count,
	ReadbackPlan *plan, std::string *err)
{
	if (!far_in_space(fs, far, err))
		return false;
	if (count == 0) {
		*err = "a count of zero frames reads nothing";
		return false;
	}
	char buf[300];
	if (count > fs.real_frames) {
		snprintf(buf, sizeof(buf), "%u frames is more than the %u frames "
			"%s has", count, fs.real_frames, fs.name);
		*err = buf;
		return false;
	}
	plan->labels.assign(1, far);
	plan->slots.assign(1, 0);
	uint32_t slot = 0, cur = far;
	for (uint32_t k = 1; k < count; k++) {
		bool crossed = false;
		if (!next_far(fs, cur, &cur, &crossed)) {
			snprintf(buf, sizeof(buf), "%u frames from FAR 0x%08x runs past "
				"the end of %s's frame space: only %u frames lie at or "
				"after it", count, far, fs.name, k);
			*err = buf;
			return false;
		}
		slot += 1 + (crossed ? fs.pads_per_group : 0);
		plan->labels.push_back(cur);
		plan->slots.push_back(slot);
	}
	plan->stream_frames = slot + 1;
	plan->pad_frames = plan->stream_frames - count;
	return true;
}

bool check_far_list(const FrameSpace &fs, const std::vector<uint32_t> &list,
	const ReadbackPlan &plan, std::string *err)
{
	char buf[400];
	if (list.size() > fs.real_frames) {
		snprintf(buf, sizeof(buf), "the frame list carries %zu addresses but "
			"%s has %u frames", list.size(), fs.name, fs.real_frames);
		*err = buf;
		return false;
	}
	for (uint32_t a : list) {
		std::string why;
		if (!far_in_space(fs, a, &why)) {
			*err = "the frame list is not this part's: " + why;
			return false;
		}
	}
	const uint32_t far = plan.labels.front();
	const auto it = std::lower_bound(list.begin(), list.end(), far);
	if (it == list.end() || *it != far) {
		snprintf(buf, sizeof(buf), "FAR 0x%08x does not appear in the %zu "
			"addresses of the supplied frame list", far, list.size());
		*err = buf;
		return false;
	}
	const size_t idx = static_cast<size_t>(it - list.begin());
	const size_t count = plan.labels.size();
	if (idx + count > list.size()) {
		snprintf(buf, sizeof(buf), "%zu frames from FAR 0x%08x runs past the "
			"end of the supplied frame list: that address is number %zu of "
			"%zu, leaving %zu", count, far, idx + 1, list.size(),
			list.size() - idx);
		*err = buf;
		return false;
	}
	for (size_t k = 0; k < count; k++) {
		if (list[idx + k] != plan.labels[k]) {
			snprintf(buf, sizeof(buf), "frame %zu of the read is 0x%08x in "
				"the supplied frame list and 0x%08x in %s's sweep order; "
				"the list skips or invents an address, so its labels "
				"would be wrong from there on", k, list[idx + k],
				plan.labels[k], fs.name);
			*err = buf;
			return false;
		}
	}
	return true;
}

}  // namespace xil7
