# Raw PCM fixtures: the raw PCM contract

This is the canonical fixture contract for the
[raw PCM contract](../../../../port.md#raw-pcm-contract) (TODO.md T22c):
header-less interleaved samples in one of FFmpeg's raw PCM formats, read with
stream parameters the caller gives and written unchanged. Every rule has at
least one named fixture here with its expected result. `av.raw`, the format
registry, detection and the reference comparison test against these files.
The WAV contract and its shared conventions are in [../README.md](../README.md).

## Files and commands

| Path | Role |
| --- | --- |
| `../generate.py` | Builds every raw fixture with the Python standard library, and writes this directory's files. |
| `<name>.raw` | The fixture files. `.raw` is no raw format's extension, so they are read with `-f`. |
| `manifest.zon` | Expected results, each with its format and parameters, imported by `zig/testing/fixtures.zig` as `fixtures.raw.all`. |
| `README.md` | This contract; the table at the end is generated. |

Change fixtures only in `generate.py`, then run
`python3 zig/testing/fixtures/generate.py`; `--check` fails when any output is
stale.

## Formats

One raw format per codec FFmpeg has one for (`pcmdec.c`, `pcmenc.c`): every
PCM codec of the port but s64. Each is named as its codec without `pcm_`, and
decodes to that codec's storage.

| Format | Codec | Extension |
| --- | --- | --- |
| `u8`, `s8` | `pcm_u8`, `pcm_s8` | `ub`, `sb` |
| `s16le`, `s16be` | `pcm_s16le`, `pcm_s16be` | `sw` for the native byte order's (FFmpeg's `AV_NE`), so `s16le` on little-endian hosts |
| `s24le`, `s24be`, `s32le`, `s32be` | the matching codec | none |
| `f32le`, `f32be`, `f64le`, `f64be` | the matching codec | none |
| `alaw`, `mulaw` | `pcm_alaw`, `pcm_mulaw` | `al`, `ul` |

## Parameters

Nothing in the bytes names the stream, so the caller gives it, as FFmpeg's
raw demuxer options:

| Option | Default | Rule |
| --- | --- | --- |
| `-sample_rate` (zffmpeg also `-ar`) | 44100 | 0 is `InvalidFormat`; above 192,000 Hz (configurable) is `LimitExceeded`. |
| `-ch_layout` (zffmpeg also `-ac`) | `mono` | `mono` or `stereo` (`-ac` 1 or 2); another layout is unsupported (T23b). |

Given for an input whose format has a header, these options are a usage error
(`UnusedOption`, exit 1); FFmpeg ignores them with a warning.

## Data

The samples run to the end of the input. They must be whole frames (sample
width × channels); input ending inside a frame is `Truncated`. When the
caller knows the input's length (a regular file's size), the frame count is
known before the first sample, so the known-length writers can take raw
input; otherwise, as on a pipe, it is counted while reading, and only raw PCM
output can be written from it (`UnsupportedStreamingSize` for the others).
An empty input is an empty stream.

## Detection

No content probe recognizes raw PCM. As FFmpeg's `av_probe_input_format3`
does, a raw demuxer whose extension matches the input's file name scores 50
(`AVPROBE_SCORE_EXTENSION`), below every content probe (99 or 100), so a file
named `take.al` that no content probe claims is A-law, while a WAV file of
that name is still WAV. Standard input has no name. The project owner chose
this fallback, as FFmpeg has it. Otherwise `-f` selects a raw format.

## Writer

The writer emits the encoded frames and nothing else, as FFmpeg's raw muxers
do; each accepted fixture with explicit parameters is writer output. A frame
count given up front is checked at the end; without one, any whole frames are
accepted.

## Error precedence

The sample rate (zero, then the limit), then a known length that is not whole
frames, then the data as read.

## Decisions

FFmpeg's behavior is from `libavformat/pcmdec.c`, `pcmenc.c`, `pcm.c` and
`format.c` at the pinned revision.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Partial last frame | `Truncated` (`raw_partial_frame`, `raw_partial_sample`). | Decodes the whole frames and reports the partial packet as invalid. |
| Duration | The frame count, exact: from the length, or counted. | Estimated from the file size and bit rate, rounded (the frame count for whole frames); none for an empty file or a pipe. |
| Pipe input to a header with sizes | `UnsupportedStreamingSize`: the writers need the length up front. | Writes placeholder sizes on a pipe, or seeks back in a file. |
| Parameters for a format with a header | Usage error. | Ignored, with a warning. |
| Sample rate above 192 kHz, more than 2 channels | `LimitExceeded`; unsupported layout. | Accepted. |
| `audio/L16` MIME type | Not used (no protocol reports one). | Sets the rate and channels of `s16be` from an HTTP MIME type. |

## Provenance

