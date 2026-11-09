#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project: a benchmark helper, not part of the port.
"""A feature's quick speed check against FFmpeg (CLAUDE.md "Speed check").

Times one conversion with hyperfine, every command pinned to one core (the
same CPU budget, FFmpeg's threads included):

  zffmpeg (ReleaseFast)  input file -> output file
  zffmpeg (ReleaseFast)  input on a pipe -> output file
  reference ffmpeg       the pinned C build without assembly (the oracle)
  native ffmpeg          the same revision with x86 assembly and
                         -march=native, when built (.claude/skills/zig-io/
                         bench/build-ffmpeg-native.sh)

and prints each median with its ratio to the reference build. It warns
when zffmpeg from a file takes more than 1.5 times the reference build
(profile it: `perf record`), and when zffmpeg from a file takes more than
1.3 times zffmpeg from a pipe: the file path doing work the pipe path does
not, as the decoded readers' counting pass did (the zig-io skill's E2E-C).
Against the native build zffmpeg is expected to be slower where FFmpeg has
assembly (T58); that ratio is for the record.

  speed_check.py [--runs N] [--core C] <work-dir> <input> <output-ext> [output options...]

<input> is a file, or `@base` for a 10-minute stereo 44.1 kHz s16 WAV the
script writes into <work-dir> once, or `@base:<ext>:<ffmpeg options>` for
that WAV encoded by the reference build (for example
`@base:caf:-c:a alac`). The output options go to both programs, after the
input; the output is `<work-dir>/out.<output-ext>`. Builds zffmpeg with
`zig build -Doptimize=ReleaseFast` into <work-dir>/zffmpeg-fast (the
repository's zig-out stays as it is).
"""

import argparse
import hashlib
import json
import math
import os
import pathlib
import shutil
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
REFERENCE = ROOT / ".references" / "ffmpeg-install" / "bin" / "ffmpeg"
NATIVE = ROOT / ".references" / "ffmpeg-native" / "bin" / "ffmpeg"
ZIG = os.environ.get("ZIG", "zig")
SLOWER_THAN_REFERENCE = 1.5
FILE_OVER_PIPE = 1.3


def base_wav(work):
    """10 minutes of stereo 44.1 kHz s16, long enough that the codec, not
    the programs' start, dominates: one minute of two slowly gliding tones
    over smoothed noise (closer to music than random bytes, which lossless
    codecs store verbatim), repeated ten times."""
    path = work / "base.wav"
    if path.exists():
        return path
    rate, seconds = 44100, 60
    frames = rate * seconds
    state, memory = 12345, [0.0, 0.0]
    data = bytearray()
    for i in range(frames):
        t = i / rate
        for c in range(2):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            memory[c] = memory[c] * 0.95 + ((state >> 8) / 4194304.0 - 1.0) * 0.05
            v = 7000 * math.sin(2 * math.pi * (220 + 30 * math.sin(t / 3) + 110 * c) * t) + 9000 * memory[c]
            data += struct.pack("<h", max(-32768, min(32767, int(v))))
    data = bytes(data) * 10
    header = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
              + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16) + b"data" + struct.pack("<I", len(data)))
    path.write_bytes(header + data)
    return path


def resolve_input(work, spec):
    if not spec.startswith("@base"):
        return pathlib.Path(spec).resolve()
    base = base_wav(work)
    if spec == "@base":
        return base
    _, ext, options = spec.split(":", 2)
    name = hashlib.sha256(spec.encode()).hexdigest()[:12]
    path = work / f"base_{name}.{ext}"
    if not path.exists():
        subprocess.run([str(REFERENCE), "-nostdin", "-v", "error", "-y", "-i", str(base), *options.split(), str(path)],
                       check=True)
    return path


def build_zffmpeg(work):
    prefix = work / "zffmpeg-fast"
    subprocess.run([ZIG, "build", "-Doptimize=ReleaseFast", "-p", str(prefix)], cwd=ROOT, check=True)
    return prefix / "bin" / "zffmpeg"


