# I/O for zffmpeg: FFmpeg's C layer, Zig 0.17.0's std.Io, measurements

This is the evidence behind [../SKILL.md](../SKILL.md). It reads FFmpeg's
I/O layer and Zig 0.17.0's `std.Io` side by side, checks what zffmpeg does
today, and measures the choices on Linux x86-64. Every source is cited by
file and line at the pinned revisions; every number comes from
[../bench/](../bench/) and is recorded in [results/](results/);
[reproduce.md](reproduce.md) reruns it all.

## Sources

| Source | Revision | Where |
| --- | --- | --- |
| FFmpeg | `5d5a38a7e46be296eab75982c0986054f731e19e` | `.references/ffmpeg` |
| Zig standard library | the 0.17.0 release's `lib/std`; tag `0.17.0` (`7647adab80dd088f4de3610fd245915a912eb6ad`) for its tests and history | the toolchain (`zig env` prints `lib_dir`); `.references/zig`, a clone read at the tag ("The Zig source" below) |
| zio | `1814bacf54ca2ebdb140c3e521860ef3320f76dd` | `.references/zio` |
| ZLS | `c275dd2ec457e6ae302d98a6116e69c6d595c24c` | `.references/zls` |
| zig-cookbook | `ed1772059f236c1721af57c785b4d94684951be5` | `.references/zig-cookbook` |
| zigimg | `083d0304840a3f5fd547c2e2005148a18886c401` | `.references/zigimg`, [doc/zigimg-reference.md](../../../../doc/zigimg-reference.md) |

README.md "Clone the reference repositories" has the clone commands. All are
references only; none is a build dependency (notes.md, "I/O references").

## FFmpeg's I/O layer

Paths are relative to `.references/ffmpeg/`.

- **One buffer per stream, 32 KiB.** `IO_BUFFER_SIZE 32768`
  (`libavformat/aviobuf.c:36`, `avio.c:40`); 256 KiB for network protocols
  (`avio.c:41`). `ffio_fdopen` doubles it for streamed (pipe) input
  (`avio.c:489-492`).
- **Reads.** `fill_buffer` (`aviobuf.c:514`) appends to the buffer while a
  full `max_buffer_size` still fits, else restarts at its start; at end of
  file it keeps the buffer so a seek back can reuse it. `avio_read`
  (`aviobuf.c:620`) copies from the buffer, and when the buffer is empty and
  the request is larger than the buffer it reads straight into the caller's
  memory, bypassing the buffer. `ffio_read_indirect` (`aviobuf.c:684`)
  returns a pointer into the buffer when the bytes are already there.
- **Seeks and skips.** `avio_seek` (`aviobuf.c:236`): inside the buffer it
  only moves the pointer; forward within the buffer plus
  `SHORT_SEEK_THRESHOLD` 32 KiB (`aviobuf.c:43`), or on any non-seekable
  stream, it reads forward; a short backward seek re-reads from half a buffer
  earlier; anything else is a real `lseek`. `avio_skip` is `avio_seek` with
  `SEEK_CUR`.
- **Writes.** `avio_write` (`aviobuf.c:206`) copies into the buffer and
  flushes when full (`flush_buffer`, `aviobuf.c:168`); with `direct` set it
  writes the caller's bytes straight out. Muxers write placeholder sizes and
  rewrite them only when the output is seekable: `wavenc.c:455-518`,
  `au.c:374-378`, `flacenc.c:337-342`, `aiffenc.c:245-253`, all on
  `AVIO_SEEKABLE_NORMAL`.
- **Files and pipes.** The file protocol marks a FIFO as streamed
  (`file.c:331`); the pipe protocol is always streamed (`file.c:485`), and
  for an fd it checks `S_ISREG || S_ISBLK` (`file.c:526`). The ffmpeg
  program maps an input `-` to the `fd:` protocol (`fftools/ffmpeg_demux.c:2376`)
  and an output `-` to `pipe:` (`fftools/ffmpeg_mux_init.c:3685`).
