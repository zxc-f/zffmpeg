# Zig package: build, tests and setup

This directory holds the native Zig sources. The package is defined by
[build.zig](../build.zig) and [build.zig.zon](../build.zig.zon) at the
repository root. Write new code following
the project's [`zig-0-17` skill](../.claude/skills/zig-0-17/SKILL.md) and its
[guide](../.claude/skills/zig-0-17/references/guide.md).

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
| `zig/resample/resample.zig` | `LGPL-2.1-or-later` (SPDX header) | Derived. The Bessel I0 coefficients are copied from `libavutil/mathematics.c` (Blair and Edwards' minimax approximations, which FFmpeg took from Boost under the Boost Software License 1.0, recorded in the file); the rest is original, following `libswresample/resample.c`, `resample_template.c`, `resample_dsp.c`, `swresample.c` and `libavutil/rational.c` at the pinned revision. |
| `zig/testing/reference/resample_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it runs the pinned FFmpeg's public `swr_convert` with a rate change to print the T24 oracle and is not part of the port. |
| `zig/testing/vectors/resample.txt` | Generated data | Printed by `resample_vectors.c` from the pinned `libswresample`; see the [reference README](testing/reference/README.md). |
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
| `zig/testing/fixtures.zig`, `zig/testing/fixtures/generate.py`, `zig/testing/write_driver.zig`, `zig/testing/registry_dump.zig` | `LGPL-2.1-or-later` (SPDX header) | Original project files. |
| `zig/testing/fixtures/wav/*.wav`, `manifest.zon` | Generated data | Written by `generate.py`; see the [fixture README](testing/fixtures/README.md#provenance). |
| `zig/testing/fixtures/au/*.au`, `au/manifest.zon` | Generated data | Written by `generate.py`; see the [AU fixture README](testing/fixtures/au/README.md#provenance). |
| `.zig-version` | Not applicable | A one-line version marker. |
| `zig/README.md` | Project documentation | Original. |
| `zig/examples/*.zig` | `LGPL-2.1-or-later` (SPDX header) | Original examples; see their headers. |

[LICENSE](../LICENSE) holds the LGPL v2.1 text.
