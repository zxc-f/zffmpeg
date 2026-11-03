# FFmpeg reference build and comparison

This directory holds the C reference setup (TODO.md T03) and the differential
checks of the WAV/PCM path (T10), the AU path (T12, with T19a's oracle
phase and write driver) and `zffmpeg`'s output (T13b). The reference is an unmodified FFmpeg
built from the pinned commit with a minimal LGPL configuration. It is a test
oracle only: nothing in the `av` module or the tools links to it, and its
binaries are never committed.

| Path | Role |
| --- | --- |
| [build-ffmpeg.sh](build-ffmpeg.sh) | Clones or checks out `.references/ffmpeg` at the pinned commit, builds it out of tree in `.references/ffmpeg-build` and installs it to the given prefix. It records the configure arguments, commit, compiler and `config.log` in `<prefix>/share/zffmpeg-reference/`. |
| [compare.py](compare.py) | Runs FFmpeg's `ffprobe` and `ffmpeg` and our `zffprobe` on every [WAV fixture](../fixtures/README.md), [AU fixture](../fixtures/au/README.md), [AIFF fixture](../fixtures/aiff/README.md) and [raw PCM fixture](../fixtures/raw/README.md), has FFmpeg read the files the Zig [write driver](../write_driver.zig) and `zffmpeg` produce, checks `zffprobe` through a pipe, compares the [registry dump](../registry_dump.zig) with FFmpeg's own codec and format listings, prints a Markdown report and exits with status 1 on any failure. Python 3, standard library only. |

## Reproduce

Linux x86-64 with Git, Clang, GNU Make, Python 3 and Zig 0.17.0. Run from the
repository root:

```bash
bash zig/testing/reference/build-ffmpeg.sh .references/ffmpeg-install
```

```bash
zig build -Doptimize=ReleaseSafe install test-tools
```

```bash
python3 zig/testing/reference/compare.py --ffmpeg .references/ffmpeg-install/bin/ffmpeg --ffprobe .references/ffmpeg-install/bin/ffprobe --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver --zffmpeg zig-out/bin/zffmpeg --registry zig-out/bin/registry-dump
```

The T20a sample-storage vectors come from the same build. The generator is
an original C program that calls the reference's `libavutil`; its output,
with LF line endings, must equal the committed file:

```bash
clang -O1 -I.references/ffmpeg-install/include zig/testing/reference/samplefmt_vectors.c .references/ffmpeg-install/lib/libavutil.a -lm -pthread -o samplefmt-vectors
./samplefmt-vectors | diff -u zig/testing/vectors/samplefmt.txt -
```

The T20b PCM codec vectors come from the reference's `libavcodec` the same way:

```bash
clang -O1 -I.references/ffmpeg-install/include zig/testing/reference/pcm_vectors.c .references/ffmpeg-install/lib/libavcodec.a .references/ffmpeg-install/lib/libavutil.a -lm -pthread -o pcm-vectors
./pcm-vectors | diff -u zig/testing/vectors/pcm.txt -
```

On Windows (MSYS2 UCRT64 clang) link with `-lm -lbcrypt` instead of
`-pthread` and strip the carriage returns MinGW's text output adds
(`tr -d '\015'`) before comparing.

CI runs the same steps in the `reference` job of
[ci.yml](../../../.github/workflows/ci.yml) and appends the report to the job
summary. The installed reference is cached under a key made from the runner
image, the Clang version line and the hash of `build-ffmpeg.sh`, so changing
the script or the compiler rebuilds it (about 51 seconds for the WAV-only
configuration). A cache is saved only when the job passes.

## Configuration