def stats(result):
    """Median wall, user and system time and peak memory, from hyperfine
    2's `summary` or 1's flat fields."""
    if "summary" in result:
        summary = result["summary"]
        rss = summary.get("memory_peak_resident", {}).get("median")
        return {"median": summary["time_wall_clock"]["median"], "user": summary["time_user"]["median"],
                "system": summary["time_system"]["median"], "rss": rss}
    return {"median": result["median"], "user": result["user"], "system": result["system"], "rss": None}


def quote(parts):
    return " ".join("'" + str(p).replace("'", "'\\''") + "'" for p in parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--core", type=int, default=2)
    parser.add_argument("work")
    parser.add_argument("input")
    parser.add_argument("ext")
    parser.add_argument("options", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if shutil.which("hyperfine") is None:
        sys.exit("hyperfine is required")
    work = pathlib.Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    source = resolve_input(work, args.input)
    zffmpeg = build_zffmpeg(work)
    out = work / f"out.{args.ext}"
    pin = ["taskset", "-c", str(args.core)]
    commands = {
        "zffmpeg (file)": quote(pin + [zffmpeg, "-y", "-i", source, *args.options, out]),
        # Redirecting a regular file leaves stdin seekable in zffmpeg.
        # Both processes share the pinned CPU budget through a real pipe.
        "zffmpeg (pipe)": "set -o pipefail; " + quote(pin + ["cat", source]) + " | " + quote(pin + [zffmpeg, "-y", "-i", "-", *args.options, out]),
        "reference ffmpeg": quote(pin + [REFERENCE, "-nostdin", "-v", "error", "-y", "-i", source, *args.options, out]),
    }
    if NATIVE.exists():
        commands["native ffmpeg"] = quote(pin + [NATIVE, "-nostdin", "-v", "error", "-y", "-i", source, *args.options,
                                                 out])
    # Every command must work before it is timed.
    for label, command in commands.items():
        done = subprocess.run(command, shell=True, executable="bash", capture_output=True)
        if done.returncode != 0:
            sys.exit(f"{label} failed: {done.stderr.decode(errors='replace').strip()}")
    report = work / "speed.json"
    hyper = ["hyperfine", "--shell", "bash", "--warmup", "1", "--runs", str(args.runs), "--export-json", str(report), "--style", "none"]
    for label, command in commands.items():
        hyper += ["--command-name", label, command]
    subprocess.run(hyper, check=True, stdout=subprocess.DEVNULL)
    # hyperfine reports the commands in the order given.
    results = {label: stats(r) for label, r in zip(commands, json.loads(report.read_text())["results"])}
    median = {label: results[label]["median"] for label in commands}
    reference = median["reference ffmpeg"]
    print(f"input {source.name} ({source.stat().st_size} bytes) -> .{args.ext} {' '.join(args.options)}; "
          f"core {args.core}, {args.runs} runs")
    print(f"{'command':18} {'median':>9} {'user':>9} {'system':>9} {'peak RSS':>9} {'vs reference':>13}")
    for label in commands:
        r = results[label]
        rss = f"{r['rss'] / 2**20:6.1f} MiB" if r["rss"] is not None else "       -"
        print(f"{label:18} {r['median']:8.3f}s {r['user']:8.3f}s {r['system']:8.3f}s {rss:>9} "
              f"{r['median'] / reference:12.2f}x")
    warnings = []
    if median["zffmpeg (file)"] > SLOWER_THAN_REFERENCE * reference:
        warnings.append(f"zffmpeg takes {median['zffmpeg (file)'] / reference:.2f}x the reference build's time: "
                        f"profile it (perf record) and fix it, or record why in notes.md")
    if median["zffmpeg (file)"] > FILE_OVER_PIPE * median["zffmpeg (pipe)"]:
        warnings.append(f"zffmpeg from a file takes {median['zffmpeg (file)'] / median['zffmpeg (pipe)']:.2f}x its "
                        f"time from a pipe: the file path does more work (a second pass?)")
    for w in warnings:
        print(f"WARNING: {w}")
    if not warnings:
        print("ok")


if __name__ == "__main__":
    main()
