# Native Zig port: implementation checklist

This is the execution checklist for [port.md](port.md). The plan explains the
architecture and compatibility rules; this file records the work to do, from
the finished first path to a port that covers most of what FFmpeg's users
need. The repository tracks project documentation, the minimal Zig package and
build (the `av` module, documented in [zig/README.md](zig/README.md)), the WAV
fixture contract ([zig/testing/fixtures](zig/testing/fixtures/README.md)) and
the first complete path: PCM s16 kernels, audio/time types, a bounded WAV
parser and known-length writer, file and pipe adapters, and the `zffprobe`
tool. Linux CI builds and tests it in every mode and compares it with a pinned
FFmpeg build ([zig/testing/reference](zig/testing/reference/README.md)).
Development is verified on Linux only; see the
[platform policy](#platform-policy-linux-only-during-development). FFmpeg and
zigimg are independent clones in ignored `.references/`; see
[README.md](README.md#clone-the-reference-repositories) for setup.

**Next tasks: T12 — a second supported variant or small container, then T13 —
a minimal `zffmpeg`. Milestone 4 (T14–T19) follows, each piece landing with its
first consumer.**

Work through the milestones in order; a task may start once its dependencies
are met. Tasks have stable IDs for references. Check an item only when its
completion criteria are met, and append a short evidence note with the relevant
files and checks run.
Keep unfinished or blocked items unchecked and record what remains. Update the
feature ledger in port.md when an entire capability becomes implemented or
verified; do not duplicate this detailed checklist there.

Dependencies below describe implementation prerequisites unless labeled a
**completion gate**. Work can begin when its code prerequisites are ready;
reference setup T03 gates differential acceptance, not writing native code.
Keep task IDs stable. Implementation decisions and fixture expectations must
agree with the task's written contract; for WAV, the
[first WAV contract](port.md#first-wav-contract).

## Platform policy: Linux only during development

Decided on 2026-11-03 and recorded in [notes.md](notes.md#ci): until the
platform milestone (T62–T63), every task is built, tested and compared on
Linux x86-64 only.

- A task's "Done when" criteria are met by native Linux runs in Debug,
  ReleaseSafe and ReleaseFast in the [CI workflow](.github/workflows/ci.yml),
  plus the `reference` job's FFmpeg comparison where the task has one. Windows,
  ARM (AArch64 Linux and macOS) and big-endian runs are neither required nor
  claimed. They wait for T62 and T63, when the code is more complete.
- New Zig code must still be portable, so that those later runs find little to
  fix. Follow [Portable Zig code](CLAUDE.md#portable-zig-code) in CLAUDE.md: in
  short, reach the OS only through `std.Io` and `std.process.Init`, keep byte
  order and integer widths explicit, and keep architecture-specific code behind
  a scalar reference.
- CI's compile-only step builds the library and tools for x86_64-windows-gnu,
  aarch64-linux-musl and aarch64-macos. It catches Linux-only APIs at compile
  time; it is a portability guard, not test evidence for those platforms.
- The FFmpeg reference build stays Linux-only, also after T62/T63; other
  platforms compare against results recorded on Linux.

## Rules for every task from T12 on

- Start with the contract: the supported subset, errors, limits and intentional
  differences, written down (port.md or a fixture README) with named fixtures,
  before the implementation. Generate fixtures with standard-library Python, or
  record how a reference-made fixture was produced and under which license.
- Extend [build-ffmpeg.sh](zig/testing/reference/build-ffmpeg.sh) only with the
  LGPL components the task compares against, and compare through the
  differential harness (`compare.py` until T19 generalizes it). Integer and
  lossless paths compare bit-exactly; floating-point and lossy paths state a
  tolerance and the reason for it.
- Keep large media out of the repository. Tiny local fixtures are required and
  fail when missing; larger samples (for example FATE's) are an optional corpus
  whose skips are reported, never silently passed.
- Every parser or decoder that reads untrusted bytes gets a bounded
  `std.testing.fuzz` entry when it lands; T60 sustains them.
- Evidence names the files, the checks and the CI run link. Record new
  revisable decisions in [notes.md](notes.md), provenance in each new file's
  header and in [zig/README.md](zig/README.md), and capability status in the
  [port.md ledger](port.md#provenance-and-feature-tracking).
- Introduce shared machinery (packets, registries, graphs, transforms) with its
  first real consumer, which each task below names.

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
  GitHub's versioned runner image (`ubuntu24` 20261026.354.1 in
  [run 41559086382](https://github.com/zxc-f/zffmpeg/actions/runs/41559086382), which restored the cached build with identical
  hashes and results) rather than a container digest; the job prints the image
  version on every run.

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

- [x] **T11 — Establish the Linux platform and build-mode baseline.** Rescoped
  on 2026-11-03 by the [platform policy](#platform-policy-linux-only-during-development):
  native Windows and ARM checks moved to T62 and T63. Once T07–T09 exist, run
  native Linux x86-64 checks in Debug, ReleaseSafe and `-Doptimize=ReleaseFast`
  (the safety-off check) in the GitHub Actions
  [Linux workflow](.github/workflows/ci.yml), covering the build, parser and CLI
  checks without FATE sample sync. Keep cross-compilation separate from test
  execution; upstream FFmpeg's Wine jobs supply no evidence. Done when the
  native runs and reference results are recorded and the exact toolchain is
  verified in each run.
  Evidence: the `linux` CI job checks `zig version` is 0.17.0, then runs
  `zig build` in Debug and ReleaseSafe and `zig build test` in Debug,
  ReleaseSafe and ReleaseFast: 47/47 tests (`av` 40, `io_patterns` 7) and the
  15 `zffprobe` process runs in each mode in [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301), and again on
  the final head of zxc-f/zffmpeg#7 in [run 41559356966](https://github.com/zxc-f/zffmpeg/actions/runs/41559356966). A separate,
  compile-only step builds the library and `zffprobe` for x86_64-windows-gnu,
  aarch64-linux-musl and aarch64-macos without running them. Reference results
  are recorded under T03/T10.

The first milestone is useful when kernels work; the second is complete when
T06–T11 meet their criteria, as they now do on Linux. port.md records the
supported subset, provenance, verification evidence and remaining limitations.

## Third milestone: prove reuse before generalizing

- [ ] **T12 — Add a second supported variant or small container.** After T10/T11,
  choose the path that tests the least-proven boundary: a sample-format variant
  for conversion/dispatch, or a small big-endian container for byte order and
  parser reuse. Stabilize T07 first. Reuse PCM/time/I/O logic and extract only shared
  contracts demonstrated by both implementations. If format dispatch becomes
  useful, start with explicit descriptors and typed options; preserve a bounded
  probe prefix for sequential input. Test format identity with disabled features
  when build selection is introduced. Done when the new path has
  independent vectors and reference comparisons without duplicating the kernel.
  The option not chosen stays in T20 (sample formats) or T22 (containers).
- [ ] **T13 — Add a minimal `zffmpeg` conversion/stream-copy pipeline.** Depends
  on T12. Start with supported PCM stream-copy/remuxing and same-format
  decode/encode; no
  rate/channel conversion until the corresponding transforms exist. Publish an
  operation matrix for the available formats. Introduce runtime
  selection, buffering and drain/reset semantics only where needed. Done when
  conversions and applicable stream-copy operations pass end-to-end checks with
  explicit ownership, progress and cancellation behavior.

## Roadmap to a nearly complete port

The milestones below take the port from one audio path to the codecs,
containers, filters and tools most FFmpeg users rely on. They refine phases 3–6
of [port.md](port.md#porting-order-and-acceptance-criteria). Each task is one
or a few reviewable pull requests. "Reference" lists the upstream sources to
read first, relative to `.references/ffmpeg/`, and the FATE definitions that
map its coverage. Order follows dependencies; a task may start as soon as its
dependencies are met. Scope wording is the intended subset. Refine it into a
written contract when the task starts.

## Milestone 4: core media framework

Shared types the next formats need. Each one lands with the first consumer it
names, not as an empty framework.

- [ ] **T14 — Packets, frames and shared buffers.** Depends on T13. It lands
  with the first stage that buffers (T13's stream copy or T26).
  Reference: `libavcodec/packet.c`, `libavutil/frame.c`, `libavutil/buffer.c`,
  `libavcodec/avcodec.h` (send/receive contract).
  A `Packet` (payload, pts, dts, duration, stream index, key/discard flags,
  owned or borrowed data) and an audio `Frame` (format, layout, sample count,
  planes, pts); video planes follow in T38. Reference-counted storage only
  where stages share data, plus a frame pool for decoders. Decoder and encoder
  adapters expose need-input, have-output, drained and reset states (port.md
  "Streaming state, ownership and time").
  Done when PCM decode and encode run through the adapters with drain and reset
  tests, and every allocating path passes `std.testing.allocator` leak checks
  and allocation-failure injection.

- [ ] **T15 — Rational arithmetic and timestamps.** Depends on T05. It lands
  with T13 or the first container with several time bases.
  Reference: `libavutil/rational.c`, `libavutil/mathematics.c`
  (`av_rescale_q_rnd`, `av_compare_ts`, `av_rescale_delta`, `av_add_stable`).
  A general signed `Rational` with reduction and float-to-rational conversion
  for CLI input; comparisons across time bases; wrap-around helpers for 33-bit
  MPEG timestamps; audio timestamp smoothing as `av_rescale_delta` does it.
  Done when vectors from an exact rational oracle, including `i64` extremes,
  agree, and the values FFmpeg exposes (ffprobe timestamps) match on fixtures.

- [ ] **T16 — Codec and format descriptors, registries and probing.** Depends
  on T12. It lands when two formats need dispatch (T13 or T22).
  Reference: `libavcodec/codec_desc.c`, `allcodecs.c`,
  `libavformat/allformats.c`, `format.c` (`av_probe_input_format3`),
  `demux.c` (probe buffer).
  Codec IDs, media types and descriptor tables; compile-time validated
  registries of demuxers, muxers, decoders and encoders (duplicate names,
  signatures); content probing with scores over a bounded prefix that is
  retained and replayed, so non-seekable input still works; extensions and
  MIME types only as hints.
  Done when every implemented format is detected from content with the same
  winner as FFmpeg on the fixtures, including short and ambiguous inputs.

- [ ] **T17 — Options, metadata and diagnostics.** Depends on T16. It lands
  with the first component that has options (T21, T24 or T13).
  Reference: `libavutil/opt.c`, `dict.c`, `log.c`, `parseutils.c`, `eval.c`.
  Typed per-component options with range, default, unit and help metadata
  derived at compile time; string parsing for the CLI (SI suffixes such as
  `128k`, `hh:mm:ss.ms` durations, sizes, rates); a metadata dictionary for
  container and stream tags; a diagnostic sink passed explicitly, with levels,
  instead of a global `av_log`. Expression evaluation arrives with its first
  filter (T25).
  Done when parsing matches FFmpeg's accepted and rejected forms for the
  supported options (vectors from `parseutils.c`), and tags round-trip through
  a container (T21).

- [ ] **T18 — Bit readers and writers, VLC tables and checksums.** Depends on
  T01. It lands with its first consumer (T26).
  Reference: `libavcodec/get_bits.h`, `put_bits.h`, `golomb.h`, `vlc.c`,
  `libavutil/crc.c`, `md5.c`, `adler32.c`.
  MSB-first and LSB-first readers over slices with checked over-read and
  explicit padding rules; writers with flush; unary, Rice and exp-Golomb codes;
  VLC/Huffman tables built at compile time; the CRC variants FFmpeg uses
  (`std.hash.crc` where its parameters match), MD5 and Adler-32.
  Done when exhaustive and round-trip vectors pass, end-of-buffer reads are
  rejected in ReleaseFast, and checksums equal reference values.

- [ ] **T19 — Differential harness and frame hashes.** Depends on T14 and T18.
  Reference: `libavformat/framecrcenc.c`, `framehash.c`, `hashenc.c`,
  `tests/fate-run.sh`, `tests/Makefile`.
  Generalize `compare.py` into a per-feature harness. It compares FFmpeg's
  `framecrc`, `framemd5` and `streamhash` output with the same hashes from Zig
  (a small test tool, later `zffmpeg -f framecrc`), and normalized
  `ffprobe -of json` metadata. It adds an optional FATE sample sync on Linux
  with recorded provenance and visible skips.
  Done when the WAV path and T12's path run through it in CI, a missing
  required fixture fails, and an absent optional sample is reported as skipped.

## Milestone 5: audio formats and processing

- [ ] **T20 — Complete PCM codec family.** Depends on T12 and T14.
  Reference: `libavcodec/pcm.c`, `pcm_tablegen.h`, `libavutil/samplefmt.c`,
  `tests/fate/pcm.mak`.
  u8, s8, s16/s24/s32/s64 in both byte orders, f32/f64 in both byte orders,
  planar variants and G.711 A-law/µ-law, specialized at compile time over a
  small set of real formats.
  Done when every variant decodes and encodes bit-exactly against the
  reference, exhaustively for 8- and 16-bit formats and by vectors for wider
  ones, with short and misaligned input covered.

- [ ] **T21 — Complete WAV.** Depends on T17 and T20.
  Reference: `libavformat/wavdec.c`, `wavenc.c`, `riffdec.c`, `riffenc.c`,
  `w64.c`.
  WAVE_FORMAT_EXTENSIBLE (channel masks, subformat GUIDs), every T20 format,
  RF64/BW64 (`ds64`) reading and writing past 4 GiB, Sony Wave64, unknown-length
  input read to end of stream, LIST/INFO and `bext` metadata, seeking on
  seekable input; the writer switches to extensible and RF64 where `riffenc.c`
  does. Revise the [first WAV contract](port.md#first-wav-contract) and its
  fixtures through `generate.py`. Fixtures that become supported move from
  rejected to accepted; keep the intentional differences that remain.
  Done when the reference comparison covers every new variant and the formerly
  rejected fixtures match FFmpeg's output.

- [ ] **T22 — Raw PCM, AIFF and AU containers.** Depends on T16 and T20.
  Reference: `libavformat/pcmdec.c`, `pcmenc.c`, `rawenc.c`, `aiffdec.c`,
  `aiffenc.c`, `au.c`, `cafdec.c`.
  Raw demux and mux with explicit parameters (`-f s16le` and the rest);
  AIFF and AIFF-C (big-endian fields, the 80-bit extended sample rate converted
  exactly, PCM, A-law, µ-law and float compression types); Sun AU; CAF demux as
  a later step.
  Done when probing tells them apart, decoding matches the reference, and mux
  output is byte-exact where FFmpeg's is deterministic, with any header
  differences documented.

- [ ] **T23 — Sample format conversion and channel rematrixing.** Depends on
  T14 and T20.
  Reference: `libswresample/audioconvert.c`, `rematrix.c`, `swresample.c`,
  `dither.c`, `libavutil/channel_layout.c`.
  Conversions between all T20 formats, packed and planar, with FFmpeg's
  rounding and clipping; layouts beyond mono and stereo (5.1, 7.1, named and
  custom orders); the default upmix and downmix matrices with center and
  surround mix levels and normalization; dither as an option.
  Done when integer conversions are bit-exact against the reference, float
  conversions stay within a documented ULP tolerance, and generated matrices
  equal `swr_build_matrix` output for every supported layout pair.

- [ ] **T24 — Resampling.** Depends on T23.
  Reference: `libswresample/resample.c`, `resample_dsp.c` (soxr is external
  and excluded).
  The polyphase windowed-sinc resampler with swresample's defaults (filter
  size, phase count, Kaiser window, cutoff), linear interpolation, exact and
  arbitrary ratios, streaming with delay, drain and timestamp compensation.
  Done when output matches the reference within a measured, documented
  tolerance (bit-exact for s16 if reachable), delay and drain sample counts
  match, and any input chunking gives identical output.

- [ ] **T25 — Audio filter graph.** Depends on T14, T17, T23 and T24.
  Reference: `libavfilter/avfilter.c`, `avfiltergraph.c`, `graphparser.c`,
  `formats.c`, `buffersrc.c`, `buffersink.c`, `af_anull.c`, `af_aformat.c`,
  `af_aresample.c`, `af_volume.c`, `trim.c`, `af_amix.c`, `af_pan.c`,
  `libavutil/eval.c`; `tests/fate/filter-audio.mak`.
  Filter descriptors and options, format negotiation that inserts conversions
  where FFmpeg does, the filtergraph string syntax, push and pull scheduling
  with timestamps and EOF; first filters: anull, aformat, aresample, volume
  (with its expression subset), atrim, asetpts, amix, pan, channelmap and
  channelsplit.
  Done when each filter's output equals the reference's on fixtures (bit-exact
  or within its documented tolerance), negotiation inserts the same
  conversions, and EOF and drain propagate through the graph.

## Milestone 6: audio codecs

- [ ] **T26 — FLAC demux, decode and encode.** Depends on T16, T18 and T19.
  Reference: `libavformat/flacdec.c`, `flacenc.c`, `libavcodec/flacdec.c`,
  `flacenc.c`, `flac.c`, `flacdsp.c`, `flac_parser.c`; `tests/fate/flac.mak`.
  Native FLAC: STREAMINFO, SEEKTABLE, VORBIS_COMMENT and PICTURE blocks; frames
  with CRC-8/16; every subframe type; 4- to 32-bit depths; stereo decorrelation;
  variable block sizes; MD5 verification; seeking by seek table and frame scan.
  An encoder covers FFmpeg's compression levels (LPC with quantized
  coefficients, Rice partitions).
  Done when the FATE FLAC cases with available samples decode bit-exactly, and
  FFmpeg decodes the encoder's output to the original samples, at a compressed
  size recorded against FFmpeg's.

- [ ] **T27 — Ogg, the transform module and Vorbis.** Depends on T18 and T26.
  Reference: `libavformat/oggdec.c`, `oggparsevorbis.c`, `oggparseflac.c`,
  `oggparseopus.c`, `oggenc.c`, `libavcodec/vorbisdec.c`, `vorbis.c`,
  `libavutil/tx.c`; `tests/fate/vorbis.mak`.
  Ogg pages and packets with CRC, chained streams, granule positions to
  timestamps, bisection seeking on seekable input, and muxing FLAC, Vorbis and
  Opus. A native FFT/MDCT module (the `tx` sizes later codecs need) and a
  Vorbis I decoder (codebooks, floors 0 and 1, residues 0–2, coupling).
  Done when decoded output matches the reference within a documented tolerance,
  granule-derived timestamps match exactly, and damaged pages are reported per
  the contract.

- [ ] **T28 — Opus decoder.** Depends on T27.
  Reference: `libavcodec/opus/` (range decoder, SILK, CELT, hybrid),
  `libavformat/oggparseopus.c`; RFC 6716, RFC 7845, RFC 8251 test vectors;
  `tests/fate/opus.mak`.
  Range decoder, SILK (narrow to wide band), CELT, hybrid mode, packet framing,
  multistream channel mapping, pre-skip and end trimming at 48 kHz.
  Done when every RFC test vector meets the RFC's `opus_compare` criteria
  (ported natively into the harness) and output matches the reference within
  tolerance.

- [ ] **T29 — MPEG audio: MP1, MP2 and MP3.** Depends on T16 and T18.
  Reference: `libavformat/mp3dec.c`, `mp3enc.c`,
  `libavcodec/mpegaudiodec_template.c`, `mpegaudiodecheader.c`,
  `mpegaudio_parser.c`, `mpegaudiodsp*.c`, `mpegaudioenc*.c`;
  `tests/fate/mp3.mak`.
  Frame sync with resynchronization; ID3v1/ID3v2 tags into metadata;
  Xing/Info/LAME/VBRI headers for duration and gapless delay and padding;
  decoding Layers I–III (Huffman, requantization, stereo modes, IMDCT, alias
  reduction, polyphase synthesis); seeking by TOC; an MP2 encoder. There is no
  MP3 encoder, because FFmpeg relies on external LAME.
  Done when decoding matches the reference's float decoder within the FATE
  conformance tolerance and gapless trimming matches.

- [ ] **T30 — AAC decoder and ADTS.** Depends on T16, T18 and T27 (`tx`).
  Reference: `libavcodec/aac/`, `aacsbr*.c`, `aacps*.c`, `mpeg4audio.c`,
  `libavformat/aacdec.c`, `adtsenc.c`; `tests/fate/aac.mak`.
  ADTS demux and mux, AudioSpecificConfig parsing (shared with MP4 in T33),
  AAC-LC (sections, scale factors, spectral Huffman, M/S, intensity, PNS, TNS,
  windows, IMDCT), then HE-AAC v1 (SBR) and v2 (PS) as separate steps, with
  encoder delay handled. LATM is a later step.
  Done when LC, SBR and PS streams decode within tolerance of the reference.

- [ ] **T31 — ADPCM and ALAC.** Depends on T21 and T22; ALAC needs T33 or CAF
  from T22.
  Reference: `libavcodec/adpcm.c`, `adpcmenc.c`, `adpcm_data.c`, `alac.c`,
  `alacenc.c`; `tests/fate/adpcm.mak`, `alac.mak`.
  IMA (WAV and QuickTime) and Microsoft ADPCM decoding and encoding, and ALAC
  decoding and encoding.
  Done when every implemented variant is bit-exact against the reference.

- [ ] **T32 — AC-3/E-AC-3 decoding and native lossy encoders.** Depends on
  T25, T29 and T30.
  Reference: `libavcodec/ac3dec.c`, `eac3dec.c`, `ac3dsp.c`, `ac3enc*.c`,
  `aacenc*.c`, `libavformat/ac3dec.c`; `tests/fate/ac3.mak`.
  AC-3 and E-AC-3 decoding (common in video files); the AC-3 and AAC-LC
  encoders FFmpeg implements natively.
  Done when decoding is within tolerance of the reference, and FFmpeg decodes
  encoder output with bitrate and an objective quality metric recorded per
  encoder; byte equality is not required.

## Milestone 7: containers

- [ ] **T33 — MP4/MOV demuxer.** Depends on T14, T15, T16, T17 and T30.
  Reference: `libavformat/mov.c`, `isom.c`, `mov_chan.c`; `tests/fate/mov.mak`.
  Box parsing with nesting and size limits; sample tables (`stsz`, `stco`,
  `co64`, `stsc`, `stts`, `ctts`, `stss`); edit lists with FFmpeg's semantics;
  fragmented MP4 (`moof`, `trun`, `sidx`, `mfra`); metadata and chapters; codec
  configuration boxes (`esds`, `avcC`, `hvcC`, `dOps`, `dfLa`, ALAC); seeking by
  sync samples. A `moov` after `mdat` on non-seekable input is reported as
  unsupported.
  Done when packet timestamps, durations, sizes and flags equal the reference's
  (`-c copy -f framecrc` or `ffprobe -show_packets`) for audio-only, video,
  fragmented and edit-list fixtures.

- [ ] **T34 — MP4/MOV muxer.** Depends on T33.
  Reference: `libavformat/movenc.c`.
  Progressive output, `+faststart`, fragmented output (`frag_keyframe`,
  `empty_moov`, CMAF), edit lists for encoder delay, metadata.
  Done when FFmpeg demuxes our output to identical packets and timestamps.

- [ ] **T35 — Matroska and WebM.** Depends on T14, T15, T16 and T17.
  Reference: `libavformat/matroskadec.c`, `matroskaenc.c`, `matroska.c`;
  `tests/fate/matroska.mak`.
  EBML with element size and depth limits and unknown-size (live) elements;
  tracks, SimpleBlock and BlockGroup with Xiph, EBML and fixed lacing; cues;
  chapters and tags; codec private data; a WebM muxer for VP8, VP9, Opus and
  Vorbis, with cues.
  Done when demuxed packets equal the reference's and FFmpeg reads our output
  to identical packets.

- [ ] **T36 — MPEG-TS and MPEG-PS.** Depends on T14, T15 and T16.
  Reference: `libavformat/mpegts.c`, `mpegtsenc.c`, `mpeg.c`, `mpegenc.c`;
  `tests/fate/mpegts.mak`.
  TS sync and resync, PAT/PMT/SDT, PES assembly, PCR, continuity counters,
  33-bit timestamp wrap (T15), stream type mapping; a TS muxer with PCR and PSI
  repetition; PS demux and mux.
  Done when demuxed packets equal the reference's, including wrap-around and
  corrupted-packet fixtures, and FFmpeg demuxes our TS output identically.

- [ ] **T37 — Other containers, raw streams and bitstream filters.** Depends on
  T16 and T22; the H.264/HEVC filters need T33's configuration parsing.
  Reference: `libavformat/avidec.c`, `avienc.c`, `flvdec.c`, `flvenc.c`,
  `ivfdec.c`, `ivfenc.c`, `rawdec.c`, `rawenc.c`, `concatdec.c`,
  `libavcodec/h264_mp4toannexb_bsf.c`, `hevc_mp4toannexb_bsf.c`,
  `aac_adtstoasc_bsf.c`, `extract_extradata_bsf.c`.
  AVI (OpenDML past 1 GiB, index), FLV, IVF, raw elementary streams (Annex B
  H.264/HEVC, ADTS, MP3, FLAC), the concat demuxer, a null muxer, and the
  bitstream filters that stream copy between containers needs.
  Done when each matches the reference's packets and remuxed output demuxes
  identically in FFmpeg.

## Milestone 8: video foundations

- [ ] **T38 — Pixel formats, video frames and raw video.** Depends on T14.
  Reference: `libavutil/pixdesc.c`, `pixfmt.h`, `imgutils.c`, `frame.c`,
  `libavcodec/rawdec.c`, `rawenc.c`, `libavformat/yuv4mpegdec.c`,
  `yuv4mpegenc.c`, `rawvideodec.c`.
  Pixel format descriptors (components, planes, chroma shifts, depth, byte
  order, alpha); frame storage with alignment, arbitrary and negative strides
  and cropping; color properties (range, primaries, transfer, matrix, chroma
  location) and sample aspect ratio; image copy and fill helpers; the rawvideo
  codec; Y4M demux and mux.
  Done when plane sizes and line sizes equal `av_image_fill_*` for every
  supported format, and frames round-trip through Y4M and rawvideo bit-exactly
  against the reference.

- [ ] **T39 — Color conversion and scaling.** Depends on T38.
  Reference: `libswscale/` (input and output stages, `yuv2rgb.c`, `rgb2rgb.c`,
  filter initialization, the newer graph code).
  YUV↔RGB with BT.601, BT.709 and BT.2020 matrices and limited or full range;
  chroma resampling between 4:2:0, 4:2:2 and 4:4:4; bit-depth changes with
  FFmpeg's dithering; packed↔planar; point, fast-bilinear, bilinear, bicubic
  and Lanczos scalers with swscale's coefficient generation; `sws_flags`,
  including `accurate_rnd`, `full_chroma_int` and `bitexact`.
  Done when outputs match swscale run with `+bitexact+accurate_rnd`, exactly
  where it is deterministic and otherwise within a documented per-pixel
  tolerance, for every supported format pair.

- [ ] **T40 — Image formats and image sequences.** Depends on T18, T38 and T39.
  Reference: `libavcodec/pnmdec.c`, `pnmenc.c`, `bmp.c`, `bmpenc.c`,
  `pngdec.c`, `pngenc.c`, `gifdec.c`, `gif.c`; `libavformat/img2dec.c`,
  `img2enc.c`, `apngdec.c`, `apngenc.c` and its own `gifdec.c` and `gif.c`;
  `tests/fate/image.mak`.
  PNM family, BMP, PNG and APNG (filters, interlacing, palettes, 16-bit,
  gamma and ICC as side data), GIF decode and encode, and image2 sequences
  with numbered patterns. Glob patterns are matched natively, not through
  `glob(3)`. Before PNG, record the compression decision in port.md and
  notes.md: `std.compress.flate`, which is native Zig, or a project inflate and
  deflate.
  Done when decoded images equal the reference's bit-exactly and FFmpeg
  decodes our PNG, BMP and GIF output identically.

- [ ] **T41 — Video filters.** Depends on T25 and T39.
  Reference: `libavfilter/vf_null.c`, `vf_format.c`, `vf_scale.c`,
  `vf_crop.c`, `vf_pad.c`, `vf_hflip.c`, `vf_vflip.c`, `vf_transpose.c`,
  `vf_fps.c`, `setpts.c`, `trim.c`, `vf_aspect.c`, `vf_overlay.c`,
  `split.c`, `avf_concat.c`, `vf_yadif.c`; `tests/fate/filter-video.mak`.
  Video negotiation in the graph (pixel formats, automatic scale insertion);
  null, format, scale, crop, pad, hflip, vflip, transpose, fps, setpts, trim,
  setsar/setdar, overlay, split and concat, then yadif deinterlacing.
  Done when each filter's frame hashes (`-f framemd5`) equal the reference's.

## Milestone 9: video codecs

FFmpeg itself implements these natively. Bit-exact decoding is the target,
because FFmpeg's integer decoders are deterministic with `-flags +bitexact` and
its default IDCT.

- [ ] **T42 — JPEG and MJPEG.** Depends on T18, T38 and T40.
  Reference: `libavcodec/mjpegdec.c`, `mjpegenc.c`, `mjpegenc_common.c`,
  `jpegtables.c`, `simple_idct.c`, `jfdctint.c`.
  Baseline and progressive Huffman JPEG, restart markers, 4:2:0, 4:2:2, 4:4:4
  and gray, EXIF orientation as side data, FFmpeg's default IDCT, and a
  baseline encoder.
  Done when decoding is bit-exact against the reference and FFmpeg decodes our
  encoder's output to the same frames as our decoder.

- [ ] **T43 — H.264 decoder, part 1: syntax and intra.** Depends on T18, T33,
  T37 and T38.
  Reference: `libavcodec/h2645_parse.c`, `h264_ps.c`, `h264_sei.c`,
  `h264_slice.c`, `h264_cavlc.c`, `h264_mb.c`, `h264pred.c`, `h264idct.c`,
  `h264_parser.c`; `tests/fate/h264.mak` (JVT conformance).
  NAL parsing (Annex B and length-prefixed), SPS, PPS and SEI (VUI, color,
  timing), slice headers, POC types, CAVLC residuals, intra 4×4, 8×8, 16×16 and
  chroma prediction, inverse transforms; I slices in Constrained Baseline.
  Done when the I-only conformance streams decode with frame MD5s equal to the
  reference's.

- [ ] **T44 — H.264 decoder, part 2: inter, CABAC, Main and High.** Depends on
  T43.
  Reference: `h264_cabac.c`, `h264_mvpred.h`, `h264_direct.c`, `h264_refs.c`,
  `h264qpel*.c`, `h264chroma*.c`, `h264_loopfilter.c`, `h264dsp*.c`,
  `h264_picture.c`.
  P and B slices, motion vector prediction, quarter-pel luma and eighth-pel
  chroma motion compensation, direct modes, weighted prediction, reference list
  management (MMCO, long-term), DPB output order, deblocking, CABAC, 8×8
  transforms and scaling matrices, basic error concealment.
  Done when the progressive 8-bit 4:2:0 Baseline, Main and High conformance
  streams decode bit-exactly against the reference.

- [ ] **T45 — H.264 decoder, part 3: interlaced and extended formats.** Depends
  on T44.
  PAFF and MBAFF, and the High 10, High 4:2:2 and High 4:4:4 profiles.
  Done when the remaining applicable conformance streams pass.

- [ ] **T46 — VP8 and VP9 decoders.** Depends on T18, T38, and T35 or T37.
  Reference: `libavcodec/vp8.c`, `vp8dsp.c`, `vpx_rac.h`, `vp9*.c`,
  `vp9dsp*.c`, `vp9_superframe_split_bsf.c`; `tests/fate/vpx.mak`.
  VP8 (boolean decoder, intra and inter, loop filter, partitions), then VP9
  profile 0 and profile 2 (10-bit), superframes, tiles and scaled references.
  Done when the VP8 and VP9 test vectors in FATE decode bit-exactly.

- [ ] **T47 — HEVC decoder.** Depends on T44 (shared H.2645 parsing), T33, T35
  and T36.
  Reference: `libavcodec/hevc/`; `tests/fate/hevc.mak`.
  Main and Main 10: parameter sets, SEI, slices, CABAC, intra and inter
  prediction, transforms, deblocking, SAO, tiles and WPP (threading in T59).
  Done when the Main and Main 10 conformance streams in FATE decode bit-exactly.

- [ ] **T48 — MPEG-1/2 and MPEG-4 Part 2 video.** Depends on T38, T36 and T37.
  Reference: `libavcodec/mpeg12dec.c`, `mpeg12.c`, `mpeg12enc.c`,
  `mpegvideo*.c`, `mpeg4videodec.c`, `mpeg4videoenc.c`, `h263dec.c`,
  `idctdsp.c`.
  MPEG-1 and MPEG-2 (MP@ML and HL, interlaced and field pictures, 4:2:0 and
  4:2:2) decoding; MPEG-4 ASP decoding (quarter-pel, packed B-frames in AVI);
  the MPEG-2 and MPEG-4 Part 2 encoders.
  Done when decoding is bit-exact with the reference's default IDCT and FFmpeg
  decodes our encoders' output to the same frames as our decoder.

- [ ] **T49 — Lossless and intermediate video codecs.** Depends on T18 and T38.
  Reference: `libavcodec/ffv1dec.c`, `ffv1enc.c`, `ffv1.c`, `huffyuvdec.c`,
  `huffyuvenc.c`, `proresdec*.c`, `proresenc_kostya.c`, `dnxhddec.c`,
  `dnxhdenc.c`; `tests/fate/vcodec.mak`, `prores.mak`.
  FFV1 versions 1–3 (range coder, slices, CRC), HuffYUV and FFVHuff, then
  ProRes and DNxHD decoding and encoding as later steps.
  Done when lossless codecs round-trip exactly and every implemented decoder
  is bit-exact against the reference.

- [ ] **T50 — Subtitles.** Depends on T14, T33, T35 and T36.
  Reference: `libavformat/srtdec.c`, `srtenc.c`, `webvttdec.c`, `webvttenc.c`,
  `assdec.c`, `assenc.c`; in `libavcodec/`, the decoders and encoders of the
  same names plus `ass_split.c`, `movtextdec.c` and `movtextenc.c`;
  `tests/fate/subtitles.mak`.
  SRT, WebVTT and ASS demux and mux, conversion through an ASS-style internal
  form, `mov_text` in MP4 and text tracks in Matroska, stream copy with timing.
  Bitmap subtitles (DVB, PGS) come later.
  Done when converted text output equals the reference's.

## Milestone 10: tools and the public API

- [ ] **T51 — zffprobe: full probing and output writers.** Depends on T16, T17
  and the implemented formats.
  Reference: `fftools/ffprobe.c` and its text writers; `tests/fate/ffprobe.mak`.
  `-show_format`, `-show_streams`, `-show_packets`, `-show_frames`,
  `-show_entries`, `-select_streams`, `-count_frames` and `-read_intervals`,
  with the default and JSON writers first, as an FFprobe-compatible mode next
  to the stable output defined in [port.md](port.md#initial-probe-output).
  Done when JSON output equals the reference's after documented normalization
  for every supported format.

- [ ] **T52 — Seeking, stream copy and timestamp correctness.** Depends on T15
  and T33–T37.
  Reference: `libavformat/seek.c`, `demux.c`, `mux.c`, `mux_utils.c`;
  `tests/fate/seek.mak`.
  Keyframe and accurate seeking (decode and discard), index building, timestamp
  wrap detection, start time and negative timestamps (`avoid_negative_ts`),
  edit-list-aware copy, remuxing between every supported container pair.
  Done when the FATE seek-equivalent tests pass and every pair in the remux
  matrix demuxes identically in FFmpeg.

- [ ] **T53 — zffmpeg: transcoding pipeline and CLI.** Depends on T13, T25,
  T41, T52 and the implemented codecs and formats.
  Reference: `fftools/ffmpeg.c`, `ffmpeg_opt.c`, `ffmpeg_demux.c`,
  `ffmpeg_dec.c`, `ffmpeg_filter.c`, `ffmpeg_enc.c`, `ffmpeg_mux.c`,
  `ffmpeg_mux_init.c`, `ffmpeg_sched.c`, `cmdutils.c`, `opt_common.c`;
  `tests/fate/ffmpeg.mak`.
  Several inputs and outputs; `-map` and default stream selection; `-c` and
  `-c copy`; `-f`; codec and format options; `-af`, `-vf` and
  `-filter_complex`; `-ss`, `-t` and `-to` on input and output; `-ar`, `-ac`,
  `-sample_fmt`, `-r`, `-s`, `-pix_fmt` and `-b`; metadata and chapter mapping;
  interleaving by DTS; timestamp options (`-copyts`); progress output;
  cancellation through `std.Io`; `-y`/`-n`; exit codes. A scheduler with
  bounded queues that follows port.md's progress rule.
  Done when an end-to-end command matrix (T13's operation matrix, extended)
  produces output the reference judges equivalent (frame hashes), and option
  errors match documented messages.

- [ ] **T54 — Public Zig API and examples.** Depends on T14, T16, T17 and T53.
  Reference: `doc/examples/decode_audio.c`, `decode_video.c`,
  `demux_decode.c`, `encode_audio.c`, `mux.c`, `remux.c`, `transcode.c`.
  A stable `av` facade: open input from a path, file or reader; stream
  discovery; decoders and encoders with send/receive; filter graphs; muxers.
  Examples in `zig/examples/` that mirror `doc/examples`, generated API
  documentation (`getEmittedDocs`) published by CI, and a versioning and
  deprecation policy for the package.
  Done when every example builds and is tested in CI and the API reference is
  generated.

- [ ] **T55 — Build-time component selection.** Depends on T16 and T54.
  Reference: `configure` (component lists, `--enable-*`/`--disable-*`,
  `_select` and `_deps`), `allcodecs.c`, `allformats.c`.
  Build options that select codecs, formats and filters through the
  compile-time registries, with dependency checks (a demuxer pulls its parsers)
  and disabled components left out of the binary.
  Done when CI builds a minimal and a full configuration and a disabled
  component is absent from both the registry and the binary.

- [ ] **T56 — Optional C ABI adapter.** Depends on T54. Only when a consumer
  needs it (port.md: a separate, optional adapter).
  A C-callable subset in `zig/compat/` with opaque handles and error codes and
  no libav* struct layouts, built as its own library artifact. Its tests may
  use a small C program in a separate test step.
  Done when the chosen subset is documented and tested. Leave this unchecked,
  with the reason, if no consumer appears.

## Milestone 11: performance and hardening

- [ ] **T57 — Benchmarks and performance baselines.** Depends on T19 and any
  implemented decoder.
  Reference: `-benchmark`, `tests/checkasm/` (bench mode).
  `zig build bench` in ReleaseFast for kernels and end-to-end decoding and
  encoding: throughput, peak memory and allocation counts, measured against
  the C-only reference and against an asm-enabled FFmpeg build kept only for
  benchmarks. Results are recorded per commit.
  Done when every implemented codec has a recorded baseline and regressions are
  reported (not failing CI until the numbers are stable).

- [ ] **T58 — SIMD kernels.** Depends on T57.
  Reference: `libavcodec/x86/`, `aarch64/` (algorithms only),
  `tests/checkasm/`.
  Portable `@Vector` versions of measured hot spots (transforms and IDCTs,
  motion compensation, deblocking, PCM conversion, resampler FIR, color
  conversion, CRC), each with a checkasm-style test against the scalar
  version over random inputs, tails and alignments, and a scalar fallback.
  No inline assembly or target intrinsics during the Linux-only phase.
  Done when each kernel is bit-identical to scalar (or within a documented
  float tolerance) and its benchmark shows a measured gain.

- [ ] **T59 — Threading.** Depends on T53 and T57, and on slice-capable codecs
  (T44, T47 or T49).
  Reference: `libavcodec/pthread_frame.c`, `pthread_slice.c`,
  `fftools/ffmpeg_sched.c`.
  Slice and frame threading for decoders that support it, slice threading in
  encoders (FFV1) and filters (scale), and parallelism between demux, decode,
  filter, encode and mux. All of it goes through the injected `std.Io` (`Io.Group`,
  `Io.async`, `Io.concurrent`); cancellation and errors propagate across
  workers.
  Done when output is identical for 1 to N threads, throughput scales on the
  benchmark set, and cancellation stress tests pass in ReleaseSafe.

- [ ] **T60 — Sustained fuzzing and resource limits.** Depends on T19 and each
  parser and decoder.
  Reference: `tools/target_dec_fuzzer.c`, `tools/target_dem_fuzzer.c`.
  A fuzz entry for every demuxer, parser and decoder, seeded from fixtures and
  FATE samples; a scheduled Linux CI job running `zig build --fuzz` for a time
  budget; every crash or timeout becomes a committed regression fixture; global
  limits (dimensions, packet and frame size, allocation, probe size) enforced
  in ReleaseFast.
  Done when every component has a fuzz entry, the scheduled job has run cleanly
  for a recorded duration, and every finding has a regression test.

- [ ] **T61 — FATE-equivalent regression suite.** Depends on T19 and the
  implemented features.
  Reference: `tests/fate/*.mak`, `tests/ref/fate/`.
  Map each relevant FATE test to a native equivalent with the same input and
  hashes regenerated from the pinned reference build. It runs with the
  optional sample sync on Linux and produces a coverage report: ported, skipped
  (sample missing) and not applicable.
  Done when the report covers every implemented codec and format and CI
  publishes it.

## Milestone 12 (long-term): platforms and release

Start these only when milestones 4–10 are largely complete. Until then the
platform policy above applies.

- [ ] **T62 — Native Windows verification.** Depends on the end of the
  Linux-only phase.
  A Windows x86-64 CI job (`windows-latest`) running the build and every test in
  Debug, ReleaseSafe and ReleaseFast; fixes for what the portable-code rules did
  not prevent (paths, console stdio, file sharing, error names). Reference
  comparisons stay on Linux. Neither Wine nor a cross-compile counts.
  Done when the full suite passes natively and any platform differences are
  documented.

- [ ] **T63 — ARM, macOS and big-endian verification.** Depends on T62 or runs
  alongside it.
  Native AArch64 Linux (for example `ubuntu-24.04-arm`) and AArch64 macOS
  (`macos-latest`) jobs in all three modes. SIMD kernels are checked against
  scalar on each. A big-endian target runs under QEMU user mode to check
  byte-order code.
  Done when the suite passes natively on each platform and SIMD fallbacks are
  exercised.

- [ ] **T64 — Release engineering.** Depends on T54, T62 and T63.
  Versioned releases with a changelog, binaries for the verified platforms, the
  package published for `build.zig.zon` consumers, a license and provenance
  audit of every derived file, and a security policy for fuzz findings.
  Done when a tagged release builds reproducibly in CI.

## Not planned

These stay out unless a recorded decision adds them:

- External, GPL or nonfree libraries and wrappers around them (x264, x265,
  libvpx, libdav1d, libaom, LAME, fdk-aac, libopus, OpenSSL and the like).
- Encoders FFmpeg does not implement natively: H.264, HEVC, VP8/VP9 and AV1
  software encoders, and MP3. Software AV1 decoding, which FFmpeg gets from
  libdav1d; a native AV1 decoder would go beyond FFmpeg's own tree, so
  reconsider it after T47.
- Hardware acceleration (VAAPI, VDPAU, NVDEC/NVENC, QSV, VideoToolbox,
  D3D11VA, Vulkan video).
- `libavdevice` capture and playback (ALSA, PulseAudio, V4L2, DirectShow,
  AVFoundation) and ffplay, which needs SDL. They are platform-specific; revisit
  after T62/T63.
- Network protocols and streaming (HTTP(S), RTMP, RTSP, SRT, HLS, DASH).
  `std.http` makes HTTP(S) input feasible later; scope it as its own task.
- Filters that need external libraries (drawtext, subtitles, zscale,
  libplacebo), and the long tail of filters beyond those listed above.
- FFmpeg C API/ABI compatibility beyond T56's optional subset.

For every task, apply the [feature completion workflow](port.md#feature-completion-workflow).
Keep tasks focused on tested behavior and readable native Zig code; completion
is not measured by how many C files have been translated.
