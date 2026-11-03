# Native Zig port: implementation checklist

This is the execution checklist for [port.md](port.md). The plan explains the
architecture and compatibility rules; this file records the work to do next.
The repository tracks project documentation, the minimal Zig package and build
(the `av` module, documented in [zig/README.md](zig/README.md)), the WAV fixture
contract ([zig/testing/fixtures](zig/testing/fixtures/README.md)) and the first
complete path: PCM s16 kernels, audio/time types, a bounded WAV parser and
known-length writer, file and pipe adapters, and the `zffprobe` tool. Linux CI
builds and tests it in every mode and compares it with a pinned FFmpeg build
([zig/testing/reference](zig/testing/reference/README.md)). FFmpeg and zigimg
are independent clones in ignored `.references/`; see
[README.md](README.md#clone-the-reference-repositories) for setup.

**Next tasks: T11's outstanding native Windows run (deferred for now), then
T12 — a second supported variant or small container.**

Work through the first WAV/PCM path before expanding the framework. Tasks have
stable IDs for references. Check an item only when its completion criteria are
met, and append a short evidence note with the relevant files and checks run.
Keep unfinished or blocked items unchecked and record what remains. Update the
feature ledger in port.md when an entire capability becomes implemented or
verified; do not duplicate this detailed checklist there.

Dependencies below describe implementation prerequisites unless labeled a
**completion gate**. Work can begin when its code prerequisites are ready;
reference setup T03 gates differential acceptance, not writing native code.
Keep task IDs stable. Implementation decisions and fixture expectations must
agree with the [first WAV contract](port.md#first-wav-contract).

## Completed preparation

- [x] Inspect the FFmpeg source layout and record the reference revision.
  Evidence: [inspected baseline](port.md#inspected-baseline) and source map.
- [x] Establish project guidance and a Zig design with phased acceptance criteria.
  Evidence: [CLAUDE.md](CLAUDE.md) (formerly AGENTS.md) and [port.md](port.md).
- [x] Validate the illustrative PCM kernel with Zig 0.17.0.
  Evidence: both documentation-example tests and formatting passed; this is not
  an implemented codec. T04 later promoted it to [zig/codec/pcm.zig](zig/codec/pcm.zig). See [the example](port.md#example-one-pcm-kernel-two-byte-orders).
- [x] Clone and inspect zigimg as a Zig implementation reference.
  Evidence: [pinned analysis](doc/zigimg-reference.md), commit `083d0304840a3f5fd547c2e2005148a18886c401`;
  its focused I/O suite passed 15/15 tests with Zig 0.17.0.
- [x] Make the adopted I/O patterns runnable in an original example.
  Evidence: [io_patterns.zig](zig/examples/io_patterns.zig), formatting and 6/6
  tests passed in each of Debug, ReleaseSafe and ReleaseFast on native Windows.
  Covers memory, fragmented input, file buffers, truncation, read failure and
  fixed output capacity. A seventh test for the file adapter's retained `.err`
  was added later; all 7 tests pass in Linux CI (see the CI entry below) but
  have not been rerun on Windows. This does not complete T01 or implement WAV.
- [x] Separate zffmpeg into its own repository with reproducible reference setup.
  Evidence: [README.md](README.md) records both pinned clone commands;
  [.gitignore](.gitignore) excludes references and Zig build output. Only project
  documentation and the original Zig example belong in the initial commit.
- [x] Add Linux CI for the standalone examples.
  Evidence: [ci.yml](.github/workflows/ci.yml);
  [run 41544372319](https://github.com/zxc-f/zffmpeg/actions/runs/41544372319)
  on `ubuntu-24.04` at commit `d701a20` confirmed `zig version` 0.17.0, passed
  `zig fmt --check zig/`, and passed 7/7 `io_patterns.zig` and 2/2
  `pcm_s16.zig` tests in each of Debug, ReleaseSafe and ReleaseFast. Native
  Windows CI is deferred (T11).

## First milestone: build and a tested PCM kernel

- [x] **T01 — Add the minimal Zig package and build.** One package, one named
  library module `av` at `zig/root.zig`; internal files use ordinary imports.
  Preserve target/optimization options. Default install must compile an artifact,
  and `test` must execute its test artifact. Explicitly aggregate the existing
  example tests (`zig/examples/*.zig`) through a test root or separate run
  artifact; no new media helpers are required for this build task. Extend the
  Linux CI workflow to run `zig build` and `zig build test` in Debug and
  ReleaseSafe with the build's exact-version check. Verify failure propagation with a
  temporary failing test, then remove it. Use `.zig-version`
  as a hint, `.minimum_zig_version = "0.17.0"` as metadata, and an explicit
  tested-version check. Generate a package fingerprint with the toolchain and
  use a `.paths` allowlist excluding the C tree; start with no dependencies.
  Record applicable license/attribution for each new file; preserve derived
  notices. Done when build/test smoke checks pass in Debug and ReleaseSafe,
  `zig fmt --check build.zig build.zig.zon zig/` passes, and build-graph inspection
  or an isolated build confirms no reference C build/compiler dependency.
  Document library setup in `zig/README.md`, update the root README's runnable
  commands and keep outputs ignored. Update the README, plan, checklist and
  agent guidance current-state statements in the same change.
  Evidence: [build.zig](build.zig), [build.zig.zon](build.zig.zon),
  [.zig-version](.zig-version), [zig/root.zig](zig/root.zig),
  [zig/README.md](zig/README.md) and [ci.yml](.github/workflows/ci.yml), merged in
  zxc-f/zffmpeg#4. The fingerprint `0x4b4a1226947194f5` is the value `zig build`
  suggested for the manifest without one ([run 41548322449](https://github.com/zxc-f/zffmpeg/actions/runs/41548322449)). A temporary
  failing test made `zig build test` report `av 0 pass, 1 fail` and exit with
  status 1 ([run 41548611661](https://github.com/zxc-f/zffmpeg/actions/runs/41548611661)); it was then reverted. On the PR head,
  [run 41548960006](https://github.com/zxc-f/zffmpeg/actions/runs/41548960006) passed the exact-version check,
  `zig fmt --check build.zig build.zig.zon zig/`, the example-registration check,
  `zig build` in Debug and ReleaseSafe, and `zig build test` with 9/9 tests
  (`av` 0, `io_patterns` 7, `pcm_s16` 2) in Debug, ReleaseSafe and ReleaseFast
  on `ubuntu-24.04`. No C dependency: `build.zig` has no C sources, libc, system
  libraries or package dependencies, and CI builds from a checkout without
  `.references/`. Native Windows was not run (T11).

- [x] **T02 — Materialize the WAV contract and fixtures.** Create the canonical
  `zig/testing/fixtures/README.md` with a named fixture for each rule in port.md:
  `fmt ` sizes/extensions, mono/stereo, rate/alignment, chunk order/duplicates,
  empty data versus unknown size, padding, truncation, limits and trailing data.
  Record expected samples, metadata, errors/precedence, hashes or deterministic
  generation commands, and fixture provenance. Include high-rate plain tag-1
  output as an intentional header difference from FFmpeg. Also decide and
  fixture the open boundary cases listed under the contract's Bounds row: a
  final odd-sized chunk whose padding byte is missing at EOF, a chunk (including
  `data`) whose declared size exceeds the RIFF extent, and a `riff_size` that
  disagrees with a known input length. Keep a fixture for an inconsistent
  `byte_rate`, which is accepted and ignored. Keep required tiny
  fixtures local and fail if any are missing. Done when small independent
  vectors make every accepted/rejected case reproducible.
  Evidence: [fixture README](zig/testing/fixtures/README.md),
  [generate.py](zig/testing/fixtures/generate.py),
  [manifest.zon](zig/testing/fixtures/manifest.zon) and
  [fixtures.zig](zig/testing/fixtures.zig). 52 committed fixtures (12 accepted,
  5 of them exact writer output, and 40 rejected) plus one synthesized 2 MiB
  vector, each with its expected result and SHA-256. The README records the
  boundary decisions, the error precedence and a byte-by-byte check of
  `mono_8k`. [run 41550661260](https://github.com/zxc-f/zffmpeg/actions/runs/41550661260): `generate.py --check` passed, and `zig build test`
  passed 12/12 in Debug, ReleaseSafe and ReleaseFast, including the `av`
  fixture tests (manifest consistency, every file embedded and matching its
  SHA-256). Remaining at the time: no parser consumed the fixtures and FFmpeg
  had not compared them; T06 and T10 have since done both.

- [x] **T03 — Establish the C reference comparison setup.** Use Linux x86-64 in
  a pinned container or WSL environment. Build `.references/ffmpeg` at the
  recorded upstream revision with Clang. Record environment/tool versions,
  tested configure command,
  `config.log`/binary/fixture hashes and comparisons in
  `zig/testing/reference/README.md`. Enable the WAV/PCM, raw sample output, I/O
  and CLI/filter prerequisites actually needed; disable unrelated autodetection.
  Do not inherit the broad GPL/nonfree FATE configuration. Done when exact PCM
  output and normalized metadata comparisons are reproducible. This is an
  explicit Linux reference-test dependency, independent of native Windows Zig
  tests; work can proceed alongside T01/T02/T04/T05.
  Evidence: [build-ffmpeg.sh](zig/testing/reference/build-ffmpeg.sh) builds the
  pinned commit out of tree with Clang and a minimal LGPL configuration (file
  and pipe protocols, WAV demuxer, s16le decoder, encoder and raw muxer,
  `aresample`; autodetection, asm, network, ffplay and avdevice off), and
  [compare.py](zig/testing/reference/compare.py) runs the comparisons. CI's
  `reference` job runs both on GitHub's `ubuntu-24.04` image, prints the image
  and tool versions, and caches the build under a key from the Clang version
  and the script. [zig/testing/reference/README.md](zig/testing/reference/README.md)
  records the environment (Ubuntu clang 18.1.3, GNU Make 4.3, Python 3.12.3,
  Zig 0.17.0), the configure command, the `ffmpeg`, `ffprobe`, `config.log` and
  fixture SHA-256 values and the full results. Two separate from-scratch builds,
  in [run 41557433205](https://github.com/zxc-f/zffmpeg/actions/runs/41557433205)
  and [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301),
  gave the same exact-sample and normalized-metadata results. The environment is
  GitHub's versioned runner image rather than a container digest; the job
  prints the image version on every run.

- [x] **T04 — Implement the PCM sample conversion kernels.** Depends on T01 and
  T02. Add typed slice-based signed 16-bit decoding and encoding with explicit
  byte order and destination capacity. Start with the needed specialization;
  retain a scalar implementation and document ownership/overlap rules. Done
  when independent vectors cover signed extrema, empty input, incomplete
  samples, insufficient output and the documented failure-mutation behavior.
  Promote the kernel/tests from `zig/examples/pcm_s16.zig` into
  `zig/codec/pcm.zig` and update the port.md source link; record applicable
  per-file license/provenance.
  Evidence: [zig/codec/pcm.zig](zig/codec/pcm.zig) (`decodeS16`/`encodeS16`, both
  byte orders; the example file is removed). Its 7 tests cover signed extrema,
  empty and odd-length input, short outputs with unchanged contents on failure,
  an exhaustive round trip of all 65,536 values checked against independently
  computed bytes, and the 5 writer-output fixtures from `generate.py`.
  [run 41553566007](https://github.com/zxc-f/zffmpeg/actions/runs/41553566007) passed `zig build test` with 28/28 tests in Debug, ReleaseSafe and
  ReleaseFast. Scalar only; no SIMD.

- [x] **T05 — Add only the audio/time types needed by this path.** Depends on T01
  and T02. Represent sample rate, channel count/order, interleaving and borrowed
  samples clearly. Derive timing from integer sample-frame counts; define the
  required time-base/rescaling behavior. Done when zero/invalid rates, channel
  alignment, rounding and overflow boundaries are covered. Defer general frame
  ownership, reference counting and compressed bit readers until needed.
  Evidence: [zig/core/audio.zig](zig/core/audio.zig) (`ChannelLayout`,
  `SampleFormat`, validated `Format` with checked frame/byte arithmetic, borrowed
  `S16Frames`) and [zig/core/time.zig](zig/core/time.zig) (`TimeBase`, `rescale`
  with FFmpeg's five rounding modes, `?i64` timestamps). Tests cover zero rates
  and channel counts, unsupported layouts, incomplete frames, `u64` overflow at
  the boundary, every rounding mode on positive, negative and halfway values,
  and `i64`/`u32` extremes. The rescale vectors come from an exact rational
  oracle that agrees with a transcription of `av_rescale_rnd` except for the
  two documented differences (overflow error, exact INT64_MIN). Passed in
  [run 41553566007](https://github.com/zxc-f/zffmpeg/actions/runs/41553566007). T10 later compared the WAV path's
  `time_base` and `duration_ts` with FFmpeg; `rescale` itself has no direct
  differential run against `av_rescale_rnd`.

## Second milestone: a complete WAV/PCM path

- [x] **T06 — Implement one bounded WAV parser.** Depends on T02 and T05. Accept
  `*std.Io.Reader`, initially tested with `Reader.fixed`; read exact fields into
  local arrays instead of casting structs. Implement T02's complete contract,
  including validation after data and contextual EOF/error mapping; test every
  fixture through `zig/testing/fixtures.zig`, matching its error precedence. Use checked
  size arithmetic in every optimization mode. Add a bounded `std.testing.fuzz`
  entry using `Smith`, plus deterministic fixture regressions; sustained fuzzing
  remains later work. Done when all contract cases pass in Debug, ReleaseSafe
  and ReleaseFast, including empty/short buffers, and the fuzz entry runs.
  Evidence: [zig/format/wav.zig](zig/format/wav.zig) (`Parser` with
  `readHeader`, `readSamples` and `finish`; `probe`; `decodeToRaw`; `Limits`).
  Fields are read with `readSliceAll` into local arrays and every size is
  checked with explicit arithmetic. Tests check all 52 fixtures against their
  contract result from `Reader.fixed` and again through `std.testing.Reader`
  with `artificial_limit = .limited(1)`, probing against decoding, an error
  found after frames were delivered (`duplicate_data`), configurable limits and
  the synthesized 2 MiB skip vector (its SHA-256 checked against generate.py).
  The `std.testing.fuzz` entry builds its input with `Smith` and runs its
  four-fixture corpus plus the empty input under `zig build test`. First pass:
  [run 41555852449](https://github.com/zxc-f/zffmpeg/actions/runs/41555852449); in [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301) the `av` tests passed 40/40 in
  Debug, ReleaseSafe and ReleaseFast. Sustained fuzzing has not been run.

- [x] **T07 — Connect the same parser/kernel to file and sequential I/O.** Depends
  on T04 and T06. Use standard-library adapters; include non-seekable readers with
  known chunk sizes and `fmt ` before data. Add file/stream writer adapters for
  T08. Follow the [I/O example](zig/examples/io_patterns.zig): borrow `.interface`
  from stable adapters, retain their scratch buffers and reuse readers across
  calls to preserve read-ahead. Keep `std.Io` at OS boundaries and recover file
  `.err` diagnostics, including cancellation. Separate path helpers that own
  handles from borrowed-handle operations. Define bounded work storage and
  flush behavior. Test file readers with empty, one-byte and larger buffers,
  plus one-byte source fragments using `std.testing.Reader.artificial_limit`.
  Done when memory, files and sequential input agree, large data streams without
  whole-file allocation, and cleanup/error paths pass. Unknown-length WAV and
  resumable nonblocking parsing remain unsupported; no new scheduler is required.
  Evidence: [zig/io/file.zig](zig/io/file.zig): borrowed-handle
  `probeFile`, `decodeFile` and `writeFile`, and path helpers `probePath` and
  `writePath` that own and close their handle. Readers use `readerStreaming`
  over the caller's buffer, one adapter per stream, so pipes take the same path
  and read-ahead is kept. Memory is that buffer plus the parser's fixed 4 KiB,
  with no allocation. A generic failure is replaced by the adapter's `.err`
  (for example `NotOpenForReading`, `Canceled`). Tests: every fixture agrees
  with memory through files with 0-, 1-, 64- and 64 KiB-byte buffers; file
  decoding equals memory decoding; a 4 MiB stream is written in 4096-sample
  pieces and read back in 1000-sample pieces; read and write failures report
  the file's own error; a path helper closes its handle after a parse failure,
  so the file can be deleted. Pipe input is covered by the `zffprobe` process runs (T09). First
  pass: [run 41556196435](https://github.com/zxc-f/zffmpeg/actions/runs/41556196435); also [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301).

- [x] **T08 — Implement known-length WAV writing.** Code prerequisites: T04,
  T05 and T07; T03 is a completion gate. Accept `*std.Io.Writer` plus the expected
  frame count for memory and file/stream output. Emit exact sizes up front with
  a 16-byte tag-1 `fmt `; no seeking or placeholders. Check all sizes with
  `std.math.add/sub/mul` or overflow builtins, including the total RIFF extent.
  `finish` validates the frame count and flushes output. Done when under/overrun,
  overflow and write/flush failures are tested and the reference decodes generated
  files to the expected samples/metadata, including empty and high-rate cases.
  Evidence: `wav.Writer` in [zig/format/wav.zig](zig/format/wav.zig):
  `begin` checks the rate limit and every 32-bit size, including the RIFF
  extent, before writing a 44-byte header; `writeFrames` and `finish` enforce
  the frame count, and `finish` flushes. Tests reproduce the five writer-output
  fixtures byte for byte (also through files with a 1-byte buffer in
  `zig/io/file.zig`), and cover too many, too few and incomplete frames, size
  overflow at the largest frame count, and write and flush failures. FFmpeg
  decodes those same five files, including `empty_data`, `stereo_96k_tag1` and
  `mono_192k_rate_limit`, to the expected samples and metadata
  ([reference results](zig/testing/reference/README.md#writer-output-checked-by-ffmpeg)).
  FFmpeg has not read writer output produced at run time; that needs a writing
  tool (T13). First pass: [run 41555852449](https://github.com/zxc-f/zffmpeg/actions/runs/41555852449); reference: [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301).

- [x] **T09 — Add the minimal `zffprobe` tool.** Depends on T06 and T07. Use
  `main(init: std.process.Init)` and the output schema/status codes in port.md.
  Keep parsing in the library; produce stdout only after complete validation,
  with diagnostics on stderr. Cleanup/flush must precede explicit process exit.
  Done when separate executable runs capture/test both streams and status for
  valid, empty, malformed, unsupported, I/O and resource-limit cases. Do not
  print CLI output inside the unit-test runner.
  Evidence: [zig/cli/probe.zig](zig/cli/probe.zig) (`main(init:
  std.process.Init) u8`; parsing stays in `av`; the report is formatted into a
  fixed buffer and written only after `probe` succeeds; diagnostics are one
  stderr line with the error name). `build.zig` runs 15 `probe_cases` as
  separate processes that check stdout, stderr and the exit status: valid mono
  and stereo (stereo from a pipe), empty data, empty input, a malformed header,
  an error after the data, a truncated pipe, an unsupported container, an
  unknown size, the chunk limit, a missing file and a directory (I/O, exit 4),
  no arguments, too many arguments and help. All passed in Debug, ReleaseSafe
  and ReleaseFast in [run 41556590842](https://github.com/zxc-f/zffmpeg/actions/runs/41556590842) and [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301). There is no
  allocating path, so the out-of-memory status is mapped but not exercised.

- [x] **T10 — Verify the whole first path.** Depends on T03 and T07–T09. Compare
  decoded samples, metadata and timing with the recorded reference; validate
  generated WAV externally as well as by self round trips. Exercise truncated
  headers/data, malformed lengths, partial I/O, resource limits and cleanup on
  failure for allocating paths. Report optional external corpus skips separately;
  missing required fixtures fail the run. Done when results and intentional
  differences are recorded and every supported operation has reproducible evidence.
  Evidence: [compare.py](zig/testing/reference/compare.py) and the
  [recorded results](zig/testing/reference/README.md#results). In
  [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301) all 12 accepted fixtures decoded to exactly the expected
  samples in FFmpeg, `ffprobe` agreed on format, codec, sample format, channels,
  rate, time base and duration, and `zffprobe` printed the expected report. All
  40 rejected fixtures gave the contract's `zffprobe` status and error name.
  FFmpeg accepts 24 of them; these and two metadata differences
  (`channel_layout=unknown`, and no duration for `empty_data`) are recorded as
  intentional. The writer is validated through the writer-output fixtures
  (T08). Truncated headers and data, malformed lengths and limits are fixtures;
  partial I/O is covered by one-byte reads and small file buffers (T06, T07).
  The WAV path allocates nothing; handle cleanup on failure is tested in T07.
  No optional external corpus is used, so nothing is skipped; a missing or
  changed fixture fails both `zig build test` (fixtures are embedded and
  hash-checked) and `compare.py`.

- [ ] **T11 — Establish the platform and build-mode baseline.** Once T07–T09
  exist, run native Linux and Windows checks in Debug, ReleaseSafe and
  `-Doptimize=ReleaseFast` (the safety-off check). The GitHub Actions
  [Linux workflow](.github/workflows/ci.yml) already checks the examples; extend
  it to the build, parser and CLI checks without FATE sample sync. Native Windows
  CI is deferred for now: add a GitHub Actions Windows job (or, failing that, a
  reproducible local Windows script) when Windows evidence is needed; upstream
  FFmpeg Wine jobs do not supply that evidence. Keep cross-compilation separate
  from default test execution. Done when both native runs and reference results
  are recorded; missing environments remain outstanding. Verify the exact
  toolchain used in each run.
  Progress: Linux is done. The `linux` CI job checks `zig version` is 0.17.0,
  then runs `zig build` in Debug and ReleaseSafe and `zig build test` in Debug,
  ReleaseSafe and ReleaseFast: 47/47 tests (`av` 40, `io_patterns` 7) and the
  15 `zffprobe` process runs in each mode in [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301). A separate,
  compile-only step builds the library and `zffprobe` for x86_64-windows-gnu,
  aarch64-linux-musl and aarch64-macos without running them. Reference results
  are recorded under T03/T10. Remaining: a native Windows run in all three
  modes, deferred for now; a cross-compile is not that evidence.

The first milestone is useful when kernels work; the second is complete when
T06–T11 meet their criteria. Update port.md with the supported subset, provenance,
verification evidence and remaining limitations at that point.

## Next: prove reuse before generalizing

- [ ] **T12 — Add a second supported variant or small container.** After T10/T11,
  choose the path that tests the least-proven boundary: a sample-format variant
  for conversion/dispatch, or a small big-endian container for byte order and
  parser reuse. Stabilize T07 first. Reuse PCM/time/I/O logic and extract only shared
  contracts demonstrated by both implementations. If format dispatch becomes
  useful, start with explicit descriptors and typed options; preserve a bounded
  probe prefix for sequential input. Test format identity with disabled features
  when build selection is introduced. Done when the new path has
  independent vectors and reference comparisons without duplicating the kernel.
- [ ] **T13 — Add a minimal `zffmpeg` conversion/stream-copy pipeline.** Start
  with supported PCM stream-copy/remuxing and same-format decode/encode; no
  rate/channel conversion until the corresponding transforms exist. Publish an
  operation matrix for the available formats. Introduce runtime
  selection, buffering and drain/reset semantics only where needed. Done when
  conversions and applicable stream-copy operations pass end-to-end checks with
  explicit ownership, progress and cancellation behavior.

## Later backlog — refine when selected

These are directions from the plan, not fully scoped implementation tasks.
Choose a concrete supported subset and acceptance tests before starting one.

- [ ] Lossless coverage: FLAC and selected image formats.
- [ ] Audio conversion/resampling and basic video scaling/filtering.
- [ ] Prioritized compressed codecs and containers, with explicit profile support.
- [ ] Registries and build feature selection when the component count justifies them.
- [ ] Fuzzing campaigns and a growing corpus as parsers become available.
- [ ] Measured SIMD/threading improvements against retained scalar baselines.
- [ ] Platform devices/hardware integration and compatibility adapters as needed.

For every item, apply the [feature completion workflow](port.md#feature-completion-workflow).
Keep tasks focused on tested behavior and readable native Zig code; completion
is not measured by how many C files have been translated.
