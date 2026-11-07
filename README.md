# zffmpeg

A native Zig multimedia library and tools, developed incrementally from FFmpeg's
documented behavior and algorithms, one supported capability at a time.

Current state: six containers and raw PCM work. The `av` library reads and
writes every WAV PCM encoding (u8, 16- to 64-bit integers, float, A-law,
mu-law, plain or WAVE_FORMAT_EXTENSIBLE) in RIFF, RF64/BW64 or Sony Wave64,
past 4 GiB, every PCM encoding of Sun AU, AIFF and AIFF-C with every PCM
encoding of FFmpeg's AIFF table, and raw PCM in FFmpeg's raw formats (bounded
parsers, writers, file and pipe adapters), and reads Apple CAF with linear
PCM, A-law and µ-law; it can also read unknown-length WAV, AU and CAF input
behind an option, and reads and writes WAV's LIST/INFO and `bext`
tags as FFmpeg does. Codec and format registries name everything as FFmpeg
does. The `zffprobe` tool detects WAV, Wave64, AU, AIFF or CAF from the content
with FFmpeg's scored probes, and raw PCM from `-f` or a raw file extension,
validates the file and reports its stream and tags. Both are checked against
129 WAV, 41 AU, 57 AIFF, 25 raw PCM and 58 CAF fixtures (475 in all with
today's 57 FLAC, 37 Ogg and 71 MPEG audio ones) and against a pinned FFmpeg
build in CI (Linux). The `zffmpeg` tool converts and stream-copies
between WAV, Wave64, AU, AIFF and raw PCM, and from CAF, carrying tags as FFmpeg does, through the
library's synchronous pipeline (T13), which runs on packets, frames and
send/receive stages (T14a), and FFmpeg reads every output it writes for the
fixtures. Transcoding converts between every sample format as libswresample
does, with `-c:a` to pick the encoder and every one of its dither methods,
noise shaping included, bit-exact with FFmpeg's (T23a). Every container
carries 1 to 64 channels with FFmpeg's channel layouts, Apple's layout chunk
in AIFF and CAF included, and `zffmpeg` names an unspecified layout as
FFmpeg's command line does (T23b); its output `-ac` and `-ch_layout`
rematrix as libswresample does, bit-exact (T23c), and its `-ar` resamples as
FFmpeg's `aresample` does, byte for byte (T24, with glibc's `sin`, `cos` and
`exp` ported since T28a); options take FFmpeg's number syntax (`44.1k`, T17a).
The library's audio filter graph negotiates and runs chains of `anull`,
`aformat`, `volume`, `aresample`, `atrim` and `asetpts` as libavfilter does
(T25a), from filtergraph text with FFmpeg's expressions too (T25b), and
graphs of several inputs and outputs with `asplit`, `channelsplit`,
`channelmap`, `pan` and `amix` on libavfilter's scheduler (T25c). FLAC
with 16-bit samples is read as FFmpeg's demuxer, parser and decoder read
it, packet for packet and sample for sample, damaged streams included:
`zffprobe` reports it and `zffmpeg` converts it to every PCM output (T26a),
and the library writes FFmpeg's framecrc, framemd5 and streamhash text for
comparisons (T19b), checked against 31 FLAC fixtures. WAV and Wave64
streams seek as FFmpeg's `av_seek_frame` and `avformat_seek_file` seek
them, by timestamp or byte position (T52a), on FFmpeg's rational
arithmetic (T15). FLAC decodes completely since T26b: 4 to 32 bits per
sample, variable blocking, tags, seek tables, cue sheets and pictures,
MD5 verification and FFmpeg's seeking, over 56 FLAC fixtures, with
FFmpeg's FATE FLAC samples as optional coverage. And `zffmpeg` writes FLAC
since T26c: FFmpeg's encoder and muxer, byte for byte the ffmpeg program's
`-bitexact` output at every compression level and with every encoder
option (`-compression_level`, `-lpc_type`, `-ch_mode`, ...). Ogg is read
since T27a as FFmpeg's demuxer reads it with its FLAC, Opus and Vorbis
mappings, without decoding: packet for packet with libavformat's
timestamps and side data, damaged pages and chained streams included,
reported by `zffprobe`, copied to FFmpeg's framecrc text, and seeked as
FFmpeg seeks it, over 20 Ogg fixtures; and `zffmpeg` writes FLAC into Ogg
(`.ogg`, `.oga`) since T27b, byte for byte as the ffmpeg program's
`-bitexact` output. Vorbis decodes since T27d, bit for bit as FFmpeg's
decoder (with FFmpeg's FFT and MDCT, T27c, and VLC tables, T18c): `zffmpeg`
converts Ogg Vorbis and Ogg FLAC to every output as the ffmpeg program does,
and `zffprobe` reports them as ffprobe does. Opus decodes since T28 (CELT
frames since T28a, SILK since T28b, hybrid frames and multistream packets
since T28c), bit for bit as FFmpeg's decoder (its range decoder, packets,
CELT, SILK with its resampling, the streams' sync buffers and channel
mapping, FFmpeg's quirks included, as notes.md lists them): `zffmpeg`
converts Ogg Opus, `zffprobe` reports it, and RFC 8251's twelve vectors
decode as FFmpeg decodes them. MPEG audio demuxes since T29a as FFmpeg's
mp3 demuxer and parser split it, its ID3v2 and ID3v1 tags, Xing, LAME,
VBRI and iTunSMPB headers and gapless side data included, and detection
follows FFmpeg's probe rounds and ID3v2 skip: `zffprobe` reports MP3 as
ffprobe does. The MPEG audio decoders are bit for bit FFmpeg's mp3float
(Layer III, T29b) and mp1float and mp2float (Layers I and II, T29c),
gapless trimming included: `zffmpeg` converts MP3, MP2 and MP1 into every
PCM output and into FLAC as the ffmpeg program does. And `zffmpeg` writes
MP2 since T29d: FFmpeg's mp2 and mp2fixed encoders with its raw mp2
muxer, byte for byte the ffmpeg program's `-bitexact` output, with `-b:a`
for the bit rate. ADTS is read since T30a as FFmpeg's demuxer and AAC parser
split it, its ID3v2, ID3v1 and APE tags included, and the library writes it
as FFmpeg's muxer does from an AudioSpecificConfig, parsed as FFmpeg parses
it. Since T30b FFmpeg's float AAC decoder decodes AAC-LC bit for bit:
`zffprobe` reports ADTS as ffprobe does and `zffmpeg` converts it into
every output as the ffmpeg program does, and since T30c HE-AAC's SBR
too (parametric stereo follows). WAV and FLAC
open after leading ID3v2 tags, as in FFmpeg.
[TODO.md](TODO.md) holds the completion
evidence and the roadmap. Development is verified on Linux only. The compiler
is **Zig 0.17.0**, enforced by the build.

Compatibility follows explicit subsets, limits and error contracts. A file
accepted by FFmpeg may be deliberately rejected here; widening support requires
a contract and fixture change. A language port alone establishes neither safety
nor speed: parser checks must work in ReleaseFast, and performance claims need
measurements. See the [design policy](port.md#supported-scope-and-policy) and
the [unplanned features](TODO.md#not-planned).

## Project files

- [port.md](port.md): architecture, supported-subset contracts, design policy and
  verification plan; also defines [which document owns each decision](port.md#document-authority).
- [TODO.md](TODO.md): ordered tasks and completion evidence.
- [notes.md](notes.md): revisable decisions and their rationale, each with what
  to change together.
- [CLAUDE.md](CLAUDE.md): repository guidance for development; [AGENTS.md](AGENTS.md)
  contains only `@CLAUDE.md` so other agents load the same file.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg source analysis.
- [.claude/skills/zig-0-17/](.claude/skills/zig-0-17/SKILL.md): the project skill for writing
  Zig 0.17 here (workflow, checklist and [guide](.claude/skills/zig-0-17/references/guide.md));
  Claude Code uses it for every Zig change.
- [.claude/skills/zig-io/](.claude/skills/zig-io/SKILL.md): the project skill for I/O code:
  which `std.Io` tool to use where, from FFmpeg's C I/O layer and measurements
  ([analysis](.claude/skills/zig-io/references/analysis.md)), with a benchmark kit that
  reruns them on another machine ([reproduce](.claude/skills/zig-io/references/reproduce.md)).
- [build.zig](build.zig), [build.zig.zon](build.zig.zon): the package and build;
  [zig/README.md](zig/README.md) documents commands, version policy and layout.
- [zig/root.zig](zig/root.zig): root of the `av` library module.
- [zig/testing/fixtures/README.md](zig/testing/fixtures/README.md): the WAV fixture
  contract (129 fixtures, expected results, decisions, error precedence).
- [zig/testing/fixtures/au/README.md](zig/testing/fixtures/au/README.md): the AU
  fixture contract (41 fixtures, parser and detection expectations kept separate).
- [zig/testing/fixtures/aiff/README.md](zig/testing/fixtures/aiff/README.md): the
  AIFF fixture contract (57 fixtures, AIFF and AIFF-C).
- [zig/testing/fixtures/raw/README.md](zig/testing/fixtures/raw/README.md): the
  raw PCM fixture contract (25 fixtures, each with its parameters).
- [zig/testing/fixtures/caf/README.md](zig/testing/fixtures/caf/README.md): the
  CAF fixture contract (58 fixtures, read only).
- [zig/testing/reference/README.md](zig/testing/reference/README.md): the pinned
  FFmpeg reference build and the recorded comparison results.
- [zig/format/wav.zig](zig/format/wav.zig), [zig/format/au.zig](zig/format/au.zig),
  [zig/format/aiff.zig](zig/format/aiff.zig), [zig/format/raw.zig](zig/format/raw.zig),
  [zig/format/caf.zig](zig/format/caf.zig),
  [zig/format/registry.zig](zig/format/registry.zig),
  [zig/codec/registry.zig](zig/codec/registry.zig),
  [zig/format/detect.zig](zig/format/detect.zig), [zig/format/convert.zig](zig/format/convert.zig),
  [zig/io/file.zig](zig/io/file.zig), [zig/cli/probe.zig](zig/cli/probe.zig),
  [zig/cli/ffmpeg.zig](zig/cli/ffmpeg.zig): WAV, AU, AIFF and raw PCM parsers
  and writers, the CAF parser, the format and codec registries, detection, the conversion


  pipeline, file adapters, and the `zffprobe` and `zffmpeg` tools.

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

Clone FFmpeg and zigimg before source research or reference comparisons; the
three Zig I/O references are needed only for I/O work (the
[`zig-io` skill](.claude/skills/zig-io/SKILL.md)). Run these commands from the
zffmpeg project root in a fresh checkout:

```text
git clone --depth 1 --no-checkout https://github.com/FFmpeg/FFmpeg.git .references/ffmpeg
git -C .references/ffmpeg fetch --depth 1 origin 5d5a38a7e46be296eab75982c0986054f731e19e
git -C .references/ffmpeg checkout --detach 5d5a38a7e46be296eab75982c0986054f731e19e

git clone --depth 1 --no-checkout https://github.com/zigimg/zigimg.git .references/zigimg
git -C .references/zigimg fetch --depth 1 origin 083d0304840a3f5fd547c2e2005148a18886c401
git -C .references/zigimg checkout --detach 083d0304840a3f5fd547c2e2005148a18886c401

git clone --depth 1 --no-checkout https://github.com/lalinsky/zio.git .references/zio
git -C .references/zio fetch --depth 1 origin 1814bacf54ca2ebdb140c3e521860ef3320f76dd
git -C .references/zio checkout --detach 1814bacf54ca2ebdb140c3e521860ef3320f76dd

git clone --depth 1 --no-checkout https://github.com/zigtools/zls.git .references/zls
git -C .references/zls fetch --depth 1 origin c275dd2ec457e6ae302d98a6116e69c6d595c24c
git -C .references/zls checkout --detach c275dd2ec457e6ae302d98a6116e69c6d595c24c

git clone --depth 1 --no-checkout https://github.com/zigcc/zig-cookbook.git .references/zig-cookbook
git -C .references/zig-cookbook fetch --depth 1 origin ed1772059f236c1721af57c785b4d94684951be5
git -C .references/zig-cookbook checkout --detach ed1772059f236c1721af57c785b4d94684951be5
```

Zig's standard library is the fourth I/O reference: the `lib/std` of the
pinned 0.17.0 toolchain (`zig env` prints `lib_dir`) is the 0.17.0 source,
but the release ships the library's own tests empty and has no history. For
those, clone Zig and read it at the release tag, not at `master`, which has
moved on (the zig-io analysis, "The Zig source"):

```text
git clone https://codeberg.org/ziglang/zig.git .references/zig
git -C .references/zig checkout --detach 0.17.0
```

`git -C .references/zig show 0.17.0:lib/std/<path>` reads the tag from any
checkout.

Do not rerun clone over an existing directory. To inspect an existing setup,
run `git -C .references/<name> rev-parse HEAD` for each clone. Refresh
revisions deliberately and update the corresponding analysis and verification
evidence ([doc/zigimg-reference.md](doc/zigimg-reference.md) for zigimg,
[the zig-io analysis](.claude/skills/zig-io/references/analysis.md) for zio,
ZLS, zig-cookbook and the standard library).

| Reference | Pinned revision | Role |
| --- | --- | --- |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg.git) | `5d5a38a7e46be296eab75982c0986054f731e19e` | Multimedia algorithms, behavior and differential testing. |
| [zigimg](https://github.com/zigimg/zigimg.git) | `083d0304840a3f5fd547c2e2005148a18886c401` | Modern Zig I/O, ownership, build and metaprogramming examples. |
| [zio](https://github.com/lalinsky/zio.git) | `1814bacf54ca2ebdb140c3e521860ef3320f76dd` | A second `std.Io` implementation; its tests document the interface's contract (cancellation, groups, pipes). |
| [ZLS](https://github.com/zigtools/zls.git) | `c275dd2ec457e6ae302d98a6116e69c6d595c24c` | A long-running Zig 0.17 program using `Io.Group`. |
| [zig-cookbook](https://github.com/zigcc/zig-cookbook.git) | `ed1772059f236c1721af57c785b4d94684951be5` | Short `std.Io` recipes (Zig 0.16): tasks, groups, queues, files. |
| Zig standard library | the 0.17.0 release; [Zig](https://codeberg.org/ziglang/zig.git) at tag `0.17.0` | The authority for every `std.Io` API; the clone at the tag for the library's tests and history. |

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
zig build zffmpeg -- -i zig/testing/fixtures/wav/stereo_44k1.wav stereo.au
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig fmt --check build.zig build.zig.zon zig/
```

`zig build` compiles the `av` library and installs `zig-out/bin/zffprobe` and
`zig-out/bin/zffmpeg`; `zig build test` runs the `av` module tests, every
example's tests and the `zffprobe` and `zffmpeg` process checks. Add `-Dtest-filter="text"` to run only
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