- **Cancellation.** `retry_transfer_wrapper` (`avio.c:578`) checks the
  interrupt callback before every transfer (`avio.c:589`) and retries
  `EAGAIN` with a short sleep.
- **Probing.** `av_probe_input_buffer2` (`format.c:270`) reads 2048 bytes
  (`PROBE_BUF_MIN`, `internal.h:33`) and doubles up to 1 MiB
  (`PROBE_BUF_MAX`, `internal.h:34`); `ffio_rewind_with_probe_data`
  (`aviobuf.c:1119`) replays those bytes on a stream that cannot seek.
- **Threads.** The ffmpeg program runs every demuxer, decoder, filtergraph,
  encoder and muxer in its own thread (`fftools/ffmpeg_sched.c:415`,
  `pthread_create`), joined by thread queues of 2 packets or 2 frames by
  default (`fftools/ffmpeg_sched.h:257,262`), with demuxers paused when they
  run more than `SCHEDULE_TOLERANCE` (100 ms, `ffmpeg_sched.c:45`) ahead.
  Among the codecs zffmpeg ports, only the FLAC decoder declares frame
  threads (`libavcodec/flacdec.c:829`); Vorbis, Opus, the MPEG audio
  decoders, PCM and the FLAC encoder have none.

## Zig 0.17.0's std.Io

Paths are relative to `lib/std/`.

- **Reader.** A caller buffer with `seek` and `end`. `peek`/`take`
  (`Io/Reader.zig:520,568`) return views into it and assert the buffer can
  hold `n`; `fill` rebases (memmove) when needed. `readSliceShort`
  (`Io/Reader.zig:685`) copies what is buffered, then calls `readVec` with the
  rest of the destination; `writableVector` (`Io/Reader.zig:2128`) makes that
  one vectored read cover the destination *and* the whole buffer when the
  buffer is empty. So a large read lands in the destination with no copy and
  refills the buffer in the same syscall: FFmpeg's direct read plus read-ahead.
- **Skips.** `discardShort` (`Io/Reader.zig:640`) adds to `seek` without an
  overflow check; zffmpeg wraps it in `zig/io/skip.zig`.
- **File.Reader modes** (`Io/File/Reader.zig`). `file.reader` starts
  positional: reads are `preadv` at its own position, `seekTo`/`seekBy` and
  `discard` only move that position (`discard`, line 300), and an
  `Unseekable` error switches it to streaming once (`readVecPositional`,
  line 240). `file.readerStreaming` (`initStreaming`, line 104) starts with
  `seek_err = Unseekable` and `size_err = Streaming`, so its `discard` reads
  and drops the bytes and it can never seek back, even on a regular file.
  `_simple` modes avoid `sendfile`-style calls.
- **File.Writer** (`Io/File/Writer.zig`). Same modes; `drain` writes the
  buffer and the new data in one vectored call; `seekTo` flushes first
  (line 199); `end` also sets the file length in positional mode (line 237).
  `sendFile` (line 134) reaches `copy_file_range` or `sendfile` in
  `Io/Threaded.zig` (`use_copy_file_range`, line 55).
- **Threaded backend.** `std.process.Init` gives an `Io.Threaded`. File
  operations run as plain syscalls on the calling thread
  (`fileReadStreamingPosix`, `Io/Threaded.zig:9907`) with cancelation checks
  around them; no thread hop for sequential I/O.
- **Concurrency.** `io.async` "may" run the function immediately on the
  caller (`Io.zig:2526`); `io.concurrent` (`Io.zig:2565`) either gets a unit
  of concurrency or fails. `Io.Group.async` inherits `async`'s rule, which
  zio's contract test "a cancel taken by a group task run on the caller
  reaches the caller" (`.references/zio/src/io.zig:5118`) exercises.
  `Io.Queue(T)` (`Io.zig:2384`) is a bounded queue with `put`/`get` of
  several elements, `close`, and cancelable waits.
- **Evented backend.** `Io.Evented` is `Io.Uring` on Linux (`Io.zig:31-36`),
  but in 0.17.0 `Io/Uring.zig:759` sets a `processReplacePath` field that
  `Io.VTable` does not have, so any program that instantiates it fails to
  compile. There is no usable event-driven std backend in this release.

