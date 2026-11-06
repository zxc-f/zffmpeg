# Reproducing the zig-io measurements

Everything in [analysis.md](analysis.md) can be rerun with the files in
[../bench/](../bench/). Absolute numbers depend on the machine; the
conclusions rest on ratios that should hold on any Linux x86-64 machine, and
this page says which ones to check. Results from another machine go into
[results/](results/) as a new file, named by date and machine, with the
header `run_all.sh` prints.

## What you need

- Linux x86-64. The benchmark program is portable Zig, but the scripts read
  `/proc`, and the end-to-end comparison uses the Linux-only FFmpeg
  reference build. Other platforms wait for TODO.md T62–T63.
- Zig **0.17.0**. Use the official tarball from ziglang.org, or, where only
  PyPI is reachable, the `ziglang` wheel, which carries the same release
  binary and `lib/`:

  ```bash
  pip download --no-deps --only-binary=:all: --platform manylinux_2_12_x86_64 --python-version 3.12 "ziglang==0.17.0" -d zigwheel
  ```

  ```bash
  python3 -I -m zipfile -e zigwheel/ziglang-0.17.0-*.whl zig017 && chmod +x zig017/ziglang/zig && zig017/ziglang/zig version
  ```

- bash, coreutils, `bc`, Python 3 (standard library only). Optional:
  `strace` for the syscall counts. For the end-to-end comparison, clang and
  GNU Make to build the FFmpeg reference, NASM for the assembly build, and
  `hyperfine` (2.0 records instructions and peak memory too) for the codec
  section. A distribution FFmpeg with lavfi, libvorbis, libopus and LAME
  makes the codec inputs; without one they come from the random test data
  and FFmpeg's own encoders, and the MP3 row is skipped.
- About 2 GiB free in the work directory, and enough memory to keep 1 GiB of
  files in the page cache (the runs measure the library and the syscalls, not
  the disk).

## Steps

Run from the zffmpeg repository root. The first two steps are only for the
end-to-end comparison (section E2E).

