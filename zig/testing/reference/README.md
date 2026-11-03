# FFmpeg reference build and comparison

This directory holds the C reference setup (TODO.md T03) and the differential
check of the first WAV/PCM path (T10). The reference is an unmodified FFmpeg
built from the pinned commit with a minimal LGPL configuration. It is a test
oracle only: nothing in the `av` module or the tools links to it, and its
binaries are never committed.

| Path | Role |
| --- | --- |
| [build-ffmpeg.sh](build-ffmpeg.sh) | Clones or checks out `.references/ffmpeg` at the pinned commit, builds it out of tree in `.references/ffmpeg-build` and installs it to the given prefix. It records the configure arguments, commit, compiler and `config.log` in `<prefix>/share/zffmpeg-reference/`. |
| [compare.py](compare.py) | Runs FFmpeg's `ffprobe` and `ffmpeg` and our `zffprobe` on every [WAV fixture](../fixtures/README.md), prints a Markdown report and exits with status 1 on any failure. Python 3, standard library only. |

## Reproduce

Linux x86-64 with Git, Clang, GNU Make, Python 3 and Zig 0.17.0. Run from the
repository root:

```bash
bash zig/testing/reference/build-ffmpeg.sh .references/ffmpeg-install
```

```bash
zig build -Doptimize=ReleaseSafe
```

```bash
python3 zig/testing/reference/compare.py --ffmpeg .references/ffmpeg-install/bin/ffmpeg --ffprobe .references/ffmpeg-install/bin/ffprobe --zffprobe zig-out/bin/zffprobe
```

CI runs the same three steps in the `reference` job of
[ci.yml](../../../.github/workflows/ci.yml) and appends the report to the job
summary. The installed reference is cached under a key made from the runner
image, the Clang version line and the hash of `build-ffmpeg.sh`, so changing
the script or the compiler rebuilds it (about 51 seconds). A cache is saved
only when the job passes.

## Configuration

