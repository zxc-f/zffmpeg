# AU fixtures: the AU contract

This is the canonical fixture contract for the
[AU contract](../../../../port.md#au-contract) (TODO.md T12a): known-length Sun
AU with signed 16-bit big-endian PCM, encoding 3. Every rule has at least one
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
| 8 | data size | `0xffffffff` (unknown length) is `UnsupportedStreamingSize`; unknown-length AU waits for T22a. Above `0x7fffffff` is `LimitExceeded`, the range FFmpeg's signed read also accepts. 0 is an empty stream. It must hold whole frames (`2 × channels` bytes), else `InvalidFormat`. |
| 12 | encoding | 3 (signed 16-bit big-endian PCM) only; any other value is `UnsupportedFormat`. Other PCM encodings wait for T22a and G.722/G.726 for T31c. |
| 16 | sample rate | 0 is `InvalidFormat`; above 192,000 Hz is `LimitExceeded` (configurable). |
| 20 | channels | 0 is `InvalidFormat`; more than 2 is `UnsupportedFormat`. |
| 24 | annotation | `offset − 24` bytes, skipped and ignored. Input ending inside them is `Truncated`. |
| offset | data | `data size` bytes of interleaved samples. Input ending inside them is `Truncated`, reported after the complete frames before it were delivered. Bytes after the data are ignored and never read. |

## Expected results

- **accept**: the parser reports the stream's channels, rate and frame count,
  and decodes exactly the listed interleaved samples.
- **writer output**: the AU writer (T12b), given the accepted stream, must
  produce exactly the fixture's bytes.
- **reject**: the parser must fail with exactly the named error, by the
  precedence below.

## Writer

The writer emits one canonical known-length header: `.snd`, data offset 32,
the exact data size, encoding 3, the rate and the channel count, then 8 zero
annotation bytes. These are the bytes FFmpeg's AU muxer writes for a seekable
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
3. The data size is then checked for whole frames, which needs the channels.
4. The annotation is skipped (`Truncated` if input ends there), then the data
   is read (`Truncated` if input ends there).

`au_limit_before_unsupported` and `au_unsupported_before_invalid` pin the field
order.

## Decisions

FFmpeg's behavior is from `libavformat/au.c` and `pcm.c` at the pinned
revision. Its demuxer reads packets until the end of input whatever the data
size says, so several rules here are deliberately stricter.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Data offset below 24 | `InvalidAu` (`au_offset_too_small`). | Ignores it and reads data from byte 24. |
| Annotation | Skipped and ignored, at most 1 MiB (`au_annotation_text`, `au_annotation_over_limit`). The data offset needs no alignment (`au_annotation_odd_length`). | Parses `title`, `artist`, `album`, `track` and `genre` into metadata; no limit. |
| Data size `0xffffffff` | `UnsupportedStreamingSize` until T22a (`au_unknown_size`). | Reads to the end of input. |
| Data size from `0x80000000` | `LimitExceeded` (`au_data_size_over_limit`). | Rejects it as a negative size. |
| Data size 0 | An empty stream (`au_empty_data`). | Its content probe needs every header field to be nonzero, so it does not detect the file; with `-f au` it reads it. Parser acceptance and detection are recorded separately. |
| Bytes after the data | Ignored, never read (`au_trailing_bytes_after_data`). | Decodes them as samples. |
| Input shorter than the data size | `Truncated` (`au_truncated_data`, `au_truncated_mid_sample`). | Decodes what is present. |
| Data size not a whole number of frames | `InvalidFormat` (`au_data_not_block_aligned`). | Reads it; the duration rounds down. |
| Sample rate above 192 kHz | `LimitExceeded` (`au_rate_over_limit`). | Accepts any rate up to `INT_MAX`. |
| More than 2 channels | `UnsupportedFormat` (`au_channels3`). | Accepts them. |
| Other encodings | `UnsupportedFormat` (`au_encoding_mulaw`, `au_encoding_g726`, `au_encoding_unknown`). | Decodes µ-law, s8, s24/s32 big-endian, float, A-law and G.72x; this reference build lacks those decoders. |
| Writer header | 32 bytes with the known data size. | The same 32 bytes; it writes `0xffffffff` and patches the size when the output is seekable. |

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
| `au_empty_input` | header | 0 | reject: `Truncated` | Zero-byte input. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `au_truncated_header` | header | 20 | reject: `Truncated` | Input ends inside the 24-byte header. | `cd16e50772d175ca42b4dd5bd4302c42f9ff2e8fda801c855758afc315ece3dd` |
| `au_bad_magic` | header | 48 | reject: `InvalidAu` | Magic `.sne` instead of `.snd`. | `b9613aad46845b44797f3a9d025ac8acd91a0df48932989784dd549b2a6285c5` |
| `au_offset_too_small` | header | 32 | reject: `InvalidAu` | Data offset 16 is below the 24-byte header. FFmpeg ignores it and reads data from byte 24. | `bdec00c6a12cbad3a8d77f8a7724462fe9612ec5baad08badd6bd7dbc5be415e` |
| `au_annotation_over_limit` | limits | 32 | reject: `LimitExceeded` | Data offset 1048601 declares one byte more than the 1,048,576-byte annotation limit; rejected from the header, before any annotation is read. | `b04c7cba1da7b7414a3c3be2b927d0cf74a465297b6692568e616ac14bbcc46b` |
| `au_truncated_annotation` | header | 32 | reject: `Truncated` | Data offset 40, but input ends after 8 annotation bytes. | `d72ebc3f0582392e7fdbadbfeaf3013b0f707883a6a78619534603c58f26f7b9` |
| `au_unknown_size` | size | 40 | reject: `UnsupportedStreamingSize` | Data size 0xffffffff (unknown length) is deferred to T22a. FFmpeg reads to the end of input. | `0b7436b2373ec60c00ddf1e07a688a2e8052bbaee103cc5ce690c2331fedd9bb` |
| `au_data_size_over_limit` | limits | 40 | reject: `LimitExceeded` | Data size 0x80000000 is above the 0x7fffffff limit that FFmpeg's signed read also enforces. | `4b07c61fdf4c62f0b57493abb28bf54b1bcf8373cb2c19a66d12540a96b4810e` |
| `au_data_not_block_aligned` | size | 38 | reject: `InvalidFormat` | Stereo data size 6 ends inside a frame. | `d36c573b63a8c4f95bb6ea9ec91090d7936c57293cc2a485375fdad9a9f8cdbc` |
| `au_truncated_data` | size | 42 | reject: `Truncated` | Data size 16, but input ends after 10 data bytes. | `c9b4a2c5c68eb42d5e295dd8a916f7736273c4b2f1b9f5b0564c824ce72c7632` |
| `au_truncated_mid_sample` | size | 37 | reject: `Truncated` | Data size 8, but input ends inside the third sample. | `bc91cb8379d7a65bb05ee136e9378d85e76c0de31b0d74d7d1ce96b905de84ae` |
| `au_encoding_mulaw` | format | 36 | reject: `UnsupportedFormat` | Encoding 1 (µ-law) waits for T22a. | `af6ca075730bf6240cfd9c273690937be225a66eb37c9a76bcd4ec7958bf6cc7` |
| `au_encoding_g726` | format | 36 | reject: `UnsupportedFormat` | Encoding 23 (4-bit G.726) waits for T31c. | `5150af0881e4c158eee09d3159a24253b5973fa802088160c398d8a8364ee1a6` |
| `au_encoding_unknown` | format | 36 | reject: `UnsupportedFormat` | Encoding 99 is not an AU encoding. | `c22a72e95b2dbda4e144be6a35e85072332302ea04cdc7878df8c0aabd4e4531` |
| `au_rate_zero` | format | 40 | reject: `InvalidFormat` | Sample rate 0. | `7bccf402af28a56ddde19e3ddc1c16d9c16042eb2b80edc4f2cad20bbc45d5a0` |
| `au_rate_over_limit` | limits | 40 | reject: `LimitExceeded` | Sample rate 192001, one above the limit. | `a95f07d4fd74824917682ec3928a27bee43f5100e020cde8cf01718dc0624ce5` |
| `au_channels_zero` | format | 40 | reject: `InvalidFormat` | Zero channels. | `19c5020adb16fa771c4766f27bede267b7b3f01f2f418d191717821284c7e4a1` |
| `au_channels3` | format | 44 | reject: `UnsupportedFormat` | Three channels: only mono and stereo are supported. | `fcce15a7e6b105a461c62ebda8bc70bddddaecf68b6a1a5cd56b87b36dc1d9d7` |
| `au_limit_before_unsupported` | precedence | 36 | reject: `LimitExceeded` | Data size over the limit and encoding 1: the data size field comes first. | `90e4f406442c886e93f1851520b3a7f8c42bf1757ca797c1d5a27e1fce743fbb` |
| `au_unsupported_before_invalid` | precedence | 36 | reject: `UnsupportedFormat` | Encoding 6 (float) and sample rate 0: the encoding field comes first. | `e2bada3e885119c15da31a055e46ea458f07ebc986bb561456b27a388d7df09b` |
<!-- END GENERATED FIXTURE TABLE -->
