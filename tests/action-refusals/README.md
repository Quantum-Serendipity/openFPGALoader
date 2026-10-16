# action-refusals

Regression arms for the refusals around `--partial`, `--readback-frames` and
`--flash-info`.

    tests/action-refusals/run.sh <path to openFPGALoader>

Exit status 0 means every arm passed; each arm prints `PASS` or `FAIL`.

No arm can reach a cable:

- Parse-level arms pass `-c no_such_cable`. A refusal must fire before the
  cable lookup; an accepted control must reach the lookup and fail there
  (`error : no_such_cable not found`), which returns before any probe is opened.
- Model arms use `--cable xvc-client` against `xvc_tap_model.py`, a TAP model
  served on a loopback TCP port. It answers IDCODE, the IR capture (DONE, INIT)
  and a fixed STAT word on CFG_OUT, and accepts any CFG_IN data.

`make_stream.py <variant> <out.bin|out.bit>` writes the synthetic configuration
streams the payload arms load: `good` is a one-frame partial, and every other
variant adds one thing a partial must not carry.
