# MP4 fixtures

The MP4, MOV, M4A and 3GP fixtures of TODO.md T33a1 and T33a2, written by
`generate.py` (never edit them by hand), except the `ffmpeg` group, which
is the reference build's mp4, mov and ipod muxers' output, made by
[mov_fixtures.sh](../../reference/mov_fixtures.sh) from inputs
`generate.py` writes (or from committed fixtures, for stream copies),
committed and checked against the hashes it records. They cover AAC
(stereo, mono, 5.1), ALAC, FLAC, Opus, MP2 and MP3 (in MP4 and in MOV,
where FFmpeg parses MPEG audio), AC-3 and E-AC-3 and every PCM sample
entry the mov muxer writes, `chan` boxes, two tracks, `moov` before
(`+faststart`) and after `mdat`, with and without the edit lists FFmpeg
writes, and (T33a2, `mov_meta_*`) the muxers' tags from `-metadata`
(iTunes `ilst`, QuickTime user data strings, `keys` with
`+use_metadata_tags`) and chapters (`chpl` and a chapter text track). The
`crafted` group is built here from them: 64-bit box sizes, a last box of
size 0, `co64`, `stz2`, `stss` and `stps`, sample-to-chunk edge cases,
QuickTime sound descriptions of versions 0 to 2, a `wave` box, an unknown
sample entry, a data track, truncations, oversized counts and nesting;
and (T33a2) user data strings in Mac Roman and with packed languages,
iTunes data atoms of every type, `keys`, `----` with iTunSMPB and
ReplayGain, `chpl`, `HMMT`, QuickTime chapter tracks, `loci`, `kind`,
`uuid` and cover pictures. What FFmpeg's mov demuxer makes of each, every
stream, tag, chapter and packet,
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
| `mov_meta_tags_mp4.mp4` | ffmpeg | yes | FFmpeg's muxer from 3072 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a aac -b:a 64k -use_editlist 0 -metadata title=Tïtle_ünïcode -metadata artist=Ärtist -metadata album=Album -metadata album_artist=Album_artist -metadata composer=Composer -metadata date=2024-05-06 -metadata track=3/12 -metadata disc=1/2 -metadata genre=Rock -metadata comment=Comment -metadata copyright=(c)_2024 -metadata grouping=Group -metadata lyrics=La_la -metadata description=Description -metadata synopsis=Synopsis -metadata show=Show -metadata episode_id=E1 -metadata network=Network -metadata keywords=k1,k2 -metadata make=Make -metadata model=Model -metadata location=+48.8566+002.3522/ -metadata:s:a:0 language=fra -metadata:s:a:0 handler_name=Voice_track -metadata:s:a:0 title=Stream_title`. |
| `mov_meta_tags_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2048 tones samples of 1 channels (mono) at 22050 Hz, `-c:a pcm_s16be -use_editlist 0 -metadata title=Tïtle_ünïcode -metadata artist=Ärtist -metadata album=Album -metadata album_artist=Album_artist -metadata composer=Composer -metadata date=2024-05-06 -metadata track=3/12 -metadata disc=1/2 -metadata genre=Rock -metadata comment=Comment -metadata copyright=(c)_2024 -metadata grouping=Group -metadata lyrics=La_la -metadata description=Description -metadata synopsis=Synopsis -metadata show=Show -metadata episode_id=E1 -metadata network=Network -metadata keywords=k1,k2 -metadata make=Make -metadata model=Model -metadata location=+48.8566+002.3522/ -metadata:s:a:0 language=fra -metadata:s:a:0 handler_name=Voice_track -metadata:s:a:0 title=Stream_title`. |
| `mov_meta_tags_ipod.m4a` | ffmpeg | yes | FFmpeg's muxer from 3072 tones samples of 2 channels (stereo) at 44100 Hz, `-c:a alac -use_editlist 0 -f ipod -metadata title=Tïtle_ünïcode -metadata artist=Ärtist -metadata album=Album -metadata album_artist=Album_artist -metadata composer=Composer -metadata date=2024-05-06 -metadata track=3/12 -metadata disc=1/2 -metadata genre=Rock -metadata comment=Comment -metadata copyright=(c)_2024 -metadata grouping=Group -metadata lyrics=La_la -metadata description=Description -metadata synopsis=Synopsis -metadata show=Show -metadata episode_id=E1 -metadata network=Network -metadata keywords=k1,k2 -metadata make=Make -metadata model=Model -metadata location=+48.8566+002.3522/ -metadata:s:a:0 language=fra -metadata:s:a:0 handler_name=Voice_track -metadata:s:a:0 title=Stream_title`. |
| `mov_meta_mdta_mp4.mp4` | ffmpeg | yes | FFmpeg's muxer from 3072 smooth samples of 2 channels (stereo) at 48000 Hz, `-c:a aac -b:a 64k -use_editlist 0 -movflags +use_metadata_tags -metadata com.example.custom=Custom_ünï -metadata title=Tïtle_ünïcode -metadata artist=Ärtist -metadata album=Album -metadata album_artist=Album_artist -metadata composer=Composer -metadata date=2024-05-06 -metadata track=3/12 -metadata disc=1/2 -metadata genre=Rock -metadata comment=Comment -metadata copyright=(c)_2024 -metadata grouping=Group -metadata lyrics=La_la -metadata description=Description -metadata synopsis=Synopsis -metadata show=Show -metadata episode_id=E1 -metadata network=Network -metadata keywords=k1,k2 -metadata make=Make -metadata model=Model -metadata location=+48.8566+002.3522/ -metadata:s:a:0 language=fra -metadata:s:a:0 handler_name=Voice_track -metadata:s:a:0 title=Stream_title`. |
| `mov_meta_mdta_mov.mov` | ffmpeg | yes | FFmpeg's muxer from 2048 smooth samples of 1 channels (mono) at 16000 Hz, `-c:a pcm_s24le -use_editlist 0 -movflags +use_metadata_tags -metadata com.example.custom=Custom -metadata title=Tïtle_ünïcode -metadata artist=Ärtist -metadata album=Album -metadata album_artist=Album_artist -metadata composer=Composer -metadata date=2024-05-06 -metadata track=3/12 -metadata disc=1/2 -metadata genre=Rock -metadata comment=Comment -metadata copyright=(c)_2024 -metadata grouping=Group -metadata lyrics=La_la -metadata description=Description -metadata synopsis=Synopsis -metadata show=Show -metadata episode_id=E1 -metadata network=Network -metadata keywords=k1,k2 -metadata make=Make -metadata model=Model -metadata location=+48.8566+002.3522/ -metadata:s:a:0 language=fra -metadata:s:a:0 handler_name=Voice_track -metadata:s:a:0 title=Stream_title`. |
| `mov_meta_chapters_mp4.mp4` | ffmpeg | yes | FFmpeg's muxer from mp4/mov_meta_chpl.mp4, `-map_metadata 0 -c copy -use_editlist 0`. |
| `mov_meta_chapters_mov.mov` | ffmpeg | yes | FFmpeg's muxer from mp4/mov_meta_chpl.mp4, `-map_metadata 0 -c copy -use_editlist 0`. |
| `mov_meta_chapters_mp3.mp4` | ffmpeg | yes | FFmpeg's muxer from mp3/mp3_apic_chap.mp3, `-map_metadata 0 -map 0:a -c copy -use_editlist 0`. |
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
| `mov_meta_udta_strings.mp4` | crafted | yes | QuickTime user data strings in moov: a packed language (`title-eng`), Mac Roman for a language of 0 and 0x7FFF, a raw `@PRM` cut at its NUL, a length past the box read raw, an unknown box, a track number, an empty string, Mac Roman cut at twice its length in UTF-8; a HandBrake 0.10.2 encoder, which makes FFmpeg parse an MP3 track in full. |
| `mov_meta_handbrake_new.mp4` | crafted | yes | A HandBrake 0.10.3 encoder string: the MP3 track is not parsed in full. |
| `mov_meta_ilst.mp4` | crafted | yes | iTunes tags in an MP4 meta: two values of one tag and two tags of one key joined by `;`, Mac Roman for type 0, UTF-16 skipped, signed and unsigned integers of 1 to 5 bytes, a float, numbers, a genre, a disc and a track (format tags), a data atom longer than its tag, a tag without one, a cover of an unknown type, a value cut at its NUL; an `ilst` inside the `ilst` ends iTunes mode, so the tag after it is read as a QuickTime string. |
| `mov_meta_keys.mp4` | crafted | yes | QuickTime metadata keys (an `mdta` handler, `keys`, then `ilst` by index): names, a key of another namespace and an index past the keys skipped, an artwork key of an unknown cover type, and a table key among them. |
| `mov_meta_keys_qt.mp4` | crafted | yes | The same keys in a QuickTime `meta` without a full box header. |
| `mov_meta_keys_count.mp4` | crafted | `InvalidMov` | A `keys` box declaring 100 keys in 9 bytes: AVERROR_INVALIDDATA. |
| `mov_meta_keys_size.mp4` | crafted | `InvalidMov` | A key of size 4: AVERROR_INVALIDDATA. |
| `mov_meta_itunsmpb.mp4` | crafted | yes | iTunes `----` atoms: iTunSMPB (1024 samples of priming, the initial padding and skip samples, and a remainder of 300, a discard window), ReplayGain (coded side data), DISCSUBTITLE, cdec dropped, one without data, one with two means, a name cut at its NUL. |
| `mov_meta_in_trak.mp4` | crafted | yes | User data inside the track: stream tags, and iTunSMPB read while the track's time base is still 1/90000. |
| `mov_meta_chpl.mp4` | crafted | yes | Nero chapters (chpl, version 1) with UTF-8 titles. |
| `mov_meta_chpl_short.mp4` | crafted | yes | A version 0 chpl declaring 3 chapters whose second title runs past the box. |
| `mov_meta_hmmt.mp4` | crafted | yes | Nero chapters, then HMMT marks with the same ids: the first two lose their titles, the third is new. |
| `mov_meta_hmmt_count.mp4` | crafted | `InvalidMov` | HMMT declaring more marks than its box holds: AVERROR_INVALIDDATA. |
| `mov_meta_chapter_track.mp4` | crafted | yes | A QuickTime chapter track (tref/chap naming a missing track and the text track): UTF-8, UTF-16 with either byte order mark and a surrogate pair, a one-byte title, a length past its sample (skipped), an empty title, and a track shorter than its last chapter. From a pipe FFmpeg keeps it a subtitle stream. |
| `mov_meta_chapter_cut.mp4` | crafted | yes | The chapter track's file cut 6 bytes short: the sample at the end reads a length of 0 there (an empty title); the next, past the end, ends the chapters. |
| `mov_meta_chapter_self.mp4` | crafted | yes | A chap reference to the audio track itself: it becomes a discarded data stream whose packets are chapter titles. |
| `mov_meta_loci.mp4` | crafted | yes | 3GPP locations (loci): with a language and an altitude, then with `und` and none; and a meta box without an hdlr. |
| `mov_meta_loci_short.mp4` | crafted | `InvalidMov` | A loci box too short for its coordinates: AVERROR_INVALIDDATA. |
| `mov_meta_kind.mp4` | crafted | yes | kind boxes in the track: DASH roles caption and dub as dispositions, another scheme ignored. |
| `mov_meta_kind_version.mp4` | crafted | `InvalidMov` | A kind box of version 1: AVERROR_INVALIDDATA. |
| `mov_meta_uuid.mp4` | crafted | yes | uuid boxes: XMP skipped, an ISML manifest's bit rate for the first stream, spherical metadata read, an unknown uuid. |
| `mov_meta_uuid_short.mp4` | crafted | `InvalidMov` | A uuid box of 10 bytes: AVERROR_INVALIDDATA. |
| `mov_meta_deep.mp4` | crafted | `InvalidMov` | User data boxes nested past the depth limit: AVERROR_INVALIDDATA. |
| `mov_meta_string_past_end.mp4` | crafted | `InvalidMov` | A user data string whose length runs past the end of the file (moov last): AVERROR_INVALIDDATA. |
| `mov_meta_covr.mp4` | crafted | yes | Two cover pictures (JPEG, PNG) after the track, which FFmpeg makes attached-picture streams and the port skips. |
| `mov_meta_covr_in_trak.mp4` | crafted | `UnsupportedFormat` | A cover picture inside the track: FFmpeg's picture stream would come before the track's end, which the port does not model. |
<!-- END GENERATED FIXTURE TABLE -->
