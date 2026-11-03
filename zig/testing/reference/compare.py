#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
"""Compare the fixtures and Zig-written files with the FFmpeg reference build (T10, T19a).

WAV fixtures: for accepted ones, FFmpeg's ffprobe must report the expected
stream parameters and duration, ffmpeg must decode exactly the expected samples,
and zffprobe must print the expected report. For rejected ones, zffprobe must
exit with the contract's status and error name; FFmpeg's own verdict is
recorded as an intentional difference, not checked.

Unknown-length WAV (T21b): FFmpeg must decode the samples the parser's
`unknown_length` option accepts from each unknown-size fixture.

AU fixtures (T12a) and AIFF fixtures (T22b): FFmpeg reads each one forced with
`-f au` or `-f aiff` (parser acceptance) and by content detection, recorded
separately. Accepted ones must give the expected parameters and samples, apart
from the listed differences.

Zig-written files: the write driver writes every writer-output stream, which
must equal its fixture byte for byte and decode in FFmpeg to the expected
samples.

zffmpeg (T13b): every accepted fixture is converted in every supported cell of
the operation matrix, and FFmpeg must read each actual output with the expected
samples and stream; copy across codecs must fail without creating output. AU
and AIFF outputs of canonical inputs must equal FFmpeg's own conversion.

Checks whose Zig code has not landed yet are listed as not implemented, never
counted as passes or skips. Expectations come from generate.py, the same
independent source as the committed fixtures.

    python3 zig/testing/reference/compare.py --ffmpeg BIN --ffprobe BIN \\
        --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver \\
        --zffmpeg zig-out/bin/zffmpeg [--report report.md]
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
    "InvalidAiff": 2,
    "InvalidWave": 2,
    "InvalidFormat": 2,
    "Truncated": 2,
    "UnsupportedFormat": 3,
    "UnsupportedStreamingSize": 3,
    "UnknownFormat": 3,
    "LimitExceeded": 5,
}
LAYOUT = {1: "mono", 2: "stereo"}

# Checks whose Zig code has not landed yet (TODO.md "Coverage and comparison
# rules"). Each is reported as not implemented, never as a pass or a skip; the
# subtask that owns it deletes its entry here, which makes the check mandatory.
NOT_IMPLEMENTED = {}

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

# Fixtures the `unknown_length` option accepts but FFmpeg cannot open: its
# Wave64 demuxer reads the 64-bit sizes as signed, so the all-ones sentinel is
# -1 and INT64_MAX overflows its bounds check, even in its own pipe output.
KNOWN_UNKNOWN_LENGTH_REJECTIONS = {
    "w64_unknown_length_pipe": "FFmpeg's Wave64 demuxer rejects unknown sizes, its own pipe output included",
    "w64_data_size_unknown": "FFmpeg's Wave64 demuxer rejects unknown sizes",
}

# Inputs whose tags FFmpeg's conversion carries but zffmpeg's cannot: FFmpeg
# reads tags after `data` from a seekable input before writing its header,
# while zffmpeg reads sequentially and writes the header first.
KNOWN_TAG_CARRY_DIFFERENCES = {
    "info_after_data": "the tags follow `data`, which FFmpeg reads first from a seekable file",
}

# The same field difference for AU, whose header has no layout field either.
KNOWN_AU_FIELD_DIFFERENCES = {
    ("channel_layout", "unknown"): "an AU header has no channel layout",
}
# Accepted AU fixtures whose FFmpeg decode continues past the expected samples:
# its output must start with them.
KNOWN_AU_DECODE_DIFFERENCES = {
    "au_trailing_bytes_after_data": "FFmpeg decodes the bytes after the declared data",
}
# AIFF has no layout either without a `CHAN` chunk, which mono and stereo omit.
KNOWN_AIFF_FIELD_DIFFERENCES = {
    ("channel_layout", "unknown"): "an AIFF header has no channel layout without `CHAN`",
}

# The contracts read by forcing a demuxer: (fixture directory and FFmpeg
# format, title, fixtures, field differences, decode differences).
FORCED_CONTRACTS = [
    ("au", "AU", generate.build_au_fixtures, KNOWN_AU_FIELD_DIFFERENCES, KNOWN_AU_DECODE_DIFFERENCES),
    ("aiff", "AIFF", generate.build_aiff_fixtures, KNOWN_AIFF_FIELD_DIFFERENCES, {}),
]
# The field differences of each output container.
FIELD_DIFFERENCES = {
    "wav": KNOWN_FIELD_DIFFERENCES,
    "w64": KNOWN_FIELD_DIFFERENCES,
    "au": KNOWN_AU_FIELD_DIFFERENCES,
    "aiff": KNOWN_AIFF_FIELD_DIFFERENCES,
}
# The codec transcoding writes into each container.
S16_CODEC = {"wav": "pcm_s16le", "w64": "pcm_s16le", "au": "pcm_s16be", "aiff": "pcm_s16be"}


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


# The encoder that writes each storage format's samples unchanged, little-endian.
STORAGE_CODEC = {"u8": "pcm_u8", "s16": "pcm_s16le", "s32": "pcm_s32le", "s64": "pcm_s64le",
                 "flt": "pcm_f32le", "dbl": "pcm_f64le"}


def wav_payload(data):
    """The bytes after the first `data` chunk header of a WAV stream written to a pipe,
    where FFmpeg cannot go back to fill in the sizes."""
    position = 12
    while position + 8 <= len(data):
        chunk_id, size = data[position:position + 4], int.from_bytes(data[position + 4:position + 8], "little")
        if chunk_id == b"data":
            return data[position + 8:]
        position += 8 + size + (size & 1)
    return b""


def ffmpeg_decode(binary, path, input_format=None, storage="s16"):
    """Decoded samples in `storage` (FFmpeg converts other formats to it), little-endian."""
    process = run(binary, "-v", "error", "-nostdin", *forced(input_format), "-i", path,
                  "-map", "0:a:0", "-c:a", STORAGE_CODEC[storage], "-f", "wav", "-")
    return process.returncode, wav_payload(process.stdout), text(process.stderr)


def detected_format(binary, path):
    """The format FFmpeg's content probe picks, or None if it picks none (T16).

    Read from ffprobe's debug log, which names the winner even when its
    demuxer then fails, so detection and parsing are judged apart."""
    process = run(binary, "-v", "debug", path)
    match = re.search(rb"Format (\S+) probed with size=\d+ and score=\d+", process.stderr)
    return match.group(1).decode() if match else None


def forced_input(fixture, container):
    """zffprobe's and zffmpeg's `-f` for a fixture FFmpeg's probing does not
    detect (T16), so its parser still reads it; nothing for the others."""
    return [] if generate.ffmpeg_detect(fixture.data) else ["-f", container]


def zffprobe(binary, path, input_args=()):
    """Exit status, the stream fields (without the tag lines) and stderr."""
    process = run(binary, *input_args, path)
    stream_lines = b"\n".join(line for line in process.stdout.split(b"\n") if not line.startswith(b"tag:"))
    return process.returncode, key_values(text(stream_lines)), text(process.stderr)


def unescape(data, escapes):
    """Undoes backslash escapes: `escapes` maps the byte after a backslash to its meaning."""
    out, i = bytearray(), 0
    while i < len(data):
        if data[i] == 0x5C and i + 1 < len(data) and data[i + 1] in escapes:
            out.append(escapes[data[i + 1]])
            i += 2
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


ZFFPROBE_ESCAPES = {0x5C: 0x5C, ord("n"): 0x0A, ord("r"): 0x0D}
# ffprobe's `c` escaping in the compact writer, with `|` as the separator.
FFPROBE_C_ESCAPES = {0x5C: 0x5C, ord("n"): 0x0A, ord("r"): 0x0D, ord("b"): 0x08, ord("f"): 0x0C, ord("|"): ord("|")}


def zffprobe_tags(binary, path, input_args=()):
    """zffprobe's `tag:<key>=<value>` lines (T21c) as (key, value) byte pairs, in order."""
    process = run(binary, *input_args, path)
    tags = []
    for line in process.stdout.split(b"\n"):
        if line.startswith(b"tag:"):
            key, _, value = line[len(b"tag:"):].partition(b"=")
            tags.append((unescape(key, ZFFPROBE_ESCAPES), unescape(value, ZFFPROBE_ESCAPES)))
    return tags


