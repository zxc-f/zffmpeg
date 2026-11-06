---
name: zig-io
description: How to write I/O code in zffmpeg with Zig 0.17.0's std.Io, measured against FFmpeg's libavformat I/O. Use it whenever you write or change code that opens, reads, writes, skips, seeks or copies files, pipes or standard input/output; adds a demuxer, muxer or parser's read/write path; picks reader or writer buffers; rewrites a header; adds stream copy; or plans threads, queues or cancellation (T53d scheduler, T59 threading). Use it together with zig-0-17, which covers the language and API breaks.
---

# I/O in zffmpeg

zffmpeg reaches the OS only through the injected `std.Io` (CLAUDE.md "Portable
Zig code"). This skill says which std.Io tool to use where, and why, from
FFmpeg's C I/O layer read side by side with Zig 0.17.0's std and from
measurements on Linux x86-64. [references/analysis.md](references/analysis.md)
has the sources (file and line), the tables and the reasoning;
[references/reproduce.md](references/reproduce.md) reruns everything on
another machine with [bench/run_all.sh](bench/run_all.sh).

## Workflow

1. Load `zig-0-17` too: it owns the language and API rules; this skill owns the
   I/O choices. CLAUDE.md wins over both.
2. Find the row below for what you are writing. Read the analysis section it
   names before deviating from it.
3. Check FFmpeg's behavior for the format first (`libavformat/<format>.c`,
   `aviobuf.c`): what it reads, skips, seeks and rewrites. Match its observable
   behavior; the I/O mechanism is ours.
4. Run the checklist on every changed hunk. A claim that one way is faster
   needs a measurement with `bench/io_bench.zig` or `run_all.sh`, recorded in
   the analysis; do not reason from syscall counts alone.

## Which tool

