# zffmpeg

A native Zig multimedia library and tools, developed incrementally from FFmpeg's
documented behavior and algorithms. The first planned path is signed 16-bit PCM
in WAV, followed by a small probe tool.

Current state: architecture, an implementation checklist and a tested standalone
I/O example. The native library build, codecs, containers and CLI are still
planned. The baseline compiler is **Zig 0.17.0**.

## Project files

- [port.md](port.md): architecture, supported-subset contracts and verification plan.
- [TODO.md](TODO.md): ordered tasks and completion evidence; T01 is next.
- [AGENTS.md](AGENTS.md): repository guidance for development.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg source analysis.
- [zig/examples/io_patterns.zig](zig/examples/io_patterns.zig): runnable I/O example.

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

## Run the current example

The example requires Zig 0.17.0 and no reference clone or C compiler:

```text
zig version
zig fmt --check zig/examples/io_patterns.zig
zig test zig/examples/io_patterns.zig
zig test zig/examples/io_patterns.zig -O ReleaseSafe
zig test zig/examples/io_patterns.zig -O ReleaseFast
```

All six tests passed in each mode on native Windows. They exercise memory and
file adapters, fragmented input, truncation, I/O failure and output capacity.
There is no root `build.zig` yet, so `zig build` and `zig build test` arrive with
T01. Follow [TODO.md](TODO.md) for the first library milestone.

## Source provenance

The standalone example is original project code and declares
`LGPL-2.1-or-later` in its source header. Reference repositories retain their own
license files and notices inside their ignored clones. Record the source,
revision, applicable license and attribution for each future derived file;
using Zig does not change the provenance of an algorithm or implementation.
