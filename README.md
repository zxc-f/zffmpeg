# zffmpeg

A native Zig multimedia library and tools, developed incrementally from FFmpeg's
documented behavior and algorithms. The first planned path is signed 16-bit PCM
in WAV, followed by a small probe tool.

Current state: the first complete path works. The `av` library reads and writes
signed 16-bit PCM WAV (bounded parser, known-length writer, file and pipe
adapters), and the `zffprobe` tool validates a WAV file and reports its stream.
Both are checked against 52 fixtures and against a pinned FFmpeg build in CI
(Linux). Other codecs, containers and a conversion tool are still planned;
[TODO.md](TODO.md) lays out the roadmap. Development is verified on Linux
only. The compiler is **Zig 0.17.0**, enforced by the build.

## Project files

- [port.md](port.md): architecture, supported-subset contracts and verification plan.
- [TODO.md](TODO.md): ordered tasks and completion evidence.
- [notes.md](notes.md): revisable decisions, each with what to change together.
- [CLAUDE.md](CLAUDE.md): repository guidance for development; [AGENTS.md](AGENTS.md)
  contains only `@CLAUDE.md` so other agents load the same file.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg source analysis.
- [doc/zig-0.17-guide.md](doc/zig-0.17-guide.md): how to write Zig 0.17 in this project.
- [build.zig](build.zig), [build.zig.zon](build.zig.zon): the package and build;
  [zig/README.md](zig/README.md) documents commands, version policy and layout.
- [zig/root.zig](zig/root.zig): root of the `av` library module.
- [zig/testing/fixtures/README.md](zig/testing/fixtures/README.md): the WAV fixture
  contract (52 fixtures, expected results, decisions, error precedence).
- [zig/testing/reference/README.md](zig/testing/reference/README.md): the pinned
  FFmpeg reference build and the recorded comparison results.
- [zig/format/wav.zig](zig/format/wav.zig), [zig/io/file.zig](zig/io/file.zig),
  [zig/cli/probe.zig](zig/cli/probe.zig): WAV parser and writer, file adapters,
  and the `zffprobe` tool.
- [zig/examples/io_patterns.zig](zig/examples/io_patterns.zig): runnable I/O example.
- [zig/codec/pcm.zig](zig/codec/pcm.zig): signed 16-bit PCM decode/encode kernels.
- [zig/core/audio.zig](zig/core/audio.zig), [zig/core/time.zig](zig/core/time.zig):
  audio stream descriptions, time bases and timestamp rescaling.
- [.github/workflows/ci.yml](.github/workflows/ci.yml): Linux CI for the build and tests.
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

## Build and test

Requires Zig 0.17.0 exactly; `build.zig` rejects any other compiler. No
reference clone or C compiler is needed. From the repository root:

```text
zig build
zig build probe -- zig/testing/fixtures/wav/stereo_44k1.wav
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig fmt --check build.zig build.zig.zon zig/
```

`zig build` compiles the `av` library and installs `zig-out/bin/zffprobe`;
`zig build test` runs the `av` module tests, every example's tests and the
`zffprobe` process checks. Add `-Dtest-filter="text"` to run only
matching tests and `--summary all` to list test counts.
[zig/README.md](zig/README.md) covers the version policy, build graph and
package manifest. A single example also runs with
`zig test zig/examples/<name>.zig`.

The [Linux CI workflow](.github/workflows/ci.yml) runs the version check,
formatting, the fixture check (`python3 zig/testing/fixtures/generate.py --check`),
`zig build` in Debug and ReleaseSafe, and `zig build test` in
Debug, ReleaseSafe and ReleaseFast on every pull request and push to `master`.
Development is verified on Linux only; Windows and ARM come later (see the
platform policy in [TODO.md](TODO.md#platform-policy-linux-only-during-development)).
New code stays portable, and CI compiles Windows and AArch64 targets without
running them.

The I/O example tests exercise memory and file adapters, fragmented input,
truncation, generic and file-specific I/O failure, and output capacity. The PCM
tests cover both byte orders, signed extrema, invalid buffer sizes and unchanged
output on failure. Follow [TODO.md](TODO.md) for the first library milestone.

## Source provenance

The build files, the `av` module, the fixture generator and the standalone
examples are original project code and declare `LGPL-2.1-or-later` in their source headers; [LICENSE](LICENSE) contains the
GNU Lesser General Public License v2.1 text, copied verbatim from FFmpeg's
`COPYING.LGPLv2.1` at the pinned revision. Reference repositories retain their own
license files and notices inside their ignored clones. Record the source,
revision, applicable license and attribution for each future derived file;
using Zig does not change the provenance of an algorithm or implementation.