FFmpeg commit `5d5a38a7e46be296eab75982c0986054f731e19e`, the same revision as
the [inspected baseline](../../../port.md#inspected-baseline). `configure` runs
with the install prefix and:

```text
--cc=clang --disable-everything --disable-autodetect --disable-doc
--disable-network --disable-x86asm --disable-ffplay --disable-avdevice
--enable-protocol=file,pipe --enable-demuxer=wav,w64,au,aiff,$pcm_formats
--enable-decoder=$pcm_codecs --enable-encoder=$pcm_codecs
--enable-muxer=wav,w64,au,aiff,$pcm_formats --enable-filter=aresample

pcm_codecs=pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,
  pcm_s32be,pcm_s64le,pcm_s64be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,
  pcm_alaw,pcm_mulaw
pcm_formats=pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,
  pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw
```

Everything is disabled and then only what the comparison needs is enabled: the
file and pipe protocols, the WAV, Wave64, AU and AIFF demuxers (T12a added AU,
T21b Wave64, T22b AIFF), the PCM
decoders and encoders T20b compares (T20b widened them from s16 alone), the
WAV muxer, through which `compare.py` takes FFmpeg's decoded samples in each
stream's storage format (T21a; it replaced the raw s16le muxer), the Wave64
muxer, whose files `zffprobe` and `zffmpeg` must read (T21b), the AU muxer,
whose copies of the AU writer-output fixtures must be byte-identical (T22a), the
AIFF muxer, likewise for AIFF (T22b), the raw PCM demuxers and muxers of every
codec FFmpeg has one for, all but s64 (T22c), and the
`aresample` filter for the
`ffmpeg` program's audio filter graph. The program itself selects the few other
filters it always needs. There are no GPL, nonfree, external-library or
hardware components, and autodetection is off. `--disable-x86asm` keeps the C
code paths as the reference and avoids a NASM dependency. The broad FATE
configuration is deliberately not used.

## Recorded run

T12a changed the configuration, so [run 41579247329](https://github.com/zxc-f/zffmpeg/actions/runs/41579247329)
(commit `d41c5a4`) built this reference. [Run 41660265753](https://github.com/zxc-f/zffmpeg/actions/runs/41660265753)
(commit `3bbdcf9`, T12c) restored it from the cache, and its "Record the
environment and the reference build" step printed:

| Item | Value |
| --- | --- |
| Runner | GitHub-hosted `ubuntu-24.04`, image `ubuntu24` 20261026.354.1: Ubuntu 24.04.5 LTS, Linux 7.0.0-1017-azure x86_64 |
| Compiler | Ubuntu clang version 18.1.3 (1ubuntu1), the runner's `clang` |
| Build tools | GNU Make 4.3, Python 3.12.3, Zig 0.17.0 |
| FFmpeg | `ffmpeg version git-2026-11-02-5d5a38a` |
| Libraries | libavutil 61.20.100, libavcodec 63.25.102, libavformat 63.18.100, libavfilter 12.12.100, libswscale 10.6.100, libswresample 7.7.100 |
| `bin/ffmpeg` SHA-256 | `dec319185b9307c56a28e5d0539325f1277d0b7c0ecc88e23341c19d01ee8bf3` |
| `bin/ffprobe` SHA-256 | `286100a999f7096db2e4a2570d3d220c925aef12fbb5f41d84a6bf4562fdcad2` |
| `config.log` SHA-256 | `d5179a8f90e73d90f620e296742c7cf712cd35f41574ed2bb7316c50d5497c47` |
| WAV fixtures SHA-256 | `d0bfcb3bf002e47cc0f297d87373480d3d4447d774a9b548bc5880356ac95785`, from `cat zig/testing/fixtures/wav/*.wav \| sha256sum` over the 52 committed files |
| AU fixtures SHA-256 | `d36c860119969c43c1ac0e66580b1528e89d7a865925f5c69433be63080f4df0`, from `cat zig/testing/fixtures/au/*.au \| sha256sum` over the 29 committed files |

The binaries and `config.log` contain the absolute install prefix
(`/home/runner/work/zffmpeg/zffmpeg/.references/ffmpeg-install` in CI), so
their hashes identify that CI build. A build at another path has different
hashes but must give the same comparison results. The earlier WAV-only build
(T03, [run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301))
had `bin/ffmpeg` SHA-256
`c606a09115285d2e3ef11ee71226bb04138756de3b9f06c590b6536732e3e84b`; its WAV
results are unchanged in this build.

## What is compared

Expectations come from `generate.py`, the source of the committed fixtures,
not from the Zig code or from FFmpeg. `compare.py` first checks that every
fixture file exists and matches `generate.py`; a missing or changed fixture
fails the run. No optional external corpus is used, so nothing is skipped.

- **Accepted WAV fixtures.** `ffprobe` must report `format_name=wav` (`w64`
  for the Wave64 fixtures, T21b), the
  fixture's `codec_name` and storage `sample_fmt` (`s32` for 24-bit, as FFmpeg
  stores it), and the expected `channels`, `channel_layout`, `sample_rate`,
  `time_base` (`1/rate`) and `duration_ts` (frames). `ffmpeg` must decode
  exactly the expected samples in that storage format (written with
  `-c:a pcm_<storage>le -f wav`, compared byte for byte, float bits included).
  `zffprobe` must exit 0 with exactly the expected nine-line report.
- **Rejected WAV fixtures.** `zffprobe` must exit with the contract's status and end
  its diagnostic with the contract's error name. FFmpeg's own verdict is
  recorded but not checked, because the contract is deliberately stricter.
  FFmpeg counts as accepting a fixture when both `ffprobe` and `ffmpeg` exit 0.
- **Tags (T21c).** For every accepted WAV fixture, ffprobe's format tags
  (`-show_entries format_tags -of compact=p=0:escape=c`, unescaped) and
  zffprobe's `tag:` lines must both equal the fixture's hand-written tags, in
  order. FFmpeg must read back the tags of the Zig writer's tagged files. Each
  zffmpeg WAV output from a tagged input must carry the tags FFmpeg's own
  `ffmpeg -bitexact` conversion of the same input carries (copy or
  `-c:a pcm_s16le`), apart from the recorded difference below, and Wave64
  and AU outputs must carry none.
- **Unknown-length WAV (T21b).** For each fixture whose result changes with
  the parser's `unknown_length` option, FFmpeg (which always reads unknown
  sizes to the end) must decode exactly the samples the option accepts, with
  the stream fields but no duration. FFmpeg's verdict on the ones the option
  still rejects is recorded. Its refusal of the two Wave64 ones is a known
  difference, checked: if FFmpeg starts reading them, the run fails.
- **AU fixtures.** FFmpeg reads each file forced with `-f au`, which records
  parser acceptance, and again by content detection, recorded separately. For
  accepted fixtures the forced read must give the fixture's `codec_name` (since
  T22a any AU PCM encoding) and storage `sample_fmt`, the expected stream
  fields and exactly the expected samples, and detection must
  find `au` except for the recorded difference. For rejected fixtures FFmpeg's
  verdict is recorded but not checked. `zffprobe` must give the expected
  report, or the contract's status and error, forced with `-f au` where
  FFmpeg's probe detects nothing, which then gives `UnknownFormat` (T16;
  before it, `au_bad_magic` went to the WAV parser and reported `InvalidRiff`).