`../generate.py` is an original project file (`LGPL-2.1-or-later`). The
fixture files and `manifest.zon` are data it generates; their sample values
are the other contracts' hand-picked values. No FFmpeg sample files or code
were used.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `raw_u8_mono_8k` | accepted | 8 | `-f u8`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_u8`; writer output; not detected (probing picks no format) | Unsigned 8-bit mono at 8 kHz. | `e71a7556739eeec114046093e9decc09939640c99429914e6f3042f209164b9c` |
| `raw_s8_mono_8k` | accepted | 8 | `-f s8`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_s8`; writer output; not detected (probing picks no format) | Signed 8-bit; stored as u8, offset by 128. | `0fa7afacef359bb58487bd71c3553f783214c866cec2c29a20118162bf056609` |
| `raw_s16le_mono_8k` | accepted | 16 | `-f s16le`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames; writer output; not detected (probing picks no format) | 16-bit little-endian mono. | `3a941550a1fc894651222384b4eb90f75cc14babfa16bce333ca6a29c03f4604` |
| `raw_s16be_stereo_44k1` | accepted | 16 | `-f s16be`, 44100 Hz, 2 channels; accept: stereo, 44100 Hz, 4 frames; writer output; not detected (probing picks no format) | 16-bit big-endian stereo at 44.1 kHz. | `0a404dc9a109bbd6a83de84b7ed47e50ab05ad48ba506c8cf8f3850b36af536b` |
| `raw_s24le_stereo_48k` | accepted | 24 | `-f s24le`, 48000 Hz, 2 channels; accept: stereo, 48000 Hz, 4 frames, `pcm_s24le`; writer output; not detected (probing picks no format) | 24-bit little-endian stereo at 48 kHz; stored as s32. | `e0f45e4de461b35a561b278f572de909f9a34e2c791942d901d3681d57d8dd21` |
| `raw_s24be_mono_8k` | accepted | 24 | `-f s24be`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_s24be`; writer output; not detected (probing picks no format) | 24-bit big-endian mono. | `284db09ce05846f167697c0ac2e1f5bb5eb052df36c53e2ba52172de82f54b2e` |
| `raw_s32le_mono_8k` | accepted | 32 | `-f s32le`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_s32le`; writer output; not detected (probing picks no format) | 32-bit little-endian mono. | `d310af6d45e7eb9f888164617bd2ecb1f8f0c41a5d4a59af6d77f8e7e8282901` |
| `raw_s32be_stereo_8k` | accepted | 32 | `-f s32be`, 8000 Hz, 2 channels; accept: stereo, 8000 Hz, 4 frames, `pcm_s32be`; writer output; not detected (probing picks no format) | 32-bit big-endian stereo. | `cf6750e78e26e4238ffaa0375624d302aa01dff3a1114fb86e3d74223daaf3fc` |
| `raw_f32le_mono_8k` | accepted | 32 | `-f f32le`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_f32le`; writer output; not detected (probing picks no format) | 32-bit float little-endian; every bit kept. | `ba8f6484dfea46af5247bcea862ddee3a782f577232807ac19c8fc7a9048fb53` |
| `raw_f32be_mono_8k` | accepted | 32 | `-f f32be`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_f32be`; writer output; not detected (probing picks no format) | 32-bit float big-endian. | `f366f3cb0a5a07f2e080bd38eb2768196fdd39585ff581ea269eb7e1cced744a` |
| `raw_f64le_stereo_96k` | accepted | 64 | `-f f64le`, 96000 Hz, 2 channels; accept: stereo, 96000 Hz, 4 frames, `pcm_f64le`; writer output; not detected (probing picks no format) | 64-bit float little-endian stereo at 96 kHz. | `5a7f2149a0dad66797901bd264646091bc3032c14f0774d99bb29c2e1c1f3737` |
| `raw_f64be_mono_8k` | accepted | 64 | `-f f64be`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_f64be`; writer output; not detected (probing picks no format) | 64-bit float big-endian. | `43715f11538183067df19a027be950e6f8b18627bc0e1dbe8cf1d7e11b281c30` |
| `raw_alaw_mono_8k` | accepted | 8 | `-f alaw`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_alaw`; writer output; not detected (probing picks no format) | A-law; decodes to s16. | `24d606b419562a23716c68da9a6e6b07d7c57abf261da4db5ffde5106393b178` |
| `raw_mulaw_mono_8k` | accepted | 8 | `-f mulaw`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 8 frames, `pcm_mulaw`; writer output; not detected (probing picks no format) | µ-law; its negative zero (0x7F) is left out, as for WAV and AU. | `643fb89f0ee9fd1fc2e9cdad6d462c668b6e69b9e173d0af9ceb818f014b7a01` |
| `raw_s16le_defaults` | accepted | 16 | `-f s16le`, defaults; accept: mono, 44100 Hz, 8 frames; not detected (probing picks no format) | No parameters: FFmpeg's defaults, 44100 Hz mono. | `3a941550a1fc894651222384b4eb90f75cc14babfa16bce333ca6a29c03f4604` |
| `raw_empty` | accepted | 0 | `-f s16le`, 8000 Hz, 1 channel; accept: mono, 8000 Hz, 0 frames; writer output; not detected (probing picks no format) | No bytes: an empty stream of 0 frames. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `raw_partial_frame` | rejected | 6 | `-f s16le`, 8000 Hz, 2 channels; reject: `Truncated`; not detected (probing picks no format) | Stereo 16-bit, 6 bytes: the input ends inside its second frame. FFmpeg decodes the whole frame. | `bec0b850f2b4fdd32b68f56dab3bbcd13f1ef527c113690eddef7f0fe53842bd` |
| `raw_partial_sample` | rejected | 4 | `-f s24le`, 8000 Hz, 1 channel; reject: `Truncated`; not detected (probing picks no format) | 24-bit mono, 4 bytes: the input ends inside its second sample. | `df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119` |
| `raw_rate_zero` | rejected | 8 | `-f s16le`, 0 Hz, 1 channel; reject: `InvalidFormat`; not detected (probing picks no format) | Sample rate 0. | `6f31e68b8986562065a3475c1f70ed4d945f799c49daa5778b4ca3a6d41540cd` |
| `raw_rate_over_limit` | rejected | 8 | `-f s16le`, 192001 Hz, 1 channel; reject: `LimitExceeded`; not detected (probing picks no format) | Sample rate 192001 Hz, above the default limit. | `6f31e68b8986562065a3475c1f70ed4d945f799c49daa5778b4ca3a6d41540cd` |
<!-- END GENERATED FIXTURE TABLE -->
