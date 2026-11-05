# WAV fixtures: the first WAV contract

This is the canonical fixture contract for the
[first WAV contract](../../../port.md#first-wav-contract) (TODO.md T02). Every rule
there has at least one named fixture here with its expected result. The WAV
parser (T06), I/O adapters (T07), writer (T08) and end-to-end verification
(T10) test against these files. T21a widened the contract from 16-bit PCM to
every WAV PCM encoding and WAVE_FORMAT_EXTENSIBLE: `fmt_extensible`,
`fmt_float32` and `fmt_bits24` moved from rejected to accepted, and the
writer's header follows FFmpeg's choice.

## Files and commands

| Path | Role |
| --- | --- |
| [generate.py](generate.py) | Defines every fixture and builds its bytes with the Python standard library, independently of the Zig code. |
| `wav/<name>.wav` | The fixture files. Never edit them by hand. |
| [manifest.zon](manifest.zon) | Expected results and SHA-256 for each file, imported at compile time. |
| [../fixtures.zig](../fixtures.zig) | Loads the manifest, embeds every file, and checks each hash. |

From the repository root:

```bash
python3 zig/testing/fixtures/generate.py           # rewrite the files, manifest and the table below
python3 zig/testing/fixtures/generate.py --check   # fail if any output is missing or stale
zig build test                                     # includes the fixture integrity test
```

CI runs both checks. A missing fixture file fails the build, because
`fixtures.zig` embeds each one with `@embedFile`. A changed file fails its
SHA-256 test. A `.wav` file that `generate.py` does not produce fails
`--check`. To change a fixture, edit `generate.py` and rerun it; never edit the
outputs.

## Expected results

- **accept**: the stream is valid. The manifest gives the `codec` (FFmpeg's
  name), `channels`, `sample_rate` and the interleaved decoded `samples`,
  tagged by their storage format as FFmpeg's decoder stores them (`.u8`,
  `.s16`, `.s32` for 24- and 32-bit, `.s64`, and `.flt`/`.dbl` holding IEEE
  bit patterns); the frame count is `samples.len / channels`. Every accepted
  stream is `wav`, `mono` or `stereo`. Duration is `frames / sample_rate`,
  unreduced (see port.md "Initial probe output").
- **reject**: the contract error the parser must return. When the error is
  found after audio has been produced (for example `duplicate_data`), the
  frames before it may already have been delivered; callers must not assume
  atomic output.
- **writer output**: the writer, given the accepted codec, layout, rate and
  samples, must produce these bytes exactly: the RIFF header, the `fmt ` that
  FFmpeg's `riffenc.c` chooses (16-byte tag 1 for PCM, 18-byte with `cbSize`
  0 for float, A-law and mu-law, or a 40-byte WAVE_FORMAT_EXTENSIBLE for a
  named layout other than mono and stereo, above 48 kHz or above 16 bits
  unless float, with a native layout's channel mask when it uses only WAVE's
  first 18 positions, else 0, and the format tag's subformat GUID), a `fact` chunk with the frame count for every
  encoding but tag 1, then `data` (and a pad byte if its size is odd), with
  `byte_rate = rate * block_align`.

## Encodings (T21a)

| Format tag | Bits | Codec | Stored as |
| --- | --- | --- | --- |
| 1 (PCM) | 8 | `pcm_u8` | `u8` |
| 1 | 16 | `pcm_s16le` | `s16` |
| 1 | 24 | `pcm_s24le` | `s32`, shifted into the top 24 bits |
| 1 | 32 | `pcm_s32le` | `s32` |
| 1 | 64 | `pcm_s64le` | `s64` |
| 3 (IEEE float) | 32 | `pcm_f32le` | `flt` |
| 3 | 64 | `pcm_f64le` | `dbl` |
| 6 (A-law) | 8 | `pcm_alaw` | `s16` |
| 7 (mu-law) | 8 | `pcm_mulaw` | `s16` |
| 0xFFFE (extensible) | as above | the subformat's tag 1, 3, 6 or 7 | as above |

`block_align` must be `channels * bits / 8`. Any other tag or depth is
`UnsupportedFormat`.

## Decisions