- **AIFF fixtures (T22b).** As for AU, with `-f aiff`: accepted fixtures must
  give the expected codec, storage, fields and samples forced and agree on
  detection; FFmpeg's verdict on rejected ones is recorded; `zffprobe` must
  give the report or the contract's status and error, forced with `-f aiff`
  where FFmpeg's probe detects nothing.
- **Raw PCM fixtures (T22c).** FFmpeg and `zffprobe` read each one forced
  with its format and parameters (`-f`, `-sample_rate`, `-ch_layout`); accepted
  ones must give the expected fields and samples, rejected ones the contract's
  status, FFmpeg's verdict recorded. A copy of each accepted fixture named
  with its format's extension (`.ub`, `.sb`, `.al`, `.ul`, `.sw`) must be
  detected as that format by FFmpeg and `zffprobe`, with the same report.
  FFmpeg's raw muxer must copy each writer-output fixture unchanged.
- **Registries (T16).** The `registry-dump` test tool prints the codec
  descriptors, decoders and encoders, formats and muxers. They must equal the
  reference build's `ffmpeg -codecs` (flags and long names), `ffmpeg -formats`
  and `ffmpeg -h muxer=...` (extensions, MIME type, default audio codec), and
  cover exactly the codecs and formats it enables; no registered demuxer may
  declare an extension, since detection ignores file names.
- **Zig-written files.** The write driver writes every WAV, AU and AIFF
  writer-output stream from raw samples, in its codec (T21a: every WAV
  encoding, plain and extensible; T21b: RF64 and Wave64 too). Each file must
  equal its fixture byte for byte, and FFmpeg must decode it to the expected
  samples and stream.
- **zffmpeg (T13b).** Every accepted WAV, Wave64, AU and AIFF fixture is
  converted in each supported cell of the operation matrix (transcode to WAV,
  Wave64, AU or AIFF; copy into a container that carries its codec) into a
  real file, which FFmpeg must probe and decode to the fixture's samples and
  stream; the same command through standard input and output must give the
  same bytes. Copy into a container without the codec must exit 3 with
  `UnsupportedOperation` and create no file. Raw PCM inputs are forced with
  their parameters, and the raw `s16le`, `alaw` and `f64be` outputs are read
  back with the stream's; transcoding into A-law is lossy, so that output must
  equal FFmpeg's own conversion byte for byte instead (T22c). Since T22b, the AU and AIFF
  outputs of every untagged writer-output input must also equal FFmpeg's own
  `ffmpeg -bitexact` conversion byte for byte.
- **FFmpeg's AU muxer (T22a).** FFmpeg copies each AU writer-output fixture
  into AU (`-f au -i … -bitexact -c:a copy -f au`); the result must equal the
  fixture byte for byte, so FFmpeg's muxer and the Zig writer emit the same
  header for every encoding. FFmpeg's AIFF muxer likewise for AIFF (T22b).
- **FFmpeg-written Wave64 (T21b).** FFmpeg copies each writer-output WAV
  fixture with an 8-byte-aligned payload into Wave64; `zffprobe` must report
  it and `zffmpeg -c copy -f wav` must give back exactly the fixture. FFmpeg's
  muxer counts the alignment padding in its sizes, unlike ours.
- **Pipes.** `zffprobe -` reading each of the 223 WAV, AU, AIFF and raw PCM fixtures (raw ones forced) from a
  pipe must give the same status, report and error as reading the file, with
  the path shown as `-`.
- **Not implemented.** Checks whose Zig code has not landed are listed apart
  from passes and skips (`NOT_IMPLEMENTED` in `compare.py`). The list is empty
  since T12c.
- **Normalization.** Fields and samples are compared exactly. Only FFmpeg's
  diagnostic text is normalized: the file path and `@ 0x…` pointer addresses are
  removed.
- **Known differences** are listed in `compare.py` and matched on the exact
  field and value; any other mismatch fails.

