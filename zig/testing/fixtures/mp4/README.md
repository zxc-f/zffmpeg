# MP4 fixtures

The MP4, MOV, M4A and 3GP fixtures of TODO.md T33a1, written by
`generate.py` (never edit them by hand), except the `ffmpeg` group, which
is the reference build's mp4, mov and ipod muxers' output, made by
[mov_fixtures.sh](../../reference/mov_fixtures.sh) from inputs
`generate.py` writes (or from committed fixtures, for stream copies),
committed and checked against the hashes it records. They cover AAC
(stereo, mono, 5.1), ALAC, FLAC, Opus, MP2 and MP3 (in MP4 and in MOV,
where FFmpeg parses MPEG audio), AC-3 and E-AC-3 and every PCM sample
entry the mov muxer writes, `chan` boxes, two tracks, `moov` before
(`+faststart`) and after `mdat`, with and without the edit lists FFmpeg
writes. The `crafted` group is built here from them: 64-bit box sizes, a
last box of size 0, `co64`, `stz2`, `stss` and `stps`, sample-to-chunk
edge cases, QuickTime sound descriptions of versions 0 to 2, a `wave` box,
an unknown sample entry, a data track, truncations, oversized counts and
nesting. What FFmpeg's mov demuxer makes of each, every stream and packet,
is [mov.txt](../../vectors/mov.txt), printed by
[mov_vectors.c](../../reference/mov_vectors.c) from the pinned build; in
the table, the third column gives the port's result (yes, or its error),
which is FFmpeg's except where notes.md "MP4 demuxing" records a
difference.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | The port opens it | Rule |
| --- | --- | --- | --- |
| `mov_aac_stereo.mp4` | ffmpeg | yes | FFmpeg's muxer from 5760 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a aac -b:a 64k -use_editlist 0`. |
| `mov_aac_faststart.m4a` | ffmpeg | yes | FFmpeg's muxer from 4410 tones samples of 2 channels (stereo) at 44100 Hz, `-c:a aac -b:a 96k -use_editlist 0 -movflags +faststart -f ipod`. |
| `mov_aac_editlist.mp4` | ffmpeg | `UnsupportedFormat` | FFmpeg's muxer from 3000 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a aac -b:a 64k`. Its edit list starts the media at 1024 (the encoder delay): the port does not apply edit lists yet (T33b). |
| `mov_aac_mono_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 3000 tones samples of 1 channels (mono) at 22050 Hz, `-c:a aac -b:a 32k -use_editlist 0`. |
| `mov_aac_51_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2048 smooth samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a aac -b:a 192k -use_editlist 0`. |
| `mov_alac_stereo.m4a` | ffmpeg | yes | FFmpeg's muxer from 5000 smooth samples of 2 channels (stereo) at 44100 Hz, `-c:a alac -use_editlist 0 -f ipod`. |
| `mov_alac_editlist.mp4` | ffmpeg | yes | FFmpeg's muxer from 5000 tones samples of 2 channels (stereo) at 44100 Hz, `-c:a alac`. |
| `mov_alac_quad_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 3000 smooth samples of 4 channels (quad) at 48000 Hz, `-c:a alac -use_editlist 0`. |
| `mov_flac_stereo.mp4` | ffmpeg | yes | FFmpeg's muxer from 5000 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a flac -use_editlist 0`. |
| `mov_flac_editlist.mp4` | ffmpeg | yes | FFmpeg's muxer from 3000 tones samples of 1 channels (mono) at 16000 Hz, `-c:a flac`. |
| `mov_opus_stereo.mp4` | ffmpeg | yes | FFmpeg's muxer from 4800 tones samples of 2 channels (stereo) at 48000 Hz, `-c:a opus -strict -2 -b:a 64k -use_editlist 0`. |
| `mov_mp2_mp4.mp4` | ffmpeg | yes | FFmpeg's muxer from 4608 tones samples of 2 channels (stereo) at 48000 Hz, `-c:a mp2 -b:a 128k -use_editlist 0`. |
| `mov_mp2_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 4608 smooth samples of 1 channels (mono) at 32000 Hz, `-c:a mp2 -b:a 64k -use_editlist 0`. |
| `mov_mp3_copy_mp4.mp4` | ffmpeg | yes | FFmpeg's muxer from mp3/mp3_six_frames.mp3, `-c copy -use_editlist 0`. |
| `mov_mp3_copy_mov.mov` | ffmpeg | yes | FFmpeg's muxer from mp3/mp3_six_frames.mp3, `-c copy -use_editlist 0`. |
| `mov_ac3_51.mp4` | ffmpeg | yes | FFmpeg's muxer from 4608 smooth samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a ac3 -b:a 384k -use_editlist 0`. |
| `mov_ac3_stereo_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 4608 tones samples of 2 channels (stereo) at 44100 Hz, `-c:a ac3 -b:a 192k -use_editlist 0`. |
| `mov_eac3_51.mp4` | ffmpeg | yes | FFmpeg's muxer from 4608 smooth samples of 6 channels (5.1(side)) at 48000 Hz, `-c:a eac3 -b:a 256k -use_editlist 0`. |
| `mov_pcm_s16le_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1500 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a pcm_s16le -use_editlist 0`. |
| `mov_pcm_s16be_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2500 tones samples of 1 channels (mono) at 8000 Hz, `-c:a pcm_s16be -use_editlist 0`. |
| `mov_pcm_s24be_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1000 smooth samples of 2 channels (stereo) at 44100 Hz, `-c:a pcm_s24be -use_editlist 0`. |
| `mov_pcm_s24le_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1000 tones samples of 1 channels (mono) at 48000 Hz, `-c:a pcm_s24le -use_editlist 0`. |
| `mov_pcm_s32be_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 700 smooth samples of 1 channels (mono) at 32000 Hz, `-c:a pcm_s32be -use_editlist 0`. |
| `mov_pcm_f32be_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 600 tones samples of 2 channels (stereo) at 22050 Hz, `-c:a pcm_f32be -use_editlist 0`. |
| `mov_pcm_f32le_51_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 300 smooth samples of 6 channels (5.1(side)) at 44100 Hz, `-c:a pcm_f32le -use_editlist 0`. |
| `mov_pcm_f64be_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 400 tones samples of 1 channels (mono) at 16000 Hz, `-c:a pcm_f64be -use_editlist 0`. |
| `mov_pcm_u8_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 3000 smooth samples of 1 channels (mono) at 11025 Hz, `-c:a pcm_u8 -use_editlist 0`. |
| `mov_pcm_s8_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1500 tones samples of 2 channels (stereo) at 8000 Hz, `-c:a pcm_s8 -use_editlist 0`. |
| `mov_pcm_alaw_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 3000 tones samples of 1 channels (mono) at 8000 Hz, `-c:a pcm_alaw -use_editlist 0`. |
| `mov_pcm_mulaw_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1500 smooth samples of 2 channels (stereo) at 8000 Hz, `-c:a pcm_mulaw -use_editlist 0`. |
| `mov_pcm_editlist_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2205 smooth samples of 2 channels (stereo) at 44100 Hz, `-c:a pcm_s16be`. |
| `mov_pcm_faststart_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2000 tones samples of 1 channels (mono) at 48000 Hz, `-c:a pcm_s16le -use_editlist 0 -movflags +faststart`. |
| `mov_two_tracks.mp4` | ffmpeg | yes | FFmpeg's muxer from 4800 smooth samples of 2 channels (stereo) at 48000 Hz, 4410 tones samples of 1 channels (mono) at 44100 Hz, `-map 0 -map 1 -c:a:0 aac -b:a:0 64k -c:a:1 alac -use_editlist 0`. |
| `mov_two_tracks_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 1600 tones samples of 1 channels (mono) at 8000 Hz, 1600 smooth samples of 2 channels (stereo) at 16000 Hz, `-map 0 -map 1 -c:a pcm_s16le -use_editlist 0`. |
| `mov_crafted_pcm.mov` | crafted | yes | A QuickTime 16-bit PCM track of 600 samples in chunks of 200, every sample one tick: packets of up to 1024 samples per chunk. |
| `mov_crafted_pcm_chunks.mov` | crafted | yes | PCM chunks of 1500, 700 and 300 samples: a chunk split into packets of 1024. |
| `mov_box64.mp4` | crafted | yes | The moov after mdat, both with 64-bit sizes (size 1 and a largesize). |
| `mov_size0_last.mp4` | crafted | yes | The last box, mdat, with size 0: it runs to the end of the file. |
| `mov_wide_mdat.mp4` | crafted | yes | A wide box before the mdat. |
| `mov_co64.mp4` | crafted | yes | 64-bit chunk offsets (co64). |
| `mov_stz2_4.mov` | crafted | yes | Compact sample sizes of 4 bits (stz2) for ten mu-law samples. |
| `mov_stz2_8.mov` | crafted | yes | Compact sample sizes of 8 bits (stz2) for ten mu-law samples. |
| `mov_stz2_16.mov` | crafted | yes | Compact sample sizes of 16 bits (stz2) for ten mu-law samples. |
| `mov_stsz_constant.mov` | crafted | yes | A constant sample size in stsz (no table) for eight samples of 6 bytes. |
| `mov_stsc_runs.mov` | crafted | yes | Three sample-to-chunk runs (2, 1, then 3 samples a chunk) over four chunks. |
| `mov_stsc_repaired.mov` | crafted | yes | Invalid sample-to-chunk entries (a repeated first chunk, a zero count and id, chunks out of order), which FFmpeg repairs from the next valid one. |
| `mov_stsc_past_chunks.mov` | crafted | `InvalidMov` | A sample-to-chunk entry starting past the last chunk: a broken track. |
| `mov_stss.mp4` | crafted | yes | An AAC track whose sync sample table marks samples 1 and 4: AAC packets keep the index's flags. |
| `mov_stps.mp4` | crafted | yes | An AAC track with an empty stss and a partial sync table (stps) marking sample 3. |
| `mov_sdtp.mp4` | crafted | yes | Sample dependency flags: two samples nobody depends on, marked disposable. |
| `mov_ctts.mp4` | crafted | yes | Composition offsets on audio (ctts): pts after dts, one negative offset. |
| `mov_rap_group.mp4` | crafted | yes | A rap sample group marking samples 2 and 3 of an AAC track whose stss marks none. |
| `mov_qt_v1_ima4.mov` | crafted | yes | A version 1 sound description of IMA ADPCM (64 samples a 34-byte frame), 40 frames in chunks of 16: packets of 16 frames, a codec without a decoder in the reference build. |
| `mov_qt_v2_lpcm.mov` | crafted | yes | A version 2 sound description of lpcm (24-bit signed little-endian by its flags, a rate as a double). |
| `mov_qt_v2_float.mov` | crafted | yes | A version 2 lpcm description of big-endian 32-bit floats. |
| `mov_qt_v2_bad_rate.mov` | crafted | `InvalidMov` | A version 2 description whose double rate is negative: "Invalid sample rate". |
| `mov_twos_8bit.mov` | crafted | yes | A twos entry of 8 bits: FFmpeg reads it as signed 8-bit PCM. |
| `mov_unknown_entry.mov` | crafted | yes | A sound track whose sample entry is an unknown format: codec none, no decoder. |
| `mov_data_track.mp4` | crafted | yes | An audio track and a data track (an unknown handler and entry): the data stream's packets are keyframes, its timings a text stream's. |
| `mov_data_zero_durations.mp4` | crafted | yes | A gpmd data track whose samples all last 0: discarded, as FFmpeg does. |
| `mov_video_track.mp4` | crafted | `UnsupportedFormat` | An AAC track and a video track: video is not demuxed yet (T33a3). |
| `mov_deep_nesting.mp4` | crafted | `InvalidMov` | Boxes nested twelve deep in a track: "Atoms too deeply nested". |
| `mov_empty_moov.mp4` | crafted | yes | A moov holding only mvhd: no streams. |
| `mov_no_moov.mp4` | crafted | `InvalidMov` | An ftyp and an mdat, no moov: "moov atom not found". |
| `mov_junk_box.mp4` | crafted | yes | A junk box before the moov and an unknown box after the mdat. |
| `mov_3gp.3gp` | crafted | yes | The AAC file with a 3gp4 major brand. |
| `mov_3g2.3g2` | crafted | yes | The AAC file with a 3g2a major brand. |
| `mov_cut_in_moov.mp4` | crafted | yes | The file cut 30% into its moov: a track with nothing read. |
| `mov_cut_in_stbl.mp4` | crafted | `Truncated` | The file cut 90% into its moov, inside a sample table: AVERROR_EOF. |
| `mov_cut_in_mdat.mp4` | crafted | yes | The file cut inside its mdat: the last packet short, then the end. |
| `mov_cut_in_mdat_after.mp4` | crafted | `InvalidMov` | A moov after the mdat, the file cut inside the moov: no moov. |
| `mov_stts_count_huge.mp4` | crafted | `Truncated` | An stts declaring a million entries in a box of one: FFmpeg reads on into the next boxes until the file ends (AVERROR_EOF). |
| `mov_stco_count_huge.mp4` | crafted | yes | An stco declaring a million offsets in a box of two: clamped to the box. |
| `mov_stsz_count_huge.mp4` | crafted | yes | A constant stsz of 100 million samples: FFmpeg's index allocation fails and the track has no packets. |
| `mov_elst_identity.mp4` | crafted | yes | An edit list of one edit from media time 0 covering every sample: the index stays. |
| `mov_elst_empty_edit.mp4` | crafted | `UnsupportedFormat` | An edit list starting with an empty edit, which shifts the start (T33b). |
| `mov_mdhd_v2.mp4` | crafted | `PatchWelcome` | An mdhd of version 2: AVERROR_PATCHWELCOME. |
| `mov_mdhd_times.mp4` | crafted | yes | Creation times in mvhd and mdhd and a packed ISO language code. |
| `mov_chan_descriptions.mov` | crafted | yes | A chan box describing a stereo track's channels as right then left: a custom order. |
| `mov_hoov.mp4` | crafted | yes | The movie header in a hoov box, which FFmpeg reads as moov. |
| `mov_dref_alias.mp4` | crafted | `UnsupportedFormat` | A data reference that is an alias record of 151 bytes, which FFmpeg reads as a path to another file. |
| `mov_sdtp_short.mp4` | crafted | `OutOfRange` | An sdtp box of 3 bytes: AVERROR(ERANGE). |
| `mov_two_stsd.mp4` | crafted | yes | Two descriptions of the same format, chunks alternating between them: new extradata side data at each change. |
<!-- END GENERATED FIXTURE TABLE -->
