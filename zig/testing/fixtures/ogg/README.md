# Ogg fixtures

The Ogg fixtures of TODO.md T27a, written by `generate.py` (never edit them by
hand): pages with Ogg's CRC-32, the FLAC, Opus and Vorbis mappings (the
Vorbis setup header carrying only the mode table FFmpeg's `vorbis_parser.c`
reads), and multiplexed, chained and damaged streams. What FFmpeg makes of
each, its streams and every packet with its timestamps, position and side
data, is [ogg.txt](../../vectors/ogg.txt), printed by
[ogg_vectors.c](../../reference/ogg_vectors.c) from the pinned libavformat;
port.md's "Ogg contract" says which behavior the port follows.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | FFmpeg opens it | Rule |
| --- | --- | --- | --- |
| `ogg_flac_stereo` | accepted | yes | FLAC in Ogg (the 0x7F FLAC mapping): STREAMINFO and a VORBIS_COMMENT as headers, one 576-sample frame per page. |
| `ogg_flac_packed_pages` | accepted | yes | FLAC frames, four to a page; a page's granule is its last frame's end. |
| `ogg_opus_stereo` | accepted | yes | Opus: OpusHead (pre-skip 312) and OpusTags, then 20 ms CELT packets four to a page; the EOS page's granule ends the stream exactly. |
| `ogg_opus_end_trim` | accepted | yes | Opus whose EOS granule falls inside the last packet: FFmpeg trims its end (skip-samples side data). |
| `ogg_opus_frame_counts` | accepted | yes | Opus TOC frame counts 1, 2 (codes 1 and 2) and code 3 with a count byte, and configurations of 2.5 to 60 ms. |
| `ogg_opus_silk` | accepted | yes | Opus SILK packets of random bytes (any bytes decode): narrow, medium and wide band, 10 to 60 ms, mono and stereo, frame count codes 0, 1 and 3, CELT packets between and frames large enough to carry redundancy (T28b). |
| `ogg_opus_hybrid` | accepted | yes | Opus hybrid packets of random bytes: super-wide and full band, 10 and 20 ms, mono and stereo, frame count code 3, redundancy frames before and after the frame, SILK and CELT packets between (T28c). |
| `ogg_opus_multistream` | accepted | yes | Opus 5.1 (mapping family 1): four streams, two coupled, each packet's streams self-delimited but the last, their modes and SILK rates mixed, so their delays differ (FFmpeg's sync buffers, T28c). |
| `ogg_opus_mapped` | accepted | yes | Opus of mapping family 255 with a gain of -3 dB: a silenced channel, a channel copying another (the gain applied twice, as FFmpeg's), and a stream mapped to no channel (T28c). |
| `ogg_vorbis_stereo` | accepted | yes | Vorbis: identification, comment and a setup header whose mode table (a short and a long mode) the parser reads; packet durations from the block sizes, four packets to a page. |
| `ogg_vorbis_granule_zero` | accepted | yes | Vorbis data pages whose granule is 0: FFmpeg drops their timestamps (trac ticket 3710). |
| `ogg_multiplexed` | accepted | yes | Two logical streams, FLAC and Opus, their BOS pages first, then pages interleaved. |
| `ogg_chained_opus` | accepted | yes | Two Opus streams one after the other (a chain): the second replaces the first, its first packet without timestamps. |
| `ogg_packet_spanning_pages` | accepted | yes | A 700-byte FLAC frame continued across pages of at most 2 segments. |
| `ogg_junk_before_first_page` | damaged | yes | 64 zero bytes before the first page: no probe scores it, so detection falls back on the .ogg extension, and the demuxer resyncs on the capture pattern. |
| `ogg_bad_crc_page` | damaged | yes | A data page with a wrong CRC: FFmpeg skips it and resyncs on the next page. |
| `ogg_version1_page` | damaged | yes | A data page of stream structure version 1 (with a valid CRC): FFmpeg skips it. |
| `ogg_lost_continued_page` | damaged | yes | The first page of a packet spanning pages is lost: the next page starts with a continuation, which FFmpeg discards. |
| `ogg_truncated` | damaged | yes | The file ends inside a data page. |
| `ogg_unknown_codec` | damaged | yes | A stream of an unknown codec beside an Opus one: FFmpeg keeps it without a codec and returns none of its packets. |
| `ogg_page_without_granule` | damaged | yes | An Opus data page whose granule is -1 although packets end on it: FFmpeg's Opus mapping refuses the granule (above 2^62) and reading stops with an error. |
| `ogg_opus_empty_first_packet` | damaged | yes | The first Opus data packet is empty: the Opus mapping refuses it during avformat_find_stream_info's read-ahead, which ends there as at the end of the input (eof_reached), so FFmpeg opens the file and reads on after it. |
| `ogg_flac_empty_header_packet` | damaged | yes | An empty FLAC header packet before a second STREAMINFO packet on the same page: FFmpeg's block type is bytestream2_get_byte's 0 for it, not the next packet's 0x7F, so the packet is skipped as a header and the file opens. |
| `ogg_opus_tags_twice` | accepted | yes | Two OpusTags packets in a row after a data packet: the second replaces the first's tags and strings-metadata side data before the next data packet takes it. |
| `ogg_flac_comment_twice` | accepted | yes | Two VORBIS_COMMENT packets in a row after a FLAC frame: the second replaces the first's tags and strings-metadata side data before the next frame takes it. |
| `ogg_opus_short_head` | rejected | `INVALIDDATA` | An OpusHead shorter than 19 bytes. |
| `ogg_no_pages` | rejected | `EOF` | OggS and nothing else: the input ends before a page. |
| `ogg_vorbis_ffmpeg_44k` | vorbis | yes | FFmpeg's Vorbis encoder, 30000 samples at 44100 Hz, `-c:a vorbis`; decoded by the T27d oracle. |
| `ogg_vorbis_ffmpeg_8k` | vorbis | yes | FFmpeg's Vorbis encoder, 6000 samples at 8000 Hz, `-c:a vorbis`; decoded by the T27d oracle. |
| `ogg_vorbis_ffmpeg_48k_q8` | vorbis | yes | FFmpeg's Vorbis encoder, 20000 samples at 48000 Hz, `-c:a vorbis -q:a 8`; decoded by the T27d oracle. |
| `ogg_vorbis_ffmpeg_22k_short` | vorbis | yes | FFmpeg's Vorbis encoder, 1000 samples at 22050 Hz, `-c:a vorbis`; decoded by the T27d oracle. |
| `ogg_opus_ffmpeg_stereo` | opus | yes | FFmpeg's Opus encoder, 20000 samples at 48000 Hz, `-c:a opus`; decoded by the T28 oracle. |
| `ogg_opus_ffmpeg_mono` | opus | yes | FFmpeg's Opus encoder, 15000 samples at 48000 Hz, `-c:a opus`; decoded by the T28 oracle. |
| `ogg_opus_ffmpeg_32k` | opus | yes | FFmpeg's Opus encoder, 20000 samples at 48000 Hz, `-c:a opus -b:a 32k`; decoded by the T28 oracle. |
| `ogg_opus_ffmpeg_delay10` | opus | yes | FFmpeg's Opus encoder, 12000 samples at 48000 Hz, `-c:a opus -opus_delay 10`; decoded by the T28 oracle. |
| `ogg_opus_ffmpeg_no_phase_inv` | opus | yes | FFmpeg's Opus encoder, 12000 samples at 48000 Hz, `-c:a opus -apply_phase_inv 0`; decoded by the T28 oracle. |
| `ogg_vorbis_bad_setup` | rejected | `UNKNOWN` | A Vorbis setup header without a mode table the parser can find. |
<!-- END GENERATED FIXTURE TABLE -->
