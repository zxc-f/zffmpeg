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
| Supported subset | Little-endian RIFF/WAVE, RF64/BW64 and Sony Wave64 (T21b) with the WAV PCM encodings (T21a: tag 1 at 8, 16, 24, 32 or 64 bits, tag 3 float at 32 or 64, A-law, mu-law, and WAVE_FORMAT_EXTENSIBLE with those subformats), 1 to 64 channels since T23b (`Limits.max_channels`, libswresample's `SWR_CH_MAX`; more is `LimitExceeded`, though FFmpeg reads them); everything else is `UnsupportedFormat`. | `fmt_*`, `extensible_*`, `rifx_*`, `rf64`, `bw64`, `w64_*` |
| Wave64 | One parser and writer for both chunk layouts (`wav.Variant`), since everything after the chunk framing is WAV's; detection names it `w64` from its `riff` magic. Sizes are read and written as the Sony specification has them (header counted, padding not); FFmpeg's muxer counts the padding, so its padded 24-byte plain `fmt ` is accepted too. Unknown sizes follow `unknown_length`, though FFmpeg's demuxer rejects them. FFmpeg also rejects an empty `data` chunk (24 bytes), which the writer emits for zero frames. | `w64_*`; `Variant` in `wav.zig`, `canonical_w64` in `generate.py`, the `w64` cells in `compare.py`. Counting the padding as FFmpeg does would make odd-sized data decode its pad bytes. |
| `fmt ` sizes | 16, or 18 with `cbSize == 0`; extensible exactly 40 with `cbSize == 22`. Fewer than 16 declared bytes is `InvalidFormat`; other sizes are `UnsupportedFormat`. | `fmt18_cbsize0`, `fmt_size_14`, `fmt20_cbsize2`, `extensible_fmt18`, `extensible_cbsize_short` |
| Whole-byte depths | Tag 1 takes 8, 16, 24, 32 or 64 bits, float 32 or 64, G.711 8; FFmpeg rounds other depths up. Odd depths in the wild are rare, and rounding would decode samples the header misdescribes. | `fmt_bits12`, `fmt_float_bits16`, `fmt_alaw_bits16` |
| Extensible details | Valid bits must be 0 or all bits; FFmpeg trusts them. A partial-valid-bits mode needs a recorded use first. Since T23b any channel mask is read as FFmpeg reads it: native when it names exactly the channels, else unspecified. | `extensible_valid_bits_*`, `extensible_mask_*` |
| `byte_rate` | Ignored, even when inconsistent, because decoding never uses it and real files get it wrong. | `byte_rate_mismatch` |
| Sample-rate limit | 192,000 Hz default; above it is `LimitExceeded`. A configurable policy limit, not a format rule. | `mono_192k_rate_limit`, `fmt_rate_over_limit` |
| Chunk-count limit | 4,096 chunks including `fmt ` and `data`; the 4,097th is `LimitExceeded`. | `chunks_at_limit`, `chunks_over_limit` |
| Retained-bytes limit | 1 MiB of non-audio bytes the parser keeps; skipped chunk bodies do not count, so large `LIST`/`id3 ` chunks stay readable. | `large_skip_2mib` (synthesized) |
| Streaming work buffer | 64 KiB default; no whole-file allocation. | None yet (T07) |
| Unknown sizes | `riff_size` 0 or 0xFFFFFFFF and `data` size 0xFFFFFFFF are `UnsupportedStreamingSize` by default. Since T21b the parser option `Limits.unknown_length` reads them to the end of the input instead: the extent may then end between chunks; unknown data must end on a whole frame, has no frame count, and nothing after it is read (FFmpeg's reading, so a known `riff_size` goes unchecked). Opt-in because it gives up the extent checks; the converter refuses unknown-length input because the writers need the length, and the CLIs do not enable it. `data` size 0 stays an empty stream, where FFmpeg reads to the end. | `riff_size_*`, `data_size_unknown`, `unknown_length_*`, `unknown_riff_*`, `empty_data`; changing it touches `Limits`, `Info.frame_count`, the manifest's `unknown_length` field and `compare.py` |
| Extent bounds | A chunk running past the RIFF extent, or fewer than 8 bytes left for a header, is `InvalidRiff`; input shorter than the extent is `Truncated`; bytes after it are ignored. FFmpeg tolerates all of these. | `*_exceeds_riff_extent`, `partial_chunk_header_in_extent`, `riff_size_exceeds_input`, `trailing_bytes_after_riff` |
| Final pad byte | A pad byte outside the extent is not read (accepted); one inside the extent but missing is `Truncated`. | `odd_final_chunk_pad_*` |
| Duplicates and order | Exactly one `fmt ` before exactly one `data`; a second `fmt ` (which FFmpeg ignores) or `data` is `InvalidWave`. | `duplicate_*`, `data_before_fmt`, `missing_data`, `no_chunks` |
| Partial frames | A `data` size that is not a multiple of `block_align` is `InvalidFormat` (FFmpeg drops the partial frame). | `data_not_block_aligned` |
| Error precedence | First violation in stream order; within `fmt `, tag, bits, channels, rate, `block_align`, then size. | `rifx_truncated`, `fmt_unsupported_before_invalid`, `data_size_unknown` |
| Partial output | Errors found after audio was produced are still reported; output is not atomic. | `duplicate_data`, `chunk_exceeds_riff_extent` |

## Writer

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| RF64 | Read: RF64 and BW64 with a 28-byte `ds64` first and no size table, stricter than FFmpeg (which ignores the 32-bit size and the table). Written: `WriteOptions.rf64 = .auto` by default, deciding up front from the known length, where FFmpeg's default `never` writes broken sizes past 4 GiB; `.always` exists to compare small RF64 files with FFmpeg. | `wav.zig`, the `rf64*` fixtures, `write_driver.zig` (`rf64` argument). |
| Header format | Since T21a, the `fmt ` FFmpeg's `riffenc.c` chooses: extensible above 48 kHz or above 16 bits unless float, else plain (16 bytes for tag 1, 18 with `cbSize` 0 otherwise), plus a `fact` chunk for every encoding but tag 1, which FFmpeg writes on seekable output and we always can. This replaced T08's tag 1 at every rate: TODO.md T21a asked for FFmpeg's choice, and plain high-rate files remain accepted input. Compare decoded samples and metadata with FFmpeg, not file bytes (FFmpeg adds LIST/INFO). | `canonical_wav` in `generate.py`, `Writer` in `wav.zig`, the writer-output fixtures. |
| Known length | The frame count is required up front; exact sizes are written with no seeking or placeholder sizes. | T08; streaming output would need seekable writers or placeholder patching. |
| Wave64 output | `WriteOptions.variant = .w64`: the same `fmt ` as WAV, a `fact` chunk with a 64-bit count for every encoding but tag 1, sizes without padding, and the file below 2^63 bytes (FFmpeg reads sizes as signed). `rf64` does not apply. | `wav.zig` `Writer`, `canonical_w64`, the `w64` writer-output fixtures. |

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
| Known FFmpeg differences | `compare.py` accepts exactly the listed metadata differences on accepted fixtures, such as `duration_ts=N/A` for `empty_data` (FFmpeg reads data size 0 as unknown length). Since T23b the channel layout is no longer one: both report `unknown` for an unspecified layout (it was the WAV and AU difference before). Any other value fails. FFmpeg's verdict on rejected fixtures is recorded, not checked. | `KNOWN_FIELD_DIFFERENCES` and `KNOWN_FIXTURE_DIFFERENCES` in `compare.py`, and the reference README. |
| Writer verification | FFmpeg decodes the files the write driver (T19a) and `zffmpeg` (T13b) actually write, not only the writer-output fixtures. | `compare.py`'s writer and zffmpeg sections. |

## AU contract and the write driver

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Writer header | 32 bytes: the 24 header bytes and 8 zero annotation bytes, which is what FFmpeg's AU muxer writes without metadata, with the known data size. Matching it makes our output comparable byte for byte with FFmpeg's seekable output. | `generate.py` (the writer-output fixtures) and the AU writer in T12b; a 24-byte header is also valid. |
| Data size bound | At most `0x7fffffff`: FFmpeg reads the field as signed and rejects larger sizes, so files we accept or write stay readable by it. Larger sizes are `LimitExceeded`. | The AU contract in `au/README.md` and the fixtures `au_data_size_over_limit`, `au_limit_before_unsupported`. |
| Annotation | Skipped and ignored, at most 1 MiB (configurable); FFmpeg parses `title`, `artist`, `album`, `track` and `genre` from it as metadata, and its muxer writes them there. Not reported yet: T22a's contract covers the encodings, and the dictionary (T17b) now exists for a later subtask. | The AU contract and `au.zig`; `carriedTags`' note on AU output. |
| Encodings (T22a) | Every PCM encoding of `au.c`'s table, by the same per-sample kernels as WAV (`pcm.decode`/`encode`), with one table each way (`codecFor`, `encodingFor`). G.722 and G.726 stay `UnsupportedFormat` until T31c. With A-law and mu-law in both containers, copy between WAV and AU works for them. | `au.zig`, `detect.Container.carries`, `AU_CODECS` in `generate.py`. |
| Unknown length (T22a) | `Limits.unknown_length`, as for WAV: off by default, the rest of the input in whole frames, no frame count. | `au.zig`, the `au_unknown_size*` fixtures. |
| Data offset below 24 | `InvalidAu`, although FFmpeg ignores it. | `au_offset_too_small`. |
| Trailing bytes | Ignored and never read, like bytes after a WAV RIFF extent; FFmpeg decodes them. | `au_trailing_bytes_after_data` and its known decode difference in `compare.py`. |
| Write driver | A test tool (`zig/testing/write_driver.zig`) installed by `zig build test-tools`, not by the default install: it exists so FFmpeg reads actual Zig output. It reads raw little-endian input in the codec's storage format, at most 1 MiB, and writes WAV, Wave64 or AU in any codec the container carries. | `build.zig`, the CI reference job and `compare.py --writer`. |
| Not-implemented checks | `compare.py`'s `NOT_IMPLEMENTED` lists checks whose Zig code has not landed; the report shows them separately from passes and skips, and the owning subtask deletes its entry. | `zig/testing/reference/compare.py`. |
| Content detection (T16) | FFmpeg's winner, as the project owner chose: each demuxer's probe ported from FFmpeg, highest nonzero score, a tie means none. Undetected input is `UnknownFormat` (exit 3), so tiny WAV, Wave64 and AU files and an AU with data size 0 are read only with `-f`, which both tools accept as `ffprobe -f` does. Since T22c, also as the project owner chose, FFmpeg's extension fallback: a probe-less demuxer (raw PCM) whose extension matches the input's file name scores 50, below every content probe. Before T16 the first 4 bytes routed the stream and anything not AU went to the WAV parser. | `zig/format/detect.zig`, each fixture's `detected` field (`ffmpeg_detect` in `generate.py`), `compare_detection` in `compare.py`. |
| Probe buffer | The first 2048 bytes (FFmpeg's first probe size), replayed to the parser through `format/replay.zig`'s `Replay` reader, which serves them and then the source with no buffer of its own, so any source buffer size works. FFmpeg probes again with more data while the best score is at most 25; every registered probe scores 0, 99 or 100 within 41 bytes, so that loop is not ported, and the registry checks each probe's byte count at compile time. | `detect.zig`; a probe that can score low (MP3, T26) needs the retry loop and a larger replay buffer. |
| Forced layouts | `-f wav` reads only RIFF/RF64/BW64 and `-f w64` only Wave64 (`wav.Parser.initVariant`), as FFmpeg's separate demuxers do. | `wav.zig`. |

## AIFF contract

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Sequential reading (T22b) | `COMM` must come before `SSND`, and the declared `FORM` size bounds every chunk: the parser never seeks, like the WAV and AU parsers, so pipes and files behave the same. FFmpeg reads `COMM` after `SSND` only by seeking back on a seekable file. | `aiff.zig`, `aiff_ssnd_before_comm`; a seekable path would need a second reading mode. |
| Frame count | `COMM`'s frame count must equal the whole frames in `SSND` (`InvalidFormat`); FFmpeg decodes the `SSND` bytes whatever `COMM` says. Equal counts keep the reported duration and the decoded length the same, as for the other contracts. | `aiff_frames_mismatch` and the AIFF README. |
| Sample size | Only 8, 16, 24 and 32 bits; FFmpeg rounds other sizes up. Odd sizes would need the WAV contract's rule on padding bits too. | `aiff_bits12`; the AIFF contract. |
| Encodings | Every PCM type of FFmpeg's `ff_codec_aiff_tags`, matched case-insensitively as FFmpeg's second pass does; the writer picks the first tag per codec, so s16le copies into AIFF-C `sowt` and u8 into `raw `, as FFmpeg's muxer does. Compressed types (`ima4`, `MAC3`, `GSM `, G.72x, QDM2, ...) are `UnsupportedFormat` until their decoders land. | `codecForCompression` and `compressionFor` in `aiff.zig`, `AIFF_CODECS` in `generate.py`. |
| Tags | `NAME`, `AUTH`, `(c) `, `ANNO` and `ID3 ` are skipped, and the writer writes none, so zffmpeg carries no tags into or out of AIFF. FFmpeg reads and writes the first four as title, author, copyright and comment. | A later subtask: `aiff.zig` with `metadata`, `convert.zig`'s `carriedTags` path. |
| Unknown length | Not supported: a `FORM` size below 4 is `InvalidAiff` and is not detected. FFmpeg writes zero sizes to a pipe, and its own demuxer rejects that file the same way, so there is nothing to interoperate with. | The AIFF README's decisions. |
| Writer header | FFmpeg's seekable output without metadata, byte for byte (plain AIFF for `NONE`, AIFF-C with `FVER` otherwise), so FFmpeg's `-bitexact` copy of each writer-output fixture is identical. | `generate.py` (`canonical_aiff`) and the AIFF writer. |

## Registries (T16)

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Codec identity | `pcm.Codec` is the codec identifier while every implemented codec is PCM; `codec/registry.zig` adds one descriptor per codec (media type, FFmpeg's name and long name, the `-codecs` properties) and the decoder and encoder lists. A second enum would only mirror it. | The first non-PCM codec widens the identifier into a general one and moves the PCM-specific fields. |
| Decoder and encoder registries | Every PCM codec has a decoder and an encoder named as the codec, as in `allcodecs.c`; `stage` marks the s16-stored ones that run as send/receive stages, whose signatures `stage.check` validates at compile time. | `codec/registry.zig`; T23a makes every codec a stage. |
| Format registry | One entry per `Container` in its order: FFmpeg's name and long name, the demuxer's probe (optional: a format without a content signature is chosen only by its extension) and extensions, and the muxer's extensions, MIME type, default audio codec and carried codecs. The tools take `-f` names and output extensions from it. Validated at compile time (order, names, unique lowercase extensions, the default codec carried). | `format/registry.zig`; the 14 raw PCM formats (T22c) are probe-less demuxers. |
| Checked against FFmpeg | A test tool, `registry-dump`, prints both registries, and `compare.py` requires them to equal the reference build's `ffmpeg -codecs`, `-formats` and `-h muxer=...` and to cover exactly the codecs and formats it enables. | `zig/testing/registry_dump.zig`, `compare_registries`; the reference configuration. |

## CAF contract

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Read only (T22d) | The task is CAF demux; FFmpeg's CAF muxer is not ported, so the registry has no CAF muxer and the reference build enables only the demuxer. | A later subtask with a writer; the registry entry and `build-ffmpeg.sh`. |
| Sequential reading | Every chunk before and after `data` is read and validated to the end of the input, never seeking; FFmpeg reads the chunks after `data` only from a seekable file. | `caf.zig`. |
| Strict description | One frame per packet of exactly the frame's bytes, whole-byte integer sizes, version 1; FFmpeg takes declared packet sizes, rounds sizes up and reads any version when forced. | `caf_bytes_per_packet`, `caf_lpcm_bits12`, `caf_version2`. |
| `pakt` | `UnsupportedFormat`: FFmpeg trims priming and remainder frames by it, which PCM files do not need. | `caf_pakt`; a codec with packet tables (ALAC, T31b) needs it. |
| Unknown `data` size | Behind `unknown_length`, as for WAV and AU: it gives up the length check. | `caf_data_size_unknown`. |
| Sample rate | Truncated toward zero, as FFmpeg's int conversion of the double; below 1 is invalid. | `sampleRate` in `caf.zig`, `caf_rate_fraction`. |

## Sample format conversion

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Kernels (T23a) | `resample/audioconvert.zig` reproduces libswresample's direct conversion (`full_convert`, no resampling, rematrixing or dither) for every pair of the twelve formats, bit-exact on the 232 vectors of the pinned libswresample, floats included: integer shifts, round-to-nearest-even int-to-float conversion times an exact power of two, and float-to-int `lrint` (half to even) with clipping. | `audioconvert.zig`, `sampleconv_vectors.c`. |
| Undefined C cases | Where FFmpeg's `lrint`/`llrint` see NaN or overflow (a product beyond the 64-bit range, like 1.0 to s64), C is undefined; the port follows x86-64, the reference platform: the most negative 64-bit value, then FFmpeg's clipping (so NaN and +inf become -32768 in s16, as FFmpeg's x86 builds give and `compare.py` checks on the float fixtures). ARM builds of FFmpeg saturate instead, and Windows' 32-bit `long` also overflows for finite products from 2^31 to 2^63 in the u8 and s16 paths, which the port computes in 64 bits. | `toI64` in `audioconvert.zig` and its tests. |
| Pipeline (T23a) | `Frame` holds any sample format; `pcm.Decoder` and `pcm.Encoder` take every codec in its storage, and `audioconvert.Converter` sits between them when the storages differ. `compare.py` checks every converted zffmpeg output by decoding it and FFmpeg's own conversion (as raw PCM of the codec) to the same samples. | `frame.zig`, `pcm.zig`, `convert.zig`, `check_converted`. |
| Scope decisions | The project owner chose FFmpeg's automatic conversion to the output's default codec when transcoding, plus `-c:a` to pick another, and every dither method, noise shaping included. | TODO.md T23a; port.md. |
| Dither (T23a) | `resample/dither.zig` reproduces libswresample's `dither_method`, `dither_scale` and `output_sample_bits` bit-exactly (133 vectors of the pinned libswresample): the internal format, the noise generator and its buffer (twice the largest call, at least 65536 frames, restarting when a call would pass its end), `sum2`'s wrapping integer mix, and the noise-shaping filters in FFmpeg's float and double arithmetic, falling back to triangular high-pass without a filter within 5% of the rate. The noise is generated as read rather than buffered, so nothing allocates. | `dither.zig`, `dither_vectors.c`. |
| Dither in the pipeline | As FFmpeg's command line: only when the sample format changes (its filter graph inserts no converter otherwise, so s32 to a 24-bit encoder is not dithered), with `output_sample_bits` 24 for a 24-bit encoder, and with the noise following FFmpeg's call sizes, one call per demuxer packet (`ff_pcm_default_packet_size` for WAV, Wave64, AU and raw PCM; 4096 bytes of frames for AIFF and CAF), whatever packets the port reads. With an unknown length the last call counts as full, which can differ only for a packet size that does not divide the noise buffer, so not for WAV, AU or raw PCM. `-c copy` ignores the options, as FFmpeg does. | `ffmpegPacketFrames` and `Transcoder` in `convert.zig`; `Dither.setCalls`. |
| Dither options | zffmpeg takes `-dither_method` (a name, or FFmpeg's number) and `-dither_scale` (a decimal from 0 to 2147483647) after `-i`; before it they are a usage error, where FFmpeg takes them as input options and ignores them. FFmpeg's option expressions are not parsed, and a bad value is a usage error before any output, where FFmpeg fails once its filter graph is configured. | `methodFromOption` and `scaleFromOption` in `dither.zig`; `zig/cli/ffmpeg.zig`. |

## Channel layouts

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Scope (T23b) | The project owner chose the layout library first, then widening every container to N channels as FFmpeg reads and writes them, as further T23b parts. The library is `core/channel_layout.zig`: FFmpeg's channel ids, names and descriptions, native, custom and unspecified layouts, the 42 named layouts, and `describe`, `parse` (`from_string`), `default` and `eql` (`compare`), equal to FFmpeg's on 662 vectors of the pinned libavutil. | TODO.md T23b; `layout_vectors.c`. |
| Ambisonics | Out of scope, as T23b says: an ambisonic layout or channel (`ambisonic N`, `AMBIn`, a `USR` id from 1024 to 2047) is `UnsupportedLayout`; names of ambisonic ids still print as FFmpeg's (`AMBI5`). | A task that needs them; `Layout` gains the order. |
| Values, no allocation | A layout is a tagged union value; a custom one holds up to 64 channels inline (`LimitExceeded` beyond, where FFmpeg allocates any number), each label truncated to 15 bytes as FFmpeg's `name[16]` does. A channel text longer than 64 bytes is invalid (FFmpeg would read `USR` with that many leading zeros). | `max_custom_channels`, `max_token_len`. |
| Layouts in streams (part 2) | `audio.Format` carries the layout, and each container reports FFmpeg's: WAV's mask rules, unspecified for AU, AIFF and CAF so far (zffprobe prints `unknown`, as ffprobe). zffmpeg applies FFmpeg's command-line guess (`guess_input_channel_layout`): an unspecified layout becomes the default for its channel count when that is named, for copy as well as transcode, so a plain six-channel WAV comes out as extensible 5.1, as from FFmpeg. Part 3 widened AU to 1 to 64 channels both ways (its header holds only a count, so the layout stays unspecified, and a 5.1 input loses its layout in AU as in FFmpeg's). Part 4 widened AIFF the same way, with its `CHAN` layout (next row). Part 5 widened CAF the same way, reading `chan` before `data` (one recorded difference: `caf_chunks_around_data`'s `chan` gives FFmpeg `mono`). | `audio.guessLayout`, `convert.zig`, `wav.zig` (`layoutFor`, `extensibleMask`), `au.zig` (`Limits.max_channels`). |
| Raw layouts and the guess (part 6) | Raw PCM takes any `-ch_layout` FFmpeg parses, up to 64 channels. As FFmpeg's command line: an input `-ch_layout` names the stream's layout and turns the guess off, so `-ch_layout 6C` stays unspecified, while `-ac 6` passes `6C` to the demuxer and the guess makes it 5.1. zffmpeg sets `convert.Request.guess_layout` from that. An `-ac` of 0 or not a number is a usage error, as FFmpeg's `0C` is. | `status.rawParams`, `cli/ffmpeg.zig`, `convert.zig`. |
| Apple's `chan` (part 4) | AIFF's `CHAN` and CAF's `chan` share one reader and writer, `format/mov_chan.zig`, FFmpeg's `ff_mov_read_chan` and `ff_mov_write_chan` with their tables restated. Their oracle calls those internal functions from the static `libavformat` (`chan_vectors.c`), since no public API reaches them; the vectors sweep every tag number from 98 to 185 with every count up to 24, bitmaps and description lists. Two stricter choices: a body too short for the descriptions it declares is `InvalidFormat` (FFmpeg keeps the layout and goes on reading inside the AIFF chunk; in CAF it seeks past it on a seekable file), and an AIFF `CHAN` after `SSND` or a CAF `chan` after `data` is skipped (FFmpeg reads a seekable file's), as a sequential reader has reported the stream. `compare.py` copies writer outputs through FFmpeg's muxer with `-guess_layout_max 0`, so its command line does not give an unspecified layout a `CHAN`. | `mov_chan.zig`, `aiff.zig`, `caf.zig`, `chan_vectors.c`, `compare.py`. |
| C number parsing | Masks (`strtoull` base 0), counts (`strtol` base 10), `USR` ids (`strtol` base 0) and `%d channels (...)` (`sscanf`) follow glibc on Linux x86-64, the reference platform: a 64-bit `long`, then C's truncation to `int`. The vectors avoid values past 32 bits, where Windows' 32-bit `long` differs. | `strtol`, `strtoull`, `scanChannels` in `channel_layout.zig`. |

## Rematrixing

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Parts (T23c) | Part 1 is the matrix builder alone, `swr_build_matrix2`, checked on 4833 matrices of the pinned libswresample (every pair of the 42 named layouts for integer and float output, option sets on 13 downmixes, 36 custom layouts against 10 others both ways); part 2 applies it to samples and gives zffmpeg the output `-ac`/`-ch_layout`. | TODO.md T23c. |
| Option values | The mix levels and the rematrix volume are libswresample's `float` options, so `Options` takes the value a `float` holds: the default `C_30DB` is `(float)M_SQRT1_2`, which every default matrix's coefficients show. `maxval` is the caller's, as `auto_matrix` picks it: 1 for integer output, `INT_MAX` for float. | `rematrix.Options`, `rematrix_vectors.c`. |
| Vector size | About 1 MB, nonzero coefficients as C99 hex floats; the named pairs are kept whole, as the rules branch on every channel combination. | `rematrix_vectors.c`. |
| Command line (part 2) | zffmpeg takes FFmpeg's output `-ac` and `-ch_layout` and nothing else of libswresample's mix (no `clev`, `slev`, `lfe_mix_level`, `rematrix_volume` or matrix encoding, which FFmpeg sets only through filter options); the library's `rematrix.Options` has them. A layout change with `-c copy` is refused (`UnsupportedOperation`), where FFmpeg ignores the option and copies, so that a requested layout is never silently dropped. | `cli/ffmpeg.zig`, `convert.Request.layout`. |
| Comparison | `compare.py` compares the remixed samples as raw PCM, not whole WAV files, so container differences recorded elsewhere stay out of it; three fixtures whose input FFmpeg reads differently (trailing AU bytes, a layout chunk after the samples) are recorded. It also found that FFmpeg's WAV muxer writes a `fact` count of 1 for an empty non-PCM stream (its sample count is 0 − `INT64_MAX`, truncated to 32 bits) where the port writes 0, a WAV writer difference outside T23c. | `compare_remix`, reference README. |

## Options and numbers

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Number syntax (T17a part 1) | `av_strtod` and `parse_number` exactly, quirks included (`0x1p3` is 1 pico, `1E` is 10^18, `nan` is not an integer), checked on 107 texts. `dB` goes through Zig's `exp2`, which may differ from glibc's in the last bit. | `core/number.zig`, `number_vectors.c`. |
| Descriptors (part 2) | Options stay plain structs; a struct declares `option_specs` (FFmpeg's names, help, ranges, constants), which `options.check` validates at compile time and `options.set` uses to set a field from text as `av_opt_set` does, checked on 136 texts. Since T25b a value is evaluated as FFmpeg's expression (core/eval.zig) with the option's constants named, as `set_string_number` does. | `core/options.zig`, `options_vectors.c`. |
| Diagnostics (part 2) | The project owner chose a sink passed explicitly, at FFmpeg's levels, with the command-line tools giving none: they keep printing errors only, so their stderr contract stays. The library reports FFmpeg's warnings to a caller that gives one (the dither fallback, the guessed layout). A `-loglevel` can come later. | `core/diagnostics.zig`, `dither.Options.diagnostics`, `convert.Request.diagnostics`. |
| `-ar 0`, `-ac 0` | zffmpeg's output `-ar 0` keeps the input's rate, as FFmpeg's encoder then does; `-ac 0` stays a usage error, before or after `-i` (FFmpeg rejects it before `-i` and ignores it after), as one rule for both. | `cli/ffmpeg.zig`, `status.layoutOption`. |

## Resampling

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Tolerance (T24) | The project owner chose a declared tolerance over porting glibc's `sin`: Zig's `std.math.sin` differs from glibc's in the last bit for 311,579 of 10,004,121 tested arguments, and glibc has CPU-specific variants, so the filter can differ from FFmpeg's by an ulp. Integer output may differ by 1 unit, float by 2^-23, double by 2^-50; frame counts, delays and chunking stay exact. On the 96 vectors integer and float outputs are exact and double ones within 2^-52. | `resample.tolerance`, port.md "Resampling". |
| Allocation | The resampler allocates its filter bank (up to millions of coefficients for extreme ratios) and its input history, as libswresample does; the stages so far did not allocate. | `resample.Engine`. |
| x86 buffering | swresample.c holds seven input samples back on x86 (`padless`), the reference platform; the port always does. It changes when samples come out, not their values. | `Engine.resample`. |
| Pipeline (part 2) | A rate change runs `aresample`'s calls exactly (FFmpeg's decoder frame sizes, its room per call, its extra and flushing calls), so that the dither's noise, which follows the calls, equals FFmpeg's. The writers' headers need the output frame count first, so `resample.outputFrames` runs the same engine in a counting mode, without samples or allocation. `av.convert` needs `Request.gpa` for a rate change and refuses one without it, or with `-c copy`. | `swr.zig`, `resample.Counter`, `convert.zig`. |

## Filter graph

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Graph API (T25a) | Two steps, as libavfilter has them: `Graph.init` creates the filters (option errors are creation errors) and `configure` negotiates once. The graph is a send/receive stage except that `receive` can fail (aresample allocates its output, as FFmpeg's `av_buffersink_get_frame` can fail) and there is no `reset`, which libavfilter graphs do not have. | `filter/graph.zig`. |
| Frames in the graph | Every frame is owned by the graph: `send` copies, filters allocate their outputs (volume scales in place), and a received frame lives until the next call. Simple and safe first; a frame pool or borrowing can come with a measured need. | `Graph.send`, `filters.Owned`. |
| Refused where FFmpeg runs | An empty frame (FFmpeg would hand aresample a call without input); a fixed-precision volume whose 256 times does not fit an int (FFmpeg's conversion is undefined); an expression with `time()`, which reads the clock. A custom layout that keeps no channel in the mask but LFE scores as no channels where FFmpeg reads a pointer's bits. | `filters.zig`, `graph.zig` `layoutScore`. |
| Graph text (T25b) | `Graph.initText` creates the source and sink before the parsed filters, as libavfilter's documented `avfilter_graph_parse_ptr` use does, so the negotiation visits them in that order. The parser's, the creation's and the expressions' error messages are FFmpeg's; `av_opt_set`'s own messages for a bad option value are not reproduced (the error is). | `filter/parse.zig`, `Graph.initText`. |
| Scheduler (T25c) | libavfilter's activation is ported as it is (queues, statuses, wanted and blocked flags, priorities, one filter at a time), not a simpler pull or push model: amix's frame sizes depend on what has arrived on each input when it runs, so only the same order gives FFmpeg's frames. The T25a pull model is gone. | `filter/graph.zig`. |
| Frames on branches | asplit and channelsplit give each output its own copy where FFmpeg shares references; filters that would write a shared frame copy it in FFmpeg anyway. A frame pool or reference counting can come with a measured need. | `cloneOwned`, `ChannelSplit.output`. |
| libswresample options | aresample takes the options the port implements (rates, formats, layouts, dither, T24's resampler); the rest of libswresample's names are `UnsupportedOption` rather than ignored. | `filters.AResample`. |

## FLAC

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Fixtures (T26a) | Most fixtures come from `generate.py`'s own FLAC writer, independent of FFmpeg and the port, so the expected samples are what was encoded. Five come from FFmpeg's encoder, for real-world LPC streams; they are committed and checked by hash, not remade in CI, because the encoder's floating-point analysis may differ between builds. | `generate.py` `FLAC_FFMPEG`, `reference/flac_fixtures.sh`. |
| Damaged input | Followed exactly as FFmpeg's parser and decoder handle it, including the valid frame its header scoring drops after junk, rather than a cleaner recovery: packets and timestamps are part of the comparison. | The FLAC contract; `flac_junk_between_frames`. |
| Parser reads | The demuxer feeds the parser 1024-byte reads, FFmpeg's raw packet size. FFmpeg's reads are shorter where its I/O buffer ends, which the port does not model; for valid streams the packets do not depend on it. | The FLAC contract's packet row. |

## Raw PCM contract

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Formats (T22c) | FFmpeg's raw formats for the port's codecs, all but s64 (FFmpeg has none), each a `Container` named as its codec, with one parser and writer (`format/raw.zig`). | `registry.zig`, `RAW_FORMATS` in `generate.py`, the reference configuration. |
| Detection by extension | As FFmpeg, the project owner's choice: a raw demuxer's extension in the input's name scores 50 when no content probe claims the stream; `sw` follows the host's byte order, as FFmpeg's `AV_NE`. The tools pass the input's name; standard input has none. | `detect.zig` (`winner`), `Source.file_name`; the registry rejects a probing demuxer with extensions until the retry loop exists. |
| Parameters | FFmpeg's option names and defaults, the project owner's choice: `-sample_rate` 44100 and `-ch_layout` mono, and zffmpeg's `-ar`/`-ac` before `-i`. Given for another format they are a usage error (`UnusedOption`), where FFmpeg warns. | `status.rawParams`, both CLIs, `detect.Source.raw`. |
| Length | A regular file's size gives the frame count up front, so raw files convert to every container; a pipe's is counted while reading, so only raw output can be written from it (`UnsupportedStreamingSize`), where FFmpeg writes placeholder sizes. zffprobe reports the counted frames either way, exactly; FFmpeg estimates a duration from the size. | `raw.Parser`, `file.regularLength`, `convert.zig`'s writer checks. |
| Partial frames | `Truncated`, as for unknown-length WAV and AU; FFmpeg decodes the whole frames. | `raw_partial_frame`, `raw_partial_sample`. |
| Lossy transcoding into raw A-law and µ-law | Compared byte for byte with FFmpeg's own conversion in `compare.py`, since the samples cannot equal the input's. | `compare_zffmpeg`. |

## Conversion pipeline

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Location and shape | `zig/format/convert.zig`, next to `detect.zig`, the other code that dispatches between containers: a `Conversion` with an input union of the parser types and a `switch` on the output container. T16 kept these exhaustive switches when AIFF made a third parser: the parsers' and writers' types and options differ, and an exhaustive `switch` on `Container` makes the compiler flag every place a new format must handle, which port.md's dispatch guidance prefers for a handful of implementations. The format registry owns the facts looked up by name. | port.md "Conversion pipeline" and "Dispatch and registration"; a vtable when callers need one handle for many formats. |
| Two phases | `init` makes every check that does not need the rest of the input and writes nothing; `run` writes. T13b can then reject a command before it creates the output file. | `convert.zig` and its tests; T13b's preflight. |
| Check order | Input header, then the request (matrix), then the output header, as FFmpeg opens the input before setting up output streams: a malformed input reports its own error even when the request would also fail. | port.md "Conversion pipeline" and `convert.zig`'s tests. |
| Copy reads raw bytes | Stream copy moves encoded data through `Parser.readData` and `Writer.writeData`, not a decode and re-encode that happens to give the same bytes, so the matrix's copy cells really copy; `readSamples` and `writeFrames` now build on them. | `wav.zig`, `au.zig`, `convert.zig`. |
| Writer header checks | `Writer.check` runs `begin`'s header checks without writing; both share one `encodeHeader`. | `wav.zig`, `au.zig`. |
| Internal writer errors | `run` treats the writer's header, frame and count errors as unreachable: `init` ran the same header checks and the parser delivers exactly the declared whole frames. Only `WriteFailed` reaches callers. | `outputFailure` in `convert.zig`; revisit if writer limits ever differ between `check` and `begin`. |
| Partial output on input failure | An exact transfer read that the input cannot fill delivers nothing, so the samples written before a truncation depend on the 4 KiB transfer boundaries. The failure itself is always reported. | `convert.zig`; delivering the readable prefix would need short reads in `readData`. |
| Rejected-input oracle | Tests expect a rejected input to fail conversion with `detect.probe`'s error, which the fixture contracts already pin, instead of repeating the fixture-to-error mapping. | `convert.zig` tests. |

## PCM encodings

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| FFmpeg's storage per codec | Each codec decodes to the packed format FFmpeg's decoder sets (s8 to u8, s24 to s32, G.711 to s16), so decoded samples compare bit for bit and later conversions start from the same values. | `Codec.storage` in `codec/pcm.zig`. |
| One per-sample conversion | `decodeSample`/`encodeSample`, specialized per codec at compile time, back both the `samples.Buffer` kernels and the older s16 slice kernels: one implementation per encoding. | `codec/pcm.zig`. |
| Floats as bits | f32 and f64 are moved as integer bit patterns, never through float registers, so NaN payloads and signaling NaNs survive as in FFmpeg's `memcpy`. | Same. |
| Tables at compile time | G.711 tables are built by `comptime` code restating FFmpeg's `build_xlaw_table`, instead of FFmpeg's run-once init or a pasted table. | `codec/g711.zig`. |
| Hash vectors | The oracle stores SHA-256 digests of FFmpeg's output over patterns both sides regenerate, keeping exhaustive 16-bit coverage in 32 lines. A mismatch says which codec and direction failed, not which sample. | `pcm_vectors.c`, `pcm.txt`; store full outputs if a mismatch needs locating. |
| Wider reference build | The reference enables every PCM decoder and encoder T20b compares; the comparison's recorded FFmpeg verdicts for four fixtures changed with it. | `build-ffmpeg.sh`, the reference README. |

## Decoded sample storage

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| One enum, FFmpeg's names | `audio.SampleFormat` has a tag per storage format (`flt`, `fltp`, ...), so names print and parse exactly as FFmpeg's and switches stay exhaustive; packed and planar forms are methods. `dsd` is left out: no supported codec produces it. | `core/audio.zig`; add `dsd` with a DSD codec. |
| FFmpeg's size bound | Buffers stay below 2^31 bytes, checked in FFmpeg's order, so every vector matches; unsigned counts make negative inputs unrepresentable instead of errors. | `core/samples.zig`. |
| Distinct errors | `InvalidArgument` (zero counts, a bad alignment) and `SizeOverflow`, where FFmpeg returns `EINVAL` for both; the vectors check that both fail. | Same. |
| `Alignment` union | `.sample_padding` and `.line = n` instead of FFmpeg's `align = 0` sentinel. | Same. |
| Oracle from libavutil | The vectors come from calling the pinned FFmpeg's functions (a C generator), not from a reimplementation, and CI regenerates and diffs them. The generator is a reference tool; nothing of it enters the port. | `zig/testing/reference/samplefmt_vectors.c`, the reference job. |
| LF vectors | The generator's output is stored with LF endings (`.gitattributes`), and MinGW's `\r\n` is stripped when generating on Windows, so both platforms give identical bytes. | `.gitattributes`, the reference README. |
| s16-only users | None since T23a: the writers check that the storage is their codec's, and `Frame` and the PCM stages take every format. | T21a widened the WAV writer, T22a AU, T23a the stages. |

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
| Output container | `-f`, else a muxer's extension in any case (the format registry's), as FFmpeg; standard output needs `-f`. | `outputContainer`; port.md "zffmpeg command". |
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
| Tag lines | Since T21c, the project owner's choice: after the nine stream lines, one `tag:<key>=<value>` line per tag, under ffprobe's names, in its order and with its duplicates, so the lines compare one to one with ffprobe's format tags; untagged streams print exactly the old report. Backslash, LF and CR are escaped (`\\`, `\n`, `\r`) to keep one tag per line; ffprobe's default writer prints them raw. | `writeReport` in `zig/cli/probe.zig`, port.md "Initial probe output", the tag probe cases, `zffprobe_tags` in `compare.py`. |

## Metadata dictionary and WAV tags

| Decision | Current choice and reason | To change it |
| --- | --- | --- |
| Dictionary model (T17b) | `metadata.Dictionary`: unmanaged, owning copies, ASCII case-insensitive keys, NUL rejected (`InvalidTag`) because FFmpeg's tags are C strings. One explicit `Duplicates` policy per `av_dict_set` flag combination the port uses (`replace`, `keep`, `keep_distinct`), with FFmpeg's entry order, confirmed against the reference `libavutil`, so tags print in ffprobe's order. A failed `put` leaves the dictionary unchanged. | `core/metadata.zig` and its tests; the tag fixtures' expected order. |
| Stored and generic names | The parser stores tags under the file's keys (`INAM`, `description`) with FFmpeg's demuxer semantics; `wav.genericTags` renames them as `wavdec.c` does at the end of the header. Renaming during parsing cannot reproduce FFmpeg's result when a repeated key replaces an earlier tag. | `wav.zig`; the `info_duplicates` and `bext_tags` fixtures. |
| Tolerant tag content | Malformed INFO content ends that list's tags; the stream stays valid, as in FFmpeg, which ignores the error. FFmpeg's recovery from a missing pad byte is ported because real writers omit it. Tag reading never changes a verdict, except through the retained-bytes limit and allocation failure. A `bext` shorter than 602 bytes gives no tags instead of FFmpeg's read into the next chunk. | `parseInfo`, `readBext`; fixture README "Tags". |
| Opt-in collection | Tags are collected only when the caller asks (`Parser.collectTags`), so the parser stays allocation-free otherwise and its other callers keep their fixed memory. | `wav.Parser`, `detect.probeWithTags`, `file.probeFile`. |
| Wave64 tags | None: FFmpeg reads only Wave64's `summarylist`, which waits for a need, and its Wave64 writer writes none. | `otherChunk` and `encodeHeader` in `wav.zig`. |
| Writer tags | `ff_riff_write_info`'s choice, reproduced without allocating (the writer stays allocation-free): a dictionary lookup per INFO code that skips what the renaming would drop as a duplicate. FFmpeg's `-bitexact` copy of the writer's tagged output is byte-identical. No `encoder` tag is added. | `infoValue`, `writeInfoList` in `wav.zig`; the `info_tags` fixture. |
| `bext` output | Opt-in, as FFmpeg's `-write_bext`, from the `bext`-named tags with FFmpeg's parsing (`strtoll`, 16-digit UMID groups, at most 8 where FFmpeg would overrun). Because reading renames those fields, a read-then-write round trip keeps only what has an INFO code, as in FFmpeg; zffmpeg does not expose the option. | `writeBext`; the `bext_written` fixture; a future zffmpeg option. |
| Carried tags | `av.convert` carries what FFmpeg's command carries by default (`copy_meta`): the project owner chose FFmpeg's default over dropping tags. Tags after the input's `data` are not carried: the sequential reader reaches them after the output header is written. compare.py checks every cell against FFmpeg's own `-bitexact` conversion. | `carriedTags` in `convert.zig`; `KNOWN_TAG_CARRY_DIFFERENCES` in `compare.py`. Carrying trailing tags needs a seekable input or a deferred header. |

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
| Second container (T12) | Sun AU with signed 16-bit big-endian PCM (encoding 3): it adds container dispatch, big-endian fields and sequential I/O through the existing `pcm` kernels without changing the decoded audio model. T22a added unknown-length AU and the other encodings. | TODO.md T12 and T22; choosing AIFF or a sample-format variant instead means rewriting T12a–T12c. |
| Stream copy (T13) | Preserves encoded media and timing, not container headers or unsupported metadata chunks. Copy between WAV s16le and AU s16be is rejected before any output, because the samples need byte swapping. | TODO.md T13's operation matrix. |
| Stable IDs | Splitting a task keeps existing IDs' meanings and appends new IDs, which need not follow execution order. The one exception, commit `8b1652a` re-splitting T43 and T47 before any work started, is mapped in TODO.md. | TODO.md "Task structure and dependency words". |
| Coverage denominator | Each subtask names its required fixtures; missing or altered required files fail, and optional corpora are reported separately with their skips. Conformance streams that cannot be generated or redistributed are fetched by pinned hash and stay required. | TODO.md "Coverage and comparison rules". |