def ffprobe_tags(binary, path, input_format=None):
    """ffprobe's format tags as (key, value) byte pairs, in order. The compact
    writer with `c` escaping keeps every tag on one line, newlines included."""
    process = run(binary, "-v", "error", "-show_entries", "format_tags", "-of", "compact=p=0:escape=c",
                  *forced(input_format), path)
    line = process.stdout.rstrip(b"\r\n")
    items, current, i = [], bytearray(), 0
    while i < len(line):
        if line[i] == 0x5C and i + 1 < len(line):
            current += line[i:i + 2]
            i += 2
        elif line[i] == ord("|"):
            items.append(bytes(current))
            current = bytearray()
            i += 1
        else:
            current.append(line[i])
            i += 1
    if current:
        items.append(bytes(current))
    tags = []
    for item in items:
        if item.startswith(b"tag:"):
            key, _, value = item[len(b"tag:"):].partition(b"=")
            tags.append((unescape(key, FFPROBE_C_ESCAPES), unescape(value, FFPROBE_C_ESCAPES)))
    return tags


def tags_text(tags):
    return ", ".join(f"{k.decode(errors='replace')}={v.decode(errors='replace')!r}" for k, v in tags) or "none"


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


def wav_container(fixture):
    """The container of a WAV-contract fixture: Wave64 starts with the `riff` GUID."""
    return "w64" if fixture.data.startswith(b"riff") else "wav"


def w64_differences(data, codec, channels, frames, differences):
    """`differences` plus FFmpeg's Wave64 duration, when it is not the frame count.

    FFmpeg's Wave64 demuxer sets no duration from the `data` size: libavformat
    estimates one from the bit rate over the bytes from the start of the data
    to the end of the file, so pad bytes and later chunks count as frames."""
    frame_bytes = channels * generate.WAV_CODECS[codec][1] // 8
    position = generate.W64_HEADER_LEN
    while position + 24 <= len(data):
        size = int.from_bytes(data[position + 16:position + 24], "little")
        if data[position:position + 16] == generate.w64_guid(b"data"):
            # Rounded to the nearest frame, as av_rescale rounds.
            estimate = (2 * (len(data) - position - 24) + frame_bytes) // (2 * frame_bytes)
            if estimate != frames:
                differences = dict(differences)
                differences[("duration_ts", str(estimate))] = \
                    "FFmpeg estimates a Wave64 duration from the bytes after the data start"
            return differences
        position += size + (-size % 8)
    return differences


