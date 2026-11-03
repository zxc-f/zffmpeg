#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
"""Compare the fixtures and Zig-written files with the FFmpeg reference build (T10, T19a).

WAV fixtures: for accepted ones, FFmpeg's ffprobe must report the expected
stream parameters and duration, ffmpeg must decode exactly the expected samples,
and zffprobe must print the expected report. For rejected ones, zffprobe must
exit with the contract's status and error name; FFmpeg's own verdict is
recorded as an intentional difference, not checked.

AU fixtures (T12a): FFmpeg reads each one forced with `-f au` (parser
acceptance) and by content detection, recorded separately. Accepted ones must
give the expected parameters and samples, apart from the listed differences.

Zig-written files: the write driver writes every writer-output stream, which
must equal its fixture byte for byte and decode in FFmpeg to the expected
samples.

Checks whose Zig code has not landed yet are listed as not implemented, never
counted as passes or skips. Expectations come from generate.py, the same
independent source as the committed fixtures.

    python3 zig/testing/reference/compare.py --ffmpeg BIN --ffprobe BIN \\
        --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver \\
        [--report report.md]
"""

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parent / "fixtures"
sys.path.insert(0, str(FIXTURES))
import generate  # noqa: E402

# zffprobe exit status for each contract error (port.md "Initial probe output").
EXIT_STATUS = {
    "InvalidRiff": 2,
    "InvalidAu": 2,
    "InvalidWave": 2,
    "InvalidFormat": 2,
    "Truncated": 2,
    "UnsupportedFormat": 3,
    "UnsupportedStreamingSize": 3,
    "LimitExceeded": 5,
}
LAYOUT = {1: "mono", 2: "stereo"}

# Checks whose Zig code has not landed yet (TODO.md "Coverage and comparison
# rules"). Each is reported as not implemented, never as a pass or a skip; the
# subtask that owns it deletes its entry here, which makes the check mandatory.
NOT_IMPLEMENTED = {}

# zffprobe detects AU by its `.snd` magic and sends anything else to the WAV
# parser, so an AU fixture without that magic reports the WAV parser's error.
ZFFPROBE_AU_DETECTION = {
    "au_bad_magic": "InvalidRiff",
}

# Understood differences in FFmpeg's metadata for accepted fixtures, matched on
# the exact value; see zig/testing/reference/README.md. Anything else fails.
KNOWN_FIELD_DIFFERENCES = {
    # A plain tag-1 header has no channel mask: FFmpeg leaves the order
    # unspecified, while the contract reports the default layout.
    ("channel_layout", "unknown"): "no channel mask in a plain WAV header",
}
KNOWN_FIXTURE_DIFFERENCES = {
    # FFmpeg reads a data size of 0 as unknown length and reports no duration.
    ("empty_data", "duration_ts", "N/A"): "FFmpeg reads data size 0 as unknown length",
}

# The same field difference for AU, whose header has no layout field either.
KNOWN_AU_FIELD_DIFFERENCES = {
    ("channel_layout", "unknown"): "an AU header has no channel layout",
}
# Accepted AU fixtures that FFmpeg's content probe does not detect.
KNOWN_AU_DETECTION_DIFFERENCES = {
    "au_empty_data": "FFmpeg's AU probe needs a nonzero data size",
}
# Accepted AU fixtures whose FFmpeg decode continues past the expected samples:
# its output must start with them.
KNOWN_AU_DECODE_DIFFERENCES = {
    "au_trailing_bytes_after_data": "FFmpeg decodes the bytes after the declared data",
}


def run(*command):
    return subprocess.run([str(part) for part in command], capture_output=True, timeout=120)


def key_values(text):
    fields = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            fields[key] = value
    return fields


def text(data):
    return data.decode(errors="replace").strip()


def forced(input_format):
    return ["-f", input_format] if input_format else []


def ffprobe(binary, path, input_format=None):
    process = run(
        binary, "-v", "error",
        "-show_entries",
        "stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,time_base,duration_ts:format=format_name",
        "-of", "default=noprint_wrappers=1",
        *forced(input_format), path,
    )
    return process.returncode, key_values(text(process.stdout)), text(process.stderr)


def ffmpeg_decode(binary, path, input_format=None):
    process = run(binary, "-v", "error", "-nostdin", *forced(input_format), "-i", path,
                  "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-")
    return process.returncode, process.stdout, text(process.stderr)