## Results

Run 41660265753 reported:

- Accepted WAV fixtures matching FFmpeg and zffprobe: **12/12**.
- Rejected WAV fixtures with the contract's zffprobe status: **40/40**.
- Rejected WAV fixtures that FFmpeg accepts (intentional differences): 24/40.
- Accepted AU fixtures FFmpeg and zffprobe read as expected: **9/9**.
- Rejected AU fixtures with zffprobe's expected status and error: **20/20**.
- Rejected AU fixtures that FFmpeg accepts with `-f au` (intentional
  differences): 7/20.
- Zig-written files FFmpeg reads as expected: **9/9** (5 WAV, 4 AU).
- Fixtures whose pipe result equals the file result: **81/81**.
- Not implemented: none.

T13b added the zffmpeg section. Its first run was local, on Windows at commit
`4433337`, against this configuration built by the unchanged `build-ffmpeg.sh`
with MSYS2 UCRT64 clang 23.1.4 (`ffmpeg version git-2026-11-02-5d5a38a`). Every
section above gave the same counts, and:

- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **63/63**
  (21 accepted fixtures in 3 cells each).
- Copies across codecs rejected before any output: **21/21**.

T21a widened the WAV contract to every WAV PCM encoding and made the reference
build include the WAV muxer. Its first run, locally on Windows at commit
`2cf3a3f` with MSYS2 UCRT64 clang 23.1.4, reported:

- Accepted WAV fixtures matching FFmpeg and zffprobe: **27/27** (u8, s16,
  s24, s32, s64, f32, f64, A-law and mu-law, plain and extensible).
- Rejected WAV fixtures with the contract's zffprobe status: **49/49**; FFmpeg
  accepts 29/49 (recorded, not checked), among them `fmt_bits12`,
  `fmt_alaw_bits16`, `fmt_s24_block_align_mismatch`,
  `extensible_valid_bits_mismatch` and `extensible_mask_mismatch`.
- AU: **9/9** and **20/20**, unchanged.
- Zig-written files FFmpeg reads as expected: **17/17** (13 WAV, every
  encoding; 4 AU), each equal to its fixture. Extensible outputs report
  `mono`/`stereo` exactly: the channel mask is written.
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **90/90**;
  unsupported cells (copy across containers, transcoding samples not stored as
  s16) rejected before any output: **54/54**.
- Fixtures whose pipe result equals the file result: **105/105**.

T22c added raw PCM, and the raw PCM demuxers and muxers to the reference
build, with detection by FFmpeg's extension fallback. The run, locally on
Windows at commit `3b94b6d` with MSYS2 UCRT64 clang 23.1.4, reported no
failures:

- Raw PCM fixtures read forced with their parameters: **16/16** accepted and
  **4/4** rejected (FFmpeg accepts 3, recorded: the partial frames, decoded
  whole, and the rate above the limit); named copies detected by FFmpeg and
  zffprobe as their format: **7/7**; FFmpeg's raw muxers copy the writer
  outputs unchanged: **15/15**.
- Registries equal to FFmpeg's listings: 16 codecs, 18 formats, 18 demuxers'
  extensions, 18 muxers.
- FFmpeg's probe winner equals the recorded one: **223/223** fixtures (44
  detected by no demuxer, the 20 raw ones among them).
- Zig-written files FFmpeg reads as expected: **59/59** (15 raw).
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **694/694**,
  raw inputs and the raw `s16le`, `alaw` and `f64be` outputs included, 58
  lossy A-law transcodes equal to FFmpeg's own encoding; unsupported cells:
  **734/734**; AU and AIFF outputs equal to FFmpeg's conversion: **134/134**.
- WAV, AU and AIFF as before; pipes **223/223**.

T22b added AIFF and AIFF-C, and the AIFF demuxer and muxer to the reference
build; T16 added the registry check. The run, locally on Windows at commit
`c829e01` with MSYS2 UCRT64 clang 23.1.4, reported no failures:

- Accepted AIFF fixtures FFmpeg and zffprobe read as expected: **21/21**;
  rejected ones with zffprobe's status: **23/23**; FFmpeg accepts 11/23
  (recorded, below).
- Registries equal to FFmpeg's listings: 16 codecs, 4 formats, 4 muxers.
- FFmpeg's probe winner equals the recorded one: **203/203** fixtures (24
  detected by no demuxer).
- Zig-written files FFmpeg reads as expected: **44/44** (13 AIFF).
- FFmpeg's AIFF muxer: its `-bitexact` copy of each of the **13/13** AIFF
  writer-output fixtures is byte-identical; AU **11/11** as before.
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **456/456**;
  unsupported cells: **232/232**; AU and AIFF outputs of untagged
  writer-output inputs equal to FFmpeg's own conversion: **105/105** (s16le
  WAV copies into AIFF-C `sowt`, as FFmpeg's muxer tags it).
- WAV **49/49** and **72/72**, AU **16/16** and **22/22**, unknown length
  **12/12**, FFmpeg-written Wave64 **12/12**, pipes **203/203**.

