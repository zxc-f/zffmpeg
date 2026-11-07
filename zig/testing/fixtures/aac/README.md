# ADTS fixtures

The ADTS (raw AAC) fixtures of TODO.md T30a, written by `generate.py` (never
edit them by hand): frames with valid headers of every profile, sampling
index, channel configuration and raw data block count, with and without a
CRC word, their payloads arbitrary bytes (no 0xFF, so no false sync inside a
frame), as FFmpeg's demuxer and parser never decode them without a decoder;
ID3v2 tags before and between frames, ID3v1 and APE tags at the end, junk,
resyncs, damaged headers and streams FFmpeg refuses. What FFmpeg makes of
each, its streams, tags and every packet with its position and flags, is
[aac.txt](../../vectors/aac.txt), printed by
[mp3_vectors.c](../../reference/mp3_vectors.c) from the pinned libavformat;
port.md's "ADTS contract" says which behavior the port follows.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `aac_lc_stereo_44k` | accepted | yes | AAC LC, 44100 Hz, stereo, 40 frames of varied lengths. |
| `aac_mono_48k_crc` | accepted | yes | AAC LC, 48000 Hz, mono, every frame protected by a CRC word. |
| `aac_main_96k` | accepted | yes | AAC Main (profile 0), 96000 Hz: the largest rates' bit rates. |
| `aac_ssr_8k_6ch` | accepted | yes | AAC SSR (profile 2), 8000 Hz, channel configuration 6 (5.1). |
| `aac_ltp_7350_8ch` | accepted | yes | AAC LTP (profile 3), 7350 Hz (index 12), channel configuration 7 (eight). |
| `aac_four_blocks` | accepted | yes | Four raw data blocks a frame (4096 samples), 22050 Hz. |
| `aac_pce_mpeg2` | accepted | yes | Channel configuration 0 (a PCE in the payload) and the MPEG-2 ID bit, 16000 Hz. |
| `aac_many_frames` | accepted | yes | 150 short frames after 40 junk bytes: the probe's run from a later position (over 100 frames, score 50). |
| `aac_junk_before` | accepted | yes | Junk before the first frame, which the open's resync skips. |
| `aac_junk_between` | accepted | yes | Junk between frames: the next read is no header, its 10 bytes no ID3v2 tag, and the resync skips to the next frame. |
| `aac_short_junk_between` | accepted | yes | Four junk bytes between frames: the resync starts after the 10 bytes read, inside the next frame's header, and skips that frame too. |
| `aac_id3v2_leading` | accepted | yes | An ID3v2.3 tag before the frames: the format's tags. |
| `aac_id3v2_between` | accepted | yes | An ID3v2 tag between frames, which the demuxer reads into the format's tags. |
| `aac_id3v1` | accepted | yes | An ID3v1 tag at the end: the format's tags; the resync at it ends the stream. |
| `aac_id3v2_and_id3v1` | accepted | yes | ID3v2 at the start and ID3v1 at the end: the demuxer's ID3v1 tags win, and avformat_open_input discards the ID3v2 ones. |
| `aac_ape_tag` | accepted | yes | ID3v2 at the start and an APEv2 tag (with a header) at the end: APE's tags win. |
| `aac_ape_binary` | accepted | yes | An APEv2 tag with a cover-art and an other binary item between text items. |
| `aac_ape_fields_past_end` | accepted | yes | An APEv2 tag declaring more items than it holds: the first missing item reads zeros at the end and fails. |
| `aac_bad_rate_index` | accepted | yes | Frames whose sampling index is 13 (reserved) between good ones: the demuxer keeps them, the parser finds no header there and joins them to the frame before. |
| `aac_length_short` | accepted | yes | A frame whose header claims 40 bytes fewer than it has: the next read lands in its payload and resyncs. |
| `aac_truncated` | accepted | yes | The last frame cut short: the demuxer's packet holds what remains. |
| `aac_header_at_end` | accepted | yes | Five bytes of a header at the end: a short read, AVERROR_INVALIDDATA. |
| `aac_frame_length_6` | accepted | yes | A frame header claiming 6 bytes after 12 frames: AVERROR_INVALIDDATA there. |
| `aac_probe_one_frame` | accepted | yes | One frame, then junk: the probe scores 1, the extension 1, and the open finds the frame. |
| `aac_three_frames_late` | accepted | yes | Junk, then three frames at the end of the probe buffer: score 25. |
| `aac_no_sync` | rejected | `EOF` | No sync word: the open's resync reaches the end (AVERROR_EOF). |
| `aac_id3v2_only` | rejected | `EOF` | An ID3v2 tag and nothing after it. |
| `aac_ffmpeg_lc_44k_stereo` | ffmpeg | yes | FFmpeg's AAC encoder, 30000 smooth samples of 2 channels at 44100 Hz, `-c:a aac`; decoded by the T30b oracle. |
| `aac_ffmpeg_mono_8k` | ffmpeg | yes | FFmpeg's AAC encoder, 8000 smooth samples of 1 channels at 8000 Hz, `-c:a aac -b:a 24k`; decoded by the T30b oracle. |
| `aac_ffmpeg_48k_64k` | ffmpeg | yes | FFmpeg's AAC encoder, 20000 tones samples of 2 channels at 48000 Hz, `-c:a aac -b:a 64k`; decoded by the T30b oracle. |
| `aac_ffmpeg_96k_256k` | ffmpeg | yes | FFmpeg's AAC encoder, 20000 smooth samples of 2 channels at 96000 Hz, `-c:a aac -b:a 256k`; decoded by the T30b oracle. |
| `aac_ffmpeg_transients` | ffmpeg | yes | FFmpeg's AAC encoder, 30000 transients samples of 2 channels at 44100 Hz, `-c:a aac`; decoded by the T30b oracle. |
| `aac_ffmpeg_pns_22k` | ffmpeg | yes | FFmpeg's AAC encoder, 15000 noise samples of 1 channels at 22050 Hz, `-c:a aac -b:a 32k -aac_pns 1`; decoded by the T30b oracle. |
| `aac_ffmpeg_is_ms` | ffmpeg | yes | FFmpeg's AAC encoder, 20000 tones samples of 2 channels at 44100 Hz, `-c:a aac -b:a 64k -aac_is 1 -aac_ms 1`; decoded by the T30b oracle. |
| `aac_ffmpeg_fast_32k` | ffmpeg | yes | FFmpeg's AAC encoder, 15000 smooth samples of 2 channels at 32000 Hz, `-c:a aac -aac_coder fast`; decoded by the T30b oracle. |
| `aac_ffmpeg_5point1` | ffmpeg | yes | FFmpeg's AAC encoder, 10000 smooth samples of 6 channels at 48000 Hz, `-c:a aac`; decoded by the T30b oracle. |
| `aac_ffmpeg_7point1_wide` | ffmpeg | yes | FFmpeg's AAC encoder, 8000 tones samples of 8 channels at 48000 Hz, `-c:a aac -ch_layout 7.1(wide)`; decoded by the T30b oracle. |
| `aac_ffmpeg_short` | ffmpeg | yes | FFmpeg's AAC encoder, 700 smooth samples of 2 channels at 44100 Hz, `-c:a aac`; decoded by the T30b oracle. |
<!-- END GENERATED FIXTURE TABLE -->
