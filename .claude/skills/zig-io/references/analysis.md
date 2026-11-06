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
| Zig standard library | the 0.17.0 release's `lib/std` | the toolchain (`zig env` prints `lib_dir`), or `.references/zig/lib` |
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

## Conclusions

1. **Positional reader for regular files, streaming for everything else.**
   Equal for sequential reads (R1); 2× to 260× faster for skips (R3, S1)
   and the only way to seek back. zffmpeg's CLI and probe already do this.
2. **64 KiB buffers.** Reads peak at 16–64 KiB (R1), small writes need
   64 KiB or more (W1), pipes are kernel-bound (R4). FFmpeg's 32 KiB, 64 KiB
   on pipes, is the same choice.
3. **`readSliceAll` for fields, bigger reads or `take` in hot loops.** The
   per-call cost (R2) is negligible for headers and visible in per-packet
   loops; `take` needs guaranteed capacity.
4. **Read large payloads straight into their destination.** std's vectored
   read already avoids the extra copy that FFmpeg's direct read avoids.
5. **Stream copy of whole files through `streamRemaining`.** The kernel
   copies (C1, S1).
6. **No threads in the audio pipeline until a measurement shows a gain.**
   Small packets lose to handoffs (Q1), and FFmpeg's thread-per-component
   design is the main reason it used 4× the CPU and 20× the syscalls of
   zffmpeg here (E2E).
7. **`std.Io.Threaded` is the backend.** `Io.Evented` does not compile in
   0.17.0; event loops (zio, libxev) would only matter for many concurrent
   network streams, which are not planned (TODO.md "Not planned").

## Concurrency for T53d and T59

- Keep the conversion pipeline synchronous: demux, decode, filter, encode
  and mux called in turn on one thread, as zffmpeg does now. T53d's
  scheduler needs bounded queues for flow control between several inputs and
  outputs, not threads; implement it with the same synchronous calls first.
- When T59 adds threads, put them where one stage is much heavier than a
  handoff: frame or slice threading inside a codec (FFmpeg does it only for
  FLAC decoding among the ported codecs), or independent outputs. Use
  `io.concurrent` for a task that must run beside the caller (a producer and a
  consumer on one bounded queue deadlock if `io.async` runs one inline), move
  batches through `Io.Queue` (`put`/`get` with a minimum count), and measure
  with the real codec in Q1's place before keeping it.
- Cancellation already reaches I/O through `std.Io`'s cancelation points;
  keep mapping `error.Canceled` from the adapter's `.err`, as `withReadCause`
  does, rather than polling a flag as FFmpeg's interrupt callback does.

## Findings for the codebase

- `av.file.decodeFile` (`zig/io/file.zig:86-94`) opens every file with
  `readerStreaming`. For a regular file a positional reader would skip
  chunks and annotations without reading them (R3). The CLI does not use
  this helper, so nothing user-visible is slow; change it with the next
  change to that file.
- Nothing else in the current I/O paths contradicts the measurements.

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

- One machine, page cache only; disk-bound and cold-cache behavior is in
  reproduce.md's variants, not measured here.
- Q1's work is a byte-hash loop, not a codec; the end-to-end runs cover PCM
  paths, where I/O dominates. Codec-heavy paths (FLAC encoding, Vorbis and
  Opus decoding) are CPU-bound and not compared here.
- The FFmpeg comparison uses the project's minimal reference build, not a
  distribution build with assembly and every component.
