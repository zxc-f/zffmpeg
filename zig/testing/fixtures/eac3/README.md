# E-AC-3 fixtures

The raw E-AC-3 fixtures of TODO.md T32b, written by `generate.py` (never
edit them by hand), except the `eac3_ffmpeg_*` files, which are FFmpeg's
E-AC-3 encoder and raw muxer's output, made by
[ac3_fixtures.sh](../../reference/ac3_fixtures.sh) from inputs
`generate.py` writes, committed and checked against the hashes it records.
They cover the encoder's channel modes and rates, coupling, low bit rates,
an Lt/Rt preferred downmix and a stream of one frame; the others are built
from `eac3_ffmpeg_stereo_48k` (junk, byte-swapped, damaged, cut, a frame
of substream 1, a reduced sample rate, a dependent frame first) and an
AC-3 stream followed by E-AC-3, which the parser renames. FFmpeg's encoder
writes neither spectral extension, AHT nor dependent frames: those come
from the optional FATE samples compare.py reads. What FFmpeg's demuxer,
parser and decoder make of each, every packet and decoded frame, is
[eac3_decode.txt](../../vectors/eac3_decode.txt), printed by
[ac3_vectors.c](../../reference/ac3_vectors.c) from the pinned build; the
third column gives the port's result, which is FFmpeg's except where
notes.md "E-AC-3" records a difference.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `eac3_junk_prefix` | accepted | yes | 29 bytes of junk before the first frame. |
| `eac3_byteswapped` | accepted | yes | The stream with every 16-bit word swapped. |
| `eac3_damaged` | accepted | yes | Bits flipped in the second and fifth frames: decoded or concealed. |
| `eac3_truncated` | accepted | yes | The last frame cut to half: concealed. |
| `eac3_substream` | accepted | yes | The second frame of substream 1: the parser keeps it in the first frame's packet and the decoder's look for a dependent frame fails the packet (AC3_PARSE_ERROR_FRAME_TYPE). |
| `eac3_reduced_rate` | accepted | yes | The second frame at a reduced sample rate (fscod 3): AVERROR_PATCHWELCOME, its packet dropped. |
| `eac3_dependent_alone` | accepted | yes | The first frame made a dependent frame: ignored without an independent frame. |
| `eac3_after_ac3` | accepted | yes | Three AC-3 frames, then the E-AC-3 stream: the parser renames the codec E-AC-3 when it meets the first. |
| `eac3_ffmpeg_stereo_48k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 9000 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a eac3 -b:a 192k`. |
| `eac3_ffmpeg_mono_32k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 6000 tones samples of 1 channels (mono) at 32000 Hz, `-c:a eac3 -b:a 32k`. |
| `eac3_ffmpeg_51side_44k` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 6000 smooth samples of 6 channels (5.1(side)) at 44100 Hz, `-c:a eac3 -b:a 256k`. |
| `eac3_ffmpeg_51_coupling` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 noise samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a eac3 -b:a 96k -channel_coupling 1`. |
| `eac3_ffmpeg_30` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 tones samples of 3 channels (3.0) at 48000 Hz, `-c:a eac3`. |
| `eac3_ffmpeg_quad` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 7000 smooth samples of 4 channels (quad) at 44100 Hz, `-c:a eac3`. |
| `eac3_ffmpeg_lowrate` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 9000 transients samples of 2 channels (stereo) at 44100 Hz, `-c:a eac3 -b:a 32k`. |
| `eac3_ffmpeg_fclfe` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 4000 noise samples of 2 channels (FC+LFE) at 48000 Hz, `-c:a eac3`. |
| `eac3_ffmpeg_ltrt` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 5000 tones samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a eac3 -dmix_mode ltrt -ltrt_cmixlev 0.5 -ltrt_surmixlev 0.5`. |
| `eac3_ffmpeg_short` | ffmpeg | yes | FFmpeg's encoder and raw muxer, 100 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a eac3`. |
<!-- END GENERATED FIXTURE TABLE -->