1. Build the pinned FFmpeg reference, as CI does (README.md "Clone the
   reference repositories" has the source clone):

   ```bash
   bash zig/testing/reference/build-ffmpeg.sh .references/ffmpeg-install
   ```

   Then, for the comparison with assembly (TODO.md T57), the same
   components with NASM and `-march=native`:

   ```bash
   bash .claude/skills/zig-io/bench/build-ffmpeg-native.sh .references/ffmpeg-install .references/ffmpeg-native
   ```

2. Build zffmpeg in ReleaseFast into its own prefix:

   ```bash
   zig build -Doptimize=ReleaseFast -p zig-out-release
   ```

3. Run every measurement; the report goes to standard output:

   ```bash
   bash .claude/skills/zig-io/bench/run_all.sh /path/to/work-dir "$(command -v zig)" zig-out-release/bin/zffmpeg pinned=.references/ffmpeg-install/bin/ffmpeg native=.references/ffmpeg-native/bin/ffmpeg system=/usr/bin/ffmpeg > zig-io-report.md
   ```

   Without zffmpeg and an FFmpeg the end-to-end sections are skipped; list
   the pinned build first (the resource and syscall lines use it). The run
   takes 20–30 minutes; keep the machine otherwise idle, and prefer the
   `performance` governor (`cpupower frequency-set -g performance`); the
   report records the governor. To rerun one table, use the commands in
   `run_all.sh` by hand from the work directory. The codec section again
   on one core, every command with the same CPU budget:

   ```bash
   cd /path/to/work-dir && taskset -c 4 ./e2e_codecs.sh "$PWD" /abs/zffmpeg pinned=/abs/ffmpeg native=/abs/ffmpeg-native
   ```

   A work directory on tmpfs keeps the disk out of the measurements; run
   W1 and C1 on the target file system too.

4. Save the report as `results/<date>-<machine>.md` and compare it with the
   recorded runs as below.

## What should hold elsewhere

The analysis' recommendations follow from these comparisons. If one fails on
another machine, record it in the analysis and revisit the recommendation it
supports.

| Check | Recorded in [results/](results/): runs 1 and 2 on machine A unless marked; run 3 on machine B | Supports |
| --- | --- | --- |
| R1: no reader buffer with 4 KiB requests is the slowest case; buffers above 64 KiB give no further gain | 4242 against 5600–6600 MiB/s (run 1), 4803 against 5499–6938 (run 2); 256 KiB and 1 MiB no faster than 64 KiB | 64 KiB default |
| R2: `takeArray`/`takeInt` beat `readSliceAll` per 4-byte field | 2.5× (run 1), 3–5× (run 2) | `take` only in hot loops with guaranteed capacity |
| R3: a positional reader's skip beats a streaming reader's from 64 KiB skips up | 2× at 60 KiB, 15× at 1 MiB, 260× at 16 MiB | positional reader for regular files |
| S1: the streaming reader's skips read the bytes | 8162 `readv` against 511 `preadv` | same |
| R4: pipe throughput barely depends on the buffer | 1.2–1.5 GiB/s for every buffer | 64 KiB on pipes, like FFmpeg |
| W1: unbuffered 64-byte writes are an order of magnitude slower than buffered | 150 against 2800 MiB/s at 64 KiB | buffer every small write |
| C1/S1: `streamRemaining` copies with `copy_file_range` and is not slower than a read/write loop | 2 syscalls; 2955–3202 against 2344–2885 MiB/s (5–37%) | stream copy of whole files |
| Q1: a queue between reader and worker loses to serial for 4 KiB packets | 300 against 600 MiB/s with work | synchronous pipeline for audio |
| E2E: zffmpeg uses less CPU and far fewer syscalls than FFmpeg on the PCM paths; wall time depends on the cores | A (4 vCPUs): 1.15–1.74× faster wall; B (16 threads, run 3): faster only for stream copy, 8–12% slower transcoding, 1.7× slower into a pipe; both: about 15,500 against 257,000–310,000 syscalls, 0.36 against 0.83–1.8 s of CPU | one thread until T59; report the core budget |
| E2E-C: per decode, zffmpeg's instructions are close to the pinned build's; the assembly build needs 25–70% fewer; the counting pass doubles Ogg and MP3 decoding from a file | run 3 only | conclusions 8 and 9, T57, T58 |
| E2E-C one core: zffmpeg is not slower than FFmpeg on the decodes | run 3: FFmpeg's wall time is 1.02–1.14× zffmpeg's for FLAC, 1.02–1.45× for Vorbis, 1.18–1.33× for Opus, 1.20–1.30× for MP3 | FFmpeg's threads cost on a busy machine |

Numbers that depend on the machine and are not conclusions: absolute MiB/s,
the exact buffer size where R1 peaks within 16–64 KiB, and the C1 margin
(`copy_file_range` is a reflink or an in-kernel copy depending on the file
system).

## Variants worth running

- **Cold cache.** As root, `sync; echo 3 > /proc/sys/vm/drop_caches` before
  each run of R1, R3 and E2E measures the disk too. The positional reader's
  advantage on skips should grow (the streaming reader reads skipped data
  from the disk); buffer-size effects should shrink.
- **Another file system.** `copy_file_range` behaves differently on XFS,
  Btrfs (reflinks) and network file systems; rerun C1.
- **A newer Zig.** If `std.Io.Evented` compiles, add an `evented` command to
  `io_bench.zig` (init `Io.Evented`, then the `read` command with its
  `io()`) and compare it with R1. It fails to compile in 0.17.0 and with
  0.17.1's library (analysis "The Zig source"); try a later library with
  the pinned compiler: `zig build-exe --zig-lib-dir <clone-at-tag>/lib`.
- **Real codecs.** Q1 uses a byte-hash loop as the work. Before T59 adds
  threads to a decoder or the scheduler, repeat Q1 with the real decoder in
  place of `work` and the real packet sizes.

## Changing the benchmarks

Add a command to `bench/io_bench.zig`, its table to `bench/run_all.sh`, and
the result and conclusion to analysis.md in the same change. Keep the
medians (5 runs, 3 for writes and copies) so new tables compare with the old
ones. `io_bench.zig` is not compiled by `zig build` or CI; check it with
`zig build-exe -OReleaseFast .claude/skills/zig-io/bench/io_bench.zig` and
`zig fmt --check` after editing.