FFmpeg commit `5d5a38a7e46be296eab75982c0986054f731e19e`, the same revision as
the [inspected baseline](../../../port.md#inspected-baseline). `configure` runs
with the install prefix and:

```text
--cc=clang --disable-everything --disable-autodetect --disable-doc
--disable-network --disable-x86asm --disable-ffplay --disable-avdevice
--enable-protocol=file,pipe --enable-demuxer=wav --enable-decoder=pcm_s16le
--enable-encoder=pcm_s16le --enable-muxer=pcm_s16le --enable-filter=aresample
```

Everything is disabled and then only what the comparison needs is enabled: the
file and pipe protocols, the WAV demuxer, the s16le PCM decoder and encoder,
the raw s16le muxer for `-f s16le` output, and the `aresample` filter for the
`ffmpeg` program's audio filter graph. The program itself selects the few other
filters it always needs. There are no GPL, nonfree, external-library or
hardware components, and autodetection is off. `--disable-x86asm` keeps the C
code paths as the reference and avoids a NASM dependency. The broad FATE
configuration is deliberately not used.

## Recorded run

[Run 41557971301](https://github.com/zxc-f/zffmpeg/actions/runs/41557971301)
(commit `501d617`) built the reference from scratch and passed. Its "Record the
environment and the reference build" step printed:

| Item | Value |
| --- | --- |
| Runner | GitHub-hosted `ubuntu-24.04`, image `ubuntu24` 20261026.354.1 (printed from run 41559086382 on): Ubuntu 24.04.5 LTS, Linux 7.0.0-1017-azure x86_64 |
| Compiler | Ubuntu clang version 18.1.3 (1ubuntu1), the runner's `clang` |
| Build tools | GNU Make 4.3, Python 3.12.3, Zig 0.17.0 |
| FFmpeg | `ffmpeg version git-2026-11-02-5d5a38a` |
| Libraries | libavutil 61.20.100, libavcodec 63.25.102, libavformat 63.18.100, libavfilter 12.12.100, libswscale 10.6.100, libswresample 7.7.100 |
| `bin/ffmpeg` SHA-256 | `c606a09115285d2e3ef11ee71226bb04138756de3b9f06c590b6536732e3e84b` |
| `bin/ffprobe` SHA-256 | `326a66ccd1423291f9a770fa04e44fe7d9310f6f2575e35c23ddf8cf35b57ff7` |
| `config.log` SHA-256 | `710789dd657a9b1a4fc4347ed2e77c100528b573ad0310513fd856dbceb02655` |
| Fixtures SHA-256 | `d0bfcb3bf002e47cc0f297d87373480d3d4447d774a9b548bc5880356ac95785`, from `cat zig/testing/fixtures/wav/*.wav \| sha256sum` over the 52 committed files |

The binaries and `config.log` contain the absolute install prefix
(`/home/runner/work/zffmpeg/zffmpeg/.references/ffmpeg-install` in CI), so
their hashes identify that CI build. A build at another path has different
hashes but must give the same comparison results.
[Run 41559086382](https://github.com/zxc-f/zffmpeg/actions/runs/41559086382)
restored this build from the cache, printed the same versions and hashes, and
gave the same results.

## What is compared

Expectations come from `generate.py`, the source of the committed fixtures,
not from the Zig code or from FFmpeg. `compare.py` first checks that every
fixture file exists and matches `generate.py`; a missing or changed fixture
fails the run. No optional external corpus is used, so nothing is skipped.

- **Accepted fixtures.** `ffprobe` must report `format_name=wav`,
  `codec_name=pcm_s16le`, `sample_fmt=s16` and the expected `channels`,
  `channel_layout`, `sample_rate`, `time_base` (`1/rate`) and `duration_ts`
  (frames). `ffmpeg -f s16le` must decode exactly the expected samples, compared
  byte for byte. `zffprobe` must exit 0 with exactly the expected nine-line
  report.
- **Rejected fixtures.** `zffprobe` must exit with the contract's status and end
  its diagnostic with the contract's error name. FFmpeg's own verdict is
  recorded but not checked, because the contract is deliberately stricter.
  FFmpeg counts as accepting a fixture when both `ffprobe` and `ffmpeg` exit 0.
- **Normalization.** Fields and samples are compared exactly. Only FFmpeg's
  diagnostic text is normalized: the file path and `@ 0x…` pointer addresses are
  removed.
- **Known differences** are listed in `compare.py` and matched on the exact
  field and value; any other mismatch fails.

## Results

Run 41557971301 reported:

- Accepted fixtures matching FFmpeg and zffprobe: **12/12**.
- Rejected fixtures with the contract's zffprobe status: **40/40**.
- Rejected fixtures that FFmpeg accepts (intentional differences): 24/40.

### Accepted fixtures

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
| `channel_layout`, every accepted fixture | `unknown` | `mono` or `stereo` | A plain tag-1 `fmt ` has no channel mask, so FFmpeg's demuxer leaves the channel order unspecified and `ffprobe` prints `unknown`. The contract reports the default layout for one or two channels. FFmpeg does report `mono` for `fmt_extensible`, whose header carries a mask. |
| `duration_ts`, `empty_data` only | `N/A` | `0` | FFmpeg reads a `data` size of 0 as unknown length and sets no duration; it still decodes zero samples. The contract treats 0 as an empty stream. |

### Writer output checked by FFmpeg

The five writer-output fixtures above are the exact bytes that `wav.Writer`
produces for their streams: `zig/format/wav.zig` and `zig/io/file.zig` test
that byte for byte, in memory and through files. FFmpeg decodes those bytes to
the expected samples and metadata, including the empty stream and the 96 kHz
and 192 kHz tag-1 headers that FFmpeg's own writer would emit as
WAVE_FORMAT_EXTENSIBLE. Together these checks validate the writer with an
independent decoder rather than only by self round trips. Feeding writer output
to FFmpeg directly needs a writing tool (T13).

### Rejected fixtures

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

## Updating the reference

Change the commit or configuration only in `build-ffmpeg.sh`; the cache key
follows the script, so CI rebuilds. Then update the tables here from the new
run's environment step and report, and review every changed FFmpeg verdict.
The decision itself is recorded in [notes.md](../../../notes.md).