T22a added every AU PCM encoding and unknown-length AU, and the AU muxer to
the reference build. Its run, locally on Windows at commit `2e68534` with
MSYS2 UCRT64 clang 23.1.4, reported no failures:

- Accepted AU fixtures FFmpeg and zffprobe read as expected: **16/16** (µ-law,
  s8, s16/24/32 big-endian, f32/64 big-endian, A-law); rejected AU fixtures
  with zffprobe's status: **22/22**; FFmpeg accepts 10/22 (recorded).
- Unknown-length results: **12/12**, the 2 accepted AU ones decoded the same.
- Zig-written files FFmpeg reads as expected: **31/31** (11 AU).
- FFmpeg's AU muxer: its `-bitexact` copy of each of the **11/11** AU
  writer-output fixtures is byte-identical.
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **265/265**,
  A-law and µ-law copies between WAV and AU included; unsupported cells:
  **125/125**.
- WAV: **49/49** and **72/72**; FFmpeg-written Wave64: **12/12**; pipes
  **159/159**. The C vectors regenerate unchanged.

T21c added WAV tags. Its run, locally on Windows at commit `f494ee7` with the
same build, reported no failures:

- Accepted WAV fixtures matching FFmpeg and zffprobe: **49/49**; for the 11
  with tags, ffprobe's format tags (read with `-of compact=escape=c`) and
  zffprobe's `tag:` lines both equal the hand-written ones, in order.
- Rejected WAV fixtures with the contract's zffprobe status: **72/72**.
- Zig-written files FFmpeg reads as expected: **24/24**, the 2 tagged ones
  with their tags.
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **245/245**;
  each WAV output from a tagged input carries the tags FFmpeg's own
  `ffmpeg -bitexact` conversion carries (`encoded_by` dropped on transcode),
  except `info_after_data`, whose trailing tags are recorded as not carried;
  Wave64 and AU outputs carry none. Unsupported cells: **103/103**.
- The other sections as for T21b; pipes **150/150**.

T21b added RF64/BW64, unknown-length input and Sony Wave64, and the Wave64
demuxer and muxer to the reference build. Its run, locally on Windows at
commit `8373e6b` with MSYS2 UCRT64 clang 23.1.4, reported no failures:

- Accepted WAV fixtures matching FFmpeg and zffprobe: **37/37**, among them
  RF64, BW64 and 7 Wave64 files.
- Rejected WAV fixtures with the contract's zffprobe status: **72/72**; FFmpeg
  accepts 42/72 (recorded, not checked).
- Unknown-length results: **10/10**: FFmpeg decodes the 8 that are RIFF the
  same, and refuses the 2 Wave64 ones as recorded.
- AU: **9/9** and **20/20**, unchanged.
- Zig-written files FFmpeg reads as expected: **22/22** (13 WAV, 1 RF64,
  4 Wave64, 4 AU), each equal to its fixture.
- zffmpeg outputs FFmpeg reads as expected, equal through pipes: **185/185**,
  the 3 empty Wave64 outputs refused by FFmpeg and read by zffprobe as
  recorded; unsupported cells rejected before any output: **91/91**.
- FFmpeg-written Wave64 files read as expected: **12/12**.
- Fixtures whose pipe result equals the file result: **138/138**.

The T20a and T20b vectors regenerate unchanged from this build.

T20b enabled every PCM decoder and encoder it compares. Rebuilt that way,
locally on Windows with MSYS2 UCRT64 clang 23.1.4, the comparison gave the
same counts everywhere except FFmpeg's recorded verdicts: it now accepts
27/40 rejected WAV fixtures (`fmt_size_14`, `fmt_float32` and `fmt_bits24`
gained a decoder) and 8/20 rejected AU fixtures (`au_encoding_mulaw`). Those
verdicts are recorded, not checked; every check still passed. The T20a and
T20b vector generators reproduced their committed files.

### Accepted WAV fixtures

This table records run 41660265753, before T21a. Since T21a, `fmt_extensible`,
`fmt_float32` and `fmt_bits24` are accepted, since T21b `rf64` and `bw64`
too, and the contract has 109 fixtures (`w64` became `w64_no_chunks`); the
fixture README lists them all, and
`compare.py --report` writes the current per-fixture table (results above).

FFmpeg decodes the same samples as the contract for every accepted fixture, and
`ffprobe` agrees on every compared field except the known differences below.