## The Zig source: the installed lib/std or a clone

Checked on 2026-11-06 against a full clone of the Zig repository
(`.references/zig`, then on `master`, `0.17.0-953-g155ec6090`):

- **The installed `lib/std` is the 0.17.0 source.** Every file of the
  release's `lib/std` equals the tag's, except the standard library's own
  tests: the release ships each `test.zig` empty (`Io/test.zig`,
  `fs/test.zig`, `Io/Threaded/test.zig` and 7 more) and leaves out their
  test data (139 files). The API reading above, and every line cited in
  this file, is the same in both.
- **`master` is not 0.17.0.** 953 commits later, 223 files of `lib/std`
  changed (23,788 lines added, 13,435 removed). Reading
  `.references/zig/lib` on `master` as if it were the pinned library gives
  wrong answers; read the clone at the tag:
  `git -C .references/zig show 0.17.0:lib/std/Io/Reader.zig`, or a worktree
  at the tag.
- **What the clone adds.** The std's own tests at the tag, which document
  behavior the release no longer carries; `git log` and `git blame`, which
  give the reason for a rule and show what changed after the release; the
  compiler (`src/`), the language reference (`doc/langref.html.in`) and the
  behavior tests (`test/`). The 0.17.x branch has a 0.17.1 tag (209
  commits after 0.17.0); its `std.Io` changes that could touch zffmpeg:
  `975d74f654` maps `EACCES` from a file read to `AccessDenied` (in 0.17.0
  it reaches `unexpectedErrno`, `error.Unexpected` with a stack trace in
  Debug); `a4b8ba9836` makes a flush of the `failing` test `Io` fail
  instead of spinning (test-only). `Io.Evented` still does not compile with
  0.17.1's `lib`: the `processReplacePath` field is gone, and `Io/Uring.zig`
  now switches on an `Io.Operation` tag `net_accept` that does not exist
  (built with the 0.17.0 compiler and `--zig-lib-dir`).
- **So:** the installed `lib/std` stays the authority for what compiles
  (CLAUDE.md pins 0.17.0); the clone, read at the tag, is the source for
  the std's tests and the history, and for checking a patch release before
  the toolchain moves.

## What zffmpeg does today

- The CLI reads a regular input file positionally and anything else
  streaming, with a 64 KiB buffer (`zig/cli/ffmpeg.zig:393-397`); `probeFile`
  does the same (`zig/io/file.zig:47-55`). `av.file.decodeFile`
  (`zig/io/file.zig:86-94`) always uses `readerStreaming`; on a regular file
  its skips read through (see "Findings").
- Outputs are created with `.exclusive = true`, written with
  `writerStreaming`, and seeked back only when `stat().kind == .file`
  (`zig/cli/ffmpeg.zig:439-456`), through `av.seek.OutputSeeker`
  (`zig/format/seek.zig:136`). Inputs seek through `av.seek.Seeker.file`
  (`zig/format/seek.zig:107`).
- Detection probes FFmpeg's way, 2048 bytes doubling, and replays the probe
  bytes through `zig/format/replay.zig` (`zig/format/detect.zig:14-19,131`).
- Everything runs on one thread; there are no queues yet (T53d, T59).

## Measurements

Two machines. The tables keep their original names (R1 to E2E) so the runs
compare; machine B adds the codec paths (E2E-C) and an FFmpeg built with
assembly.

### Machine A: a virtual machine (runs 1 and 2)

One Linux x86-64 virtual machine: Intel Xeon @ 2.10 GHz, 4 logical cores,
AVX2 and FMA, 15 GiB, kernel 6.18, ext4 on a virtio disk; Zig 0.17.0; files
read from the page cache, so the numbers measure the library and the
syscalls. Medians of 5 runs (3 for writes and copies). Run 1 (by hand) and
run 2 (`run_all.sh`, the script as committed) are in [results/](results/);
the tables below are run 1, and run 2 supports every conclusion, with the
ranges given where it differs.

