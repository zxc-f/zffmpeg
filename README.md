# zffmpeg

A native Zig multimedia library and tools, developed incrementally from FFmpeg's
documented behavior and algorithms. The first planned path is signed 16-bit PCM
in WAV, followed by a small probe tool.

Current state: architecture, an implementation checklist, two tested standalone
examples (I/O patterns and a PCM s16 kernel) and a Linux CI workflow that checks
them. The native library build, codecs, containers and CLI are still planned.
The baseline compiler is **Zig 0.17.0**.

## Project files

- [port.md](port.md): architecture, supported-subset contracts and verification plan.
- [TODO.md](TODO.md): ordered tasks and completion evidence; T01 is next.
- [CLAUDE.md](CLAUDE.md): repository guidance for development; [AGENTS.md](AGENTS.md)
  contains only `@CLAUDE.md` so other agents load the same file.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg source analysis.
- [zig/examples/io_patterns.zig](zig/examples/io_patterns.zig): runnable I/O example.
- [zig/examples/pcm_s16.zig](zig/examples/pcm_s16.zig): runnable PCM kernel example.
- [.github/workflows/ci.yml](.github/workflows/ci.yml): Linux CI for the examples.
- [LICENSE](LICENSE): GNU LGPL v2.1 text for the project's `LGPL-2.1-or-later` sources.

The project has its own Git repository. Only this project's documentation and
native Zig sources are tracked. FFmpeg and zigimg are separate reference clones
under `.references/`, excluded by [.gitignore](.gitignore); they are neither
submodules nor native package dependencies.

## Clone the reference repositories

Clone **both repositories** before source research or reference comparisons.
Run these commands from the zffmpeg project root in a fresh checkout:

```text
git clone --depth 1 --no-checkout https://github.com/FFmpeg/FFmpeg.git .references/ffmpeg
git -C .references/ffmpeg fetch --depth 1 origin 5d5a38a7e46be296eab75982c0986054f731e19e
git -C .references/ffmpeg checkout --detach 5d5a38a7e46be296eab75982c0986054f731e19e

git clone --depth 1 --no-checkout https://github.com/zigimg/zigimg.git .references/zigimg
git -C .references/zigimg fetch --depth 1 origin 083d0304840a3f5fd547c2e2005148a18886c401
git -C .references/zigimg checkout --detach 083d0304840a3f5fd547c2e2005148a18886c401
```

Do not rerun clone over an existing directory. To inspect an existing setup,
run `git -C .references/ffmpeg rev-parse HEAD` and
`git -C .references/zigimg rev-parse HEAD`. Refresh revisions deliberately and
update the corresponding analysis and verification evidence.

| Reference | Pinned revision | Role |
| --- | --- | --- |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg.git) | `5d5a38a7e46be296eab75982c0986054f731e19e` | Multimedia algorithms, behavior and differential testing. |
| [zigimg](https://github.com/zigimg/zigimg.git) | `083d0304840a3f5fd547c2e2005148a18886c401` | Modern Zig I/O, ownership, build and metaprogramming examples. |

The local source map is `.references/ffmpeg/libavcodec/`,
`.references/ffmpeg/libavformat/`, and the other upstream directories documented
in port.md. Documentation source links pin the upstream commit so they also work
before the clones are present. Keep reference checkouts out of commits and
release packages; do not force-add `.references/`.

## Run the current examples

The examples require Zig 0.17.0 and no reference clone or C compiler:

```text
zig version
zig fmt --check zig/
zig test zig/examples/io_patterns.zig
zig test zig/examples/pcm_s16.zig
```

Repeat each `zig test` with `-O ReleaseSafe` and `-O ReleaseFast`. The
[Linux CI workflow](.github/workflows/ci.yml) runs exactly these checks on every
pull request and on pushes to `master`, after verifying that `zig version` is
`0.17.0`. Native Windows CI is deferred; see T11 in [TODO.md](TODO.md).

The I/O tests exercise memory and file adapters, fragmented input, truncation,
generic and file-specific I/O failure, and output capacity. The PCM tests cover
both byte orders, signed extrema, invalid buffer sizes and unchanged output on
failure. There is no root `build.zig` yet, so `zig build` and `zig build test`
arrive with T01. Follow [TODO.md](TODO.md) for the first library milestone.

## Source provenance

The standalone examples are original project code and declare
`LGPL-2.1-or-later` in their source headers; [LICENSE](LICENSE) contains the
GNU Lesser General Public License v2.1 text, copied verbatim from FFmpeg's
`COPYING.LGPLv2.1` at the pinned revision. Reference repositories retain their own
license files and notices inside their ignored clones. Record the source,
revision, applicable license and attribution for each future derived file;
using Zig does not change the provenance of an algorithm or implementation.
