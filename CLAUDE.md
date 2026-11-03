# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` only imports this file (`@CLAUDE.md`); keep agent guidance here.

## Project intent and current state

This standalone repository is becoming a native Zig implementation of FFmpeg's
multimedia functionality. Implement algorithms and APIs in Zig; compiling FFmpeg's C with
`zig cc`, translating headers, or wrapping libav* does not constitute the port.

Current state: the minimal Zig package and build (the `av` module rooted at
`zig/root.zig`, which exports nothing yet), the WAV fixture contract with 52
fixtures, two tested standalone examples (I/O patterns and a PCM s16 kernel) and
a Linux CI workflow; no codec/container implementation yet. The next tasks are
T03 (the reference build), T04 (PCM kernels) and T05 (audio/time types). When the state changes, update the current-state
statements in README.md, port.md ("Status and scope"), the TODO.md introduction
and this file together.

## Commands

Toolchain: Zig **0.17.0** exactly. `build.zig` stops with a compile error on any
other compiler, and CI checks `zig version` too. No C compiler or reference
clone is needed. Run from the repository root, because `std.testing.tmpDir`
creates `.zig-cache/tmp/` in the current directory.

```bash
zig build                                    # compile the av library (Debug)
zig build test                               # av module tests + every example's tests
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast        # safety off; required for parser/size code
zig build test -Dtest-filter="truncation"    # only tests whose names contain the text
zig build test --summary all                 # per-artifact test counts
zig fmt --check build.zig build.zig.zon zig/
zig test zig/examples/io_patterns.zig        # one standalone example, without the build
python3 zig/testing/fixtures/generate.py --check   # WAV fixtures are current (Python 3, stdlib only)
```

[.github/workflows/ci.yml](.github/workflows/ci.yml) (Linux only; native Windows
CI is deferred to T11) runs the version check, formatting, the fixture
`--check`, a check that every `zig/examples/*.zig` is registered in `build.zig`, `zig build` in Debug and
ReleaseSafe, and `zig build test` in Debug, ReleaseSafe and ReleaseFast. If no
local Zig 0.17.0 is available, the pull request's CI run is the verification;
never report local results that were not run. CI also runs on a branch without
a pull request through `workflow_dispatch`. The C reference uses `configure` and
Make, not Zig's build system.

When adding code:

- Register a new example in the `examples` list in `build.zig`.
- Reference each new `av` file that has tests from a `test` block in
  `zig/root.zig`; Zig analyzes lazily, so unreferenced files' tests never run.
- Export only supported features from `zig/root.zig`.
- Change WAV fixtures only in `zig/testing/fixtures/generate.py`, then rerun it;
  never edit the generated `.wav` files, `manifest.zon` or the README table.

[zig/README.md](zig/README.md) documents the build graph, version policy,
package manifest and per-file provenance.

## Where decisions live

- [README.md](README.md): setup, pinned reference clone commands, runnable commands.
- [zig/README.md](zig/README.md): build graph, version policy, manifest, provenance.
- [zig/testing/fixtures/README.md](zig/testing/fixtures/README.md): the WAV
  fixture contract: every fixture's expected result, the boundary decisions and
  the error precedence the parser must follow. `zig/testing/fixtures.zig`
  exposes the fixtures to tests.
- [port.md](port.md): architecture, contracts and the feature ledger. Read it
  before architectural work. Key sections:
  - "First WAV contract": the accepted subset, limits, error names (`Truncated`,
    `UnsupportedFormat`, `LimitExceeded`, `IoFailure`, `Canceled`, ...) and
    intentional differences from FFmpeg. T02 turns each row into named fixtures
    in `zig/testing/fixtures/README.md`, the canonical fixture contract.
  - "Initial probe output": zffprobe key order, canonical strings, exit codes 0–6.
  - "Verified Zig 0.17 I/O choices", "C-to-Zig decisions that affect correctness"
    and "Recorded design decisions": std API facts and porting decisions already
    checked against the pinned toolchain; consult them before re-deriving.
  - "Proposed Zig layout": one package whose `av` module is rooted at
    `zig/root.zig`, with `core/`, `io/`, `codec/`, `format/`, `cli/` and
    `testing/` created only when their first feature lands.
  - "Provenance and feature tracking": ledger statuses are planned,
    implemented, verified and optimized.
