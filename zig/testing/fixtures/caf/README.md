# CAF fixtures: the CAF contract

This is the canonical fixture contract for the
[CAF contract](../../../../port.md#caf-contract) (TODO.md T22d): Apple Core
Audio Format files holding linear PCM, A-law or µ-law, read only here (FFmpeg's
CAF muxer came with T31b: compare.py's CAF output section compares its
output, and ALAC has [its own fixtures](../alac/README.md)). Every rule has at least one named fixture
here with its expected result. `av.caf`, the content detection and the
reference comparison test against these files. The WAV contract and its
shared conventions are in [../README.md](../README.md).

## Files and commands

| Path | Role |
| --- | --- |
| `../generate.py` | Builds every CAF fixture byte by byte with the Python standard library, and writes this directory's files. |
| `<name>.caf` | The fixture files. |
| `manifest.zon` | Expected results, imported by `zig/testing/fixtures.zig` as `fixtures.caf.all`. |
| `README.md` | This contract; the table at the end is generated. |

Change fixtures only in `generate.py`, then run
`python3 zig/testing/fixtures/generate.py`; `--check` fails when any output is
stale.

## Structure

Every field is big-endian. A file is `caff`, a `u16` version that must be 1
(`InvalidCaf`), a `u16` of file flags (ignored), then chunks to the end of the
input: a 4-byte type, a signed 64-bit size and the body, with no padding.

| Chunk | Rule |
| --- | --- |
| `desc` | Must come first with size 32 (`InvalidCaf`): the sample rate as a double, the format ID, format flags, bytes per packet, frames per packet, channels and bits per channel, each a `u32`. Channels 0 is `InvalidFormat`, above 64 (the configurable `Limits.max_channels`, as for WAV, AU and AIFF) `LimitExceeded`; since T23b any count up to it is read. |
| `data` | A `u32` edit count (skipped), then the samples. A size below 4 is `InvalidCaf`; the samples must be whole frames (`InvalidFormat`). A size of -1 means the data runs to the end of the input: `UnsupportedStreamingSize`, unless the parser's `unknown_length` option reads it, in whole frames (`Truncated` otherwise). A second `data` is `InvalidCaf`. |
| `pakt` | `UnsupportedFormat` for PCM: a packet table can make FFmpeg trim priming and remainder frames. ALAC (T31b) reads it: the [ALAC fixtures](../alac/README.md). |
| `chan` | Since T23b, before `data`, Apple's channel layout, read as FFmpeg's `ff_mov_read_chan` reads it ([mov_chan.zig](../../../format/mov_chan.zig), as for AIFF's `CHAN`): a layout tag (`caf_chan_5point1`), a bitmap (`caf_chan_bitmap`) or channel descriptions (`caf_chan_descriptions`, a custom order) give the layout when their channel count is `desc`'s, else it is ignored (`caf_chan_count_mismatch`). Fewer than 12 bytes (`caf_chan_short`) and more descriptions than the chunk holds (`caf_chan_descriptions_overflow`) are `InvalidFormat`, a negative size `InvalidCaf` (`caf_chan_size_negative`). After `data` it is skipped (`caf_chan_after_data`). Without `chan` the layout is unspecified, which zffprobe prints as `unknown`. |
| Others | Skipped (`free`, `info`, `kuki`, ...), before or after `data`; a negative size is `InvalidCaf`. At most 4096 chunk headers after `desc` (`LimitExceeded`, configurable). |

Input that ends exactly between chunks before any `data` is `InvalidCaf`; one
that ends inside a chunk header or body is `Truncated`.

## The description

| Field | Rule |
| --- | --- |
| Sample rate | Truncated toward zero, as FFmpeg's int conversion (`caf_rate_fraction`). Below 1 (zero, negative, NaN) is `InvalidFormat`; above 192,000 Hz (configurable) is `LimitExceeded`. |
| Format ID, flags, bits | `lpcm` with flag 1 (float) and flag 2 (little-endian): integers of 8, 16, 24, 32 or 64 bits, always signed as FFmpeg reads them (8-bit is `pcm_s8`), floats of 32 or 64 bits. `alaw` and `ulaw`. Anything else, other sizes included, is `UnsupportedFormat`. |
| Channels | 0 is `InvalidFormat`; more than 2 is `UnsupportedFormat`. |
| Packets | One frame per packet, of exactly a frame's bytes; anything else is `InvalidFormat`. |

| Codec | Format ID and flags | Decoded storage |
| --- | --- | --- |
| `pcm_s8` | `lpcm`, 8 bits | `u8`, offset by 128 |
| `pcm_s16be`, `pcm_s16le` | `lpcm`, 16 bits | `s16` |
| `pcm_s24be`, `pcm_s24le` | `lpcm`, 24 bits | `s32` |
| `pcm_s32be`, `pcm_s32le` | `lpcm`, 32 bits | `s32` |
| `pcm_s64be`, `pcm_s64le` | `lpcm`, 64 bits | `s64` |
| `pcm_f32be`, `pcm_f32le` | `lpcm`, float, 32 bits | `flt` |
| `pcm_f64be`, `pcm_f64le` | `lpcm`, float, 64 bits | `dbl` |
| `pcm_alaw`, `pcm_mulaw` | `alaw`, `ulaw` | `s16` |

## Error precedence

1. The 8-byte file header and the `desc` chunk header are read whole first,
   so shorter input is `Truncated`; then magic, version, `desc` and its size.
2. The description: the sample rate, then the codec, the channels and the
   packet layout.
3. The chunks in file order (a `chan`: its size, then its fields and
   descriptions), then the samples, then the chunks after them.

## Content detection

`zffprobe`, `zffmpeg` and `av.detect` choose CAF when the input starts with
`caff`, version 1 and a `desc` chunk of size 32 (FFmpeg's `probe` in
`cafdec.c`). A stream no demuxer recognizes is `UnknownFormat`; `-f caf`
forces this contract's parser. Each fixture's `detected` field in
`manifest.zon` records FFmpeg's winner, which `compare.py` checks.

## Decisions

FFmpeg's behavior is from `libavformat/cafdec.c`, `caf.c` and `isom.h` at the
pinned revision.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Version other than 1 | `InvalidCaf` (`caf_version2`). | Its probe rejects it; forced, its demuxer reads it. |
| Integer sizes other than 8 to 64 in whole bytes | `UnsupportedFormat` (`caf_lpcm_bits12`). | Rounds up to the next whole byte. |
| Packet description | Exactly one frame of the frame's bytes (`caf_bytes_per_packet`, `caf_frames_per_packet`). | Takes the declared sizes for its packets. |
| `pakt` | `UnsupportedFormat` (`caf_pakt`). | Trims the priming and remainder frames it declares. |
| `data` size -1 | `UnsupportedStreamingSize` by default; the rest of the input with `unknown_length` (`caf_data_size_unknown`). Opt-in as for WAV and AU. | Reads to the end of the input. |
| Data not whole frames | `InvalidFormat` (`caf_data_not_whole_frames`). | Decodes the whole frames. |
| Chunks after `data` | Read and validated sequentially; a second `data` is `InvalidCaf`. | Read only from a seekable file. |
| `chan` before `data` | Read (`caf_chunks_around_data`, mono). | The same. |
| `chan` after `data` | Skipped (`caf_chan_after_data`): a sequential reader has reported the stream by then. | Reads it from a seekable file, which `compare.py` records as a known difference (`quad` here). |
| `chan` too short for its descriptions | `InvalidFormat` (`caf_chan_descriptions_overflow`). | Keeps the layout and, on a seekable file, goes on after the chunk. |
| `info`, `kuki` | Skipped; no tags are read. | Reads the `info` strings as tags. |
| Duration | The frame count, exact: from the `data` size. | Estimated from the bit rate over the bytes after the data start, so chunks after `data` count as frames (`caf_chunks_around_data`: 10 for 4); none for empty `data`. |
| Sample rate above 192 kHz, more than 64 channels | `LimitExceeded` (`caf_rate_over_limit`, `caf_channels65`). | Accepted. |
| Muxing | Not supported (T22d is demux only). | Has a CAF muxer. |

## Provenance

`../generate.py` is an original project file (`LGPL-2.1-or-later`). The
fixture files and `manifest.zon` are data it generates; their sample values
are the other contracts' hand-picked values. No FFmpeg sample files or code
were used.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `caf_s16be_mono_8k` | accepted | 84 | accept: 1 channel, 8000 Hz, 8 frames | `lpcm`, big-endian 16-bit mono: the encoding afconvert writes by default. | `ec73b222a3935661c4c88bc08f61e87d9bbb2529dea98a875ef03fc601a6ff5c` |
| `caf_s16le_stereo_44k1` | accepted | 84 | accept: 2 channels, 44100 Hz, 4 frames | `lpcm` with the little-endian flag, stereo at 44.1 kHz. | `680a66dee23dd00865292392a7a2cc6165374c5075daa5bb7238b1cec98643b8` |
| `caf_s8_mono` | accepted | 76 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s8` | 8-bit `lpcm` is signed (FFmpeg passes the signed flag); stored as u8, offset by 128. | `0de54dae110b6d93457dae696b3ac76367fd23ce85ccbe9584078904c20fdb9c` |
| `caf_s24le_stereo_48k` | accepted | 92 | accept: 2 channels, 48000 Hz, 4 frames, `pcm_s24le` | 24-bit little-endian stereo at 48 kHz; stored as s32. | `a8e89e3a08f23642975c5bdeba48e6658e257a72fa94ad7e8c4176591cfff057` |
| `caf_s24be_mono` | accepted | 92 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s24be` | 24-bit big-endian. | `d3528e4892f96b9f523013d52a4049b10610b2ad9c316ddf88e77608c3935766` |
| `caf_s32be_mono` | accepted | 100 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s32be` | 32-bit big-endian. | `a768068b9f724eb61ab9921b0c119c2e8442229ac1c26420d0d22080fd7554c1` |
| `caf_s32le_mono` | accepted | 100 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s32le` | 32-bit little-endian. | `27b6f772bed8e1fdda89c923217dd4142bae3543cf4711ffb43c50f81c91c9d9` |
| `caf_s64be_mono` | accepted | 132 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s64be` | 64-bit big-endian integers. | `7e273d84b79beff9d796be8018432187340c5884be295e02d1c0c39ff17ab595` |
| `caf_s64le_mono` | accepted | 132 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_s64le` | 64-bit little-endian integers. | `1790e32d65b1d9b37d1e96768152b21fc35a27c06ec301cf8bbedbbd102ef5cd` |
| `caf_f32be_mono` | accepted | 100 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_f32be` | 32-bit float (`lpcm` with the float flag); every bit kept. | `5d288efb6dc6441edee0e113ab62fe6dd07c493dea944e5076aac34fa51db9e2` |
| `caf_f32le_mono` | accepted | 100 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_f32le` | 32-bit float, little-endian. | `6c4ceb1e7519a492b53fa77a80e899d0cf57f4de9b67ab0482e3f0f4e7d35182` |
| `caf_f64be_stereo_96k` | accepted | 132 | accept: 2 channels, 96000 Hz, 4 frames, `pcm_f64be` | 64-bit float stereo at 96 kHz. | `0b221fc593bead62195755065e77bf91e7a0acf325b0236edb40ea907a107a99` |
| `caf_f64le_mono` | accepted | 132 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_f64le` | 64-bit float, little-endian. | `5d34d7cf2e0bd3bc78a9193054a4d45850dfeb7d674655c864fcd2c311d95fab` |
| `caf_alaw_mono_8k` | accepted | 76 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_alaw` | Format ID `alaw`; decodes to s16. | `f4cf704ca46dd6b13b7199adeabddbf721278ae2df4c329fd724b99898953f8e` |
| `caf_ulaw_mono_8k` | accepted | 76 | accept: 1 channel, 8000 Hz, 8 frames, `pcm_mulaw` | Format ID `ulaw`; decodes to s16. | `10e9310a847fa4521267fae8c351ff7ff837540cad112e7379dc57e5c08c1aea` |
| `caf_empty_data` | accepted | 68 | accept: 1 channel, 8000 Hz, 0 frames | A `data` chunk of 4 bytes, its edit count only: 0 frames. | `e9ae4517e0b5818fd44002e96dff92a3476ce9ffdcd30b91179a5021410ed810` |
| `caf_chunks_around_data` | accepted | 167 | accept: mono (1 channel), 8000 Hz, 4 frames | `free`, `info` and `kuki` before `data` and `free` after it are skipped; `chan` before it, the mono layout tag, gives the layout (skipped before T23b). | `e14afe6c5a78f6e765603e684c1df35edb1231b551f1e9f38969220b4444f090` |
| `caf_rate_fraction` | accepted | 76 | accept: 1 channel, 8000 Hz, 4 frames | A rate of 8000.75 Hz is truncated to 8000, as FFmpeg's int conversion does. | `e2e5fb2eaf15f3843eb7b67d80f5389499888574123dc679b1bca12151ea3316` |
| `caf_edit_count` | accepted | 76 | accept: 1 channel, 8000 Hz, 4 frames | A nonzero edit count is skipped. | `e49571e5722dc411f0eda5ad59714f044df0570272440e8730f0f931719260bc` |
| `caf_data_size_unknown` | size | 76 | reject: `UnsupportedStreamingSize`; with `unknown_length`, accept: 1 channel, 8000 Hz, 4 frames | `data` size -1, as a writer that could not seek back leaves it: with `unknown_length` the data is the rest of the input. | `da3a4066c511124b113e0c92b044f74e12177113afd8a60c1d6d1edc7303cd39` |
| `caf_unknown_size_partial_frame` | size | 74 | reject: `UnsupportedStreamingSize`; with `unknown_length`, reject: `Truncated` | Size -1, stereo, ending after 1.5 frames. | `992a3901599298e6a4c7cb671dec96518cd320d55b5793c0465098b235630289` |
| `caf_empty_input` | header | 0 | reject: `Truncated`; not detected (probing picks no format) | No bytes at all. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `caf_bad_magic` | header | 76 | reject: `InvalidCaf`; not detected (probing picks no format) | Magic `cafe`. | `61b774a00e7dca7d6e83a97ebc4e0784f5bf9e0ad2f1027e16bb2b060fbd950b` |
| `caf_version2` | header | 76 | reject: `InvalidCaf`; not detected (probing picks no format) | File version 2: only version 1 exists. FFmpeg's probe rejects it, and its demuxer, forced, reads it. | `ed472a069cd2e8d9d64f97addd718bc1449cbcbc3f73b1f5dbfa4f378b3184b5` |
| `caf_desc_missing` | header | 120 | reject: `InvalidCaf`; not detected (probing picks no format) | The first chunk is `free`, not `desc`. | `a85e2086dce821db0d13bb9cc24a6eeb5198d05335085f33f680674f0369f664` |
| `caf_desc_size` | header | 80 | reject: `InvalidCaf`; not detected (probing picks no format) | A `desc` chunk of size 36. | `8a905b08b4cc593efff43e13159f83d88ca39180b6c7c2024e3be11c7890a11a` |
| `caf_truncated_desc` | header | 30 | reject: `Truncated` | Input ends inside `desc`. | `0cd83d6049419a1cf43ca97071d65fdef05e29a5a847eec37daf43d86e28b022` |
| `caf_rate_zero` | desc | 76 | reject: `InvalidFormat` | Sample rate 0. | `a9301540be36017de467dd8b8e54ab52c447462b61e7572470de57c107bece43` |
| `caf_rate_nan` | desc | 76 | reject: `InvalidFormat` | Sample rate NaN. | `cfea541b2c5dc386379ea76005866b04b9f38e781ab3e46a672a22dfe8adfca8` |
| `caf_rate_over_limit` | desc | 76 | reject: `LimitExceeded` | Sample rate 192001 Hz, above the default limit. | `2a5d8b713b1df443e0110e46732e9f588beefbe5967439a0cd2e70651dbb3026` |
| `caf_format_aac` | desc | 76 | reject: `UnsupportedFormat` | Format ID `aac ` waits for its decoder. | `cb7eb8b729d6d768b9b77ed36431c63b7ac7a38109b74a21807a029c05fa298a` |
| `caf_lpcm_bits12` | desc | 76 | reject: `UnsupportedFormat` | 12-bit `lpcm`: whole bytes only. FFmpeg rounds up to 16. | `631accfb6cd3e99c631add0fe8e606d9a56aec5d31b6413a9d210b998aad5532` |
| `caf_float_bits16` | desc | 76 | reject: `UnsupportedFormat` | A 16-bit float: no codec. | `6cf9714e077016654a77846638491d213fe79e4b6e4b6ab517fdbd7d397bff96` |
| `caf_channels0` | desc | 68 | reject: `InvalidFormat` | Zero channels. | `118207f3e9ad6439b26083f6a8e784e363248beff68d225fbba116022261a3bd` |
| `caf_channels3` | channels | 80 | accept: 3 channels, 8000 Hz, 2 frames | Three channels without `chan`: unspecified (rejected before T23b). | `0eaff576bb2c31e0365ff8c85b66ee028a3ec683067fdbf74dd264534aa0c879` |
| `caf_channels6` | channels | 92 | accept: 6 channels, 8000 Hz, 2 frames | Six channels without `chan`; FFmpeg's command line guesses 5.1 for them. | `05613e99004b968b09d817981756af81b995f7b4e236f596c9ad8de82ec0fc59` |
| `caf_channels64` | channels | 196 | accept: 64 channels, 8000 Hz, 1 frame | 64 channels, the default limit: one frame. | `5a30cb376a37ef5cc22fc56203c42c74ce7fe10760037e9645e84fd327e89fd0` |
| `caf_channels65` | channels | 198 | reject: `LimitExceeded` | 65 channels, above the default limit (FFmpeg reads them). | `101ff8debc8bb3b53460421f898b4e63992296d59f86a00823c58a57acb6f52f` |
| `caf_chan_5point1` | channels | 116 | accept: 5.1(side) (6 channels), 8000 Hz, 2 frames | `chan` with the tag MPEG_5_1_A (L, R, C, LFE, Ls, Rs): 5.1(side). | `bac1368e2a9b58b679631415ceb4fe23d0a2d9e74875d169ef6fc0878b4601cb` |
| `caf_chan_bitmap` | channels | 116 | accept: 5.1 (6 channels), 8000 Hz, 2 frames | `chan` with the 5.1 bitmap. | `0fae5b3f5b64acd36907a2c3483a6ea3c684bfe6b8b761ee39abd797b20af25f` |
| `caf_chan_descriptions` | channels | 148 | accept: 2 channels (FR+FL) (2 channels), 8000 Hz, 4 frames | `chan` with channel descriptions R, L: a custom order, as FFmpeg reads it. | `bcfa208943af797e857c672147c549c5ef7623dfcdc97130a4b53343768be229` |
| `caf_chan_count_mismatch` | channels | 108 | accept: 2 channels, 8000 Hz, 4 frames | `chan` with a four-channel tag on a stereo stream is ignored, as FFmpeg ignores it. | `89c7707b4e701a7a9023ff93fe42e2386f0ba0c1c3438860bbf9b355832ac21e` |
| `caf_chan_after_data` | channels | 108 | accept: 4 channels, 8000 Hz, 2 frames | `chan` after `data` is skipped: a sequential reader has reported the stream by then. FFmpeg reads it from a seekable file. | `2a71aaf89c74a38b8727c8e4fd200e703e0ca9ca2de7641b9ccf2496e39126d6` |
| `caf_chan_short` | channels | 96 | reject: `InvalidFormat` | A `chan` of 8 bytes, short of the 12 fixed ones: FFmpeg rejects it too. | `55ddb02017966df54a67f79ef31ca892506bcb94b55b41f07f6b24cffcccfaf4` |
| `caf_chan_size_negative` | channels | 88 | reject: `InvalidCaf` | A `chan` of size -1: FFmpeg rejects it too. | `439476f598c5fa45671c8bb131144f4c2339a3399677e4308bfd9839b9ac2d3c` |
| `caf_chan_descriptions_overflow` | channels | 128 | reject: `InvalidFormat` | A `chan` declaring two descriptions in room for one. FFmpeg keeps the layout and, on a seekable file, goes on after the chunk. | `1709e1f32496a8e112eb37eb12ce717f8dea31cb27d2808299fa6430cae1d990` |
| `caf_bytes_per_packet` | desc | 76 | reject: `InvalidFormat` | 4 bytes per packet for 16-bit mono. | `e5ad27068b706f49996bee6299e0f866ddb635e07d07674e2faefb233ea6804d` |
| `caf_frames_per_packet` | desc | 76 | reject: `InvalidFormat` | 2 frames per packet: PCM has one. | `2258c471efe5d6c3d8db2420af0abb989c2ba7b685f20c6ebee33c9dada9760e` |
| `caf_missing_data` | chunks | 52 | reject: `InvalidCaf` | `desc`, then the end of the input. | `2e9c02b3f9e0f6ac06cc7e0820aa4e4cad7f840bd939f2dbc87f25c313f79f72` |
| `caf_truncated_chunk_header` | chunks | 58 | reject: `Truncated` | Input ends inside a chunk header. | `ba43240ebc85b2d73d562a70ebe062c3ee6406609ef8c0e3af83aece6bd6386c` |
| `caf_chunk_size_negative` | chunks | 88 | reject: `InvalidCaf` | A `free` chunk of size -2. | `b77366fa72dbb617b0eb3e9614578822855ff8e7576548ceff3add1c71d3cc2c` |
| `caf_free_size_unknown` | chunks | 88 | reject: `InvalidCaf` | A `free` chunk of size -1: only `data` may have an unknown size. | `c61300014a71629ebc9448d3d8c96d3aece465abc17b7ba9a278d8b681bd558c` |
| `caf_pakt` | chunks | 112 | reject: `UnsupportedFormat` | A packet table, with which FFmpeg trims priming and remainder frames. | `8fbd751eb87fc391defd019426eb5ab78216d7b710fed4728340bcbfef8bb8be` |
| `caf_data_size_small` | data | 66 | reject: `InvalidCaf` | A `data` chunk of size 2, short of its edit count. | `a370d58fef034c70c6bcd965ab61d39f4c0ed444615b31c72f62713c76a22a72` |
| `caf_data_not_whole_frames` | data | 74 | reject: `InvalidFormat` | Stereo 16-bit data of 6 bytes. FFmpeg reads the whole frame. | `2415febfe0bc18ab3c6b5bfc3d385067ab2c16afdfcb31ed3163d361f69cc925` |
| `caf_truncated_data` | data | 73 | reject: `Truncated` | Input ends inside the samples. | `7dc97b8ed3b19730ec1916da957e04b915aec26443ea7bfc0fca5a00bbf3cc71` |
| `caf_second_data` | data | 100 | reject: `InvalidCaf` | A second `data` chunk after the first. | `ef84146520b9076a8bf0d6afb95fdf3740e4442bd8f7e0cad9cb06abb9e351bf` |
| `caf_trailing_partial_header` | data | 81 | reject: `Truncated` | 5 bytes after `data`: a cut chunk header. | `574756e2d4693fa5be28ea1c159f0d06542d0a1406873f9098cee80defec8875` |
<!-- END GENERATED FIXTURE TABLE -->
