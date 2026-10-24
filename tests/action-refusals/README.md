# action-refusals

Regression arms for the refusals around `--partial`, `--readback-frames`,
`--user-dr` and `--flash-info`, and for the labelling of a `--readback-frames`
dump. The `--user-dr` model arms assert from the IR log that the mode latches
only USER3 and BYPASS, parks in BYPASS, and refuses before USER3 when DONE is
low, when a second device sits on the chain (`--neighbour` on the TDO side,
`--neighbour-tdi` on the TDI side, the latter with a mis-declared IR length),
and when the IR capture does not read 01 (`--ir-capture`).
`--partial` and `--readback-frames` (with and without `--read-register`)
are held to the same single-device, no-padding and 01-capture refusals, and
assert from the IR log that no CFG_IN, CFG_OUT, JPROGRAM, JSTART or
JSHUTDOWN was latched.

    tests/action-refusals/run.sh <path to openFPGALoader>

Exit status 0 means every arm passed; each arm prints `PASS` or `FAIL`.

No arm can reach a cable:

- Parse-level arms pass `-c no_such_cable`. A refusal must fire before the
  cable lookup; an accepted control must reach the lookup and fail there
  (`error : no_such_cable not found`), which returns before any probe is opened.
- Model arms use `--cable xvc-client` against `xvc_tap_model.py`, a TAP model
  served on a loopback TCP port. It answers IDCODE, the IR capture (DONE, INIT)
  and a fixed STAT word on CFG_OUT. It also parses the CFG_IN packet stream,
  and after RCFG, a FAR write and an FDRO read it streams a dummy frame and then
  the XC7A100T's frames in sweep order, with all-zero pad frames between
  `(block, half, row)` groups. Each frame carries its own address, so a dump
  label can be checked against its content. `--pads` and `--pad-word` model a
  device whose pads differ; `--replay` serves recorded dumps instead.
  `--ir-log` writes every instruction latched at UPDATE-IR, so an arm can
  assert that `--partial` never issues JPROGRAM, JSTART or JSHUTDOWN while a
  full load does. `--user1-byte` answers USER1 with a fixed byte pattern, a
  stable responder that is not a flash. `--short-shift` answers one shift
  with half its bytes and half-closes the socket, as a proxy that dies
  mid-reply; the model keeps consuming commands and answers none of them,
  so only the first error a cut provokes is under test.
  `--cfg-out-shift-log` names the shifts that carried CFG_OUT bits, so an
  arm can pick the one to cut, and `--tlr-shift-log` names the shifts that
  left the TAP in Test-Logic-Reset.

`OFL_RECORDED_CROSSING_DIR=<dir>` adds two arms that replay a silicon
readback across a half and a row boundary. The directory must hold
`b0-{left,right,cross}.{dump,far}` and `b1-...` as written by the
xilinx7-dpr-foss-toolchain U31 crossing procedure; the arm passes when the
crossing read, relabelled, equals the two non-crossing reads joined.

`make_stream.py <variant> <out.bin|out.bit>` writes the synthetic configuration
streams the payload arms load: `good` is a one-frame partial, and every other
variant adds one thing a partial must not carry.

The frame-space functions, the FTDI MPSSE `writeTDI` and `writeTMS`
transport error paths and the short-write path of `mpsse_write` have unit
tests, built with `-DENABLE_UNIT_TESTS=ON` and run by `ctest`.