**R1. Bulk read of 512 MiB into a caller chunk** (MiB/s):

| Buffer | Mode | 4 KiB chunks | 64 KiB | 1 MiB |
| ---: | --- | ---: | ---: | ---: |
| 0 | pos | 4242 | 6359 | 6576 |
| 4096 | pos | 5633 | 6867 | 6448 |
| 16384 | pos | 6165 | 6725 | 7002 |
| 32768 | pos | 6195 | 5927 | 6928 |
| 65536 | pos | 5955 | 5766 | 6900 |
| 262144 | pos | 6432 | 5741 | 5791 |
| 1048576 | pos | 6395 | 5765 | 5728 |

Streaming mode is within ±10% of positional in every cell (results file). No
buffer with 4 KiB requests is the slowest case (a syscall per 4 KiB); from
16 KiB on, the buffer size hardly matters, and 256 KiB–1 MiB buffers are a
little slower with 64 KiB chunks, as they no longer fit the core's cache.

**R2. 4-byte fields over 64 MiB**, positional (MiB/s): `readSliceAll` into a
local array 969–1146, `takeArray` 2678–2812, `takeInt` 2717–3082, for buffers
of 4 KiB, 64 KiB and 1 MiB (run 2: 752–1102, 3230–4016, 2653–3081). Per
call, about 4 ns against 1–1.5 ns: `take` is 2.5–5× cheaper.

**R3. Read 4 KiB, skip N**, 64 KiB buffer (logical MiB/s, skipped bytes
included):

| Skip | Positional | Streaming |
| ---: | ---: | ---: |
| 4 KiB | 6947 | 6465 |
| 60 KiB | 12919 | 6715 |
| 1 MiB | 101885 | 6616 |
| 16 MiB | 1756848 | 6683 |

**S1. Syscalls** (`strace -c`): the 1 MiB-skip run made 511 `preadv` calls
positionally (one per 4 KiB read) and 8162 `readv` calls streaming (every
skipped byte read through the buffer).

**R4. 512 MiB through a pipe from `cat`** (MiB/s): 1155–1468 for every
buffer from 0 to 1 MiB and both chunk sizes (run 2: 1207–1506); the
kernel's 64 KiB pipe and the writer set the rate. A third, discarded run of
the script measured one 926 MiB/s cell: this table is the noisiest.

**W1. 256 MiB with `writeAll(chunk)`, then flush** (MiB/s, positional;
streaming within the noise):

| Buffer | 64 B writes | 4 KiB writes | 1 MiB writes |
| ---: | ---: | ---: | ---: |
| 0 | 153 | 1861 | 4876 |
| 4096 | 1548 | 2633 | 5164 |
| 32768 | 2636 | 3156 | 4342 |
| 65536 | 2847 | 3091 | 5175 |
| 262144 | 3274 | 3996 | 4500 |
| 1048576 | 3632 | 3751 | 2884 |

**C1. Copy a 512 MiB file**: a 64 KiB read/write loop 2344–2885 MiB/s;
`streamRemaining` into a `File.Writer` 2955–3202 MiB/s, done with 2
`copy_file_range` calls (S1).

**Q1. Read packets and hash them** (FNV-1a over each byte, `rounds` times),
serially or as two tasks joined by an `Io.Queue` of capacity N (buffers return
through a second queue), MiB/s:

| Packet | Work | Serial | N = 1 | N = 2 | N = 8 | N = 32 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 KiB | none | 5728 | 450 | 562 | 1575 | 3140 |
| 4 KiB | 1 round | 601 | 302 | 302 | 318 | 329 |
| 64 KiB | none | 6666 | 4532 | 4398 | 4436 | 4070 |
| 64 KiB | 1 round | 598 | 612 | 620 | 614 | 627 |

A handoff costs several microseconds of thread wake-up. With 4 KiB packets
the pipeline halves throughput even though the reader is idle most of the
time; with 64 KiB packets it gains about 3%, because reading from the cache
costs a tenth of the work and a two-stage pipeline cannot beat its slowest
stage.

