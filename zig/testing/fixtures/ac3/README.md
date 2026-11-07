# AC-3 fixtures

The raw AC-3 fixtures of TODO.md T32a, written by `generate.py` (never edit
them by hand), except the `ac3_ffmpeg_*` files, which are FFmpeg's AC-3
encoder and raw muxer's output, made by
[ac3_fixtures.sh](../../reference/ac3_fixtures.sh) from inputs
`generate.py` writes, committed and checked against the hashes it records.
They cover every channel mode the encoder writes (mono to 3/2 with LFE,
and the center and LFE pair), the three sample rates, coupling in stereo
and 5.1, stereo without rematrixing, Dolby Surround and dialog
normalization, low bit rates and a stream of one frame. The others are
built from `ac3_ffmpeg_stereo_48k`: junk before the first frame or between
frames, the stream byte-swapped, the half- and quarter-rate bit stream ids
9 and 10 (each frame's CRC recomputed), damaged frames and a cut last
frame. What FFmpeg's demuxer, parser and decoder make of each, every packet
and decoded frame, is [ac3_decode.txt](../../vectors/ac3_decode.txt),
printed by [ac3_vectors.c](../../reference/ac3_vectors.c) from the pinned
build; in the table, the third column gives the port's result (yes, or
its error), which is FFmpeg's except where notes.md "AC-3" records a
difference.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `ac3_junk_prefix` | accepted | yes | 37 bytes of junk before the first frame: the probe's later starts, the decoder's first packet after the parser's resync. |
| `ac3_byteswapped` | accepted | yes | The stream with every 16-bit word swapped (sync word 0x770B): the probe, parser and decoder swap it back. |
| `ac3_half_rate` | accepted | yes | Bit stream id 9 in every frame (the CRC recomputed): 24 kHz, the bit allocation's shifted decays. |
| `ac3_quarter_rate` | accepted | yes | Bit stream id 10: 12 kHz. |
| `ac3_damaged` | accepted | yes | Bits flipped in the third and sixth frames: their CRCs fail the parser's check, the decoder decodes or conceals them. |
| `ac3_truncated` | accepted | yes | The last frame cut to half: an incomplete frame, concealed. |
| `ac3_junk_between_short` | accepted | yes | 10 bytes of junk after the fourth frame, which the decoder skips with it. |
| `ac3_junk_between_long` | accepted | yes | 40 bytes of junk after the fourth frame: the decoder finds no header after the frame and fails the packet, its frame lost. |
| `ac3_ffmpeg_stereo_48k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 9000 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a ac3 -b:a 192k`. |
| `ac3_ffmpeg_mono_32k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 6000 tones samples of 1 channels (mono) at 32000 Hz, `-c:a ac3 -b:a 64k`. |
| `ac3_ffmpeg_51side_44k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 6000 smooth samples of 6 channels (5.1(side)) at 44100 Hz, `-c:a ac3 -b:a 384k`. |
| `ac3_ffmpeg_51_48k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 tones samples of 6 channels (5.1) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_30` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 noise samples of 3 channels (3.0) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_30back` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 smooth samples of 3 channels (3.0(back)) at 44100 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_quad` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 tones samples of 4 channels (quad) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_40` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 smooth samples of 4 channels (4.0) at 32000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_21` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 noise samples of 3 channels (2.1) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_fclfe` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 3000 tones samples of 2 channels (FC+LFE) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_coupling` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 8000 smooth samples of 2 channels (stereo) at 44100 Hz, `-c:a ac3 -b:a 96k -channel_coupling 1 -cpl_start_band 1`. |
| `ac3_ffmpeg_51_coupling` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 noise samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a ac3 -b:a 192k -channel_coupling 1`. |
| `ac3_ffmpeg_no_rematrix` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 tones samples of 2 channels (stereo) at 48000 Hz, `-c:a ac3 -stereo_rematrixing 0`. |
| `ac3_ffmpeg_short` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 100 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a ac3`. |
| `ac3_ffmpeg_dsur` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 3000 tones samples of 2 channels (stereo) at 48000 Hz, `-c:a ac3 -dsur_mode 2 -dialnorm -20`. |
| `ac3_ffmpeg_lowrate` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 transients samples of 1 channels (mono) at 44100 Hz, `-c:a ac3 -b:a 32k`. |
<!-- END GENERATED FIXTURE TABLE -->
