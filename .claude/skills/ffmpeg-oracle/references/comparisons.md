# Reference comparisons

Run from the repository root. The reference pin is
`5d5a38a7e46be296eab75982c0986054f731e19e` in
[port.md](../../../../port.md#inspected-baseline). Inspect the installed
build as well as the source revision: enabled components, compiler, C
library and assembly selection can change its results.

## Select an observable boundary

| Operation | Compare | Preserve |
| --- | --- | --- |
| Integer/lossless decoding | Canonical decoded samples or active pixel planes exactly | Format, dimensions/layout, sample/frame count and timing |
| A path with an existing bit-exact float contract | Exact output required by that contract | Operation order, precision and alignment |
| A path whose contract permits float error | The declared metric, threshold and sample/frame alignment | Exceptional values and the rules for handling them |
| Demuxing or stream copy | Packet payloads, codec configuration, stream parameters, side data and timestamps | Stream identity and declared packet-boundary rules |
| Muxing | FFmpeg's interpretation of the actual generated file | Payloads, timing, metadata and configuration; file bytes only where promised |
| Lossy encoding | Successful reference decoding, duration, bitrate and the contract's quality metric | Encoder options and declared alignment/delay |
| Rejection | The exact error, process status and relevant side effects | Error precedence, output creation and failure cleanup |

Do not infer a tolerance merely because a value is a float. Several existing
decoders and transforms promise bit-exact results. Do not force equal
container bytes where the contract promises equal media and timestamps.

## Establish independent expectations

1. Find the task's upstream implementation, headers, Makefile/configure
   dependencies and relevant `tests/fate/*.mak` entries. FATE is a coverage
   map; many commands require components or samples outside this port.
2. Use a reference generator under `zig/testing/reference/` for library
   behavior and command-line runs for program behavior. Calling a primitive
   does not reproduce the demuxer's read-ahead or the program's conversion
   policy. `mov_vectors.c` opens, finds stream information, and reads packets;
   its `-pipe` mode exercises a nonseekable source separately.
3. Generate expected data without calling the Zig implementation under test.
   Use hand-checked tiny inputs to catch a mistaken interpretation shared by
   a generator and the port. Record generation commands, fixture hashes and
   provenance as the task requires.
4. Add required fixtures through `zig/testing/fixtures/generate.py` and its
   format-specific generators; preserve the fixture contract's expected
   errors and precedence. Check the existing README before regenerating
   reference-made inputs. Never replace expected output just because a new
   implementation disagrees with it.
5. Check an encoder or muxer by feeding its actual Zig output to FFmpeg.
   Include partial writes, truncation and finalization where the operation
   has those failure modes.

The reproducible build, generator-specific link arguments and full comparison
command live in
[the reference README](../../../../zig/testing/reference/README.md#reproduce)
and [CI](../../../../.github/workflows/ci.yml). Use those commands; generators
need different static libraries, private headers and fixture arguments.
`build-ffmpeg.sh` records the commit, compiler, configure arguments and
`config.log` under the installation's `share/zffmpeg-reference/` directory.
Match the build identity before reusing cached results. Record binary and
fixture hashes with task evidence as TODO.md requires.

For an expression whose C behavior depends on compilation, use the flags
that produced the library under test, not just the convenient `-O1` flags
used by an unrelated generator. See
[ffmpeg-c-semantics](../../ffmpeg-c-semantics/SKILL.md).

The C-only build is the correctness oracle. The separate assembly-enabled
build used by `zig-io` measures performance; do not silently substitute its
numeric results for the declared oracle. Rebuilding the reference can fetch
sources and replace its build directory: inspect the script and the local
build before deciding a rebuild is needed.

## Make the comparator reject broken runs

`compare.py` already provides `refusal_name`, `tool_error`,
`same_decode_refusal`, and `check_oracle_predicates`. Extend a helper's
fault-injection checks when changing the acceptance predicate it implements.

At minimum, a successful-output comparator must reject:

- Two failed commands with identical empty stdout.
- One failed command paired with a successful command.
- Successful commands that produced the wrong kind of artifact.
- Altered payload, stream configuration or timing that the contract covers.

Artifact validation must allow contractually valid empty media; a nonempty
check alone is not a general format validator. Select checks appropriate to
the operation, such as a recognizable header and expected decoded count.

A refusal predicate must reject a crash, usage failure, wrong error name,
wrong path where the path is specified, and the right name with the wrong
exit status. A failed reference command caused by a disabled decoder or a
missing file is a setup failure unless a particular comparison explicitly
tests and classifies it. Follow the existing per-operation helper.

To run the existing predicate checks without the full media matrix:

```bash
python3 - <<'PY'
import runpy
checks = runpy.run_path('zig/testing/reference/compare.py', run_name='predicate_check')
checks['check_oracle_predicates']()
PY
```

This checks those predicates only. It is not a reference comparison run.

## Interpret a mismatch

Locate the first differing boundary: probe/stream parameters, packet payload
and timestamps, decoded samples, converted samples, encoded packets, then
muxed interpretation. Reduce the input and options at that boundary before
changing the decoder or adding a `KNOWN_*` entry. Preserve negative and
missing timestamps during normalization.

For an intentional difference, state exactly which field or error differs,
assert everything that must still agree, and record the row in
[notes.md](../../../../notes.md). A table keyed only by fixture name cannot
distinguish the documented difference from a new crash.

Report missing required fixtures as failures. Optional FATE/RFC samples may
be skipped with reasons and counts. Unimplemented checks remain explicitly
unimplemented; they do not increase the pass or skip count.
