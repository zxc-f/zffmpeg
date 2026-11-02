# Native Zig FFmpeg port

## Project intent and current state

This standalone repository is becoming a native Zig implementation of FFmpeg's
multimedia functionality. Implement algorithms and APIs in Zig; compiling FFmpeg's C with
`zig cc`, translating headers, or wrapping libav* does not constitute the port.

Read [port.md](port.md) before architectural work. It records the inspected
upstream revision, source map, proposed module boundaries, metaprogramming
patterns, milestones, and acceptance criteria.

Use [TODO.md](TODO.md) for the current implementation queue. Mark tasks complete
only with recorded evidence; update port.md when feature-level status changes.

Current state: design documents, two tested standalone examples (I/O patterns
and a PCM s16 kernel) and a Linux CI workflow that checks them; no native
multimedia library build or codec/container implementation yet. See TODO.md for
tasks and port.md for verified capabilities. Update the README, plan, checklist
and agent guidance when T01 introduces the build. The ignored FFmpeg clone
remains the behavior reference.

## Repository map

- `README.md`: project setup and pinned clone commands for both references.
- `port.md`, `TODO.md`: design/feature evidence and the authoritative task queue.
- `doc/zigimg-reference.md`: pinned zigimg analysis and adopted Zig patterns.
- `.references/ffmpeg/`: ignored FFmpeg behavior/reference clone.
- `.references/zigimg/`: ignored Zig implementation reference; no build dependency.
- `zig/examples/io_patterns.zig`, `zig/examples/pcm_s16.zig`: tested standalone
  examples; other native files are planned.
- `.github/workflows/ci.yml`: Linux-only CI; native Windows CI is deferred (T11).
- `LICENSE`: LGPL v2.1 text for the `LGPL-2.1-or-later` project sources.

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

Clone both upstream repositories using [README.md](README.md#clone-the-reference-repositories)
before source research. Keep them under the ignored `.references/` directory;
do not commit their files, Git metadata or gitlinks. They are not submodules.
New Zig implementation files belong under `zig/`, with a future root `build.zig`
and `build.zig.zon`. Preserve reference attribution/licenses and existing user
changes.

## Toolchain and architecture

- Baseline: Zig **0.17.0** on PATH. `.zig-version` is a tooling convention and
  `minimum_zig_version` is package metadata; neither is an exact compiler check.
  T01 must enforce the tested version in the build/automation; upgrade deliberately.
- Check installed standard-library sources and versioned official documentation
  before adopting build, I/O, or reflection APIs from older examples. Resolve
  disagreements by compiling a minimal check with the pinned toolchain.
- Start with one package and one named library module, `av`. Use ordinary
  file imports internally. Split named modules only for a demonstrated need,
  such as publishing a subset; keep imports acyclic and shared types minimal.
- The default build must compile an artifact; the test step must execute tests.
  Use an explicit package `.paths` allowlist excluding the reference C tree.
- Keep the public Zig API small, typed, and independent of C struct layouts.
  Add any C ABI compatibility later as a separate adapter.
- Pass allocators and I/O dependencies explicitly. Document whether slices and
  frames are borrowed, owned, shared, or transferred, and their lifetimes.
- Use the pinned [zigimg analysis](doc/zigimg-reference.md) as implementation
  evidence. `std.Io` belongs at OS boundaries; memory parsing needs only Reader/
  Writer interfaces, and allocation-free kernels need neither an allocator nor I/O.
- Keep PCM kernels on slices. Parse WAV through `*std.Io.Reader`, starting with
  `Reader.fixed` tests. Use exact reads into local field buffers to handle tiny
  input fragments; do not retain reader-buffer views across subsequent reads.
  A failed exact read may have consumed part of a field; treat it as terminal.
  Encode output fields into local arrays and call `writeAll`; do not rely on
  `Writer.writeInt` working with buffers smaller than its documented minimum.
- Borrow `.interface` from a stable file adapter and reuse that adapter across
  reads. Preserve its scratch-buffer lifetime and detailed `.err` diagnostics;
  reconstructing it can lose read-ahead bytes. Keep seekability optional.
- Distinguish malformed input, unsupported functionality, end of stream, and
  backpressure. Preserve timestamp, rounding, draining, and seek semantics.
- Implement portable scalar behavior first. Add SIMD or architecture-specific
  kernels only with comparisons against the scalar implementation.

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

## Working and validation

Inspect source with `rg` and read the corresponding implementation, header,
Makefile feature/dependency entries, and relevant tests before porting behavior.
Port a small working path at a time. The first proposed path is a bounded
RIFF/WAV PCM signed 16-bit little-endian reader/decoder/writer, then a probe CLI.

No project Zig build exists yet. T01 must document setup in `zig/README.md` and
provide `zig build`, `zig build test`, and
`zig fmt --check build.zig build.zig.zon zig/`. Check Debug and ReleaseSafe;
run parser/size tests in ReleaseFast once implemented to verify explicit checks.
Until then, do not report those project commands as passing. The standalone
examples can be checked now with `zig fmt --check zig/` and
`zig test zig/examples/<name>.zig` in Debug, ReleaseSafe and ReleaseFast; the
Linux CI workflow runs the same checks. When T01 lands, add the build commands
to that workflow.
The C reference uses `configure` and Make, not Zig's build system.

For implemented multimedia behavior, use hand-checked vectors and differential
tests against a recorded FFmpeg revision/configuration. Check decoded content,
metadata, timestamps, failure cases, and resource cleanup. Bit-exact results are
appropriate for integer/lossless paths; define justified tolerances for floating
point or lossy paths. Test round trips against an independent reference as well
as the port. Run relevant FATE cases only when their prerequisites are present.
Required local fixtures must fail when missing. Report skips from optional
external corpora explicitly; a passing run with skips is not complete coverage.

Record each completed feature in port.md with source provenance, supported
subset, tests run, and remaining limitations. For each new file, record its
applicable license and, if derived, upstream path/revision and attribution;
preserve the actual notices instead of assigning one SPDX tag indiscriminately.
Keep optional GPL/external components explicit. Use descriptive future commit
subjects; do not rewrite existing history as part of documentation work.
