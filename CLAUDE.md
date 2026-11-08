# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` only imports this file (`@CLAUDE.md`); keep agent guidance here.

## Project intent and current state

This standalone repository is becoming a native Zig implementation of FFmpeg's
multimedia functionality. Implement algorithms and APIs in Zig; compiling FFmpeg's C with
`zig cc`, translating headers, or wrapping libav* does not constitute the port.

Current state: the WAV and AU PCM paths are complete (T01–T12), WAV with every
PCM encoding, plain or extensible (T21a), in RIFF, RF64/BW64 or Sony Wave64,
with unknown-length input behind an option (T21b) and LIST/INFO and `bext`
tags (T21c), AU with every PCM encoding of FFmpeg's table and unknown
length (T22a), AIFF and AIFF-C with every PCM encoding of FFmpeg's table
(T22b), raw PCM in FFmpeg's raw formats (T22c), and CAF read only (T22d),
with conversion between every sample format and libswresample's dither
(T23a), FFmpeg's channel layouts, 1 to 64 channels, in every container
(T23b), rematrixing between them (T23c) and resampling (T24), with
FFmpeg's option syntax (T17a), an audio filter graph (T25), and FLAC with
16-bit samples read and decoded as FFmpeg does (T26a), and WAV seeking
(T52a) on FFmpeg's rational arithmetic (T15), complete FLAC decoding
and seeking (T26b), and FFmpeg's FLAC encoder and muxer (T26c), and
Ogg read without decoding, with the FLAC, Opus and Vorbis mappings, and
seeked on libavformat's generic layer (T27a), and FFmpeg's Ogg muxer with
FLAC encoded into Ogg (T27b), and FFmpeg's float FFT and MDCT (T27c), the
LSB-first reader and VLC tables (T18c) and the Vorbis decoder, with Ogg
decoded in zffmpeg (T27d), and the Opus decoder for CELT frames, with
Ogg Opus decoded (T28a), SILK frames (T28b), and hybrid frames and
multistream packets (T28c), and the MP3 demuxer with its parser, ID3
tags and FFmpeg's probe rounds (T29a), and the MPEG audio decoders, Layer
III (T29b) and Layers I and II (T29c), with MP3, MP2 and MP1 decoded in
zffmpeg, and FFmpeg's MP2 encoders with its mp2 muxer (T29d), and the
ADTS demuxer and muxer and AudioSpecificConfig, with WAV
and FLAC read after leading ID3v2 tags (T30a), and FFmpeg's float AAC
decoder for AAC-LC, with ADTS decoded in zffmpeg (T30b), and its SBR
decoder, with HE-AAC decoded (T30c), and its parametric stereo, with
HE-AACv2 decoded (T30d), and FFmpeg's IMA WAV and Microsoft ADPCM codecs,
decoded and encoded in WAV (T31a), and its ALAC codec, read from CAF and
written there with its CAF muxer, which also writes PCM (T31b), and its
G.722 and G.726 codecs, read from AU and written there (T31c), and its raw
AC-3 demuxer, parser and float decoder (T32a), and its E-AC-3 decoder and
raw eac3 demuxer (T32b), and its AC-3 encoder and raw ac3 muxer (T32c), and
its AAC encoder with its nmr, twoloop and fast coders, into ADTS (T32d), and
its mov demuxer for MP4 and QuickTime audio tracks, reported by zffprobe
(T33a1), with their metadata and chapters (T33a2). The `av`
module (rooted at `zig/root.zig`) exports `pcm` (the PCM encodings,
kernels and decoder/encoder stages), `audio`, `channel_layout` (FFmpeg's
channel layouts), `time`, `samples` (decoded sample storage
for every sample format), `packet`, `frame`, `stage` (the send/receive
contract), `metadata` (the tag dictionary), `number`, `options` and
`diagnostics` (FFmpeg's number syntax, typed options, a log sink),
`eval` (FFmpeg's expressions), `filter` (the audio filter graph: anull,
aformat, volume, aresample, atrim, asetpts, asplit, channelsplit,
channelmap, pan, amix, from filtergraph text, several inputs and outputs),
`wav`
(also Wave64), `au`,
`aiff` and `raw` (bounded parsers and writers), `caf` (a bounded parser),
`flac` (FFmpeg's FLAC demuxer, parser and decoder, 4 to 32 bits, with
metadata blocks and seeking), `flacenc` and `flacmux` (FFmpeg's FLAC
encoder, packet for packet, and its muxer as a PCM writer), `ogg`
(FFmpeg's Ogg demuxer and mappings), `oggmux` (its Ogg muxer), `oggdecode` (an Ogg stream decoded), `mp3decode` (an MPEG audio stream decoded), `tx` (FFmpeg's float FFT
and MDCT), `vlc` (VLC tables), `vorbis` (the Vorbis decoder), `opusdec` (the Opus
decoder: CELT, SILK and hybrid frames, multistream packets), `mp3dec` (FFmpeg's
float MPEG audio decoders, Layers I to III), `mp2enc` and `mp2mux` (FFmpeg's
MP2 encoders, mp2 and mp2fixed, and its mp2 muxer), `adts`, `aac`,
`mpeg4audio` and `adtsmux` (ADTS headers and FFmpeg's AAC parser, its ADTS
demuxer, the AudioSpecificConfig, its ADTS muxer), `aacdec` and
`aacdecode` (FFmpeg's float AAC decoder with SBR and PS, an ADTS stream
decoded), `adpcm` and `wavadpcm` (FFmpeg's IMA WAV and Microsoft ADPCM
codecs, and ADPCM in WAV decoded and encoded, T31a), `alac`, `cafalac` and
`cafmux` (FFmpeg's ALAC codec, ALAC in CAF decoded, and its CAF muxer,
T31b), `g722`, `g726` and `aug72x` (FFmpeg's G.722 and G.726 codecs, and
G.722 and G.726 in AU decoded and encoded, T31c), `ac3`, `ac3dec` and
`ac3demux` (AC-3 headers and FFmpeg's AC-3 parser, its float decoder, its
raw demuxer, T32a; E-AC-3 decoded and its raw demuxer, T32b), `ac3enc` and
`ac3mux` (FFmpeg's float AC-3 encoder and its raw ac3 muxer, T32c), `aacpsy`,
`aacenc` and `aacadts` (FFmpeg's AAC psy model, its AAC encoder with the nmr,
twoloop and fast coders, and the encoder before its adts muxer, T32d), `mov`
(FFmpeg's mov demuxer, audio tracks, T33a1, metadata and chapters, T33a2),
`chapters` (libavformat's chapter list), `mp3` (FFmpeg's MPEG
audio demuxer), `mpegaudio` (frame headers and the mpegaudio parser), `id3v2` and
`id3v1` (ID3 tags), `demux` (libavformat's generic layer:
timestamps, the stream-info read-ahead, timings and seeking),
`bits` (an MSB-first bit reader and writer and FLAC's CRCs), `framehash` (FFmpeg's
framecrc, framemd5 and streamhash text), `rational` (FFmpeg's rational
arithmetic and timestamp helpers), `seek` (the seek API),
`codecs` and `formats`
(the codec and format registries), `detect` (detection with FFmpeg's scored
probes and extension fallback), `audioconvert` and `dither` (sample format
conversion, T23a), `convert` (the synchronous T13a conversion and
stream-copy pipeline) and `file` (file and pipe adapters). Two tools sit on it:
`zffprobe` probes WAV, Wave64, AU, AIFF, CAF, FLAC, Ogg, MP3, ADTS, AC-3, E-AC-3, MP4 and raw PCM, tags included, and `zffmpeg` (T13b)
converts and stream-copies between them (CAF as input only; Ogg Vorbis, Opus
and FLAC, MPEG audio, ADTS AAC, AC-3 and E-AC-3, decoded as input; FLAC, MP2, AC-3 and ADTS AAC written as output; IMA WAV and
Microsoft ADPCM in WAV, ALAC in CAF and G.722 and G.726 in AU both ways, PCM CAF written), carrying tags,
with `-c:a`, `-b:a`, `-q:a`, FFmpeg's dither options and its FLAC, ADPCM, G.726, AC-3 and AAC encoder options. Tests cover 129 WAV,
40 AU, 57 AIFF, 25 raw PCM, 58 CAF, 57 FLAC, 37 Ogg, 71 MP3, 46 ADTS, 41 ADPCM, 33 ALAC, 23 G.72x, 24 AC-3, 18 E-AC-3 and 117 MP4 fixtures, process runs of both tools, and a CI comparison against a
pinned FFmpeg build that also reads every `zffmpeg` output. Verification is
Linux-only during development; Windows and ARM wait for T62–T63. T13, T14a
(packets, frames and stages), T17b (the metadata dictionary), T20a (decoded
sample storage), T20b (the PCM encodings) and T21 (complete WAV: T21a
extensible headers and encodings, T21b RF64, Wave64 and unknown length, T21c
tags), T16 (codec and format registries and probing) and T22 (T22a AU
encodings, T22b AIFF, T22c raw PCM, T22d CAF) and T23a (sample format
conversion and dither), T23b (channel layouts) and T23c (rematrixing) are
verified, completing T23, and so are T17 (T17a: number syntax, typed
options, a diagnostic sink), T24 (resampling) and T25a (the audio filter
graph's core), T25b (expressions, filtergraph text, atrim and asetpts)
and T25c (several inputs and outputs on libavfilter's scheduler), completing
T25, and T26a (FLAC demux and 16-bit decoding) with T18a (the bit reader
and CRCs) and T19b (frame and stream hashes), T15 (rational arithmetic and
timestamps) and T52a (the seek API and WAV seeking), and T26b (complete
FLAC decoding and seeking) and T26c (the FLAC encoder and muxer, with
T18b's bit writer), completing T26, and T19c (the optional FATE corpus
and the comparison's coverage summary), completing T19, and T27a (Ogg
demux, with libavformat's generic layer and Ogg seeking), T27b (Ogg
mux, FLAC into Ogg), T27c (FFT and MDCT), T18c (VLC tables) and T27d
(Vorbis decoding), completing T27, and T28a (the range decoder, CELT and
Ogg Opus decoding), T28b (SILK) and T28c (hybrid frames and
multistream), completing T28, and T29a (the MPEG audio demuxer and
parser), T29b (the Layer III decoder), T29c (Layers I and II) and T29d
(the MP2 encoder), completing T29, and T30a (ADTS and AudioSpecificConfig)
T30b (the AAC-LC decoder), T30c (SBR) and T30d (parametric stereo),
completing T30, and T31a (IMA WAV and Microsoft ADPCM, decoded and
encoded in WAV), T31b (ALAC in CAF and the CAF muxer) and T31c (G.722
and G.726 in AU), completing T31, and T32a (raw AC-3 decoded), T32b
(raw E-AC-3 decoded), T32c (the AC-3 encoder) and T32d (the AAC-LC
encoder, T32d1 its twoloop and fast coders and T32d2 its default nmr
coder), completing T32, and T33a1 (the MP4 demuxer's boxes and audio
tracks) and T33a2 (MP4 metadata and chapters); T33a3 (MP4 video tracks)
is next,
and TODO.md lays out the roadmap through T65.
 When the state changes, update the current-state statements in
README.md, port.md ("Status and scope"), the TODO.md introduction and this file
together.

## Writing Zig: use the `zig-0-17` skill

Every time you create or change a `.zig` file (anything under `zig/`, or
`build.zig`) or `build.zig.zon`, first invoke the project skill `zig-0-17`
([.claude/skills/zig-0-17/SKILL.md](.claude/skills/zig-0-17/SKILL.md)) and
follow its workflow: read its reference ([references/guide.md](.claude/skills/zig-0-17/references/guide.md))
before writing, and run its checklist on every changed hunk before you commit.
This applies to every change, however small, including tests, examples and
review fixes, and to subagents that write Zig: tell them to use the skill.
Once per session is enough to load it; re-read the guide sections a later
change touches. Agents that cannot load skills read the two files directly.
Where the skill and this file differ, this file wins.

For I/O code, also invoke the project skill `zig-io`
([.claude/skills/zig-io/SKILL.md](.claude/skills/zig-io/SKILL.md)): opening,
reading, writing, skipping, seeking or copying files, pipes and standard
streams; a demuxer's, muxer's or parser's read or write path; buffer sizes;
header rewrites; stream copy. It says which `std.Io` tool to use where, from
FFmpeg's C I/O layer and measurements; a change that departs from it needs a
measurement with its benchmarks, recorded in its analysis.

For a spawn, a wait, a cancel, or a shared queue or lock, also invoke
`zig-async` ([.claude/skills/zig-async/SKILL.md](.claude/skills/zig-async/SKILL.md)).
T53d's scheduler is synchronous queues. T59 is the first task that may spawn,
and only after `zig-io`'s measurement rule. Do not add `io.async` from a blog.

For fixtures, reference generators, comparison predicates, recorded
differences, or G1/G3/G4 validation, invoke
`ffmpeg-oracle` ([.claude/skills/ffmpeg-oracle/SKILL.md](.claude/skills/ffmpeg-oracle/SKILL.md)).
It operates the existing reference and failure-testing tools; TODO.md still
owns the gates and completion evidence.

When porting or reviewing C arithmetic, macros, libc behavior or error
handling, invoke `ffmpeg-c-semantics`
([.claude/skills/ffmpeg-c-semantics/SKILL.md](.claude/skills/ffmpeg-c-semantics/SKILL.md)).
For packet/frame retention, media backpressure, draining, reset, seeking,
reconfiguration or timestamp changes, invoke `media-pipeline`
([.claude/skills/media-pipeline/SKILL.md](.claude/skills/media-pipeline/SKILL.md)).
These apply to the relevant change, not every unrelated Zig edit. They do
not change the supported subsets or authorize threads before T59.

## Commands

Toolchain: Zig **0.17.0** exactly. `build.zig` stops with a compile error on any
other compiler, and CI checks `zig version` too. No C compiler or reference
clone is needed. Run from the repository root, because `std.testing.tmpDir`
creates `.zig-cache/tmp/` in the current directory.

```bash
zig build                                    # compile the av library (Debug)
zig build test                               # av module tests + every example's tests
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast        # safety off; required for parser/size code
zig build test -Dtest-filter="truncation"    # only tests whose names contain the text
zig build test --summary all                 # per-artifact test counts
zig build probe -- file.wav                  # run zffprobe (`-` reads stdin)
zig build zffmpeg -- -i in.wav out.au        # run zffmpeg (`-` for stdin/stdout)
zig fmt --check build.zig build.zig.zon zig/
zig test zig/examples/io_patterns.zig        # one standalone example, without the build
python3 zig/testing/fixtures/generate.py --check   # WAV fixtures are current (Python 3, stdlib only)
```

[.github/workflows/ci.yml](.github/workflows/ci.yml) (Linux only; see the
[platform policy](#platform-policy-and-portable-zig-code)) runs the version
check, formatting, the fixture `--check`, a check that every
`zig/examples/*.zig` is registered in `build.zig`, `zig build` in Debug and
ReleaseSafe, `zig build test` in Debug, ReleaseSafe and ReleaseFast, a
compile-only cross build, and the FFmpeg reference comparison. If no
local Zig 0.17.0 is available, the pull request's CI run is the verification;
never report local results that were not run. CI also runs on a branch without
a pull request through `workflow_dispatch`. The C reference uses `configure` and
Make, not Zig's build system.

When adding code:

- Register a new example in the `examples` list in `build.zig`.
- Reference each new `av` file that has tests from a `test` block in
  `zig/root.zig`; Zig analyzes lazily, so unreferenced files' tests never run.
- Export only supported features from `zig/root.zig`.
- Change WAV fixtures only in `zig/testing/fixtures/generate.py`, then rerun it;
  never edit the generated `.wav` files, `manifest.zon` or the README table.
- Test CLI behavior by adding a `probe_cases` or `convert_cases` entry in
  `build.zig` (a separate process run that checks stdout, stderr and the exit
  status), never by printing from a unit test. zffmpeg cases that need files
  prepared on disk go in `zig/testing/zffmpeg_cases.zig`.
- Keep parsing in `av`; `zig/cli/` only handles arguments, files and output.

[zig/README.md](zig/README.md) documents the build graph, version policy,
package manifest and per-file provenance.

## Where decisions live

Follow [port.md's document authority](port.md#document-authority): contracts
govern behavior and TODO.md governs task status and evidence. This file is
agent guidance; reconcile any disagreement with a contract in the same change.
Record a scope or policy revision in notes.md and update the affected contract,
task and fixtures together, and record every difference from FFmpeg there as
"Recording differences from FFmpeg in notes.md" below says. Silence in one
document does not widen support.

- [README.md](README.md): setup, pinned reference clone commands, runnable commands.
- [zig/README.md](zig/README.md): build graph, version policy, manifest, provenance.
- [zig/testing/reference/README.md](zig/testing/reference/README.md): how the
  pinned FFmpeg reference is built and the recorded comparison results.
  `compare.py` there is the T10 differential check; CI runs it.
- [zig/testing/fixtures/README.md](zig/testing/fixtures/README.md): the WAV
  fixture contract: every fixture's expected result, the boundary decisions and
  the error precedence the parser must follow. `zig/testing/fixtures.zig`
  exposes the fixtures to tests.
- [port.md](port.md): architecture, contracts and the feature ledger. Read it
  before architectural work. Key sections:
  - "First WAV contract": the accepted subset, limits, error names (`Truncated`,
    `UnsupportedFormat`, `LimitExceeded`, `IoFailure`, `Canceled`, ...) and
    intentional differences from FFmpeg. T02 turns each row into named fixtures
    in `zig/testing/fixtures/README.md`, the canonical fixture contract.
  - "Initial probe output": zffprobe key order, canonical strings, exit codes 0–6.
  - "Verified Zig 0.17 I/O choices", "C-to-Zig decisions that affect correctness"
    and "Recorded design decisions": std API facts and porting decisions already
    checked against the pinned toolchain; consult them before re-deriving.
  - "Proposed Zig layout": one package whose `av` module is rooted at
    `zig/root.zig`, with `core/`, `io/`, `codec/`, `format/`, `cli/` and
    `testing/` created only when their first feature lands.
  - "Provenance and feature tracking": ledger statuses are planned,
    implemented, verified and optimized.
- [TODO.md](TODO.md): tasks T01–T65 and their subtasks (T12a, ...) with stable
  IDs, dependency words (**Needs**, **Lands with**, **Verified after**), gates
  G0–G5, a progress card and "Done when" criteria. Check an item only at G5,
  with an evidence note naming the files, the checks, the commit and the CI run
  link; keep unfinished items unchecked with what remains. Update the port.md
  ledger when a whole capability changes.
- [notes.md](notes.md): every revisable project decision, its reason and what to
  change together. Add new revisable decisions there in the same change.
- [doc/zigimg-reference.md](doc/zigimg-reference.md): pinned zigimg analysis,
  the source of the I/O adapter rules below.
- [.claude/skills/zig-0-17/](.claude/skills/zig-0-17/SKILL.md): the project
  skill for writing Zig 0.17 here. `SKILL.md` holds the workflow, a section
  map and the checklist to run before sending Zig; `references/guide.md` covers
  `@as` versus real casts, the 0.15/0.16 I/O breaks, containers, removed
  builtins, formatting, tests and the build graph. Use it for every Zig change
  (see "Writing Zig" above); where it differs from this file, this file wins.
- [.claude/skills/zig-io/](.claude/skills/zig-io/SKILL.md): the project skill
  for I/O code. `SKILL.md` holds the decision table and checklist;
  `references/analysis.md` the FFmpeg and std.Io sources (file and line) and
  the measurements; `references/reproduce.md` and `bench/run_all.sh` rerun
  them on another machine; `references/results/` keeps each run.
- [.claude/skills/zig-async/](.claude/skills/zig-async/SKILL.md): the project
  skill for spawning, waiting, cancelling, and sharing a queue or a lock.
  `SKILL.md` holds the which-tool table, the deadlocks, and the checklist;
  `references/analysis.md` holds the 0.17.0 contract, the sources, and the
  FFmpeg mapping. Not a reason to add threads before T59.
- [.claude/skills/ffmpeg-oracle/](.claude/skills/ffmpeg-oracle/SKILL.md):
  independent expected results, comparison predicates, required/optional
  coverage and the existing allocation/fuzz harnesses. Its references cover
  [comparisons](.claude/skills/ffmpeg-oracle/references/comparisons.md) and
  [failure testing](.claude/skills/ffmpeg-oracle/references/failure-testing.md).
- [.claude/skills/ffmpeg-c-semantics/](.claude/skills/ffmpeg-c-semantics/SKILL.md):
  preserving C arithmetic, conversions, macros, libc behavior and error
  treatment; [the procedure](.claude/skills/ffmpeg-c-semantics/references/behavior.md)
  maps the existing numeric helpers and reference sources.
- [.claude/skills/media-pipeline/](.claude/skills/media-pipeline/SKILL.md):
  packet/frame ownership and media lifecycle/timing across synchronous or
  future concurrent stages; [the reference](.claude/skills/media-pipeline/references/state-and-time.md)
  maps the current contracts, consumers and tests.

## References

FFmpeg and zigimg are independent clones under the ignored `.references/`
directory; clone both at the pinned revisions using
[README.md](README.md#clone-the-reference-repositories) before source research.
For I/O work, the same section pins zio, ZLS and zig-cookbook, and the
toolchain's own `lib/std` is the standard-library reference, with a Zig
clone read at the `0.17.0` tag for the library's tests and history, never
its `master` (the `zig-io` skill).
Do not commit their files, Git metadata or gitlinks; they are not submodules.
zigimg is a Zig implementation reference, never a build dependency.

The following paths are relative to `.references/ffmpeg/`:

- `libavutil/`: frames, buffers, rational arithmetic, formats, options, CPU support.
- `libavcodec/`: codec implementations, packets, bit readers, parsers, DSP.
- `libavformat/`: containers, muxing/demuxing, protocols, buffered I/O.
- `libavfilter/`: filter graph, negotiation, individual audio/video filters.
- `libswresample/`, `libswscale/`: audio resampling and video conversion/scaling.
- `libavdevice/`: platform capture and playback integrations.
- `fftools/`: ffmpeg, ffprobe, ffplay, scheduling and command-line behavior.
- `configure`, `ffbuild/`, library `Makefile`s: C feature/dependency/build model.
- `tests/fate/`, `tests/ref/`, `tests/checkasm/`: integration definitions,
  expected outputs, and optimized-kernel checks; some need external samples.

New Zig implementation files belong under `zig/`; the package is defined by
the root `build.zig` and `build.zig.zon`. Preserve reference attribution/licenses
and existing user changes.

## Toolchain and architecture

- `.zig-version` is a tooling convention and `minimum_zig_version` is package
  metadata; neither is an exact compiler check. `build.zig` enforces the tested
  version (`tested_zig_version`); upgrade deliberately, changing all three and
  CI together.
- Check installed standard-library sources and versioned official documentation
  before adopting build, I/O, or reflection APIs from older examples; the
  [`zig-0-17` skill's guide](.claude/skills/zig-0-17/references/guide.md) lists
  the stale patterns to avoid.
  Resolve disagreements by compiling a minimal check with the pinned toolchain.
- Start with one package and one named library module, `av`. Use ordinary
  file imports internally. Split named modules only for a demonstrated need,
  such as publishing a subset; keep imports acyclic and shared types minimal.
- The default build must compile an artifact; the test step must execute tests.
  Keep the explicit package `.paths` allowlist, which excludes the reference C
  tree; never use `""`. The build has no C sources, libc or package
  dependencies; add one only with a recorded decision in port.md.
- Keep the public Zig API small, typed, and independent of C struct layouts.
  Add any C ABI compatibility later as a separate adapter.
- Keep one implementation of an algorithm; a second needs a recorded purpose,
  comparison oracle and retention or retirement condition. Optimized kernels
  retain their scalar oracle. Give each codec local state; shared infrastructure
  starts with the consumer named in TODO.md.
- Pass allocators and I/O dependencies explicitly. Document whether slices and
  frames are borrowed, owned, shared, or transferred, and their lifetimes.
- `std.Io` belongs at OS boundaries; memory parsing needs only Reader/Writer
  interfaces, and allocation-free kernels need neither an allocator nor I/O.
- Distinguish malformed input, unsupported functionality, end of stream, and
  backpressure. Preserve timestamp, rounding, draining, and seek semantics.
- Follow [supported-scope policy](port.md#supported-scope-and-policy) and
  [CLI policy](port.md#cli-policy): derive time from supported timing rules,
  preserve missing values, reject unsupported operations before creating output,
  and expose media-changing defaults as named, documented options. Late parse,
  write or flush failures remain failures even after partial output.
- Implement portable scalar behavior first. Add SIMD or architecture-specific
  kernels only with comparisons against the scalar implementation.

## Platform policy and portable Zig code

During development every task is verified on Linux x86-64 only (TODO.md
"Platform policy"). CI's native runs in Debug, ReleaseSafe and ReleaseFast and
the FFmpeg reference job are the evidence. Windows, ARM and macOS runs wait for
TODO.md T62–T63: do not add them to CI or claim them before then. CI also
cross-compiles for x86_64-windows-gnu, aarch64-linux-musl and aarch64-macos as
a compile-only guard; keep it green.

### Portable Zig code

Write code that will pass on Windows and ARM later without rework:

- Reach the OS only through `std.Io` (files, directories, stdio, clocks,
  cancellation, concurrency) and `std.process.Init` (arguments, `environ_map`,
  `io`, `gpa`). Do not import `std.os.linux`, call `std.posix` directly, link
  libc, or use fork/exec, signals, `ioctl` or `mmap`. If a feature truly needs
  an OS facility, put it behind a `zig/io/` adapter with a portable fallback.
- Treat paths as opaque arguments opened relative to a `std.Io.Dir`, and build
  new ones with `std.fs.path`. Never hard-code `/` separators, `/dev/*`,
  `/proc`, `/tmp` or `~`. Tests use `std.testing.tmpDir`; `-` means standard
  input.
- Do not rely on case-sensitive names, symlinks, permission bits, deleting or
  renaming open files, a seekable or terminal stdin, or console encoding. Write
  `\n` and format numbers with `std.fmt`.
- Keep byte order explicit (`.little`/`.big`). Never reinterpret byte buffers
  as native-endian integers or structs.
- Use fixed-width integers for file offsets, sizes and sample or frame counts.
  Keep `usize` for in-memory indexing and convert with checks
  (`std.math.cast`), so 32-bit targets cannot overflow silently.
- Write SIMD as portable `@Vector` code next to a scalar reference. No inline
  assembly or target intrinsics until the platform milestone; guard any
  target-specific choice with `builtin` and keep a fallback.
- Assert OS-specific error names only in tests gated on `builtin.os.tag`, next
  to a portable assertion, as [zig/io/file.zig](zig/io/file.zig) does.
- Keep `build.zig` free of system libraries and shell commands; run processes
  through `std.Build.Step.Run`. Test helpers are Zig or standard-library
  Python. Bash is limited to the Linux-only FFmpeg reference tooling.

## Zig 0.17 I/O and test patterns

[zig/examples/io_patterns.zig](zig/examples/io_patterns.zig) is the executable
reference for these rules.

- Keep PCM kernels on slices. Parse WAV through `*std.Io.Reader`, starting with
  `Reader.fixed` tests. Use exact reads (`readSliceAll`) into local field
  buffers to handle tiny input fragments; do not retain reader-buffer views
  across subsequent reads. A failed exact read may have consumed part of a
  field; treat it as terminal.
- Encode output fields into local arrays and call `writeAll`; do not rely on
  `Writer.writeInt` working with buffers smaller than its documented minimum.
  The owning operation or encoder `finish` flushes and checks failure.
- Borrow `.interface` from a stable file adapter and reuse that adapter across
  reads. Preserve its scratch-buffer lifetime and detailed `.err` diagnostics;
  reconstructing it can lose read-ahead bytes. Keep seekability optional.
- Tests live beside the code. Cover fragmented input with `std.testing.Reader`
  and `artificial_limit = .limited(1)`, generic read failure with
  `std.Io.Reader.failing`, and real files with `std.testing.io` plus
  `std.testing.tmpDir` using empty, tiny and larger adapter buffers. Test CLI
  output in separate process runs, never inside the test runner.

## Modern Zig metaprogramming

- Prefer normal types and functions; use `comptime` for actual invariants,
  static tables, generic kernels, and component registration.
- Keep component selection explicit. Validate descriptors, signatures,
  dependencies, and duplicate names at compile time. Registration must not
  depend on filesystem traversal order or runtime global constructors.
- Use typed options with explicit metadata for ranges, help, units, and aliases;
  derive repetitive access with `@field` and `@FieldType` where useful.
- Zig 0.17 reflection uses `field_names` / `field_types`; do not copy older
  `@typeInfo(T).@"struct".fields` or `@Type(...)` recipes. Consult `@Struct`,
  `@Enum`, and other current constructors only when generated types are needed.
- Specialize hot loops on a small set of real constants. Use runtime dispatch
  at stream/component boundaries rather than generating every possible graph.
- Parse wire bytes explicitly. A Zig `packed struct` is not a general container
  or bitstream parser. Check lengths and arithmetic before reads/allocations.

## Porting and validation

Inspect source with `rg` and read the corresponding implementation, header,
Makefile feature/dependency entries, and relevant tests before porting behavior.
Port a small working path at a time. The first path is a bounded RIFF/WAV PCM
signed 16-bit little-endian reader/decoder/writer, then the zffprobe CLI.

### Recording differences from FFmpeg in notes.md

Match FFmpeg, its bugs and quirks included, even where a specification or the
codec's own reference library (libopus, libvorbis, ...) behaves otherwise
("Reference behavior" in notes.md's port design policy). Every place where the
port's observable behavior is not FFmpeg's, or is FFmpeg's on purpose against
the obvious alternative, has a row in [notes.md](notes.md), in the feature's
section, naming the FFmpeg code, what the port or the alternative does, and
the checks or recorded differences that pin it. Add or update the row in the
same commit as any of these:

- a recorded difference in `compare.py` (a `KNOWN_*` table, `FIELD_DIFFERENCES`,
  an expected rejection FFmpeg accepts, an inline special case);
- a code comment saying the port departs from, does not model or does not port
  FFmpeg's behavior, or defers it to a task ("where FFmpeg", "FFmpeg would",
  "not ported", "not modeled", "until Tnn");
- an FFmpeg bug or quirk reproduced on purpose;
- a value chosen where FFmpeg's C is undefined (follow the reference build,
  notes.md "Undefined C behavior") or reads memory it never wrote;
- a refusal (`LimitExceeded`, `UnsupportedOperation`, a stricter parse) of
  input or options FFmpeg accepts;
- an intentional difference or limitation in a port.md contract or a TODO.md
  card that changes output, errors or timing against FFmpeg.

When a later task removes a difference, delete or revise its row, the comment
and the recorded difference together. Before a task reaches G5, check its
changes: search the changed files for those phrases and the new `compare.py`
entries, and confirm each has its row. Rows describe the current state, so
fix a row a change makes stale in the same commit.

### Speed check

Every feature that adds or changes a decode, encode, demux, mux or
conversion path gets a quick speed comparison with FFmpeg before it reaches
G5: correctness checks cannot see a second pass over the input. The T53
I/O study (the `zig-io` skill, E2E-C) found zffmpeg decoding Ogg and MP3
twice from a file, 45% of the conversion, which every comparison had
passed. Run [speed_check.py](zig/testing/reference/speed_check.py) on the
feature's own paths: each new decoder into WAV, each new encoder from WAV,
and a probe or stream copy when it reads the whole input; for example

```bash
ZIG=/home/julek/zig/zig-x86_64-linux-0.17.0/zig python3 zig/testing/reference/speed_check.py \
    <scratch-dir> '@base:caf:-c:a alac' wav
```

It builds zffmpeg in ReleaseFast and times it from a file and from a pipe
against the pinned reference build (the oracle, no assembly) and the
native build (assembly and `-march=native`, built by the `zig-io` skill's
`bench/build-ffmpeg-native.sh`; rebuild it when `build-ffmpeg.sh`'s
components change), all pinned to one core. Run it on an idle machine,
not beside the local CI.

- A warning means zffmpeg takes more than 1.5 times the reference build's
  time, or its file path more than 1.3 times its pipe path. Profile it
  (`perf record`, `perf report`), find the cause and fix it before G5, or
  record in notes.md why it stays (for example a counting pass that only
  an output which cannot seek back needs).
- Slower than the native build is expected where FFmpeg has assembly
  (T58); record the ratio, do not chase it here.
- The task's evidence note records each command's median and its ratio to
  the reference build.

### Malformed input, cleanup and the CLI

The review of 2026-11-04 found memory-safety defects, double frees and
unbounded work that every test mode and the FFmpeg comparison passed. They
live on paths valid fixtures never reach. The `zig-0-17` guide's "Hostile
input" and "Shape the port as Zig, not as C" sections hold the coding rules;
these are the project rules around them:

- A parser, demuxer or decoder change needs a malformed-input regression test
  that runs in Debug. Use crafted bytes in a unit test, plus a process case
  for each tool that reaches the path. A fuzz entry varies the limits
  (unknown length, tag collection, seeking), not only the defaults.
- Compare work against FFmpeg's on adversarial input. A header-declared count
  must not drive per-unit work, and where FFmpeg is linear the port must be
  too.
- CLI outputs:
  - Every check that depends only on the request runs before the output is
    created; this includes resampler bounds and encoder block sizes.
  - Failure cleanup removes only a regular file this run created; never a
    FIFO, symlink or device.
  - Header rewrites seek only regular files.
  - Output-side failures name the output.
- A recorded difference in compare.py asserts the difference it records, for
  example the error name, or equality of everything but the recorded field.
  A fixture listed there must still fail when our side crashes.
- Float-to-integer conversions and C's `lrint`/`lrintf`/`rint` go through
  `zig/core/cconv.zig`, which returns the reference build's result for NaN,
  infinities and overflow; a bare `@trunc` or `@intFromFloat` on an
  unproven value is a panic in Debug and undefined in ReleaseFast. The
  skill's "C's numeric conversions" section has the rules (the review of
  2026-11-05).
- An open design question goes in notes.md's "Open questions" section. It
  states the current behavior and the evidence that would settle it. Until
  it is answered, the code takes the safe option: refuse with a recorded
  difference, or keep the current behavior.

For implemented multimedia behavior, use hand-checked vectors and differential
tests against a recorded FFmpeg revision/configuration. Check decoded content,
metadata, timestamps, failure cases, and resource cleanup. Bit-exact results are
appropriate for integer/lossless paths; define justified tolerances for floating
point or lossy paths. Test round trips against an independent reference as well
as the port. Run relevant FATE cases only when their prerequisites are present.
Required local fixtures must fail when missing. Report skips from optional
external corpora explicitly; a passing run with skips is not complete coverage.

## Provenance and commits

Record each completed feature in port.md with source provenance, supported
subset, tests run, and remaining limitations. New Zig files start with an
`SPDX-License-Identifier` line and a provenance comment, then `//!` module docs
(see `zig/examples/`); [LICENSE](LICENSE) holds the LGPL v2.1 text for the
`LGPL-2.1-or-later` project sources. For a derived file, record its upstream
path/revision and attribution and preserve the actual notices instead of
assigning one SPDX tag indiscriminately. Keep optional GPL/external components
explicit. Use descriptive commit subjects; do not rewrite existing history as
part of documentation work.
