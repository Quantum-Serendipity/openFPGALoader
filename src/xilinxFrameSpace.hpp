// SPDX-License-Identifier: Apache-2.0

#ifndef SRC_XILINXFRAMESPACE_HPP_
#define SRC_XILINXFRAMESPACE_HPP_

#include <cstdint>
#include <istream>
#include <string>
#include <vector>

namespace xil7 {

enum { FS_BLOCKS = 2, FS_HALVES = 2, FS_ROWS = 2 };

struct FrameSpace {
	uint32_t idcode;
	const char *name;
	uint16_t words_per_frame;
	uint8_t blocks;
	uint8_t rows;
	uint16_t cols[FS_BLOCKS][FS_ROWS];
	const uint8_t *col_frames[FS_BLOCKS][FS_ROWS];
	uint16_t pads_per_group;
	uint32_t real_frames;
	uint32_t total_frames;
};

struct ReadbackPlan {
	std::vector<uint32_t> labels;
	std::vector<uint32_t> slots;
	uint32_t stream_frames;
	uint32_t pad_frames;
};

bool parse_u32(const std::string &tok, uint32_t *out);

bool read_far_list(std::istream &in, const std::string &name,
	std::vector<uint32_t> *out, std::string *err);

const FrameSpace *find_frame_space(uint32_t idcode);

bool check_frame_space(const FrameSpace &fs, std::string *err);

bool far_in_space(const FrameSpace &fs, uint32_t far, std::string *err);

bool next_far(const FrameSpace &fs, uint32_t far, uint32_t *next,
	bool *crossed);

bool plan_readback(const FrameSpace &fs, uint32_t far, uint32_t count,
	ReadbackPlan *plan, std::string *err);

bool check_far_list(const FrameSpace &fs, const std::vector<uint32_t> &list,
	const ReadbackPlan &plan, std::string *err);

}  // namespace xil7

#endif  // SRC_XILINXFRAMESPACE_HPP_
