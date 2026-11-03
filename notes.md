# Revisable decisions

Project choices that could reasonably change later. The choices are project
policy, informed by the reference behavior and evidence linked below. They keep
each supported path small, strict and testable. Every entry names where the
choice lives, so a change can update those places together and re-run the
affected checks.

Authoritative details stay where they are: the WAV and AU contracts in
[port.md](port.md#first-wav-contract), their fixtures and precedence in the
[WAV](zig/testing/fixtures/README.md) and
[AU](zig/testing/fixtures/au/README.md) fixture READMEs, tasks in [TODO.md](TODO.md).
When you make a new revisable decision, add it here in the same change.

## Port design policy

The design review of 2026-11-03 supplied reasons for rules that must remain
visible as the port grows. These decisions live in the architecture and task
contracts; this section preserves their rationale without duplicating the
checklist or its status.

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Supported surface | Explicit accepted subsets and exclusions. Every additional parser and recovery rule adds maintenance and untrusted-input paths; accepting everything FFmpeg accepts is not a goal. Failed experiments may be removed. | port.md "Supported scope and policy", the affected TODO.md G0 contract, fixture generator/README and reference differences. Excluded features also require revising "Not planned". |
| Checks and isolation | Check sizes before use in every mode; require named fixtures and a bounded fuzz entry before G5. Component selection should omit unused parsers. A Zig implementation is not a security boundary; applications retain responsibility for process isolation and privileges. | port.md's scope and resource rules, TODO.md coverage rules, T55 and T60. Record the changed bounds and evidence; a unit pass is not a sustained fuzz campaign. |
| Ownership and diagnostics | Types distinguish ownership where possible; APIs document remaining lifetimes and test failure cleanup. Allocators, I/O and diagnostic sinks are explicit dependencies. Copying an owner is not cloning it. | port.md "Core API and resource rules" and "Streaming state, ownership and time", TODO.md T14/T17a and the affected APIs and tests. |
| Algorithm duplication | Keep one implementation, specialized only for real variation. A second needs a purpose, comparison oracle and retention or retirement condition. Optimized kernels retain scalar; T24 has one native resampler. Shared contexts must not force unrelated codecs into one state model. | port.md's design goal, the consuming task and its tests; T58 for optimized variants. Follow each infrastructure task's Start-with note. |
| Time policy | Derive time from supported container/codec rules and integer counts; keep unavailable values null and preserve negative timestamps. Explicit rescaling, wrap handling and smoothing do not imply heuristic repair of broken streams. | port.md's time rules, TODO.md T15/T52 and affected timing vectors; update comparison normalization without hiding missing or negative values. |
| CLI policy | Library operation matrices govern commands. Reject unsupported combinations before creating output; media-changing defaults are named, documented options. Late parsing, writing and flushing errors remain failures after partial output. | port.md "CLI policy", TODO.md T13/T17a/T53 and process cases, including overwrite and cleanup behavior. T51's compatibility mode stays separate from the stable probe report. |
| Performance claims | Language choice establishes no speed advantage. Compare against both the C-only oracle and an asm-enabled FFmpeg benchmark build; keep their identities and results separate. SIMD also needs scalar equivalence and a measured gain. | port.md "Verification strategy", TODO.md T57/T58 and benchmark reports. Declare float tolerances before measuring; do not widen them to pass. |

Historical sources explain these choices, rather than establish the port's
current safety or completion. The
[2014 Google fuzzing report](https://security.googleblog.com/2014/01/ffmpeg-and-thousand-fixes.html)
records recurring bounds, pointer, cleanup and initialization failures and
recommends privilege separation. FFmpeg's pinned
[undefined-behavior note](https://github.com/FFmpeg/FFmpeg/blob/5d5a38a7e46be296eab75982c0986054f731e19e/doc/undefined.txt)
explains why signed overflow remains unsafe even on invalid input, and the
[send/receive contract](https://github.com/FFmpeg/FFmpeg/blob/5d5a38a7e46be296eab75982c0986054f731e19e/libavcodec/avcodec.h)
requires explicit progress, draining and reset behavior. The response here is
checked arithmetic and tested contracts; Zig alone supplies neither ownership
proof nor codec correctness.

## Toolchain and build

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Compiler version | Exactly Zig 0.17.0. A comptime check in `build.zig` rejects any other compiler, because the std API moves between releases. | Update `tested_zig_version` in `build.zig`, `.minimum_zig_version` in `build.zig.zon`, `.zig-version`, the CI `version:` and version check, and the docs; validate the new std APIs first and update the [`zig-0-17` skill](.claude/skills/zig-0-17/SKILL.md), renaming it for the new version. |
| Module layout | One package, one `av` module rooted at `zig/root.zig`. | Split named modules only for a demonstrated need, such as publishing a subset; keep imports acyclic. |
| Library artifact | Static `libzffmpeg.a`, named after the package so it does not look like an FFmpeg or Libav library. | `addLibrary` in `build.zig` (name, `.linkage`); [zig/README.md](zig/README.md). |
| Package identity | Name `zffmpeg`, version `0.0.0`, toolchain-generated fingerprint. | Version can change freely; the fingerprint changes only for a fork that becomes a separate package. |
| Package contents | `.paths` lists `build.zig`, `build.zig.zon`, `zig/`, `LICENSE`, `README.md`. `zig/` includes test fixtures and `generate.py`. | Narrow `.paths` if packaging should exclude test data; never use `""`. |
| Dependencies | None: no package dependencies, C sources, libc or translate-c. | Add one only with a recorded decision in port.md; a C library never counts as ported functionality. |
| Build policy | `build.zig` and one explicit component catalog as selection grows (T55). No configure-like shell layer or automatic host-library discovery; preserve predictable build time and keep the reference build separate. | Record each host probe or system-library addition in port.md and here; update zig/README.md and T55, with build-time and binary-size measurements. |
| Example registration | Examples are listed explicitly in `build.zig`; CI fails on an unregistered `zig/examples/*.zig`. | Keep explicit; the CI guard can go if examples move into the `av` test tree. |
| Test filter | `-Dtest-filter` applies to every test artifact. | `build.zig` option. |

## CI

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Platforms | Linux x86-64 only (`ubuntu-24.04`) during development, decided on 2026-11-03: every task's evidence comes from Linux runs. Windows, ARM and macOS runs wait until the code is more complete. New code follows CLAUDE.md "Portable Zig code", and a compile-only cross build for x86_64-windows-gnu, aarch64-linux-musl and aarch64-macos catches Linux-only APIs. | Start TODO.md T62 (Windows) and T63 (ARM, macOS, big-endian) when the Linux-only phase ends; update the platform policy in TODO.md and CLAUDE.md together. |
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
| Exit-code mapping | Contract errors map to 2, 3 or 5; running out of memory for the arguments, `SystemResources` and descriptor-quota errors to 5; `Canceled` to 6; every other error to 4 (I/O). The statuses are the `ExitStatus` enum, converted to a number only in `main`; `status.of` takes the named `status.Error` set, so a new error source must be added to it deliberately. zffmpeg shares the mapping and adds `UnsupportedOperation` (3) and `SizeOverflow` (5). | `zig/cli/status.zig`; `build.zig` keeps the expected statuses as independent literals. |
| CLI tests and filters | The 24 `zffprobe` and 36 `zffmpeg` process cases and the prepared-file cases run in `zig build test` but are skipped when `-Dtest-filter` is given. | `build.zig`. |
| Reference build | Linux x86-64, Clang, minimal LGPL configuration, `--disable-x86asm` (the C paths are the reference; no NASM dependency), built out of tree and cached in CI under a key from the Clang version and the build script. | `zig/testing/reference/build-ffmpeg.sh`; changing it or the runner's Clang rebuilds the cache. Update the recorded values in `zig/testing/reference/README.md`. |
| Reference job | Runs on every pull request and push to `master`, after the first build only from the cache. | `.github/workflows/ci.yml`; move it to a schedule if it gets slow. |
| Known FFmpeg differences | `compare.py` accepts exactly two metadata differences on accepted fixtures: `channel_layout=unknown` (a plain WAV header has no channel mask) and `duration_ts=N/A` for `empty_data` (FFmpeg reads data size 0 as unknown length). Any other value fails. FFmpeg's verdict on rejected fixtures is recorded, not checked. | `KNOWN_FIELD_DIFFERENCES` and `KNOWN_FIXTURE_DIFFERENCES` in `compare.py`, and the reference README. |
| Writer verification | FFmpeg decodes the files the write driver (T19a) and `zffmpeg` (T13b) actually write, not only the writer-output fixtures. | `compare.py`'s writer and zffmpeg sections. |

## AU contract and the write driver

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Writer header | 32 bytes: the 24 header bytes and 8 zero annotation bytes, which is what FFmpeg's AU muxer writes without metadata, with the known data size. Matching it makes our output comparable byte for byte with FFmpeg's seekable output. | `generate.py` (the writer-output fixtures) and the AU writer in T12b; a 24-byte header is also valid. |
| Data size bound | At most `0x7fffffff`: FFmpeg reads the field as signed and rejects larger sizes, so files we accept or write stay readable by it. Larger sizes are `LimitExceeded`. | The AU contract in `au/README.md` and the fixtures `au_data_size_over_limit`, `au_limit_before_unsupported`. |
| Annotation | Skipped and ignored, at most 1 MiB (configurable); FFmpeg parses it as metadata, which we do not report yet. | The AU contract; report it when metadata lands (T17b). |
| Data offset below 24 | `InvalidAu`, although FFmpeg ignores it. | `au_offset_too_small`. |
| Trailing bytes | Ignored and never read, like bytes after a WAV RIFF extent; FFmpeg decodes them. | `au_trailing_bytes_after_data` and its known decode difference in `compare.py`. |
| Write driver | A test tool (`zig/testing/write_driver.zig`) installed by `zig build test-tools`, not by the default install: it exists so FFmpeg reads actual Zig output. It reads raw s16le input, at most 1 MiB. | `build.zig`, the CI reference job and `compare.py --writer`. |
| Not-implemented checks | `compare.py`'s `NOT_IMPLEMENTED` lists checks whose Zig code has not landed; the report shows them separately from passes and skips, and the owning subtask deletes its entry. | `zig/testing/reference/compare.py`. |
| Content detection | A stream that starts with `.snd` is AU; anything else, including input shorter than 4 bytes, goes to the WAV parser (`zig/format/detect.zig`). With two formats, one magic check is enough, and WAV's results and errors stay exactly as before: a non-AU file reports `InvalidRiff`. The magic alone selects AU, so `au_empty_data` is detected, unlike FFmpeg's `au_probe`, which needs every header field nonzero. | Scored probing over a longer prefix (TODO.md T16/T26a) replaces it when a third format lands; `detect.zig`, the probe cases in `build.zig` and `ZFFPROBE_AU_DETECTION` in `compare.py`. |
| Detection prefix | Detection reads at most 4 bytes with `readSliceShort` and hands them to the chosen parser through `format/prefix.zig`'s `Prefix`, a 4-byte array, instead of peeking into the reader's buffer: it works with any reader buffer size, including none, and a pipe loses no bytes. Each parser's first header read takes the whole prefix. | `prefix.zig`, `Parser.initPrefixed` in `wav.zig` and `au.zig`; a longer prefix (T16) needs `max_len` raised and a first read at least that long. |

## Conversion pipeline

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Location and shape | `zig/format/convert.zig`, next to `detect.zig`, the other code that dispatches between containers: a `Conversion` with a two-container input union and a `switch` on the output, no registry or codec context. A third format replaces both switches with T16's dispatch. | port.md "Conversion pipeline"; T16. |
| Two phases | `init` makes every check that does not need the rest of the input and writes nothing; `run` writes. T13b can then reject a command before it creates the output file. | `convert.zig` and its tests; T13b's preflight. |
| Check order | Input header, then the request (matrix), then the output header, as FFmpeg opens the input before setting up output streams: a malformed input reports its own error even when the request would also fail. | port.md "Conversion pipeline" and `convert.zig`'s tests. |
| Copy reads raw bytes | Stream copy moves encoded data through `Parser.readData` and `Writer.writeData`, not a decode and re-encode that happens to give the same bytes, so the matrix's copy cells really copy; `readSamples` and `writeFrames` now build on them. | `wav.zig`, `au.zig`, `convert.zig`. |
| Writer header checks | `Writer.check` runs `begin`'s header checks without writing; both share one `encodeHeader`. | `wav.zig`, `au.zig`. |
| Internal writer errors | `run` treats the writer's header, frame and count errors as unreachable: `init` ran the same header checks and the parser delivers exactly the declared whole frames. Only `WriteFailed` reaches callers. | `outputFailure` in `convert.zig`; revisit if writer limits ever differ between `check` and `begin`. |
| Partial output on input failure | An exact transfer read that the input cannot fill delivers nothing, so the samples written before a truncation depend on the 4 KiB transfer boundaries. The failure itself is always reported. | `convert.zig`; delivering the readable prefix would need short reads in `readData`. |
| Rejected-input oracle | Tests expect a rejected input to fail conversion with `detect.probe`'s error, which the fixture contracts already pin, instead of repeating the fixture-to-error mapping. | `convert.zig` tests. |

## Packets, frames and stages

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Views and `Owned` | `Packet` and `Frame` are views; `clone(gpa)` makes an `Owned` value that composes the view and its allocator. Explicit copies cover every current consumer; reference counting waits for a stage that shares data (T14b). | `core/packet.zig`, `core/frame.zig`; T14b. |
| One plane | `Frame` holds interleaved s16 samples only, the one supported sample format. | T20a replaces it with real sample storage. |
| `.full` is a result | Backpressure is a normal answer (`Send.full`), not an error, so `try` never hides it and failures stay errors. | `core/stage.zig`. |
| Idempotent `finishInput` | A second call does nothing, where FFmpeg decoders answer `AVERROR_EOF`; `send` after it is `InputAfterEnd` in both. One rule for every stage and no error for a harmless repeat. | `core/stage.zig`, port.md. |
| PCM stages in caller storage | `pcm.Decoder` and `pcm.Encoder` hold one item in storage the caller provides and never allocate, so `av.convert` keeps its fixed memory. A codec that needs growing buffers takes an allocator itself. | `codec/pcm.zig`. |
| Test stage | `DelayStage` exists only for tests: PCM never buffers, delays or splits, so it alone exercises those rows of the contract. It is not exported. | `zig/testing/delay_stage.zig`. |
| Byte order with the codec | `detect.Container.sampleEndian` sits next to `codecName`: the order is the codec's property. | `detect.zig`; the codec descriptors of T16 replace both. |

## zffmpeg command

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Option order | `-f` and `-c` only after `-i`. In FFmpeg an option before `-i` applies to the input; reading it as an output option would silently change the command's meaning, so it is a usage error until input options exist. | `parse` in `zig/cli/ffmpeg.zig`, the usage cases in `build.zig`; T53a. |
| Output container | `-f`, else the `.wav`/`.au` extension in any case, as FFmpeg; standard output needs `-f`. | `outputContainer`; port.md "zffmpeg command". |
| Existing output | Refused without `-y`, by exclusive creation, with status 1; never an interactive prompt, so scripts and pipes behave the same everywhere. | `convert` in `ffmpeg.zig`; the prepared-file cases. |
| Same file | Compared by `Stat.inode` instead of FFmpeg's name comparison, so other spellings and redirected input are caught. A false match across volumes (no device number in `Stat`) refuses the command; it never loses the input. | `sameFile`; switch to a device-qualified identity if std exposes one. |
| Partial output | Removed after any failure once the file was created (closed first: Windows cannot delete an open file). Standard output keeps what was already written and is not flushed after a failure. | `convert` in `ffmpeg.zig`; port.md. |
| Cancellation | No process case: the synchronous command has no source of `Canceled`, and the tools install no signal handlers (CLAUDE.md), so on POSIX SIGINT and SIGPIPE end it by signal. Status 6 stays mapped for when a source exists. | `status.zig`; add the process case with the first cancellation source. |
| Read-failure case | The write-only standard input case runs only on POSIX: on Windows, std's spawn reopens a passed stdio file with the access its stream needs, so the failure cannot be set up. Write failures use a closed pipe, which fails everywhere. | `zig/testing/zffmpeg_cases.zig`; the zig-0-17 guide's process section. |
| Shared statuses | `zig/cli/status.zig` holds the exit statuses, the error classification and stderr output for both tools: zffmpeg was the second caller. `SizeOverflow` (an output its container cannot hold) is a resource limit, status 5. | `status.zig`; port.md's status lists. |
| Prepared-file cases | A separate tool, run by `zig build test` in a fresh output directory, because process runs in `build.zig` cannot prepare existing outputs or check that a file was removed without touching the build cache. It reads the fixtures from a directory argument: `fixtures.zig` already belongs to the `av` module. | `build.zig`, `zffmpeg_cases.zig`. |

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
| Document authority | port.md owns architecture and behavior; fixture READMEs own detailed expectations; TODO.md owns tasks and evidence; this file owns revisable decisions. Agent guidance follows the contracts. Summaries add no completion evidence. | port.md "Document authority", CLAUDE.md and TODO.md together. Resolve conflicting rules before implementation; update the affected contract, task, fixtures and decision in one change. |
| Style guide precedence | The [`zig-0-17` skill](.claude/skills/zig-0-17/SKILL.md) and its guide govern new Zig, but `CLAUDE.md` wins where they differ. | Either file. |
| Zig guide as a skill | The Zig 0.17 guide is a project skill (`.claude/skills/zig-0-17/`) rather than a plain document, so Claude Code loads it on every Zig change; CLAUDE.md requires it. `SKILL.md` keeps the workflow, section map and the only copy of the checklist; `references/guide.md` keeps the full guide, so the always-loaded part stays short. | Move `references/guide.md` back to `doc/` and drop the skill, updating CLAUDE.md, README.md, zig/README.md and this row together. |

## Planning

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Task structure | Parent tasks keep stable IDs and split into subtasks with their own gates (G0–G5). Dependencies use **Needs**, **Lands with** and **Verified after**; shared infrastructure has a **Start with** note instead of a dependency, so no task waits on its own consumer. Adopted after a review found scheduling loops in the first roadmap. | TODO.md "How tasks are completed". |
| Second container (T12) | Sun AU with signed 16-bit big-endian PCM (encoding 3): it adds container dispatch, big-endian fields and sequential I/O through the existing `pcm` kernels without changing the decoded audio model. Unknown-length AU and the other encodings wait for T22a. | TODO.md T12 and T22; choosing AIFF or a sample-format variant instead means rewriting T12a–T12c. |
| Stream copy (T13) | Preserves encoded media and timing, not container headers or unsupported metadata chunks. Copy between WAV s16le and AU s16be is rejected before any output, because the samples need byte swapping. | TODO.md T13's operation matrix. |
| Stable IDs | Splitting a task keeps existing IDs' meanings and appends new IDs, which need not follow execution order. The one exception, commit `8b1652a` re-splitting T43 and T47 before any work started, is mapped in TODO.md. | TODO.md "Task structure and dependency words". |
| Coverage denominator | Each subtask names its required fixtures; missing or altered required files fail, and optional corpora are reported separately with their skips. Conformance streams that cannot be generated or redistributed are fetched by pinned hash and stay required. | TODO.md "Coverage and comparison rules". |
