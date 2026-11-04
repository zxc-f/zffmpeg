# AIFF fixtures: the AIFF contract

This is the canonical fixture contract for the
[AIFF contract](../../../../port.md#aiff-contract) (TODO.md T22b): AIFF and
AIFF-C with the PCM encodings of FFmpeg's AIFF table, known length. Every rule
has at least one named fixture here with its expected result. `av.aiff`, the
content detection and the reference comparison test against these files. The
WAV contract and its shared conventions are in [../README.md](../README.md).

## Files and commands

| Path | Role |
| --- | --- |
| `../generate.py` | Builds every AIFF fixture byte by byte with the Python standard library, and writes this directory's files. |
| `<name>.aiff` | The fixture files. |
| `manifest.zon` | Expected results, imported by `zig/testing/fixtures.zig` as `fixtures.aiff.all`. |
| `README.md` | This contract; the table at the end is generated. |

Change fixtures only in `generate.py`, then run
`python3 zig/testing/fixtures/generate.py`; `--check` fails when any output is
stale.

## Structure

Every field is big-endian. A file is one `FORM` chunk: `FORM`, a `u32` size
(the bytes after it), then the form type `AIFF` or `AIFC` and the chunks. Each
chunk is a 4-byte ID, a `u32` size and the body, followed by one pad byte when
the size is odd. The parser reads sequentially and never seeks, so it works on
pipes.

| Chunk | Rule |
| --- | --- |
| `FORM` header | `FORM`, else `InvalidAiff`. A size below 4 is `InvalidAiff`. Form type `AIFF` or `AIFC`, else `InvalidAiff`. The declared size bounds every chunk: a chunk that does not fit is `InvalidAiff`, and bytes after the extent are never read. |
| `FVER` | Its first 4 bytes are the AIFF-C version (an `FVER` of fewer bytes is skipped like any other chunk). A `FORM AIFC` file starts as version 1 (`0xA2805140`), as FFmpeg's reader does, and `FVER` replaces it. |
| `COMM` | Required before `SSND`, once (`InvalidAiff` otherwise). Fields: channels `u16`, frames `u32`, sample size `u16`, the sample rate as an 80-bit extended float, then in AIFF-C a compression type and a Pascal-string name. A size below 18 is `InvalidFormat`. Channels 0 is `InvalidFormat`, above 64 (the configurable `Limits.max_channels`, libswresample's limit, as for WAV and AU) `LimitExceeded`; since T23b any count up to it is read. A count other than an earlier `CHAN` chunk's is `InvalidFormat`, as in FFmpeg (`aiff_chan_before_comm_mismatch`). |
| `SSND` | A data offset `u32` and a block size `u32` (ignored), the `offset` bytes skipped, then the samples to the end of the chunk. A size below 8, or an offset past the chunk's end, is `InvalidAiff`. The samples must be whole frames (`InvalidFormat`), exactly as many as `COMM` declares (`InvalidFormat`). |
| `CHAN` | Since T23b, before `SSND`, Apple's channel layout (FFmpeg's `ff_mov_read_chan`, [mov_chan.zig](../../../format/mov_chan.zig), checked on [chan.txt](../../vectors/chan.txt)): a layout tag, a bitmap and a count of 20-byte channel descriptions. A tag FFmpeg's table names gives its channels (`aiff_chan_5point1`, the tag MPEG_5_1_A, is 5.1(side)), the bitmap tag the bitmap's channels below bit 18 (`aiff_chan_bitmap`), the description tag one channel per description's label, in order (`aiff_chan_descriptions`, a custom layout); the list is put in FFmpeg's canonical order. A tag or bitmap whose channel count is not the stream's is ignored (`aiff_chan_count_mismatch`); before `COMM` it gives the count, which `COMM` must repeat (`aiff_chan_before_comm`). Fewer than 12 bytes (`aiff_chan_short`), fewer descriptions than channels (`aiff_chan_too_few_descriptions`) and more descriptions than the chunk holds (`aiff_chan_descriptions_overflow`) are `InvalidFormat`. After `SSND` it is skipped like any other chunk (`aiff_chan_after_ssnd`). Without `CHAN` the layout is unspecified, which zffprobe prints as `unknown`. |
| Others | Skipped with their pad byte, before or after `SSND`; after `SSND` a second `COMM` or `SSND` is `InvalidAiff`. At most 4096 chunk headers (`LimitExceeded`, configurable). |

### Sample rate

The 80-bit rate converts as FFmpeg's `get_aiff_header` does: with `e` the
15-bit exponent field minus 16383 + 63, an `e` outside −63..63 is
`InvalidFormat`; otherwise the 64-bit mantissa is shifted left by `e`, or right
by `−e` after adding half of the last shifted-out place, so fractions round
half up (`aiff_rate_fraction`). A rate of 0 is `InvalidFormat`; above 192,000
Hz (configurable) is `LimitExceeded`, which also covers rates too large for
FFmpeg's `int`.

## Encodings

The codec comes from the compression type when the file is AIFF-C version 1
and `COMM` has room for a type (at least 22 bytes); otherwise from the sample
size. Types compare case-insensitively, as FFmpeg's `ff_codec_get_id` falls
back to.

| Compression type | FFmpeg codec | Bytes per sample | Decoded storage |
| --- | --- | ---: | --- |
| none (plain AIFF), `NONE` or `twos` with sample size 8 | `pcm_s8` | 1 | `u8`, offset by 128 |
| the same, sample size 16 | `pcm_s16be` | 2 | `s16` |
| the same, sample size 24 | `pcm_s24be` | 3 | `s32`, in the top 24 bits |
| the same, sample size 32 | `pcm_s32be` | 4 | `s32` |
| `raw ` | `pcm_u8` | 1 | `u8` |
| `sowt` | `pcm_s16le` | 2 | `s16` |
| `fl32` | `pcm_f32be` | 4 | `flt` |
| `fl64` | `pcm_f64be` | 8 | `dbl` |
| `alaw` | `pcm_alaw` | 1 | `s16` |
| `ulaw` | `pcm_mulaw` | 1 | `s16` |
| `in24` | `pcm_s24be` | 3 | `s32` |
| `in32` | `pcm_s32be` | 4 | `s32` |

Other sample sizes are `UnsupportedFormat`; so is every other compression type,
such as `ima4` or `MAC3`.

## Expected results

- **accept**: the parser reports the stream's channels, rate and frame count,
  and decodes exactly the listed interleaved samples.
- **writer output**: the AIFF writer, given the accepted stream, must produce
  exactly the fixture's bytes.
- **reject**: the parser must fail with exactly the named error, by the
  precedence below.

## Writer

The writer emits the header FFmpeg's AIFF muxer writes on seekable output
without metadata, with exact sizes known up front: no seeking and no
placeholder sizes. For `pcm_s8`, `pcm_s16be`, `pcm_s24be` and `pcm_s32be`
(type `NONE`) it is plain AIFF: `FORM`, `AIFF`, an 18-byte `COMM`, then
`SSND` with offset and block size 0. For the other encodings it is AIFF-C:
`FORM`, `AIFC`, `FVER` version 1, a 24-byte `COMM` ending in the compression
type and an empty name, then `SSND`. For a native layout of more than two
channels a 12-byte `CHAN` follows `COMM`, as FFmpeg's `ff_mov_write_chan`
writes it: the first layout tag its table pairs with the mask, else the
bitmap tag and the mask's low 32 bits (`aiff_chan_5point1`,
`aiff_chan_bitmap`); other layouts get none (`aiff_channels6`). The rate is the integer's exact 80-bit
form. Odd data gets a pad byte, counted in the `FORM` size but not in the
`SSND` size. The frame count and the `FORM` size must fit in 32 bits, and the
rate and channel limits apply, before anything is written.

