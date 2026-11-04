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

AU fixtures (T12a), AIFF fixtures (T22b) and CAF fixtures (T22d): FFmpeg reads
each one forced with `-f au`, `-f aiff` or `-f caf` (parser acceptance) and by content detection, recorded
separately. Accepted ones must give the expected parameters and samples, apart
from the listed differences.

Zig-written files: the write driver writes every writer-output stream, which
must equal its fixture byte for byte and decode in FFmpeg to the expected
samples.

zffmpeg (T13b): every accepted fixture is converted in every supported cell of
the operation matrix, and FFmpeg must read each actual output with the expected
samples and stream; copy across codecs must fail without creating output. AU
and AIFF outputs of canonical inputs must equal FFmpeg's own conversion.

Raw PCM fixtures (T22c): FFmpeg and zffprobe read each one forced with its
format and parameters; FFmpeg must detect a copy named with the format's
extension as that format, as zffprobe does; FFmpeg's raw muxers copy the
writer-output fixtures unchanged.

Dither (T23a): zffmpeg's `-dither_method` and `-dither_scale` must give
FFmpeg's samples for every method, on long inputs in every input container.

Registries (T16): the codec descriptors, decoders and encoders, and the
formats with their demuxers' and muxers' extensions, MIME types and default codecs, as the
registry dump prints them, must equal the reference build's own `ffmpeg
-codecs`, `ffmpeg -formats` and `ffmpeg -h muxer=...`, and cover exactly the
codecs and formats it enables.

Checks whose Zig code has not landed yet are listed as not implemented, never
counted as passes or skips. Expectations come from generate.py, the same
independent source as the committed fixtures.

    python3 zig/testing/reference/compare.py --ffmpeg BIN --ffprobe BIN \\
        --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver \\
        --zffmpeg zig-out/bin/zffmpeg --registry zig-out/bin/registry-dump \\
        [--report report.md]
"""

import argparse
import hashlib
import pathlib
import re
import struct
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
    "InvalidCaf": 2,
    "InvalidFlac": 2,
    "FrameCountMismatch": 2,
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
# Since T23b the contracts report FFmpeg's layouts (`unknown` when the header
# has none), so the channel layout is no longer a known difference.
KNOWN_FIELD_DIFFERENCES = {}
KNOWN_FIXTURE_DIFFERENCES = {
    # FFmpeg reads a data size of 0 as unknown length and reports no duration.
    ("empty_data", "duration_ts", "N/A"): "FFmpeg reads data size 0 as unknown length",
    # FFmpeg estimates a raw duration from the file size, and has none for 0 bytes.
    ("raw_empty", "duration_ts", "N/A"): "FFmpeg gives an empty raw file no duration",
    # FFmpeg sets a CAF frame count only from a nonzero data size.
    ("caf_empty_data", "duration_ts", "N/A"): "FFmpeg gives an empty CAF data chunk no duration",
    # FFmpeg estimates a CAF duration from the bit rate over the bytes after the
    # data start, so the 12-byte trailing ree chunk counts as 6 frames.
    ("caf_chunks_around_data", "duration_ts", "10"): "FFmpeg estimates the duration from the bytes after the data start",
    # FFmpeg reads a seekable CAF file's chunks after a data chunk of known size.
    ("caf_chan_after_data", "channel_layout", "quad"): "`chan` after `data` is not read",
    # The same estimate counts the 24-byte `chan` after the data as 3 frames.
    ("caf_chan_after_data", "duration_ts", "5"): "FFmpeg estimates the duration from the bytes after the data start",
    # FFmpeg reads a seekable AIFF file's chunks after SSND; a sequential
    # reader has reported the stream by then.
    ("aiff_chan_after_ssnd", "channel_layout", "quad"): "CHAN after SSND is not read",
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

KNOWN_AU_FIELD_DIFFERENCES = {}
# Accepted AU fixtures whose FFmpeg decode continues past the expected samples:
# its output must start with them.
KNOWN_AU_DECODE_DIFFERENCES = {
    "au_trailing_bytes_after_data": "FFmpeg decodes the bytes after the declared data",
}
KNOWN_AIFF_FIELD_DIFFERENCES = {}

# The contracts read by forcing a demuxer: (fixture directory and FFmpeg
# format, title, fixtures, field differences, decode differences).
KNOWN_CAF_FIELD_DIFFERENCES = {}

FORCED_CONTRACTS = [
    ("au", "AU", generate.build_au_fixtures, KNOWN_AU_FIELD_DIFFERENCES, KNOWN_AU_DECODE_DIFFERENCES),
    ("aiff", "AIFF", generate.build_aiff_fixtures, KNOWN_AIFF_FIELD_DIFFERENCES, {}),
    ("caf", "CAF", generate.build_caf_fixtures, KNOWN_CAF_FIELD_DIFFERENCES, {}),
]
# The forced contracts whose muxer the port has, and FFmpeg's reference build
# enables: CAF is read only (T22d).
MUXED_CONTRACTS = ("au", "aiff")
# The field differences of each output container.
FIELD_DIFFERENCES = {
    "wav": KNOWN_FIELD_DIFFERENCES,
    "w64": KNOWN_FIELD_DIFFERENCES,
    "au": KNOWN_AU_FIELD_DIFFERENCES,
    "aiff": KNOWN_AIFF_FIELD_DIFFERENCES,
}
# The codec transcoding writes into each container.
S16_CODEC = {"wav": "pcm_s16le", "w64": "pcm_s16le", "au": "pcm_s16be", "aiff": "pcm_s16be"}
# A raw format's muxer writes its own codec (T22c); FFmpeg reports the layout
# it was given, so raw output has no field difference.
S16_CODEC.update(generate.RAW_FORMATS)
FIELD_DIFFERENCES.update({fmt: {} for fmt in generate.RAW_FORMATS})


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
    """The input options for a forced format: a format name, or a whole list
    of options (raw PCM's format and parameters)."""
    if isinstance(input_format, list):
        return input_format
    return ["-f", input_format] if input_format else []


# The raw formats whose demuxer and muxer declare an extension; `sw` goes to
# the native byte order's 16-bit format (FFmpeg's AV_NE).
RAW_EXTENSIONS = {"u8": "ub", "s8": "sb", "alaw": "al", "mulaw": "ul",
                  ("s16le" if sys.byteorder == "little" else "s16be"): "sw"}


def layout_text(stream):
    """A stream's layout for the report: ffprobe's name, or its channel count."""
    channels = stream.channels
    count = f"{channels} channel{'s' if channels != 1 else ''}"
    return count if stream.layout == "unknown" else stream.layout


def layout_mask(layout):
    """The mask of a native layout's description (`generate.describe_mask`),
    or None for `unknown` and a custom order (channels that do not rise)."""
    for name, mask in generate.NAMED_LAYOUTS:
        if name == layout:
            return mask
    match = re.fullmatch(r"\d+ channels \((.*)\)", layout)
    if not match:
        return None
    by_name = {name: bit for bit, name in generate.CHANNEL_NAMES.items()}
    bits = [by_name[name] if name in by_name else int(name[3:]) for name in match.group(1).split("+")]
    if any(a >= b for a, b in zip(bits, bits[1:])):
        return None
    return sum(1 << bit for bit in bits)


def describe_channels(names):
    """FFmpeg's description of a channel list: native when the channels rise
    (`generate.describe_mask`), else a custom order."""
    by_name = {name: bit for bit, name in generate.CHANNEL_NAMES.items()}
    bits = [by_name[name] for name in names]
    if all(a < b for a, b in zip(bits, bits[1:])):
        return generate.describe_mask(sum(1 << bit for bit in bits))
    return f"{len(names)} channels ({'+'.join(names)})"


# FFmpeg's AIFF muxer writes a native layout of more than two channels as a
# CHAN chunk (ff_mov_write_chan in isom.c): the first Core Audio layout tag
# its table pairs with the mask, else the mask as a bitmap. Its demuxer
# reads a tag back as the tag's channel list in Core Audio's order
# (mov_chan.c), so a round trip can change the layout: 5.1 comes back as
# 5.1(side). Each entry: the mask written, then the channels read, both
# restated from the Core Audio tags (kAudioChannelLayoutTag_*).
AIFF_CHAN_ROUND_TRIP = [
    (("FC",), ("FC",)),  # Mono
    (("FL", "FR"), ("FL", "FR")),  # Stereo
    (("FL", "FR", "BC"), ("FL", "FR", "BC")),  # ITU_2_1
    (("FL", "FR", "BL", "BR"), ("FL", "FR", "SL", "SR")),  # ITU_2_2 for quad
    (("FL", "FR", "SL", "SR"), ("FL", "FR", "SL", "SR")),  # ITU_2_2
    (("FL", "FR", "FC"), ("FL", "FR", "FC")),  # MPEG_3_0_A
    (("FL", "FR", "FC", "BC"), ("FL", "FR", "FC", "BC")),  # MPEG_4_0_A
    (("FL", "FR", "FC", "BL", "BR"), ("FL", "FR", "FC", "SL", "SR")),  # MPEG_5_0_A for 5.0
    (("FL", "FR", "FC", "SL", "SR"), ("FL", "FR", "FC", "SL", "SR")),  # MPEG_5_0_A
    (("FL", "FR", "FC", "LFE", "BL", "BR"), ("FL", "FR", "FC", "LFE", "SL", "SR")),  # MPEG_5_1_A for 5.1
    (("FL", "FR", "FC", "LFE", "SL", "SR"), ("FL", "FR", "FC", "LFE", "SL", "SR")),  # MPEG_5_1_A
    (("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"),
     ("FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR")),  # MPEG_7_1_C
    (("FL", "FR", "FC", "LFE", "SL", "SR", "FLC", "FRC"),
     ("FL", "FR", "FC", "LFE", "SL", "SR", "FLC", "FRC")),  # MPEG_7_1_A
    (("FL", "FR", "FC", "LFE", "BL", "BR", "DL", "DR"),
     ("FL", "FR", "FC", "LFE", "SL", "SR", "DL", "DR")),  # SMPTE_DTV
    (("FL", "FR", "LFE"), ("FL", "FR", "LFE")),  # DVD_4
    (("FL", "FR", "LFE", "BC"), ("FL", "FR", "LFE", "BC")),  # DVD_5
    (("FL", "FR", "LFE", "BL", "BR"), ("FL", "FR", "LFE", "SL", "SR")),  # DVD_6 for quad and LFE
    (("FL", "FR", "LFE", "SL", "SR"), ("FL", "FR", "LFE", "SL", "SR")),  # DVD_6
    (("FL", "FR", "FC", "LFE"), ("FL", "FR", "FC", "LFE")),  # DVD_10
    (("FL", "FR", "FC", "LFE", "BC"), ("FL", "FR", "FC", "LFE", "BC")),  # DVD_11
]


def aiff_round_trip(mask):
    """The layout ffprobe reads from an AIFF file FFmpeg's muxer (or ours)
    wrote with the native layout `mask`."""
    if bin(mask).count("1") <= 2:
        return "unknown"  # no CHAN
    for written, read in AIFF_CHAN_ROUND_TRIP:
        if generate.channel_bits(*written) == mask:
            return describe_channels(read)
    # A bitmap: read back below bit 18, the 32 bits written, else ignored.
    return generate.describe_mask(mask) if mask < 0x40000 else "unknown"


def guessed_layout(layout, channels):
    """FFmpeg's command line (`guess_input_channel_layout`): an unspecified
    layout becomes the default for its channel count when one is named."""
    if layout != "unknown":
        return layout
    mask = generate.default_mask(channels)
    return "unknown" if mask is None else generate.describe_mask(mask)


def written_layout(container, codec, rate, layout, channels):
    """What ffprobe reads back from a file a muxer wrote with `layout`: WAV
    and Wave64 keep a native layout's mask in an extensible header (riffenc.c,
    `generate.canonical_wav`), AIFF keeps one of more than two channels in a
    CHAN chunk (`aiff_round_trip`), AU keeps none, and raw PCM is read with
    the layout of its channel count."""
    if container in generate.RAW_FORMATS:
        return LAYOUT.get(channels, "unknown")
    if container == "aiff":
        mask = layout_mask(layout)
        return "unknown" if mask is None else aiff_round_trip(mask)
    if container not in ("wav", "w64"):
        return "unknown"
    tag, bits, _ = generate.WAV_CODECS[codec]
    mask = layout_mask(layout)
    named_order = mask is not None and mask not in generate.CHANNEL_MASK.values()
    extensible = named_order or rate > generate.WRITER_MAX_PLAIN_RATE or (bits > 16 and tag != 3)
    if extensible and mask is not None and mask < generate.WRITER_MAX_MASK:
        return generate.describe_mask(mask)
    return "unknown"


def raw_input_args(fmt, params):
    """FFmpeg's (and the tools') input options for raw PCM: the format, then
    the parameters unless the defaults apply."""
    options = ["-f", fmt]
    if params is not None:
        # A fixture's (rate, channels, layout text), or a stream's (rate,
        # channels), read with FFmpeg's names for mono and stereo, else
        # the count alone.
        layout = params[2] if len(params) > 2 else LAYOUT.get(params[1], f"{params[1]}C")
        options += ["-sample_rate", str(params[0]), "-ch_layout", layout]
    return options


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
    # A winner scoring at most 25 (raw FLAC's 13, T26a) is logged differently.
    match = match or re.search(rb"Format (\S+) detected only with low score of \d+", process.stderr)
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


# The coverage summary (T19c): each section records its required cases,
# and the optional corpus its cases with skips and their reasons.
COVERAGE = []


def record(section, passed, total, understood=0, missing=0, optional=False, skipped=0, reasons=()):
    """One section's cases: `passed` of `total`, `understood` of them
    passing as listed differences; for a required section `missing` input
    files (failures), for the optional corpus `skipped` cases and why."""
    COVERAGE.append({"section": section, "passed": passed, "total": total, "understood": understood,
                     "missing": missing, "optional": optional, "skipped": skipped, "reasons": list(reasons)})


def coverage_summary(lines, failures):
    """The report's closing table: required cases passed, failed and
    missing; optional cases passed, failed and skipped, with reasons."""
    required = [c for c in COVERAGE if not c["optional"]]
    optional = [c for c in COVERAGE if c["optional"]]
    rows = []
    for c in required:
        failed = c["total"] - c["passed"] - c["skipped"]
        rows.append(f"| {c['section']} | required | {c['passed']} | {failed} | {c['missing']} missing | "
                    f"{c['understood']} understood |")
    for c in optional:
        failed = c["total"] - c["passed"] - c["skipped"]
        why = "; ".join(c["reasons"]) or "-"
        rows.append(f"| {c['section']} | optional | {c['passed']} | {failed} | {c['skipped']} skipped | {why} |")
    req_passed = sum(c["passed"] for c in required)
    req_total = sum(c["total"] for c in required)
    req_missing = sum(c["missing"] for c in required)
    opt_passed = sum(c["passed"] for c in optional)
    opt_skipped = sum(c["skipped"] for c in optional)
    opt_total = sum(c["total"] for c in optional)
    lines += [
        "",
        "## Coverage summary (T19c)",
        "",
        f"Required cases: passed {req_passed}, failed {req_total - req_passed}, missing {req_missing}. "
        f"Optional cases: passed {opt_passed}, failed {opt_total - opt_passed - opt_skipped}, skipped {opt_skipped} "
        f"(a skipped optional case is reported, not failed; a passing run with skips is not complete coverage). "
        f"Failure messages in all: {len(failures)}.",
        "",
        "| Section | Kind | Passed | Failed | Missing or skipped | Notes |",
        "| --- | --- | --- | --- | --- | --- |",
    ] + rows


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
        "channel_layout": stream.layout,
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
        "channel_layout": stream.layout,
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
    return problems, f"{layout_text(stream)}, {rate} Hz, {frames} frames{encoding}", "exit 0, report matches", verdict


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


def expected_stream(format_name, codec_name, channels, rate, frames, storage, layout):
    return {
        "format_name": format_name,
        "codec_name": codec_name,
        "sample_fmt": storage,
        "channels": str(channels),
        "channel_layout": layout,
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


def zffprobe_report(container, codec, channels, rate, frames, storage, layout):
    return {
        "format": container,
        "codec": codec,
        "sample_fmt": storage,
        "channels": str(channels),
        "channel_layout": layout,
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
                               fixture.accept.storage, fixture.accept.layout)
        if code != 0 or fields != want:
            problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")
        return problems, f"{prefix}exit 0, report matches"
    problems += check_rejection(args.zffprobe, path, fixture.reject, input_args)
    return problems, f"{prefix}exit {EXIT_STATUS[fixture.reject]}"


def compare_forced_accepted(container, field_differences, decode_differences, fixture, args, path):
    channels, rate, samples = fixture.accept
    frames = len(samples) // channels
    expected = expected_stream(container, fixture.accept.codec, channels, rate, frames, fixture.accept.storage,
                               fixture.accept.layout)
    problems, notes = check_stream(args, fixture.name, path, expected, fixture.accept, container,
                                   decode_differences.get(fixture.name), field_differences)

    detection, detection_problems = check_detection(args, fixture, path)
    problems += detection_problems

    verdict = "same samples and stream" if not problems else "differs"
    if notes:
        verdict += "; " + "; ".join(notes)
    return problems, f"{layout_text(fixture.accept)}, {rate} Hz, {frames_text(frames)}", verdict, detection


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
    fixtures += [("raw", f) for f in generate.build_raw_fixtures()]
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
    record("Content detection (T16)", agree, len(fixtures))


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
    record(f"{title} fixtures", accepted_ok + rejected_ok, len(fixtures))


def compare_raw(args, lines, failures):
    """The raw PCM fixtures (T22c), read forced with their format and
    parameters; a copy named with the format's extension, detected; FFmpeg's
    raw muxer copying each writer-output fixture unchanged."""
    lines += [
        "",
        "## Raw PCM fixtures",
        "",
        "FFmpeg and zffprobe read each file forced with its format and parameters "
        "(`-f`, `-sample_rate`, `-ch_layout`); copies named with the format's extension are detected.",
        "",
        "| Fixture | Expected | FFmpeg | zffprobe | Named copy | Result |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    fixtures = generate.build_raw_fixtures()
    accepted_ok = rejected_ok = named_ok = named_total = muxed_ok = muxed_total = ffmpeg_accepts_rejected = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for fixture in fixtures:
            path = FIXTURES / "raw" / f"{fixture.name}.raw"
            if not path.exists() or path.read_bytes() != fixture.data:
                failures.append(f"{fixture.name}: fixture file is missing or differs from generate.py")
                continue
            input_args = raw_input_args(fixture.format, fixture.params)
            problems, named = [], "no extension"
            if fixture.accept is not None:
                stream = fixture.accept
                channels, rate, samples = stream
                frames = len(samples) // channels
                expected = expected_stream(fixture.format, stream.codec, channels, rate, frames, stream.storage,
                                           stream.layout)
                stream_problems, notes = check_stream(args, fixture.name, path, expected, stream, input_args)
                problems += stream_problems
                code, fields, err = zffprobe(args.zffprobe, path, input_args)
                want = zffprobe_report(fixture.format, stream.codec, channels, rate, frames, stream.storage,
                                       stream.layout)
                if code != 0 or fields != want:
                    problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")
                ours = "exit 0, report matches"
                theirs = "same samples and stream" if not stream_problems else "differs"
                if notes:
                    theirs += "; " + "; ".join(notes)
                expected_text = f"{layout_text(stream)}, {rate} Hz, {frames_text(frames)}"
                extension = RAW_EXTENSIONS.get(fixture.format)
                if extension is not None:
                    named_total += 1
                    copy = work / f"{fixture.name}.{extension}"
                    copy.write_bytes(fixture.data)
                    detected = detected_format(args.ffprobe, copy)
                    # Detected, FFmpeg's defaults apply: compare the two reports.
                    probe_code, their_fields, _ = ffprobe(args.ffprobe, copy)
                    code, our_fields, err = zffprobe(args.zffprobe, copy)
                    named_problems = []
                    if detected != fixture.format:
                        named_problems.append(f"FFmpeg detects .{extension} as {detected}")
                    if code != 0 or our_fields.get("format") != fixture.format:
                        named_problems.append(f"zffprobe on .{extension} exited {code} ({first_line(err)})")
                    elif probe_code == 0 and (our_fields.get("sample_rate") != their_fields.get("sample_rate")
                                              or (our_fields.get("nb_samples") != their_fields.get("duration_ts")
                                                  and (fixture.name, "duration_ts", their_fields.get("duration_ts"))
                                                  not in KNOWN_FIXTURE_DIFFERENCES)):
                        named_problems.append(f"named copy: zffprobe {our_fields}, ffprobe {their_fields}")
                    named_ok += not named_problems
                    problems += named_problems
                    named = f"`.{extension}`: " + ("detected as " + fixture.format if not named_problems else "differs")
                if fixture.writer_output:
                    muxed_total += 1
                    out = work / f"{fixture.name}-ffmpeg.raw"
                    process = run(args.ffmpeg, "-v", "error", "-nostdin", *input_args, "-i", path,
                                  "-bitexact", "-c:a", "copy", "-f", fixture.format, out)
                    if process.returncode == 0 and out.read_bytes() == fixture.data:
                        muxed_ok += 1
                    else:
                        problems.append(f"FFmpeg's {fixture.format} muxer exited {process.returncode} or changed the bytes")
                accepted_ok += not problems
            else:
                problems += check_rejection(args.zffprobe, path, fixture.reject, input_args)
                ours = f"exit {EXIT_STATUS[fixture.reject]}"
                expected_text = f"`{fixture.reject}`"
                probe_code, fields, probe_err = ffprobe(args.ffprobe, path, input_args)
                decode_code, raw, decode_err = ffmpeg_decode(args.ffmpeg, path, input_args)
                if probe_code == 0 and decode_code == 0:
                    theirs = f"accepts: {fields.get('sample_rate', '?')} Hz, {len(raw) // 2} samples"
                    ffmpeg_accepts_rejected += 1
                else:
                    theirs = f"rejects: {clean(first_line(probe_err or decode_err), path) or 'exit ' + str(probe_code or decode_code)}"
                rejected_ok += not problems
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            lines.append(f"| `{fixture.name}` | `-f {fixture.format}`, {expected_text} | {theirs} | {ours} | {named} | {result} |")
            failures.extend(f"{fixture.name}: {problem}" for problem in problems)
    accepted = sum(1 for f in fixtures if f.accept is not None)
    lines += [
        "",
        f"Accepted raw fixtures FFmpeg and zffprobe read as expected: {accepted_ok}/{accepted}.",
        f"Rejected raw fixtures with zffprobe's expected status and error: {rejected_ok}/{len(fixtures) - accepted}; "
        f"FFmpeg accepts {ffmpeg_accepts_rejected} (intentional differences).",
        f"Named copies detected as their format by FFmpeg and zffprobe: {named_ok}/{named_total}.",
        f"Writer-output fixtures FFmpeg's raw muxers copy unchanged: {muxed_ok}/{muxed_total}.",
    ]
    record("Raw PCM fixtures (T22c)", accepted_ok + rejected_ok + named_ok + muxed_ok,
           len(fixtures) + named_total + muxed_total)


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
    streams += [(f.format, f) for f in generate.build_raw_fixtures() if f.writer_output]
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
            process = run(args.writer, container, stream.codec, rate, channels, raw, out, *options,
                          f"layout={stream.layout}")
            problems, notes = [], []
            if process.returncode != 0:
                problems.append(f"write-driver exited {process.returncode}: {first_line(text(process.stderr))}")
                output = "not written"
            else:
                written = out.read_bytes()
                output = f"{len(written)} bytes, " + ("equal to the fixture" if written == fixture.data else "differs")
                if written != fixture.data:
                    problems.append("output differs from the writer-output fixture")
                # Raw output is read back with the fixture's own -ch_layout.
                layout = (stream.layout if container in generate.RAW_FORMATS
                          else written_layout(container, stream.codec, rate, stream.layout, channels))
                expected = expected_stream(container, stream.codec, channels, rate, frames, stream.storage, layout)
                if container in generate.RAW_FORMATS:
                    stream_problems, notes = check_stream(args, fixture.name, out, expected, stream,
                                                          raw_input_args(container, fixture.params))
                elif container == "aiff":
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
            label = f"{container.upper()} `{stream.codec}` {layout_text(stream)}, {rate} Hz, {frames_text(frames)} (`{fixture.name}`)"
            lines.append(f"| {label} | {output} | {verdict} | {result} |")
            passed += not problems
            failures.extend(f"writer {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"Zig-written files FFmpeg reads as expected: {passed}/{len(streams)}."]
    record("Zig-written files read by FFmpeg", passed, len(streams))


def compare_zffmpeg(args, lines, failures):
    """zffmpeg's actual output for every accepted fixture, read by FFmpeg (T13b, T21a, T21b, T22b).

    Copy works into any container that carries the input's codec, and
    transcoding only from samples stored as s16 (other storage needs
    sample-format conversion, T23a). Each supported cell writes a file that
    FFmpeg must probe and decode to the fixture's samples and stream; the same
    command through standard input and output must give the same bytes, except
    that raw PCM from a pipe into a container with a header must fail with
    status 3, `UnsupportedStreamingSize`, writing nothing (T22c). Every
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
    inputs += [(f.format, FIXTURES / "raw" / f"{f.name}.raw", f) for f in generate.build_raw_fixtures() if f.accept]
    # The codecs each output carries; copy needs the input's (T21a, T22a, T22b);
    # a raw format carries its own codec only (T22c).
    carried = {"wav": generate.WAV_CODECS, "w64": generate.WAV_CODECS, "au": generate.AU_CODECS,
               "aiff": generate.AIFF_CODECS}
    carried.update({fmt: {codec} for fmt, codec in generate.RAW_FORMATS.items()})
    read_ok = read_total = rejected_ok = rejected_total = same_ok = same_total = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for container, path, fixture in inputs:
            stream = fixture.accept
            channels, rate, samples = stream
            frames = len(samples) // channels
            for output, copy in [(o, c) for c in (False, True) for o in ZFFMPEG_OUTPUTS]:
                cell = f"{'copy' if copy else 'transcode'} to {output.upper() if output not in generate.RAW_FORMATS else output}"
                options = (["-c", "copy"] if copy else []) + ["-f", output]
                out = work / f"{fixture.name}-{'copy' if copy else 'transcode'}.{output}"
                # An input FFmpeg's probing does not detect is forced (T16);
                # raw PCM with its format and parameters (T22c).
                if container in generate.RAW_FORMATS:
                    input_args = raw_input_args(container, fixture.params)
                else:
                    input_args = forced_input(fixture, container)
                code, _, err = zffprobe_raw(args.zffmpeg, *input_args, "-i", path, *options, out)
                output_codec = stream.codec if copy else S16_CODEC[output]
                # Since T23a any storage transcodes to the output's default codec.
                supported = stream.codec in carried[output] if copy else True
                if not supported:
                    rejected_total += 1
                    error = b"UnsupportedOperation"
                    if code == 3 and error in err and not out.exists():
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
                    pipe_code, pipe_out, pipe_err = zffprobe_raw(args.zffmpeg, *input_args, "-i", "-", *options, "-",
                                                                 data=path.read_bytes())
                    if container in generate.RAW_FORMATS and output not in generate.RAW_FORMATS:
                        # Raw PCM from a pipe has no length for a header's sizes
                        # (T22c contract): status 3 before any output.
                        if pipe_code != 3 or b"UnsupportedStreamingSize" not in pipe_err or pipe_out:
                            problems.append(f"through pipes zffmpeg exited {pipe_code} "
                                            f"({first_line(text(pipe_err)) or 'no error'}), "
                                            f"expected UnsupportedStreamingSize")
                    elif pipe_code != 0 or pipe_out != written:
                        problems.append(f"through pipes zffmpeg exited {pipe_code} with different output")
                    codec = output_codec
                    # FFmpeg's command line guesses an unspecified layout, for copy
                    # too, unless an input -ch_layout names it, as for raw PCM
                    # here; the output keeps what its muxer can store (T23b).
                    in_layout = (stream.layout if container in generate.RAW_FORMATS and fixture.params
                                 else guessed_layout(stream.layout, channels))
                    out_layout = written_layout(output, codec, rate, in_layout, channels)
                    expected = expected_stream(output, codec, channels, rate, frames, stream.storage, out_layout)
                    differences = dict(FIELD_DIFFERENCES.get(output, KNOWN_FIELD_DIFFERENCES))
                    # FFmpeg reads raw output with the stream's parameters.
                    output_args = (raw_input_args(output, (rate, channels)) if output in generate.RAW_FORMATS
                                   else output if output in ("au", "aiff") else None)
                    # A G.711 encoding loses precision, and a storage change converts the
                    # samples: either way the bytes must be FFmpeg's own conversion (T23a).
                    lossy = codec != stream.codec and (codec in ("pcm_alaw", "pcm_mulaw")
                                                       or generate.CAF_STORAGE[codec] != stream.storage)
                    if output == "wav" and frames == 0:
                        differences[("duration_ts", "N/A")] = "FFmpeg reads data size 0 as unknown length"
                    if output == "w64":
                        differences = w64_differences(written, codec, channels, frames, differences)
                    if output in generate.RAW_FORMATS and frames == 0:
                        differences[("duration_ts", "N/A")] = "FFmpeg gives an empty raw file no duration"
                    if lossy:
                        if fixture.name in KNOWN_AU_DECODE_DIFFERENCES:
                            notes.append("lossy, and FFmpeg reads the input differently: not compared")
                        elif frames == 0:
                            notes.append("empty: nothing to convert")
                        else:
                            problems += check_converted(args, path, input_args, out, output, output_args, codec, work)
                            if not problems:
                                notes.append("converted: the samples of FFmpeg's own conversion")
                    elif output == "w64" and frames == 0:
                        probe_code, _, _ = ffprobe(args.ffprobe, out)
                        z_code, z_fields, _ = zffprobe(args.zffprobe, out)
                        if probe_code == 0:
                            problems.append("FFmpeg now reads an empty Wave64 `data` chunk")
                        if z_code != 0 or z_fields != zffprobe_report("w64", codec, channels, rate, 0, stream.storage,
                                                                      out_layout):
                            problems.append(f"zffprobe exited {z_code} with {z_fields}")
                        empty_w64 = True
                    else:
                        # Forced for AU, because FFmpeg's probe does not detect an empty AU file.
                        stream_problems, notes = check_stream(args, f"zffmpeg {fixture.name}", out, expected, stream,
                                                              output_args if output != "aiff" else None,
                                                              field_differences=differences)
                        problems += stream_problems
                        problems += check_carried_tags(args, fixture, path, out, output, copy, work, notes)
                    if output in ("au", "aiff") and fixture.writer_output and not fixture.tags and not lossy:
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
    record("zffmpeg outputs (T13b, T23a)", read_ok + rejected_ok + same_ok, read_total + rejected_total + same_total)


# zffmpeg's outputs in the matrix: every container with a header, and raw PCM
# s16le (lossless transcoding), A-law (lossy transcoding) and f64be (copy only).
ZFFMPEG_OUTPUTS = ("wav", "w64", "au", "aiff", "s16le", "alaw", "f64be")


def check_converted(args, path, input_args, out, output, output_args, codec, work):
    """A transcode that converts the sample format or encodes G.711 (T23a):
    zffmpeg's output must hold `codec` and decode, in FFmpeg, to the samples
    of FFmpeg's own conversion of the same input (`-bitexact -c:a <codec>`),
    written as raw PCM of that codec, so no container header (FFmpeg's Wave64
    counts its padding as samples) gets in the way. Returns the problems."""
    raw_format = next((fmt for fmt, c in generate.RAW_FORMATS.items() if c == codec), None)
    reference = work / "ffmpeg-converted.raw"
    container = raw_format or output
    process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", path, "-bitexact",
                  "-c:a", codec, "-f", container, reference)
    if process.returncode != 0:
        return [f"ffmpeg's own conversion failed: {first_line(text(process.stderr))}"]
    storage = generate.CAF_STORAGE[codec]
    code, fields, err = ffprobe(args.ffprobe, out, output_args)
    if code != 0 or fields.get("codec_name") != codec:
        return [f"ffprobe reads {fields.get('codec_name')} ({first_line(err)}), expected {codec}"]
    if raw_format is not None:
        rate, channels = int(fields["sample_rate"]), int(fields["channels"])
        reference_args = raw_input_args(raw_format, (rate, channels))
    else:
        reference_args = output_args
    ours_code, ours, ours_err = ffmpeg_decode(args.ffmpeg, out, output_args, storage)
    theirs_code, theirs, theirs_err = ffmpeg_decode(args.ffmpeg, reference, reference_args, storage)
    if ours_code != 0 or theirs_code != 0:
        return [f"decoding failed: ours {first_line(ours_err)}, FFmpeg's {first_line(theirs_err)}"]
    if ours != theirs:
        return [f"samples differ from FFmpeg's own conversion ({len(ours)} and {len(theirs)} bytes)"]
    return []

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

# T23a dither: long generated inputs, so the noise buffer restarts, in every
# container, whose demuxers read packets of different sizes (FFmpeg converts
# a packet at a time, and the noise depends on it). Each is (name, container,
# the codec FFmpeg writes it with, or the raw format, rate, channels).
DITHER_INPUTS = [
    ("f32-wav", "wav", "pcm_f32le", 44100, 2),
    ("s24-aiff", "aiff", "pcm_s24be", 48000, 2),
    ("s32-au", "au", "pcm_s32be", 8000, 1),
    ("f64-w64", "w64", "pcm_f64le", 22050, 2),
    ("f32be-raw", "f32be", None, 37800, 2),
    ("s32be-caf", "caf", "pcm_s32be", 46000, 1),
    ("s16-wav", "wav", "pcm_s16le", 44100, 2),
    # Six channels (T23b): FFmpeg guesses 5.1 for the raw input and writes it.
    ("f32-wav-6ch", "wav", "pcm_f32le", 48000, 6),
]
DITHER_FRAMES = 200000
DITHER_METHODS = ("rectangular", "triangular", "triangular_hp", "lipshitz", "f_weighted", "modified_e_weighted",
                  "improved_e_weighted", "shibata", "low_shibata", "high_shibata")
# The encoders each input is converted to, as raw PCM of the encoder.
DITHER_ENCODERS = ("pcm_s16le", "pcm_u8", "pcm_s24le", "pcm_s32le")


def dither_source(ffmpeg, work, name, container, codec, rate, channels):
    """Writes one DITHER_INPUTS input and returns its path and input options:
    a 64-bit LCG's top bits as f32 samples, raw, then put in the container by
    FFmpeg (or, for CAF, which the reference build cannot write, by hand)."""
    x, values = 1, []
    for _ in range(DITHER_FRAMES * channels):
        x = (x * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        values.append(((x >> 32) - (1 << 32 if x >> 63 else 0)) / 2147483648.0)
    raw = work / f"{name}.f32le"
    raw.write_bytes(struct.pack(f"<{len(values)}f", *values))
    raw_args = raw_input_args("f32le", (rate, channels))
    if codec is None:
        path = work / f"{name}.{container}"
        process = run(ffmpeg, "-v", "error", "-nostdin", "-y", *raw_args, "-i", raw, "-f", container, path)
        return path, raw_input_args(container, (rate, channels)), process
    if container == "caf":
        # Big-endian s32 PCM: `desc` (flags 0), then `data` with its edit count.
        reference = work / f"{name}.s32be"
        process = run(ffmpeg, "-v", "error", "-nostdin", "-y", *raw_args, "-i", raw, "-f", "s32be", reference)
        data = reference.read_bytes() if reference.exists() else b""
        desc = struct.pack(">d4sIIIII", rate, b"lpcm", 0, 4 * channels, 1, channels, 32)
        path = work / f"{name}.caf"
        path.write_bytes(b"caff" + struct.pack(">HH", 1, 0) + b"desc" + struct.pack(">q", len(desc)) + desc
                         + b"data" + struct.pack(">qI", len(data) + 4, 0) + data)
        return path, [], process
    path = work / f"{name}.{container}"
    process = run(ffmpeg, "-v", "error", "-nostdin", "-y", *raw_args, "-i", raw, "-bitexact", "-c:a", codec,
                  "-f", container, path)
    return path, [], process



def compare_dither(args, lines, failures):
    """zffmpeg's `-dither_method` and `-dither_scale` against FFmpeg's (T23a):
    every method on long inputs in every input container, to every encoder
    the sample format can narrow to, each written as raw PCM by both, must
    give the same bytes. FFmpeg dithers only when the sample format changes
    (not s32 to a 24-bit encoder) and scales the noise for a 24-bit encoder;
    the noise follows FFmpeg's packet sizes."""
    lines += [
        "",
        "## zffmpeg dither against FFmpeg",
        "",
        "| Input | Encoder | Methods and scales | Result |",
        "| --- | --- | --- | --- |",
    ]
    same = total = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for name, container, codec, rate, channels in DITHER_INPUTS:
            path, input_args, process = dither_source(args.ffmpeg, work, name, container, codec, rate, channels)
            if process.returncode != 0:
                failures.append(f"dither {name}: making the input failed: {first_line(text(process.stderr))}")
                continue
            for encoder in DITHER_ENCODERS:
                raw_format = next(fmt for fmt, c in generate.RAW_FORMATS.items() if c == encoder)
                settings = [(method, None) for method in DITHER_METHODS] + [("triangular", "0.5"), ("shibata", "3"),
                                                                            ("triangular", "0")]
                problems = []
                for method, scale in settings:
                    options = ["-dither_method", method] + (["-dither_scale", scale] if scale else [])
                    theirs, ours = work / "ffmpeg.raw", work / "zffmpeg.raw"
                    process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", path, *options,
                                  "-c:a", encoder, "-f", raw_format, theirs)
                    code, _, err = zffprobe_raw(args.zffmpeg, "-y", *input_args, "-i", path, "-c:a", encoder,
                                                *options, "-f", raw_format, ours)
                    total += 1
                    if process.returncode != 0 or code != 0:
                        problems.append(f"{method} {scale or 1}: FFmpeg exited {process.returncode}, zffmpeg {code} "
                                        f"({first_line(text(err))})")
                    elif theirs.read_bytes() != ours.read_bytes():
                        problems.append(f"{method} {scale or 1}: the samples differ")
                    else:
                        same += 1
                result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
                lines.append(f"| `{name}` | {encoder} | {len(settings)} | {result} |")
                failures.extend(f"dither {name} to {encoder}: {problem}" for problem in problems)
    lines += ["", f"Dithered conversions equal to FFmpeg's: {same}/{total}."]
    record("Dither (T23a)", same, total)


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
                # FFmpeg's copy carries its guessed layout into the Wave64 header.
                guessed = guessed_layout(stream.layout, channels)
                want = zffprobe_report("w64", stream.codec, channels, rate, frames, stream.storage,
                                       written_layout("w64", stream.codec, rate, guessed, channels))
                probe_text = "report matches" if code == 0 and fields == want else f"exit {code}"
                if code != 0 or fields != want:
                    problems.append(f"zffprobe exited {code} with {fields or first_line(err)}")
                code, copied, err = zffprobe_raw(args.zffmpeg, "-i", out, "-c", "copy", "-f", "wav", "-")
                # Copied back with the guessed layout: the fixture itself unless
                # the guess names a layout WAV writes as a mask (six plain
                # channels become 5.1).
                expected_copy = fixture.data
                if guessed != stream.layout:
                    _, bits, _ = generate.WAV_CODECS[stream.codec]
                    payload = fixture.data[len(fixture.data) - frames * channels * bits // 8:]
                    expected_copy = generate.canonical_wav(stream.codec, channels, rate, payload, mask=layout_mask(guessed))
                copy_text = "equal to the fixture" if code == 0 and copied == fixture.data else (
                    "the fixture with the guessed layout" if code == 0 and copied == expected_copy else f"exit {code}")
                if code != 0 or copied != expected_copy:
                    problems.append(f"zffmpeg copy exited {code} ({first_line(text(err)) or 'different bytes'})")
            passed += not problems
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            lines.append(f"| `{fixture.name}` | {probe_text} | {copy_text} | {result} |")
            failures.extend(f"ffmpeg w64 {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"FFmpeg-written Wave64 files read as expected: {passed}/{len(fixtures)}."]
    record("FFmpeg-written Wave64 (T21b)", passed, len(fixtures))


def compare_ffmpeg_muxer(args, lines, failures, container, title, build):
    """FFmpeg's AU or AIFF muxer against the Zig writer (T22a, T22b): FFmpeg
    copies each writer-output fixture into the same container, which must give
    back the same bytes, so both write the same header for every encoding.
    `-guess_layout_max 0` keeps the command line from guessing a layout for an
    unspecified one (T23b), so the muxer gets the stream's own: six AIFF
    channels with no CHAN stay without one."""
    fixtures = [f for f in build() if f.writer_output]
    same = 0
    with tempfile.TemporaryDirectory() as tmp:
        for fixture in fixtures:
            out = pathlib.Path(tmp) / f"{fixture.name}.{container}"
            # Forced, because FFmpeg's probe does not detect an empty AU file.
            process = run(args.ffmpeg, "-v", "error", "-nostdin", "-f", container, "-guess_layout_max", "0",
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
    record(f"FFmpeg's {title} muxer", same, len(fixtures))


# Output rates for zffmpeg's resampler (T24), as FFmpeg's output options,
# with the raw format each output is compared in.
RESAMPLE_OPTIONS = [
    (["-ar", "48000"], "s16le"),
    (["-ar", "8000"], "s16le"),
    (["-ar", "44100", "-ac", "1"], "s16le"),
    (["-ar", "96000", "-c:a", "pcm_f32le"], "f32le"),
    (["-ar", "22050", "-c:a", "pcm_f64le"], "f64le"),
    (["-ar", "48000", "-dither_method", "triangular"], "s16le"),
    (["-ar", "32000", "-ch_layout", "5.1"], "s16le"),
]


def compare_resample(args, lines, failures):
    """zffmpeg's output -ar against FFmpeg's (T24): the long generated inputs
    of the dither section, one per input container, resampled to each rate of
    RESAMPLE_OPTIONS (with a layout change, float and double output, and
    dither among them) and written as raw PCM by both: equal bytes."""
    lines += [
        "",
        "## zffmpeg resampling against FFmpeg",
        "",
        "| Input | Options | Result |",
        "| --- | --- | --- |",
    ]
    exact = total = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for name, container, codec, rate, channels in DITHER_INPUTS:
            path, input_args, process = dither_source(args.ffmpeg, work, name, container, codec, rate, channels)
            if process.returncode != 0:
                failures.append(f"resample {name}: making the input failed: {first_line(text(process.stderr))}")
                continue
            for options, raw_format in RESAMPLE_OPTIONS:
                theirs, ours = work / "ffmpeg.raw", work / "zffmpeg.raw"
                for stale in (theirs, ours):
                    stale.unlink(missing_ok=True)
                process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", path, *options,
                              "-bitexact", "-f", raw_format, theirs)
                code, _, err = zffprobe_raw(args.zffmpeg, "-y", *input_args, "-i", path, *options, "-f", raw_format,
                                            ours)
                total += 1
                label = " ".join(options)
                if process.returncode != 0 or code != 0:
                    result = f"**FAIL**: FFmpeg exited {process.returncode}, zffmpeg {code} ({first_line(text(err))})"
                    failures.append(f"resample {name} {label}: {result}")
                else:
                    a, b = theirs.read_bytes(), ours.read_bytes()
                    if a == b:
                        exact += 1
                        result = "pass (equal bytes)"
                    else:
                        if len(a) != len(b):
                            result = f"**FAIL**: {len(b)} bytes, FFmpeg {len(a)}"
                        else:
                            first = next(i for i in range(len(a)) if a[i] != b[i])
                            result = f"**FAIL**: bytes differ from offset {first}"
                        failures.append(f"resample {name} {label}: {result}")
                lines.append(f"| `{name}` | {label} | {result} |")
    lines += ["", f"Resampled outputs equal to FFmpeg's: {exact}/{total}."]
    record("Resampling (T24)", exact, total)


# Inputs whose decoded samples FFmpeg reads differently, for reasons other
# sections record: their remixed outputs differ by that alone.
KNOWN_REMIX_DIFFERENCES = {
    "au_trailing_bytes_after_data": "FFmpeg decodes the bytes after the declared data",
    # FFmpeg reads their layout chunk after the samples (quad); the port
    # mixes the default layout for four channels (4.0).
    "aiff_chan_after_ssnd": "FFmpeg mixes the CHAN after SSND's quad",
    "caf_chan_after_data": "FFmpeg mixes the chan after data's quad",
}

# Output layouts for zffmpeg's rematrix (T23c), as FFmpeg's output options:
# downmixes, an upmix, a reorder, dither after the mix, and float output.
REMIX_OPTIONS = [
    ["-ac", "1"],
    ["-ac", "2"],
    ["-ch_layout", "5.1"],
    ["-ch_layout", "FR+FL"],
    ["-ac", "2", "-dither_method", "triangular"],
    ["-ac", "2", "-c:a", "pcm_f32le"],
]


def compare_remix(args, lines, failures):
    """zffmpeg's output -ac and -ch_layout against FFmpeg's (T23c): every
    accepted fixture of every input container, rematrixed into each layout
    of REMIX_OPTIONS and written as raw PCM by both (s16le, or f32le for the
    float encoder), so the samples alone are compared, must give the same
    bytes; where FFmpeg's libswresample cannot mix the layouts, zffmpeg must
    refuse too, with status 3 and no output. The input differences recorded
    for the other sections stay: FFmpeg decodes the bytes after an AU's
    data (`au_trailing_bytes_after_data`)."""
    lines += [
        "",
        "## zffmpeg rematrix against FFmpeg",
        "",
        "| Input | Options | Result |",
        "| --- | --- | --- |",
    ]
    inputs = [(wav_container(f), FIXTURES / "wav" / f"{f.name}.wav", f) for f in generate.build_fixtures() if f.accept]
    inputs += [(directory, FIXTURES / directory / f"{f.name}.{directory}", f)
               for directory, _, build, _, _ in FORCED_CONTRACTS for f in build() if f.accept]
    inputs += [(f.format, FIXTURES / "raw" / f"{f.name}.raw", f) for f in generate.build_raw_fixtures() if f.accept]
    same = refused = total = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for container, path, fixture in inputs:
            if container in generate.RAW_FORMATS:
                input_args = raw_input_args(container, fixture.params)
            else:
                input_args = forced_input(fixture, container)
            problems = []
            for options in REMIX_OPTIONS:
                raw_format = "f32le" if "pcm_f32le" in options else "s16le"
                theirs, ours = work / "ffmpeg.raw", work / "zffmpeg.raw"
                for stale in (theirs, ours):
                    stale.unlink(missing_ok=True)
                process = run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", path, *options,
                              "-bitexact", "-f", raw_format, theirs)
                code, _, err = zffprobe_raw(args.zffmpeg, "-y", *input_args, "-i", path, *options, "-f", raw_format,
                                            ours)
                total += 1
                label = " ".join(options)
                if process.returncode != 0:
                    if code == 3 and not ours.exists():
                        refused += 1
                    else:
                        problems.append(f"{label}: FFmpeg refuses ({first_line(text(process.stderr))}), "
                                        f"zffmpeg exited {code}")
                elif code != 0:
                    problems.append(f"{label}: zffmpeg exited {code} ({first_line(text(err))})")
                elif theirs.read_bytes() != ours.read_bytes():
                    if fixture.name in KNOWN_REMIX_DIFFERENCES:
                        same += 1
                    else:
                        problems.append(f"{label}: the output differs")
                else:
                    same += 1
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            if not problems and fixture.name in KNOWN_REMIX_DIFFERENCES:
                result = f"pass ({KNOWN_REMIX_DIFFERENCES[fixture.name]})"
            lines.append(f"| `{fixture.name}` | {len(REMIX_OPTIONS)} layouts | {result} |")
            failures.extend(f"remix {fixture.name}: {problem}" for problem in problems)
    lines += ["", f"Rematrixed outputs equal to FFmpeg's: {same}/{total}; refused by both: {refused}."]
    record("Rematrixing (T23c)", same + refused, total)


def compare_pipes(args, lines, failures):
    """zffprobe through a pipe must match zffprobe on the file (T12c)."""
    cases = [(FIXTURES / "wav" / f"{f.name}.wav") for f in generate.build_fixtures()]
    cases = [(path, []) for path in cases]
    cases += [(FIXTURES / directory / f"{f.name}.{directory}", [])
              for directory, _, build, _, _ in FORCED_CONTRACTS for f in build()]
    # Raw PCM forced: the length comes from the file, or is counted from the pipe.
    cases += [(FIXTURES / "raw" / f"{f.name}.raw", raw_input_args(f.format, f.params))
              for f in generate.build_raw_fixtures()]
    same = 0
    for path, input_args in cases:
        file_code, file_out, file_err = zffprobe_raw(args.zffprobe, *input_args, path)
        pipe_code, pipe_out, pipe_err = zffprobe_raw(args.zffprobe, *input_args, "-", data=path.read_bytes())
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
    record("zffprobe through a pipe", same, len(cases))


# FLAC fixtures zffmpeg converts differently from the ffmpeg program (T26a).
KNOWN_FLAC_CONVERSION_DIFFERENCES = {
    "flac_junk_between_frames": "FFmpeg's parser drops a valid frame after the junk, so the samples fall short "
                                "of STREAMINFO's count, which zffmpeg writes in the WAV header first "
                                "(`FrameCountMismatch`); FFmpeg rewrites its seekable output's header",
    "flac_bps24": "no frames for STREAMINFO's 576 samples (`FrameCountMismatch`), as above",
    "flac_no_total": "no sample count for the WAV header written first (`UnsupportedStreamingSize`); FFmpeg "
                     "rewrites its header",
    "flac_headerless": "no STREAMINFO, so no sample count for the WAV header written first, as above",
    "flac_streaminfo_rate0": "no sample count in STREAMINFO without a rate, as above",
    "flac_channel_change": "a mid-stream channel change, which the WAV header written first cannot follow "
                           "(`UnsupportedFormat`); the ffmpeg program's filters convert it",
    "flac_rate_change": "a mid-stream rate change, as above",
}


def compare_flac(args, lines, failures):
    """FLAC (T26a): each fixture's integrity and FFmpeg's detection, zffprobe's
    report against ffprobe's fields, the contract's status for rejected ones
    beside FFmpeg's verdict, and zffmpeg's WAV against the ffmpeg program's
    bit-exact one."""
    lines += [
        "",
        "## FLAC fixtures (T26a)",
        "",
        "| Fixture | zffprobe | FFmpeg | WAV conversion | Result |",
        "| --- | --- | --- | --- | --- |",
    ]
    matched = total = 0
    for fixture in generate.build_flac_fixtures():
        total += 1
        path = FIXTURES / "flac" / f"{fixture.name}.flac"
        problems = []
        if not path.exists():
            failures.append(f"{fixture.name}: fixture file is missing")
            continue
        data = path.read_bytes()
        if fixture.data is not None and data != fixture.data:
            failures.append(f"{fixture.name}: fixture file differs from generate.py")
            continue
        if fixture.data is None and hashlib.sha256(data).hexdigest() != fixture.sha256:
            failures.append(f"{fixture.name}: FFmpeg-made fixture differs from its recorded hash")
            continue
        theirs_detected = detected_format(args.ffprobe, path)
        if theirs_detected != generate.ffmpeg_detect(data[:2048]):
            problems.append(f"FFmpeg's probe picks {theirs_detected or 'nothing'}")
        conversion = "-"
        if fixture.reject:
            problems += check_rejection(args.zffprobe, path, fixture.reject)
            ours = f"`{fixture.reject}`"
            theirs = ffmpeg_verdict(args, path)
        else:
            code, fields, err = zffprobe(args.zffprobe, path)
            # The audio stream: a PICTURE block is FFmpeg's second stream.
            their = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,time_base,duration_ts"
                        ":format=format_name", "-of", "default=noprint_wrappers=1", path)
            their_code, their_fields, their_err = their.returncode, key_values(text(their.stdout)), text(their.stderr)
            ours = "accepts" if code == 0 else f"exit {code}: {err}"
            theirs = "accepts" if their_code == 0 else f"rejects: {clean(first_line(their_err), path)}"
            expected = {
                "format": their_fields.get("format_name"),
                "codec": their_fields.get("codec_name"),
                "sample_fmt": their_fields.get("sample_fmt"),
                "channels": their_fields.get("channels"),
                "channel_layout": their_fields.get("channel_layout"),
                "sample_rate": their_fields.get("sample_rate"),
                "nb_samples": their_fields.get("duration_ts"),
                "duration_num": their_fields.get("duration_ts"),
                # zffprobe's three count fields are N/A together.
                "duration_den": "N/A" if their_fields.get("duration_ts") == "N/A" else their_fields.get("sample_rate"),
            }
            if code != 0 or their_code != 0:
                problems.append(f"zffprobe exit {code}, ffprobe exit {their_code}")
            elif fields != expected:
                problems.append(f"zffprobe {fields}, ffprobe {expected}")
            # The time base (FFmpeg's 1/90000 without a STREAMINFO rate) is
            # checked against flac.txt by the Zig tests.
            if their_fields.get("time_base") not in (f"1/{their_fields.get('sample_rate')}", "1/90000"):
                problems.append(f"ffprobe's time base {their_fields.get('time_base')}")
            want_tags = [(k.encode(), v.encode()) for k, v in (fixture.tags or [])]
            if zffprobe_tags(args.zffprobe, path) != want_tags or ffprobe_tags(args.ffprobe, path) != want_tags:
                problems.append("the tags differ from the manifest's in zffprobe or ffprobe")
            with tempfile.TemporaryDirectory() as work:
                out_ours = pathlib.Path(work) / "ours.wav"
                out_theirs = pathlib.Path(work) / "theirs.wav"
                zr = run(args.zffmpeg, "-i", path, out_ours)
                fr = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", path, "-fflags", "+bitexact",
                         "-flags:a", "+bitexact", out_theirs)
                same = zr.returncode == 0 and fr.returncode == 0 and out_ours.read_bytes() == out_theirs.read_bytes()
                known = KNOWN_FLAC_CONVERSION_DIFFERENCES.get(fixture.name)
                if same:
                    conversion = "identical"
                elif known:
                    conversion = f"known: {known}"
                else:
                    conversion = "differs"
                    problems.append(f"zffmpeg exit {zr.returncode} ({first_line(text(zr.stderr))}), ffmpeg exit "
                                    f"{fr.returncode}; the WAV files differ")
        matched += not problems
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {ours} | {theirs} | {conversion} | {result} |")
        failures.extend(f"{fixture.name}: {problem}" for problem in problems)
    lines += ["", f"FLAC fixtures matching the contract and FFmpeg: {matched}/{total}."]
    record("FLAC fixtures (T26a, T26b)", matched, total)


# Fixtures whose hash text differs from the ffmpeg program's for an
# understood reason, by (fixture, mode): (reason).
KNOWN_HASH_DIFFERENCES = {
    ("flac_rate_streaminfo", "copy"): "its one packet has no timestamp, which the ffmpeg program makes 0",
    ("flac_rate_streaminfo", "decode"): "its one frame has no timestamp, which the ffmpeg program drops",
    ("au_trailing_bytes_after_data", "copy"): "FFmpeg reads the bytes after the declared data",
    ("au_trailing_bytes_after_data", "decode"): "FFmpeg decodes the bytes after the declared data",
    ("aiff_chan_after_ssnd", "copy"): "CHAN after SSND is not read",
    ("aiff_chan_after_ssnd", "decode"): "CHAN after SSND is not read",
    ("caf_chan_after_data", "copy"): "`chan` after `data` is not read",
    ("caf_chan_after_data", "decode"): "`chan` after `data` is not read",
    ("caf_chunks_around_data", "copy"): "FFmpeg keeps a `kuki` chunk as the stream's extradata",
    ("flac_picture", "copy"): "FFmpeg makes the PICTURE block a second, attached-picture stream; the port keeps it "
                              "as data",
    ("flac_picture", "decode"): "the attached-picture stream, as above, which the ffmpeg program cannot encode "
                                "in this build",
    ("flac_channel_change", "decode"): "the ffmpeg program's filters convert a mid-stream change; the driver "
                                       "hashes the decoder's frames",
    ("flac_rate_change", "decode"): "a mid-stream rate change, as above",
    # The driver copies through the codec's raw format, and FFmpeg has none
    # for s64; the decoded stream is still compared.
    ("s64_mono_8k_extensible", "copy"): "the hash driver has no raw format to copy s64 into",
    ("caf_s64be_mono", "copy"): "the hash driver has no raw format to copy s64 into",
    ("caf_s64le_mono", "copy"): "the hash driver has no raw format to copy s64 into",
}


def compare_hashes(args, lines, failures):
    """FFmpeg's framecrc, framemd5 and streamhash text from the ffmpeg program
    against the hash driver's for the same input (T19b): every FLAC fixture
    FFmpeg reads, its packets copied and its frames decoded to pcm_s16le, in
    all three; and every accepted WAV, AU, AIFF and CAF fixture's stream,
    copied and decoded, in streamhash, the one whose text does not depend on
    FFmpeg's PCM packet sizes."""
    cases = []
    # The decoded storage: s32 above 16 bits.
    s32_inputs = set()
    for fixture in generate.build_flac_fixtures():
        if fixture.reject is None:
            cases.append((FIXTURES / "flac" / f"{fixture.name}.flac", ("framecrc", "framemd5", "streamhash")))
            if fixture.bps > 16:
                s32_inputs.add(fixture.name)
    for fixture in generate.build_fixtures():
        if fixture.accept is not None:
            cases.append((FIXTURES / "wav" / f"{fixture.name}.wav", ("streamhash",)))
    for directory, _, build, _, _ in FORCED_CONTRACTS:
        for fixture in build():
            if fixture.accept is not None:
                cases.append((FIXTURES / directory / f"{fixture.name}.{directory}", ("streamhash",)))
    same = known = total = 0
    for path, kinds in cases:
        for kind in kinds:
            for mode in ("copy", "decode"):
                decoder_codec = "pcm_s32le" if path.stem in s32_inputs else "pcm_s16le"
                codec = ["-c", "copy"] if mode == "copy" else ["-c:a", decoder_codec]
                theirs = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-fflags", "+bitexact",
                             *codec, "-f", kind, "-")
                ours = run(args.hasher, kind, mode, str(path))
                total += 1
                # Both refusing the input agrees too (an input only a forced
                # format opens).
                if (ours.returncode == 0) == (theirs.returncode == 0) and ours.stdout == theirs.stdout:
                    same += 1
                    continue
                reason = KNOWN_HASH_DIFFERENCES.get((path.stem, mode))
                if reason is not None:
                    known += 1
                    continue
                if ours.returncode != 0:
                    failures.append(f"{path.name}: the hash driver failed ({kind}, {mode}): {first_line(text(ours.stderr))}")
                elif theirs.returncode != 0:
                    failures.append(f"{path.name}: ffmpeg failed ({kind}, {mode}): {first_line(text(theirs.stderr))}")
                else:
                    failures.append(f"{path.name}: the {kind} text differs from ffmpeg's ({mode})")
    lines += [
        "",
        "## Frame and stream hashes",
        "",
        f"Hash texts equal to the ffmpeg program's with `-fflags +bitexact`: {same}/{total}; "
        f"understood differences: {known}.",
        "",
        "| Fixture | Mode | Understood difference |",
        "| --- | --- | --- |",
    ]
    record("Frame and stream hashes (T19b)", same + known, total, understood=known)
    lines += [f"| `{name}` | {mode} | {reason} |" for (name, mode), reason in KNOWN_HASH_DIFFERENCES.items()]


# tests/fate/flac.mak: (test, reference sample, encoder options, decoded codec).
FATE_FLAC = [
    ("fate-flac-16-chmode-indep", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-ch_mode", "indep"], "pcm_s16le"),
    ("fate-flac-16-chmode-left_side", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-ch_mode", "left_side"],
     "pcm_s16le"),
    ("fate-flac-16-chmode-mid_side", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-ch_mode", "mid_side"],
     "pcm_s16le"),
    ("fate-flac-16-chmode-right_side", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-ch_mode", "right_side"],
     "pcm_s16le"),
    ("fate-flac-16-fixed", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-lpc_type", "fixed"], "pcm_s16le"),
    ("fate-flac-16-lpc-cholesky", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-lpc_type", "cholesky"],
     "pcm_s16le"),
    ("fate-flac-16-lpc-levinson", "audio-reference/luckynight_2ch_44kHz_s16.wav", ["-lpc_type", "levinson"],
     "pcm_s16le"),
    ("fate-flac-24-comp-8", "audio-reference/divertimenti_2ch_96kHz_s24.wav", ["-compression_level", "8"], "pcm_s24le"),
    ("fate-flac-32-wasted-bits", "audio-reference/drums_2ch_44kHz_s32_wastedbits.wav", ["-strict", "experimental"],
     "pcm_s32le"),
    ("fate-flac-rice-params", "audio-reference/chorusnoise_2ch_44kHz_s16.wav", [], "pcm_s16le"),
]
# FLAC samples other FATE tests read, decoded as they are.
FATE_FLAC_SAMPLES = [
    "cover_art/cover_art.flac",
    "filter/hdcd-mix.flac",
    "filter/hdcd-false-positive.flac",
    "filter/hdcd-encoding-errors.flac",
    "filter/hdcd-fake20bit.flac",
    "filter/seq-3341-7_seq-3342-5-24bit.flac",
    "filter/out-of-phase-1000hz.flac",
]


def flac_output_inputs(work):
    """The WAV inputs of the FLAC output comparison (T26c), made here with
    the standard library: a tenth of a second or more of each sample format
    FFmpeg's FLAC encoder takes through its two storages, so that blocks are
    whole and the last one short."""
    import math
    import random
    specs = [
        # name, format tag, bits, channels, rate, frames
        ("s16_stereo_44k1", 1, 16, 2, 44100, 9000),
        ("u8_mono_8k", 1, 8, 1, 8000, 3000),
        ("s24_stereo_96k", 1, 24, 2, 96000, 12000),
        ("s32_stereo_48k", 1, 32, 2, 48000, 6000),
        ("f32_stereo_44k1", 3, 32, 2, 44100, 6000),
        ("f64_mono_48k", 3, 64, 1, 48000, 6000),
        ("s16_6ch_48k", 1, 16, 6, 48000, 5000),
        ("s16_mono_22k", 1, 16, 1, 22050, 5000),
        ("s64_ramp_stereo", 1, 64, 2, 44100, 5000),
    ]
    paths = {}
    for name, tag, bits, channels, rate, frames in specs:
        rnd = random.Random(name)
        data = bytearray()
        for i in range(frames):
            for c in range(channels):
                if name.startswith("s64"):
                    # Slow ramps: the LPC analysis' last bits matter.
                    v = i * (1234567890123 if c == 0 else -987654321)
                    data += struct.pack("<q", v)
                    continue
                x = math.sin(i * (0.01 + 0.003 * c)) * 0.6 + (rnd.random() - 0.5) * 0.05
                if tag == 3:
                    data += struct.pack("<f" if bits == 32 else "<d", x)
                elif bits == 8:
                    data += bytes([int(x * 127) + 128])
                else:
                    data += int(x * (2 ** (bits - 1) - 1)).to_bytes(bits // 8, "little", signed=True)
        align = channels * bits // 8
        fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * align, align, bits)
        body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
        path = work / f"{name}.wav"
        path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
        paths[name] = path
    return paths


# Encoder options compared on every FLAC output input (T26c).
FLAC_OUTPUT_OPTIONS = [[]] + [["-compression_level", str(level)] for level in range(13)] + [
    ["-strict", "experimental"],
    ["-compression_level", "12", "-strict", "-2"],
    ["-lpc_type", "cholesky", "-lpc_passes", "3"],
    ["-lpc_type", "none"],
    ["-ch_mode", "mid_side", "-exact_rice_parameters", "1"],
    ["-prediction_order_method", "8level", "-max_prediction_order", "32"],
    ["-multi_dim_quant", "1", "-max_prediction_order", "4"],
    ["-min_partition_order", "0", "-max_partition_order", "0", "-lpc_coeff_precision", "7"],
    ["-ar", "48000"],
    ["-ac", "1"],
    ["-ar", "22050", "-ac", "2"],
]


def compare_flac_output(args, lines, failures):
    """zffmpeg's FLAC output (T26c) against the ffmpeg program's with
    `-bitexact`: the same bytes, as a file (STREAMINFO rewritten at the
    end) and on a pipe (as first written), and FFmpeg's decoding of ours
    equal to the samples the encoder takes. The FLAC fixtures FFmpeg made
    are inputs too. Sizes per compression level are recorded."""
    rows = []
    same = total = 0
    sizes = {}
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        inputs = flac_output_inputs(work)
        for fixture in ("flac_ffmpeg_level5_stereo", "flac_ffmpeg_level8_mono", "flac_ffmpeg_lpc_orders"):
            inputs[fixture] = FIXTURES / "flac" / f"{fixture}.flac"
        for name, source in inputs.items():
            problems = []
            for opts in FLAC_OUTPUT_OPTIONS:
                total += 1
                theirs, ours = work / "theirs.flac", work / "ours.flac"
                for path in (theirs, ours):
                    path.unlink(missing_ok=True)
                tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-bitexact", "-c:a", "flac", *opts, theirs)
                zp = run(args.zffmpeg, "-y", "-i", source, *opts, ours)
                label = " ".join(opts) or "defaults"
                if tp.returncode != 0 or zp.returncode != 0:
                    problems.append(f"{label}: FFmpeg {tp.returncode}, zffmpeg {zp.returncode} "
                                    f"({first_line(text(zp.stderr))})")
                    continue
                if theirs.read_bytes() != ours.read_bytes():
                    problems.append(f"{label}: the files differ")
                    continue
                # A pipe cannot seek back: STREAMINFO stays as first written.
                tpipe = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", source, "-bitexact", "-c:a", "flac", *opts,
                            "-f", "flac", "-")
                zpipe = run(args.zffmpeg, "-i", source, *opts, "-f", "flac", "-")
                if tpipe.stdout != zpipe.stdout:
                    problems.append(f"{label}: the piped output differs")
                    continue
                # FFmpeg decodes ours to the samples the encoder took: those
                # of the same conversion to pcm_s32le, shifted as the stream
                # keeps them (s16 outputs compare as s16).
                probe = run(args.ffprobe, "-v", "error", "-show_entries", "stream=sample_fmt,bits_per_raw_sample",
                            "-of", "default=nw=1:nk=1", ours)
                fields = text(probe.stdout).split()
                fmt = "s16le" if fields and fields[0] == "s16" else "s32le"
                decoded = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", ours, "-f", fmt, "-").stdout
                pairs = [opts[i:i + 2] for i in range(0, len(opts), 2) if opts[i] in ("-ar", "-ac")]
                conversion_opts = [x for pair in pairs for x in pair]
                expected = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", source, *conversion_opts, "-f", fmt, "-").stdout
                bits = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else 0
                if fmt == "s32le" and bits and bits < 32:
                    # The encoder keeps the top `bits` bits of each sample.
                    mask = struct.pack("<i", -(1 << (32 - bits)))
                    keep = int.from_bytes(mask, "little")
                    words = struct.unpack(f"<{len(expected) // 4}I", expected)
                    expected = struct.pack(f"<{len(words)}I", *(w & keep for w in words))
                if decoded != expected:
                    problems.append(f"{label}: FFmpeg's decoding differs from the encoder's input")
                    continue
                same += 1
                if len(opts) == 2 and opts[0] == "-compression_level":
                    sizes.setdefault(name, {})[int(opts[1])] = ours.stat().st_size
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            rows.append(f"| `{name}` | {len(FLAC_OUTPUT_OPTIONS)} | {result} |")
            failures.extend(f"FLAC output {name}: {p}" for p in problems)
    record("FLAC output (T26c)", same, total)
    lines += [
        "",
        "## FLAC output (T26c)",
        "",
        f"zffmpeg's FLAC equal to the ffmpeg program's (`-bitexact`) as a file and on a pipe, and decoded by FFmpeg "
        f"to the encoder's input: {same}/{total}.",
        "",
        "| Input | Option sets | Result |",
        "| --- | --- | --- |",
    ] + rows + [
        "",
        "Bytes per compression level (zffmpeg's, which equal FFmpeg's):",
        "",
        "| Input | " + " | ".join(str(level) for level in range(13)) + " |",
        "| --- |" + " --- |" * 13,
    ] + [f"| `{name}` | " + " | ".join(str(per.get(level, "-")) for level in range(13)) + " |"
         for name, per in sizes.items()]


OGG_OUTPUT_OPTIONS = [[], ["-compression_level", "0"], ["-compression_level", "8"],
                      ["-compression_level", "12", "-strict", "-2"], ["-ar", "22050"], ["-ac", "1"]]


def ogg_output_inputs(work):
    """The Ogg output comparison's own inputs (T27b): a WAV with LIST/INFO
    tags, which the Ogg muxer writes after the encoder's stream tag, and
    three seconds of mono, which fill several pages."""
    import math
    paths = {}
    for name, channels, frames, info in (("s16_stereo_tagged", 2, 9000, True), ("s16_mono_3s", 1, 132300, False)):
        data = bytearray()
        for i in range(frames):
            for c in range(channels):
                data += struct.pack("<h", int(math.sin(i * (0.01 + 0.004 * c)) * 12000))

        def chunk(tag, body):
            return tag + struct.pack("<I", len(body)) + body + (b"\0" if len(body) % 2 else b"")
        body = b"WAVE" + chunk(b"fmt ", struct.pack("<HHIIHH", 1, channels, 44100, 44100 * channels * 2, channels * 2, 16))
        if info:
            body += chunk(b"LIST", b"INFO" + chunk(b"INAM", b"Title\0") + chunk(b"IART", b"Artist\0")
                          + chunk(b"ICMT", b"A comment\0"))
        body += chunk(b"data", bytes(data))
        path = work / f"{name}.wav"
        path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
        paths[name] = path
    return paths


def compare_ogg_output(args, lines, failures):
    """zffmpeg's Ogg output (T27b): FLAC encoded into Ogg, against the
    ffmpeg program's with `-bitexact`, as `.ogg` and `.oga` files and on a
    pipe (`-f ogg`, `-f oga`): the same bytes, so FFmpeg demuxes ours to
    its own packets and timestamps; and FFmpeg's decoding of ours equal to
    its decoding of the same conversion to FLAC."""
    rows = []
    same = total = 0
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        inputs = flac_output_inputs(work)
        inputs.update(ogg_output_inputs(work))
        inputs["flac_ffmpeg_level5_stereo"] = FIXTURES / "flac" / "flac_ffmpeg_level5_stereo.flac"
        for name, source in inputs.items():
            problems = []
            for opts in OGG_OUTPUT_OPTIONS:
                label = " ".join(opts) or "defaults"
                for ext, fmt in (("ogg", "ogg"), ("oga", "oga")):
                    total += 1
                    theirs, ours = work / f"theirs.{ext}", work / f"ours.{ext}"
                    for path in (theirs, ours):
                        path.unlink(missing_ok=True)
                    tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-bitexact", *opts, theirs)
                    zp = run(args.zffmpeg, "-y", "-i", source, *opts, ours)
                    if tp.returncode != 0 or zp.returncode != 0:
                        problems.append(f"{label} .{ext}: FFmpeg {tp.returncode}, zffmpeg {zp.returncode} "
                                        f"({first_line(text(zp.stderr))})")
                        continue
                    if theirs.read_bytes() != ours.read_bytes():
                        problems.append(f"{label} .{ext}: the files differ")
                        continue
                    tpipe = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", source, "-bitexact", *opts, "-f", fmt, "-")
                    zpipe = run(args.zffmpeg, "-i", source, *opts, "-f", fmt, "-")
                    if tpipe.stdout != zpipe.stdout or zpipe.stdout != ours.read_bytes():
                        problems.append(f"{label} -f {fmt}: the piped output differs")
                        continue
                    decoded = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", ours, "-f", "s32le", "-").stdout
                    flac = work / "ours.flac"
                    flac.unlink(missing_ok=True)
                    run(args.zffmpeg, "-y", "-i", source, *opts, flac)
                    expected = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", flac, "-f", "s32le", "-").stdout
                    if not decoded or decoded != expected:
                        problems.append(f"{label} .{ext}: FFmpeg's decoding differs from the FLAC output's")
                        continue
                    same += 1
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            rows.append(f"| `{name}` | {2 * len(OGG_OUTPUT_OPTIONS)} | {result} |")
            failures.extend(f"Ogg output {name}: {p}" for p in problems)
        # -f opus asks for the Opus encoder, which neither build has.
        total += 1
        tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", inputs["s16_stereo_44k1"], "-bitexact",
                 work / "theirs.opus")
        zp = run(args.zffmpeg, "-y", "-i", inputs["s16_stereo_44k1"], work / "ours.opus")
        if tp.returncode != 0 and zp.returncode == 3 and not (work / "ours.opus").exists():
            same += 1
        else:
            failures.append(f"Ogg output: .opus: FFmpeg {tp.returncode}, zffmpeg {zp.returncode}")
    record("Ogg output (T27b)", same, total)
    lines += [
        "",
        "## Ogg output (T27b)",
        "",
        f"zffmpeg's FLAC in Ogg equal to the ffmpeg program's (`-bitexact`) as `.ogg` and `.oga` files and on "
        f"pipes, and decoded by FFmpeg as the same conversion to FLAC; `.opus`, whose default encoder neither "
        f"has, refused before any output: {same}/{total}.",
        "",
        "| Input | Outputs | Result |",
        "| --- | --- | --- |",
    ] + rows


OGG_DECODE_OUTPUTS = [(["-f", "wav"], "wav"), (["-f", "au"], "au"), (["-f", "aiff"], "aiff"),
                      (["-f", "flac"], "flac"), (["-f", "ogg"], "ogg"), (["-f", "s16le"], "raw"),
                      (["-f", "f32le"], "raw"), (["-ar", "22050", "-f", "wav"], "wav"),
                      (["-ac", "1", "-f", "wav"], "wav")]
FATE_VORBIS = ["1.0.1-test_small", "1.0-test_small", "beta3-test_small", "beta4-test_small", "chain-test1_small",
               "chain-test2_small", "highrate-test_small", "lsp-test2_small", "lsp-test3_small", "lsp-test4_small",
               "lsp-test_small", "mono_small", "moog_small", "rc1-test_small", "rc2-test2_small", "rc2-test_small",
               "rc3-test_small", "sleepzor_small", "test-short2_small", "6"]


# Ogg fixtures FFmpeg decodes and the port does not yet: zffmpeg must
# refuse them with UnsupportedOpusMode, before any output.
PENDING_OGG_DECODE = {
    "ogg_opus_frame_counts": "its hybrid frame (T28c)",
}


# Ogg decodes that differ from the ffmpeg program's for an understood
# reason: (fixture, options or None for every output) -> reason.
KNOWN_OGG_DECODE_DIFFERENCES = {
    ("ogg_chained_opus", "-f ogg"): "the same samples; the first page's granule differs: the chain's timestamps "
                                    "restart and the program's muxing fixes them up (mux_fixup_ts, T53)",
    ("ogg_opus_silk", "-f ogg"): "the same packets and samples; their timestamps differ: the program's decoded "
                                 "frames keep the Opus packets' timestamps, with gaps where the SILK resampler "
                                 "delays samples, and the Ogg muxer's granules follow them (the program's "
                                 "timestamps, T53)",
    ("ogg_page_without_granule", None): "the demuxer fails mid-stream (a granule above 2^62): the ffmpeg program "
                                        "ends the input there and exits 0, zffmpeg fails (port.md: a late parse "
                                        "error stays a failure), before any output from a file",
}


def compare_opus_vectors(args, lines, failures):
    """RFC 6716's test vectors as updated by RFC 8251 (T28, optional): each
    `.bit` decoded by av.opusdec into stereo and into mono must equal
    FFmpeg's decoding (vectors/opus_rfc.txt, printed by
    opus_rfc_vectors.c), sample for sample. opus_compare's verdict and the
    packets whose final range differs from the encoder's are reported
    beside it: FFmpeg's SILK path, resampled by libswresample, fails
    opus_compare on some vectors, and its mono SILK decoding reads other
    bits than libopus' (notes.md "Opus"). Vectors with hybrid frames wait
    for T28c and are reported as skipped."""
    folder = pathlib.Path(args.opus_vectors)
    ffmpeg = {}
    for line in (HERE.parent / "vectors" / "opus_rfc.txt").read_text().splitlines():
        _, name, channels, samples, md5 = line.split()
        ffmpeg[(name, int(channels))] = (samples, md5)
    rows = []
    passed = failed = skipped = 0
    reasons = set()
    for number in range(1, 13):
        name = f"testvector{number:02d}"
        bit = folder / f"{name}.bit"
        refs = {"stereo": [folder / f"{name}.dec"], "mono": [folder / f"{name}.dec", folder / f"{name}m.dec"]}
        for channels, label in ((2, "stereo"), (1, "mono")):
            if not bit.exists() or not all(r.exists() for r in refs[label]):
                skipped += 1
                reasons.add("test vectors missing (opus_vectors_sync.sh)")
                rows.append(f"| {name} | {label} | skipped: missing |")
                continue
            p = run(args.opus_vector_driver, bit, str(channels), *refs[label])
            out = text(p.stdout).split()
            if p.returncode == 3:
                skipped += 1
                reasons.add("hybrid frames (T28c)")
                rows.append(f"| {name} | {label} | skipped: hybrid frames (T28c) |")
                continue
            fields = dict(zip(out[0::2], out[1::2])) if p.returncode == 0 else {}
            theirs = ffmpeg.get((name, channels))
            note = (f"opus_compare {fields.get('opus_compare')} ({fields.get('quality')}), "
                    f"{fields.get('range-mismatches')} final ranges differ")
            if theirs and fields.get("md5") == theirs[1] and fields.get("samples") == theirs[0]:
                passed += 1
                rows.append(f"| {name} | {label} | pass: equal to FFmpeg's; {note} |")
            else:
                failed += 1
                why = (f"differs from FFmpeg's ({note})" if p.returncode == 0
                       else first_line(text(p.stderr)) or f"exit {p.returncode}")
                rows.append(f"| {name} | {label} | **FAIL**: {why} |")
                failures.append(f"Opus test vector {name} {label}: {why}")
    record("RFC 8251 Opus test vectors (T28)", passed, passed + failed + skipped, optional=True, skipped=skipped,
           reasons=sorted(reasons))
    lines += [
        "",
        "## RFC 8251 Opus test vectors (T28)",
        "",
        f"Test vectors decoded by av.opusdec equal to FFmpeg's decoding (optional): {passed} passed, "
        f"{failed} failed, {skipped} skipped; opus_compare and the final ranges as reported.",
        "",
        "| Vector | Output | Result |",
        "| --- | --- | --- |",
    ] + rows


def compare_ogg_decode(args, lines, failures):
    """Ogg decoded (T27d, T28a): every Ogg fixture FFmpeg decodes (Vorbis,
    Opus, FLAC in Ogg) converted by zffmpeg and by the ffmpeg program with `-bitexact`
    into each output, byte for byte; then FATE's Vorbis decode tests
    (optional), as `tests/fate/vorbis.mak` runs them (s16le), byte for
    byte against the ffmpeg program's."""
    rows = []
    same = total = pending = 0
    understood_notes = set()
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        for path in sorted((FIXTURES / "ogg").glob("*.ogg")):
            probe = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
                        "-of", "default=nw=1:nk=1", path)
            codec = text(probe.stdout).strip()
            if probe.returncode != 0 or codec not in ("vorbis", "flac", "opus") or path.stem == "ogg_multiplexed":
                continue
            if path.stem in PENDING_OGG_DECODE:
                # FFmpeg decodes it; the port stops with UnsupportedOpusMode.
                for opts, ext in OGG_DECODE_OUTPUTS:
                    total += 1
                    zp = run(args.zffmpeg, "-y", "-i", path, *opts, work / f"ours.{ext}")
                    if zp.returncode == 3 and b"UnsupportedOpusMode" in zp.stderr:
                        same += 1
                        pending += 1
                    else:
                        failures.append(f"Ogg decode {path.stem}: zffmpeg {zp.returncode}, expected UnsupportedOpusMode")
                rows.append(f"| `{path.stem}` | {codec} | pending: {PENDING_OGG_DECODE[path.stem]} |")
                continue
            problems = []
            for opts, ext in OGG_DECODE_OUTPUTS:
                total += 1
                theirs, ours = work / f"theirs.{ext}", work / f"ours.{ext}"
                for f in (theirs, ours):
                    f.unlink(missing_ok=True)
                tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", path, "-bitexact", *opts, theirs)
                zp = run(args.zffmpeg, "-y", "-i", path, *opts, ours)
                label = " ".join(opts)
                known = (KNOWN_OGG_DECODE_DIFFERENCES.get((path.stem, label))
                         or KNOWN_OGG_DECODE_DIFFERENCES.get((path.stem, None)))
                if known and (tp.returncode != 0 or zp.returncode != 0 or theirs.read_bytes() != ours.read_bytes()):
                    same += 1
                    pending += 1
                    understood_notes.add(f"`{path.stem}`: {known}")
                elif tp.returncode != 0 and zp.returncode != 0 and not ours.exists():
                    # Both refuse (a decode error rate past -max_error_rate),
                    # zffmpeg before any output.
                    same += 1
                elif tp.returncode != 0 or zp.returncode != 0:
                    problems.append(f"{label}: FFmpeg {tp.returncode}, zffmpeg {zp.returncode} "
                                    f"({first_line(text(zp.stderr))})")
                elif theirs.read_bytes() != ours.read_bytes():
                    problems.append(f"{label}: the outputs differ")
                else:
                    same += 1
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            rows.append(f"| `{path.stem}` | {codec} | {result} |")
            failures.extend(f"Ogg decode {path.stem}: {p}" for p in problems)
    record("Ogg decoding (T27d, T28a)", same, total, understood=pending)
    suite = pathlib.Path(args.fate_suite)
    fate_rows = []
    passed = failed = skipped = 0
    for name in FATE_VORBIS:
        sample = suite / "vorbis" / f"{name}.ogg"
        if not sample.exists():
            skipped += 1
            fate_rows.append(f"| {name} | skipped: `vorbis/{name}.ogg` missing |")
            continue
        theirs = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", sample, "-vn", "-f", "s16le", "-")
        ours = run(args.zffmpeg, "-i", sample, "-f", "s16le", "-")
        if ours.returncode == 0 and ours.stdout == theirs.stdout:
            passed += 1
            fate_rows.append(f"| {name} | pass |")
        else:
            failed += 1
            why = "the samples differ" if ours.returncode == 0 else first_line(text(ours.stderr))
            fate_rows.append(f"| {name} | **FAIL**: {why} |")
            failures.append(f"FATE vorbis {name}: {why}")
    record("FATE Vorbis (T27d)", passed, len(FATE_VORBIS), optional=True, skipped=skipped,
           reasons=["FATE samples missing"] if skipped else ())
    lines += [
        "",
        "## Ogg decoding (T27d, T28a)",
        "",
        f"Ogg fixtures decoded by zffmpeg into WAV, AU, AIFF, FLAC, Ogg and raw PCM (and resampled, and downmixed) "
        f"equal to the ffmpeg program's with `-bitexact`: {same}/{total}, {pending} of them as understood "
        f"differences or pending decoders:",
        "",
    ] + [f"- {note}" for note in sorted(understood_notes)] + [
        "",
        "| Fixture | Codec | Result |",
        "| --- | --- | --- |",
    ] + rows + [
        "",
        f"FATE's Vorbis decode tests (optional), zffmpeg's s16le equal to the ffmpeg program's: {passed} passed, "
        f"{failed} failed, {skipped} skipped.",
        "",
        "| Test | Result |",
        "| --- | --- |",
    ] + fate_rows


# Ogg fixtures whose copy the ffmpeg program changes past libavformat
# (T27a): ogg.txt holds what av_read_frame gives for every one.
KNOWN_OGG_COPY_DIFFERENCES = {
    "ogg_multiplexed": "two audio streams: the ffmpeg program's choice of one is not modeled",
    "ogg_chained_opus": "the chain's timestamps restart, and the program's muxing holds a non-increasing dts at the "
                        "last one (mux_fixup_ts, T53)",
}


def compare_ogg(args, lines, failures):
    """The Ogg fixtures (T27a): zffprobe against ffprobe's first audio
    stream (codec, sample format, channels, layout, rate, duration), and
    the hash driver's stream copy against `ffmpeg -c copy -f framecrc`."""
    rows = []
    passed = 0
    fixtures = sorted((FIXTURES / "ogg").glob("*.ogg"))
    for path in fixtures:
        name = path.stem
        problems = []
        theirs = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                     "stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,duration_ts", "-of",
                     "default=nw=1", path)
        ours = run(args.zffprobe, path)
        if theirs.returncode != 0 or not theirs.stdout.strip():
            if ours.returncode == 0:
                problems.append("zffprobe accepts what ffprobe refuses")
        elif ours.returncode != 0:
            problems.append(f"zffprobe refuses: {first_line(text(ours.stderr))}")
        else:
            f = dict(line.split("=", 1) for line in text(theirs.stdout).splitlines() if "=" in line)
            o = dict(line.split("=", 1) for line in text(ours.stdout).splitlines() if "=" in line)
            want = {"codec": f.get("codec_name"), "sample_fmt": f.get("sample_fmt"), "channels": f.get("channels"),
                    "channel_layout": f.get("channel_layout"), "sample_rate": f.get("sample_rate"),
                    "nb_samples": f.get("duration_ts")}
            for key, value in want.items():
                if o.get(key) != value:
                    problems.append(f"{key}: zffprobe {o.get(key)}, ffprobe {value}")
        ref = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", path, "-c", "copy", "-fflags", "+bitexact", "-f",
                  "framecrc", "-")
        mine = run(args.hasher, "framecrc", "copy", path)
        if ref.returncode == 0 and ref.stdout:
            if mine.returncode != 0 or mine.stdout != ref.stdout:
                if name in KNOWN_OGG_COPY_DIFFERENCES:
                    pass
                else:
                    problems.append("the framecrc copy differs" if mine.returncode == 0
                                    else f"the hash driver fails: {first_line(text(mine.stderr))}")
        elif mine.returncode == 0 and mine.stdout.count(b"\n0,") > 0:
            problems.append("the hash driver copies what FFmpeg refuses")
        if problems:
            failures.extend(f"ogg {name}: {p}" for p in problems)
            rows.append(f"| `{name}` | **FAIL**: {'; '.join(problems)} |")
        else:
            passed += 1
            note = KNOWN_OGG_COPY_DIFFERENCES.get(name)
            rows.append(f"| `{name}` | pass{' (copy: ' + note + ')' if note else ''} |")
    lines += [
        "",
        "## Ogg fixtures (T27a)",
        "",
        f"Ogg fixtures whose zffprobe report equals ffprobe's and whose copy equals `ffmpeg -c copy -f framecrc`: "
        f"{passed}/{len(fixtures)} (vectors/ogg.txt holds every packet av_read_frame gives).",
        "",
        "| Fixture | Result |",
        "| --- | --- |",
    ] + rows
    record("Ogg fixtures (T27a)", passed, len(fixtures), understood=sum(1 for p in fixtures if p.stem in KNOWN_OGG_COPY_DIFFERENCES))


def compare_fate(args, lines, failures):
    """Optional coverage (T26b, T19c): FATE's FLAC tests, the reference
    sample encoded by FFmpeg with the test's options and decoded by zffmpeg
    and by FFmpeg, and the FLAC samples other FATE tests read, decoded by
    both. A missing sample is skipped and reported, never failed."""
    suite = pathlib.Path(args.fate_suite)
    rows = []
    passed = failed = skipped = 0
    reasons = []
    # Provenance (T19c): each sample's SHA-256 as fate_sync.sh fetched it;
    # a present sample with other bytes fails.
    recorded = {}
    for entry in (HERE / "fate_samples.txt").read_text().splitlines():
        digest, _, sample = entry.partition("  ")
        recorded[sample] = digest
    changed = set()
    for sample, digest in recorded.items():
        path = suite / sample
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            changed.add(path)
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        cases = [(name, suite / ref, opts, codec) for name, ref, opts, codec in FATE_FLAC]
        cases += [(f"sample {sample}", suite / sample, None, None) for sample in FATE_FLAC_SAMPLES]
        for name, source, opts, codec in cases:
            if not source.exists():
                skipped += 1
                where = source.relative_to(suite) if suite in source.parents else source
                rows.append(f"| {name} | skipped: `{where}` missing |")
                reasons.append(f"{name}: `{where}` missing")
                continue
            if source in changed:
                failed += 1
                rows.append(f"| {name} | **FAIL**: the sample differs from fate_samples.txt's SHA-256 |")
                failures.append(f"{name}: the FATE sample differs from its recorded SHA-256")
                continue
            flac = work / "in.flac"
            encoded = ""
            if opts is not None:
                enc = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-c", "flac", *opts,
                          "-fflags", "+bitexact", "-flags:a", "+bitexact", flac)
                if enc.returncode != 0:
                    failed += 1
                    rows.append(f"| {name} | **FAIL**: FFmpeg could not encode: {first_line(text(enc.stderr))} |")
                    failures.append(f"{name}: FFmpeg could not encode the reference")
                    continue
                # T26c: zffmpeg's encoding with the test's options.
                ours_flac = work / "ours.flac"
                zenc = run(args.zffmpeg, "-y", "-i", source, *opts, ours_flac)
                rewrapped = ""
                if zenc.returncode != 0 and b"InvalidRiff" in zenc.stderr:
                    # The WAV contract refuses a chunk past the RIFF extent,
                    # which FFmpeg reads; its stream copy into a valid WAV
                    # gives the encoder the same packets.
                    valid = work / "valid.wav"
                    run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-c", "copy", "-bitexact", valid)
                    zenc = run(args.zffmpeg, "-y", "-i", valid, *opts, ours_flac)
                    rewrapped = "; from FFmpeg's copy into a valid WAV, as the sample's `data` runs past its " \
                                "RIFF extent, which the WAV contract refuses"
                if zenc.returncode != 0 or ours_flac.read_bytes() != flac.read_bytes():
                    failed += 1
                    why = first_line(text(zenc.stderr)) if zenc.returncode else "the encoded files differ"
                    rows.append(f"| {name} | **FAIL**: zffmpeg's encoding: {why} |")
                    failures.append(f"{name}: zffmpeg's FLAC encoding differs from FFmpeg's ({why})")
                    continue
                encoded = f"encoded identically ({flac.stat().st_size} bytes{rewrapped}), "
            else:
                flac = source
            if codec is None:
                probe = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                            "stream=bits_per_raw_sample", "-of", "default=nw=1:nk=1", flac)
                codec = "pcm_s32le" if int(text(probe.stdout).strip() or 16) > 16 else "pcm_s16le"
            fmt = codec[len("pcm_"):]
            ours = run(args.zffmpeg, "-i", flac, "-c:a", codec, "-f", fmt, "-")
            theirs = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", flac, "-map", "0:a", "-c:a", codec, "-f", fmt, "-")
            if ours.returncode == 0 and theirs.returncode == 0 and ours.stdout == theirs.stdout:
                passed += 1
                rows.append(f"| {name} | pass: {encoded}{len(ours.stdout)} bytes of {fmt} |")
            else:
                failed += 1
                why = first_line(text(ours.stderr)) if ours.returncode else "the samples differ"
                rows.append(f"| {name} | **FAIL**: {why} |")
                failures.append(f"{name}: zffmpeg's decoding differs from FFmpeg's ({why})")
    lines += [
        "",
        "## Optional FATE FLAC coverage (T26b)",
        "",
        f"Samples from `{suite}` (fetched by `fate_sync.sh`): passed {passed}, failed {failed}, "
        f"skipped {skipped} (missing samples are skipped, not failed).",
        "",
        "| Case | Result |",
        "| --- | --- |",
    ] + rows
    record("FATE FLAC (T26b, T26c)", passed, passed + failed + skipped, optional=True, skipped=skipped,
           reasons=reasons)


def compare_unknown_length(args, lines, failures):
    """The fixtures whose result changes with the parser's `unknown_length` option (T21b).

    Their default result is checked with the other fixtures. FFmpeg always reads
    unknown sizes to the end of the stream, so for the ones the option accepts it
    must decode exactly the expected samples and stream; its duration is not
    compared, since the header gives none. Its verdict on the ones the option
    still rejects is recorded, not checked."""
    lines += [
        "",
        "## Unknown-length WAV, AU and CAF (T21b, T22a, T22d)",
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
    fixtures += [("caf", f) for f in generate.build_caf_fixtures() if changes(f)]
    accepted = [f for _, f in fixtures if f.unknown_accept is not None]
    accepted_ok = 0
    for directory, fixture in fixtures:
        path = FIXTURES / directory / f"{fixture.name}.{directory}"
        au_file = directory == "au"
        forced_dir = directory if directory in ("au", "caf") else None
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
            lines.append(f"| `{fixture.name}` | {layout_text(stream)}, {rate} Hz, {frames_text(frames)} "
                         f"| {theirs} ({reason}) | {result} |")
            failures.extend(f"{fixture.name} (unknown_length): {problem}" for problem in problems)
            continue
        container = forced_dir or wav_container(fixture)
        expected = expected_stream(container, stream.codec, channels, rate, frames, stream.storage, stream.layout)
        del expected["duration_ts"]
        differences = {"au": KNOWN_AU_FIELD_DIFFERENCES, "caf": KNOWN_CAF_FIELD_DIFFERENCES}.get(
            directory, KNOWN_FIELD_DIFFERENCES)
        problems, notes = check_stream(args, fixture.name, path, expected, stream, forced_dir,
                                       field_differences=differences)
        accepted_ok += not problems
        theirs = "same samples and stream" if not problems else "differs"
        if notes:
            theirs += "; " + "; ".join(notes)
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {layout_text(stream)}, {rate} Hz, {frames_text(frames)} | {theirs} | {result} |")
        failures.extend(f"{fixture.name} (unknown_length): {problem}" for problem in problems)
    lines += ["", f"Fixtures the option accepts that FFmpeg decodes the same, or rejects as recorded: "
                  f"{accepted_ok}/{len(accepted)}."]
    record("Unknown length (T21b)", accepted_ok, len(accepted))


def ffmpeg_help_fields(binary, kind, name):
    """The `Common extensions`, `Mime type` and `Default audio codec` lines of
    `ffmpeg -h <kind>=<name>`, without their final period."""
    process = run(binary, "-hide_banner", "-h", f"{kind}={name}")
    fields = {}
    for line in text(process.stdout).splitlines():
        key, separator, value = line.strip().partition(": ")
        if separator and key in ("Common extensions", "Mime type", "Default audio codec"):
            fields[key] = value.rstrip(".")
    return fields


# Registry entries that differ from the reference build's listings for an
# understood reason: (kind, name) -> ((our flags, FFmpeg's flags), reason).
KNOWN_REGISTRY_DIFFERENCES = {
    ("format only in FFmpeg", "framecrc"): ((None, None), "written by av.framehash for the hash comparison (T19b)"),
    ("format only in FFmpeg", "framemd5"): ((None, None), "written by av.framehash for the hash comparison (T19b)"),
    ("format only in FFmpeg", "streamhash"): ((None, None), "written by av.framehash for the hash comparison (T19b)"),
    ("codec", "vorbis"): (("D.AIL.", "DEAIL."), "FFmpeg's native Vorbis encoder makes the Vorbis fixtures (T27d); "
                          "the port has no Vorbis encoder"),
    ("codec", "opus"): (("D.AIL.", "DEAIL."), "FFmpeg's native Opus encoder makes the Opus fixtures (T28a); "
                        "the port has no Opus encoder"),
}


def compare_registries(args, lines, failures):
    """The registry dump against FFmpeg's own listings (T16). The reference
    build enables exactly the codecs and formats the port implements, so the
    two sets must be equal, and every field must match."""
    ours = text(run(args.registry).stdout).splitlines()
    codecs = {}
    formats = {}
    demuxers = {}
    muxers = {}
    for line in ours:
        kind, _, rest = line.partition(" ")
        if kind == "codec":
            name, flags, long_name = rest.split(" ", 2)
            codecs[name] = (flags, long_name)
        elif kind == "format":
            name, flags, long_name = rest.split(" ", 2)
            formats[name] = (flags, long_name)
        elif kind == "demuxer":
            name, extensions = rest.split(" ")
            demuxers[name] = extensions
        elif kind == "muxer":
            name, extensions, mime, codec = rest.split(" ")
            muxers[name] = {"Common extensions": extensions, "Mime type": mime, "Default audio codec": codec}
    problems = []
    if not codecs or not formats:
        problems.append(f"the registry dump printed {len(ours)} lines")

    their_codecs = {}
    for line in text(run(args.ffmpeg, "-hide_banner", "-codecs").stdout).splitlines():
        match = re.match(r"^ ([D.][E.][VASDT.][I.][L.][S.]) (\S+)\s+(.*)$", line)
        if match:
            their_codecs[match.group(2)] = (match.group(1), match.group(3))
    # The codecs both decode and encode must be the same; a codec only a
    # demuxer names (T27a's Vorbis and Opus) is listed with its
    # descriptor's flags, checked below.
    # A codec whose flags differ for a known reason is checked below.
    known_codecs = {name for (kind, name) in KNOWN_REGISTRY_DIFFERENCES if kind == "codec"}
    enabled = {name for name, (flags, _) in their_codecs.items() if flags.startswith("DE") and name not in known_codecs}
    ours_enabled = {name for name, (flags, _) in codecs.items() if flags.startswith("DE") and name not in known_codecs}
    if enabled != ours_enabled:
        problems.append(f"codecs FFmpeg decodes and encodes {sorted(enabled)}, the registry {sorted(ours_enabled)}")
    for name, value in codecs.items():
        theirs = their_codecs.get(name)
        known = KNOWN_REGISTRY_DIFFERENCES.get(("codec", name))
        if theirs != value and not (known and (value[0], theirs[0] if theirs else None) == known[0]):
            problems.append(f"codec {name}: ours {value}, FFmpeg's {theirs}")

    their_formats = {}
    for line in text(run(args.ffmpeg, "-hide_banner", "-formats").stdout).splitlines():
        match = re.match(r"^ ([D ])([E ])[d ] (\S+)\s+(.*)$", line)
        if match:
            flags = (match.group(1) + match.group(2)).replace(" ", ".")
            their_formats[match.group(3)] = (flags, match.group(4))
    # FFmpeg's hash muxers (T19b) are av.framehash's text, not zffmpeg
    # outputs, so the format registry leaves them out.
    hash_muxers = {name for (kind, name) in KNOWN_REGISTRY_DIFFERENCES if kind == "format only in FFmpeg"}
    if set(their_formats) - hash_muxers != set(formats):
        problems.append(f"FFmpeg's formats {sorted(their_formats)}, the registry {sorted(formats)}")
    for name, value in formats.items():
        theirs = their_formats.get(name)
        known = KNOWN_REGISTRY_DIFFERENCES.get(("format", name))
        if theirs != value and not (known and (value[0], theirs[0] if theirs else None) == known[0]):
            problems.append(f"format {name}: ours {value}, FFmpeg's {theirs}")
        if value[0][0] == "D":
            # Detection's file-name hints (T22c) use the demuxers' extensions.
            theirs = ffmpeg_help_fields(args.ffmpeg, "demuxer", name).get("Common extensions", "-")
            if demuxers.get(name) != theirs:
                problems.append(f"demuxer {name}: ours extensions {demuxers.get(name)}, FFmpeg's {theirs}")
    for name, ours_fields in muxers.items():
        theirs = ffmpeg_help_fields(args.ffmpeg, "muxer", name)
        theirs = {key: theirs.get(key, "-") for key in ours_fields}
        if theirs != ours_fields:
            problems.append(f"muxer {name}: ours {ours_fields}, FFmpeg's {theirs}")

    failures.extend(f"registry: {problem}" for problem in problems)
    lines += [
        "",
        "## Registries (T16)",
        "",
        "Understood differences: " + "; ".join(f"{kind} `{name}`: {reason}"
                                                for (kind, name), (_, reason) in KNOWN_REGISTRY_DIFFERENCES.items()) + ".",
        "",
        f"Codec descriptors, decoders and encoders equal to `ffmpeg -codecs`: "
        f"{len(codecs) if not problems else 'see failures'} codecs; formats equal to `ffmpeg -formats`: "
        f"{len(formats)}; demuxers' extensions equal to `ffmpeg -h demuxer=...`: {len(demuxers)}; "
        f"muxers' extensions, MIME types and default codecs equal to `ffmpeg -h muxer=...`: "
        f"{len(muxers)}. Result: {'pass' if not problems else '**FAIL**'}.",
    ]
    entries = len(codecs) + len(formats) + len(demuxers) + len(muxers)
    record("Registries (T16)", entries - min(len(problems), entries), entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--zffprobe", required=True)
    parser.add_argument("--writer", required=True, help="the write driver (zig build test-tools)")
    parser.add_argument("--zffmpeg", required=True)
    parser.add_argument("--registry", required=True, help="the registry dump (zig build test-tools)")
    parser.add_argument("--hasher", required=True, help="the hash driver (zig build test-tools)")
    parser.add_argument("--opus-vector-driver", required=True,
                        help="the RFC test vector driver (zig build test-tools)")
    parser.add_argument("--opus-vectors", default=str(HERE.parent.parent.parent / ".references" / "opus-testvectors"),
                        help="the RFC 8251 Opus test vectors (opus_vectors_sync.sh); missing ones are skipped")
    parser.add_argument("--fate-suite", default=str(HERE.parent.parent.parent / ".references" / "fate-suite"),
                        help="FATE samples for the optional coverage (fate_sync.sh); missing ones are skipped")
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
    accepted_ok = rejected_ok = ffmpeg_accepts_rejected = missing_fixtures = 0
    for fixture in fixtures:
        path = FIXTURES / "wav" / f"{fixture.name}.wav"
        if not path.exists():
            failures.append(f"{fixture.name}: fixture file is missing")
            missing_fixtures += 1
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
    record("WAV fixtures (T02, T21)", accepted_ok + rejected_ok, len(fixtures), missing=missing_fixtures)
    lines += [
        "",
        f"Accepted fixtures matching FFmpeg and zffprobe: {accepted_ok}/{accepted}.",
        f"Rejected fixtures with the contract's zffprobe status: {rejected_ok}/{rejected}.",
        f"Rejected fixtures that FFmpeg accepts (intentional differences): {ffmpeg_accepts_rejected}/{rejected}.",
    ]
    compare_unknown_length(args, lines, failures)
    compare_registries(args, lines, failures)
    compare_detection(args, lines, failures)

    for container, title, build, field_differences, decode_differences in FORCED_CONTRACTS:
        compare_forced(args, lines, failures, container, title, build, field_differences, decode_differences)
    compare_raw(args, lines, failures)

    compare_writer(args, lines, failures)
    compare_zffmpeg(args, lines, failures)
    compare_dither(args, lines, failures)
    compare_remix(args, lines, failures)
    compare_resample(args, lines, failures)
    compare_ffmpeg_w64(args, lines, failures)
    for container, title, build, _, _ in FORCED_CONTRACTS:
        if container in MUXED_CONTRACTS:
            compare_ffmpeg_muxer(args, lines, failures, container, title, build)

    compare_pipes(args, lines, failures)
    compare_flac(args, lines, failures)
    compare_flac_output(args, lines, failures)
    compare_ogg_output(args, lines, failures)
    compare_ogg(args, lines, failures)
    compare_ogg_decode(args, lines, failures)
    compare_opus_vectors(args, lines, failures)
    compare_hashes(args, lines, failures)
    compare_fate(args, lines, failures)
    coverage_summary(lines, failures)

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
