# Native Zig port: implementation checklist

This is the execution checklist for [port.md](port.md). The plan explains the
architecture and compatibility rules; this file records the work to do next.
The repository tracks project documentation, the minimal Zig package and build
(the `av` module, documented in [zig/README.md](zig/README.md)), two tested
standalone Zig examples and a Linux CI workflow. FFmpeg and zigimg are
independent clones in ignored `.references/`; see
[README.md](README.md#clone-the-reference-repositories) for setup. There is no
codec/container implementation yet.

**Next tasks: T02 — materialize the WAV contract and fixtures, and T03 — the C
reference setup (independent of T02). T04 and T05 need T01 and T02.**

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
  an implemented codec. The kernel now lives in [pcm_s16.zig](zig/examples/pcm_s16.zig)
  and runs in Linux CI. See [the example](port.md#example-one-pcm-kernel-two-byte-orders).
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

- [ ] **T02 — Materialize the WAV contract and fixtures.** Create the canonical
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

- [ ] **T03 — Establish the C reference comparison setup.** Use Linux x86-64 in
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

- [ ] **T04 — Implement the PCM sample conversion kernels.** Depends on T01 and
  T02. Add typed slice-based signed 16-bit decoding and encoding with explicit
  byte order and destination capacity. Start with the needed specialization;
  retain a scalar implementation and document ownership/overlap rules. Done
  when independent vectors cover signed extrema, empty input, incomplete
  samples, insufficient output and the documented failure-mutation behavior.
  Promote the kernel/tests from [pcm_s16.zig](zig/examples/pcm_s16.zig) into
  `zig/codec/pcm.zig` and update the port.md source link; record applicable
  per-file license/provenance.

- [ ] **T05 — Add only the audio/time types needed by this path.** Depends on T01
  and T02. Represent sample rate, channel count/order, interleaving and borrowed
  samples clearly. Derive timing from integer sample-frame counts; define the
  required time-base/rescaling behavior. Done when zero/invalid rates, channel
  alignment, rounding and overflow boundaries are covered. Defer general frame
  ownership, reference counting and compressed bit readers until needed.

## Second milestone: a complete WAV/PCM path

- [ ] **T06 — Implement one bounded WAV parser.** Depends on T02 and T05. Accept
  `*std.Io.Reader`, initially tested with `Reader.fixed`; read exact fields into
  local arrays instead of casting structs. Implement T02's complete contract,
  including validation after data and contextual EOF/error mapping. Use checked
  size arithmetic in every optimization mode. Add a bounded `std.testing.fuzz`
  entry using `Smith`, plus deterministic fixture regressions; sustained fuzzing
  remains later work. Done when all contract cases pass in Debug, ReleaseSafe
  and ReleaseFast, including empty/short buffers, and the fuzz entry runs.

- [ ] **T07 — Connect the same parser/kernel to file and sequential I/O.** Depends
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

- [ ] **T08 — Implement known-length WAV writing.** Code prerequisites: T04,
  T05 and T07; T03 is a completion gate. Accept `*std.Io.Writer` plus the expected
  frame count for memory and file/stream output. Emit exact sizes up front with
  a 16-byte tag-1 `fmt `; no seeking or placeholders. Check all sizes with
  `std.math.add/sub/mul` or overflow builtins, including the total RIFF extent.
  `finish` validates the frame count and flushes output. Done when under/overrun,
  overflow and write/flush failures are tested and the reference decodes generated
  files to the expected samples/metadata, including empty and high-rate cases.

- [ ] **T09 — Add the minimal `zffprobe` tool.** Depends on T06 and T07. Use
  `main(init: std.process.Init)` and the output schema/status codes in port.md.
  Keep parsing in the library; produce stdout only after complete validation,
  with diagnostics on stderr. Cleanup/flush must precede explicit process exit.
  Done when separate executable runs capture/test both streams and status for
  valid, empty, malformed, unsupported, I/O and resource-limit cases. Do not
  print CLI output inside the unit-test runner.

- [ ] **T10 — Verify the whole first path.** Depends on T03 and T07–T09. Compare
  decoded samples, metadata and timing with the recorded reference; validate
  generated WAV externally as well as by self round trips. Exercise truncated
  headers/data, malformed lengths, partial I/O, resource limits and cleanup on
  failure for allocating paths. Report optional external corpus skips separately;
  missing required fixtures fail the run. Done when results and intentional
  differences are recorded and every supported operation has reproducible evidence.

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