## Error precedence

1. The 12-byte `FORM` header is read whole first, so shorter input is
   `Truncated`; then its fields in order.
2. Chunks are read in file order. Each chunk header must fit in the extent
   (`InvalidAiff`), then counts toward the chunk limit; each body must fit in
   the extent (`InvalidAiff`). Input ending inside any of them is `Truncated`.
3. `COMM`: duplicate (`InvalidAiff`), then a size below 18 (`InvalidFormat`),
   then the extent, then channels (zero, the limit, then an earlier `CHAN`'s
   count), sample rate and codec, in that order. `CHAN`: the extent, a size
   below 12, the description count against the size and then the channels,
   then the descriptions (`Truncated` if input ends there).
4. `SSND`: no `COMM` yet, then a size below 8, then the extent (all
   `InvalidAiff`), then the offset, then whole frames, then the frame count.
5. The samples, then every chunk after `SSND` up to the end of the extent.

## Content detection

`zffprobe`, `zffmpeg` and `av.detect` choose AIFF when the input starts with
`FORM`, a size of at least 4 and `AIFF` or `AIFC` (FFmpeg's `aiff_probe`). A
stream no demuxer recognizes is `UnknownFormat`; `-f aiff` forces this
contract's parser, as `ffprobe -f aiff` does. Each fixture's `detected` field in
`manifest.zon` records FFmpeg's winner, which `compare.py` checks against FFmpeg
itself. `aiff_empty_input`, `aiff_truncated_header`, `aiff_not_form`,
`aiff_bad_form_type` and `aiff_form_size_small` are not detected; with `-f
aiff` they give the errors in the table.

## Decisions

FFmpeg's behavior is from `libavformat/aiffdec.c`, `aiffenc.c` and `aiff.c` at
the pinned revision.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| `SSND` before `COMM` | `InvalidAiff` (`aiff_ssnd_before_comm`): a sequential reader cannot know the format. | Reads it from a seekable file by seeking back; fails on a pipe. |
| No `SSND`, or two `COMM` chunks | `InvalidAiff` (`aiff_missing_ssnd`, `aiff_duplicate_comm`). | Accepts both; without `SSND` it reports the frames `COMM` declares. |
| Frame count | `COMM` must declare exactly the frames in `SSND` (`aiff_frames_mismatch`). | Decodes the `SSND` bytes whatever `COMM` says. |
| Data not whole frames | `InvalidFormat` (`aiff_data_not_block_aligned`). | Decodes the whole samples. |
| Offset past the chunk, short `SSND`, chunk beyond the extent | `InvalidAiff` (`aiff_ssnd_offset_too_big`, `aiff_ssnd_short`, `aiff_chunk_exceeds_form`). | Rejects a short `SSND`; accepts the others and reads what it finds. |
| Sample size not 8, 16, 24 or 32 | `UnsupportedFormat` (`aiff_bits12`). | Rounds up to the next of those. |
| Sample rate above 192 kHz | `LimitExceeded` (`aiff_rate_over_limit`). | Accepts any rate that fits in an `int`; larger values are truncated to one. |
| Channels | Since T23b 1 to 64 (`aiff_channels3`, `aiff_channels6`, `aiff_channels64`); more is `LimitExceeded` (`aiff_channels65`). | Accepts more. |
| `CHAN` after `SSND` | Skipped (`aiff_chan_after_ssnd`): a sequential reader has reported the stream by then. | Reads it from a seekable file, which `compare.py` records as a known difference (`quad` here). |
| `CHAN` too short for its descriptions | `InvalidFormat` (`aiff_chan_descriptions_overflow`). | Keeps the layout and reads on from the middle of the chunk, as if a chunk header started there. |
| `NAME`, `AUTH`, `(c) `, `ANNO`, `ID3 ` | Skipped (`aiff_other_chunks`); AIFF tags are not read or written. | Reads them as title, author, copyright, comment and ID3 tags, and writes the first four. |
| Unknown length | Not supported: a `FORM` size below 4 is `InvalidAiff`, and not detected. | Writes zero sizes when its output is a pipe, and its own demuxer rejects that file the same way (`FORM` size 0). |

| Compressed AIFF-C (`ima4`, `MAC3`, `GSM `, `G722`, `QDM2`, ...) | `UnsupportedFormat` (`aifc_unknown_type`). | Decodes those it has decoders for. |
| Writer header | Plain AIFF for `NONE`, AIFF-C otherwise, as FFmpeg chooses. | The same bytes (its `-bitexact` copy of each writer-output fixture is identical). |

## Provenance

`../generate.py` is an original project file (`LGPL-2.1-or-later`). The
fixture files and `manifest.zon` are data it generates; their sample values
are the WAV and AU fixtures' hand-picked values. No FFmpeg sample files or code
were used. FFmpeg's `aiffdec.c`, `aiffenc.c` and `aiff.c` were read only to
record the behavior and differences above.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `aiff_mono_8k` | writer | 70 | accept: 1 channel, 8000 Hz, 8 frames; writer output | Plain AIFF, 16-bit mono: FORM, an 18-byte COMM, SSND. | `ded1e537d05d318f7214d26dd0b38e1c9b5fd96c2f7ae6cdca45a3a40ec9337e` |
| `aiff_stereo_44k1` | writer | 70 | accept: 2 channels, 44100 Hz, 4 frames; writer output | 16-bit stereo at 44.1 kHz. | `4f4ea11029dca6bcb0e1d30cb2c94624999e7017f61a54ef296b287b0ff3e8d0` |
| `aiff_s8_mono` | writer | 62 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s8`; writer output | 8-bit samples are signed in AIFF; stored as u8, offset by 128. | `6b2118eb6adcd22e04bec710a3e7423c91b7c5f75f6e0d2e8fdacb036a8e98ac` |
| `aiff_s24_stereo` | writer | 78 | accept: 2 channels, 48000 Hz, 4 frames, `pcm_s24be`; writer output | 24-bit stereo at 48 kHz; stored as s32. | `378224dc55db4bbe88201d03d17d402f5326125f172ea894aabd4fbfb0209514` |
| `aiff_s32_mono` | writer | 86 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s32be`; writer output | 32-bit mono. | `26feddbce85f42ff276b1f336b80bba5c9a87a63b393e2a75d897f4c72411cc1` |
| `aiff_empty` | writer | 54 | accept: 1 channel, 8000 Hz, 0 frames; writer output | No frames: SSND holds only its offset and block size. | `99018cf4d400c8bed27d73024cd70dfee229069df6273096d22d9c3bf70c8af5` |
| `aifc_u8_raw` | writer | 80 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_u8`; writer output | AIFF-C `raw `: unsigned 8-bit, with FVER and a 24-byte COMM. | `176dfeb1127436d9a932cb4b1c6d00bb4c21903506ced6a40f217b40ee722dbf` |
| `aifc_sowt` | writer | 88 | accept: 1 channel, 8000 Hz, 8 frames; writer output | AIFF-C `sowt`: 16-bit little-endian. | `b0877299011f01d47146875e32f94ec8e937a40125f5f4d56a98b37a7a8bbbfd` |
| `aifc_fl32` | writer | 104 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_f32be`; writer output | AIFF-C `fl32`: 32-bit float; every bit kept. | `68ea28ac56776e80a51127c75dd75a5508a639e9e5c36b2209c27f79bad12db0` |
| `aifc_fl64_stereo_96k` | writer | 136 | accept: 2 channels, 96000 Hz, 4 frames, `pcm_f64be`; writer output | AIFF-C `fl64` at 96 kHz. | `f01ca9a47094daf3f140d850da3aa09dca18964efbd3b282139c7e203f0dbc49` |
| `aifc_alaw` | writer | 80 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_alaw`; writer output | AIFF-C `alaw`, COMM sample size 8; decodes to s16. | `e544ab749ee4f3a1ea053e27f91fa6103d051502522bac54f8b7488e4ea5c0a9` |
| `aifc_ulaw` | writer | 80 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_mulaw`; writer output | AIFF-C `ulaw`; its negative zero (0x7F) is left out, as for WAV and AU. | `7ad36bd666b8cabfe468f8a0f9ec01174db88c87a5646936e09a3c92c15e2516` |
| `aifc_none_twos` | accepted | 84 | accept: 1 channel, 8000 Hz, 4 frames, `pcm_s24be` | AIFF-C `twos` with 24-bit samples: the codec follows the sample size. | `79d61e026d5e55e23e30ab0f039cb5b44df95780b79d4f324b0f41fc949346e2` |
| `aifc_uppercase_type` | accepted | 88 | accept: 1 channel, 8000 Hz, 4 frames, `pcm_f32be` | `FL32` matches `fl32`: types compare case-insensitively, as in FFmpeg. | `0d54c5efa7cbfcf0884e21a86267e2ec3e1585f7402d23e4ce9cb51943272e97` |
| `aifc_in24` | accepted | 84 | accept: 1 channel, 8000 Hz, 4 frames, `pcm_s24be` | AIFF-C `in24` is 24-bit big-endian, whatever the sample size says. | `1fba136be2b30f2f3f15fb0a11f2405a72a34c73b398adabac781bb35b2b518b` |
| `aifc_short_comm` | accepted | 62 | accept: 1 channel, 8000 Hz, 4 frames | AIFF-C with an 18-byte COMM, no room for a type: read as plain AIFF. | `4f8cfb9e464e4ec99c97a594f83e6b499c0730d4c1d71bd7d8f0d52fb6f64f03` |
| `aifc_without_fver_version` | accepted | 88 | accept: 1 channel, 8000 Hz, 4 frames, `pcm_s32be` | An FVER that is not version 1 makes COMM carry no type: its `fl32` is ignored and 32 bits read as s32. | `d5961fa5913a64e477d46cded10814d04bdb160287559182cc15bd966424e0cc` |
| `aiff_ssnd_offset` | accepted | 66 | accept: 1 channel, 8000 Hz, 4 frames | SSND with a data offset of 4: the 4 bytes before the samples are skipped. | `2e359b7b7c32a3803b05b4ff85003f486ce84ccd310e0e95d0aca16048aaa9ea` |
| `aiff_other_chunks` | accepted | 98 | accept: 1 channel, 8000 Hz, 4 frames | NAME, an odd-sized ANNO and a chunk after SSND are skipped with their pad bytes. | `3ee8da50c5db481fa2fd3e65f0bb94d3f51c20a0483c190509637af914330422` |
| `aiff_odd_data` | accepted | 58 | accept: 1 channel, 8000 Hz, 3 frames, `pcm_s8`; writer output | Three s8 frames: SSND is odd and a pad byte follows it. | `5621100abf22f1a838830ffdd7355817b8a2c35de3464cc71f6f745fe6d2fd26` |
| `aiff_rate_fraction` | accepted | 62 | accept: 1 channel, 8001 Hz, 4 frames | An 80-bit rate of 8000.5 Hz rounds half up to 8001, as FFmpeg's does. | `3ff54b8711fb9a8f5e7f90d2016af8b578c13f46d2f6a0a61c2f45d7f38e1fdd` |
| `aiff_empty_input` | header | 0 | reject: `Truncated`; not detected (probing picks no format) | No bytes at all. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `aiff_not_form` | header | 62 | reject: `InvalidAiff`; not detected (probing picks no format) | The file starts with `RIFF`, not `FORM`. | `616983ae8c9d932fb844b77043972f3e69b90e98a43f50cc17e39dbd4e5c09d1` |
| `aiff_bad_form_type` | header | 62 | reject: `InvalidAiff`; not detected (probing picks no format) | FORM type `WAVE`. | `379b22dc2cd0a3c343fcb4243defe834dbf9bafb379b15b013ee8dc9d39a4cb7` |
| `aiff_form_size_small` | header | 38 | reject: `InvalidAiff`; not detected (probing picks no format) | FORM size 2 cannot hold the form type. | `d3427c337b421fcef9f0e75dfc9a7b94ef03699b28c3157bcc80405b0be72cdc` |
| `aiff_truncated_header` | header | 10 | reject: `Truncated`; not detected (probing picks no format) | Input ends inside the 12-byte FORM header. | `0cbf5fc92f2bf895740653001b391e74ccea0080f7b053fa1de18b4785bb7113` |
| `aiff_missing_ssnd` | order | 38 | reject: `InvalidAiff` | COMM, but no SSND within the FORM extent. | `6adb9768af0aa17f81aa515040168a8d52391a27affcea2762c4877f304e9f31` |
| `aiff_ssnd_before_comm` | order | 62 | reject: `InvalidAiff` | SSND before COMM: a sequential reader cannot know the format. FFmpeg reads it from a seekable file. | `9f20df66b93b3eb091f39a02892c6ec8d08f8eec4b147e27fc6c7abe64bfbf4d` |
| `aiff_duplicate_comm` | order | 88 | reject: `InvalidAiff` | Two COMM chunks. | `f71f19d2c52bdad14748c81c1c464f0f6e380a3d422a63d79bf621d3e2494d89` |
| `aiff_comm_short` | comm | 60 | reject: `InvalidFormat` | A COMM chunk declaring 16 bytes. | `72398ebcb7d62b67e81ea82ad6b4e7364976c48b7a8d30cb8d2e39c0ee8f8b35` |
| `aiff_truncated_comm` | comm | 24 | reject: `Truncated` | Input ends inside COMM. | `d89f8e19ba3e918510a7743bb1af094c6f6e28797550792575e8894f8ef73836` |
| `aiff_channels0` | comm | 54 | reject: `InvalidFormat` | Zero channels. | `69941c534df543a1d5f71fe60aba3df0f5fb73a4fdebaede5d08e2ee7f376dc8` |
| `aiff_channels3` | channels | 66 | accept: 3 channels, 8000 Hz, 2 frames | Three channels without CHAN: unspecified (rejected before T23b). | `b04b869fda7694057d418ab47db8a3fc81205c9835a8370f3f76e5fb73ce999f` |
| `aiff_channels6` | channels | 78 | accept: 6 channels, 8000 Hz, 2 frames; writer output | Six channels without CHAN, written back the same way; FFmpeg's command line guesses 5.1 for them. | `adb12066341ed11af8b203f24b208d39d4ef0f9cda8f439ad7229dc0be8b07bd` |
| `aiff_channels64` | channels | 182 | accept: 64 channels, 8000 Hz, 1 frame | 64 channels, the default limit: one frame. | `9b383e44725338dc56d42685e876e7cc51023502443a76bd9312795018564d8e` |
| `aiff_channels65` | channels | 184 | reject: `LimitExceeded` | 65 channels, above the default limit (FFmpeg reads them). | `a81dbb63f2ebd4e5ed96f2985616ca45ae867ba35faa685437d7aa4578224382` |
| `aiff_chan_5point1` | channels | 98 | accept: 5.1(side) (6 channels), 8000 Hz, 2 frames; writer output | CHAN with the tag MPEG_5_1_A (L, R, C, LFE, Ls, Rs) after COMM: 5.1(side), as FFmpeg's muxer writes it. | `c1ad980af720b03baddb21202398a1f0ee060d9a78c5791f762f1c93b1b6ad6e` |
| `aiff_chan_bitmap` | channels | 120 | accept: 6.1 (7 channels), 8000 Hz, 2 frames; writer output | CHAN with a channel bitmap, 6.1, which no tag names, as FFmpeg's muxer writes it in AIFF-C `sowt`. | `8ef4162ef70726315e0ea12ec8edf857870b613c7c7ffd6b1f55435a5ff0df29` |
| `aiff_chan_descriptions` | channels | 146 | accept: 3 channels (FC+FL+FR) (3 channels), 8000 Hz, 2 frames | CHAN with channel descriptions C, L, R: a custom order, as FFmpeg reads it. | `53d75e2437ed662ce270a8ce85e3993e06503caaf347a293bbc1a494ecf5d892` |
| `aiff_chan_before_comm` | channels | 90 | accept: quad (4 channels), 8000 Hz, 2 frames | CHAN (the quadraphonic tag) before COMM: the tag's count must be COMM's, as FFmpeg checks. | `537be3a3a92cc08152b3a279bba5040f8831858717a48417a5bfab167297cac9` |
| `aiff_chan_count_mismatch` | channels | 90 | accept: 4 channels, 8000 Hz, 2 frames | CHAN with a six-channel tag on a four-channel stream is ignored, as FFmpeg ignores it. | `8b710d002310ed49a49d82c4c94014d111a54d30a6fea0767c1959b81ac135a6` |
| `aiff_chan_after_ssnd` | channels | 90 | accept: 4 channels, 8000 Hz, 2 frames | CHAN after SSND is not read: a sequential reader has reported the stream by then. FFmpeg reads it from a seekable file. | `56312a73bafae34a9a5a90598e5580575e2dc334f298062343888e28a745e214` |
| `aiff_chan_before_comm_mismatch` | channels | 82 | reject: `InvalidFormat` | CHAN (a four-channel tag) before a two-channel COMM: FFmpeg rejects it too. | `54399afb580a895bb89602375d6090c5be056a6c01ba05a0013c8d60ca44c6c6` |
| `aiff_chan_short` | channels | 78 | reject: `InvalidFormat` | A CHAN chunk of 8 bytes, short of the 12 fixed ones: FFmpeg rejects it too. | `eb32353bd197f69731473d7ee9b7a9c52fa3131a802191405fcf31a6f49f08d9` |
| `aiff_chan_too_few_descriptions` | channels | 102 | reject: `InvalidFormat` | One channel description for two channels: FFmpeg rejects it too. | `4201fda85da1127d18580d67dba1979b6a1a936610078fbf86b9ace1911ac18f` |
| `aiff_chan_descriptions_overflow` | channels | 102 | reject: `InvalidFormat` | CHAN declaring two descriptions in room for one. FFmpeg keeps the layout and reads on from the middle of the chunk. | `70b70b95a36f40e9b06dd382d760af7af6326e8264ea79e1da5f8403337622c6` |
| `aiff_rate_zero` | comm | 62 | reject: `InvalidFormat` | An 80-bit rate of 0. | `4fe9ac1db3fef971f44dbf81e3ae6f0a448e469b5da4999b3b5d4221a5cd66ff` |
| `aiff_rate_exponent` | comm | 62 | reject: `InvalidFormat` | An 80-bit rate whose exponent needs a shift beyond 63. | `912f24089bff7f3d73e6753ba972f9c50619ab2cc46868adb9d0bb3cf4829d5a` |
| `aiff_rate_over_limit` | comm | 62 | reject: `LimitExceeded` | Sample rate 192001 Hz, above the default limit. | `e36541dd0d80cef503f0c9fc650d9f2973cc93b07df79d892da8886dae5625a9` |
| `aiff_bits12` | comm | 62 | reject: `UnsupportedFormat` | 12-bit samples: whole bytes only. FFmpeg rounds them up to 16. | `8dda0890d5d05ae4676be9364bba4edc445f5352a4eb8d233132f36f9011dffe` |
| `aifc_unknown_type` | comm | 80 | reject: `UnsupportedFormat` | AIFF-C type `ima4` (IMA ADPCM) is not a contract encoding. | `eeb7bcdf142e3939e762ffa47ce160ff68bf0273e9ff1ebee730bcc622e23fd4` |
| `aiff_frames_mismatch` | sound | 62 | reject: `InvalidFormat` | COMM declares 5 frames, SSND holds 4. FFmpeg decodes the 4. | `43a36672bb8771cf3c158be6bc2643120ccfb039f4fa836623979753b7bdb6ca` |
| `aiff_data_not_block_aligned` | sound | 60 | reject: `InvalidFormat` | Stereo 16-bit data of 6 bytes. | `fd16347b75025b44da7b34b804d47412e82698836d77d3392c5572ea1649824e` |
| `aiff_ssnd_short` | sound | 74 | reject: `InvalidAiff` | An SSND declaring 4 bytes, less than its offset and block size. | `2b0399df0c562f245e8306469228db566e36c9b91bdd56a50e7325f9cfba6795` |
| `aiff_ssnd_offset_too_big` | sound | 62 | reject: `InvalidAiff` | A data offset past the end of SSND. | `d5aa191129b40714b410a2e3aa55f5ca8e8259395294b760b3850572b19a1b10` |
| `aiff_chunk_exceeds_form` | bounds | 62 | reject: `InvalidAiff` | SSND declares more bytes than the FORM extent has left. | `9004a7bf862e9812bdd32d93e9df641e7f9f0cc454ed07da0045e7920d65891e` |
| `aiff_truncated_data` | bounds | 59 | reject: `Truncated` | Input ends inside the samples. | `92c7bfbbdf0394aabac466768a9434d67f25c87f75a1f5ee891c6a3c73c280d8` |
<!-- END GENERATED FIXTURE TABLE -->
