# Zig package: build, tests and setup

This directory holds the native Zig sources. The package is defined by
[build.zig](../build.zig) and [build.zig.zon](../build.zig.zon) at the
repository root. Write new code following
the project's [`zig-0-17` skill](../.claude/skills/zig-0-17/SKILL.md) and its
[guide](../.claude/skills/zig-0-17/references/guide.md), and I/O code also
following the [`zig-io` skill](../.claude/skills/zig-io/SKILL.md).

## Compiler

Use Zig **0.17.0** exactly. Three files name it, and each does a different job:

| File | Role | Enforces the version? |
| --- | --- | --- |
| `build.zig` (`tested_zig_version`) | A `comptime` check that compares `@import("builtin").zig_version_string` with `0.17.0` and stops the build with a compile error otherwise. | Yes |
| `build.zig.zon` (`.minimum_zig_version`) | Package metadata; a floor that the build runner does not enforce. | No |
| `.zig-version` | Hint for version managers; the compiler does not read it. | No |

CI also fails when `zig version` is not `0.17.0`. Upgrade deliberately: change
all three files, the CI workflow and the docs together after validating the new
compiler.

What the next upgrade is known to touch (checked 2026-11-06 against the Zig
devlog and the `0.17.0`, `0.17.1` and `master` source; the zig-io analysis,
"The Zig source"):

- **0.17.1** (2026-11-02) is the 0.17 branch's patch release. Its `std.Io`
  fixes include `EACCES` from a file read becoming `AccessDenied` (0.17.0
  reports `Unexpected`); `std.Io.Evented` still does not compile with it.
