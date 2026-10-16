#!/usr/bin/env bash
set -u

OFL=${1:?usage: run.sh <path to openFPGALoader>}
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
MODEL_PID=

cleanup() {
	if [[ -n $MODEL_PID ]]; then
		kill "$MODEL_PID" 2>/dev/null
		wait "$MODEL_PID" 2>/dev/null
	fi
	rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() {
	echo "FAIL $1: $2"
	sed 's/^/    | /' "$T/out" | head -6
	fail=$((fail + 1))
}

offline() {
	timeout 20 "$OFL" -c no_such_cable "$@" >"$T/out" 2>&1
	echo $? >"$T/rc"
}

refused() {
	local name=$1 pat=$2
	shift 2
	offline "$@"
	if grep -q 'no_such_cable not found' "$T/out"; then
		ko "$name" "passed every refusal and reached the cable lookup"
	elif ! grep -qF -- "$pat" "$T/out"; then
		ko "$name" "no '$pat' in the output"
	elif [[ $(cat "$T/rc") -eq 0 ]]; then
		ko "$name" "exit 0"
	else
		ok "$name"
	fi
}

accepted() {
	local name=$1
	shift
	offline "$@"
	if grep -q 'error : no_such_cable not found' "$T/out"; then
		ok "$name"
	else
		ko "$name" "refused before the cable lookup"
	fi
}

with_model() {
	local margs=()
	while [[ $1 != -- ]]; do
		margs+=("$1")
		shift
	done
	shift
	rm -f "$T/port"
	timeout 120 python3 "$HERE/xvc_tap_model.py" --port-file "$T/port" \
		--accept-timeout 30 "${margs[@]}" &
	MODEL_PID=$!
	for _ in $(seq 1 100); do
		[[ -s $T/port ]] && break
		sleep 0.1
	done
	timeout 60 "$OFL" --cable xvc-client --ip 127.0.0.1 \
		--port "$(cat "$T/port")" "$@" >"$T/out" 2>&1
	echo $? >"$T/rc"
	kill "$MODEL_PID" 2>/dev/null
	wait "$MODEL_PID" 2>/dev/null
	MODEL_PID=
}

model_rc() {
	local name=$1 want=$2 pat=$3
	shift 3
	with_model "$@"
	local rc
	rc=$(cat "$T/rc")
	if [[ $want == 0 && $rc -ne 0 ]]; then
		ko "$name" "exit $rc, expected 0"
	elif [[ $want != 0 && $rc -eq 0 ]]; then
		ko "$name" "exit 0, expected a failure"
	elif [[ -n $pat ]] && ! grep -qF -- "$pat" "$T/out"; then
		ko "$name" "no '$pat' in the output"
	else
		ok "$name"
	fi
}

for v in good start grestore shutdown iprog cor0 wbstar ctl0-bit12 nosync truncated; do
	python3 "$HERE/make_stream.py" "$v" "$T/$v.bin"
done
python3 "$HERE/make_stream.py" good "$T/good.bit"
python3 "$HERE/make_stream.py" start "$T/start.bit"
cp "$T/good.bin" "$T/good.mcs"
printf '0x00000000\n0x00000001\n' >"$T/far.txt"

has_xvc_server=0
"$OFL" --help 2>/dev/null | grep -q -- '--xvc ' && has_xvc_server=1

RB=(--readback-frames 0x0:1 --readback-out "$T/d.txt")
FI=(--flash-info --skip-load-bridge --skip-reset --fpga-part xc7a100tfgg484)

accepted readback_alone "${RB[@]}"
accepted readback_as_h15_runs_it --read-register CTRL0 --freq 6000000 \
	--readback-frames 0x0:2 --readback-out "$T/d.txt" --readback-far-list "$T/far.txt"
accepted readback_with_selector --busdev-num 001:002 "${RB[@]}"
accepted partial_as_the_guard_runs_it --busdev-num 001:002 --partial -m "$T/good.bit" --freq 6000000
accepted partial_bin -m --partial "$T/good.bin"
accepted flash_info_with_both_skips "${FI[@]}"

refused readback_positional_bit '--readback-frames cannot be combined with' "${RB[@]}" "$T/good.bit"
refused readback_positional_mcs '--readback-frames cannot be combined with' "${RB[@]}" "$T/good.mcs"
for o in bulk-erase enable-quad disable-quad unprotect-flash spi detect dfu \
		read-dna reset write-sram write-flash dump-flash external-flash; do
	refused "readback_with_$o" "--readback-frames cannot be combined with --$o" "${RB[@]}" "--$o"
done
refused readback_with_protect_flash '--readback-frames cannot be combined with --protect-flash' \
	"${RB[@]}" --protect-flash 4096
refused readback_with_file_size '--readback-frames cannot be combined with --file-size' \
	"${RB[@]}" --file-size 4
refused readback_on_dfu_board '--readback-frames cannot be used with board' \
	-b orangeCrab "${RB[@]}"

for o in detect passive-serial bulk-erase enable-quad spi reset read-dna; do
	refused "partial_with_$o" "--partial cannot be combined with --$o" -m --partial "$T/good.bit" "--$o"
done
refused partial_with_read_register '--partial cannot be combined with --read-register' \
	-m --partial "$T/good.bit" --read-register STAT
refused partial_without_write_sram '--partial requires -m/--write-sram' --partial "$T/good.bit"
refused partial_with_readback '--partial cannot be combined with --readback-frames' \
	-m --partial "$T/good.bit" "${RB[@]}"
refused partial_on_non_7series_board 'not a Xilinx 7-series part' \
	-b alinx_ax516 -m --partial "$T/good.bit"
refused partial_on_spi_board '--partial cannot be used with board' \
	-b ice40_generic -m --partial "$T/good.bit"

if [[ $has_xvc_server -eq 1 ]]; then
	refused readback_with_xvc '--readback-frames cannot be combined with --xvc' "${RB[@]}" --xvc
	refused partial_with_xvc '--partial cannot be combined with --xvc' -m --partial "$T/good.bit" --xvc
	refused flash_info_with_xvc 'cannot be combined with --xvc' "${FI[@]}" --xvc
fi

for o in reset write-sram dump-flash write-flash; do
	refused "flash_info_with_$o" "cannot be combined with --$o" "${FI[@]}" "--$o"
done
refused flash_info_with_readback '--readback-frames cannot be combined with --flash-info' \
	"${FI[@]}" "${RB[@]}"
refused flash_info_without_skip_reset '--skip-reset' \
	--flash-info --skip-load-bridge --fpga-part xc7a100tfgg484
refused flash_info_refusal_names_skip_reset '--skip-load-bridge --skip-reset' \
	--flash-info --fpga-part xc7a100tfgg484

for v in start grestore shutdown iprog cor0 wbstar ctl0-bit12 nosync truncated; do
	refused "partial_payload_$v" '--partial refused' -m --partial "$T/$v.bin"
done
refused partial_payload_start_in_bit '--partial refused' -m --partial "$T/start.bit"

echo '{"stale": true}' >"$T/info.json"
offline --flash-info-json "$T/info.json" --fpga-part xc7a100tfgg484
if [[ -e $T/info.json ]]; then
	ko flash_info_json_stale_file_removed_on_refusal "the previous file survived a refused run"
else
	ok flash_info_json_stale_file_removed_on_refusal
fi

model_rc partial_clean_stat 0 'Done' -- -m --partial "$T/good.bit"
model_rc partial_crc_error_stat 1 'CRC_ERROR' --stat 0x401079FD -- -m --partial "$T/good.bit"
model_rc partial_id_error_stat 1 'ID_ERROR' --stat 0x4010F9FC -- -m --partial "$T/good.bit"
model_rc partial_done_low_stat 1 'DONE' --stat 0x401039FC -- -m --partial "$T/good.bit"
model_rc partial_spartan6_idcode 1 'not a Xilinx 7-series part' --idcode 0x04001093 -- \
	-m --partial "$T/good.bit"
model_rc readback_to_file 0 'written to' -- "${RB[@]}"
if grep -q '^\.frame 0x00000000' "$T/d.txt" 2>/dev/null; then
	ok readback_to_file_has_frame
else
	ko readback_to_file_has_frame "no .frame line in the dump"
fi
if [[ -w /dev/full ]]; then
	model_rc readback_to_full_device 1 '' -- --readback-frames 0x0:1 --readback-out /dev/full
fi

echo "action-refusals: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
