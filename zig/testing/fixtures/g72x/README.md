# G.722 and G.726 fixtures

The G.722 and G.726 AU fixtures of TODO.md T31c, written by `generate.py`
(never edit them by hand), except the `g72x_ffmpeg_*` files, which are
FFmpeg's `g722` and `g726le` encoders and AU muxer's output, made by
[g72x_fixtures.sh](../../reference/g72x_fixtures.sh) from inputs
`generate.py` writes, committed and checked against the hashes it records.
The others carry pseudo-random codes under AU headers of every encoding
(24 for G.722; 23, 25, 26 and the private '7262' for 4-, 3-, 5- and 2-bit
G.726), headers of more than one channel (FFmpeg's decoders take the data
as one), data that ends inside a code, rates FFmpeg's encoders would not
write, an annotation, and the headers the port refuses. T22a's
`au_encoding_g726` is `g72x_au_encoding_23` here. What FFmpeg makes of
each, the stream ffprobe reports and the samples the ffmpeg program
decodes, is [g72x_au.txt](../../vectors/g72x_au.txt), printed by
[g72x_au_vectors.sh](../../reference/g72x_au_vectors.sh) from the pinned
build; in the table, the third column gives the port's result (yes, or its
error), which is FFmpeg's except where notes.md "G.722 and G.726" records
a difference. port.md's "AU contract" says which behavior the port
follows.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `g72x_au_encoding_23` | accepted | yes | T22a's `au_encoding_g726`: four zero bytes of 4-bit G.726 (encoding 23), rejected until T31c. |
| `g72x_g722_stereo_header` | accepted | yes | G.722 under a header of two channels: FFmpeg's decoder takes every byte as one channel, the duration counts two. |
| `g72x_g722_3ch_header` | accepted | yes | G.722 under three channels: a packet of one byte a block. |
| `g72x_g726_3_ch2` | accepted | yes | 3-bit G.726 under two channels: the decoder refuses them in avformat_find_stream_info, then decodes the data as one. |
| `g72x_7262_8ch` | accepted | yes | 2-bit G.726 ('7262') under eight channels: `block_align` 2. |
| `g72x_g726_5_partial` | accepted | yes | 5-bit G.726 whose last packet ends inside a code: its bits dropped. |
| `g72x_g726_4_16k` | accepted | yes | 4-bit G.726 at 16 kHz, which its decoder takes. |
| `g72x_g722_44k` | accepted | yes | G.722 at 44100 Hz: packets of a power of two of bytes. |
| `g72x_g726_2_one_byte` | accepted | yes | One byte of 2-bit G.726: four samples. |
| `g72x_g726_3_two_bytes` | accepted | yes | Two bytes of 3-bit G.726: five codes, one bit dropped. |
| `g72x_annotation` | accepted | yes | G.722 after a 16-byte annotation of zeros. |
| `g72x_unknown_size` | rejected | `UnsupportedStreamingSize` | G.722 of unknown length (data size 0xFFFFFFFF): refused by default, as for PCM AU. |
| `g72x_truncated` | rejected | `Truncated` | 3-bit G.726 whose data ends 1000 bytes before its size: `Truncated`, where FFmpeg decodes what is there. |
| `g72x_rate_over_limit` | rejected | `LimitExceeded` | G.722 at 200000 Hz, above the parser's limit. |
| `g72x_channels65` | rejected | `LimitExceeded` | 4-bit G.726 under 65 channels, above the parser's limit. |
| `g72x_ffmpeg_g722_16k` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 12000 tones samples at 16000 Hz, `-c:a g722`. |
| `g72x_ffmpeg_g722_trellis` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 9001 smooth samples at 16000 Hz, `-c:a g722 -trellis 5`. |
| `g72x_ffmpeg_g722_8k` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 5000 noise samples at 8000 Hz, `-c:a g722`. |
| `g72x_ffmpeg_g726_2` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 9000 tones samples at 8000 Hz, `-c:a g726le -code_size 2`. |
| `g72x_ffmpeg_g726_3` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 9001 smooth samples at 8000 Hz, `-c:a g726le -code_size 3`. |
| `g72x_ffmpeg_g726_4` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 8000 transients samples at 8000 Hz, `-c:a g726le`. |
| `g72x_ffmpeg_g726_5` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 7003 noise samples at 8000 Hz, `-c:a g726le -code_size 5`. |
| `g72x_ffmpeg_one_sample` | ffmpeg | yes | FFmpeg's encoder and AU muxer, 1 tones samples at 8000 Hz, `-c:a g726le -code_size 3`. |
<!-- END GENERATED FIXTURE TABLE -->
