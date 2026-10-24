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
	(
		if [[ -n ${FSIZE_BLOCKS:-} ]]; then
			trap '' XFSZ
			ulimit -f "$FSIZE_BLOCKS"
		fi
		exec timeout 60 "$OFL" --cable xvc-client --ip 127.0.0.1 \
			--port "$(cat "$T/port")" "$@"
	) >"$T/out" 2>&1
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

PAYLOAD_REFUSED=(
	"start:issues CMD START"
	"grestore:issues CMD GRESTORE"
	"shutdown:issues CMD SHUTDOWN"
	"iprog:issues CMD IPROG"
	"cor0:writes register COR0"
	"wbstar:writes register WBSTAR"
	"ctl0-bit12:which covers bit 12"
	"nosync:has no sync word"
	"truncated:ends inside a packet"
	"nocrc:has no CRC write after its last FDRI"
	"crc-before-fdri:has no CRC write after its last FDRI"
	"stop-after-fdri:has no CRC write after its last FDRI"
	"crc-empty:writes CRC with other than a single-word"
	"crc-two:writes CRC with other than a single-word"
	"crc-type2:writes CRC with other than a single-word"
	"no-desync:does not end with a DESYNC"
	"desync-wcfg:issues a command after DESYNC"
	"desync-15-noops:NOOPs after its DESYNC"
	"desync-no-noops:NOOPs after its DESYNC"
	"odd-length:is not a whole number of 32-bit words"
	"axss-two:writes AXSS with other than a single-word"
	"axss-type2:writes AXSS with other than a single-word"
	"t2-after-noop:has a malformed packet header"
)
for v in good axss "${PAYLOAD_REFUSED[@]%%:*}" unaligned-sync unaligned-resync two-syncs; do
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

for vp in "${PAYLOAD_REFUSED[@]}"; do
	v=${vp%%:*}
	refused "partial_payload_$v" "${vp#*:}" -m --partial "$T/$v.bin"
done
accepted partial_payload_axss_stamp -m --partial "$T/axss.bin"
refused partial_payload_start_in_bit '--partial refused' -m --partial "$T/start.bit"
for v in unaligned-sync unaligned-resync; do
	refused "partial_payload_$v" 'not on a 32-bit word boundary' -m --partial "$T/$v.bin"
done
accepted partial_payload_two_syncs -m --partial "$T/two-syncs.bin"

echo '{"stale": true}' >"$T/info.json"
offline --flash-info-json "$T/info.json" --fpga-part xc7a100tfgg484
if [[ -e $T/info.json ]]; then
	ko flash_info_json_stale_file_removed_on_refusal "the previous file survived a refused run"
else
	ok flash_info_json_stale_file_removed_on_refusal
fi