def detected_format(binary, path):
    """The format FFmpeg's content probe picks, or None if it detects nothing."""
    code, fields, _ = ffprobe(binary, path)
    return fields.get("format_name") if code == 0 else None


def zffprobe(binary, path):
    process = run(binary, path)
    return process.returncode, key_values(text(process.stdout)), text(process.stderr)


def zffprobe_raw(binary, *args, data=None):
    """Exit status, stdout and stderr; with `data`, standard input is a pipe."""
    process = subprocess.run([str(part) for part in (binary, *args)], input=data,
                             capture_output=True, timeout=120)
    return process.returncode, process.stdout, process.stderr


def first_line(message):
    return message.splitlines()[0] if message else ""


def clean(message, path):
    """Removes run-specific paths and pointer addresses from FFmpeg messages."""
    message = message.replace(f"{path}: ", "")
    return re.sub(r" @ 0x[0-9a-f]+\]", "]", message)


def compare_accepted(fixture, args, path):
    channels, rate, samples = fixture.accept
    frames = len(samples) // channels
    problems, notes = [], []

    code, fields, err = ffprobe(args.ffprobe, path)
    expected = {
        "format_name": "wav",
        "codec_name": "pcm_s16le",
        "sample_fmt": "s16",
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "time_base": f"1/{rate}",
        "duration_ts": str(frames),
    }
    if code != 0:
        problems.append(f"ffprobe failed: {clean(first_line(err), path)}")
    else:
        for key, value in expected.items():
            got = fields.get(key)
            if got == value:
                continue
            reason = KNOWN_FIXTURE_DIFFERENCES.get((fixture.name, key, got)) or KNOWN_FIELD_DIFFERENCES.get((key, got))
            if reason:
                notes.append(f"`{key}={got}` ({reason})")
            else:
                problems.append(f"ffprobe {key}={got!r}, expected {value!r}")

    code, raw, err = ffmpeg_decode(args.ffmpeg, path)
    if code != 0:
        problems.append(f"ffmpeg failed: {clean(first_line(err), path)}")
    elif raw != generate.pcm(samples):
        problems.append(f"ffmpeg decoded {len(raw) // 2} samples that differ from the {len(samples)} expected")

    code, fields, err = zffprobe(args.zffprobe, path)
    z_expected = {
        "format": "wav",
        "codec": "pcm_s16le",
        "sample_fmt": "s16",
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "nb_samples": str(frames),
        "duration_num": str(frames),
        "duration_den": str(rate),
    }
    if code != 0 or fields != z_expected:
        problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")

    verdict = "same samples and stream" if not problems else "differs"
    if notes:
        verdict += "; " + "; ".join(notes)
    return problems, f"{LAYOUT[channels]}, {rate} Hz, {frames} frames", "exit 0, report matches", verdict


def compare_rejected(fixture, args, path):
    problems = []
    want = EXIT_STATUS[fixture.reject]
    code, _, err = zffprobe(args.zffprobe, path)
    if code != want or not err.endswith(f": {fixture.reject}"):
        problems.append(f"zffprobe exited {code} ({err}), expected {want} with {fixture.reject}")

    probe_code, fields, probe_err = ffprobe(args.ffprobe, path)
    decode_code, raw, decode_err = ffmpeg_decode(args.ffmpeg, path)
    if probe_code == 0 and decode_code == 0:
        layout = fields.get("channel_layout") or f"{fields.get('channels', '?')} channels"
        verdict = f"accepts: {layout}, {fields.get('sample_rate', '?')} Hz, {len(raw) // 2} samples"
    else:
        reason = clean(first_line(probe_err or decode_err), path) or f"exit {probe_code or decode_code}"
        verdict = f"rejects: {reason}"
    return problems, f"`{fixture.reject}` (exit {want})", f"exit {code}", verdict


def expected_stream(format_name, codec_name, channels, rate, frames):
    return {
        "format_name": format_name,
        "codec_name": codec_name,
        "sample_fmt": "s16",
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "time_base": f"1/{rate}",
        "duration_ts": str(frames),
    }


def frames_text(frames):
    return f"{frames} frame{'s' if frames != 1 else ''}"