**E2E. zffmpeg against the reference FFmpeg** on a 512 MiB stereo 48 kHz
WAV (median wall time of 5; run 2: zffmpeg 1.15–1.74× faster, the same
syscall counts within a few):

| Operation | zffmpeg | FFmpeg |
| --- | ---: | ---: |
| WAV stream copy to WAV | 0.546 s | 0.825 s |
| WAV s16le to AU s16be | 0.789 s | 1.074 s |
| WAV to raw s16le | 0.707 s | 1.165 s |
| WAV from a pipe to AU | 0.957 s | 1.207 s |
| WAV to raw s16le on a pipe | 0.691 s | 0.821 s |

For WAV to AU, zffmpeg made 15,481 syscalls on one thread (7711 `preadv` and
7711 `writev` of 64 KiB) and used 0.13 s user and 0.32 s system time; FFmpeg
made 310,343 syscalls on 9 threads (16,389 reads of 32 KiB, 2050 writes,
291,661 `futex`) and used 0.74 s user and 1.05 s system time. Peak memory was
13 MiB for both. The FFmpeg build is the minimal reference configuration
with `--disable-x86asm` (zig/testing/reference/README.md); these PCM paths do
no SIMD work, so the gap is the I/O and threading design.

### Machine B: a desktop (run 3)

AMD Ryzen 7 5700X3D, 8 cores and 16 threads, AVX2, 31 GiB, kernel 7.2,
Zig 0.17.0, zffmpeg at `574bd16` in ReleaseFast for the native CPU; the
work directory on tmpfs, W1 and C1 again on ext4 (a USB-attached NVMe);
governor `powersave` with `balance_performance` (amd-pstate). Three FFmpeg
builds: **pinned**, the reference oracle (clang, `--disable-x86asm`);
**native**, the same components with NASM assembly and `-march=native`
([../bench/build-ffmpeg-native.sh](../bench/build-ffmpeg-native.sh)); and
**system**, Arch Linux's n9.0.2 (GCC, LTO, assembly). The full report is
[results/2026-11-06-ryzen-5700x3d.md](results/2026-11-06-ryzen-5700x3d.md).

- **R1**: no buffer with 4 KiB requests 4883 MiB/s, a 64 KiB buffer
  11142–13373, 1 MiB buffers no faster (10878–11580); positional and
  streaming within 3%.
- **R2**: `readSliceAll` 1266–1640 MiB/s, `takeArray` 2928–4809,
  `takeInt` 2937–4705: 2.3–3×.
- **R3** (positional against streaming): 60 KiB skips 22,847 against
  11,824 MiB/s (1.9×), 1 MiB 192,702 against 12,130 (16×), 16 MiB
  2,538,650 against 12,199 (208×). **S1**: 511 `preadv` against 8162
  `readv`, as on A.