def compare_accepted(fixture, args, path):
    stream = fixture.accept
    channels, rate, samples = stream
    frames = len(samples) // channels
    problems, notes = [], []
    container = wav_container(fixture)

    code, fields, err = ffprobe(args.ffprobe, path)
    expected = {
        "format_name": container,
        "codec_name": stream.codec,
        "sample_fmt": stream.storage,
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "time_base": f"1/{rate}",
        "duration_ts": str(frames),
    }
    differences = KNOWN_FIELD_DIFFERENCES
    if container == "w64":
        differences = w64_differences(fixture.data, stream.codec, channels, frames, differences)
    if code != 0:
        problems.append(f"ffprobe failed: {clean(first_line(err), path)}")
    else:
        for key, value in expected.items():
            got = fields.get(key)
            if got == value:
                continue
            reason = KNOWN_FIXTURE_DIFFERENCES.get((fixture.name, key, got)) or differences.get((key, got))
            if reason:
                notes.append(f"`{key}={got}` ({reason})")
            else:
                problems.append(f"ffprobe {key}={got!r}, expected {value!r}")

    code, raw, err = ffmpeg_decode(args.ffmpeg, path, storage=stream.storage)
    if code != 0:
        problems.append(f"ffmpeg failed: {clean(first_line(err), path)}")
    elif raw != generate.storage_bytes(stream):
        problems.append(f"ffmpeg decoded {len(raw)} bytes of {stream.storage} that differ from the {len(samples)} expected samples")

    input_args = forced_input(fixture, container)
    if input_args:
        undetected_code, _, undetected_err = zffprobe(args.zffprobe, path)
        if undetected_code != 3 or not undetected_err.endswith(": UnknownFormat"):
            problems.append(f"undetected, zffprobe exited {undetected_code} ({undetected_err}), expected UnknownFormat")
    code, fields, err = zffprobe(args.zffprobe, path, input_args)
    z_expected = {
        "format": container,
        "codec": stream.codec,
        "sample_fmt": stream.storage,
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "nb_samples": str(frames),
        "duration_num": str(frames),
        "duration_den": str(rate),
    }
    if code != 0 or fields != z_expected:
        problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")

    # Tags (T21c): FFmpeg's and zffprobe's must both equal the hand-written ones.
    want_tags = fixture.tags
    their_tags = ffprobe_tags(args.ffprobe, path)
    if their_tags != want_tags:
        problems.append(f"ffprobe tags {tags_text(their_tags)}, expected {tags_text(want_tags)}")
    our_tags = zffprobe_tags(args.zffprobe, path, input_args)
    if our_tags != want_tags:
        problems.append(f"zffprobe tags {tags_text(our_tags)}, expected {tags_text(want_tags)}")

    verdict = "same samples and stream" if not problems else "differs"
    if want_tags and not problems:
        verdict += f", and the same {len(want_tags)} tag{'s' if len(want_tags) != 1 else ''}"
    if notes:
        verdict += "; " + "; ".join(notes)
    encoding = "" if stream.codec == "pcm_s16le" else f", `{stream.codec}`"
    return problems, f"{LAYOUT[channels]}, {rate} Hz, {frames} frames{encoding}", "exit 0, report matches", verdict


def check_rejection(binary, path, error, input_args=()):
    """zffprobe must exit with `error`'s status and name it; returns the problems."""
    want = EXIT_STATUS[error]
    code, _, err = zffprobe(binary, path, input_args)
    if code != want or not err.endswith(f": {error}"):
        return [f"zffprobe {' '.join(input_args)} exited {code} ({err}), expected {want} with {error}"]
    return []


def compare_rejected(fixture, args, path):
    """The contract's error from the parser, forced when FFmpeg's probing does
    not detect the file, and `UnknownFormat` from detection then (T16)."""
    input_args = forced_input(fixture, wav_container(fixture))
    problems = check_rejection(args.zffprobe, path, fixture.reject, input_args)
    ours = f"exit {EXIT_STATUS[fixture.reject]}"
    if input_args:
        problems += check_rejection(args.zffprobe, path, "UnknownFormat")
        ours = f"undetected: exit 3; {' '.join(input_args)}: {ours}"
    want = EXIT_STATUS[fixture.reject]
    return problems, f"`{fixture.reject}` (exit {want})", ours, ffmpeg_verdict(args, path)


def ffmpeg_verdict(args, path):
    """FFmpeg's own verdict on a file the contract rejects."""
    probe_code, fields, probe_err = ffprobe(args.ffprobe, path)
    decode_code, raw, decode_err = ffmpeg_decode(args.ffmpeg, path)
    if probe_code == 0 and decode_code == 0:
        layout = fields.get("channel_layout") or f"{fields.get('channels', '?')} channels"
        return f"accepts: {layout}, {fields.get('sample_rate', '?')} Hz, {len(raw) // 2} samples"
    reason = clean(first_line(probe_err or decode_err), path) or f"exit {probe_code or decode_code}"
    return f"rejects: {reason}"


def expected_stream(format_name, codec_name, channels, rate, frames, storage="s16"):
    return {
        "format_name": format_name,
        "codec_name": codec_name,
        "sample_fmt": storage,
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "time_base": f"1/{rate}",
        "duration_ts": str(frames),
    }