- [TODO.md](TODO.md): ordered tasks T01–T13 with stable IDs, dependencies and
  "Done when" criteria. Check an item only with an evidence note naming the
  files and checks run (for CI, the run link); keep unfinished items unchecked
  with what remains. Update the port.md ledger when a whole capability changes.
- [notes.md](notes.md): every revisable project decision, its reason and what to
  change together. Add new revisable decisions there in the same change.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg analysis,
  the source of the I/O adapter rules below.
- [doc/zig-0.17-guide.md](doc/zig-0.17-guide.md): how to write Zig 0.17 here:
  `@as` versus real casts, the 0.15/0.16 I/O breaks, containers, removed
  builtins, formatting, tests, the build graph, and a checklist to run before
  sending Zig. Follow it for new Zig; where it differs from this file, this
  file wins.

## References

FFmpeg and zigimg are independent clones under the ignored `.references/`
directory; clone both at the pinned revisions using
[README.md](README.md#clone-the-reference-repositories) before source research.
Do not commit their files, Git metadata or gitlinks; they are not submodules.
zigimg is a Zig implementation reference, never a build dependency.

The following paths are relative to `.references/ffmpeg/`:

- `libavutil/`: frames, buffers, rational arithmetic, formats, options, CPU support.
- `libavcodec/`: codec implementations, packets, bit readers, parsers, DSP.
- `libavformat/`: containers, muxing/demuxing, protocols, buffered I/O.
- `libavfilter/`: filter graph, negotiation, individual audio/video filters.
- `libswresample/`, `libswscale/`: audio resampling and video conversion/scaling.
- `libavdevice/`: platform capture and playback integrations.
- `fftools/`: ffmpeg, ffprobe, ffplay, scheduling and command-line behavior.
- `configure`, `ffbuild/`, library `Makefile`s: C feature/dependency/build model.
- `tests/fate/`, `tests/ref/`, `tests/checkasm/`: integration definitions,
  expected outputs, and optimized-kernel checks; some need external samples.

New Zig implementation files belong under `zig/`; the package is defined by
the root `build.zig` and `build.zig.zon`. Preserve reference attribution/licenses
and existing user changes.

## Toolchain and architecture

- `.zig-version` is a tooling convention and `minimum_zig_version` is package
  metadata; neither is an exact compiler check. `build.zig` enforces the tested
  version (`tested_zig_version`); upgrade deliberately, changing all three and
  CI together.
- Check installed standard-library sources and versioned official documentation
  before adopting build, I/O, or reflection APIs from older examples; the
  [Zig 0.17 guide](doc/zig-0.17-guide.md) lists the stale patterns to avoid.
  Resolve disagreements by compiling a minimal check with the pinned toolchain.
- Start with one package and one named library module, `av`. Use ordinary
  file imports internally. Split named modules only for a demonstrated need,
  such as publishing a subset; keep imports acyclic and shared types minimal.
- The default build must compile an artifact; the test step must execute tests.
  Keep the explicit package `.paths` allowlist, which excludes the reference C
  tree; never use `""`. The build has no C sources, libc or package
  dependencies; add one only with a recorded decision in port.md.
- Keep the public Zig API small, typed, and independent of C struct layouts.
  Add any C ABI compatibility later as a separate adapter.
- Pass allocators and I/O dependencies explicitly. Document whether slices and
  frames are borrowed, owned, shared, or transferred, and their lifetimes.
- `std.Io` belongs at OS boundaries; memory parsing needs only Reader/Writer
  interfaces, and allocation-free kernels need neither an allocator nor I/O.
- Distinguish malformed input, unsupported functionality, end of stream, and
  backpressure. Preserve timestamp, rounding, draining, and seek semantics.
- Implement portable scalar behavior first. Add SIMD or architecture-specific
  kernels only with comparisons against the scalar implementation.

## Zig 0.17 I/O and test patterns

[zig/examples/io_patterns.zig](zig/examples/io_patterns.zig) is the executable
reference for these rules.

- Keep PCM kernels on slices. Parse WAV through `*std.Io.Reader`, starting with
  `Reader.fixed` tests. Use exact reads (`readSliceAll`) into local field
  buffers to handle tiny input fragments; do not retain reader-buffer views
  across subsequent reads. A failed exact read may have consumed part of a
  field; treat it as terminal.
- Encode output fields into local arrays and call `writeAll`; do not rely on
  `Writer.writeInt` working with buffers smaller than its documented minimum.
  The owning operation or encoder `finish` flushes and checks failure.
- Borrow `.interface` from a stable file adapter and reuse that adapter across
  reads. Preserve its scratch-buffer lifetime and detailed `.err` diagnostics;
  reconstructing it can lose read-ahead bytes. Keep seekability optional.
- Tests live beside the code. Cover fragmented input with `std.testing.Reader`
  and `artificial_limit = .limited(1)`, generic read failure with
  `std.Io.Reader.failing`, and real files with `std.testing.io` plus
  `std.testing.tmpDir` using empty, tiny and larger adapter buffers. Test CLI
  output in separate process runs, never inside the test runner.

## Modern Zig metaprogramming

- Prefer normal types and functions; use `comptime` for actual invariants,
  static tables, generic kernels, and component registration.
- Keep component selection explicit. Validate descriptors, signatures,
  dependencies, and duplicate names at compile time. Registration must not
  depend on filesystem traversal order or runtime global constructors.
- Use typed options with explicit metadata for ranges, help, units, and aliases;
  derive repetitive access with `@field` and `@FieldType` where useful.
- Zig 0.17 reflection uses `field_names` / `field_types`; do not copy older
  `@typeInfo(T).@"struct".fields` or `@Type(...)` recipes. Consult `@Struct`,
  `@Enum`, and other current constructors only when generated types are needed.
- Specialize hot loops on a small set of real constants. Use runtime dispatch
  at stream/component boundaries rather than generating every possible graph.
- Parse wire bytes explicitly. A Zig `packed struct` is not a general container
  or bitstream parser. Check lengths and arithmetic before reads/allocations.

## Porting and validation

Inspect source with `rg` and read the corresponding implementation, header,
Makefile feature/dependency entries, and relevant tests before porting behavior.
Port a small working path at a time. The first path is a bounded RIFF/WAV PCM
signed 16-bit little-endian reader/decoder/writer, then the zffprobe CLI.

For implemented multimedia behavior, use hand-checked vectors and differential
tests against a recorded FFmpeg revision/configuration. Check decoded content,
metadata, timestamps, failure cases, and resource cleanup. Bit-exact results are
appropriate for integer/lossless paths; define justified tolerances for floating
point or lossy paths. Test round trips against an independent reference as well
as the port. Run relevant FATE cases only when their prerequisites are present.
Required local fixtures must fail when missing. Report skips from optional
external corpora explicitly; a passing run with skips is not complete coverage.

## Provenance and commits

Record each completed feature in port.md with source provenance, supported
subset, tests run, and remaining limitations. New Zig files start with an
`SPDX-License-Identifier` line and a provenance comment, then `//!` module docs
(see `zig/examples/`); [LICENSE](LICENSE) holds the LGPL v2.1 text for the
`LGPL-2.1-or-later` project sources. For a derived file, record its upstream
path/revision and attribution and preserve the actual notices instead of
assigning one SPDX tag indiscriminately. Keep optional GPL/external components
explicit. Use descriptive commit subjects; do not rewrite existing history as
part of documentation work.
