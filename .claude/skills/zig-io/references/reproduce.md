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
  GNU Make to build the FFmpeg reference.
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

2. Build zffmpeg in ReleaseFast into its own prefix:

   ```bash
   zig build -Doptimize=ReleaseFast -p zig-out-release
   ```

3. Run every measurement; the report goes to standard output:

   ```bash
   bash .claude/skills/zig-io/bench/run_all.sh /path/to/work-dir "$(command -v zig)" zig-out-release/bin/zffmpeg .references/ffmpeg-install/bin/ffmpeg > zig-io-report.md
   ```

   Without the last two arguments the end-to-end section is skipped. The run
   takes about 15 minutes; keep the machine otherwise idle. To rerun one
   table, use the commands in `run_all.sh` by hand from the work directory.

4. Save the report as `results/<date>-<machine>.md` and compare it with the
   recorded runs as below.

## What should hold elsewhere

The analysis' recommendations follow from these comparisons. If one fails on
another machine, record it in the analysis and revisit the recommendation it
supports.

| Check | Recorded (run 1 / run 2 in [results/](results/)) | Supports |
| --- | --- | --- |
| R1: no reader buffer with 4 KiB requests is the slowest case; buffers above 64 KiB give no further gain | 4242 against 5600–6600 MiB/s (run 1), 4803 against 5499–6938 (run 2); 256 KiB and 1 MiB no faster than 64 KiB | 64 KiB default |
| R2: `takeArray`/`takeInt` beat `readSliceAll` per 4-byte field | 2.5× (run 1), 3–5× (run 2) | `take` only in hot loops with guaranteed capacity |
| R3: a positional reader's skip beats a streaming reader's from 64 KiB skips up | 2× at 60 KiB, 15× at 1 MiB, 260× at 16 MiB | positional reader for regular files |
| S1: the streaming reader's skips read the bytes | 8162 `readv` against 511 `preadv` | same |
| R4: pipe throughput barely depends on the buffer | 1.2–1.5 GiB/s for every buffer | 64 KiB on pipes, like FFmpeg |
| W1: unbuffered 64-byte writes are an order of magnitude slower than buffered | 150 against 2800 MiB/s at 64 KiB | buffer every small write |
| C1/S1: `streamRemaining` copies with `copy_file_range` and is not slower than a read/write loop | 2 syscalls; 2955–3202 against 2344–2885 MiB/s (5–37%) | stream copy of whole files |
| Q1: a queue between reader and worker loses to serial for 4 KiB packets | 300 against 600 MiB/s with work | synchronous pipeline for audio |
| E2E: zffmpeg is not slower than the reference FFmpeg, with far fewer syscalls and no threads | 1.19–1.65× (run 1), 1.15–1.74× (run 2) faster; about 15,500 against 310,000 syscalls | the whole design |

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
  `io()`) and compare it with R1. In 0.17.0 it fails to compile (analysis
  "Backends").
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