def frames_text(frames):
    return f"{frames} frame{'s' if frames != 1 else ''}"


def check_stream(args, fixture_name, path, expected, stream, input_format=None, decode_note=None,
                 field_differences=KNOWN_FIELD_DIFFERENCES):
    """ffprobe fields and the decoded samples of `stream` (a generate.Stream); returns (problems, notes)."""
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

    code, raw, err = ffmpeg_decode(args.ffmpeg, path, input_format, stream.storage)
    want = generate.storage_bytes(stream)
    samples = stream.stored
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


def zffprobe_report(container, codec, channels, rate, frames, storage="s16"):
    return {
        "format": container,
        "codec": codec,
        "sample_fmt": storage,
        "channels": str(channels),
        "channel_layout": LAYOUT[channels],
        "sample_rate": str(rate),
        "nb_samples": str(frames),
        "duration_num": str(frames),
        "duration_den": str(rate),
    }


def check_zffprobe_forced(container, fixture, args, path):
    """zffprobe on one AU or AIFF fixture (T12c, T16, T22b): the parser's
    result, forced with `-f` when FFmpeg's probing does not detect the file,
    which then gives `UnknownFormat`. Returns (problems, summary)."""
    input_args = forced_input(fixture, container)
    problems = check_rejection(args.zffprobe, path, "UnknownFormat") if input_args else []
    prefix = f"undetected: exit 3; -f {container}: " if input_args else ""
    if fixture.accept is not None:
        code, fields, err = zffprobe(args.zffprobe, path, input_args)
        channels, rate, samples = fixture.accept
        want = zffprobe_report(container, fixture.accept.codec, channels, rate, len(samples) // channels,
                               fixture.accept.storage)
        if code != 0 or fields != want:
            problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")
        return problems, f"{prefix}exit 0, report matches"
    problems += check_rejection(args.zffprobe, path, fixture.reject, input_args)
    return problems, f"{prefix}exit {EXIT_STATUS[fixture.reject]}"


def compare_forced_accepted(container, field_differences, decode_differences, fixture, args, path):
    channels, rate, samples = fixture.accept
    frames = len(samples) // channels
    expected = expected_stream(container, fixture.accept.codec, channels, rate, frames, fixture.accept.storage)
    problems, notes = check_stream(args, fixture.name, path, expected, fixture.accept, container,
                                   decode_differences.get(fixture.name), field_differences)

    detection, detection_problems = check_detection(args, fixture, path)
    problems += detection_problems

    verdict = "same samples and stream" if not problems else "differs"
    if notes:
        verdict += "; " + "; ".join(notes)
    return problems, f"{LAYOUT[channels]}, {rate} Hz, {frames_text(frames)}", verdict, detection


def compare_forced_rejected(container, fixture, args, path):
    probe_code, fields, probe_err = ffprobe(args.ffprobe, path, container)
    decode_code, raw, decode_err = ffmpeg_decode(args.ffmpeg, path, container)
    if probe_code == 0 and decode_code == 0:
        layout = fields.get("channel_layout") or f"{fields.get('channels', '?')} channels"
        verdict = f"accepts: {layout}, {fields.get('sample_rate', '?')} Hz, {len(raw) // 2} samples"
    else:
        reason = clean(first_line(probe_err or decode_err), path) or f"exit {probe_code or decode_code}"
        verdict = f"rejects: {reason}"
    detection, problems = check_detection(args, fixture, path)
    return problems, f"`{fixture.reject}`", verdict, detection


def check_detection(args, fixture, path):
    """FFmpeg's probe winner must be the one the manifest records (T16), which
    the Zig tests hold detection to. Returns (summary, problems)."""
    theirs = detected_format(args.ffprobe, path)
    want = generate.ffmpeg_detect(fixture.data)
    summary = theirs or "not detected"
    if theirs != want:
        return summary, [f"FFmpeg's probe picks {theirs or 'nothing'}, the manifest {want or 'nothing'}"]
    return summary, []


def compare_detection(args, lines, failures):
    """Every fixture: FFmpeg's probe winner equals the manifest's, as the Zig
    detection tests require (T16)."""
    fixtures = [("wav", f) for f in generate.build_fixtures()]
    fixtures += [(directory, f) for directory, _, build, _, _ in FORCED_CONTRACTS for f in build()]
    agree = undetected = 0
    for directory, fixture in fixtures:
        path = FIXTURES / directory / f"{fixture.name}.{directory}"
        summary, problems = check_detection(args, fixture, path)
        agree += not problems
        undetected += summary == "not detected"
        failures.extend(f"{fixture.name} (detection): {problem}" for problem in problems)
    lines += [
        "",
        "## Content detection (T16)",
        "",
        f"Fixtures whose FFmpeg probe winner equals the manifest's: {agree}/{len(fixtures)} "
        f"({undetected} detected by no demuxer).",
    ]