ir_log() {
	local name=$1 log=$2 want=$3
	shift 3
	if [[ $want == none-or-empty && -e $log ]]; then
		want=none
	elif [[ ! -s $log ]]; then
		ko "$name" "the model wrote no IR log"
		return
	fi
	local ir hit=0
	for ir in "$@"; do
		grep -qx "$ir" "$log" && hit=$((hit + 1))
	done
	if [[ $want == none && $hit -ne 0 ]]; then
		ko "$name" "the IR log holds one of $*"
	elif [[ $want == all && $hit -ne $# ]]; then
		ko "$name" "the IR log lacks one of $*"
	else
		ok "$name"
	fi
}

JPROG_JSTART_JSHUT=(0x0b 0x0c 0x0d)
for a in clean:0:Done:0x401079FC crc_error:1:CRC_ERROR:0x401079FD \
		id_error:1:ID_ERROR:0x4010F9FC done_low:1:DONE:0x401039FC; do
	IFS=: read -r an aw ap as <<<"$a"
	rm -f "$T/ir"
	model_rc "partial_${an}_stat" "$aw" "$ap" --stat "$as" --ir-log "$T/ir" -- \
		-m --partial "$T/good.bit"
	ir_log "partial_${an}_stat_issues_no_jprogram_jstart_jshutdown" "$T/ir" none \
		"${JPROG_JSTART_JSHUT[@]}"
done
rm -f "$T/ir"
model_rc full_load_control 0 '' --ir-log "$T/ir" -- -m "$T/good.bit"
ir_log full_load_control_issues_jprogram_and_jstart "$T/ir" all 0x0b 0x0c

short_cfg_out_reply() {
	local name=$1 out=$2
	shift 2
	rm -f "$T/shifts" "$out"
	with_model --cfg-out-shift-log "$T/shifts" -- "$@"
	local k
	k=$(tail -1 "$T/shifts" 2>/dev/null)
	if [[ $(cat "$T/rc") -ne 0 ]]; then
		ko "$name" "the unperturbed control exited $(cat "$T/rc")"
		return
	elif [[ -z $k ]]; then
		ko "$name" "no shift carried CFG_OUT bits"
		return
	fi
	rm -f "$out"
	model_rc "$name" 1 '' --short-shift "$k" -- "$@"
	if [[ -n $out && -e $out ]]; then
		ko "${name}_leaves_no_dump" "a dump was written"
	elif [[ -n $out ]]; then
		ok "${name}_leaves_no_dump"
	fi
}

short_cfg_out_reply readback_short_cfg_out_reply "$T/sr.txt" \
	--readback-frames 0x0:1 --readback-out "$T/sr.txt"
short_cfg_out_reply partial_short_stat_reply '' -m --partial "$T/good.bit"

rm -f "$T/tlr"
with_model --tlr-shift-log "$T/tlr" -- --detect
k=$(head -1 "$T/tlr" 2>/dev/null)
if [[ $(cat "$T/rc") -ne 0 || -z $k ]]; then
	ko detect_short_tlr_flush_reply "the unperturbed control exited $(cat "$T/rc") or no shift ended in TLR"
else
	model_rc detect_short_tlr_flush_reply 1 'JTAG TMS flush failed' --short-shift "$k" -- --detect
fi

rm -f "$T/shifts"
with_model --cfg-out-shift-log "$T/shifts" -- --read-register STAT
k=$(tail -1 "$T/shifts" 2>/dev/null)
if [[ $(cat "$T/rc") -ne 0 || -z $k ]]; then
	ko read_register_short_reply_exits_through_main "the unperturbed control exited $(cat "$T/rc") or no shift carried CFG_OUT bits"
else
	with_model --short-shift "$k" -- --read-register STAT
	if [[ $(cat "$T/rc") -ne 1 ]]; then
		ko read_register_short_reply_exits_through_main "exit $(cat "$T/rc"), expected 1"
	elif grep -q 'terminate called' "$T/out"; then
		ko read_register_short_reply_exits_through_main "an uncaught exception reached std::terminate"
	elif ! grep -qF 'Error: ' "$T/out"; then
		ko read_register_short_reply_exits_through_main "no 'Error: ' in the output"
	else
		ok read_register_short_reply_exits_through_main
	fi
fi

rm -f "$T/fi.json"
model_rc flash_info_non_flash_responder_refused 1 '' --user1-byte 0x02 -- \
	--flash-info-json "$T/fi.json" --skip-load-bridge --skip-reset
if [[ -e $T/fi.json ]]; then
	ko flash_info_non_flash_responder_writes_no_record "a JSON record was written"
else
	ok flash_info_non_flash_responder_writes_no_record
fi
model_rc flash_info_echo_responder_reads_a_zero_id 1 'Read ID failed' -- \
	--flash-info --skip-load-bridge --skip-reset
model_rc partial_spartan6_idcode 1 'not a Xilinx 7-series part' --idcode 0x04001093 -- \
	-m --partial "$T/good.bit"
model_rc flash_info_xilinx_found_on_chain 1 'pass --skip-load-bridge --skip-reset' -- \
	--flash-info --skip-load-bridge
model_rc readback_to_file 0 'written to' -- "${RB[@]}"
if grep -q '^\.frame 0x00000000' "$T/d.txt" 2>/dev/null; then
	ok readback_to_file_has_frame
else
	ko readback_to_file_has_frame "no .frame line in the dump"
fi
FSIZE_BLOCKS=1 model_rc readback_over_file_size_limit 1 '' -- \
	--readback-frames 0x0:2 --readback-out "$T/big.txt" --readback-far-list "$T/far.txt"
if [[ -e $T/big.txt ]]; then
	ko readback_over_file_size_limit_leaves_no_dump "a truncated dump was left at the path"
else
	ok readback_over_file_size_limit_leaves_no_dump
fi
if [[ -w /dev/full ]]; then
	model_rc readback_to_full_device 1 '' -- --readback-frames 0x0:1 --readback-out /dev/full
fi

labelled() {
	local name=$1 far=$2 count=$3
	shift 3
	if ! python3 "$HERE/xvc_tap_model.py" --write-far-list "$T/w.far" --far "$far" \
			--count "$count" >"$T/out" 2>&1; then
		ko "$name" "the model has no such window"
		return
	fi
	rm -f "$T/w.txt"
	with_model "$@" -- --readback-frames "$far:$count" --readback-out "$T/w.txt" \
		--readback-far-list "$T/w.far"
	if [[ $(cat "$T/rc") -ne 0 ]]; then
		ko "$name" "exit $(cat "$T/rc")"
	elif ! python3 "$HERE/xvc_tap_model.py" --check-dump "$T/w.txt" --far "$far" \
			--count "$count" >"$T/out" 2>&1; then
		ko "$name" "the dump's labels or content disagree with the sweep"
	else
		ok "$name"
	fi
}

refused_with_model() {
	local name=$1 pat=$2 far=$3 count=$4
	shift 4
	if ! python3 "$HERE/xvc_tap_model.py" --write-far-list "$T/w.far" --far "$far" \
			--count "$count" >"$T/out" 2>&1; then
		ko "$name" "the model has no such window"
		return
	fi
	rm -f "$T/w.txt"
	model_rc "$name" 1 "$pat" "$@" -- --readback-frames "$far:$count" \
		--readback-out "$T/w.txt" --readback-far-list "$T/w.far"
	if [[ -e $T/w.txt ]]; then
		ko "${name}_leaves_no_dump" "a dump was written"
	else
		ok "${name}_leaves_no_dump"
	fi
}

labelled readback_labels_inside_one_group 0x00000F00 100
labelled readback_labels_across_a_half 0x00021990 48
labelled readback_labels_across_a_row 0x00401C18 80
labelled readback_labels_across_a_block_type 0x00421990 20
labelled readback_labels_across_two_groups 0x00820170 538
labelled readback_labels_last_frame_of_device 0x00C2017F 1
refused_with_model readback_nonzero_pad_refused 'pad' 0x00021990 48 --pad-word 0x1
refused_with_model readback_device_without_pads_refused 'pad' 0x00021990 48 --pads 0
model_rc readback_minor_past_its_column_refused 1 'minor' -- \
	--readback-frames 0x0000009E:1 --readback-out "$T/m.txt"
model_rc readback_column_last_minor_accepted 0 'written to' -- \
	--readback-frames 0x0000009D:1 --readback-out "$T/m.txt"
printf '0x00000000\n0x00000001\n0x00000003\n' >"$T/gap.far"
model_rc readback_far_list_with_a_gap_refused 1 'sweep' -- \
	--readback-frames 0x0:3 --readback-out "$T/m.txt" --readback-far-list "$T/gap.far"

if [[ -n ${OFL_RECORDED_CROSSING_DIR:-} ]]; then
	for b in b0:0x00021990:48 b1:0x00401C18:80; do
		IFS=: read -r bn far count <<<"$b"
		R=$OFL_RECORDED_CROSSING_DIR
		python3 - "$R/$bn-right.dump" "$T/$bn-tail.dump" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('.frame ')[1:]
open(sys.argv[2], 'w').write(''.join('.frame ' + x for x in lines[-2:]))
PY
		rm -f "$T/r.txt"
		with_model --replay "$R/$bn-cross.dump" "$T/$bn-tail.dump" -- \
			--readback-frames "$far:$count" --readback-out "$T/r.txt" \
			--readback-far-list "$R/$bn-cross.far"
		if [[ $(cat "$T/rc") -ne 0 ]]; then
			ko "readback_recorded_${bn}_crossing" "exit $(cat "$T/rc")"
		elif ! python3 "$HERE/xvc_tap_model.py" --compare-dump "$T/r.txt" \
				--expect "$R/$bn-left.dump" "$R/$bn-right.dump" >"$T/out" 2>&1; then
			ko "readback_recorded_${bn}_crossing" "the dump is not left + right"
		else
			ok "readback_recorded_${bn}_crossing"
		fi
	done
fi

printf '0x100000000\n0x00000001\n' >"$T/wide.far"
printf -- '-1\n0x00000001\n' >"$T/neg.far"
printf '0x00000000\n0x00000000\n' >"$T/dup.far"
printf '0x00000001\n0x00000000\n' >"$T/desc.far"
printf '010\n011\n' >"$T/oct.far"
printf '# header\n\n  0x00000000\r\n0x00000001 \n# tail\n' >"$T/commented.far"
for v in wide neg oct; do
	refused "readback_far_list_$v" 'is not a frame address' \
		--readback-frames 0x0:2 --readback-out "$T/d.txt" --readback-far-list "$T/$v.far"
done
for v in dup desc; do
	refused "readback_far_list_$v" 'ascending' \
		--readback-frames 0x0:2 --readback-out "$T/d.txt" --readback-far-list "$T/$v.far"
done
accepted readback_far_list_commented --readback-frames 0x0:2 --readback-out "$T/d.txt" \
	--readback-far-list "$T/commented.far"
refused readback_spec_negative_far 'is not a frame address' \
	--readback-frames=-0x0:1 --readback-out "$T/d.txt"
refused readback_spec_octal_count 'is not a frame count' \
	--readback-frames 0x0:010 --readback-out "$T/d.txt"

head -c 32 /dev/urandom >"$T/ud0.bin"
head -c 160 /dev/urandom >"$T/ud1.bin"
: >"$T/ud-empty.bin"
UD=(--user-dr "3:$T/ud0.bin:$T/ud0.tdo,3:$T/ud1.bin:$T/ud1.tdo")
accepted user_dr_alone "${UD[@]}"
accepted user_dr_with_selector --busdev-num 001:002 --freq 6000000 "${UD[@]}"
refused user_dr_positional_bit '--user-dr cannot be combined with' "${UD[@]}" "$T/good.bit"
for o in bulk-erase reset write-sram write-flash dump-flash detect read-dna spi external-flash; do
	refused "user_dr_with_$o" "--user-dr cannot be combined with --$o" "${UD[@]}" "--$o"
done
refused user_dr_with_partial '--partial cannot be combined with --user-dr' \
	"${UD[@]}" -m --partial "$T/good.bit"
refused user_dr_with_readback '--readback-frames cannot be combined with --user-dr' \
	"${UD[@]}" "${RB[@]}"
refused user_dr_with_read_register '--user-dr cannot be combined with --read-register' \
	"${UD[@]}" --read-register STAT
refused user_dr_chain_zero 'is not one of 1, 2, 3, 4' --user-dr "0:$T/ud0.bin:$T/x.tdo"
refused user_dr_chain_five 'is not one of 1, 2, 3, 4' --user-dr "5:$T/ud0.bin:$T/x.tdo"
refused user_dr_two_fields 'expected <chain>:<tdi.bin>:<tdo.bin>' --user-dr "3:$T/ud0.bin"
refused user_dr_four_fields 'expected <chain>:<tdi.bin>:<tdo.bin>' --user-dr "3:$T/ud0.bin:$T/a:$T/b"
refused user_dr_same_file 'reads and writes the same file' --user-dr "3:$T/ud0.bin:$T/ud0.bin"
refused user_dr_shared_tdo 'shares a TDO file' --user-dr "3:$T/ud0.bin:$T/x.tdo,3:$T/ud1.bin:$T/x.tdo"
refused user_dr_missing_tdi 'cannot open' --user-dr "3:$T/no-such.bin:$T/x.tdo"
refused user_dr_empty_tdi 'is empty or larger' --user-dr "3:$T/ud-empty.bin:$T/x.tdo"
if [[ $has_xvc_server -eq 1 ]]; then
	refused user_dr_with_xvc '--user-dr cannot be combined with --xvc' "${UD[@]}" --xvc
fi
rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_model 0 'IR parked in BYPASS' --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_model_issues_user3 "$T/ir" all 0x22 0x3f
ir_log user_dr_model_issues_no_configuration_instruction "$T/ir" none \
	0x02 0x03 0x04 0x05 0x0b 0x0c 0x0d 0x10 0x11 0x16 0x23 0x30 0x31 0x32 0x33 0x34 0x35
if [[ -s $T/ir ]] && [[ -z $(grep -vx -e 0x22 -e 0x3f "$T/ir") ]]; then
	ok user_dr_model_ir_log_is_only_user3_and_bypass
else
	ko user_dr_model_ir_log_is_only_user3_and_bypass "IR log: $(tr '\n' ' ' <"$T/ir" 2>/dev/null)"
fi
if [[ $(tail -1 "$T/ir" 2>/dev/null) == 0x3f ]]; then
	ok user_dr_model_parks_in_bypass
else
	ko user_dr_model_parks_in_bypass "last IR $(tail -1 "$T/ir" 2>/dev/null)"
fi
if python3 - "$T/ud1.bin" "$T/ud1.tdo" <<'PY'
import sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
n = 8 * len(a)
ia = int.from_bytes(a, 'little')
ib = int.from_bytes(b, 'little')
sys.exit(0 if len(b) == len(a) and ib == ((ia << 1) & ((1 << n) - 1)) else 1)
PY
then
	ok user_dr_model_tdo_file_is_the_one_bit_register_echo
else
	ko user_dr_model_tdo_file_is_the_one_bit_register_echo "TDO file is not TDI delayed one bit"
fi
rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_done_low_refused 1 'DONE is low' --done-low --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_done_low_issues_no_user3 "$T/ir" none 0x22

refused user_dr_with_misc_device '--user-dr cannot be combined with --misc-device' \
	"${UD[@]}" --misc-device 0x4ba00477,4,dap
refused user_dr_with_index_chain '--user-dr cannot be combined with --index-chain' \
	"${UD[@]}" --index-chain 0
UD_CFG=(0x02 0x03 0x04 0x05 0x0b 0x0c 0x0d 0x10 0x11 0x16 0x22 0x23 0x30 0x31 0x32 0x33 0x34 0x35)
rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_two_device_chain_refused 1 'requires exactly one device' \
	--neighbour 0x4ba00477:4 --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_two_device_chain_latches_no_user_or_configuration_ir "$T/ir" none-or-empty "${UD_CFG[@]}"
rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_misdeclared_neighbour_irlength_refused 1 'requires exactly one device' \
	--neighbour-tdi 0x4ba00477:5 --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_misdeclared_neighbour_latches_no_user_or_configuration_ir "$T/ir" none-or-empty "${UD_CFG[@]}"
if [[ ! -e $T/ud0.tdo && ! -e $T/ud1.tdo ]]; then
	ok user_dr_misdeclared_neighbour_writes_no_tdo_file
else
	ko user_dr_misdeclared_neighbour_writes_no_tdo_file "a TDO file exists after the refusal"
fi
rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_ir_capture_not_01_refused 1 'are not 01' \
	--ir-capture 0x33 --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_ir_capture_not_01_issues_no_user3 "$T/ir" none 0x22

rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
model_rc user_dr_user_ir_capture_not_01_refused 1 'does not read 01' \
	--ir-capture-in-bypass 0x00 --ir-log "$T/ir" -- "${UD[@]}"
if [[ $(tail -1 "$T/ir" 2>/dev/null) == 0x3f ]]; then
	ok user_dr_user_ir_capture_not_01_parks_in_bypass
else
	ko user_dr_user_ir_capture_not_01_parks_in_bypass "last IR $(tail -1 "$T/ir" 2>/dev/null)"
fi
if [[ ! -e $T/ud0.tdo && ! -e $T/ud1.tdo ]]; then
	ok user_dr_user_ir_capture_not_01_writes_no_tdo_file
else
	ko user_dr_user_ir_capture_not_01_writes_no_tdo_file "a TDO file exists after the refusal"
fi

refused user_dr_newline_in_path 'control character' --user-dr "3:$T/ud0.bin:$T/x"$'\n'"y.tdo"
refused user_dr_tab_in_path 'control character' --user-dr "3:$T/ud0.bin:$T/x"$'\t'"y.tdo"

rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo"
printf keep >"$T/ud0.tdo"
model_rc user_dr_existing_tdo_refused 1 'already exists' --ir-log "$T/ir" -- "${UD[@]}"
ir_log user_dr_existing_tdo_issues_no_user3 "$T/ir" none-or-empty 0x22
if [[ $(cat "$T/ud0.tdo") == keep && ! -e $T/ud1.tdo ]]; then
	ok user_dr_existing_tdo_left_untouched
else
	ko user_dr_existing_tdo_left_untouched "the existing TDO file was rewritten"
fi

rm -f "$T/ir" "$T/ud0.tdo" "$T/ud1.tdo" "$T/victim"
printf keep >"$T/victim"
ln -s "$T/victim" "$T/ud0.tdo.tmp"
model_rc user_dr_tmp_symlink_scan 0 'IR parked in BYPASS' -- "${UD[@]}"
if [[ $(cat "$T/victim") == keep ]]; then
	ok user_dr_tdo_write_follows_no_tmp_symlink
else
	ko user_dr_tdo_write_follows_no_tmp_symlink "a symbolic link beside the TDO path was written through"
fi
if [[ -f $T/ud0.tdo && ! -L $T/ud0.tdo ]]; then
	ok user_dr_tdo_is_a_regular_file
else
	ko user_dr_tdo_is_a_regular_file "the TDO path is not a regular file after the scan"
fi
rm -f "$T/ud0.tdo.tmp" "$T/victim" "$T/ud0.tdo" "$T/ud1.tdo"

synced_after() {
	local name=$1 want=$2
	shift 2
	rm -f "$T/synced" "$T/d.txt"
	with_model --synced-log "$T/synced" "$@"
	local got
	got=$(cat "$T/synced" 2>/dev/null)
	if [[ -z $got ]]; then
		ko "$name" "the model wrote no synced log"
	elif [[ $got != "$want" ]]; then
		ko "$name" "configuration engine synced=$got after the run, want $want"
	else
		ok "$name"
	fi
}
synced_after partial_clean_stat_leaves_engine_desynced 0 -- -m --partial "$T/good.bit"
if grep -qF 'released with DESYNC' "$T/out"; then
	ok partial_clean_stat_reports_the_desync
else
	ko partial_clean_stat_reports_the_desync "no 'released with DESYNC' in the output"
fi
synced_after partial_crc_error_stat_withholds_desync_and_leaves_engine_synced 1 \
	--stat 0x401079FD -- -m --partial "$T/good.bit"
if grep -qF 'released with DESYNC' "$T/out" || ! grep -qF 'DESYNC withheld' "$T/out"; then
	ko partial_crc_error_stat_reports_desync_withheld "a DESYNC was reported, or no 'DESYNC withheld' line"
else
	ok partial_crc_error_stat_reports_desync_withheld
fi
synced_after partial_id_error_stat_still_releases_engine 0 \
	--stat 0x4010F9FC -- -m --partial "$T/good.bit"
if [[ $(cat "$T/rc") -ne 0 ]]; then
	ok partial_id_error_stat_still_fails_the_load
else
	ko partial_id_error_stat_still_fails_the_load "exit 0"
fi
synced_after readback_leaves_engine_desynced 0 -- "${RB[@]}"
synced_after readback_beside_read_register_leaves_engine_desynced 0 -- \
	--read-register CTRL0 "${RB[@]}"
synced_after read_register_stat_leaves_engine_desynced 0 -- --read-register STAT
if [[ $(grep -c 'Register raw value' "$T/out") -eq 1 ]]; then
	ok read_register_stat_prints_one_raw_value_line
else
	ko read_register_stat_prints_one_raw_value_line "want exactly one 'Register raw value' line"
fi
synced_after read_register_ctrl0_leaves_engine_desynced 0 -- --read-register CTRL0
synced_after read_register_crc_error_stat_withholds_desync 1 --stat 0x401079FD -- \
	--read-register STAT

echo "action-refusals: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