- **After 0.17 (`master`)**: mixed operators without a defined precedence
  are compile errors (the `zig-0-17` guide, "Operator precedence after
  0.17"); `zig build --fetch` fetches every dependency without configuring
  (`--configure` is the old behavior) and `--print-tree` prints the package
  tree, neither of which the build or CI uses; dependency metadata and hash
  checks change, which a package without dependencies does not see.

## Commands

Run from the repository root. No C compiler, reference clone or network
dependency is needed.

```bash
zig build                                    # compile the av library, zffprobe and zffmpeg (Debug)
zig build probe -- path/to/file.wav          # run zffprobe; `-` reads standard input
zig build zffmpeg -- -i in.wav out.au        # run zffmpeg
zig build -Doptimize=ReleaseSafe
zig build test                               # av module tests and every example's tests
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast        # safety checks off; required for parser/size code
zig build test -Dtest-filter="truncation"    # only tests whose names contain the text
zig build test --summary all                 # list every step and its test counts
zig build test-tools                         # install the test tools that compare.py runs
zig fmt --check build.zig build.zig.zon zig/
```

`-Dtest-filter` can be repeated and applies to every test artifact; an artifact
with no matching tests runs zero tests and passes. A filtered run skips the
`zffprobe` and `zffmpeg` process checks. Build output goes to
`zig-out/` and `.zig-cache/`, both ignored by Git. A single example also still
runs on its own with `zig test zig/examples/<name>.zig`.

Python 3 (standard library only) is needed only to regenerate the WAV and AU
fixtures with `python3 zig/testing/fixtures/generate.py`; building and testing
do not need it.

The [Linux CI workflow](../.github/workflows/ci.yml) has two jobs. `linux` runs
the version check, formatting, the fixture `--check`, a compile-only cross build
for Windows, AArch64 Linux and AArch64 macOS, `zig build` in Debug and ReleaseSafe, and `zig build test` in Debug,
ReleaseSafe and ReleaseFast. `reference` builds the pinned FFmpeg with Clang and
compares every fixture with it ([testing/reference](testing/reference/README.md)).
Development is verified on Linux only; the cross build is a portability guard,
not a test run. Windows and ARM runs wait for TODO.md T62–T63.

## Build graph

- **One module, `av`**, rooted at [root.zig](root.zig) and published with
  `b.addModule`. Files inside it use ordinary relative imports. Split named
  modules only for a demonstrated need.
- **Default install step:** `b.addLibrary` compiles `av` into the static
  library `zig-out/lib/libzffmpeg.a`, so `zig build` always compiles code. It
  also installs `zig-out/bin/zffprobe` and `zig-out/bin/zffmpeg`, built from
  [cli/probe.zig](cli/probe.zig) and [cli/ffmpeg.zig](cli/ffmpeg.zig) with `av`
  imported as a module; both share [cli/status.zig](cli/status.zig).
  The artifact name is the package name, not `av`, so it does not look like an
  FFmpeg or Libav library.
- **`test` step:** one test artifact for the `av` module plus one per example.
  Each runs through `b.addRunArtifact`, so the step executes tests rather than
  only compiling them. Tests must not write to stdout, which the build runner
  uses to talk to the test runner. The step also runs `zffprobe` as a separate
  process for each entry in `probe_cases` in `build.zig`, checking stdout,
  stderr and the exit status, for WAV and AU fixtures; `set` picks the
  fixture directory. Cases that pipe a fixture through standard input cover
  non-seekable input and content detection without a file name. `zffmpeg`
  runs the same way for each entry in `convert_cases`, which can also check
  an output file's exact bytes (`b.addCheckFile`). Cases that need files
  prepared on disk (an existing output, the input as the output, a removed
  partial output, redirected standard streams) run in
  [testing/zffmpeg_cases.zig](testing/zffmpeg_cases.zig), a tool the step
  runs in a fresh output directory. It also compiles the test tools, so a
  break shows in every mode.
- **`test-tools` step:** installs `zig-out/bin/write-driver`, built from
  [testing/write_driver.zig](testing/write_driver.zig), which writes a media file
  from raw samples with the `av` writers, so the FFmpeg comparison reads actual
  Zig output (TODO.md T19a), and `zig-out/bin/registry-dump`, built from
  [testing/registry_dump.zig](testing/registry_dump.zig), which prints the codec
  and format registries for the comparison to check against FFmpeg's own
  listings (T16). They are test tools, not part of the default install.
- **Examples are registered explicitly** in the `examples` list in `build.zig`.
  CI fails when a file in `examples/` is missing from that list.
- **Tests inside `av`:** Zig analyzes lazily, so a file's tests run only when
  `root.zig` references that file from a `test` block. Add the reference with
  each new file. `root.zig` already references `testing/fixtures.zig`, which
  imports `testing/fixtures/manifest.zon` and `testing/fixtures/au/manifest.zon`
  and embeds every fixture, so a missing or changed fixture fails
  `zig build test`.
- **Targets:** `-Dtarget` and `-Doptimize` come from `standardTargetOptions` and
  `standardOptimizeOption`. The test step runs on the host; cross-target
  compilation needs its own step and is not native-run evidence.

## Package manifest

[build.zig.zon](../build.zig.zon) declares the package `zffmpeg`, version
`0.0.0`, no dependencies, and an explicit `.paths` allowlist: `build.zig`,
`build.zig.zon`, `zig/`, `LICENSE` and `README.md`. Never use `""`, which would
include the ignored `.references/` clones and the FFmpeg C tree. The package
name makes no FFmpeg API or ABI compatibility claim.

The `.fingerprint` was generated by the Zig 0.17.0 toolchain: built without the
field, it rejected the manifest and suggested this value. Never edit it; a fork
that becomes a separate package generates a new one.

## No C build dependency

The build has no C sources, no `link_libc`, no system libraries, no
`translate-c` step and no dependencies. CI builds and tests from a checkout
that contains no `.references/` directory, so the reference FFmpeg tree and a
C compiler play no part in the native build.

As build-time component selection arrives (TODO.md T55), keep one explicit
catalog with checked dependencies and omit disabled components from both the
registry and binary. It controls the parsers a consumer ships. Host probes or
system-library discovery require a recorded decision in port.md and notes.md;
do not grow a configure-like shell layer around `build.zig`. Record build time
and binary size when changing selection machinery, and investigate unexplained
slowdowns of the default build.

## Provenance

| File | License | Origin |
| --- | --- | --- |
| `build.zig`, `build.zig.zon`, `zig/root.zig` | `LGPL-2.1-or-later` (SPDX header) | Original project files. The build structure follows the Zig 0.17 build-system guide and port.md; no code is copied. |
| `zig/format/wav.zig`, `zig/io/file.zig`, `zig/cli/probe.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `wavdec.c`, `wavenc.c`, `w64.c`, `riffenc.c` and `ffprobe` were read for behavior only; no code is copied (the Wave64 GUIDs are format constants). |
| `zig/format/au.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `au.c` and `pcm.c` were read for behavior only; no code is copied. |
| `zig/format/aiff.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `aiffdec.c`, `aiffenc.c` and `aiff.c` were read for behavior only (the 80-bit rate conversion and the compression-type table); no code is copied. |
| `zig/format/caf.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `cafdec.c`, `caf.c` and `isom.h` were read for behavior only; no code is copied. |
| `zig/format/seek.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The API follows `libavformat/seek.c` and `avformat.h`; WAV's seek in `wav.zig` follows `wavdec.c` and `pcm.c` (`ff_pcm_read_seek`); no code is copied. |
| `zig/testing/reference/seek_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it seeks WAV fixtures with the pinned FFmpeg's public `libavformat` API to print the T52a oracle; not part of the port. |
| `zig/testing/vectors/seek.txt`, `seek_flac.txt` | Generated data | Printed by `seek_vectors.c` from the pinned `libavformat` and `libavcodec`; see the [reference README](testing/reference/README.md). |
| `zig/core/rational.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The arithmetic follows `libavutil/rational.c`, `mathematics.c` and `common.h` at the pinned revision, its wrap-around included; no code is copied. |
| `zig/testing/reference/rational_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's public `libavutil` rational and timestamp functions to print the T15 oracle; not part of the port. |
| `zig/testing/vectors/rational.txt` | Generated data | Printed by `rational_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/codec/bits.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The reader's over-read rules and the Golomb decoding follow `libavcodec/get_bits.h`, `golomb.h` and `unary.h`, the writer `put_bits.h` and flacenc.c's `set_sr_golomb_flac`; the CRCs are `std.hash.crc`'s, matching `libavutil/crc.c`'s FLAC tables; no code is copied. |
| `zig/format/flacmux.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `libavformat/flacenc.c`, `flacenc_header.c`, `vorbiscomment.c`, `metadata.c` and `fftools/ffmpeg_enc.c` were read for behavior; no code is copied. |
| `zig/codec/flacenc.zig`, `zig/codec/lpc.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | Translated from FFmpeg's `libavcodec/flacenc.c` and `flacdsp_lpc_template.c`, and `lpc.c`, `lpc_functions.h` and `libavutil/lls.c`, function by function, so that the floating-point analysis runs in FFmpeg's order of operations; the files name their sources and authors. |
| `zig/codec/flac.zig`, `zig/codec/flac_parser.zig`, `zig/codec/flacdec.zig`, `zig/format/flac.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `libavcodec/flac.c`, `flacdata.c`, `flac_parser.c`, `parser.c`, `flacdec.c`, `flacdsp.c`, `decode.c` and `libavformat/flacdec.c`, `rawdec.c` and `demux.c` were read for behavior (the tables restated as data); no code is copied. |
| `zig/codec/opus_rc.zig`, `zig/codec/opus.zig`, `zig/codec/celt.zig`, `zig/codec/celt_tab.zig`, `zig/codec/opusdec.zig`, `zig/codec/silk.zig`, `zig/codec/silk_tab.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/opus/rc.c`, `parse.c`, `dec_celt.c`, `celt.c`, `pvq.c`, `dsp.c`, `silk.c`, `dec.c` and `tab.c` (the tables transcribed), function by function, so that the decoder runs in FFmpeg's order of operations; the files name their sources and authors. |
| `zig/codec/mpegaudio.zig`, `zig/format/mp3.zig`, `zig/format/id3v2.zig`, `zig/format/id3v1.zig`, `zig/format/avlanguage.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/mpegaudiodecheader.c`, `mpegaudiotabs.h`, `mpegaudio_parser.c`, `parser.c` (`ff_combine_frame`), `libavformat/mp3dec.c`, `id3v2.c`, `id3v1.c` (the genre table), `avlanguage.c` (its ISO 639-2 codes, computed from the table by its lookup), `replaygain.c` and `demux_utils.c` (`ff_itunes_parse_smpb`), T29a; the files name their sources and authors. |
| `zig/codec/mp3dec.zig`, `zig/codec/mp3_tab.zig`, `zig/codec/mpadsp.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/mpegaudiodec_template.c` and `mpegaudiodec_float.c` (the Layer III decoder), `mpegaudiodec_common.c`, `mpegaudiodec_common_tablegen.h` and `mpegaudio_tablegen.h` (the tables, transcribed or computed as FFmpeg computes them), `mpegaudiodsp.c`, `mpegaudiodsp_template.c`, `x86/mpegaudiodsp.c` (`apply_window_mp3`, the window the reference build runs), `mpegaudiodsp_data.c` and `dct32_template.c`, function by function, so that the decoder runs in FFmpeg's order of operations (T29b); the files name their sources and authors. |
| `zig/codec/mp2enc.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/mpegaudioenc.c` (`mpa_encode_init`, `idct32`, `filter`, `compute_scale_factors`, `compute_bit_allocation`, `encode_frame`) and `mpegaudiotab.h` (`costab32`, `bitinv32`, `quant_snr`, `fixed_smr`, `nb_scale_factors`), function by function, in FFmpeg's integer and float arithmetic (T29d). |
| `zig/codec/parser.zig`, `zig/codec/adts.zig`, `zig/codec/mpeg4audio.zig`, `zig/format/aac.zig`, `zig/format/apetag.zig`, `zig/format/adtsmux.zig` | `LGPL-2.1-or-later` (SPDX headers, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/parser.c` (`ff_combine_frame`), `adts_header.c`, `aac_parser.c`, `aac_ac3_parser.c`, `mpeg4audio.c`, `mpeg4audio_copy_pce.h`, and `libavformat/aacdec.c`, `apetag.c` and `adtsenc.c`, function by function (T30a); the files name their sources and authors. |
| `zig/codec/aacdec.zig`, `zig/codec/aac_tab.zig` | `LGPL-2.1-or-later` (SPDX headers, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/aac/aacdec.c`, `aacdec_proc_template.c`, `aacdec_dsp_template.c`, `aacdec_float.c`, `aacdec_float_coupling.h` and `aacdec_tab.c`, and `libavcodec/aactab.c`, `kbdwin.c`, `sinewin_tablegen.h`, `cbrt_tablegen.h` and `lpc_functions.h`, function by function, the tables transcribed or computed as FFmpeg computes them (T30b); the files name their sources and authors. |
| `zig/codec/aacsbr.zig`, `zig/codec/sbr_tab.zig` | `LGPL-2.1-or-later` (SPDX headers, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/aacsbr.c`, `aacsbr_template.c`, `sbrdsp.c`, `sbrdsp_template.c`, `aacsbrdata.h` and `aac/aacdec_tab.c` (the SBR Huffman tables), function by function, the tables transcribed by a script (T30c). |
| `zig/codec/aacps.zig`, `zig/codec/ps_tab.zig` | `LGPL-2.1-or-later` (SPDX headers, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/aacps_common.c`, `aacps.c`, `aacps_tablegen.h`, `aacpsdsp_template.c` and `aacpsdata.c`, function by function, the data tables transcribed by a script (T30d). |
| `zig/codec/adpcm.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright line kept) | **Derived** from FFmpeg's `libavcodec/adpcm.c`, `adpcmenc.c` and `adpcm_data.c` (the IMA WAV and MS paths, the trellis search, the tables from the ADPCM reference source and libsndfile), function by function (T31a). |
| `zig/format/wavadpcm.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavformat/wavdec.c`, `libavcodec/decode.c`, `encode.c` and the ffmpeg program's decoding were read for behavior only; no code is copied (T31a). |
| `zig/testing/reference/adpcm_fixtures.sh`, `adpcm_wav_vectors.sh`, `zig/testing/vectors/adpcm_wav.txt`, `seek_adpcm.txt`, `zig/testing/fixtures/adpcm/adpcm_ffmpeg_*.wav` | `LGPL-2.1-or-later` (SPDX headers); generated data | Original reference scripts: `adpcm_fixtures.sh` encodes the `adpcm_ffmpeg_*` fixtures with the reference build's ADPCM encoders, `adpcm_wav_vectors.sh` prints what its ffprobe and ffmpeg make of every ADPCM fixture; their output; not part of `av`. |
| `zig/testing/reference/speed_check.py` | `LGPL-2.1-or-later` (SPDX header) | An original benchmark helper: a feature's conversion timed with hyperfine against the reference and native FFmpeg builds (CLAUDE.md "Speed check"); not part of `av`. |
| `zig/codec/alac.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/alac.c`, `alacenc.c`, `alacdsp.c` and `alac_data.c`, function by function (T31b). |
| `zig/format/cafmux.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavformat/cafenc.c` and `mov_chan.c` were read for behavior only; no code is copied (T31b). |
| `zig/format/cafalac.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavformat/cafdec.c`, `libavcodec/decode.c` and the ffmpeg program's decoding were read for behavior only; no code is copied (T31b). |
| `zig/testing/reference/alac_fixtures.sh`, `alac_caf_vectors.sh`, `zig/testing/vectors/alac_caf.txt`, `zig/testing/fixtures/alac/alac_ffmpeg_*.caf` | `LGPL-2.1-or-later` (SPDX headers); generated data | Original reference scripts: `alac_fixtures.sh` encodes the `alac_ffmpeg_*` fixtures with the reference build's ALAC encoder and CAF muxer, `alac_caf_vectors.sh` prints what its ffprobe and ffmpeg make of every ALAC fixture; their output; not part of `av`. |
| `zig/testing/reference/alac_vectors.c`, `zig/testing/vectors/alac.txt` | `LGPL-2.1-or-later` (SPDX header); generated data | An original reference tool printing the pinned FFmpeg's ALAC encoder's packets and decoder's samples, and its output; see the [reference README](testing/reference/README.md). |
| `zig/codec/g722.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/g722.c`, `g722.h`, `g722dsp.c`, `g722dec.c` and `g722enc.c` (the QMF, the band predictors, the decoder and the encoder with its trellis search), function by function (T31c). |
| `zig/codec/g726.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/g726.c` (Float11, the tables, the quantizers, the decoder and encoder and their little-endian frame functions), function by function (T31c). |
| `zig/testing/reference/g72x_vectors.c`, `zig/testing/vectors/g72x.txt` | `LGPL-2.1-or-later` (SPDX header); generated data | An original reference tool printing the pinned FFmpeg's G.722 and G.726 encoders' packets and decoders' samples, and its output; see the [reference README](testing/reference/README.md). |
| `zig/testing/signals.zig` | `LGPL-2.1-or-later` (SPDX header) | Original: the vector generators' test signals, shared by the ALAC and G.72x tests; not part of `av`'s API. |
| `zig/codec/ac3.zig`, `zig/codec/aac_ac3_parser.zig` | `LGPL-2.1-or-later` (SPDX headers, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/ac3_parser.c`, `ac3tab.c`, `ac3_channel_layout_tab.h` and `aac_ac3_parser.c`: AC-3 and E-AC-3 headers, the AC-3 parser, and the frame splitting it shares with the AAC parser (`codec/adts.zig`) (T32a). |
| `zig/codec/ac3dec.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavcodec/ac3dec.c`, `ac3dec_float.c`, `ac3dec_data.c`, `ac3.c`, `ac3dsp.c` and `ac3tab.c`, function by function (T32a). |
| `zig/core/lfg.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright line kept) | **Derived** from FFmpeg's `libavutil/lfg.c` and `lfg.h` (`av_lfg_init`, `av_lfg_get`) (T32a). |
| `zig/format/ac3.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright line kept) | **Derived** from FFmpeg's `libavformat/ac3dec.c` (the probe) and `rawdec.c` (the raw audio header and partial packets) (T32a). |
| `zig/format/ac3decode.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavcodec/decode.c` and the ffmpeg program's decoding were read for behavior only; no code is copied (T32a). |
| `zig/testing/reference/ac3_vectors.c`, `ac3_fixtures.sh`, `zig/testing/vectors/ac3_decode.txt`, `zig/testing/fixtures/ac3/ac3_ffmpeg_*.ac3` | `LGPL-2.1-or-later` (SPDX headers); generated data | Original reference tools: `ac3_vectors.c` prints the pinned demuxer's packets and decoder's frames for every AC-3 fixture, `ac3_fixtures.sh` encodes the `ac3_ffmpeg_*` fixtures with the reference build's AC-3 encoder; their output; not part of `av`. |
| `zig/format/aug72x.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavformat/au.c`, `pcm.c`, the G.722 and G.726 encoders' registrations and the ffmpeg program's frame grouping were read for behavior only; no code is copied (T31c). |
| `zig/testing/reference/g72x_fixtures.sh`, `g72x_au_vectors.sh`, `zig/testing/vectors/g72x_au.txt`, `zig/testing/fixtures/g72x/g72x_ffmpeg_*.au` | `LGPL-2.1-or-later` (SPDX headers); generated data | Original reference scripts: `g72x_fixtures.sh` encodes the `g72x_ffmpeg_*` fixtures with the reference build's G.722 and G.726 encoders and AU muxer, `g72x_au_vectors.sh` prints what its ffprobe and ffmpeg make of every G.72x fixture; their output; not part of `av`. |
| `zig/testing/reference/adpcm_vectors.c`, `zig/testing/vectors/adpcm.txt` | `LGPL-2.1-or-later` (SPDX header); generated data | An original reference tool printing the pinned FFmpeg's ADPCM encoders' packets and decoders' samples, and its output; see the [reference README](testing/reference/README.md). |
| `zig/testing/reference/heaac_encode.c` | `LGPL-2.1-or-later` (SPDX header) | Original fixture tool: it encodes the `aac_fdk_*` HE-AAC fixtures with the system's libfdk-aac (the Fraunhofer FDK AAC library, under its own license, not distributed here); not part of `av`. |
| `zig/format/aacdecode.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. `libavcodec/decode.c` and the ffmpeg program's decoding (`fftools/ffmpeg_dec.c`) were read for behavior only; no code is copied. |
| `zig/testing/reference/aac_tab_vectors.c`, `aac_fixtures.sh` | `LGPL-2.1-or-later` (SPDX header) | Original reference tools: `aac_tab_vectors.c` prints the pinned FFmpeg's AAC decoder tables after their static initialization, `aac_fixtures.sh` encodes the `aac_ffmpeg_*` fixtures with the reference build's AAC encoder; not part of `av`. |
| `zig/testing/vectors/aac_tab.txt`, `aac_decode.txt` | Generated data | Printed by `aac_tab_vectors.c` and `mp3_decode_vectors.c` from the pinned `libavcodec`; see the [reference README](testing/reference/README.md). |
| `zig/format/mp2mux.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `libavformat/rawenc.c` (the mp2 muxer), `libavcodec/encode.c` (`pad_last_frame`) and the ffmpeg program's frame grouping for a fixed-frame-size encoder were read for behavior; no code is copied. |
| `zig/testing/opus_compare.zig` | `BSD-3-Clause` (SPDX header, Xiph's notice kept) | **Derived** from libopus 1.5.2's `src/opus_compare.c`, RFC 6716's quality check; a test tool, not part of `av`. |
| `zig/testing/opus_vector_driver.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Reads RFC 6716's `.bit` format and checks final ranges as libopus' `opus_demo` does; no code is copied. |
| `zig/codec/float_dsp.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright lines kept) | **Derived** from FFmpeg's `libavutil/float_dsp.c` (the C kernels). |
| `zig/core/libm.zig`, `zig/core/libm/*.zig` but `hyperbolic.zig`, `hyptab.zig`, `cbrtf.zig` and `atanf.zig` | `LGPL-2.1-or-later` (SPDX headers, the FSF and Sun copyright lines kept) | **Derived** from the GNU C Library 2.44's `exp2f`, `sinf` and `cosf` (Arm's optimized-routines, constants read from the installed `libm.so.6`), `powf` (Arm, its FMA variant; T30b), `log2f` (Arm, its FMA variant; T30c) and its double `sin`, `cos`, `tan` (IBM, with fdlibm's argument reduction), `asin`, `acos`, `atan`, `atan2` (IBM), `exp`, `exp2`, `log`, `pow` (Arm), `hypot` and `ldexp` (fdlibm's `scalbn`), the tables transcribed; notes.md "Floating-point library". |
| `zig/core/libm/hyperbolic.zig`, `zig/core/libm/hyptab.zig`, `zig/core/libm/cbrtf.zig`, `zig/core/libm/atanf.zig` | `MIT` (SPDX headers, CORE-MATH's copyright and permission notice kept) | **Derived** from the GNU C Library 2.44's `sinh`, `cosh` and `tanh` and their tables, its `cbrtf` (T30b) and its `atanf` and `atan2f` (T30d), from the CORE-MATH project. |
| `zig/core/bessel.zig` | `LGPL-2.1-or-later` (SPDX header, FFmpeg's copyright line kept) | **Derived** from FFmpeg's `libavutil/mathematics.c` (`av_bessel_i0`, `eval_poly`); the coefficients are Blair and Edwards' minimax approximations, which FFmpeg took from Boost under the Boost Software License 1.0, recorded in the file. Shared by the resampler and the AAC tables. |
| `zig/format/framehash.zig`, `zig/testing/hash_driver.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The text follows `libavformat/framecrcenc.c`, `framehash.c` and `hashenc.c`; no code is copied. |
| `zig/testing/reference/fate_sync.sh` | `LGPL-2.1-or-later` (SPDX header) | Original script: it fetches FATE samples for the optional coverage; the samples stay in the ignored `.references/` and are never committed. |
| `zig/testing/reference/flac_vectors.c`, `flac_fixtures.sh` | `LGPL-2.1-or-later` (SPDX header) | Original reference tools: `flac_vectors.c` drives the pinned FFmpeg's public `libavformat` and `libavcodec` API to print the T26a oracle, and `flac_fixtures.sh` runs its FLAC encoder to make five fixtures; not part of the port. |
| `zig/testing/vectors/flac.txt` | Generated data | Printed by `flac_vectors.c` from the pinned `libavformat` and `libavcodec`; see the [reference README](testing/reference/README.md). |
| `zig/testing/fixtures/flac/*.flac`, `flac/manifest.zon` | Generated data | Written by `generate.py`, except `flac_ffmpeg_*.flac`, made by the reference build's FLAC encoder through `flac_fixtures.sh`; see the [FLAC fixture README](testing/fixtures/flac/README.md). |
| `zig/format/raw.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `pcmdec.c`, `pcmenc.c` and `pcm.c` were read for behavior only; no code is copied. |
| `zig/format/registry.zig`, `zig/codec/registry.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The names, long names, properties, extensions, MIME types and default codecs are FFmpeg's, from `libavcodec/codec_desc.c`, `allcodecs.c`, `libavformat/allformats.c` and the format descriptors (T16); no code is copied. |
| `zig/format/detect.zig`, `zig/format/replay.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The probes and their scoring follow `wav_probe`, `w64_probe`, `au_probe`, `aiff_probe`, CAF's `probe` and `format.c` (T16, T22b, T22d); no code is copied. |
| `zig/codec/g711.zig` | `LGPL-2.1-or-later` (SPDX header) | **Derived** from FFmpeg's `libavcodec/pcm_tablegen.h` at commit `5d5a38a7e46be296eab75982c0986054f731e19e`, © 2010 Reimar Döffinger, `LGPL-2.1-or-later`; its A-law and mu-law conversions come from Sun Microsystems' `g711.c` (unrestricted use). The header keeps that attribution. |
| `zig/testing/reference/pcm_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it drives the pinned FFmpeg's public `libavcodec` API to print the T20b oracle and is not part of the port. |
| `zig/testing/vectors/pcm.txt` | Generated data | Printed by `pcm_vectors.c` from the pinned `libavcodec`; see the [reference README](testing/reference/README.md). |
| `zig/core/metadata.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Key matching, the duplicate-key flags and the entry order follow `libavutil/dict.c`; no code is copied. |
| `zig/core/samples.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The size, line and plane rules follow `libavutil/samplefmt.c`; no code is copied. |
| `zig/core/channel_layout.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The channel ids, names, descriptions and named layouts' masks are FFmpeg's (`libavutil/channel_layout.h` and `.c`), restated as data; parsing and descriptions follow `channel_layout.c`, `opt.c` (`av_opt_get_key_value`) and `avstring.c` (`av_get_token`) at the pinned revision; no code is copied. |
| `zig/resample/audioconvert.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The conversions follow `libswresample/audioconvert.c` (`CONV_FUNC`) at the pinned revision; no code is copied. |
| `zig/resample/dither.zig` | `LGPL-2.1-or-later` (SPDX header) | Derived: the noise-shaping filter coefficients are copied from `libswresample/noise_shaping_data.c` (Copyright (C) 2013 Michael Niedermayer; the filters credit SoX and Shibata), as its header records. The rest is original and follows `dither.c`, `dither_template.c`, `swresample.c` and `rematrix_template.c` at the pinned revision. |
| `zig/testing/reference/sampleconv_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it drives the pinned FFmpeg's public `libswresample` API to print the T23a oracle and is not part of the port. |
| `zig/testing/vectors/sampleconv.txt` | Generated data | Printed by `sampleconv_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
| `zig/testing/reference/dither_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it drives the pinned FFmpeg's public `libswresample` API with its dither options to print the T23a dither oracle and is not part of the port. |
| `zig/testing/reference/layout_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it drives the pinned FFmpeg's public `libavutil` channel layout API to print the T23b oracle and is not part of the port. |
| `zig/testing/vectors/layout.txt` | Generated data | Printed by `layout_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/format/mov_chan.zig` | `LGPL-2.1-or-later` (SPDX header) | Original code. The layout tags and their channel lists (`mov_chan.h`, `mov_ch_layout_map` in `mov_chan.c`) and the writer's table (`mov_channel_layout` in `isom.c`) are FFmpeg's data at the pinned revision, restated; reading and writing follow `ff_mov_read_chan` and `ff_mov_write_chan`. |
| `zig/testing/reference/chan_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's internal `ff_mov_read_chan` and `ff_mov_write_chan` from the static `libavformat` to print the T23b `chan` oracle and is not part of the port. |
| `zig/resample/rematrix.zig` | `LGPL-2.1-or-later` (SPDX header) | Original code. The mix rules and constants of `libswresample/rematrix.c` (`build_matrix`, `clean_layout`, `clean_downmix`, `sane_layout`), `options.c` and `swresample_internal.h` at the pinned revision are restated; no code is copied. |
| `zig/testing/reference/rematrix_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's public `swr_build_matrix2` to print the T23c oracle and is not part of the port. |
| `zig/testing/reference/remix_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it runs the pinned FFmpeg's public `swr_convert` with a channel layout change on generated input to print the T23c remix oracle and is not part of the port. |
| `zig/testing/vectors/remix.txt` | Generated data | Printed by `remix_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
| `zig/resample/resample.zig` | `LGPL-2.1-or-later` (SPDX header) | Original (the Bessel I0 function is `core/bessel.zig`'s), following `libswresample/resample.c`, `resample_template.c`, `resample_dsp.c`, `swresample.c` and `libavutil/rational.c` at the pinned revision. |
| `zig/testing/reference/resample_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it runs the pinned FFmpeg's public `swr_convert` with a rate change to print the T24 oracle and is not part of the port. |
| `zig/testing/vectors/resample.txt` | Generated data | Printed by `resample_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
| `zig/core/number.zig` | `LGPL-2.1-or-later` (SPDX header) | Original code. The SI prefix values are FFmpeg's (`si_prefixes` in `libavutil/eval.c`), restated; parsing follows `av_strtod`, fftools' `parse_number` and glibc's `strtod`/`strtoul` in the C locale. |
| `zig/testing/reference/number_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's `av_strtod` and restates fftools' `parse_number` to print the T17a oracle; not part of the port. |
| `zig/testing/vectors/number.txt` | Generated data | Printed by `number_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/core/options.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Setting follows `av_opt_set` in `libavutil/opt.c` (`set_string_number`, `set_string_bool`, `write_number`) and `eval.c`'s whitespace removal and constants at the pinned revision; no code is copied. |
| `zig/core/diagnostics.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The levels are `libavutil/log.h`'s. |
| `zig/core/eval.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The grammar and evaluation follow `libavutil/eval.c`, `sfc64.h` and `reverse.c` at the pinned revision; no code is copied. |
| `zig/testing/reference/eval_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's `av_expr_parse` and `av_expr_eval` to print the T25b expression oracle; not part of the port. |
| `zig/testing/vectors/eval.txt` | Generated data | Printed by `eval_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/testing/reference/multigraph_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it builds and runs multi-input, multi-output graphs with the pinned FFmpeg's public `libavfilter` API to print the T25c oracle; not part of the port. |
| `zig/testing/vectors/multigraph.txt` | Generated data | Printed by `multigraph_vectors.c` from the pinned `libavfilter`, `libswresample` and `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/filter/formats.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The lists and merges follow `libavfilter/formats.c` (`MERGE_FORMATS`, `MERGE_REF`, `merge_channel_layouts_internal`, the checks) at the pinned revision; no code is copied. |
| `zig/filter/filters.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The filters follow `libavfilter/af_anull.c`, `af_aformat.c`, `af_volume.c`, `af_aresample.c` and `audio.c`, options `libavutil/opt.c` and `eval.c`, timestamps `libswresample/swresample.c`, at the pinned revision; no code is copied. |
| `zig/filter/parse.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Parsing follows `libavfilter/graphparser.c`, `avfilter.c` (`ff_filter_opt_parse`), `libavutil/avstring.c` (`av_get_token`) and `opt.c` (`av_opt_get_key_value`) at the pinned revision; no code is copied. |
| `zig/filter/negotiate.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Negotiation follows `libavfilter/avfiltergraph.c` and `formats.c` at the pinned revision; no code is copied. |
| `zig/filter/multi.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The filters follow `libavfilter/split.c`, `af_channelsplit.c`, `af_channelmap.c`, `af_pan.c` and `af_amix.c`, with `libavutil/float_dsp.c` and libswresample's matrix and channel mapping, at the pinned revision; no code is copied. |
| `zig/filter/graph.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Negotiation and configuration follow `libavfilter/avfiltergraph.c`, `avfilter.c`, `buffersrc.c`, `buffersink.c` and `formats.c` at the pinned revision; no code is copied. |
| `zig/testing/reference/options_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's `av_opt_set` on libswresample's options to print the T17a option oracle; not part of the port. |
| `zig/testing/vectors/options.txt` | Generated data | Printed by `options_vectors.c` from the pinned `libswresample` and `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/testing/reference/graph_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it builds filter graphs with the pinned FFmpeg's public `libavfilter` API to print the T25a graph oracle; not part of the port. |
| `zig/testing/vectors/graph.txt` | Generated data | Printed by `graph_vectors.c` from the pinned `libavfilter`, `libswresample` and `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/testing/vectors/rematrix.txt` | Generated data | Printed by `rematrix_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
| `zig/testing/vectors/chan.txt` | Generated data | Printed by `chan_vectors.c` from the pinned `libavformat`; see the [reference README](testing/reference/README.md). |
| `zig/testing/vectors/dither.txt` | Generated data | Printed by `dither_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
| `zig/testing/reference/samplefmt_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's public `libavutil` API to print the T20a oracle and is not part of the port. |
| `zig/testing/vectors/samplefmt.txt` | Generated data | Printed by `samplefmt_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/core/packet.zig`, `zig/core/frame.zig`, `zig/core/stage.zig`, `zig/testing/delay_stage.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The send/receive rules follow `libavcodec/avcodec.h`; the fields follow `libavcodec/packet.h` and `libavutil/frame.h`; no code is copied. |
| `zig/format/convert.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The operation matrix is TODO.md T13's; no FFmpeg source maps to it directly. |
| `zig/cli/ffmpeg.zig`, `zig/cli/status.zig`, `zig/testing/zffmpeg_cases.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `fftools/ffmpeg_opt.c` (`assert_file_overwrite`) was read for the `-y`/`-n` and same-file behavior only; no code is copied. |
| `zig/testing/reference/build-ffmpeg.sh`, `compare.py` | `LGPL-2.1-or-later` (SPDX header) | Original scripts; they build and run the separate, unmodified FFmpeg reference. |
| `zig/codec/pcm.zig`, `zig/core/audio.zig`, `zig/core/time.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Behavior follows FFmpeg's `libavcodec/pcm.c`, `libavutil/mathematics.c`, `channel_layout.h` and `samplefmt.c` at the pinned revision; no code is copied. |
| `zig/testing/fixtures.zig`, `zig/testing/fixtures/generate.py`, `zig/testing/write_driver.zig`, `zig/testing/registry_dump.zig`, `zig/testing/hostile.zig` | `LGPL-2.1-or-later` (SPDX header) | Original project files. |
| `zig/testing/fixtures/wav/*.wav`, `manifest.zon` | Generated data | Written by `generate.py`; see the [fixture README](testing/fixtures/README.md#provenance). |
| `zig/testing/fixtures/au/*.au`, `au/manifest.zon` | Generated data | Written by `generate.py`; see the [AU fixture README](testing/fixtures/au/README.md#provenance). |
| `.zig-version` | Not applicable | A one-line version marker. |
| `zig/README.md` | Project documentation | Original. |
| `zig/examples/*.zig` | `LGPL-2.1-or-later` (SPDX header) | Original examples; see their headers. |

[LICENSE](../LICENSE) holds the LGPL v2.1 text.
