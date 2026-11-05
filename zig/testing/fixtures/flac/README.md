# FLAC fixtures: the FLAC contract

This is the canonical fixture contract for the
[FLAC contract](../../../../port.md#flac-contract) (TODO.md T26a, T26b):
native and headerless FLAC at every sample size, read only. Every rule has at least one named
fixture here with its expected result. The oracle for every fixture is
[../../vectors/flac.txt](../../vectors/flac.txt), printed by
[../../reference/flac_vectors.c](../../reference/flac_vectors.c) from the
pinned FFmpeg's libavformat and libavcodec: the stream, each packet, each
decoded frame and each decoding error. The WAV contract and its shared
conventions are in [../README.md](../README.md).

## Files and commands

| Path | Role |
| --- | --- |
| `../generate.py` | A FLAC writer built from the format's description, independently of FFmpeg and the port; writes every fixture but the FFmpeg-made ones, this directory's manifest and the table below. |
| `../../reference/flac_fixtures.sh` | Makes the `flac_ffmpeg_*` fixtures with the reference build's FLAC encoder from inputs `generate.py --flac-input` writes. |
| `<name>.flac` | The fixture files. |
| `manifest.zon` | Expected results, imported by `zig/testing/fixtures.zig` as `fixtures.flac.all`. |
| `README.md` | This contract; the table at the end is generated. |

Change fixtures only in `generate.py`, then run
`python3 zig/testing/fixtures/generate.py`; `--check` fails when any output is
stale or an FFmpeg-made file differs from its recorded hash. The FFmpeg-made
files are committed rather than remade in CI, because the encoder's
floating-point analysis is not part of any contract; after remaking one, record
the printed hash in `generate.py`'s `FLAC_FFMPEG` table.

## Expected results

An accepted fixture records its channel count, rate, sample size, the
samples per channel the decoder gives and the SHA-256 of those samples as
FFmpeg outputs them (interleaved little-endian s16 up to 16 bits, else s32,
each shifted to the top of its storage): the samples `generate.py` encoded,
or the FFmpeg-made fixture's input. It also records the format tags ffprobe
reports, modeled independently of FFmpeg from its documented behavior, and
whether STREAMINFO's MD5 matches. A rejected fixture records the error the demuxer returns
before any packet. A damaged fixture records neither: what FFmpeg's parser
and decoder make of it, packet by packet, is the oracle's.

## Structure

`fLaC`, then metadata blocks: a byte with the last-block flag (bit 7) and the
type, a 24-bit big-endian size and the body. STREAMINFO (type 0, 34 bytes)
comes once, before every block but SEEKTABLE (3), CUESHEET (5) and PICTURE
(6); otherwise, or with another size, `InvalidFlac`. VORBIS_COMMENT (4)
holds the tags; the others are skipped. The input ending inside a block is
`Truncated`. Input without `fLaC` is FFmpeg's headerless mode, read from its
first frame.

STREAMINFO: minimum and maximum block sizes (16 bits each; a maximum below
16 is `InvalidFlac`), minimum and maximum frame sizes (24 bits each), the rate
(20 bits; 0 defers it to the frames), channels minus one (3 bits), bits per
sample minus one (5 bits; below 4 is `InvalidFlac`), the sample count (36
bits, the duration when nonzero) and the MD5.

## Frames

Each frame is a header (a 14-bit sync code, the blocking strategy, block size,
rate, channel assignment and sample size codes, a reserved bit, the frame
number, or with variable blocking the first sample's number, in FLAC's
extended UTF-8, the optional 8- or 16-bit size and rate, and a CRC-8), one
subframe per channel, zero padding to a byte and a CRC-16. The packets are
FFmpeg's parser's (port.md), so a frame's validity is decided as FFmpeg's
decoder decides it, packet by packet; the CRC-16 is not checked. A sample
size code of 0 defers to STREAMINFO.

Subframes: a zero bit, the type (constant, verbatim, fixed of order 0 to 4,
LPC of order 1 to 32), the wasted-bits flag with a unary count, then the
samples. The side channel of left/side, right/side and mid/side stereo has
one bit more, 33 for 32-bit samples. LPC subframes have warm-up samples, a
4-bit precision (15 is invalid), a 5-bit signed shift (negative is invalid)
and the coefficients, the latest sample's first. Residuals use 4-bit
(method 0) or 5-bit (method 1) Rice parameters per partition, all ones
escaping to a 5-bit raw sample size.

## Decisions

- The decoder outputs FFmpeg's packed s16 or s32, each sample shifted to the
  top of its storage, as FFmpeg's does with the default request.
- Damaged input follows FFmpeg exactly, including a valid frame its parser
  drops after junk (`flac_junk_between_frames`) and mid-stream changes of
  the channels or rate (`flac_channel_change`, `flac_rate_change`).
- PICTURE and CUESHEET are kept as data in `flac.Info`, not as the
  attached-picture stream and chapters FFmpeg makes of them: the port has no
  video streams or chapters yet.
- Converting (`av.convert`, zffmpeg) needs the decoded samples to equal
  STREAMINFO's count and its parameters to stay, which the output header
  holds before them (`FrameCountMismatch`, `UnsupportedFormat`), and a count
  for any output with a header: FFmpeg rewrites a seekable output's header.
  Raw PCM output has no header to hold the count and takes the decoded
  samples, as FFmpeg's does.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Made by | Expected | Rule |
| --- | --- | --- | --- | --- |
| `flac_constant_mono_8k` | accepted | generate.py | 1 ch, 8000 Hz, 256 frames | Constant subframes, 64-sample frames (an 8-bit size at the header's end). |
| `flac_verbatim_stereo_44k1` | accepted | generate.py | 2 ch, 44100 Hz, 500 frames | Verbatim subframes, independent channels, 192-sample frames; the last frame shorter (a 16-bit size). |
| `flac_fixed_orders_mono` | accepted | generate.py | 1 ch, 44100 Hz, 2880 frames | Fixed predictors of orders 0 to 4, one per 576-sample frame, partition orders 0 to 4. |
| `flac_lpc_orders_mono` | accepted | generate.py | 1 ch, 44100 Hz, 16384 frames | LPC subframes of orders 1, 8, 12 and 32, one per 4096-sample frame, with 12-bit coefficients and partition orders 0, 3, 8 and 6. |
| `flac_lpc_precision` | accepted | generate.py | 2 ch, 48000 Hz, 1152 frames | LPC of order 8 with 15-bit coefficients on the 17-bit side channel (the 64-bit prediction path) and 5-bit coefficients on the mid channel. |
| `flac_lpc_zero_shift` | accepted | generate.py | 1 ch, 32000 Hz, 576 frames | LPC of order 2 with given coefficients 2 and -1 and a shift of 0. |
| `flac_left_side` | accepted | generate.py | 2 ch, 44100 Hz, 1152 frames | Stereo as left/side: the side channel has 17 bits. |
| `flac_right_side` | accepted | generate.py | 2 ch, 44100 Hz, 1152 frames | Stereo as right/side: the side channel has 17 bits. |
| `flac_mid_side` | accepted | generate.py | 2 ch, 44100 Hz, 1152 frames | Stereo as mid/side: the side channel has 17 bits. |
| `flac_rice_escape` | accepted | generate.py | 1 ch, 22050 Hz, 576 frames | A residual partition coded raw (Rice escape) beside Rice-coded ones. |
| `flac_rice2_params` | accepted | generate.py | 1 ch, 48000 Hz, 576 frames | Rice coding with 5-bit parameters (method 1), one above 14. |
| `flac_wasted_bits` | accepted | generate.py | 1 ch, 16000 Hz, 576 frames | Samples that are multiples of 4, with two wasted bits. |
| `flac_many_frames` | accepted | generate.py | 1 ch, 8000 Hz, 4800 frames | 300 frames of 16 samples: frame numbers past 127 take two UTF-8 bytes. |
| `flac_six_channels_48k` | accepted | generate.py | 6 ch, 48000 Hz, 256 frames | Six independent channels; a 256-sample block (code 8). |
| `flac_rate_khz` | accepted | generate.py | 1 ch, 11000 Hz, 192 frames | A rate in kHz (code 12). |
| `flac_rate_hz` | accepted | generate.py | 1 ch, 12345 Hz, 192 frames | A rate in Hz (code 13). |
| `flac_rate_tens` | accepted | generate.py | 1 ch, 50000 Hz, 192 frames | A rate in tens of Hz (code 14). |
| `flac_rate_streaminfo` | accepted | generate.py | 1 ch, 37800 Hz, 192 frames | The rate from STREAMINFO (code 0). |
| `flac_metadata_blocks` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | PADDING, APPLICATION and an unknown block before the frames, skipped. |
| `flac_corrupt_frame_data` | damaged | generate.py | FFmpeg's result (flac_vectors.c) | The second frame's data damaged: its CRC-16 fails. |
| `flac_junk_between_frames` | damaged | generate.py | FFmpeg's result (flac_vectors.c) | Junk with false sync codes between the first two frames. |
| `flac_bps8_mono` | accepted | generate.py | 1 ch, 8000 Hz, 1152 frames | 8-bit samples, the header's code 1: s16 output shifted by 8. |
| `flac_bps12_left_side` | accepted | generate.py | 2 ch, 22050 Hz, 1152 frames | 12-bit left/side stereo (a 13-bit side channel). |
| `flac_bps20_lpc` | accepted | generate.py | 1 ch, 44100 Hz, 1152 frames | 20-bit samples with LPC of order 8: s32 output shifted by 12. |
| `flac_bps24_mid_side` | accepted | generate.py | 2 ch, 48000 Hz, 1152 frames | 24-bit mid/side with LPC: a 25-bit side channel on the 64-bit prediction path. |
| `flac_bps32_left_side_fixed` | accepted | generate.py | 2 ch, 96000 Hz, 384 frames | 32-bit left/side: a 33-bit side channel with a fixed predictor. |
| `flac_bps32_right_side_lpc` | accepted | generate.py | 2 ch, 96000 Hz, 384 frames | 32-bit right/side: a 33-bit side channel with LPC. |
| `flac_bps32_mid_side_verbatim` | accepted | generate.py | 2 ch, 44100 Hz, 128 frames | 32-bit mid/side, verbatim: a 33-bit side channel read raw. |
| `flac_bps32_wasted_bits` | accepted | generate.py | 1 ch, 32000 Hz, 256 frames | 32-bit samples with three wasted bits. |
| `flac_bps4_mono` | accepted | generate.py | 1 ch, 8000 Hz, 384 frames | 4-bit samples: the header defers the size to STREAMINFO (code 0). |
| `flac_bps10_stereo` | accepted | generate.py | 2 ch, 16000 Hz, 384 frames | 10-bit independent stereo, the size from STREAMINFO. |
| `flac_bps28_lpc` | accepted | generate.py | 1 ch, 48000 Hz, 512 frames | 28-bit samples with LPC, the size from STREAMINFO. |
| `flac_variable_blocksize` | accepted | generate.py | 2 ch, 44100 Hz, 1715 frames | Variable blocking: frames of 100, 576, 32, 1000 and 7 samples, each numbered by its first sample. |
| `flac_vorbis_comment` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | VORBIS_COMMENT: tags, a repeated key joined with ';', FFmpeg's renamings, entries without a key or value skipped. |
| `flac_vorbis_comment_truncated` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | VORBIS_COMMENT claiming more comments than it holds: the ones present are read. |
| `flac_seektable` | accepted | generate.py | 1 ch, 44100 Hz, 1152 frames | A SEEKTABLE with two points and a placeholder before the frames. |
| `flac_picture` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | A PICTURE block (a front cover in PNG) and PADDING. |
| `flac_cuesheet` | accepted | generate.py | 1 ch, 44100 Hz, 1152 frames | A CUESHEET of two tracks and the lead-out: FFmpeg's chapters. |
| `flac_md5_match` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | STREAMINFO's MD5 matches the samples. |
| `flac_md5_mismatch` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | STREAMINFO's MD5 does not match: decoding is unaffected; verification fails. |
| `flac_streaminfo_rate0` | accepted | generate.py | 1 ch, 22050 Hz, 576 frames | STREAMINFO's rate is 0: the frames give it. |
| `flac_no_total` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | STREAMINFO without a sample count. |
| `flac_headerless` | accepted | generate.py | 1 ch, 44100 Hz, 576 frames | Frames without fLaC or metadata: FFmpeg's headerless mode. |
| `flac_headerless_mid_side` | accepted | generate.py | 2 ch, 44100 Hz, 1152 frames | Headerless mid/side frames: raw_flac_probe accepts channel code 10. |
| `flac_channel_change` | damaged | generate.py | FFmpeg's result (flac_vectors.c) | Mono, then a stereo frame: FFmpeg follows the change. |
| `flac_rate_change` | damaged | generate.py | FFmpeg's result (flac_vectors.c) | 44.1 kHz, then a 48 kHz frame: FFmpeg follows the change. |
| `flac_bps24` | accepted | generate.py | 1 ch, 44100 Hz, 0 frames | 24-bit STREAMINFO and no frames: an empty stream. |
| `flac_bps3` | rejected | generate.py | `InvalidFlac` | STREAMINFO's sample size of 3 bits, below FLAC's 4. |
| `flac_second_streaminfo` | rejected | generate.py | `InvalidFlac` | A second STREAMINFO. |
| `flac_no_streaminfo` | rejected | generate.py | `InvalidFlac` | The first block is PADDING: STREAMINFO must come first. |
| `flac_streaminfo_short` | rejected | generate.py | `InvalidFlac` | STREAMINFO of 33 bytes. |
| `flac_truncated_metadata` | rejected | generate.py | `Truncated` | The file ends inside STREAMINFO. |
| `flac_ffmpeg_level0_stereo` | ffmpeg | ffmpeg | 2 ch, 44100 Hz, 9216 frames | FFmpeg's encoder, `-compression_level 0 -frame_size 1152`; VORBIS_COMMENT and PADDING blocks. |
| `flac_ffmpeg_level5_stereo` | ffmpeg | ffmpeg | 2 ch, 44100 Hz, 9216 frames | FFmpeg's encoder, `-compression_level 5 -frame_size 1152`; VORBIS_COMMENT and PADDING blocks. |
| `flac_ffmpeg_level8_mono` | ffmpeg | ffmpeg | 1 ch, 8000 Hz, 4000 frames | FFmpeg's encoder, `-compression_level 8`; VORBIS_COMMENT and PADDING blocks. |
| `flac_ffmpeg_level12_stereo` | ffmpeg | ffmpeg | 2 ch, 48000 Hz, 6000 frames | FFmpeg's encoder, `-compression_level 12 -frame_size 2000`; VORBIS_COMMENT and PADDING blocks. |
| `flac_ffmpeg_lpc_orders` | ffmpeg | ffmpeg | 1 ch, 44100 Hz, 8192 frames | FFmpeg's encoder, `-compression_level 12 -lpc_type levinson -min_prediction_order 1 -max_prediction_order 32 -frame_size 512`; VORBIS_COMMENT and PADDING blocks. |
<!-- END GENERATED FIXTURE TABLE -->