T02 had to settle the contract's open boundary cases and some unclear wording.
FFmpeg's behavior is from `libavformat/wavdec.c` and `riffenc.c` at the pinned
revision. That demuxer ignores `riff_size` entirely and stops at end of input,
so most of the bounds rules here are stricter than FFmpeg's on purpose.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Final odd-sized chunk whose pad byte is missing at EOF | If `riff_size` excludes the pad byte, the pad lies outside the extent and is not read: accept (`odd_final_chunk_pad_outside_extent`). If `riff_size` counts it, the input is short: `Truncated` (`odd_final_chunk_pad_missing`). | Accepts both. |
| A chunk, including `data`, whose declared size runs past the RIFF extent | `InvalidRiff`, found from the chunk header before its body is read (`data_exceeds_riff_extent`, `chunk_exceeds_riff_extent`). | Reads `data` up to its declared end or EOF. |
| `riff_size` disagrees with the input length | Input longer than the extent: the extra bytes are ignored (`trailing_bytes_after_riff`). Input shorter: `Truncated` (`riff_size_exceeds_input`). A known input size may report this before any audio; otherwise it appears while reading. | Ignores `riff_size`. |
| Fewer than 8 bytes of extent left where a chunk header should start | `InvalidRiff` (`partial_chunk_header_in_extent`). | Stops at EOF. |
| `riff_size` sentinels | 0 and 0xFFFFFFFF are unknown sizes: `UnsupportedStreamingSize` by default (`riff_size_unknown`, `riff_size_zero`). 1 to 3 cannot hold the form type: `InvalidRiff`. | Ignores `riff_size`. |
| Unknown length (T21b) | Opt-in: the parser's `Limits.unknown_length`. Off, every unknown size is `UnsupportedStreamingSize`; the manifest's `unknown_length` field gives the result with it on, where it differs, and every other fixture must give its usual result either way. On, an unknown `riff_size` makes the extent the rest of the stream: it may end cleanly between chunks (`unknown_riff_chunk_after_data`), but not inside a header (`unknown_riff_partial_chunk_header`, `Truncated`) or before a pad byte (`unknown_riff_pad_missing`, `Truncated`), and ending before `data` is `InvalidWave` (`unknown_riff_missing_data`). A `data` size of 0xFFFFFFFF outside RF64 makes the data the rest of the stream (`unknown_length_pipe`, as FFmpeg writes to a pipe), with no frame count; it must end on a whole frame (`unknown_length_partial_frame`, `Truncated`), needs no pad byte (`unknown_length_odd_u8`), and nothing after it is read, so later chunks decode as samples and a known `riff_size` goes unchecked (`unknown_length_reads_past_chunks`). `data` size 0 stays an empty stream (`unknown_riff_empty_data`). RF64 sizes stay known. | Always reads unknown sizes to the end of the input, also a `data` size of 0; keeps a partial frame's whole samples. |
| RF64 and BW64 (T21b) | Accepted (`rf64`, `bw64`): the 32-bit RIFF size must be 0xFFFFFFFF (`rf64_riff_size_not_sentinel`), `ds64` must come first (`rf64_missing_ds64`) with at least 28 bytes (`rf64_ds64_short`) and no table of other chunks' sizes (`rf64_ds64_table`, `UnsupportedFormat`); its RIFF size bounds the extent, and its data size is used only when `data`'s own is 0xFFFFFFFF (`rf64_data_size_in_chunk`); the sample count is ignored like `fact`'s. | Ignores the 32-bit size and the table, accepts a 24-byte `ds64`, and reads `data` past the extent (`rf64_data_exceeds_extent`). |
| RF64 in the writer | `WriteOptions.rf64`: `.auto` (the default) writes RF64 exactly when the RIFF or `data` size would not fit in 32 bits, decided before the header since the length is known; `.always` writes it for any stream (`rf64`); `.never` makes such sizes `SizeOverflow`. The layout is FFmpeg's: `ds64` (28 bytes, no table) after `WAVE`, then the same `fmt ` and `fact` (0xFFFFFFFF when the count needs 64 bits), and `data` sized 0xFFFFFFFF. | `-rf64` defaults to `never`, which writes broken sizes past 4 GiB; `auto` needs seekable output. |
| `fmt ` declaring fewer than 16 bytes | `InvalidFormat`: a complete but malformed chunk (`fmt_size_14`). Input ending inside `fmt ` is `Truncated` (`fmt_truncated`). This is what the contract's "short fields are truncated" means. | Rejects. |
| `fmt ` sizes other than 16, or 18 with `cbSize == 0` (40 with `cbSize == 22` when extensible) | `UnsupportedFormat` (`fmt20_cbsize2`, `extensible_fmt18`, `extensible_cbsize_short`). | Accepts more variants and keeps the extra bytes as extradata. |
| Bit depths that are not whole bytes | `UnsupportedFormat` (`fmt_bits12`): tag 1 takes 8, 16, 24, 32 or 64 bits, float 32 or 64, A-law and mu-law 8. | Rounds up to the next byte (12 bits reads as `pcm_s16le`). |
| Extensible `wValidBitsPerSample` | 0 or equal to the container's bits (`extensible_valid_bits_zero`); anything else is `UnsupportedFormat` (`extensible_valid_bits_mismatch`). | Lets the valid bits override the container size. |
| Channels and layout (T23b) | 1 to 64 channels (the default `Limits.max_channels`, libswresample's limit; above it `LimitExceeded`: `fmt_channels64`, `fmt_channels65`). The layout is FFmpeg's: an extensible mask naming exactly the channels is a native layout (`extensible_5point1`, `extensible_7point1_s24`, `extensible_mask_high`, whose position 20 WAVE does not define); a mask of 0 or with another channel count, and every plain header, leave it unspecified (`extensible_mask_zero`, `extensible_mask_mismatch`, `extensible_mask_extra`, `fmt_channels3`, `fmt_channels6`), which zffprobe reports as `unknown`, as ffprobe does. Each accepted stream records the layout ffprobe prints. | The same, without a channel limit. |
| Extensible subformat | Tag 1, 3, 6 or 7 in a GUID of the three families FFmpeg reads as a format tag (`parse_waveformatex`): KSDATAFORMAT, ambisonic B-format and FFmpeg's "broken" shifted KSDATAFORMAT; another GUID or tag is `UnsupportedFormat` (`extensible_unknown_subformat`, `extensible_subformat_adpcm`; the other two families are unit tests in `wav.zig`). | Maps more GUIDs. |
| `fact` chunk | Skipped like any unknown chunk: the frame count comes from `data` (`fmt_float32` has none). | Uses it for the duration of non-PCM codecs. |
| Odd `data` size | Possible for 8-bit mono and odd frame counts of 24-bit; the pad byte inside the extent is skipped like a chunk's, and the writer writes it. | Same pad rule. |
| mu-law's negative zero (0x7F) | Decodes to 0 like 0xFF; the writer, like FFmpeg's encoder, writes 0 as 0xFF, so writer output never contains 0x7F. | Same. |
| Sample rate above 192,000 Hz | `LimitExceeded`, a configurable policy limit (`fmt_rate_over_limit`). | No such limit. |
| `data` size not a multiple of `block_align` | `InvalidFormat` (`data_not_block_aligned`). | Drops the partial frame. |
| Second `fmt ` | `InvalidWave` (`duplicate_fmt`). | Ignores it. |
| Inconsistent `byte_rate` | Accepted and ignored (`byte_rate_mismatch`). | Does not check it. |
| Sony Wave64 (T21b) | Accepted through the same parser, reported as the `w64` container: the `riff` GUID (another suffix is `InvalidRiff`, `w64_bad_riff_guid`), a 64-bit file size counting the whole file (below 40 is `InvalidRiff`, `w64_size_too_small`), the `wave` GUID (`w64_bad_wave_guid`, `InvalidWave`), then chunks of a 16-byte GUID and a 64-bit size that counts the 24-byte header (below 24 is `InvalidRiff`, `w64_chunk_size_below_header`), padded to 8 bytes. `fmt ` and `data` are the GUIDs `libavformat/w64.c` names; other GUIDs are skipped (`w64_unknown_chunks`). Everything else, the `fmt ` body included, follows the WAV rules. Pad bytes follow the RIFF rule: outside the extent they are not read (`w64_pad_outside_extent`), inside it they must be present (`w64_pad_missing`). | Its own demuxer: reads the sizes as signed and ignores the file size past a minimum of 72; rejects a chunk of 24 bytes or less, so an empty `data` too. |
| Wave64 sizes and padding | Sizes count the header but not the padding, as the Sony specification and libsndfile write them; the writer does so (`w64_mono_8k`, `w64_u8_odd`, `w64_alaw_mono_8k`, `w64_s24_stereo_extensible`). FFmpeg's muxer counts the padding instead: its 18-byte `fmt ` declares 48 bytes, so a plain `fmt ` body may be 24 bytes in Wave64, the last 6 skipped (`w64_ffmpeg_padded_sizes`); any other plain size stays `UnsupportedFormat` (`w64_fmt_size_20`). Its `data` size after an unaligned payload counts the pad bytes as data, which every reader then decodes. | The muxer writes padded sizes; its demuxer estimates the duration from the bytes after the data start, padding and later chunks included. |
| Tags (T21c) | Read only when the caller collects them (`Parser.collectTags`), from RIFF and RF64 streams, before or after `data`, as FFmpeg's demuxer reads them: a `LIST` (or `list`) of type `INFO` gives one tag per subchunk, the 4-byte code up to its first NUL as the key and the value, read with its pad byte, up to its first NUL (`info_tags`, `info_after_data`, `info_values`); an all-zero code is skipped; a repeated key replaces the earlier tag, which moves the last tag into its place (`info_duplicates`). A subchunk that does not fit is read again one byte back, FFmpeg's recovery from a missing pad byte (`info_missing_pad`); if it still does not fit, the list ends there and its earlier tags stay (`info_malformed`). Other list types are skipped (`list_adtl`). A `bext` of at least 602 bytes gives its five text fields when not empty, the time reference in decimal, the UMID in hexadecimal when version 1 or later has a nonzero one (32 or 64 bytes), and the coding history when present (`bext_tags`, `bext_version0`, `bext_extended_umid`); a shorter `bext` gives none. Tags are then reported under FFmpeg's names: the `bext` fields first (`description` → `comment`, `originator` → `encoded_by`, `origination_date` → `date`, `origination_time` → `creation_time`), then the INFO codes (`IART` → `artist`, `INAM` → `title`, ...; `IPRT` and `ITRK` → `track`), each pass keeping a duplicate key only with a different value. Collecting never changes a stream's verdict, except that tag chunks then count toward the 1 MiB retained-bytes limit (`LimitExceeded`). Wave64 streams report no tags. | The same tags in the same order. FFmpeg reads tags after `data` only from seekable input; a value may run up to 8 bytes past its list, where ours stops at the list's end; a `bext` shorter than 602 bytes is read into the next chunk; a coding history above 1 MiB, and a `LIST` shorter than 4 bytes, fail the whole file. |
| Writing tags (T21c) | `WriteOptions.tags`, under FFmpeg's names, as `riffenc.c`'s `ff_riff_write_info` writes them: every name renamed to the first INFO code it reports as (`track` → `IPRT`), a duplicate key and value dropped, then one subchunk per known INFO code in its fixed order, from the first tag with exactly that code, with the value's NUL and pad byte; an empty value is skipped, though it still makes a list. The `LIST` goes after `fmt ` and `fact`, before `data` (`info_tags`; FFmpeg's `-bitexact` copy of it is byte-identical). `WriteOptions.bext` writes a version 1 `bext` before it from the `bext`-named tags (`bext_written`), as `-write_bext`; reading renames those fields, so a read-then-write round trip keeps only what has an INFO code, as in FFmpeg. Wave64 output has no tags. | The same bytes, without FFmpeg's `encoder` tag (`ISFT`), which its command adds unless `-bitexact`. |
| Carrying tags (T21c) | zffmpeg carries the tags before the input's `data` into WAV output, as FFmpeg's command does by default (`copy_meta`): the first tag of each key, without `creation_time` and the other source-file keys, and when transcoding without `encoded_by` and the other encoding keys. AU and Wave64 output carry none. | FFmpeg also carries tags after `data`, which it reads first from a seekable file (`info_after_data`), and writes AU annotations. |
| Wave64 unknown sizes | Off by default, `UnsupportedStreamingSize`; with `unknown_length`, a file size of all ones is unknown, and a `data` size of all ones or INT64_MAX (what FFmpeg's muxer leaves on a pipe) runs to the end of the input (`w64_unknown_length_pipe`, `w64_data_size_unknown`). | Rejects them, its own pipe output included. |
| Chunk-count limit | Every chunk header inside the extent counts, `fmt ` and `data` included. 4,096 is accepted (`chunks_at_limit`); the 4,097th header is `LimitExceeded` (`chunks_over_limit`). | No limit. |
| 1 MiB retained non-audio bytes | This parser keeps only the `fmt ` fields (at most 18 bytes), so no committed file can reach the limit. The synthesized `large_skip_2mib` vector shows that skipped bytes do not count. | No limit. |
| The writer's header | Since T21a, the `fmt ` FFmpeg's `riffenc.c` chooses: WAVE_FORMAT_EXTENSIBLE above 48 kHz (`s16_stereo_96k_extensible`, `s16_mono_192k_extensible`, `f64_stereo_96k_extensible`) or above 16 bits except float (`s24_stereo_48k_extensible`, `s32_mono_8k_extensible`, `s64_mono_8k_extensible`), with the channel mask, and a `fact` chunk for float, A-law and mu-law. Plain tag-1 high-rate files (`stereo_96k_tag1`, `mono_192k_rate_limit`) are still accepted input. Header bytes still differ where FFmpeg adds its LIST/INFO tags; compare samples and metadata. | Same choice; also writes LIST/INFO unless bit-exact. |

## Error precedence

The parser reads sequentially, and the first violation in stream order wins.
Within one structure, checks run in this order:

1. **RIFF header** (12 bytes; 40 for Wave64): the container tag (`RIFF`,
   `RF64`, `BW64`, or `riff` for Wave64; `RIFX` is `UnsupportedFormat`;
   anything else is `InvalidRiff`), then `riff_size` (RF64: not 0xFFFFFFFF is
   `InvalidRiff`; RIFF: sentinels unless `unknown_length`, then the minimum
   of 4), then the form type (`WAVE`, else `InvalidWave`). For RF64 the `ds64`
   chunk follows: another chunk ID, a size below 28, or a RIFF size that
   cannot hold `ds64` is `InvalidRiff`; a table is `UnsupportedFormat`. For
   Wave64: the rest of the `riff` GUID (`InvalidRiff`), the 64-bit file size
   (all ones unless `unknown_length`, then the minimum of 40), then the `wave`
   GUID (`InvalidWave`). Input that ends before a check's bytes are complete
   is `Truncated`.
2. **Each chunk header** (8 bytes; 24 for Wave64) inside the extent:
   1. fewer bytes of extent left than a header: `InvalidRiff`; input ends
      inside the header: `Truncated` (an unknown extent ends where the input
      does, between chunks);
   2. chunk count above 4,096: `LimitExceeded`; then for Wave64 a declared size
      below 24: `InvalidRiff`;
   3. `fmt `: a second one is `InvalidWave`; a declared size below 16 is
      `InvalidFormat`. `data`: no `fmt ` yet or a second `data` is
      `InvalidWave`; size 0xFFFFFFFF (Wave64: all ones or INT64_MAX) is
      `UnsupportedStreamingSize` (RF64: the `ds64` data size instead; with
      `unknown_length`, the rest of the input, where a partial final frame is
      `Truncated`); a size that is not a multiple of `block_align` is
      `InvalidFormat`;
   4. the body ends beyond the extent: `InvalidRiff`;
   5. the body, and its pad bytes where they lie inside the extent: input
      ends early: `Truncated`.
3. **`fmt ` fields**: format tag (not 1, 3, 6, 7 or 0xFFFE:
   `UnsupportedFormat`); for 0xFFFE, the chunk size (not 40) and `cbSize`
   (not 22), then the subformat GUID (not tag 1, 3, 6 or 7 in the
   KSDATAFORMAT, ambisonic or "broken" family), each `UnsupportedFormat`; bits per sample for the (sub)format
   tag (see the encodings table; otherwise `UnsupportedFormat`), then for
   extensible the valid bits (not 0 or the container's: `UnsupportedFormat`);
   channels (0: `InvalidFormat`; above the limit: `LimitExceeded`; the
   extensible mask never fails, since T23b);
   sample rate (0: `InvalidFormat`; above the limit: `LimitExceeded`);
   `block_align` (not `channels * bits / 8`: `InvalidFormat`); then, for a
   plain `fmt `, the chunk size (16, or 18 with `cbSize == 0`, or in Wave64
   also 24 with `cbSize == 0`; anything else is `UnsupportedFormat`).
4. **End of the extent**: a missing `fmt ` or `data` is `InvalidWave`.

Fixtures that pin precedence: `rifx_truncated` (tag before truncation),
`fmt_unsupported_before_invalid` (tag 2 before channels; before T21a it used
tag 3, now supported), `extensible_mask_mismatch` (mask after channels),
`data_size_unknown`
(sentinel before extent), `chunks_over_limit` (count before any other check on
the 4,097th chunk) and `duplicate_data` (an error after audio).

## Hand check: `mono_8k`

The canonical mono file, 60 bytes, checked field by field:

```text
offset  bytes                                    field
0       52 49 46 46                              "RIFF"
4       34 00 00 00                              riff_size 52 = 60 - 8
8       57 41 56 45                              "WAVE"
12      66 6d 74 20                              "fmt "
16      10 00 00 00                              fmt size 16
20      01 00                                    format tag 1 (PCM)
22      01 00                                    channels 1
24      40 1f 00 00                              sample rate 8000
28      80 3e 00 00                              byte_rate 16000 = 8000 * 2
32      02 00                                    block_align 2
34      10 00                                    bits per sample 16
36      64 61 74 61                              "data"
40      10 00 00 00                              data size 16 = 8 samples * 2
44      00 00 01 00 ff ff ff 7f                  0, 1, -1, 32767
52      00 80 39 30 c7 cf 00 01                  -32768, 12345, -12345, 256
```

## Provenance

`generate.py` and `../fixtures.zig` are original project files
(`LGPL-2.1-or-later`). The fixture files and `manifest.zon` are data generated
by `generate.py`; their sample values were chosen by hand. No FFmpeg sample
files or code were used. FFmpeg's `wavdec.c`, `riffdec.c` and `riffenc.c` were
read only to record the behavior differences above and the header choice.
`generate.py` computes expected decoded values with its own decoders, G.711
included (restated from the ITU recommendation's reference code), independently
of the Zig tables.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `mono_8k` | accepted | 60 | accept: 1 channel, 8000 Hz, 8 frames; writer output | Canonical mono: 16-byte `fmt `, tag 1, 8 kHz. | `c7f5296f101833dffb9e8cb2ddbd144071d532b4a37edebc1b5179f444e92be4` |
| `stereo_44k1` | accepted | 60 | accept: 2 channels, 44100 Hz, 4 frames; writer output | Canonical stereo at 44.1 kHz; samples interleave left/right. | `c6e43f79515989f847a0b0c71b0d43312c56944272da0acdf82c2992b412c531` |
| `stereo_96k_tag1` | accepted | 60 | accept: 2 channels, 96000 Hz, 4 frames | High-rate stereo with a plain tag-1 `fmt `, as older writers produce. The writer emits WAVE_FORMAT_EXTENSIBLE above 48 kHz (`s16_stereo_96k_extensible`). | `6a74d1d4934a89b8402a64b6f66a96d1b1a002ff29242c9922984158ddb99dd6` |
| `mono_192k_rate_limit` | accepted | 52 | accept: 1 channel, 192000 Hz, 4 frames | Sample rate exactly at the 192,000 Hz limit, with a plain tag-1 `fmt `. | `98fe629f578d2d3793fd0464fb7ba91d3bed349f97cce05f69695994a3d5df75` |
| `empty_data` | accepted | 44 | accept: 1 channel, 8000 Hz, 0 frames; writer output | `data` size 0 is an empty stream, not read-to-EOF. | `4f8734c5e13ac599e168cf247a51c1dd0758537ce00bf16d7fed1a3d14d07041` |
| `fmt18_cbsize0` | accepted | 54 | accept: 1 channel, 8000 Hz, 4 frames | 18-byte `fmt ` with `cbSize == 0`. | `ad6aec9f3e62070477f61fd767a73b3bd9b5d3c5192419a735e8ed82074a6e53` |
| `byte_rate_mismatch` | accepted | 52 | accept: 1 channel, 8000 Hz, 4 frames | Inconsistent `byte_rate` is ignored. | `f0078566dc0aeaaa6df7a9050b562b870faeefb6b0bd07364409fd2269758106` |
| `unknown_chunks` | accepted | 90 | accept: 1 channel, 8000 Hz, 4 frames | Unknown chunks before `fmt `, between `fmt ` and `data`, and after `data` (odd-sized, padded) are skipped. | `3a639faa3763a5428d9e8ab4d5bce77c92961d3d33e39905711c156081cca77d` |
| `odd_chunk_padded` | accepted | 64 | accept: 1 channel, 8000 Hz, 4 frames | An odd-sized chunk before `data` is followed by its pad byte, which is skipped. | `acb12746075573f1b567643270f26b36ce615bb87fc5529473478ab8d11844b9` |
| `odd_final_chunk_pad_outside_extent` | accepted | 63 | accept: 1 channel, 8000 Hz, 4 frames | The final odd-sized chunk ends at the RIFF extent and the file ends there: the pad byte would lie outside the extent, so it is not read. | `22d6e90392dd812ba3d70fa8adaa5616ad5bf64ff4118fd607d18cbb93d5f278` |
| `trailing_bytes_after_riff` | accepted | 60 | accept: 1 channel, 8000 Hz, 4 frames | Bytes after the declared RIFF extent are ignored. | `4b15a44087486e2d17244e08036b35a69b5c8d47e167a58b9fbe2a7c6fdf2272` |
| `chunks_at_limit` | accepted | 32800 | accept: 1 channel, 8000 Hz, 2 frames | Exactly 4096 chunks: `fmt `, 4094 empty `JUNK`, `data`. | `ce09b852cc70d64349dcaee84927ee08c29dca175ffca0b70e297e11a6414b19` |
| `u8_mono_8k` | encodings | 52 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_u8`; writer output | Unsigned 8-bit (tag 1, 8 bits) with a 16-byte `fmt `; silence is 128. | `a46626a3c3a49b624beccf9d989c1892a5e735823d68c028ba20dd3a1de29fff` |
| `s24_stereo_48k_extensible` | encodings | 92 | accept: stereo (2 channels), 48000 Hz, 4 frames, `pcm_s24le`; writer output | 24-bit stereo; above 16 bits the writer uses WAVE_FORMAT_EXTENSIBLE with the channel mask. | `5f6806bc0a30ac77b48f9f8a12efcc773f3fae4326a1ea759488dc7eddff9577` |
| `s32_mono_8k_extensible` | encodings | 100 | accept: mono (1 channel), 8000 Hz, 8 frames, `pcm_s32le`; writer output | 32-bit integers, extensible. | `184f1dd20b729357adcfcd28542d79e44baf5d3337e82902d93e2f1e4d18d682` |
| `s64_mono_8k_extensible` | encodings | 132 | accept: mono (1 channel), 8000 Hz, 8 frames, `pcm_s64le`; writer output | 64-bit integers, extensible. | `d9491f8b731ae40ac2ce76ed6bc0e5ff55f4ee3696f36547ca2f3951206f262e` |
| `f32_mono_8k` | encodings | 90 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_f32le`; writer output | IEEE float (tag 3) up to 48 kHz: an 18-byte `fmt ` with `cbSize` 0 and a `fact` chunk. Every bit is kept, NaN payload included. | `be8a1cda321f60acfaeebcc1a2db9de39e0dd3cbbca026daa46fc9f6c1a1f68b` |
| `f64_stereo_96k_extensible` | encodings | 144 | accept: stereo (2 channels), 96000 Hz, 4 frames, `pcm_f64le`; writer output | 64-bit float above 48 kHz: extensible with the IEEE float subformat, and a `fact` chunk. | `98ff90854642635641bff14bf65a9c98e1e43dab22f47f220e698e578e98b828` |
| `alaw_mono_8k` | encodings | 66 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_alaw`; writer output | A-law (tag 6): an 18-byte `fmt ` and a `fact` chunk; decodes to s16. | `a1b490a6ff6901a9ee8160032d6e301dd23e4edab9b3d50ba563ceddf9f1b8e6` |
| `mulaw_mono_8k` | encodings | 66 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_mulaw`; writer output | mu-law (tag 7): an 18-byte `fmt ` and a `fact` chunk; decodes to s16. Its negative zero (0x7F) is left out: it reads as zero, which every encoder writes as 0xFF. | `d93d6af5d3a67eebdac8f82d285ddefef7e6395990030702ce4357242032fd92` |
| `s16_stereo_96k_extensible` | encodings | 84 | accept: stereo (2 channels), 96000 Hz, 4 frames; writer output | 16-bit stereo above 48 kHz: the writer uses WAVE_FORMAT_EXTENSIBLE, as FFmpeg's does. | `c87522608bf97540beb0ec6a8d1362b70994f5deab6199785a3c73d16df80d72` |
| `s16_mono_192k_extensible` | encodings | 76 | accept: mono (1 channel), 192000 Hz, 4 frames; writer output | 16-bit mono at the 192 kHz limit, extensible. | `ee0605d3a877cf0eea475b90dae6388992e921750fa8036f7b8810c1323552f8` |
| `extensible_mask_zero` | encodings | 76 | accept: 1 channel, 8000 Hz, 4 frames | Extensible with channel mask 0: FFmpeg leaves the layout unspecified. | `186d38f552a9d16048991d285ebc1c802e648e389849e1b07f723f414951152d` |
| `extensible_valid_bits_zero` | encodings | 92 | accept: stereo (2 channels), 8000 Hz, 4 frames, `pcm_s24le` | Extensible 24-bit stereo with `wValidBitsPerSample` 0: all bits are valid. | `7dd3eaf5fdbbb76b9d6721cb04ca63e2c5280464f800771895b2d09a1727274b` |
| `info_tags` | tags | 142 | accept: 1 channel, 8000 Hz, 4 frames; writer output; 5 tags | A LIST/INFO chunk between `fmt ` and `data`, NUL-terminated values in the order FFmpeg's writer uses; the codes report as FFmpeg's names. | `62c3d42f0466a298994d5c5c809733884c6b071532ca650984d2425ec5527141` |
| `bext_written` | tags | 670 | accept: 1 channel, 8000 Hz, 4 frames; writer output; 8 tags | The writer's `bext` option: the 602 fixed bytes from the `bext`-named tags, version 1, the UMID parsed back to bytes, and the coding history with its NUL. Read back, the fields report under FFmpeg's names. | `5bcec15b6ed4defb08b382c4b7246e0c831dfffdfa7edef99e18204770e846b7` |
| `info_after_data` | tags | 78 | accept: 1 channel, 8000 Hz, 4 frames; 1 tag | A lowercase `list` INFO chunk after `data`: read with the trailing chunks. | `9d7ee0dbde06f0aa889ee1a8426cb7f69413f1147952fe5108b0792ddbb814eb` |
| `info_duplicates` | tags | 114 | accept: 1 channel, 8000 Hz, 4 frames; 3 tags | INAM twice: the second replaces the first, which moves the last tag into its place; IPRT and ITRK both report as `track`. | `01ac77442c29d2aafdd17d1c3f326bfb2357f4609ff9d03440d0fe4dba0b2e57` |
| `info_values` | tags | 148 | accept: 1 channel, 8000 Hz, 4 frames; 6 tags | An unterminated odd value with its pad, an embedded NUL, an empty value, a lowercase code, an unknown code, an all-zero code (skipped) and a code cut at its NUL. | `88b2ce1e268f7d02ad2db19cf6c9f3894bb6d03bc15fd5ebbdee25fe2496a3e0` |
| `info_missing_pad` | tags | 90 | accept: 1 channel, 8000 Hz, 4 frames; 2 tags | A 3-byte value without its pad byte: the next header is one byte early, which FFmpeg's reader recovers from by reading it again one byte back. | `19e8d3145c01ac837c570944ed73b29d16eff674a1efb234f665e1c9362edf39` |
| `info_malformed` | tags | 88 | accept: 1 channel, 8000 Hz, 4 frames; 1 tag | A subchunk declaring 200 bytes in a shorter list ends the list; the tag before it is kept and the stream is valid. | `b8f28ec6c42e9842b878ec7aa88d7370b7abb08432d5389bc23455cbae1fe94b` |
| `list_adtl` | tags | 76 | accept: 1 channel, 8000 Hz, 4 frames | A LIST of type `adtl` (cue labels) is skipped: no tags. | `6587a25848b2ff9eae1bbe17d504d712b3f76c56ce42ca15b2f6b300a0cfac46` |
| `bext_tags` | tags | 720 | accept: 1 channel, 8000 Hz, 4 frames; 9 tags | A version 1 bext with every text field, a basic UMID and a coding history, then INFO: ICMT equals the description, so only one `comment` remains. | `b39a6b023bba9a76c060f70623a6a3b8a1f0d41aef4c3845d2b989865a54ea98` |
| `bext_version0` | tags | 662 | accept: 1 channel, 8000 Hz, 4 frames; 1 tag | A version 0 bext with empty text: only the time reference, even 0, is reported; the UMID bytes are ignored before version 1. | `c6e043d6ea114be4fc5a35c9d5c171b5291fcf4e57cedac854fc5aee2640320f` |
| `bext_extended_umid` | tags | 662 | accept: 1 channel, 8000 Hz, 4 frames; 2 tags | A 64-byte (extended) UMID: all eight parts are reported. | `9788fadb12f1f27307cca5202dffbdd918764cfb0cb749cc48b2bdb4965e0c2f` |
| `rf64_info` | tags | 112 | accept: 1 channel, 8000 Hz, 4 frames; 1 tag | RF64 carries LIST/INFO like RIFF. | `8ea0136d4efd7edbf4e0600c61580c50235a9ad454f900ebcecd0b7e2cd5d107` |
| `empty_input` | riff header | 0 | reject: `Truncated`; not detected (probing picks no format) | No bytes at all. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `truncated_riff_header` | riff header | 6 | reject: `Truncated`; not detected (probing picks no format) | Input ends inside the RIFF size field. | `b3c8c531fe520e8a27cc91b078c6dd6334e872e894ecc92700c87f6fc3ad7e62` |
| `not_riff` | riff header | 60 | reject: `InvalidRiff`; not detected (probing picks no format) | Unknown container tag `JUNK`. | `b3124366628d32f43bff7df698a2beadf8a14cbf26cf1255ea8338b48ee962f0` |
| `rifx_big_endian` | riff header | 60 | reject: `UnsupportedFormat` | Big-endian RIFX container. | `5ba707782a9dd8287a62fc2862d9a00c043d03bc80e615dc59c21c5845a91fb7` |
| `rifx_truncated` | riff header | 6 | reject: `UnsupportedFormat`; not detected (probing picks no format) | Precedence: the container tag is checked as soon as it is read, before the input runs out. | `747a7d80b921cad654cf7d736c5eaf96d8e51f4f4aaba69f29ebc7a3f4356e7e` |
| `rf64` | rf64 | 88 | accept: 1 channel, 8000 Hz, 4 frames; writer output | RF64 as the writer emits it with `rf64 = .always`: 0xFFFFFFFF in the 32-bit RIFF and `data` sizes, the real ones in `ds64` (rejected before T21b). | `908d7944bcb48cec43734a4c051e73369ca6fa33fa05772d2efa811a2ccc2036` |
| `bw64` | rf64 | 88 | accept: 1 channel, 8000 Hz, 4 frames | BW64, the EBU's RF64 (rejected before T21b). | `e38fae0af5bfb6da5b3031f1c8e853c8f08d935cc663941af42c0dce82f2d616` |
| `rf64_data_size_in_chunk` | rf64 | 88 | accept: 1 channel, 8000 Hz, 4 frames | RF64 whose small `data` chunk holds its own size: `ds64`'s is used only for 0xFFFFFFFF. | `9869cb2e55b60327c5414ad77734f62599bbfa23df77e81a7dbcc6843e34a851` |
| `rf64_riff_size_not_sentinel` | rf64 | 88 | reject: `InvalidRiff` | RF64 with a 32-bit RIFF size other than 0xFFFFFFFF. FFmpeg ignores the field. | `8b035e483117536abba7dec3f5774a61a9362bfcfa42169c5e78dff995eb2dd7` |
| `rf64_missing_ds64` | rf64 | 52 | reject: `InvalidRiff` | RF64 whose first chunk is `fmt `, not `ds64`. | `01eeb370eeda2363edc3e07c9af3449a5e81c494e290da65386e61da32a3c4e4` |
| `rf64_ds64_short` | rf64 | 84 | reject: `InvalidRiff` | A 24-byte `ds64` without the table count. FFmpeg accepts 24 bytes. | `25ec7abe69bac79d164fb55431d51412bb9cfff00cd6e0f848431ac62637dbb4` |
| `rf64_ds64_table` | rf64 | 88 | reject: `UnsupportedFormat` | A `ds64` with one table entry (64-bit sizes of other chunks). | `2e0622a8b237f23435446ea211ffd10214422a1a80551ebda7f4ce21ac464ccf` |
| `rf64_data_exceeds_extent` | rf64 | 88 | reject: `InvalidRiff` | `ds64` declares 64 data bytes, but the RF64 extent ends after 8. | `842d16c4389674b69a28bd5d74f59a6929300a3adf432223b5fac524ee6286ec` |
| `rf64_truncated_ds64` | rf64 | 30 | reject: `Truncated` | Input ends inside `ds64`. | `396b56f69749b010a61d32aec205ffdbfd4aa5f9f4293a97fed1512004308d23` |
| `w64_mono_8k` | w64 | 120 | accept: 1 channel, 8000 Hz, 8 frames; writer output | Wave64 as the writer emits it: the `fmt ` of WAV, sizes that count the 24-byte chunk header. | `f28cafb2b9124a673d72bc8716eaa2c57cb48279ef1a841341179aacd8491ff9` |
| `w64_u8_odd` | w64 | 112 | accept: 1 channel, 8000 Hz, 3 frames, `pcm_u8`; writer output | Three u8 frames: `data` declares 27 bytes and 5 pad bytes follow, outside its size. | `411de02c8dce8ac243c6d761302f305299dcb967fdd9b76651c0c0a340f5a81a` |
| `w64_alaw_mono_8k` | w64 | 152 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_alaw`; writer output | A-law: the 18-byte `fmt ` is padded to 8 bytes, and a `fact` chunk holds a 64-bit count. | `7e8162072976ee575743aec27529b79022a34f0ba99b1451220f27c677ad8b72` |
| `w64_s24_stereo_extensible` | w64 | 152 | accept: stereo (2 channels), 8000 Hz, 4 frames, `pcm_s24le`; writer output | 24-bit stereo: the extensible `fmt `. | `d7c62199bd6878643a276338add2e6e952d5ce3b7e698d37a404d0193525cdb8` |
| `w64_4point0` | w64 | 144 | accept: 4.0 (4 channels), 8000 Hz, 2 frames; writer output | Four channels with the 4.0 mask (FL, FR, FC, BC): the extensible `fmt ` a named layout other than mono and stereo gets (T23b). | `2dcb9bb225fc187e3ec9bae9aa11eea1fc22c381b235e867647b606f73e9eead` |
| `w64_ffmpeg_padded_sizes` | w64 | 160 | accept: 1 channel, 8000 Hz, 4 frames, `pcm_f32le` | Float as FFmpeg's muxer writes it: its sizes count the padding, so the 18-byte `fmt ` declares 48 bytes, a 24-byte body whose last 6 are skipped. | `d54baa587a37d5244b4f57dadfb8980e67b31794e633f11eeeb83b2143af8a09` |
| `w64_unknown_chunks` | w64 | 176 | accept: 1 channel, 8000 Hz, 4 frames | A `summarylist` GUID chunk with a 5-byte body before `data` and a `levl` chunk after it are skipped, with their padding. | `e97352e15f54ca2261431a1bbc13794c9c0a7d4081c8c2a00dca37f4c2bb79fd` |
| `w64_pad_outside_extent` | w64 | 110 | accept: 1 channel, 8000 Hz, 3 frames | The file size ends with 3 frames (6 data bytes); the 2 pad bytes after them are absent. | `36d5bab01f796cb6b4b31faab6d3948bfdfae3f0a1d5fb03e1d379eef4ada8ef` |
| `w64_pad_missing` | w64 | 110 | reject: `Truncated` | The file size counts the 2 pad bytes after 6 data bytes, but the input ends before them. | `621fe993315cbf3a126d2203def3ed6eb70f1b743ff35a454939108e18426f31` |
| `w64_no_chunks` | w64 | 40 | reject: `InvalidWave`; not detected (probing picks no format) | A Wave64 header with no chunks: `fmt ` and `data` are missing. | `c241923d87f74120fe400a96583693c9e1c64984f3dc3d57939b27e3533bdaf2` |
| `w64_bad_riff_guid` | w64 | 112 | reject: `InvalidRiff`; not detected (probing picks no format) | `riff` followed by another GUID's last 12 bytes. | `f96e6c4734cf0942041f0ad3a827270c8e99af074608dbad29c7db9e49e997d9` |
| `w64_bad_wave_guid` | w64 | 112 | reject: `InvalidWave`; not detected (probing picks no format) | The form GUID is not `wave`'s. | `f28cdd76df2c225214cf6d46d0cf24853bf453de24f1b6cffa8041c239d05631` |
| `w64_size_too_small` | w64 | 112 | reject: `InvalidRiff` | A file size of 39, less than the 40-byte header. | `603b006075b7c8fdffd3e1bdb5df448e9d3e57d0d43054f8dfdb2c4088f65675` |
| `w64_chunk_size_below_header` | w64 | 112 | reject: `InvalidRiff` | A `fmt ` chunk declaring 16 bytes, less than its own 24-byte header. | `56e3a713c07bc4378f0e1d2bf869e3769fae884f9e00034ee082ef0ef91ca4e8` |
| `w64_data_exceeds_extent` | w64 | 112 | reject: `InvalidRiff` | `data` declares 64 bytes past the file size. | `386a03d36c3173febb454941a65f17c4d46f53fb2e8067a26bc6a80c12496283` |
| `w64_fmt_size_20` | w64 | 120 | reject: `UnsupportedFormat` | A plain `fmt ` of 20 bytes: Wave64 adds only FFmpeg's padded 24 to 16 and 18. | `4bba683d75f97855d006e76c3fec154946b93f3103f65b7cc5394e3aa945d71c` |
| `w64_truncated_chunk_header` | w64 | 90 | reject: `Truncated` | Input ends inside the `data` chunk's GUID. | `c9e077a63e0a3a0d30c4df568da54df4c0115a9d136187c09eab59339067bdf9` |
| `w64_unknown_length_pipe` | w64 | 120 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 8 frames | As FFmpeg's muxer writes Wave64 to a pipe: file size all ones, `data` size INT64_MAX. | `0c0320f09899281b445876086c345457ecfb3050c76d6c197905109df7124333` |
| `w64_data_size_unknown` | w64 | 108 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 2 frames | A known file size with `data` size all ones: with `unknown_length` the rest of the stream. | `bb4c3699594d24da71bff6678c055546cf752ba14740241a48e66aecd95ef0a4` |
| `riff_size_unknown` | riff header | 52 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 4 frames | `riff_size` is the 0xFFFFFFFF unknown-size sentinel. With `unknown_length` the extent is the rest of the stream. | `6f4aee6c2e8c23872b15942f3873525270ed8be04fb64aa0907e7f13f86a528a` |
| `riff_size_zero` | riff header | 52 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 4 frames | `riff_size` is 0, the other unknown-size sentinel. | `2efc1f7b368fa82528aaf298aa8a1b0c69c0bae297d8b7c2fb5a0b35a5034c50` |
| `riff_size_too_small` | riff header | 52 | reject: `InvalidRiff` | `riff_size` 2 cannot hold the form type. | `00ef3e3b7d407394188f7d35cb008f353e8866c0f2d8ba1274742d37dc577700` |
| `not_wave_form` | riff header | 52 | reject: `InvalidWave`; not detected (probing picks no format) | RIFF form type `AVI ` instead of `WAVE`. | `c550e46e05c769704d13e5ab988b17cd505983f51cebc712f5f29fad437f2ff1` |
| `no_chunks` | riff header | 12 | reject: `InvalidWave`; not detected (probing picks no format) | A WAVE form with no chunks: `fmt ` and `data` are missing. | `1fe5a351bf0314c8a1840b023fd1e4cab3f0f123468940c241bd7bf20e989ab8` |
| `fmt_size_14` | fmt | 50 | reject: `InvalidFormat` | A complete `fmt ` chunk declaring only 14 bytes. | `a68b82d69f1db19666a330f62a3415a16845a4ae5db85ffb5bbdc7100762649b` |
| `fmt_truncated` | fmt | 30 | reject: `Truncated`; not detected (probing picks no format) | Input ends inside the `fmt ` body. | `e617018ac7052f420c9b95ae6562fbc0c7fab8e30f4ef0df1f0e2018c8dbca78` |
| `fmt20_cbsize2` | fmt | 56 | reject: `UnsupportedFormat` | 20-byte `fmt ` with `cbSize == 2` and two extension bytes. | `2b577347e4fcee5463047a1da4fd3e9e0a624ec2baeb69901dac34754c3c8dcf` |
| `fmt_extensible` | fmt | 76 | accept: mono (1 channel), 8000 Hz, 4 frames | WAVE_FORMAT_EXTENSIBLE (tag 0xFFFE, 40 bytes) with the PCM subformat and the mono mask: 16-bit PCM (rejected before T21a). | `2ab8c3455ef12b8fd8908ea15fa2ba2a6df86f96abcbe6eb271e788a97ba6668` |
| `fmt_float32` | fmt | 52 | accept: 1 channel, 8000 Hz, 2 frames, `pcm_f32le` | IEEE float (tag 3, 32-bit) with a 16-byte `fmt ` and no `fact` chunk, which is optional (rejected before T21a). | `04650c8621f4e7c37764fb2f3a5c7e1cda719f5d2c5fbe250799599a78b9cf49` |
| `fmt_bits24` | fmt | 50 | accept: 1 channel, 8000 Hz, 2 frames, `pcm_s24le` | Tag 1 with 24-bit samples and a plain 16-byte `fmt ` (rejected before T21a). | `099d32416235d742870b590106e8b9ef404e1daf1a07d6e108b51a012a7daaac` |
| `fmt_bits12` | fmt | 52 | reject: `UnsupportedFormat` | Tag 1 with 12 bits in 2-byte samples: only whole-byte depths. FFmpeg rounds up and reads s16. | `30177bc9f218a9e3666d52fc9ee87abeeb2f682980a38bad4ffd26f699c31c64` |
| `fmt_float_bits16` | fmt | 52 | reject: `UnsupportedFormat` | Tag 3 with 16-bit samples: float is 32 or 64 bits. | `35b8b9356cd816d5b43b03804b08e0bcd692580d12125460990aacb37eb3d21f` |
| `fmt_alaw_bits16` | fmt | 52 | reject: `UnsupportedFormat` | A-law (tag 6) declaring 16 bits: A-law is 8 bits. | `379389d4268891ae69f192943e769a2975948fd00e010f32ba15a37e27cf3244` |
| `fmt_adpcm` | fmt | 52 | reject: `UnsupportedFormat` | Tag 2 (Microsoft ADPCM) is not a contract encoding. | `c78e8f744ef4ced5c34c22eec2da08691efa8147278c06937ab88e69c50d1609` |
| `fmt_s24_block_align_mismatch` | fmt | 52 | reject: `InvalidFormat` | 24-bit stereo with `block_align` 4 instead of 6. | `fbd7a6c580a15ebd14575426ed3e7febae1fe89d2a60358f6ada105f3eafeef4` |
| `extensible_fmt18` | extensible | 54 | reject: `UnsupportedFormat` | Tag 0xFFFE in an 18-byte `fmt ` with `cbSize` 0. | `810fed57ee6ed5e35ae9ddd8d8c9492ea0bdff74a05bdbf4c107568f99294200` |
| `extensible_cbsize_short` | extensible | 76 | reject: `UnsupportedFormat` | A 40-byte extensible `fmt ` declaring `cbSize` 10. | `9c3fe2614e94d8957e13a3f6bbc3872d2a2b1d80f641442a2d9d6c35e3a82a2f` |
| `extensible_unknown_subformat` | extensible | 76 | reject: `UnsupportedFormat` | An extensible `fmt ` whose subformat is the AC-3 GUID. | `23b39f19a48d0f8c8b7f8837519dc4ccc07bff6a7453fac179145b5ff3482a3b` |
| `extensible_subformat_adpcm` | extensible | 76 | reject: `UnsupportedFormat` | The base subformat GUID with tag 2 (ADPCM). | `7550344848c60d2ae9b2d6b4f28bdcb3b905097ef8d4a1821f4318dda4a5e860` |
| `extensible_valid_bits_mismatch` | extensible | 80 | reject: `UnsupportedFormat` | 24-bit samples declaring 20 valid bits: only all bits valid. FFmpeg reads them as s24. | `ff3624938ccceda00f9422e69154bb0f73d9b587a5e70f9edbc65db72ea2daec` |
| `extensible_mask_mismatch` | extensible | 84 | accept: 2 channels, 8000 Hz, 4 frames | Stereo with the mono channel mask (front center): FFmpeg ignores a mask that does not name exactly the channels, so the layout is unspecified (rejected before T23b). | `85cfb57100d4ba0f41662960bd0bd61a088299886aeab4d0fb11953d3b9fcb88` |
| `extensible_truncated` | extensible | 50 | reject: `Truncated` | Input ends inside the 40-byte extensible `fmt `. | `84fa3ea6ecc07b9e08c7e5531ba04078b3bc8049146dc0b93aef67ddb0f888f4` |
| `fmt_channels3` | fmt | 56 | accept: 3 channels, 8000 Hz, 2 frames | Three channels in a plain header: the layout is unspecified (rejected before T23b). | `5c412517300b1a98125b0a72acdc0fd637003326ef0c2409d5db899855985dd6` |
| `extensible_5point1` | layouts | 92 | accept: 5.1 (6 channels), 8000 Hz, 2 frames; writer output | Six channels with the 5.1 mask (FL, FR, FC, LFE, BL, BR): a named layout other than mono and stereo makes the writer use WAVE_FORMAT_EXTENSIBLE even at 16 bits. | `8d376175d24b11d8306196f50527b3ad9d0f36b0dd32137ca01e988a7279c14e` |
| `extensible_7point1_s24` | layouts | 92 | accept: 7.1 (8 channels), 8000 Hz, 1 frame, `pcm_s24le`; writer output | Eight 24-bit channels with the 7.1 mask (5.1(side) and BL, BR). | `6251a9fa13007ae5ee8f9ee3c3bed7857dc3d76299dd585e2132b7a55fdd9c52` |
| `fmt_channels6` | layouts | 68 | accept: 6 channels, 8000 Hz, 2 frames; writer output | Six channels in a plain header: unspecified, written back the same way. | `c68f4df007fe030c61066584500fbfa210a6f6a8197ba42972f16e95230f6c2f` |
| `extensible_mask_high` | layouts | 80 | accept: 3 channels (FL+FR+USR20) (3 channels), 8000 Hz, 2 frames | Three channels whose mask has FL, FR and position 20, which WAVE does not define: native all the same, described by its positions. | `02835004ebf845fd475ff6eceaa750749b5d34e8103510ea487c579153e5dda2` |
| `extensible_mask_extra` | layouts | 84 | accept: 2 channels, 8000 Hz, 4 frames | Stereo with a three-channel mask: unspecified. | `9d94fffc3e6250da42232f23a8a8e64fa9936a70a662946f2ed15a2d34d2681c` |
| `fmt_channels64` | layouts | 172 | accept: 64 channels, 8000 Hz, 1 frame | 64 channels, the default limit, in a plain header: one frame. | `d56b11ec00f1f2a66681a764267e3b0a195e9bc2823cc509de508a70b1bf17a8` |
| `fmt_channels65` | layouts | 174 | reject: `LimitExceeded` | 65 channels, above the default limit (FFmpeg reads them). | `5fb1406526f96292d5aac26cb4aa5cbcc76fac335b3c005d6cc8b92e0ca95143` |
| `fmt_channels0` | fmt | 44 | reject: `InvalidFormat` | Zero channels. | `4b5033687417507625294bed6a571d8fe3cbf288290b0d22967ee8277520be78` |
| `fmt_rate0` | fmt | 52 | reject: `InvalidFormat` | Zero sample rate. | `1d7080024c4773fdaf47ecc1ff6174a424a6c339f348d3f680fb865d33e0b96b` |
| `fmt_rate_over_limit` | fmt | 52 | reject: `LimitExceeded` | Sample rate 192,001 Hz, above the default limit. | `fb68abcc3c4d8912777b9d78d89cff6a0f7d645e9daca283fc0ecf42f93b780f` |
| `fmt_block_align_mismatch` | fmt | 60 | reject: `InvalidFormat` | Stereo with `block_align` 2 instead of 4. | `7487494878462bb126a2858c54b4164bca7dac59d53a82c0ba68f1aee072f2df` |
| `fmt_unsupported_before_invalid` | fmt | 44 | reject: `UnsupportedFormat` | Precedence: tag 2 (ADPCM) with zero channels reports the unsupported tag first. | `6d875c806f3d508b7c1ae459a1a3bc97360e14c81c7c60145f10522679b3bac2` |
| `data_before_fmt` | order | 52 | reject: `InvalidWave` | `data` appears before any `fmt `. | `6dc6ff3326113206fd7c7766df7fd7bd8ee057a06dec6a6a9d042154c2c6462c` |
| `missing_data` | order | 36 | reject: `InvalidWave` | `fmt ` but no `data` within the RIFF extent. | `96b0b94deea11168966c72d7ec8d7fbff14d4dd6ad06dbbd5089b034e0b4bb70` |
| `duplicate_fmt` | order | 76 | reject: `InvalidWave` | Two `fmt ` chunks (FFmpeg ignores the second). | `c9d98fda8d44b0d655a71cd2858f5a6d905e647386e67bc01c800c703f837efc` |
| `duplicate_data` | order | 60 | reject: `InvalidWave` | A second `data` chunk after the first; reported after the first chunk's 2 frames. | `ee90f0ce3209f1028d1292c906d694927ebcecdef66382edc149dd3c0e8e3868` |
| `data_size_unknown` | data length | 48 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 2 frames | `data` size 0xFFFFFFFF; precedence: the sentinel is reported before the extent check. With `unknown_length` the data is the rest of the stream. | `f86e50fa5b8f8a6f20bd2311eabc6f35f966149a900b324540819167e72d7ca4` |
| `unknown_length_pipe` | unknown length | 60 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 8 frames | RIFF and `data` sizes 0xFFFFFFFF, as FFmpeg's muxer leaves them on a pipe. | `68f584fab2283a877a08e64ce4f496c2310e5bd2ddcb5ab110c89fca4001e3ab` |
| `unknown_length_odd_u8` | unknown length | 47 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 3 frames, `pcm_u8` | Three u8 frames of unknown length: odd data at the end of the stream needs no pad byte. | `5b1a0f675921871c49db55ef3d52e8498546e22d0c83eab70687d317640edfbc` |
| `unknown_length_partial_frame` | unknown length | 50 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `Truncated` | Stereo data of unknown length ending after 1.5 frames. | `9794a375928fe143b3c73b0b9914d305154b3df8c0d8da0658fced2cd6db0af1` |
| `unknown_length_reads_past_chunks` | unknown length | 60 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 8 frames | `data` size 0xFFFFFFFF in a known RIFF extent: the data is the rest of the stream, so the chunk after it decodes as samples and the RIFF size goes unchecked, as in FFmpeg. | `5c511724a1b6aafc0ba9fe414f27f91d1d49d7072dd6056a00d175fc08552331` |
| `unknown_riff_chunk_after_data` | unknown length | 60 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 2 frames | Unknown `riff_size` with a known `data` size: the chunks after `data` are read to the end of the stream. | `4be4b937341fafcfbbb7e3d44c7a197616206988bfd7e89c20f2edc6846a71cf` |
| `unknown_riff_empty_data` | unknown length | 44 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 0 frames | Unknown `riff_size` with `data` size 0: still an empty stream. | `f8487a3786721ce11170385e66f3d34e7496d69445ba8a2f91a1b4a22e95841b` |
| `unknown_riff_partial_chunk_header` | unknown length | 51 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `Truncated` | Unknown `riff_size`: the stream ends 3 bytes into the chunk header after `data`. | `f2748524acb393b05010303d8d3f7c5c292ba7c7713aad983f0ceed8b074647c` |
| `unknown_riff_missing_data` | unknown length | 36 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `InvalidWave` | Unknown `riff_size`: the stream ends after `fmt `, between chunks, with no `data`. | `dca663a405f417efaeb1b049fe2d8bdc6f39de2cf6770fe9ec01b154116f1fef` |
| `unknown_riff_pad_missing` | unknown length | 47 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `Truncated` | Unknown `riff_size`: odd u8 data of known size, and the stream ends before its pad byte. | `fa6f7be9eaad8857e6224f730f242d7428dff709bf6a293b9fabe89d0ef512ef` |
| `data_not_block_aligned` | data length | 50 | reject: `InvalidFormat` | Stereo `data` of 6 bytes (1.5 frames). | `185fc947b7c8f7394eb72d7af262ba0a7a180b37104d8393c642c9d537835e36` |
| `data_exceeds_riff_extent` | bounds | 60 | reject: `InvalidRiff` | `data` declares 64 bytes but the RIFF extent ends after 16. | `6182a7c308a387407f09ad54ab255aadc71e0cd7f6d45aceb5eda0f7eb9fdd5a` |
| `chunk_exceeds_riff_extent` | bounds | 60 | reject: `InvalidRiff` | A chunk after `data` declares more bytes than the RIFF extent has left. | `f993ca1dae9966512e96d45047119325e21dd7051f8ef9d2dffe244ff6a4f7ce` |
| `partial_chunk_header_in_extent` | bounds | 51 | reject: `InvalidRiff` | The RIFF extent leaves 3 bytes after `data`, too few for a chunk header. | `a10405d3b09efd8067b9c6782960997acd2c31f93dfa3c3f818c65e26a4e9cfd` |
| `odd_final_chunk_pad_missing` | bounds | 63 | reject: `Truncated` | `riff_size` counts the final chunk's pad byte, but the input ends before it. | `1f182922bcebe651b9965e80cf479d809a8049027f44191c91463a9868f14486` |
| `riff_size_exceeds_input` | bounds | 52 | reject: `Truncated` | `riff_size` claims 16 more bytes than the input holds after complete chunks. | `42008a2676b5e4eb8ee9fb0774eed07d2ba907e389ee021f7979251a1a540377` |
| `truncated_data` | bounds | 54 | reject: `Truncated` | Input ends after 5 of the 8 declared samples. | `eb611ea86ef9d3c0048eb5228725e981af5c8559fef173d54a407070e78526dc` |
| `truncated_mid_sample` | bounds | 51 | reject: `Truncated` | Input ends inside a sample (7 data bytes). | `2024edadaf0f4134670555d5d44809975816b6f97a31fa4f1cc1c7a0afc879fc` |
| `truncated_chunk_header_after_data` | bounds | 51 | reject: `Truncated` | Input ends inside the chunk header that follows `data`. | `b549b974c2891d4cdc84fcc72c98ca8a19f71f4046c3b0780cc7d3d66038e508` |
| `chunks_over_limit` | limits | 32808 | reject: `LimitExceeded` | 4097 chunks: `fmt `, 4095 empty `JUNK`, `data`. | `8ae35f76b3d001f40386075519f017520958ce6631702f13f20953b16a8f9cb7` |
| `large_skip_2mib` (synthesized, not committed) | accepted | 2097212 | accept: mono, 8000 Hz, 4 frames | A 2 MiB `LIST` chunk before `data` is skipped; skipped bytes do not count toward the 1 MiB retained limit. Build it in the test: `fmt ` as in `mono_8k`, then `LIST` with 2,097,152 zero bytes, then `data` with the first 4 `mono_8k` samples. | `e3edce59e7710b921c2082f76f1b97a299b1a869a8ecf594dcf7099fb7e0414b` |
<!-- END GENERATED FIXTURE TABLE -->