def compare_forced(args, lines, failures, container, title, build, field_differences, decode_differences):
    """One contract whose demuxer FFmpeg is forced to (AU, AIFF)."""
    lines += [
        "",
        f"## {title} fixtures",
        "",
        f"FFmpeg reads each file forced with `-f {container}` (parser acceptance) and by content detection.",
        "",
        f"| Fixture | Expected | FFmpeg with `-f {container}` | FFmpeg detection | zffprobe | Result |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    fixtures = build()
    accepted_ok = rejected_ok = ffmpeg_accepts_rejected = 0
    for fixture in fixtures:
        path = FIXTURES / container / f"{fixture.name}.{container}"
        if not path.exists():
            failures.append(f"{fixture.name}: fixture file is missing")
            continue
        if path.read_bytes() != fixture.data:
            failures.append(f"{fixture.name}: fixture file differs from generate.py")
            continue
        if fixture.accept is not None:
            problems, expected, theirs, detection = compare_forced_accepted(
                container, field_differences, decode_differences, fixture, args, path)
        else:
            problems, expected, theirs, detection = compare_forced_rejected(container, fixture, args, path)
            ffmpeg_accepts_rejected += theirs.startswith("accepts")
        probe_problems, ours = check_zffprobe_forced(container, fixture, args, path)
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
    lines += [
        "",
        f"Accepted {title} fixtures FFmpeg and zffprobe read as expected: {accepted_ok}/{accepted}.",
        f"Rejected {title} fixtures with zffprobe's expected status and error: {rejected_ok}/{rejected}.",
        f"Rejected {title} fixtures that FFmpeg accepts with `-f {container}` (intentional differences): "
        f"{ffmpeg_accepts_rejected}/{rejected}.",
    ]


def compare_writer(args, lines, failures):
    """The write driver's actual output, read by FFmpeg (T19a)."""
    lines += [
        "",
        "## Zig-written files read by FFmpeg",
        "",
        "| Stream | Output | FFmpeg | Result |",
        "| --- | --- | --- | --- |",
    ]
    streams = [(wav_container(f), f) for f in generate.build_fixtures() if f.writer_output]
    streams += [(directory, f) for directory, _, build, _, _ in FORCED_CONTRACTS for f in build() if f.writer_output]
    passed = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for container, fixture in streams:
            stream = fixture.accept
            channels, rate, samples = stream
            frames = len(samples) // channels
            raw = work / f"{fixture.name}.raw"
            out = work / f"{fixture.name}.{container}"
            raw.write_bytes(generate.storage_bytes(stream))
            options = ["rf64"] if fixture.writer_header == "rf64" else []
            options += ["bext"] if fixture.writer_bext else []
            options += [f"tag={key.decode()}={value.decode()}" for key, value in (fixture.writer_tags or fixture.tags)]
            process = run(args.writer, container, stream.codec, rate, channels, raw, out, *options)
            problems, notes = [], []
            if process.returncode != 0:
                problems.append(f"write-driver exited {process.returncode}: {first_line(text(process.stderr))}")
                output = "not written"
            else:
                written = out.read_bytes()
                output = f"{len(written)} bytes, " + ("equal to the fixture" if written == fixture.data else "differs")
                if written != fixture.data:
                    problems.append("output differs from the writer-output fixture")
                expected = expected_stream(container, stream.codec, channels, rate, frames, stream.storage)
                if container == "aiff":
                    # Detected, not forced: every AIFF writer output carries a FORM size FFmpeg's probe accepts.
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, stream,
                                                          field_differences=KNOWN_AIFF_FIELD_DIFFERENCES)
                elif container != "au":
                    differences = KNOWN_FIELD_DIFFERENCES
                    if container == "w64":
                        differences = w64_differences(written, stream.codec, channels, frames, differences)
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, stream,
                                                          field_differences=differences)
                    # T21c: FFmpeg reads back the tags the fixture reports.
                    their_tags = ffprobe_tags(args.ffprobe, out)
                    if their_tags != fixture.tags:
                        stream_problems.append(f"FFmpeg reads tags {tags_text(their_tags)}, "
                                               f"expected {tags_text(fixture.tags)}")
                    elif fixture.tags:
                        notes.append(f"FFmpeg reads its {len(fixture.tags)} tags")
                else:
                    # Forced, because FFmpeg's probe does not detect an empty AU file.
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, stream, "au",
                                                          field_differences=KNOWN_AU_FIELD_DIFFERENCES)
                problems += stream_problems
            verdict = "same samples and stream" if not problems else "differs"
            if notes:
                verdict += "; " + "; ".join(notes)
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            label = f"{container.upper()} `{stream.codec}` {LAYOUT[channels]}, {rate} Hz, {frames_text(frames)} (`{fixture.name}`)"
            lines.append(f"| {label} | {output} | {verdict} | {result} |")
            passed += not problems
            failures.extend(f"writer {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"Zig-written files FFmpeg reads as expected: {passed}/{len(streams)}."]


def compare_zffmpeg(args, lines, failures):
    """zffmpeg's actual output for every accepted fixture, read by FFmpeg (T13b, T21a, T21b, T22b).

    Copy works into any container that carries the input's codec, and
    transcoding only from samples stored as s16 (other storage needs
    sample-format conversion, T23a). Each supported cell writes a file that
    FFmpeg must probe and decode to the fixture's samples and stream; the same
    command through standard input and output must give the same bytes. Every
    other cell must fail with status 3 before creating any output. FFmpeg's
    Wave64 demuxer rejects an empty `data` chunk (24 bytes, its header only),
    so an empty Wave64 output must be refused by FFmpeg and read by zffprobe.
    For a writer-output input without tags, an AU or AIFF output must also
    equal FFmpeg's own conversion (`ffmpeg -bitexact`, which picks the same
    codec tag: `sowt` for s16le in AIFF, for instance).
    """
    lines += [
        "",
        "## zffmpeg output read by FFmpeg",
        "",
        "| Input | Cell | Output | FFmpeg | Result |",
        "| --- | --- | --- | --- | --- |",
    ]
    inputs = [(wav_container(f), FIXTURES / "wav" / f"{f.name}.wav", f) for f in generate.build_fixtures() if f.accept]
    inputs += [(directory, FIXTURES / directory / f"{f.name}.{directory}", f)
               for directory, _, build, _, _ in FORCED_CONTRACTS for f in build() if f.accept]
    # The codecs each output carries; copy needs the input's (T21a, T22a, T22b).
    carried = {"wav": generate.WAV_CODECS, "w64": generate.WAV_CODECS, "au": generate.AU_CODECS,
               "aiff": generate.AIFF_CODECS}
    read_ok = read_total = rejected_ok = rejected_total = same_ok = same_total = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for container, path, fixture in inputs:
            stream = fixture.accept
            channels, rate, samples = stream
            frames = len(samples) // channels
            for output, copy in [(o, c) for c in (False, True) for o in ("wav", "w64", "au", "aiff")]:
                cell = f"{'copy' if copy else 'transcode'} to {output.upper()}"
                options = (["-c", "copy"] if copy else []) + ["-f", output]
                out = work / f"{fixture.name}-{'copy' if copy else 'transcode'}.{output}"
                # An input FFmpeg's probing does not detect is forced (T16).
                input_args = forced_input(fixture, container)
                code, _, err = zffprobe_raw(args.zffmpeg, *input_args, "-i", path, *options, out)
                supported = stream.codec in carried[output] if copy else stream.storage == "s16"
                if not supported:
                    rejected_total += 1
                    if code == 3 and b"UnsupportedOperation" in err and not out.exists():
                        rejected_ok += 1
                    else:
                        failures.append(f"zffmpeg {fixture.name} {cell}: exited {code} "
                                        f"({first_line(text(err)) or 'no error'}), "
                                        f"output {'created' if out.exists() else 'absent'}")
                    continue
                problems, notes = [], []
                empty_w64 = False
                if code != 0:
                    problems.append(f"zffmpeg exited {code}: {first_line(text(err))}")
                    summary = "not written"
                else:
                    written = out.read_bytes()
                    summary = f"{len(written)} bytes"
                    pipe_code, pipe_out, _ = zffprobe_raw(args.zffmpeg, *input_args, "-i", "-", *options, "-",
                                                          data=path.read_bytes())
                    if pipe_code != 0 or pipe_out != written:
                        problems.append(f"through pipes zffmpeg exited {pipe_code} with different output")
                    codec = stream.codec if copy else S16_CODEC[output]
                    expected = expected_stream(output, codec, channels, rate, frames, stream.storage)
                    differences = dict(FIELD_DIFFERENCES[output])
                    if output == "wav" and frames == 0:
                        differences[("duration_ts", "N/A")] = "FFmpeg reads data size 0 as unknown length"
                    if output == "w64":
                        differences = w64_differences(written, codec, channels, frames, differences)
                    if output == "w64" and frames == 0:
                        probe_code, _, _ = ffprobe(args.ffprobe, out)
                        z_code, z_fields, _ = zffprobe(args.zffprobe, out)
                        if probe_code == 0:
                            problems.append("FFmpeg now reads an empty Wave64 `data` chunk")
                        if z_code != 0 or z_fields != zffprobe_report("w64", codec, channels, rate, 0, stream.storage):
                            problems.append(f"zffprobe exited {z_code} with {z_fields}")
                        empty_w64 = True
                    else:
                        # Forced for AU, because FFmpeg's probe does not detect an empty AU file.
                        stream_problems, notes = check_stream(args, f"zffmpeg {fixture.name}", out, expected, stream,
                                                              "au" if output == "au" else None,
                                                              field_differences=differences)
                        problems += stream_problems
                        problems += check_carried_tags(args, fixture, path, out, output, copy, work, notes)
                    if output in ("au", "aiff") and fixture.writer_output and not fixture.tags:
                        same_total += 1
                        same_problems = check_ffmpeg_conversion(args, path, input_args, out, output, copy, work)
                        same_ok += not same_problems
                        if not same_problems:
                            notes.append("equal to FFmpeg's own conversion")
                        problems += same_problems
                read_total += 1
                read_ok += not problems
                verdict = "same samples and stream" if not problems else "differs"
                if empty_w64 and not problems:
                    verdict = ("refuses it, as recorded: FFmpeg rejects a Wave64 chunk of 24 bytes, "
                               "an empty `data`; zffprobe reads the empty stream")
                if notes:
                    verdict += "; " + "; ".join(notes)
                result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
                lines.append(f"| `{fixture.name}` | {cell} | {summary} | {verdict} | {result} |")
                failures.extend(f"zffmpeg {fixture.name} {cell}: {problem}" for problem in problems)
    lines += [
        "",
        f"zffmpeg outputs FFmpeg reads as expected, equal through pipes: {read_ok}/{read_total}.",
        f"Unsupported cells rejected before any output: {rejected_ok}/{rejected_total}.",
        f"AU and AIFF outputs of untagged writer-output inputs equal to FFmpeg's own conversion: "
        f"{same_ok}/{same_total}.",
    ]


def check_ffmpeg_conversion(args, path, input_args, out, output, copy, work):
    """The same conversion by FFmpeg (`-bitexact`, so no `encoder` tag), whose
    output must equal zffmpeg's byte for byte. Returns the problems."""
    reference = work / f"ffmpeg-reference.{output}"
    process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", path, "-bitexact",
                  *(["-c:a", "copy"] if copy else ["-c:a", S16_CODEC[output]]), "-f", output, reference)
    if process.returncode != 0:
        return [f"ffmpeg's own conversion failed: {first_line(text(process.stderr))}"]
    if reference.read_bytes() != out.read_bytes():
        return ["differs from FFmpeg's own conversion"]
    return []