def check_stream(args, fixture_name, path, expected, samples, input_format=None, decode_note=None,
                 field_differences=KNOWN_FIELD_DIFFERENCES):
    """ffprobe fields and decoded samples; returns (problems, notes)."""
    problems, notes = [], []
    code, fields, err = ffprobe(args.ffprobe, path, input_format)
    if code != 0:
        problems.append(f"ffprobe failed: {clean(first_line(err), path)}")
    else:
        for key, value in expected.items():
            got = fields.get(key)
            if got == value:
                continue
            reason = KNOWN_FIXTURE_DIFFERENCES.get((fixture_name, key, got)) or field_differences.get((key, got))
            if reason:
                notes.append(f"`{key}={got}` ({reason})")
            else:
                problems.append(f"ffprobe {key}={got!r}, expected {value!r}")

    code, raw, err = ffmpeg_decode(args.ffmpeg, path, input_format)
    want = generate.pcm(samples)
    if code != 0:
        problems.append(f"ffmpeg failed: {clean(first_line(err), path)}")
    elif decode_note is not None:
        if not raw.startswith(want) or len(raw) == len(want):
            problems.append(f"ffmpeg decoded {len(raw) // 2} samples; expected the {len(samples)} expected ones and more")
        else:
            notes.append(f"decodes {len(raw) // 2} samples ({decode_note})")
    elif raw != want:
        problems.append(f"ffmpeg decoded {len(raw) // 2} samples that differ from the {len(samples)} expected")
    return problems, notes


def zffprobe_report(container, codec, channels, rate, frames):
    return {
        "format": container,
        "codec": codec,
        "sample_fmt": "s16",
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "nb_samples": str(frames),
        "duration_num": str(frames),
        "duration_den": str(rate),
    }


