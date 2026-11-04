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
| `ogg_opus_short_head` | rejected | `INVALIDDATA` | An OpusHead shorter than 19 bytes. |
| `ogg_no_pages` | rejected | `EOF` | OggS and nothing else: the input ends before a page. |
| `ogg_vorbis_bad_setup` | rejected | `UNKNOWN` | A Vorbis setup header without a mode table the parser can find. |
<!-- END GENERATED FIXTURE TABLE -->
