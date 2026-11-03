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
zig build test-tools                         # install the write driver that compare.py runs
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
  runs in a fresh output directory. It also compiles the write driver, so a
  break shows in every mode.
- **`test-tools` step:** installs `zig-out/bin/write-driver`, built from
  [testing/write_driver.zig](testing/write_driver.zig). It writes a media file
  from raw samples with the `av` writers, so the FFmpeg comparison reads actual
  Zig output (TODO.md T19a). It is a test tool, not part of the default install.
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
| `zig/format/wav.zig`, `zig/io/file.zig`, `zig/cli/probe.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `wavdec.c`, `wavenc.c`, `riffenc.c` and `ffprobe` were read for behavior only; no code is copied. |
| `zig/format/au.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `au.c` and `pcm.c` were read for behavior only; no code is copied. |
| `zig/format/detect.zig`, `zig/format/prefix.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The detection rule is the project's own; FFmpeg's `au_probe` in `au.c` was read only to record where it differs. |
| `zig/core/samples.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The size, line and plane rules follow `libavutil/samplefmt.c`; no code is copied. |
| `zig/testing/reference/samplefmt_vectors.c` | `LGPL-2.1-or-later` (SPDX header) | Original reference tool: it calls the pinned FFmpeg's public `libavutil` API to print the T20a oracle and is not part of the port. |
| `zig/testing/vectors/samplefmt.txt` | Generated data | Printed by `samplefmt_vectors.c` from the pinned `libavutil`; see the [reference README](testing/reference/README.md). |
| `zig/core/packet.zig`, `zig/core/frame.zig`, `zig/core/stage.zig`, `zig/testing/delay_stage.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The send/receive rules follow `libavcodec/avcodec.h`; the fields follow `libavcodec/packet.h` and `libavutil/frame.h`; no code is copied. |
| `zig/format/convert.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. The operation matrix is TODO.md T13's; no FFmpeg source maps to it directly. |
| `zig/cli/ffmpeg.zig`, `zig/cli/status.zig`, `zig/testing/zffmpeg_cases.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. FFmpeg's `fftools/ffmpeg_opt.c` (`assert_file_overwrite`) was read for the `-y`/`-n` and same-file behavior only; no code is copied. |
| `zig/testing/reference/build-ffmpeg.sh`, `compare.py` | `LGPL-2.1-or-later` (SPDX header) | Original scripts; they build and run the separate, unmodified FFmpeg reference. |
| `zig/codec/pcm.zig`, `zig/core/audio.zig`, `zig/core/time.zig` | `LGPL-2.1-or-later` (SPDX header) | Original. Behavior follows FFmpeg's `libavcodec/pcm.c`, `libavutil/mathematics.c`, `channel_layout.h` and `samplefmt.c` at the pinned revision; no code is copied. |
| `zig/testing/fixtures.zig`, `zig/testing/fixtures/generate.py`, `zig/testing/write_driver.zig` | `LGPL-2.1-or-later` (SPDX header) | Original project files. |
| `zig/testing/fixtures/wav/*.wav`, `manifest.zon` | Generated data | Written by `generate.py`; see the [fixture README](testing/fixtures/README.md#provenance). |
| `zig/testing/fixtures/au/*.au`, `au/manifest.zon` | Generated data | Written by `generate.py`; see the [AU fixture README](testing/fixtures/au/README.md#provenance). |
| `.zig-version` | Not applicable | A one-line version marker. |
| `zig/README.md` | Project documentation | Original. |
| `zig/examples/*.zig` | `LGPL-2.1-or-later` (SPDX header) | Original examples; see their headers. |

[LICENSE](../LICENSE) holds the LGPL v2.1 text.