- **R4**: pipes run at 11.7–13.6 GiB/s from a 64 KiB buffer on, 3.8 GiB/s
  with no buffer and 4 KiB requests: here the buffer matters for pipes too
  (A's virtualized pipe capped every cell near 1.4 GiB/s).
- **W1**: unbuffered 64-byte writes 87 MiB/s on tmpfs and 34 MiB/s on
  ext4, against 2699 and 2425 with a 64 KiB buffer (31× and 71×); 1 MiB
  writes 3.1–5.1 GiB/s with any buffer.
- **C1**: `streamRemaining` 2708–2730 MiB/s against a read/write loop's
  2348–2477 on tmpfs (+10–16%), 4141 against 3351 on ext4 (+24%), each in
  2 `copy_file_range` calls.
- **Q1**: 4 KiB packets with work, serial 902 MiB/s against 798–812
  through a queue; 64 KiB with work, 906 against 955–961 (+6%); without
  work the queue loses at every size.

**E2E on B**, the PCM paths (median wall time of 5, 512 MiB):

| Operation | zffmpeg | pinned | native | system |
| --- | ---: | ---: | ---: | ---: |
| WAV stream copy to WAV | 0.283 s | 0.358 s | 0.356 s | 0.348 s |
| WAV s16le to AU s16be | 0.398 s | 0.364 s | 0.363 s | 0.353 s |
| WAV to raw s16le | 0.407 s | 0.365 s | 0.365 s | 0.352 s |
| WAV from a pipe to AU | 0.402 s | 0.372 s | 0.369 s | 0.359 s |
| WAV to raw s16le on a pipe | 0.300 s | 0.177 s | 0.171 s | 0.226 s |

zffmpeg is faster only for the stream copy (1.26×); FFmpeg is 8–12% faster
transcoding and 1.7× faster into a pipe, where its reader and writer
threads overlap the read with the writes `cat` waits for. Resources for WAV
to AU are A's: zffmpeg 0.36 s of CPU, 15,536 syscalls, one thread; FFmpeg
0.83–0.86 s of CPU and 257,000–281,000 syscalls (236,000–263,000 `futex`)
on 9 threads; 13 MiB peak (the system build 54 MiB, shared libraries).

**E2E-C on B**, the codec paths (`e2e_codecs.sh`: 10 minutes of tones over
pink noise, s16 stereo 48 kHz, decoded or encoded to a WAV or raw file;
median wall time of 5; instructions retired, all threads):

| Operation | zffmpeg | pinned | native | system | zffmpeg, one core | pinned, one core | native, one core | Instructions: zffmpeg / pinned / native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| WAV to FLAC | 1.344 s | 0.653 s | 0.494 s | 0.573 s | 1.351 s | 1.218 s | 1.016 s | 19.5 / 7.8 / 5.8 G |
| FLAC to WAV | 0.682 s | 0.174 s | 0.138 s | 0.175 s | 0.686 s | 0.739 s | 0.698 s | 6.2 / 4.2 / 3.1 G |
| Ogg Vorbis to WAV | 1.411 s | 0.627 s | 0.388 s | 0.411 s | 1.407 s | 2.039 s | 1.457 s | 17.4 / 7.4 / 4.0 G |
| Ogg Opus to WAV | 2.105 s | 0.989 s | 0.803 s | 0.889 s | 2.105 s | 2.790 s | 2.490 s | 21.5 / 10.6 / 7.4 G |
| MP3 to WAV | 1.353 s | 0.531 s | 0.463 s | 0.503 s | 1.347 s | 1.751 s | 1.617 s | 16.8 / 6.9 / 4.6 G |
| Resample 48 to 44.1 kHz | 0.680 s | 0.583 s | 0.181 s | 0.287 s | 0.679 s | 1.085 s | 0.568 s | 9.4 / 9.2 / 3.0 G |
| s16 to f32le, 512 MiB | 0.738 s | 0.661 s | 0.675 s | 0.546 s | 0.742 s | 1.958 s | 1.907 s | 3.5 / 3.5 / 2.0 G |

The one-core columns run every command under `taskset -c 4`. Three effects
separate in this table:

1. **zffmpeg decodes Ogg and MP3 twice from a file.** The decoded reader's
   counting pass (`format/oggdecode.zig`, `format/mp3decode.zig`) decodes
   the whole stream once to know the sample count before the header, for
   every output, raw ones included. From a pipe, which has no counting
   pass, the same decodes take 0.707 s (MP3) and 0.742 s (Vorbis) instead of
   1.272 s and 1.339 s (raw f32le). Halved, zffmpeg's instructions per
   decode are close to the C reference's: Opus 10.8 against 10.6 G, Vorbis
   8.7 against 7.4, MP3 8.4 against 6.9. FLAC is read with STREAMINFO's
   count and decoded once.
2. **FFmpeg's assembly removes 25–70% of the C's instructions**: the
   resampler 3.1×, Vorbis 1.9×, MP3 1.5×, Opus 1.45×, FLAC 1.35×, the
   s16-to-float conversion 1.8×. zffmpeg's scalar code matches the C
   reference, not the assembly (T58).
3. **FFmpeg's threads turn the same CPU time into 2–5× less wall time on 16
   threads, and cost it on one core.** All cores: FFmpeg spends about as
   much CPU as zffmpeg (MP3 1.43 s pinned against 1.35 s) but finishes in a
   third of the time. One core: zffmpeg is faster than every build for
   every decode, even decoding twice (FFmpeg's system time rises to
   1.0–1.6 s of thread switching), and slower only for FLAC encoding and
   the assembly resampler.

Two of zffmpeg's own costs stand out beyond these: the FLAC encoder runs
2.5× the reference's instructions (a profile puts 42% in
`flacmux.Writer.drain`, where the encoder is inlined, and 12% in MD5), and
FLAC decoding 1.5× (40% in `flac_parser.Parser.scoreHeader`, 13% in the
demuxer's `parsePacketAt`).

## Conclusions

Each holds on both machines unless it says otherwise.

1. **Positional reader for regular files, streaming for everything else.**
   Equal for sequential reads (R1); 2× to 260× faster for skips (R3, S1)
   and the only way to seek back. zffmpeg's CLI and probe already do this.
2. **64 KiB buffers.** Reads peak at 16–64 KiB (R1), small writes need
   64 KiB or more (W1: 31–71× over unbuffered 64-byte writes), and on B a
   pipe needs one too (R4). FFmpeg's 32 KiB, 64 KiB on pipes, is the same
   choice.
3. **`readSliceAll` for fields, bigger reads or `take` in hot loops.** The
   per-call cost (R2) is negligible for headers and visible in per-packet
   loops; `take` needs guaranteed capacity.
4. **Read large payloads straight into their destination.** std's vectored
   read already avoids the extra copy that FFmpeg's direct read avoids.
5. **Stream copy of whole files through `streamRemaining`.** The kernel
   copies, 10–37% faster (C1, S1).
6. **zffmpeg is not faster than FFmpeg in general.** On A (4 vCPUs) it was
   1.15–1.74× faster on the PCM paths; on B (16 threads) it is faster only
   for the stream copy, 8–12% slower transcoding PCM, 1.7× slower into a
   pipe and 2–5× slower on the codec paths (E2E-C). Its single thread uses
   the least CPU and the fewest syscalls on every path but FLAC encoding,
   and wins on one core; FFmpeg's thread per component wins wall time when
   cores are free. Report which machine and core budget a comparison ran
   on, and compare instructions or CPU time for the code itself.
7. **Synchronous until T59, then measure the pipeline with real codecs on a
   multi-core machine.** Q1's byte hash shows that a handoff costs
   microseconds and small packets lose; E2E-C shows that with a codec as the
   work, overlapping demux, decode and output gains 2–5× wall time on 16
   threads. Neither number decides T59 alone: batch handoffs (Q1) and
   measure the wall time and the CPU time (E2E-C), on one core and on all.
8. **Decode once.** A decoded input must not decode the stream ahead to
   count its samples (E2E-C, effect 1); write the header with a
   placeholder and rewrite it at the end on a seekable output, as FFmpeg's
   muxers do (`wavenc.c`, `au.c`, `aiffenc.c`), and skip any count for an
   output that needs none.
9. **Compare against the assembly build too.** The pinned build is the
   oracle for output; for speed, T57 needs both it (the same C algorithms)
   and an assembly build (what users run), since assembly removes 25–70%
   of the instructions (E2E-C, effect 2).
10. **`std.Io.Threaded` is the backend.** `Io.Evented` does not compile in
    0.17.0, nor with 0.17.1's library; event loops (zio, libxev) would
    only matter for many concurrent network streams, which are not planned
    (TODO.md "Not planned").

## Concurrency for T53d and T59

- Keep the conversion pipeline synchronous: demux, decode, filter, encode
  and mux called in turn on one thread, as zffmpeg does now. T53d's
  scheduler needs bounded queues for flow control between several inputs and
  outputs, not threads; implement it with the same synchronous calls first.
- When T59 adds threads, put them where one stage is much heavier than a
  handoff: the pipeline between components (on B, FFmpeg's 2–5× wall-time
  gain on the codec paths comes from decoding on one thread while another
  converts and writes; with no codec work, E2E's PCM paths, it gains little
  or loses), frame or slice threading inside a codec (FFmpeg does it only
  for FLAC decoding among the ported codecs), or independent outputs. Hand
  frames over in batches, so the handoff stays small against the work. Use
  `io.concurrent` for a task that must run beside the caller (a producer and a
  consumer on one bounded queue deadlock if `io.async` runs one inline), move
  batches through `Io.Queue` (`put`/`get` with a minimum count), and measure
  with the real codec in Q1's place before keeping it.
- Cancellation already reaches I/O through `std.Io`'s cancelation points;
  keep mapping `error.Canceled` from the adapter's `.err`, as `withReadCause`
  does, rather than polling a flag as FFmpeg's interrupt callback does.

## Findings for the codebase

- **The decoded readers decode twice** (E2E-C, effect 1):
  `format/oggdecode.zig` and `format/mp3decode.zig` run a counting pass
  over the whole stream when the input can seek, for every output, raw,
  FLAC and Ogg ones included, which then drop the count. It costs 45% of an
  Ogg or MP3 conversion from a file. Conclusion 8 says how to remove it;
  the count also checks that the stream decodes to what was announced
  (`FrameCountMismatch`), which a header rewritten at the end makes
  unnecessary.
- **FLAC decoding spends 53% in the parser and demuxer**
  (`flac_parser.Parser.scoreHeader` 40%, `Demuxer.parsePacketAt` 13%,
  perf on B): 1.5× the reference's instructions for the same algorithm.
  Look first at `checkHeaderMismatch` and the CRCs it computes over the
  bytes between candidate headers.
- **The FLAC encoder runs 2.5× the reference's instructions**: 42% in
  `flacmux.Writer.drain` (the encoder inlined: residual coding and the bit
  writer), 12% in MD5.
- **No SIMD yet** (T58): against the assembly build the largest gaps are
  the resampler (3.1×), Vorbis (1.9×), the s16-to-float conversion (1.8×)
  and MP3 (1.5×).
- `av.file.decodeFile` (`zig/io/file.zig`) opens every file with
  `readerStreaming`. For a regular file a positional reader would skip
  chunks and annotations without reading them (R3). The CLI does not use
  this helper, so nothing user-visible is slow; change it with the next
  change to that file.

## Other references

- **Zig's std** is the authority for every API above; read it before an old
  example.
- **zio** (`.references/zio/src/io.zig`, 114 tests) implements `std.Io` a
  second time. Its tests document the contract: pipes report `Unseekable`,
  streaming reads over a pipe, positional reads, a cancel reaching a group
  task run inline. Read them when T53d/T59 depend on such a rule. Its native
  API is not `std.Io`; its examples mostly use it.
- **ZLS** uses `Io.Group` in a long-running tool: `src/Server.zig:43,327,1388,1441`
  and `src/DocumentStore.zig:961-988` (start tasks, await them, cancel them at
  shutdown).
- **zig-cookbook** has short 0.16 recipes: `assets/src/io/io-tasks.zig`
  (async, groups, select, cancel), `io-sync.zig` (`Io.Queue`),
  `io-file-dir.zig`, `concurrency/threadpool.zig`. Check each against the
  zig-0-17 guide before copying.
- **libxev** was examined and not adopted: a callback event loop over raw
  `std.posix`, not `std.Io` (notes.md).

## Limits of this analysis

- Two machines, page cache (or tmpfs) only; disk-bound and cold-cache
  behavior is in reproduce.md's variants, not measured here. B's governor
  was `powersave` with `balance_performance`.
- Q1's work is a byte-hash loop; E2E-C covers the codecs end to end but not
  a reader and decoder split inside zffmpeg, which T59 must measure.
- E2E-C's inputs are synthetic (tones over pink noise, 10 minutes; Vorbis,
  Opus and MP3 encoded by libvorbis, libopus and LAME at 128–192 kbit/s);
  real music changes the FLAC numbers most.
- The system FFmpeg is a newer release (n9.0.2) with other compiler flags;
  the native build is the like-for-like assembly comparison.