def check_carried_tags(args, fixture, path, out, output, copy, work, notes):
    """T21c: a WAV output carries the tags FFmpeg's own conversion carries
    (`ffmpeg -bitexact`, which adds no `encoder` tag), and other outputs none.
    Returns the problems; appends notes."""
    ours = ffprobe_tags(args.ffprobe, out, output if output in ("au", "aiff") else None)
    if output != "wav" or not fixture.tags:
        return [] if not ours else [f"output carries tags {tags_text(ours)}, expected none"]
    reference = work / f"{fixture.name}-ffmpeg-{'copy' if copy else 'transcode'}.wav"
    process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", "-i", path, "-bitexact",
                  *(["-c:a", "copy"] if copy else ["-c:a", "pcm_s16le"]), "-f", "wav", reference)
    if process.returncode != 0:
        return [f"ffmpeg's own conversion failed: {first_line(text(process.stderr))}"]
    theirs = ffprobe_tags(args.ffprobe, reference)
    if ours == theirs:
        notes.append(f"carries the same {len(ours)} tags as FFmpeg")
        return []
    reason = KNOWN_TAG_CARRY_DIFFERENCES.get(fixture.name)
    if reason and not ours:
        notes.append(f"carries no tags; FFmpeg carries {tags_text(theirs)} ({reason})")
        return []
    return [f"carries tags {tags_text(ours)}; FFmpeg carries {tags_text(theirs)}"]


