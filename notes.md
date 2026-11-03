# Revisable decisions

Project choices that could reasonably change later. None of them is a fact
about FFmpeg or Zig; each was picked to keep the first WAV/PCM path small,
strict and testable. Every entry names where the choice lives, so a change can
update all of those places together and re-run the affected checks.

Authoritative details stay where they are: the WAV contract in
[port.md](port.md#first-wav-contract), its fixtures and precedence in the
[fixture README](zig/testing/fixtures/README.md), tasks in [TODO.md](TODO.md).
When you make a new revisable decision, add it here in the same change.

## Toolchain and build

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Compiler version | Exactly Zig 0.17.0. A comptime check in `build.zig` rejects any other compiler, because the std API moves between releases. | Update `tested_zig_version` in `build.zig`, `.minimum_zig_version` in `build.zig.zon`, `.zig-version`, the CI `version:` and version check, and the docs; validate the new std APIs first ([guide](doc/zig-0.17-guide.md)). |
| Module layout | One package, one `av` module rooted at `zig/root.zig`. | Split named modules only for a demonstrated need, such as publishing a subset; keep imports acyclic. |
| Library artifact | Static `libzffmpeg.a`, named after the package so it does not look like an FFmpeg or Libav library. | `addLibrary` in `build.zig` (name, `.linkage`); [zig/README.md](zig/README.md). |
| Package identity | Name `zffmpeg`, version `0.0.0`, toolchain-generated fingerprint. | Version can change freely; the fingerprint changes only for a fork that becomes a separate package. |
| Package contents | `.paths` lists `build.zig`, `build.zig.zon`, `zig/`, `LICENSE`, `README.md`. `zig/` includes test fixtures and `generate.py`. | Narrow `.paths` if packaging should exclude test data; never use `""`. |
| Dependencies | None: no package dependencies, C sources, libc or translate-c. | Add one only with a recorded decision in port.md; a C library never counts as ported functionality. |
| Example registration | Examples are listed explicitly in `build.zig`; CI fails on an unregistered `zig/examples/*.zig`. | Keep explicit; the CI guard can go if examples move into the `av` test tree. |
| Test filter | `-Dtest-filter` applies to every test artifact. | `build.zig` option. |

## CI

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Platforms | Linux only (`ubuntu-24.04`). Native Windows CI is deferred (T11). | Add a `windows-latest` job, or a recorded local Windows script, when Windows evidence is needed. |
| Build modes | `zig build` in Debug and ReleaseSafe; `zig build test` in Debug, ReleaseSafe and ReleaseFast. ReleaseFast runs without safety checks, so parser checks must be explicit. | `.github/workflows/ci.yml`. |
| Actions | `actions/checkout` v6.1.0 and `mlugg/setup-zig` v2.2.1, pinned by commit SHA. `setup-zig` targets Node 20, which GitHub runs on Node 24 with a deprecation warning. | Bump both SHAs together when a newer `setup-zig` release targets Node 24. |
| Example tests | Standalone per-file `zig test` loops were dropped from CI; `zig build test` covers the examples. | Re-add them if examples ever depend on build options. |

## License

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Project license | `LGPL-2.1-or-later` for original sources, matching FFmpeg's default; the root `LICENSE` holds the LGPL v2.1 text, so GitHub shows LGPL for the repository. | A different license needs every SPDX header, `LICENSE` and the README provenance sections changed; derived files keep their upstream notices regardless. |

## Test fixtures

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Generator language | Python 3, standard library only, so fixtures are built independently of the Zig code and can be generated where no Zig is installed. CI needs `python3`. | Rewrite `generate.py` in Zig if Python becomes a burden; keep the bytes identical so hashes still match. |
| Committed outputs | `.wav` files, `manifest.zon` and the README table are generated and committed; `--check` fails on drift. `.gitattributes` keeps `.wav` binary. | Generating at build time would remove committed binaries but needs a Zig build step and loses the independent generator. |
| Large vectors | The 2 MiB skip vector is described and hashed but built at test time, to keep the repository small. | Commit it if build-time construction proves error-prone. |
| Failure names | The `Failure` enum uses the contract's error names (`InvalidRiff`, ...) rather than snake_case, so tests can compare with `@errorName`. | `zig/testing/fixtures.zig` and `generate.py` together. |

## WAV contract

All of these are stricter than FFmpeg's `wavdec.c`, which ignores `riff_size`,
stops at end of input and accepts more variants. Each change needs `generate.py`
rerun, the [fixture README](zig/testing/fixtures/README.md) decisions table and
port.md's contract table updated, and (after T06) the parser.

| Decision | Current choice and reason | Fixtures |
| --- | --- | --- |
| Supported subset | Little-endian RIFF/WAVE, tag 1, signed 16-bit, mono or stereo only; everything else is `UnsupportedFormat`. Widen it as kernels and channel layouts land (T12). | `fmt_*`, `rifx_*`, `rf64`, `bw64`, `w64` |
| `fmt ` sizes | 16, or 18 with `cbSize == 0`. Fewer than 16 declared bytes is `InvalidFormat`; other sizes are `UnsupportedFormat`. | `fmt18_cbsize0`, `fmt_size_14`, `fmt20_cbsize2`, `fmt_extensible` |
| `byte_rate` | Ignored, even when inconsistent, because decoding never uses it and real files get it wrong. | `byte_rate_mismatch` |
| Sample-rate limit | 192,000 Hz default; above it is `LimitExceeded`. A configurable policy limit, not a format rule. | `mono_192k_rate_limit`, `fmt_rate_over_limit` |
| Chunk-count limit | 4,096 chunks including `fmt ` and `data`; the 4,097th is `LimitExceeded`. | `chunks_at_limit`, `chunks_over_limit` |
| Retained-bytes limit | 1 MiB of non-audio bytes the parser keeps; skipped chunk bodies do not count, so large `LIST`/`id3 ` chunks stay readable. | `large_skip_2mib` (synthesized) |
| Streaming work buffer | 64 KiB default; no whole-file allocation. | None yet (T07) |
| Unknown sizes | `riff_size` 0 or 0xFFFFFFFF and `data` size 0xFFFFFFFF are `UnsupportedStreamingSize`; unknown-length streaming WAV is out of scope. `data` size 0 is an empty stream. | `riff_size_*`, `data_size_unknown`, `empty_data` |
| Extent bounds | A chunk running past the RIFF extent, or fewer than 8 bytes left for a header, is `InvalidRiff`; input shorter than the extent is `Truncated`; bytes after it are ignored. FFmpeg tolerates all of these. | `*_exceeds_riff_extent`, `partial_chunk_header_in_extent`, `riff_size_exceeds_input`, `trailing_bytes_after_riff` |
| Final pad byte | A pad byte outside the extent is not read (accepted); one inside the extent but missing is `Truncated`. | `odd_final_chunk_pad_*` |
| Duplicates and order | Exactly one `fmt ` before exactly one `data`; a second `fmt ` (which FFmpeg ignores) or `data` is `InvalidWave`. | `duplicate_*`, `data_before_fmt`, `missing_data`, `no_chunks` |
| Partial frames | A `data` size that is not a multiple of `block_align` is `InvalidFormat` (FFmpeg drops the partial frame). | `data_not_block_aligned` |
| Error precedence | First violation in stream order; within `fmt `, tag, bits, channels, rate, `block_align`, then size. | `rifx_truncated`, `fmt_unsupported_before_invalid`, `data_size_unknown` |
| Partial output | Errors found after audio was produced are still reported; output is not atomic. | `duplicate_data`, `chunk_exceeds_riff_extent` |

## Writer

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Header format | Always a 16-byte tag-1 `fmt `, including above 48 kHz where FFmpeg writes WAVE_FORMAT_EXTENSIBLE. Compare decoded samples and metadata with FFmpeg, not header bytes. | Writer-output fixtures (`stereo_96k_tag1`, `mono_192k_rate_limit`) and T08. |
| Known length | The frame count is required up front; exact sizes are written with no seeking or placeholder sizes. | T08; streaming output would need seekable writers or placeholder patching. |

## PCM, audio and time types

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Public API shape | `zig/root.zig` exports flat namespaces `av.pcm`, `av.audio` and `av.time`. | Reorganize before external users depend on the names. |
| PCM kernel API | `decodeS16` / `encodeS16` over caller slices, byte order as a `comptime` parameter (both orders exist). Scalar only; no SIMD yet. | Add SIMD kernels only with comparisons against the scalar ones (port.md). |
| Kernel failures | A failing call writes nothing; input and output must not overlap, asserted only in Debug and ReleaseSafe. | `zig/codec/pcm.zig` docs and tests. |
| Rounding | Callers always pass a `Rounding`; there is no implicit default. FFmpeg's `av_rescale_q` uses `nearest`. | Add a defaulting helper in `zig/core/time.zig` if call sites repeat `.nearest`. |
| Rescale edge cases | Exact `i128` arithmetic. Overflow is `error.Overflow` (FFmpeg returns INT64_MIN) and `minInt(i64)` rescales exactly (FFmpeg treats it as -INT64_MAX). | `rescale` and its tests; T03/T10 differential checks should expect these two differences. |
| Time-base range | `TimeBase` has positive `u32` fields, unlike FFmpeg's signed `int` `AVRational`; negative or zero time bases are rejected. | Widen the fields if a format needs time bases beyond `u32`. |
| Missing timestamps | `?i64` (`null`), never a sentinel such as `AV_NOPTS_VALUE`. | Every API that carries timestamps. |
| Channel layouts | Only `mono` (front center, as in FFmpeg) and `stereo` (front left, front right). Other counts are `UnsupportedChannelCount`. | Add layouts with their channel order when a format needs them. |
| Sample-rate policy | `audio.Format` accepts any nonzero `u32` rate; the 192 kHz cap is WAV-parser policy. | Keep limits in the parser's configurable options. |
| Example promotion | The former `zig/examples/pcm_s16.zig` was moved into `zig/codec/pcm.zig`; examples now cover only I/O patterns. | Re-add examples only for patterns not shown by library code. |

## WAV parser, writer and file adapters

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Parser API | `wav.Parser`: `readHeader`, `readSamples`, `finish`; `wav.probe` validates without decoding and `wav.decodeToRaw` streams raw s16le. Validity requires `finish`, which skips unread data and checks the rest of the extent. | `zig/format/wav.zig`; a resumable or seeking parser would be a separate API. |
| Working storage | 4 KiB on the stack per read or write call; no allocator anywhere in the WAV path. The 64 KiB figure is the recommended file-adapter buffer (`file.default_buffer_len`). | Raise `scratch_len` only with a measured benefit. |
| Configurable limits | `wav.Limits` exposes `max_sample_rate` (192 kHz) and `max_chunks` (4,096). The 1 MiB retained-bytes limit has no knob because the parser keeps only the `fmt ` fields. | Add a field when the parser starts retaining metadata. |
| Writer limits | `wav.Writer.begin` rejects rates above `Limits.max_sample_rate` (`LimitExceeded`) and sizes beyond 32 bits (`SizeOverflow`) before writing anything; frame-count errors leave the writer usable. | `zig/format/wav.zig` and its tests. |
| File reading | Always `readerStreaming`, never positional reads, so files and pipes take one code path. | `zig/io/file.zig`; positional reads could help only a future seeking parser. |
| Error detail | File adapters return the file's own error (for example `NotOpenForReading`, `Canceled`) instead of `IoFailure`/`WriteFailed`. | `withReadCause` / `withWriteCause` in `zig/io/file.zig`. |
| Namespace | The adapters are `av.file`. | Rename before external users depend on it. |

## zffprobe and the FFmpeg reference

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Arguments | Exactly one path, or `-` for standard input; `-h`/`--help` prints help. No options yet. | `zig/cli/probe.zig` and the `probe_cases` in `build.zig`. |
| Diagnostics | One stderr line, `zffprobe: <path>: <ErrorName>`, using Zig error names rather than prose, so tests and scripts can match them. | Same places; `compare.py` matches the error name too. |
| Exit-code mapping | Contract errors map to 2, 3 or 5; `OutOfMemory`, `SystemResources` and descriptor-quota errors to 5; `Canceled` to 6; every other error to 4 (I/O). | `exitCode` in `zig/cli/probe.zig`. |
| CLI tests and filters | The 15 process cases run in `zig build test` but are skipped when `-Dtest-filter` is given. | `build.zig`. |
| Reference build | Linux x86-64, Clang, minimal LGPL configuration, `--disable-x86asm` (the C paths are the reference; no NASM dependency), built out of tree and cached in CI under a key from the Clang version and the build script. | `zig/testing/reference/build-ffmpeg.sh`; changing it or the runner's Clang rebuilds the cache. Update the recorded values in `zig/testing/reference/README.md`. |
| Reference job | Runs on every pull request and push to `master`, after the first build only from the cache. | `.github/workflows/ci.yml`; move it to a schedule if it gets slow. |
| Known FFmpeg differences | `compare.py` accepts exactly two metadata differences on accepted fixtures: `channel_layout=unknown` (a plain WAV header has no channel mask) and `duration_ts=N/A` for `empty_data` (FFmpeg reads data size 0 as unknown length). Any other value fails. FFmpeg's verdict on rejected fixtures is recorded, not checked. | `KNOWN_FIELD_DIFFERENCES` and `KNOWN_FIXTURE_DIFFERENCES` in `compare.py`, and the reference README. |
| Writer verification | FFmpeg decodes the writer-output fixtures, and the writer is tested to produce those exact bytes; that pair stands in for FFmpeg decoding writer output directly. | Add a writer CLI (T13) to feed its output to FFmpeg directly. |

## Probe output

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Output schema | Our own `key=value` lines in a fixed order, not FFprobe-compatible output; FFprobe compatibility is a separate future mode. | port.md "Initial probe output", T09 tests. |
| Duration | Unreduced in the stream's time base: `duration_num = nb_samples`, `duration_den = sample_rate`. | port.md and T09; a reduced fraction or decimal seconds would change every expected output. |
| Exit codes | 0 success/help, 1 usage, 2 invalid/truncated, 3 unsupported, 4 I/O, 5 resource limit, 6 cancellation. | port.md and T09. |

## I/O and API

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Field reads | `readSliceAll` into local arrays instead of `takeInt`, so parsing works with any reader buffer size, including zero. A failed read is terminal for the stream. | CLAUDE.md, port.md "Verified Zig 0.17 I/O choices", `io_patterns.zig`. |
| Field writes | Encode into a local array and `writeAll`, instead of relying on `Writer.writeInt` working below its documented buffer minimum. | Same places. |
| Error spelling | `Canceled`, Zig's `std.Io.Cancelable` spelling, not `Cancelled`. | port.md error list. |
| Sequential parsing | The first parser is synchronous and blocking through `*std.Io.Reader`; resumable nonblocking parsing is a separate future capability. | port.md "Recorded design decisions". |

## Documentation and agents

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Agent guidance | `CLAUDE.md` is canonical; `AGENTS.md` only contains `@CLAUDE.md`. | Move the content back if a tool cannot follow the import. |
| Style guide precedence | [doc/zig-0.17-guide.md](doc/zig-0.17-guide.md) governs new Zig, but `CLAUDE.md` wins where they differ. | Either file. |