def check_zffprobe_au(fixture, args, path):
    """zffprobe on one AU fixture (T12c); returns (problems, summary)."""
    code, fields, err = zffprobe(args.zffprobe, path)
    if fixture.accept is not None:
        channels, rate, samples = fixture.accept
        want = zffprobe_report("au", "pcm_s16be", channels, rate, len(samples) // channels)
        if code != 0 or fields != want:
            return [f"zffprobe exited {code} with {fields or first_line(err)}"], f"exit {code}"
        return [], "exit 0, report matches"
    error = ZFFPROBE_AU_DETECTION.get(fixture.name, fixture.reject)
    status = EXIT_STATUS[error]
    if code != status or not err.endswith(f": {error}"):
        return [f"zffprobe exited {code} ({err}), expected {status} with {error}"], f"exit {code}"
    if error != fixture.reject:
        return [], f"exit {code}, `{error}` (not AU by content)"
    return [], f"exit {code}"


def compare_au_accepted(fixture, args, path):
    channels, rate, samples = fixture.accept
    frames = len(samples) // channels
    expected = expected_stream("au", "pcm_s16be", channels, rate, frames)
    problems, notes = check_stream(args, fixture.name, path, expected, samples, "au",
                                   KNOWN_AU_DECODE_DIFFERENCES.get(fixture.name),
                                   KNOWN_AU_FIELD_DIFFERENCES)

    detected = detected_format(args.ffprobe, path)
    detection_note = KNOWN_AU_DETECTION_DIFFERENCES.get(fixture.name)
    if detected == "au":
        detection = "au"
        if detection_note:
            problems.append(f"FFmpeg now detects {fixture.name}; remove its known difference")
    elif detection_note:
        detection = f"not detected ({detection_note})"
    else:
        detection = f"{detected or 'not detected'}"
        problems.append(f"FFmpeg's content probe gave {detected!r}, expected 'au'")

    verdict = "same samples and stream" if not problems else "differs"
    if notes:
        verdict += "; " + "; ".join(notes)
    return problems, f"{LAYOUT[channels]}, {rate} Hz, {frames_text(frames)}", verdict, detection


def compare_au_rejected(fixture, args, path):
    probe_code, fields, probe_err = ffprobe(args.ffprobe, path, "au")
    decode_code, raw, decode_err = ffmpeg_decode(args.ffmpeg, path, "au")
    if probe_code == 0 and decode_code == 0:
        layout = fields.get("channel_layout") or f"{fields.get('channels', '?')} channels"
        verdict = f"accepts: {layout}, {fields.get('sample_rate', '?')} Hz, {len(raw) // 2} samples"
    else:
        reason = clean(first_line(probe_err or decode_err), path) or f"exit {probe_code or decode_code}"
        verdict = f"rejects: {reason}"
    detection = detected_format(args.ffprobe, path) or "not detected"
    return [], f"`{fixture.reject}`", verdict, detection


def compare_au(args, lines, failures):
    lines += [
        "",
        "## AU fixtures",
        "",
        "FFmpeg reads each file forced with `-f au` (parser acceptance) and by content detection.",
        "",
        "| Fixture | Expected | FFmpeg with `-f au` | FFmpeg detection | zffprobe | Result |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    fixtures = generate.build_au_fixtures()
    accepted_ok = rejected_ok = ffmpeg_accepts_rejected = 0
    for fixture in fixtures:
        path = FIXTURES / "au" / f"{fixture.name}.au"
        if not path.exists():
            failures.append(f"{fixture.name}: fixture file is missing")
            continue
        if path.read_bytes() != fixture.data:
            failures.append(f"{fixture.name}: fixture file differs from generate.py")
            continue
        if fixture.accept is not None:
            problems, expected, theirs, detection = compare_au_accepted(fixture, args, path)
        else:
            problems, expected, theirs, detection = compare_au_rejected(fixture, args, path)
            ffmpeg_accepts_rejected += theirs.startswith("accepts")
        if "au-probe" in NOT_IMPLEMENTED:
            ours = "not implemented (T12c)"
        else:
            probe_problems, ours = check_zffprobe_au(fixture, args, path)
            problems = problems + probe_problems
        if fixture.accept is not None:
            accepted_ok += not problems
        else:
            rejected_ok += not problems
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {expected} | {theirs} | {detection} | {ours} | {result} |")
        failures.extend(f"{fixture.name}: {problem}" for problem in problems)

    accepted = sum(1 for fixture in fixtures if fixture.accept is not None)
    rejected = len(fixtures) - accepted
    if "au-probe" in NOT_IMPLEMENTED:
        lines += ["", f"Accepted AU fixtures FFmpeg reads as expected: {accepted_ok}/{accepted}."]
    else:
        lines += [
            "",
            f"Accepted AU fixtures FFmpeg and zffprobe read as expected: {accepted_ok}/{accepted}.",
            f"Rejected AU fixtures with zffprobe's expected status and error: {rejected_ok}/{rejected}.",
        ]
    lines.append(f"Rejected AU fixtures that FFmpeg accepts with `-f au` (intentional differences): "
                 f"{ffmpeg_accepts_rejected}/{rejected}.")


def compare_writer(args, lines, failures):
    """The write driver's actual output, read by FFmpeg (T19a)."""
    lines += [
        "",
        "## Zig-written files read by FFmpeg",
        "",
        "| Stream | Output | FFmpeg | Result |",
        "| --- | --- | --- | --- |",
    ]
    streams = [("wav", f) for f in generate.build_fixtures() if f.writer_output]
    if "au-writer" not in NOT_IMPLEMENTED:
        streams += [("au", f) for f in generate.build_au_fixtures() if f.writer_output]
    passed = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for container, fixture in streams:
            channels, rate, samples = fixture.accept
            frames = len(samples) // channels
            raw = work / f"{fixture.name}.s16le"
            out = work / f"{fixture.name}.{container}"
            raw.write_bytes(generate.pcm(samples))
            process = run(args.writer, container, rate, channels, raw, out)
            problems, notes = [], []
            if process.returncode != 0:
                problems.append(f"write-driver exited {process.returncode}: {first_line(text(process.stderr))}")
                output = "not written"
            else:
                written = out.read_bytes()
                output = f"{len(written)} bytes, " + ("equal to the fixture" if written == fixture.data else "differs")
                if written != fixture.data:
                    problems.append("output differs from the writer-output fixture")
                if container == "wav":
                    expected = expected_stream("wav", "pcm_s16le", channels, rate, frames)
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, samples)
                else:
                    # Forced, because FFmpeg's probe does not detect an empty AU file.
                    expected = expected_stream("au", "pcm_s16be", channels, rate, frames)
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, samples, "au",
                                                          field_differences=KNOWN_AU_FIELD_DIFFERENCES)
                problems += stream_problems
            verdict = "same samples and stream" if not problems else "differs"
            if notes:
                verdict += "; " + "; ".join(notes)
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            label = f"{container.upper()} {LAYOUT[channels]}, {rate} Hz, {frames_text(frames)} (`{fixture.name}`)"
            lines.append(f"| {label} | {output} | {verdict} | {result} |")
            passed += not problems
            failures.extend(f"writer {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"Zig-written files FFmpeg reads as expected: {passed}/{len(streams)}."]


def compare_pipes(args, lines, failures):
    """zffprobe through a pipe must match zffprobe on the file (T12c)."""
    cases = [(FIXTURES / "wav" / f"{f.name}.wav") for f in generate.build_fixtures()]
    cases += [(FIXTURES / "au" / f"{f.name}.au") for f in generate.build_au_fixtures()]
    same = 0
    for path in cases:
        file_code, file_out, file_err = zffprobe_raw(args.zffprobe, path)
        pipe_code, pipe_out, pipe_err = zffprobe_raw(args.zffprobe, "-", data=path.read_bytes())
        expected_err = file_err.replace(f"zffprobe: {path}: ".encode(), b"zffprobe: -: ")
        if (pipe_code, pipe_out, pipe_err) == (file_code, file_out, expected_err):
            same += 1
        else:
            failures.append(f"{path.name}: through a pipe zffprobe exited {pipe_code} "
                            f"({text(pipe_err) or 'no error'}), from the file {file_code} ({text(file_err) or 'no error'})")
    lines += [
        "",
        "## zffprobe through a pipe",
        "",
        f"Fixtures whose pipe result (status, report and error) equals the file result: {same}/{len(cases)}.",
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--zffprobe", required=True)
    parser.add_argument("--writer", required=True, help="the write driver (zig build test-tools)")
    parser.add_argument("--report", help="also write the Markdown report to this file")
    args = parser.parse_args()

    version = text(run(args.ffmpeg, "-hide_banner", "-version").stdout).splitlines()
    lines = [
        "# FFmpeg reference comparison",
        "",
        f"- Reference: `{version[0] if version else 'unknown'}`",
        f"- {next((line for line in version if line.startswith('configuration:')), 'configuration: unknown')}",
        "",
        "## WAV fixtures",
        "",
        "| Fixture | Expected | zffprobe | FFmpeg | Result |",
        "| --- | --- | --- | --- | --- |",
    ]
    failures = []
    fixtures = generate.build_fixtures()
    accepted_ok = rejected_ok = ffmpeg_accepts_rejected = 0
    for fixture in fixtures:
        path = FIXTURES / "wav" / f"{fixture.name}.wav"
        if not path.exists():
            failures.append(f"{fixture.name}: fixture file is missing")
            continue
        if path.read_bytes() != fixture.data:
            failures.append(f"{fixture.name}: fixture file differs from generate.py")
            continue
        if fixture.accept is not None:
            problems, expected, ours, theirs = compare_accepted(fixture, args, path)
            accepted_ok += not problems
        else:
            problems, expected, ours, theirs = compare_rejected(fixture, args, path)
            rejected_ok += not problems
            ffmpeg_accepts_rejected += theirs.startswith("accepts")
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {expected} | {ours} | {theirs} | {result} |")
        failures.extend(f"{fixture.name}: {problem}" for problem in problems)

    accepted = sum(1 for fixture in fixtures if fixture.accept is not None)
    rejected = len(fixtures) - accepted
    lines += [
        "",
        f"Accepted fixtures matching FFmpeg and zffprobe: {accepted_ok}/{accepted}.",
        f"Rejected fixtures with the contract's zffprobe status: {rejected_ok}/{rejected}.",
        f"Rejected fixtures that FFmpeg accepts (intentional differences): {ffmpeg_accepts_rejected}/{rejected}.",
    ]
    compare_au(args, lines, failures)
    compare_writer(args, lines, failures)
    if "au-probe" not in NOT_IMPLEMENTED:
        compare_pipes(args, lines, failures)
    if NOT_IMPLEMENTED:
        lines += ["", "## Not implemented", ""]
        lines += [f"- `{key}`: {note}" for key, note in NOT_IMPLEMENTED.items()]
    report = "\n".join(lines) + "\n"
    print(report)
    if args.report:
        pathlib.Path(args.report).write_text(report)
    if failures:
        print("FAILURES:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