def compare_ffmpeg_w64(args, lines, failures):
    """Wave64 files FFmpeg's muxer writes, read by zffprobe and zffmpeg (T21b).

    FFmpeg counts the alignment padding in its chunk sizes, unlike the Sony
    specification and the Zig writer, so its 18-byte `fmt ` declares 48 bytes.
    Each writer-output WAV fixture with an aligned data size is copied into
    Wave64 by FFmpeg; zffprobe must report its stream, and zffmpeg must copy it
    back to exactly the fixture's bytes."""
    lines += [
        "",
        "## FFmpeg-written Wave64 read by zffprobe and zffmpeg",
        "",
        "| Fixture | zffprobe | Copied back to WAV | Result |",
        "| --- | --- | --- | --- |",
    ]
    def payload_len(stream):
        return len(stream.stored) * generate.WAV_CODECS[stream.codec][1] // 8

    # FFmpeg's `data` size would count padding after an unaligned payload,
    # which it and every reader then decode as samples.
    # Wave64 carries no tags, so tagged fixtures cannot come back unchanged.
    fixtures = [f for f in generate.build_fixtures()
                if f.writer_output and f.writer_header == "riff" and f.accept.codec in generate.WAV_CODECS
                and not f.tags and not f.writer_bext
                and payload_len(f.accept) > 0 and payload_len(f.accept) % 8 == 0]
    passed = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for fixture in fixtures:
            stream = fixture.accept
            channels, rate, samples = stream
            frames = len(samples) // channels
            out = work / f"{fixture.name}.w64"
            problems = []
            process = run(args.ffmpeg, "-v", "error", "-nostdin", "-i", FIXTURES / "wav" / f"{fixture.name}.wav",
                          "-c:a", "copy", "-f", "w64", out)
            probe_text = copy_text = "not run"
            if process.returncode != 0:
                problems.append(f"ffmpeg exited {process.returncode}: {first_line(text(process.stderr))}")
            else:
                code, fields, err = zffprobe(args.zffprobe, out)
                want = zffprobe_report("w64", stream.codec, channels, rate, frames, stream.storage)
                probe_text = "report matches" if code == 0 and fields == want else f"exit {code}"
                if code != 0 or fields != want:
                    problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")
                code, copied, err = zffprobe_raw(args.zffmpeg, "-i", out, "-c", "copy", "-f", "wav", "-")
                copy_text = "equal to the fixture" if code == 0 and copied == fixture.data else f"exit {code}"
                if code != 0 or copied != fixture.data:
                    problems.append(f"zffmpeg copy exited {code} ({first_line(text(err)) or 'different bytes'})")
            passed += not problems
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            lines.append(f"| `{fixture.name}` | {probe_text} | {copy_text} | {result} |")
            failures.extend(f"ffmpeg w64 {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"FFmpeg-written Wave64 files read as expected: {passed}/{len(fixtures)}."]


def compare_ffmpeg_muxer(args, lines, failures, container, title, build):
    """FFmpeg's AU or AIFF muxer against the Zig writer (T22a, T22b): FFmpeg
    copies each writer-output fixture into the same container, which must give
    back the same bytes, so both write the same header for every encoding."""
    fixtures = [f for f in build() if f.writer_output]
    same = 0
    with tempfile.TemporaryDirectory() as tmp:
        for fixture in fixtures:
            out = pathlib.Path(tmp) / f"{fixture.name}.{container}"
            # Forced, because FFmpeg's probe does not detect an empty AU file.
            process = run(args.ffmpeg, "-v", "error", "-nostdin", "-f", container,
                          "-i", FIXTURES / container / f"{fixture.name}.{container}",
                          "-bitexact", "-c:a", "copy", "-f", container, out)
            if process.returncode == 0 and out.read_bytes() == fixture.data:
                same += 1
            else:
                failures.append(f"ffmpeg {container} {fixture.name}: exited {process.returncode} "
                                f"({first_line(text(process.stderr)) or 'different bytes'})")
    lines += [
        "",
        f"## FFmpeg's {title} muxer",
        "",
        f"{title} writer-output fixtures FFmpeg copies to identical bytes: {same}/{len(fixtures)}.",
    ]


def compare_pipes(args, lines, failures):
    """zffprobe through a pipe must match zffprobe on the file (T12c)."""
    cases = [(FIXTURES / "wav" / f"{f.name}.wav") for f in generate.build_fixtures()]
    cases += [(FIXTURES / directory / f"{f.name}.{directory}")
              for directory, _, build, _, _ in FORCED_CONTRACTS for f in build()]
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


def compare_unknown_length(args, lines, failures):
    """The fixtures whose result changes with the parser's `unknown_length` option (T21b).

    Their default result is checked with the other fixtures. FFmpeg always reads
    unknown sizes to the end of the stream, so for the ones the option accepts it
    must decode exactly the expected samples and stream; its duration is not
    compared, since the header gives none. Its verdict on the ones the option
    still rejects is recorded, not checked."""
    lines += [
        "",
        "## Unknown-length WAV and AU (T21b, T22a)",
        "",
        "The result with the `unknown_length` parser option, which the Zig tests check; "
        "zffprobe and zffmpeg do not enable it.",
        "",
        "| Fixture | With `unknown_length` | FFmpeg | Result |",
        "| --- | --- | --- | --- |",
    ]
    def changes(f):
        return f.unknown_accept is not None or f.unknown_reject is not None

    fixtures = [("wav", f) for f in generate.build_fixtures() if changes(f)]
    fixtures += [("au", f) for f in generate.build_au_fixtures() if changes(f)]
    accepted = [f for _, f in fixtures if f.unknown_accept is not None]
    accepted_ok = 0
    for directory, fixture in fixtures:
        path = FIXTURES / directory / f"{fixture.name}.{directory}"
        au_file = directory == "au"
        stream = fixture.unknown_accept
        if stream is None:
            lines.append(f"| `{fixture.name}` | `{fixture.unknown_reject}` | {ffmpeg_verdict(args, path)} | recorded |")
            continue
        channels, rate, samples = stream
        frames = len(samples) // channels
        reason = KNOWN_UNKNOWN_LENGTH_REJECTIONS.get(fixture.name)
        if reason is not None:
            # Recorded, but checked: FFmpeg must still reject it.
            theirs = ffmpeg_verdict(args, path)
            problems = [] if theirs.startswith("rejects") else [f"FFmpeg now {theirs}"]
            accepted_ok += not problems
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            lines.append(f"| `{fixture.name}` | {LAYOUT[channels]}, {rate} Hz, {frames_text(frames)} "
                         f"| {theirs} ({reason}) | {result} |")
            failures.extend(f"{fixture.name} (unknown_length): {problem}" for problem in problems)
            continue
        container = "au" if au_file else wav_container(fixture)
        expected = expected_stream(container, stream.codec, channels, rate, frames, stream.storage)
        del expected["duration_ts"]
        problems, notes = check_stream(args, fixture.name, path, expected, stream, "au" if au_file else None,
                                       field_differences=KNOWN_AU_FIELD_DIFFERENCES if au_file else KNOWN_FIELD_DIFFERENCES)
        accepted_ok += not problems
        theirs = "same samples and stream" if not problems else "differs"
        if notes:
            theirs += "; " + "; ".join(notes)
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {LAYOUT[channels]}, {rate} Hz, {frames_text(frames)} | {theirs} | {result} |")
        failures.extend(f"{fixture.name} (unknown_length): {problem}" for problem in problems)
    lines += ["", f"Fixtures the option accepts that FFmpeg decodes the same, or rejects as recorded: "
                  f"{accepted_ok}/{len(accepted)}."]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--zffprobe", required=True)
    parser.add_argument("--writer", required=True, help="the write driver (zig build test-tools)")
    parser.add_argument("--zffmpeg", required=True)
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
    compare_unknown_length(args, lines, failures)
    compare_detection(args, lines, failures)
    for container, title, build, field_differences, decode_differences in FORCED_CONTRACTS:
        compare_forced(args, lines, failures, container, title, build, field_differences, decode_differences)
    compare_writer(args, lines, failures)
    compare_zffmpeg(args, lines, failures)
    compare_ffmpeg_w64(args, lines, failures)
    for container, title, build, _, _ in FORCED_CONTRACTS:
        compare_ffmpeg_muxer(args, lines, failures, container, title, build)
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