| Situation | Use | Why (analysis section) |
| --- | --- | --- |
| Input that is a regular file | `file.reader(io, buffer)` (positional) | Skips and seeks cost no syscall; the streaming reader reads every skipped byte (R3, S1). It falls back to streaming by itself if `pread` fails. |
| Pipe, standard input, or unknown kind | `file.readerStreaming(io, buffer)` | Never seeks; no failed `pread` first. Decide with `stat().kind == .file` (`av.file.regularLength`), as `zig/cli/ffmpeg.zig` does. Standard input that is a regular file is read positionally from offset 0, an open question in notes.md (FFmpeg's `pipe:` never seeks). |
| Reader and writer buffers | 64 KiB (`av.file.default_buffer_len`) | 16 to 64 KiB is the measured optimum for reads (R1), writes need 64 KiB or more (W1), pipes are capped by the kernel (R4). FFmpeg uses 32 KiB, 64 KiB for pipes. Bigger is not faster. |
| Header fields | `readSliceAll` into a local array, then `std.mem.readInt` | Works with any buffer size, including 0. About 4 ns a call (R2): fine for headers. |
| Per-packet or per-sample loops | One `readSliceAll` of the whole header or block, or `take`/`peek` when the adapter guarantees the capacity | `takeArray`/`takeInt` are 2.5–5× cheaper per call (R2) but assert `buffer.len >= n`. |
| Large reads (packets, payload) | `readSliceAll`/`readSliceShort` straight into the destination | One `readv` fills the destination and tops up the buffer: FFmpeg's direct read plus read-ahead (analysis "Zig 0.17.0's std.Io", Reader). |
| Skipping untrusted lengths | `zig/io/skip.zig` (`discardShort`/`discardAll`) | std's `discardShort` overflows `seek + n` on huge skips. On a positional reader a skip is free. |
| Seeking an input | `av.seek.Seeker.file(&reader)` on a positional reader | `seekTo` only moves the logical position; streaming readers cannot seek back. |
| Output file | Create with `.exclusive = true` first, `writerStreaming`, flush at `finish`; seek back (header rewrite) only when `stat().kind == .file` | FFmpeg rewrites sizes only on seekable output (`wavenc.c`, `au.c`, `flacenc.c`, `aiffenc.c`); CLAUDE.md's cleanup rules. Writer mode does not change speed (W1). |
| Whole-file copy with no re-mux | `reader.interface.streamRemaining(&writer.interface)` | Reaches `File.Writer.sendFile`: `copy_file_range`, 2 syscalls for 512 MiB, 5–37% faster than a read/write loop (C1, S1). |
| Concurrency | Synchronous by default. `io.concurrent` (never `io.async`) for a task that must run beside the caller; `Io.Queue` with batches | Each queue handoff costs microseconds; a reader/decoder split of small audio packets halved throughput (Q1). 291,661 of FFmpeg's 310,343 syscalls on a WAV to AU conversion were `futex` calls of its thread-per-component scheduler; zffmpeg made 15,481 on one thread (E2E). |
| Event-driven backend | None: `std.Io.Threaded` from `std.process.Init` | `std.Io.Evented` (io_uring) does not compile in Zig 0.17.0. Libraries (zio, libxev) are references, not dependencies (notes.md). |

## Checklist before sending I/O code

- The reader mode follows the input kind: positional for regular files,
  streaming for pipes and stdin. A path that must also take a pipe is tested
  with a pipe: a `probe_cases` entry with `stdin_fixture` or a `convert_cases`
  entry with `stdin_input` in `build.zig`.
- Buffers are caller-owned, live as long as the adapter, and the adapter is
  built in its final place before `.interface` is borrowed. Reader views
  (`take`, `peek`, `buffered`) are not kept across the next read.
- `take`/`peek`/`takeArray`/`takeInt` only where the buffer capacity is
  guaranteed by the caller; everywhere else `readSliceAll` into local storage.
- Skips of lengths from the input go through `zig/io/skip.zig`.
- `error.EndOfStream` becomes the domain error (`Truncated`) at the parser
  boundary; `error.ReadFailed`/`WriteFailed` are replaced by the adapter's
  `.err`, which carries `error.Canceled` (CLAUDE.md, `withReadCause`).
- Output: every request-only check runs before the file is created; header
  rewrites and failure cleanup touch only a regular file this run created;
  `finish` flushes, and a flush failure is an error even after partial output.
- No per-byte or per-field syscall: anything written in pieces smaller than
  4 KiB goes through a buffer of at least 64 KiB (W1: 150 MiB/s unbuffered
  64-byte writes against 2.8 GiB/s buffered).
- No thread or queue without a measurement showing a gain on the target
  workload (Q1). Bounded queues carry batches, not single small packets.
  `Io.Group.async` may run inline; a producer and consumer joined by a bounded
  queue use `io.concurrent`, or they can deadlock.
- Tests cover `Reader.fixed`, one-byte reads (`std.testing.Reader` with
  `artificial_limit = .limited(1)`), `Reader.failing`, and real files with
  0, 1, 64 and 64 KiB buffers (CLAUDE.md "Zig 0.17 I/O and test patterns").

## FFmpeg's I/O layer in std.Io terms

| FFmpeg (`libavformat/aviobuf.c`, `avio.c`, `file.c`) | std.Io |
| --- | --- |
| `AVIOContext` buffer, `IO_BUFFER_SIZE` 32768 | `Io.Reader`/`Io.Writer` with a caller buffer (64 KiB here) |
| Pipe input buffer doubled (`ffio_fdopen`) | `readerStreaming` with the same 64 KiB |
| `avio_read` direct read when the request exceeds the buffer | `readSliceShort`: vectored read into the destination and the buffer |
| `ffio_read_indirect` (view into the buffer) | `take`, `peek` (capacity asserted) |
| `avio_skip`/`avio_seek`: read forward within buffer + 32 KiB, else `lseek` | Positional reader: logical position only; streaming: reads through |
| `AVIO_SEEKABLE_NORMAL` checked before header rewrites | `stat().kind == .file` before using `av.seek.OutputSeeker` |
| `ff_check_interrupt` before every transfer | Cancelation points inside `std.Io` syscalls; `error.Canceled` via `.err` |
| `av_probe_input_buffer2` and `ffio_rewind_with_probe_data` (probe 2048 bytes, doubling; replay them) | `zig/format/detect.zig` with its `Replay` reader (`zig/format/replay.zig`) |
| `ffmpeg_sched.c`: a thread per component, queues of 2 | Not adopted; see Q1 and the analysis' "Concurrency" before T53d/T59 |
