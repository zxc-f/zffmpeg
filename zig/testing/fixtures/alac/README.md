# ALAC fixtures

The ALAC-in-CAF fixtures of TODO.md T31b, written by `generate.py` (never
edit them by hand), except the `alac_ffmpeg_*` files, which are FFmpeg's
ALAC encoder and CAF muxer's output, made by
[alac_fixtures.sh](../../reference/alac_fixtures.sh) from inputs
`generate.py` writes, committed and checked against the hashes it records
(FFmpeg's muxer puts the packet table after `data`). The others carry
ALAC's verbatim frames, which need no encoder, with the cookie and packet
table before or after `data`, old and new cookie styles, priming and
remainder frames, damaged packets, 20- and 32-bit cookies, five channels,
and the tables and streams FFmpeg's demuxer or decoder refuses. What
FFmpeg makes of each, the stream ffprobe reports and the samples the ffmpeg
program decodes, is [alac_caf.txt](../../vectors/alac_caf.txt), printed by
[alac_caf_vectors.sh](../../reference/alac_caf_vectors.sh) from the
pinned build; in the table, the third column gives the port's result (yes,
or its error), which is FFmpeg's except where notes.md "ALAC in CAF"
records a difference. port.md's "CAF contract" says which behavior the port
follows.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `alac_pakt_before_data` | accepted | yes | Stereo 16-bit verbatim frames, the cookie and packet table before `data`, as Apple's tools write them: read from a pipe too. |
| `alac_pakt_after_data` | accepted | yes | The same packets with the table after `data`, as FFmpeg's muxer writes it on a seekable output. |
| `alac_new_kuki` | accepted | yes | A new-style cookie (24 bytes, no `frma` atom), to which FFmpeg adds the first 12. |
| `alac_priming` | accepted | yes | 1000 priming frames: the first packet's skip-samples side data drops them. |
| `alac_remainder_cut` | accepted | yes | A remainder of 300 frames on a last frame of 900: its last 300 samples dropped. |
| `alac_damaged_packet` | accepted | yes | The second packet's element type is 4 (DSE), which FFmpeg's decoder does not decode: that packet dropped. |
| `alac_all_damaged` | rejected | `DecodeErrorRate` | Every packet with element type 2 (CCE): every decode fails. |
| `alac_no_end_tag` | accepted | yes | A last packet without its END element: "no end tag found", dropped. |
| `alac_20bit` | accepted | yes | A 20-bit cookie and verbatim frames: s32p, the samples shifted up 12 bits. |
| `alac_32bit` | accepted | yes | A 32-bit mono cookie and verbatim frames. |
| `alac_32bit_stereo` | rejected | `DecodeErrorRate` | 32-bit stereo: a CPE's 33 bits, which FFmpeg's decoder does not decode ("bps 33"). |
| `alac_5ch` | accepted | yes | Five channels (5.0): an SCE and two CPEs mapped by FFmpeg's offsets. |
| `alac_no_kuki` | rejected | `UnsupportedFormat` | No magic cookie: FFmpeg's decoder does not open ("extradata is too small"). |
| `alac_no_pakt` | rejected | `InvalidCaf` | No packet table: "Missing packet table". |
| `alac_9ch_cookie` | rejected | `UnsupportedFormat` | A cookie of nine channels, which FFmpeg's decoder does not open. |
| `alac_pakt_short` | rejected | `InvalidCaf` | A 20-byte packet table, shorter than its fields. |
| `alac_pakt_count_past_body` | rejected | `InvalidCaf` | A table declaring 1000 packets in 3 bytes of sizes. |
| `alac_zero_duration` | rejected | `InvalidCaf` | A table whose remainder cancels every frame: no duration, "Missing packet table". |
| `alac_packet_size_zero` | rejected | `InvalidCaf` | A table entry of 0 bytes, which read_packet refuses mid-stream. |
| `alac_data_past_table` | rejected | `InvalidCaf` | Ten bytes of data after the table's last packet. |
| `alac_table_past_data` | rejected | `InvalidCaf` | A last packet the table makes 50 bytes longer than the data holds. |
| `alac_constant_packets` | rejected | `UnsupportedFormat` | A desc with a constant packet size, which the port does not read (notes.md "ALAC in CAF"). |
| `alac_data_size_unknown` | rejected | `UnsupportedStreamingSize` | A `data` size of -1 after the table: unknown length, refused by default. |
| `alac_ffmpeg_stereo_44k` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 20000 smooth samples of 2 channels at 44100 Hz, 16 bits, `-c:a alac`. |
| `alac_ffmpeg_mono_8k` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 9000 tones samples of 1 channels at 8000 Hz, 16 bits, `-c:a alac`. |
| `alac_ffmpeg_stereo24_96k` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 12000 noise samples of 2 channels at 96000 Hz, 24 bits, `-c:a alac`. |
| `alac_ffmpeg_3ch` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 6000 smooth samples of 3 channels at 48000 Hz, 16 bits, `-c:a alac`. |
| `alac_ffmpeg_6ch` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 5000 tones samples of 6 channels at 48000 Hz, 16 bits, `-c:a alac`. |
| `alac_ffmpeg_8ch_24` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 4500 smooth samples of 8 channels at 48000 Hz, 24 bits, `-c:a alac`. |
| `alac_ffmpeg_level0` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 6000 transients samples of 2 channels at 44100 Hz, 16 bits, `-c:a alac -compression_level 0`. |
| `alac_ffmpeg_level1` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 9000 tones samples of 2 channels at 22050 Hz, 16 bits, `-c:a alac -compression_level 1`. |
| `alac_ffmpeg_orders` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 7000 smooth samples of 1 channels at 32000 Hz, 24 bits, `-c:a alac -min_prediction_order 1 -max_prediction_order 30`. |
| `alac_ffmpeg_one_sample` | ffmpeg | yes | FFmpeg's encoder and CAF muxer, 1 tones samples of 2 channels at 44100 Hz, 16 bits, `-c:a alac`. |
<!-- END GENERATED FIXTURE TABLE -->
