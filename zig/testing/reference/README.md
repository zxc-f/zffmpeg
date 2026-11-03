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
| [compare.py](compare.py) | Runs FFmpeg's `ffprobe` and `ffmpeg` and our `zffprobe` on every [WAV fixture](../fixtures/README.md) and [AU fixture](../fixtures/au/README.md), has FFmpeg read the files the Zig [write driver](../write_driver.zig) and `zffmpeg` produce, checks `zffprobe` through a pipe, prints a Markdown report and exits with status 1 on any failure. Python 3, standard library only. |

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
python3 zig/testing/reference/compare.py --ffmpeg .references/ffmpeg-install/bin/ffmpeg --ffprobe .references/ffmpeg-install/bin/ffprobe --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver --zffmpeg zig-out/bin/zffmpeg
```

The T20a sample-storage vectors come from the same build. The generator is
an original C program that calls the reference's `libavutil`; its output,
with LF line endings, must equal the committed file:

```bash
clang -O1 -I.references/ffmpeg-install/include zig/testing/reference/samplefmt_vectors.c .references/ffmpeg-install/lib/libavutil.a -lm -pthread -o samplefmt-vectors
./samplefmt-vectors | diff -u zig/testing/vectors/samplefmt.txt -
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
--enable-protocol=file,pipe --enable-demuxer=wav,au
--enable-decoder=pcm_s16le,pcm_s16be --enable-encoder=pcm_s16le
--enable-muxer=pcm_s16le --enable-filter=aresample
```

Everything is disabled and then only what the comparison needs is enabled: the
file and pipe protocols, the WAV and AU demuxers (T12a added AU), the s16le and
s16be PCM decoders, the s16le encoder and the raw s16le muxer for `-f s16le`
output, and the `aresample` filter for the
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

- **Accepted WAV fixtures.** `ffprobe` must report `format_name=wav`,
  `codec_name=pcm_s16le`, `sample_fmt=s16` and the expected `channels`,
  `channel_layout`, `sample_rate`, `time_base` (`1/rate`) and `duration_ts`
  (frames). `ffmpeg -f s16le` must decode exactly the expected samples, compared
  byte for byte. `zffprobe` must exit 0 with exactly the expected nine-line
  report.
- **Rejected WAV fixtures.** `zffprobe` must exit with the contract's status and end
  its diagnostic with the contract's error name. FFmpeg's own verdict is
  recorded but not checked, because the contract is deliberately stricter.
  FFmpeg counts as accepting a fixture when both `ffprobe` and `ffmpeg` exit 0.
- **AU fixtures.** FFmpeg reads each file forced with `-f au`, which records
  parser acceptance, and again by content detection, recorded separately. For
  accepted fixtures the forced read must give `codec_name=pcm_s16be`, the
  expected stream fields and exactly the expected samples, and detection must
  find `au` except for the recorded difference. For rejected fixtures FFmpeg's
  verdict is recorded but not checked. `zffprobe` must give the expected
  report, or the contract's status and error, except where content detection
  sends a file without the `.snd` magic to the WAV parser (`au_bad_magic`
  reports `InvalidRiff`).
- **Zig-written files.** The write driver writes every WAV and AU
  writer-output stream from raw samples. Each file must equal its fixture byte
  for byte, and FFmpeg must decode it to the expected samples and stream.
- **zffmpeg (T13b).** Every accepted WAV and AU fixture is converted in each
  supported cell of the operation matrix (transcode to WAV, transcode to AU,
  copy within its own codec) into a real file, which FFmpeg must probe and
  decode to the fixture's samples and stream; the same command through
  standard input and output must give the same bytes. Copy into the other
  codec must exit 3 with `UnsupportedOperation` and create no file.
- **Pipes.** `zffprobe -` reading each of the 81 WAV and AU fixtures from a
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

### Accepted WAV fixtures

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
| `fmt_size_14` | `InvalidFormat` (2) | rejects: no decoder for pcm_u8 in this build |
| `fmt_truncated` | `Truncated` (2) | rejects: Invalid data found when processing input |
| `fmt20_cbsize2` | `UnsupportedFormat` (3) | accepts: 8000 Hz, 4 samples |
| `fmt_extensible` | `UnsupportedFormat` (3) | accepts: mono, 8000 Hz, 4 samples |
| `fmt_float32` | `UnsupportedFormat` (3) | rejects: no decoder for pcm_f32le in this build |
| `fmt_bits24` | `UnsupportedFormat` (3) | rejects: no decoder for pcm_s24le in this build |
| `fmt_channels3` | `UnsupportedFormat` (3) | accepts: 3 channels, 8000 Hz, 6 samples |
| `fmt_channels0` | `InvalidFormat` (2) | rejects: [pcm_s16le] Decoder requires channel layout to be set |
| `fmt_rate0` | `InvalidFormat` (2) | rejects: [wav] Invalid sample rate: 0 |
| `fmt_rate_over_limit` | `LimitExceeded` (5) | accepts: 192001 Hz, 4 samples |
| `fmt_block_align_mismatch` | `InvalidFormat` (2) | accepts: 8000 Hz, 8 samples |
| `fmt_unsupported_before_invalid` | `UnsupportedFormat` (3) | rejects: no decoder for pcm_f32le in this build |
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
mistakes, and has no rate or chunk limits. Four rejections (`fmt_size_14`,
`fmt_float32`, `fmt_bits24`, `fmt_unsupported_before_invalid`) come from this
minimal build lacking those decoders (the full message is "Decoding requested,
but no decoder found for: …"); a fuller FFmpeg build would decode them.

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
| `au_encoding_mulaw` | `UnsupportedFormat` (3) | rejects: no decoder for pcm_mulaw in this build | au |
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

## Updating the reference

Change the commit or configuration only in `build-ffmpeg.sh`; the cache key
follows the script, so CI rebuilds. Then update the tables here from the new
run's environment step and report, and review every changed FFmpeg verdict.
The decision itself is recorded in [notes.md](../../../notes.md).