| Fixture | Stream | Writer output |
| --- | --- | --- |
| `mono_8k` | mono, 8000 Hz, 8 frames | yes |
| `stereo_44k1` | stereo, 44100 Hz, 4 frames | yes |
| `stereo_96k_tag1` | stereo, 96000 Hz, 4 frames | yes |
| `mono_192k_rate_limit` | mono, 192000 Hz, 4 frames | yes |
| `empty_data` | mono, 8000 Hz, 0 frames | yes |
| `fmt18_cbsize0` | mono, 8000 Hz, 4 frames | |
| `byte_rate_mismatch` | mono, 8000 Hz, 4 frames | |
| `unknown_chunks` | mono, 8000 Hz, 4 frames | |
| `odd_chunk_padded` | mono, 8000 Hz, 4 frames | |
| `odd_final_chunk_pad_outside_extent` | mono, 8000 Hz, 4 frames | |
| `trailing_bytes_after_riff` | mono, 8000 Hz, 4 frames | |
| `chunks_at_limit` | mono, 8000 Hz, 2 frames | |

### Known metadata differences

| Field | FFmpeg | Contract | Reason |
| --- | --- | --- | --- |
| `channel_layout`, every accepted WAV fixture | `unknown` | `mono` or `stereo` | A plain tag-1 `fmt ` has no channel mask, so FFmpeg's demuxer leaves the channel order unspecified and `ffprobe` prints `unknown`. The contract reports the default layout for one or two channels. FFmpeg does report `mono` for `fmt_extensible`, whose header carries a mask. |
| `duration_ts`, `empty_data` and zffmpeg's WAV output of an empty stream | `N/A` | `0` | FFmpeg reads a `data` size of 0 as unknown length and sets no duration; it still decodes zero samples. The contract treats 0 as an empty stream. |
| `channel_layout`, every accepted AU fixture | `unknown` | `mono` or `stereo` | An AU header has no channel layout. |
| Decoded samples, `au_trailing_bytes_after_data` only | 6 samples | 4 samples | FFmpeg's AU demuxer reads to the end of input and decodes the bytes after the declared data; the contract never reads them. |
| Content detection, `au_empty_data` only | not detected | detected | FFmpeg's `au_probe` needs every header field nonzero, including the data size; with `-f au` it reads the file as expected. Our detection checks only the `.snd` magic. |
| `duration_ts`, Wave64 files with pad bytes or chunks after the data | the bytes from the data start to the end of the file, in frames, rounded | the frame count | FFmpeg's Wave64 demuxer sets no duration from the `data` size, so libavformat estimates one from the bit rate; the decoded samples still match. `compare.py` computes the estimate and accepts exactly that value. |
| Empty Wave64 `data` (zffmpeg's Wave64 output of an empty stream) | rejected | 0 frames | FFmpeg's demuxer rejects any chunk of 24 bytes or less, the header alone; zffprobe must read it. |
| Carried tags, `info_after_data` only | carried | not carried | FFmpeg reads a seekable input's tags after `data` before writing its output header; zffmpeg reads sequentially and has written the header by then. |
| Wave64 unknown sizes (`w64_unknown_length_pipe`, `w64_data_size_unknown`) | rejected | read with `unknown_length` | FFmpeg reads the 64-bit sizes as signed: all ones is -1 and INT64_MAX fails its bounds check, so it rejects even its own pipe output. |

### Zig-written files read by FFmpeg

The write driver ([write_driver.zig](../write_driver.zig), installed by
`zig build test-tools`) writes each writer-output stream with `av.wav.Writer`
or `av.au.Writer`, and `compare.py` gives FFmpeg those files. All 9 were
byte-identical to their fixtures and decoded to the expected samples and
stream:

| Stream | Fixture | Bytes |
| --- | --- | ---: |
| WAV mono, 8000 Hz, 8 frames | `mono_8k` | 60 |
| WAV stereo, 44100 Hz, 4 frames | `stereo_44k1` | 60 |
| WAV stereo, 96000 Hz, 4 frames | `stereo_96k_tag1` | 60 |
| WAV mono, 192000 Hz, 4 frames | `mono_192k_rate_limit` | 52 |
| WAV mono, 8000 Hz, 0 frames | `empty_data` | 44 |
| AU mono, 8000 Hz, 8 frames | `au_mono_8k` | 48 |
| AU stereo, 44100 Hz, 4 frames | `au_stereo_44k1` | 48 |
| AU mono, 192000 Hz, 4 frames | `au_mono_192k_rate_limit` | 40 |
| AU mono, 8000 Hz, 0 frames | `au_empty_data` | 32 |

FFmpeg accepts the empty streams and the 96 kHz and 192 kHz tag-1 WAV headers
that its own writer would emit as WAVE_FORMAT_EXTENSIBLE. The same metadata
differences as for the fixtures apply.

### Rejected WAV fixtures

This table records run 41660265753, before T21a. Since T21a, `fmt_extensible`,
`fmt_float32` and `fmt_bits24` are accepted, since T21b `rf64` and `bw64`
too, and the contract has 109 fixtures (`w64` became `w64_no_chunks`); the
fixture README lists them all, and
`compare.py --report` writes the current per-fixture table (results above).

`zffprobe` gave the contract's status and error name for all 40. FFmpeg's
verdict, recorded for reference:

| Fixture | Contract (zffprobe exit) | FFmpeg |
| --- | --- | --- |
| `empty_input` | `Truncated` (2) | rejects: Invalid data found when processing input |
| `truncated_riff_header` | `Truncated` (2) | rejects: Invalid data found when processing input |
| `not_riff` | `InvalidRiff` (2) | rejects: Invalid data found when processing input |
| `rifx_big_endian` | `UnsupportedFormat` (3) | rejects: [wav] Failed to read extradata of size 25697 |
| `rifx_truncated` | `UnsupportedFormat` (3) | rejects: Invalid data found when processing input |
| `rf64` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 0 samples |
| `bw64` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 0 samples |
| `w64` | `UnsupportedFormat` (3) | rejects: Invalid data found when processing input |
| `riff_size_unknown` | `UnsupportedStreamingSize` (3) | accepts: 8000 Hz, 4 samples |
| `riff_size_zero` | `UnsupportedStreamingSize` (3) | accepts: 8000 Hz, 4 samples |
| `riff_size_too_small` | `InvalidRiff` (2) | accepts: 8000 Hz, 4 samples |
| `not_wave_form` | `InvalidWave` (2) | rejects: Invalid data found when processing input |
| `no_chunks` | `InvalidWave` (2) | rejects: Invalid data found when processing input |
| `fmt_size_14` | `InvalidFormat` (2) | accepts: 8000 Hz, 8 samples |
| `fmt_truncated` | `Truncated` (2) | rejects: Invalid data found when processing input |
| `fmt20_cbsize2` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 4 samples |
| `fmt_extensible` | `UnsupportedFormat` (3) | accepts: mono, 8000 Hz, 4 samples |
| `fmt_float32` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 2 samples |
| `fmt_bits24` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 2 samples |
| `fmt_channels3` | `UnsupportedFormat` (3) | accepts: 3 channels, 8000 Hz, 6 samples |
| `fmt_channels0` | `InvalidFormat` (2) | rejects: [pcm_s16le] Decoder requires channel layout to be set |
| `fmt_rate0` | `InvalidFormat` (2) | rejects: [wav] Invalid sample rate: 0 |
| `fmt_rate_over_limit` | `LimitExceeded` (5) | accepts: 192001 Hz, 4 samples |
| `fmt_block_align_mismatch` | `InvalidFormat` (2) | accepts: 8000 Hz, 8 samples |
| `fmt_unsupported_before_invalid` | `UnsupportedFormat` (3) | rejects: [pcm_f32le] Decoder requires channel layout to be set |
| `data_before_fmt` | `InvalidWave` (2) | accepts: 8000 Hz, 4 samples |
| `missing_data` | `InvalidWave` (2) | rejects: [wav] no 'data' tag found |
| `duplicate_fmt` | `InvalidWave` (2) | accepts: 8000 Hz, 4 samples |
| `duplicate_data` | `InvalidWave` (2) | accepts: 8000 Hz, 2 samples |
| `data_size_unknown` | `UnsupportedStreamingSize` (3) | accepts: 8000 Hz, 2 samples |
| `data_not_block_aligned` | `InvalidFormat` (2) | accepts: 8000 Hz, 2 samples |
| `data_exceeds_riff_extent` | `InvalidRiff` (2) | accepts: 8000 Hz, 8 samples |
| `chunk_exceeds_riff_extent` | `InvalidRiff` (2) | accepts: 8000 Hz, 2 samples |
| `partial_chunk_header_in_extent` | `InvalidRiff` (2) | accepts: 8000 Hz, 2 samples |
| `odd_final_chunk_pad_missing` | `Truncated` (2) | accepts: 8000 Hz, 4 samples |
| `riff_size_exceeds_input` | `Truncated` (2) | accepts: 8000 Hz, 4 samples |
| `truncated_data` | `Truncated` (2) | accepts: 8000 Hz, 5 samples |
| `truncated_mid_sample` | `Truncated` (2) | accepts: 8000 Hz, 3 samples |
| `truncated_chunk_header_after_data` | `Truncated` (2) | accepts: 8000 Hz, 2 samples |
| `chunks_over_limit` | `LimitExceeded` (5) | accepts: 8000 Hz, 2 samples |

"Samples" counts all samples across channels. FFmpeg's layout is `unknown` for
every accepting row except `fmt_extensible`. The accepting rows are the
intentional differences recorded in the
[fixture decisions](../fixtures/README.md#decisions) and the
[first WAV contract](../../../port.md#first-wav-contract): FFmpeg ignores
`riff_size`, stops at end of input, accepts more `fmt ` variants and ordering
mistakes, and has no rate or chunk limits. Until T20b enabled every PCM
decoder, `fmt_size_14`, `fmt_float32` and `fmt_bits24` failed only for a missing
decoder; FFmpeg now decodes them, and `fmt_unsupported_before_invalid` fails
because its header declares no channels.

### AU fixtures

The 9 accepted AU fixtures (`au_mono_8k`, `au_stereo_44k1`,
`au_mono_192k_rate_limit`, `au_empty_data`, `au_header_24`,
`au_annotation_text`, `au_annotation_odd_length`, `au_one_frame_stereo`,
`au_trailing_bytes_after_data`) decode in FFmpeg with `-f au` to the contract's
samples, apart from the differences above, and `zffprobe` reports each one.
FFmpeg detects all of them by content except `au_empty_data`. For the 20
rejected fixtures, `zffprobe` gave the expected status and error. FFmpeg's
verdict, recorded for reference:

| Fixture | Contract (zffprobe exit) | FFmpeg with `-f au` | FFmpeg detection |
| --- | --- | --- | --- |
| `au_empty_input` | `Truncated` (2) | rejects: Invalid data found when processing input | not detected |
| `au_truncated_header` | `Truncated` (2) | rejects: End of file | not detected |
| `au_bad_magic` | `InvalidAu`; through detection `InvalidRiff` (2) | rejects: Invalid data found when processing input | not detected |
| `au_offset_too_small` | `InvalidAu` (2) | accepts: 8000 Hz, 4 samples | au |
| `au_annotation_over_limit` | `LimitExceeded` (5) | rejects: End of file | not detected |
| `au_truncated_annotation` | `Truncated` (2) | rejects: End of file | not detected |
| `au_unknown_size` | `UnsupportedStreamingSize` (3) | accepts: 8000 Hz, 4 samples | au |
| `au_data_size_over_limit` | `LimitExceeded` (5) | rejects: [au] Invalid negative data size '-2147483648' found | not detected |
| `au_data_not_block_aligned` | `InvalidFormat` (2) | accepts: 8000 Hz, 2 samples | au |
| `au_truncated_data` | `Truncated` (2) | accepts: 8000 Hz, 5 samples | au |
| `au_truncated_mid_sample` | `Truncated` (2) | accepts: 8000 Hz, 2 samples | au |
| `au_encoding_mulaw` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 4 samples | au |
| `au_encoding_g726` | `UnsupportedFormat` (3) | rejects: no decoder for adpcm_g726le in this build | au |
| `au_encoding_unknown` | `UnsupportedFormat` (3) | rejects: Not yet implemented in FFmpeg, patches welcome | not detected |
| `au_rate_zero` | `InvalidFormat` (2) | rejects: [au] Invalid sample rate: 0 | not detected |
| `au_rate_over_limit` | `LimitExceeded` (5) | accepts: 192001 Hz, 4 samples | au |
| `au_channels_zero` | `InvalidFormat` (2) | rejects: [au] Invalid number of channels 0 | not detected |
| `au_channels3` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 6 samples | au |
| `au_limit_before_unsupported` | `LimitExceeded` (5) | rejects: [au] Invalid negative data size '-2147483648' found | not detected |
| `au_unsupported_before_invalid` | `UnsupportedFormat` (3) | rejects: [au] Invalid sample rate: 0 | not detected |

"Samples" counts all samples across channels; FFmpeg's layout is `unknown` for
every accepting row. The 7 accepting rows are the intentional differences in
the [AU fixture decisions](../fixtures/au/README.md#decisions): FFmpeg ignores
a data offset below 24 and the declared data size, reads to the end of input,
and has no rate or channel limits. The µ-law and G.726 rejections come from
this minimal build lacking those decoders (the full message is "Decoding
requested, but no decoder found for: …"). The detection column is the format
`ffprobe` reports without `-f`; "not detected" means it found no format or
could not open the file.

### AIFF fixtures

FFmpeg accepts 11 of the 23 rejected AIFF fixtures with `-f aiff`; the
contract is deliberately stricter
([decisions](../fixtures/aiff/README.md#decisions)): `aiff_missing_ssnd`
(0 samples, the duration from `COMM`), `aiff_ssnd_before_comm` and
`aiff_duplicate_comm` (4 samples), `aiff_channels3` (6 samples),
`aiff_rate_over_limit` (192001 Hz), `aiff_bits12` (read as 16-bit),
`aiff_frames_mismatch` (the 4 samples present), `aiff_data_not_block_aligned`
(2 samples), `aiff_ssnd_offset_too_big` (0 samples), `aiff_chunk_exceeds_form`
(4 samples) and `aiff_truncated_data` (2 samples). It rejects the rest;
`aifc_unknown_type` probes as `adpcm_ima_qt`, which this build cannot decode.
The 5 fixtures FFmpeg's probe does not detect (`aiff_empty_input`,
`aiff_not_form`, `aiff_bad_form_type`, `aiff_form_size_small`,
`aiff_truncated_header`) are `UnknownFormat` in zffprobe without `-f aiff`.
AIFF has no layout field without `CHAN`, so ffprobe reports
`channel_layout=unknown` for the accepted ones, the one known field
difference.

## Updating the reference


Change the commit or configuration only in `build-ffmpeg.sh`; the cache key
follows the script, so CI rebuilds. Then update the tables here from the new
run's environment step and report, and review every changed FFmpeg verdict.
The decision itself is recorded in [notes.md](../../../notes.md).
