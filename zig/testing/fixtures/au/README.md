# AU fixtures: the AU contract

This is the canonical fixture contract for the
[AU contract](../../../../port.md#au-contract) (TODO.md T12a, T22a): Sun AU with
the PCM encodings of FFmpeg's AU table, known length, and unknown length behind
an option. Every rule has at least one
named fixture here with its expected result. The parser and writer (T12b), the
probe dispatch (T12c) and the reference comparison (T19a) test against these
files. The WAV contract and its shared conventions are in
[../README.md](../README.md).

## Files and commands

| Path | Role |
| --- | --- |
| `../generate.py` | Builds every AU fixture byte by byte with the Python standard library, and writes this directory's files. |
| `<name>.au` | The fixture files. |
| `manifest.zon` | Expected results, imported by `zig/testing/fixtures.zig` as `fixtures.au.all`. |
| `README.md` | This contract; the table at the end is generated. |

Change fixtures only in `generate.py`, then run
`python3 zig/testing/fixtures/generate.py`; `--check` fails when any output is
stale.

## Header and data

All header fields are big-endian `u32` values.

| Offset | Field | Rule |
| ---: | --- | --- |
| 0 | magic | `.snd`; anything else is `InvalidAu`. |
| 4 | data offset | At least 24, else `InvalidAu`. The `offset − 24` annotation bytes may be at most 1 MiB (1,048,576), else `LimitExceeded`; the limit is configurable. |
| 8 | data size | `0xffffffff` (unknown length) is `UnsupportedStreamingSize`, unless the parser's `unknown_length` option (T22a) reads the data to the end of the input, which must end on a whole frame (`Truncated` otherwise). Above `0x7fffffff` is `LimitExceeded`, the range FFmpeg's signed read also accepts. 0 is an empty stream. It must hold whole frames (the encoding's sample width × channels bytes), else `InvalidFormat`. |
| 12 | encoding | Since T22a, the PCM encodings of `au.c`'s table (see below); any other value is `UnsupportedFormat`, G.722 and G.726 (23 to 26) until T31c. |
| 16 | sample rate | 0 is `InvalidFormat`; above 192,000 Hz is `LimitExceeded` (configurable). |
| 20 | channels | 0 is `InvalidFormat`; more than 2 is `UnsupportedFormat`. |
| 24 | annotation | `offset − 24` bytes, skipped and ignored. Input ending inside them is `Truncated`. |
| offset | data | `data size` bytes of interleaved samples. Input ending inside them is `Truncated`; output is not atomic, so samples returned by earlier reads stay delivered. Bytes after the data are ignored and never read. |

## Encodings

| Encoding | FFmpeg codec | Bytes per sample | Decoded storage |
| ---: | --- | ---: | --- |
| 1 | `pcm_mulaw` | 1 | `s16` |
| 2 | `pcm_s8` | 1 | `u8`, offset by 128 |
| 3 | `pcm_s16be` | 2 | `s16` |
| 4 | `pcm_s24be` | 3 | `s32`, in the top 24 bits |
| 5 | `pcm_s32be` | 4 | `s32` |
| 6 | `pcm_f32be` | 4 | `flt` |
| 7 | `pcm_f64be` | 8 | `dbl` |
| 27 | `pcm_alaw` | 1 | `s16` |

## Expected results

- **accept**: the parser reports the stream's channels, rate and frame count,
  and decodes exactly the listed interleaved samples.
- **writer output**: the AU writer (T12b), given the accepted stream, must
  produce exactly the fixture's bytes.
- **reject**: the parser must fail with exactly the named error, by the
  precedence below.

## Writer

The writer emits one canonical known-length header: `.snd`, data offset 32,
the exact data size, the codec's encoding, the rate and the channel count, then
8 zero annotation bytes. These are the bytes FFmpeg's AU muxer writes for a seekable
output without metadata. The frame count is known up front: there is no
seeking and no placeholder size. The data size is checked before the header is
written; the largest stream is the largest whole number of frames within
`0x7fffffff` bytes. The rate limit applies to the writer too.

## Error precedence

1. The 24-byte header is read whole first, so input shorter than 24 bytes is
   `Truncated` whatever it contains.
2. The header fields are then checked in file order, and the first failing
   check wins: magic; data offset (below 24, then the annotation limit); data
   size (unknown, then the limit); encoding; sample rate (zero, then the
   limit); channels (zero, then the count).
3. The data size is then checked for whole frames, which needs the encoding
   and the channels (unless its length is unknown).
4. The annotation is skipped (`Truncated` if input ends there), then the data
   is read (`Truncated` if input ends there).

`au_limit_before_unsupported` and `au_unsupported_before_invalid` pin the field
order.

## Content detection

`zffprobe` and `av.detect` (T12c) choose the container from content, not the
file name. They read at most the first 4 bytes: `.snd` selects this contract's
parser, and anything else, including input shorter than 4 bytes, goes to the
WAV parser, whose results are those of the [WAV contract](../README.md). The
bytes read are handed to the chosen parser, so a pipe loses nothing. Two
fixtures therefore report differently through detection than to the AU parser
alone:

| Fixture | AU parser | Through detection |
| --- | --- | --- |
| `au_bad_magic` | `InvalidAu` | `InvalidRiff`: not AU by content, so the WAV parser reports it. |
| `au_empty_data` | accepted | accepted: the magic alone selects AU, while FFmpeg's content probe does not detect it. |

Every other fixture gives the same result both ways.

## Decisions

FFmpeg's behavior is from `libavformat/au.c` and `pcm.c` at the pinned
revision. Its demuxer reads packets until the end of input whatever the data
size says, so several rules here are deliberately stricter.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Data offset below 24 | `InvalidAu` (`au_offset_too_small`). | Ignores it and reads data from byte 24. |
| Annotation | Skipped and ignored, at most 1 MiB (`au_annotation_text`, `au_annotation_over_limit`). The data offset needs no alignment (`au_annotation_odd_length`). | Parses `title`, `artist`, `album`, `track` and `genre` into metadata; no limit. |
| Data size `0xffffffff` | `UnsupportedStreamingSize` by default; with `unknown_length` (T22a) the rest of the input, in whole frames, with no frame count (`au_unknown_size`, `au_unknown_size_mulaw`, `au_unknown_size_partial_frame`). Opt-in for the same reason as WAV's: it gives up the length check. | Reads to the end of input, keeping a partial frame's whole samples. |
| Data size from `0x80000000` | `LimitExceeded` (`au_data_size_over_limit`). | Rejects it as a negative size. |
| Data size 0 | An empty stream (`au_empty_data`). | Its content probe needs every header field to be nonzero, so it does not detect the file; with `-f au` it reads it. Parser acceptance and detection are recorded separately. |
| Bytes after the data | Ignored, never read (`au_trailing_bytes_after_data`). | Decodes them as samples. |
| Input shorter than the data size | `Truncated` (`au_truncated_data`, `au_truncated_mid_sample`). | Decodes what is present. |
| Data size not a whole number of frames | `InvalidFormat` (`au_data_not_block_aligned`). | Reads it; the duration rounds down. |
| Sample rate above 192 kHz | `LimitExceeded` (`au_rate_over_limit`). | Accepts any rate up to `INT_MAX`. |
| More than 2 channels | `UnsupportedFormat` (`au_channels3`). | Accepts them. |
| Encodings | Since T22a every PCM encoding of `au.c`'s table, read and written (`au_mulaw_mono_8k`, `au_s8_mono_8k`, `au_s24_stereo`, `au_s32_mono`, `au_f32_mono`, `au_f64_stereo_96k`, `au_alaw_mono_8k`); whole frames follow the encoding's width (`au_s24_data_not_block_aligned`). G.722 and G.726 (`au_encoding_g726`) and unknown numbers (`au_encoding_unknown`) are `UnsupportedFormat`. µ-law's negative zero is left out of writer output, as for WAV. | The same PCM encodings; G.72x needs decoders this reference build lacks. |
| Writer header | 32 bytes with the known data size and the codec's encoding. | The same 32 bytes for every encoding (its `-bitexact` copy of each writer-output fixture is identical); it writes `0xffffffff` and patches the size when the output is seekable, and puts title, artist, album, track and genre tags in the annotation. |

## Provenance

`../generate.py` is an original project file (`LGPL-2.1-or-later`). The
fixture files and `manifest.zon` are data it generates; their sample values
are the WAV fixtures' hand-picked values. No FFmpeg sample files or code were
used. FFmpeg's `au.c` and `pcm.c` were read only to record the behavior
differences above.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `au_mono_8k` | accepted | 48 | accept: mono, 8000 Hz, 8 frames; writer output | Canonical writer output: 24-byte header, 8 zero annotation bytes, encoding 3, 8 kHz mono. | `b3ee2a6ef998ac87910e2d7210cea80afd062854036c8de03d8758c1b29e9613` |
| `au_stereo_44k1` | accepted | 48 | accept: stereo, 44100 Hz, 4 frames; writer output | Canonical stereo at 44.1 kHz; samples interleave left/right. | `4d9aac23caa7b2c90f7fd34b10c3f526364082ca56ac2b051bcfe68be37863a9` |
| `au_mono_192k_rate_limit` | accepted | 40 | accept: mono, 192000 Hz, 4 frames; writer output | Sample rate exactly at the 192,000 Hz limit. | `ad4207ff73ca69e7022590635223c426659be36ad944989ca12d31cff1985de9` |
| `au_empty_data` | accepted | 32 | accept: mono, 8000 Hz, 0 frames; writer output | Data size 0 is an empty stream. FFmpeg's content probe needs a nonzero data size, so it does not detect this file; forced with `-f au` it reads it. | `a5ccce11ea71cf99c1208dbf91803d697089d578ebe81bf2f75322d4eee3d4b6` |
| `au_header_24` | accepted | 32 | accept: mono, 8000 Hz, 4 frames | Data offset 24: the minimal header, with no annotation. | `eee93e7eab7ca84a60bd3229d360bb18b96a31703975158ad5b0f8acf2610320` |
| `au_annotation_text` | accepted | 48 | accept: mono, 8000 Hz, 4 frames | A 16-byte text annotation (offset 40) is skipped and ignored; FFmpeg reads it as metadata. | `507cad839041cb6e89c0634397e5f21a72327333698e5320cee3847726b8b5e5` |
| `au_annotation_odd_length` | accepted | 37 | accept: mono, 8000 Hz, 4 frames | A 5-byte annotation (offset 29): the data offset needs no alignment. | `4668188d2dd6f9b9f85887127b1b1b5b9fc61ce0c4ed75fbf446ac1259a0f1af` |
| `au_one_frame_stereo` | accepted | 36 | accept: stereo, 48000 Hz, 1 frame | One stereo frame holding both extrema, at 48 kHz. | `d01ae75ee5ef3930ca36688412574880602526762f63dc0c41b38cf3ccdef036` |
| `au_trailing_bytes_after_data` | accepted | 44 | accept: mono, 8000 Hz, 4 frames | Two samples after the declared data are ignored and never read. FFmpeg decodes them. | `b4e976b7566605ad19c4bbb12838a173166d879eac091cc93292efca0120ce1e` |
| `au_mulaw_mono_8k` | encodings | 40 | accept: mono, 8000 Hz, 8 frames, `pcm_mulaw`; writer output | Encoding 1, µ-law; decodes to s16. Its negative zero (0x7F) is left out, as for WAV: every encoder writes zero as 0xFF. | `7a5b3f3ef1e39fd574ec28298181dd055a7ab91c5fd7da8bc034b0b185c7c01d` |
| `au_s8_mono_8k` | encodings | 40 | accept: mono, 8000 Hz, 8 frames, `pcm_s8`; writer output | Encoding 2, signed 8-bit; stored as u8, offset by 128, as FFmpeg's decoder does. | `14c11860cdf9057aa9587e1a1e49cb1a5fc255101242bb726ed7b667237ba2d8` |
| `au_s24_stereo` | encodings | 56 | accept: stereo, 8000 Hz, 4 frames, `pcm_s24be`; writer output | Encoding 4, 24-bit big-endian; stored as s32 in the top 24 bits. | `cfffd626c931fa472fd3e7f2e12a6b88b37d31907a016d21b5efb4be255a564d` |
| `au_s32_mono` | encodings | 64 | accept: mono, 8000 Hz, 8 frames, `pcm_s32be`; writer output | Encoding 5, 32-bit big-endian. | `c55bdfff5b96f5c27a61ad7d67ff0bcd18d3ae530cdfa06b2c2c7d7d80c2a01f` |
| `au_f32_mono` | encodings | 64 | accept: mono, 8000 Hz, 8 frames, `pcm_f32be`; writer output | Encoding 6, 32-bit float; every bit kept, NaN payload included. | `c79883f0a8c93e0a38f122ba73b82c6d5acea64113f016af91b8a4d3e50c2264` |
| `au_f64_stereo_96k` | encodings | 96 | accept: stereo, 96000 Hz, 4 frames, `pcm_f64be`; writer output | Encoding 7, 64-bit float, at 96 kHz. | `c41010d664f522d968190a589f20af0c6e83d71c809f7fb5b95b786dbb8540ce` |
| `au_alaw_mono_8k` | encodings | 40 | accept: mono, 8000 Hz, 8 frames, `pcm_alaw`; writer output | Encoding 27, A-law; decodes to s16. | `2b41318fcffacc0e3e0a53a0667e9a59ded8d429098ca188f77dccd5f26cc74e` |
| `au_empty_input` | header | 0 | reject: `Truncated` | Zero-byte input. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `au_truncated_header` | header | 20 | reject: `Truncated` | Input ends inside the 24-byte header. | `cd16e50772d175ca42b4dd5bd4302c42f9ff2e8fda801c855758afc315ece3dd` |
| `au_bad_magic` | header | 48 | reject: `InvalidAu` | Magic `.sne` instead of `.snd`. | `b9613aad46845b44797f3a9d025ac8acd91a0df48932989784dd549b2a6285c5` |
| `au_offset_too_small` | header | 32 | reject: `InvalidAu` | Data offset 16 is below the 24-byte header. FFmpeg ignores it and reads data from byte 24. | `bdec00c6a12cbad3a8d77f8a7724462fe9612ec5baad08badd6bd7dbc5be415e` |
| `au_annotation_over_limit` | limits | 32 | reject: `LimitExceeded` | Data offset 1048601 declares one byte more than the 1,048,576-byte annotation limit; rejected from the header, before any annotation is read. | `b04c7cba1da7b7414a3c3be2b927d0cf74a465297b6692568e616ac14bbcc46b` |
| `au_truncated_annotation` | header | 32 | reject: `Truncated` | Data offset 40, but input ends after 8 annotation bytes. | `d72ebc3f0582392e7fdbadbfeaf3013b0f707883a6a78619534603c58f26f7b9` |
| `au_unknown_size` | size | 40 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: mono, 8000 Hz, 4 frames | Data size 0xffffffff, unknown length, as FFmpeg's muxer writes to a pipe: with `unknown_length` the data is the rest of the input (T22a). | `0b7436b2373ec60c00ddf1e07a688a2e8052bbaee103cc5ce690c2331fedd9bb` |
| `au_unknown_size_mulaw` | size | 35 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: mono, 8000 Hz, 3 frames, `pcm_mulaw` | Unknown length with 3 µ-law frames: any byte count is whole frames. | `7f82a277b90e5afaf516bd4644782e7fbf9c9be729a015470a10227ff93939af` |
| `au_unknown_size_partial_frame` | size | 38 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `Truncated` | Unknown length, stereo, ending after 1.5 frames. | `713b7d52707bb6e2c462cc7e5783d322eef4d90a4aec1497f67eba3022c2c15d` |
| `au_data_size_over_limit` | limits | 40 | reject: `LimitExceeded` | Data size 0x80000000 is above the 0x7fffffff limit that FFmpeg's signed read also enforces. | `4b07c61fdf4c62f0b57493abb28bf54b1bcf8373cb2c19a66d12540a96b4810e` |
| `au_data_not_block_aligned` | size | 38 | reject: `InvalidFormat` | Stereo data size 6 ends inside a frame. | `d36c573b63a8c4f95bb6ea9ec91090d7936c57293cc2a485375fdad9a9f8cdbc` |
| `au_s24_data_not_block_aligned` | size | 36 | reject: `InvalidFormat` | 24-bit mono data size 4: frames follow the encoding's width. | `9a9187a98f5ca69433217d2d52a16f75fd658faf47c58a53b248f9229e75fcf2` |
| `au_truncated_data` | size | 42 | reject: `Truncated` | Data size 16, but input ends after 10 data bytes. | `c9b4a2c5c68eb42d5e295dd8a916f7736273c4b2f1b9f5b0564c824ce72c7632` |
| `au_truncated_mid_sample` | size | 37 | reject: `Truncated` | Data size 8, but input ends inside the third sample. | `bc91cb8379d7a65bb05ee136e9378d85e76c0de31b0d74d7d1ce96b905de84ae` |
| `au_encoding_g726` | format | 36 | reject: `UnsupportedFormat` | Encoding 23 (4-bit G.726) waits for T31c. | `5150af0881e4c158eee09d3159a24253b5973fa802088160c398d8a8364ee1a6` |
| `au_encoding_unknown` | format | 36 | reject: `UnsupportedFormat` | Encoding 99 is not an AU encoding. | `c22a72e95b2dbda4e144be6a35e85072332302ea04cdc7878df8c0aabd4e4531` |
| `au_rate_zero` | format | 40 | reject: `InvalidFormat` | Sample rate 0. | `7bccf402af28a56ddde19e3ddc1c16d9c16042eb2b80edc4f2cad20bbc45d5a0` |
| `au_rate_over_limit` | limits | 40 | reject: `LimitExceeded` | Sample rate 192001, one above the limit. | `a95f07d4fd74824917682ec3928a27bee43f5100e020cde8cf01718dc0624ce5` |
| `au_channels_zero` | format | 40 | reject: `InvalidFormat` | Zero channels. | `19c5020adb16fa771c4766f27bede267b7b3f01f2f418d191717821284c7e4a1` |
| `au_channels3` | format | 44 | reject: `UnsupportedFormat` | Three channels: only mono and stereo are supported. | `fcce15a7e6b105a461c62ebda8bc70bddddaecf68b6a1a5cd56b87b36dc1d9d7` |
| `au_limit_before_unsupported` | precedence | 36 | reject: `LimitExceeded` | Data size over the limit and encoding 99: the data size field comes first. | `572bd49c00e6a74b04615d07f4f48b42cc7faa5644791c91f8407b1d4cf9b364` |
| `au_unsupported_before_invalid` | precedence | 36 | reject: `UnsupportedFormat` | Encoding 24 (G.722) and sample rate 0: the encoding field comes first. (Before T22a it used encoding 6, now supported.) | `4d9bf4b697802293982178987c44517b4b87cc67789892ab0672f8d54ccf96b2` |
<!-- END GENERATED FIXTURE TABLE -->
