# ADPCM fixtures

The IMA WAV and Microsoft ADPCM WAV fixtures of TODO.md T31a, written by
`generate.py` (never edit them by hand), except the `adpcm_ffmpeg_*` files,
which are FFmpeg's encoders' output, made by
[adpcm_fixtures.sh](../../reference/adpcm_fixtures.sh) from inputs
`generate.py` writes, committed and checked against the hashes it records.
The others are built from the formats' descriptions: blocks of
pseudo-random bytes under valid headers (or invalid ones, where a fixture
says so), at every IMA WAV bit depth, with one to seven channels, odd and
tiny block sizes, partial last blocks, every rule of FFmpeg's demuxer for
the duration (`fact`, `ds64`, the data's size), an extensible `fmt `, and
the streams FFmpeg's decoders do not open. What FFmpeg makes of each, the
stream ffprobe reports and the samples the ffmpeg program decodes, is
[adpcm_wav.txt](../../vectors/adpcm_wav.txt), printed by
[adpcm_wav_vectors.sh](../../reference/adpcm_wav_vectors.sh) from the
pinned build; the "FFmpeg opens it" column says whether ffprobe opens the
stream and the ffmpeg program decodes it, else the port's error. port.md's
"ADPCM in WAV" says which behavior the port follows, and notes.md "ADPCM"
records where it differs.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `adpcm_ima_stereo` | accepted | yes | IMA WAV, stereo, 22050 Hz, six 1024-byte blocks and a fact count of their samples. |
| `adpcm_ima_2bit` | accepted | yes | IMA WAV at 2 bits a sample (FFmpeg's grouped codes), mono and stereo blocks of 520 bytes. |
| `adpcm_ima_3bit` | accepted | yes | IMA WAV at 3 bits a sample (FFmpeg's grouped codes), mono and stereo blocks of 1000 bytes. |
| `adpcm_ima_5bit` | accepted | yes | IMA WAV at 5 bits a sample (FFmpeg's grouped codes), mono and stereo blocks of 1288 bytes. |
| `adpcm_ima_partial_block` | accepted | yes | IMA WAV mono whose data ends 300 bytes into a block: a shorter last frame. |
| `adpcm_ima_odd_align` | accepted | yes | IMA WAV stereo with `block_align` 1030: each frame takes 1024 bytes, so the decoder starts its next frame 6 bytes early, as FFmpeg's does inside a packet. |
| `adpcm_ima_bad_step` | accepted | yes | IMA WAV blocks 2 and 5 of 8 with a step index past 88: FFmpeg's decoder fails those packets' frames, which the program drops. |
| `adpcm_ima_all_bad` | rejected | `DecodeErrorRate` | Every IMA WAV block with a bad step index: every decode fails, past the program's error rate. |
| `adpcm_ima_align_short` | rejected | `DecodeErrorRate` | IMA WAV stereo with `block_align` 6, shorter than its 8-byte header: no frame has a sample. |
| `adpcm_ima_bits8` | rejected | `UnsupportedFormat` | IMA WAV tag with 8 bits a sample: FFmpeg's adpcm_zork. |
| `adpcm_ima_bits6` | rejected | `UnsupportedFormat` | IMA WAV at 6 bits: the demuxer's stream, which FFmpeg's decoder does not open. |
| `adpcm_ima_3ch` | rejected | `UnsupportedFormat` | IMA WAV with three channels, which FFmpeg's decoder does not open. |
| `adpcm_ms_stereo` | accepted | yes | Microsoft ADPCM stereo, 44100 Hz, 1024-byte blocks with a fact count. |
| `adpcm_ms_mono_fmt16` | accepted | yes | Microsoft ADPCM mono in a 16-byte `fmt ` (no `cbSize`, no coefficients). |
| `adpcm_ms_6ch` | accepted | yes | Microsoft ADPCM in 5.1's six channels, a 256-byte block each: FFmpeg's demuxer multiplies `block_align` by the channels, and the decoder gives s16p. |
| `adpcm_ms_3ch` | accepted | yes | Microsoft ADPCM with three channels and 100-byte blocks. |
| `adpcm_ms_tiny_blocks` | accepted | yes | Microsoft ADPCM stereo with 13-byte blocks: one sample a frame, whose second header sample FFmpeg writes past it. |
| `adpcm_ms_bad_predictor` | accepted | yes | Microsoft ADPCM blocks 1 and 3 of 6 with a predictor index past 6. |
| `adpcm_ms_7ch` | rejected | `UnsupportedFormat` | Microsoft ADPCM with seven channels, which FFmpeg's decoder does not open. |
| `adpcm_ms_extensible` | accepted | yes | Microsoft ADPCM as the subformat of an extensible `fmt ` (96000 Hz), the coefficients after the extension, as FFmpeg's muxer writes above 48 kHz. |
| `adpcm_ima_fmt_garbage` | accepted | yes | IMA WAV whose `fmt ` declares `cbSize` 2 but holds 10 more bytes, which FFmpeg skips. |
| `adpcm_fact_all_channels` | accepted | yes | A fact count of every channel's samples (2 × 3 × 1017): the bit rate says so, and FFmpeg's demuxer divides it by the channels. |
| `adpcm_fact_wrong` | accepted | yes | A fact count far below the data's (10 samples for three blocks): FFmpeg ignores it and takes the duration from the data's size. |
| `adpcm_fact_zero_then_count` | accepted | yes | A fact count of 0, then a second fact chunk: FFmpeg reads the second. |
| `adpcm_no_fact` | accepted | yes | No fact chunk: the duration from the data's size at 4 bits a sample. |
| `adpcm_fact_wrong_byte_rate` | accepted | yes | A header byte rate the block size contradicts, which FFmpeg's demuxer replaces, with a fact count of every channel's samples. |
| `adpcm_rf64` | accepted | yes | Microsoft ADPCM in RF64, the sample count in `ds64`. |
| `adpcm_ms_large_packets` | accepted | yes | Microsoft ADPCM mono at 192000 Hz with 32-byte blocks: FFmpeg's demuxer reads a power of two of blocks (8192 bytes) a packet. |
| `adpcm_block_align_zero` | rejected | `UnsupportedFormat` | IMA WAV with `block_align` 0, which the port refuses (notes.md "ADPCM"). |
| `adpcm_fact_short` | rejected | `UnsupportedFormat` | A two-byte fact chunk, whose count FFmpeg reads from the bytes after it; the port refuses (notes.md "ADPCM"). |
| `adpcm_w64` | rejected | `UnsupportedFormat` | IMA WAV in Wave64, which the port does not read (notes.md "ADPCM"). |
| `adpcm_truncated` | rejected | `Truncated` | IMA WAV whose `data` declares four blocks and holds three. |
| `adpcm_ffmpeg_ima_stereo_44k` | ffmpeg | yes | FFmpeg's encoder, 30000 smooth samples of 2 channels at 44100 Hz, `-c:a adpcm_ima_wav`. |
| `adpcm_ffmpeg_ima_mono_8k_256` | ffmpeg | yes | FFmpeg's encoder, 9000 noise samples of 1 channels at 8000 Hz, `-c:a adpcm_ima_wav -block_size 256`. |
| `adpcm_ffmpeg_ima_trellis` | ffmpeg | yes | FFmpeg's encoder, 12000 tones samples of 2 channels at 22050 Hz, `-c:a adpcm_ima_wav -trellis 6 -block_size 512`. |
| `adpcm_ffmpeg_ima_96k` | ffmpeg | yes | FFmpeg's encoder, 20000 transients samples of 1 channels at 96000 Hz, `-c:a adpcm_ima_wav`. |
| `adpcm_ffmpeg_ms_stereo_44k` | ffmpeg | yes | FFmpeg's encoder, 30000 smooth samples of 2 channels at 44100 Hz, `-c:a adpcm_ms`. |
| `adpcm_ffmpeg_ms_mono_16k_8192` | ffmpeg | yes | FFmpeg's encoder, 40000 noise samples of 1 channels at 16000 Hz, `-c:a adpcm_ms -block_size 8192`. |
| `adpcm_ffmpeg_ms_trellis` | ffmpeg | yes | FFmpeg's encoder, 15000 tones samples of 2 channels at 32000 Hz, `-c:a adpcm_ms -trellis 5`. |
| `adpcm_ffmpeg_ms_mono_32` | ffmpeg | yes | FFmpeg's encoder, 3000 transients samples of 1 channels at 11025 Hz, `-c:a adpcm_ms -block_size 32`. |
| `adpcm_ffmpeg_ms_short` | ffmpeg | yes | FFmpeg's encoder, 100 smooth samples of 2 channels at 48000 Hz, `-c:a adpcm_ms`. |
<!-- END GENERATED FIXTURE TABLE -->
