# MP3 fixtures

The MPEG audio fixtures of TODO.md T29a, written by `generate.py` (never edit
them by hand): frames with valid headers of every MPEG version, layer, rate,
bit rate, padding and channel mode, their payloads arbitrary bytes (no 0xFF,
so no false sync inside a frame), as FFmpeg's demuxer and parser never decode
them; ID3v2 tags of versions 2.2 to 2.4, ID3v1 and APE tags, Xing, Info,
LAME, VBRI and iTunSMPB headers, junk, resyncs and damaged streams. What
FFmpeg makes of each, its streams, tags and every packet with its
timestamps, position and side data, is [mp3.txt](../../vectors/mp3.txt),
printed by [mp3_vectors.c](../../reference/mp3_vectors.c) from the pinned
libavformat; port.md's "MP3 contract" says which behavior the port follows.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `mp3_mpeg1_l3_stereo` | accepted | yes | MPEG-1 Layer III, 44100 Hz, 128 kbit/s stereo, every third frame padded. |
| `mp3_mpeg1_l3_mono_48k` | accepted | yes | MPEG-1 Layer III, 48000 Hz, 64 kbit/s mono. |
| `mp3_mpeg1_l3_32k_crc` | accepted | yes | MPEG-1 Layer III, 32000 Hz, 96 kbit/s joint stereo with the mode extension, frames protected by a CRC. |
| `mp3_mpeg2_l3_22k` | accepted | yes | MPEG-2 Layer III (LSF), 22050 Hz, 64 kbit/s stereo: 576 samples a frame. |
| `mp3_mpeg2_l3_16k_mono` | accepted | yes | MPEG-2 Layer III, 16000 Hz, 32 kbit/s mono. |
| `mp3_mpeg25_l3_8k` | accepted | yes | MPEG-2.5 Layer III, 8000 Hz, 16 kbit/s mono. |
| `mp3_mpeg25_l3_12k` | accepted | yes | MPEG-2.5 Layer III, 12000 Hz, 32 kbit/s stereo. |
| `mp3_vbr_bitrates` | accepted | yes | MPEG-1 Layer III frames of every bit rate, 32 to 320 kbit/s, in turn. |
| `mp2_layer2_48k` | accepted | yes | MPEG-1 Layer II, 48000 Hz, 192 kbit/s stereo: codec mp2. |
| `mp2_layer2_mpeg2_24k` | accepted | yes | MPEG-2 Layer II, 24000 Hz, 64 kbit/s mono. |
| `mp1_layer1_44k` | accepted | yes | MPEG-1 Layer I, 44100 Hz, 384 kbit/s stereo, padded slots of 4 bytes: codec mp1. |
| `mp1_layer1_mono_32k` | accepted | yes | MPEG-1 Layer I, 32000 Hz, 128 kbit/s mono. |
| `mp1_layer1_joint_crc` | accepted | yes | MPEG-1 Layer I, 48000 Hz, 256 kbit/s joint stereo, the mode extension (the intensity bound) cycling through 0 to 3, frames protected by a CRC. |
| `mp1_layer1_mpeg2_22k` | accepted | yes | MPEG-2 Layer I, 22050 Hz, 96 kbit/s stereo. |
| `mp2_layer2_44k_dual` | accepted | yes | MPEG-1 Layer II, 44100 Hz, 192 kbit/s dual channel: allocation table 1 (96 kbit/s a channel, not 48 kHz). |
| `mp2_layer2_44k_mono_48` | accepted | yes | MPEG-1 Layer II, 44100 Hz, 48 kbit/s mono: allocation table 2. |
| `mp2_layer2_32k_mono` | accepted | yes | MPEG-1 Layer II, 32000 Hz, 32 kbit/s mono: allocation table 3. |
| `mp2_layer2_joint_crc` | accepted | yes | MPEG-1 Layer II, 48000 Hz, 128 kbit/s joint stereo (allocation table 0), the mode extension cycling through 0 to 3, frames protected by a CRC. |
| `mp2_layer2_mpeg2_joint` | accepted | yes | MPEG-2 Layer II, 22050 Hz, 64 kbit/s joint stereo (allocation table 4), the mode extension cycling. |
| `mp2_layer2_mpeg25_8k` | accepted | yes | MPEG-2.5 Layer II, 8000 Hz, 32 kbit/s stereo. |
| `mp3_xing_lame` | accepted | yes | A Xing tag (frame count, byte count, TOC, quality) with LAME's extension (delay 576, padding 1104, radio and audiophile gains, a peak) and its valid CRC, then 30 VBR frames: the gapless start and end, the encoder tag and ReplayGain. |
| `mp3_info_lame` | accepted | yes | An Info tag (CBR) with LAME's extension and valid CRC, then 24 CBR frames. |
| `mp3_xing_bad_crc` | accepted | yes | A Xing tag whose LAME CRC is wrong: the delays still apply, but not the encoder tag or ReplayGain. |
| `mp3_xing_frames_only` | accepted | yes | A Xing tag with only a frame count and no LAME extension: no delays. |
| `mp3_xing_lavf` | accepted | yes | A Xing tag written by libavformat (encoder Lavf): its delays apply as LAME's. |
| `mp3_xing_size_mismatch` | accepted | yes | A Xing tag whose byte count is far below the file's: FFmpeg takes it for a concatenated file and drops the frame count. |
| `mp3_xing_mpeg2_mono` | accepted | yes | A Xing tag in an MPEG-2 mono frame (side information of 9 bytes). |
| `mp3_vbri` | accepted | yes | A Fraunhofer VBRI header: its frame and byte counts give the duration. |
| `mp3_itunsmpb` | accepted | yes | Gapless data in an iTunSMPB comment (an ID3v2.3 COMM frame), as Apple's encoders write it instead of LAME's tag. |
| `mp3_itunsmpb_bare_0x` | accepted | yes | An iTunSMPB comment whose priming field is a bare 0x: glibc's sscanf fails to match it, so FFmpeg ignores the tag and keeps no gapless counts. |
| `mp3_id3v23_tags` | accepted | yes | ID3v2.3: text frames in every encoding (ISO-8859-1, UTF-16 with either BOM), TYER, TDAT and TIME merged into a date, a numeric genre, TXXX, COMM frames with and without a language and descriptor, USLT, PRIV, ReplayGain in TXXX and an unread WXXX, with padding. |
| `mp3_id3v24_tags` | accepted | yes | ID3v2.4: an extended header, UTF-8 and UTF-16BE texts, TDRC, sort and compilation frames, a frame sized as v2.3 by mistake, a data length indicator, a compressed and an encrypted frame (both skipped), an unsynchronised frame, an empty frame, padding and a footer. |
| `mp3_id3v22_tags` | accepted | yes | ID3v2.2: three-letter frames (TT2, TP1, TAL, TCO, TYE, TRK, COM, TXX) and an empty one. |
| `mp3_id3v23_unsync` | accepted | yes | An ID3v2.3 tag with the unsynchronisation flag: zeros after 0xFF removed from each frame. |
| `mp3_two_id3v2` | accepted | yes | Two ID3v2 tags in a row: FFmpeg reads both. |
| `mp3_large_id3v2` | accepted | yes | A 6000-byte ID3v2 tag: probing skips it only once the probe buffer holds more than it, so FFmpeg probes again with more data. |
| `mp3_id3v1` | accepted | yes | An ID3v1 tag at the end (title, artist with trailing spaces, album, year, a track number, genre 13) and no ID3v2 tag: FFmpeg reads it; its parser drops the tag at the end. |
| `mp3_id3v1_and_v2` | accepted | yes | Both ID3v2 and ID3v1 tags: FFmpeg reads the ID3v1 tag only without ID3v2 tags. |
| `mp3_apic_chap` | accepted | yes | An ID3v2.3 tag with an APIC picture and a CHAP chapter (with its own TIT2): FFmpeg adds an attached-picture stream and a chapter, which the port does not model. |
| `mp3_ape_tag` | accepted | yes | An APEv2 tag (with its header) after the frames: the parser drops it at the end. |
| `mp3_ape_footer_only` | accepted | yes | An APEv2 tag without its header: the parser keeps its bytes as a last packet. |
| `mp3_junk_before` | damaged | yes | 300 bytes of junk before the first frame: the demuxer resyncs on two consecutive frames. |
| `mp3_zeros_before` | damaged | yes | 1000 zero bytes before the first frame: the probe skips leading zeros. |
| `mp3_junk_between` | damaged | yes | Junk between frames: the parser resyncs on the next frame header. |
| `mp3_truncated` | damaged | yes | The last frame cut short: the parser returns the partial frame at the end. |
| `mp3_rate_change` | damaged | yes | A sample-rate change mid-stream, 44100 to 48000 Hz. |
| `mp3_layer_change` | damaged | yes | Layer III frames followed by Layer II frames. |
| `mp3_header_emulation` | damaged | yes | Frames whose payload holds copies of the header: the probe stops counting a run where more than two emulate it. |
| `mp3_short` | damaged | yes | Three frames only: the probe's lowest scores. |
| `mp3_six_frames` | damaged | yes | Six frames: below the seven a first-run score needs. |
| `mp3_l3_long_stereo` | decoded | yes | Decodable MPEG-1 Layer III, 44100 Hz, 128 kbit/s stereo: long blocks, every Huffman table, both count1 tables, scfsi, preflag and scalefac_scale. |
| `mp3_l3_reservoir_mono` | decoded | yes | Decodable MPEG-1 Layer III, 48000 Hz, 64 kbit/s mono: frames alternately use 40% and all of the space left, so the bit reservoir carries data across frames. |
| `mp3_l3_window_switching` | decoded | yes | Decodable MPEG-1 Layer III stereo: long, start, short and stop windows in turn, some short granules mixed, with subblock gains. |
| `mp3_l3_short_ms` | decoded | yes | Decodable MPEG-1 Layer III, 32000 Hz, joint stereo with M/S only: short blocks. |
| `mp3_l3_intensity_ms` | decoded | yes | Decodable MPEG-1 Layer III joint stereo with intensity and M/S stereo: the right channel's upper bands empty. |
| `mp3_l3_intensity` | decoded | yes | Decodable MPEG-1 Layer III joint stereo with intensity stereo only, window switching. |
| `mp3_l3_mpeg2_22k_intensity` | decoded | yes | Decodable MPEG-2 Layer III, 22050 Hz, 64 kbit/s joint stereo with intensity stereo: the LSF intensity scalefactor partitions. |
| `mp3_l3_mpeg2_24k_switch` | decoded | yes | Decodable MPEG-2 Layer III, 24000 Hz stereo, window switching: the LSF short and mixed partitions. |
| `mp3_l3_mpeg2_16k_mono` | decoded | yes | Decodable MPEG-2 Layer III, 16000 Hz, 32 kbit/s mono, long blocks. |
| `mp3_l3_mpeg25_8k_switch` | decoded | yes | Decodable MPEG-2.5 Layer III, 8000 Hz mono, window switching: the 8 kHz regions and band tables (FFmpeg logs its switch-point request). |
| `mp3_l3_mpeg25_11k_ms` | decoded | yes | Decodable MPEG-2.5 Layer III, 11025 Hz joint stereo with M/S. |
| `mp3_l3_crc_linbits` | decoded | yes | Decodable MPEG-1 Layer III, 320 kbit/s, CRC-protected frames, values up to 3000 (escape tables with up to 13 linbits). |
| `mp3_l3_gapless` | decoded | yes | Decodable MPEG-1 Layer III after an Info tag with LAME's delays (576 and 1104): the decoder's output is trimmed at both ends. |
| `mp3_l3_bad_big_values` | decoded, damaged | yes | Decodable Layer III whose sixth frame declares 289 big-value pairs: that frame fails to decode. |
| `mp3_l3_bad_block_type` | decoded, damaged | yes | Decodable Layer III whose sixth frame switches windows with block type 0: that frame fails to decode. |
| `mp3_l3_long_part` | decoded, damaged | yes | Decodable Layer III whose fifth frame's last granule declares 400 bits more than its data: the Huffman decoding reads into the next frame's data. |
| `mp3_l3_short_part` | decoded, damaged | yes | Decodable Layer III whose fifth frame's first granule declares half its bits: the decoding stops early and the next granule starts mid-data. |
| `mp3_l3_reservoir_missing` | decoded, damaged | yes | Decodable Layer III whose first frame's main data begins 200 bytes before the stream: its granules decode as silence. |
| `mp3_l3_truncated` | decoded, damaged | yes | Decodable Layer III cut in its last frame's main data. |
| `mp3_free_format` | rejected | `INVALIDDATA` | Free-format frames (bit rate index 0), whose size FFmpeg's header decoding does not compute: no frame is recognized. |
| `mp3_no_frames` | rejected | `INVALIDDATA` | Arbitrary bytes and no frame. |
<!-- END GENERATED FIXTURE TABLE -->
