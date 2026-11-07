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
import collections
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
# The statuses zffprobe and zffmpeg give each error (port.md "Diagnostics and
# statuses"; zig/cli/status.zig): an error not listed is an I/O failure, 4.
EXIT_STATUS = {
    "InvalidOption": 1,
    "InvalidOgg": 2,
    "InvalidVorbis": 2,
    "InvalidOpus": 2,
    "DecodeErrorRate": 2,
    "UnsupportedOperation": 3,
    "UnsupportedLayout": 3,
    "SizeOverflow": 5,
    "OutOfMemory": 5,
    "SystemResources": 5,
    "ProcessFdQuotaExceeded": 5,
    "SystemFdQuotaExceeded": 5,
    "Canceled": 6,
    "InvalidRiff": 2,
    "InvalidAu": 2,
    "InvalidAiff": 2,
    "InvalidCaf": 2,
    "InvalidFlac": 2,
    "InvalidMp3": 2,
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
    detect as its own format (T16), so its parser still reads it; nothing
    for the others."""
    return [] if generate.ffmpeg_detect(fixture.data) == container else ["-f", container]


def detection_error(fixture):
    """What zffprobe reports for a fixture probing does not give its own
    parser: `UnknownFormat` when no format wins, else the winner's refusal
    (T29a: FFmpeg's MP3 probe claims a few tiny files, whose frames its
    demuxer then does not find)."""
    detected = generate.ffmpeg_detect(fixture.data)
    return {None: "UnknownFormat", "mp3": "InvalidMp3"}[detected]


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


def tool_error(process, tool, path):
    """The error a refusal of `tool` (zffprobe, zffmpeg, hash-driver) names:
    its one stderr line `<tool>: <path>: <Name>`, with a failure status (2
    or more: not a usage error, and not a crash, whose signal Python reports
    as a negative status). None for anything else, so a crash, a usage error
    or a stray message never counts as the recorded refusal."""
    return refusal_name(process.returncode, process.stderr, tool, path)


def refusal_name(code, stderr, tool, path):
    """`tool_error` for an exit status and stderr bytes (`zffprobe_raw`'s).
    For zffprobe and zffmpeg the status must also be the one their contract
    gives the named error (`EXIT_STATUS`), so the right name with the wrong
    status is no refusal."""
    if code < 2:
        return None
    match = re.fullmatch(rf"{re.escape(tool)}: {re.escape(str(path))}: ([A-Z][A-Za-z0-9]*)\n",
                         stderr.decode(errors="replace"))
    if not match:
        return None
    if tool in ("zffprobe", "zffmpeg") and code != EXIT_STATUS.get(match.group(1), 4):
        return None
    return match.group(1)


# The ffmpeg program's last line when an input's own bytes stop it opening
# (AVERROR_INVALIDDATA, AVERROR_EOF, and the Ogg Vorbis header parser's
# AVERROR_UNKNOWN); a missing file, memory or an encoder the reference build
# lacks fail otherwise, and are never a refusal both tools share.
FFMPEG_INPUT_REFUSALS = tuple(f"Error opening input files: {reason}" for reason in (
    "Invalid data found when processing input", "End of file", "Unknown error occurred"))


def ffmpeg_refuses_input(process):
    """Whether the ffmpeg program failed because the input's bytes do not open."""
    lines = text(process.stderr).splitlines()
    return process.returncode != 0 and bool(lines) and lines[-1] in FFMPEG_INPUT_REFUSALS


def samples_end(data):
    """The offset just past an AU, AIFF or CAF stream's samples: a copy cut
    there holds nothing FFmpeg reads that the port does not (the bytes after
    an AU's declared data, a layout chunk after the samples)."""
    if data[:4] == b".snd":
        return int.from_bytes(data[4:8], "big") + int.from_bytes(data[8:12], "big")
    if data[:4] == b"FORM":
        position = 12
        while position + 8 <= len(data):
            size = int.from_bytes(data[position + 4:position + 8], "big")
            if data[position:position + 4] == b"SSND":
                return position + 8 + size
            position += 8 + size + (size & 1)
    if data[:4] == b"caff":
        position = 8
        while position + 12 <= len(data):
            size = int.from_bytes(data[position + 4:position + 12], "big")
            if data[position:position + 4] == b"data":
                return position + 12 + size
            position += 12 + size
    return None


def cut_after_samples(path, work):
    """A copy of `path` cut after its samples (`samples_end`), in `work`, or
    None when nothing follows them (then the recorded difference the cut
    explains is gone, and the caller fails)."""
    data = path.read_bytes()
    end = samples_end(data)
    if end is None or end >= len(data):
        return None
    cut = pathlib.Path(work) / f"cut-{path.name}"
    cut.write_bytes(data[:end])
    return cut


def packet_columns(hash_text, dropped):
    """A framecrc or framemd5 text with the `dropped` columns of every packet
    line removed (1 is the dts, 2 the pts); header lines kept whole."""
    lines = []
    for line in text(hash_text).splitlines():
        if line.startswith("#"):
            lines.append(line)
        else:
            lines.append([column.strip() for i, column in enumerate(line.split(",")) if i not in dropped])
    return lines


def ogg_without_granules(data):
    """An Ogg stream's pages with every granule position and CRC zeroed, so
    two streams compare equal when only their granules differ; None if the
    bytes are not whole Ogg pages."""
    out, position = bytearray(), 0
    while position < len(data):
        if data[position:position + 4] != b"OggS" or position + 27 > len(data):
            return None
        segments = data[position + 26]
        lacing = data[position + 27:position + 27 + segments]
        size = 27 + segments + sum(lacing)
        if len(lacing) != segments or position + size > len(data):
            return None
        page = bytearray(data[position:position + size])
        page[6:14] = bytes(8)
        page[22:26] = bytes(4)
        out += page
        position += size
    return bytes(out)


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
        error = detection_error(fixture)
        if undetected_code != EXIT_STATUS[error] or not undetected_err.endswith(f": {error}"):
            problems.append(f"undetected, zffprobe exited {undetected_code} ({undetected_err}), expected {error}")
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
        error = detection_error(fixture)
        problems += check_rejection(args.zffprobe, path, error)
        ours = f"{'undetected' if error == 'UnknownFormat' else 'detected as mp3'}: exit {EXIT_STATUS[error]}; " \
               f"{' '.join(input_args)}: {ours}"
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
    other cell must fail with status 3, `UnsupportedOperation` naming the
    input, before creating any output. FFmpeg's
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
    read_ok = read_total = rejected_ok = rejected_total = same_ok = same_total = understood = 0
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
                    # Exactly this refusal, naming the input: a crash or
                    # another error does not count.
                    if code == 3 and refusal_name(code, err, "zffmpeg", path) == "UnsupportedOperation" \
                            and not out.exists():
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
                        if pipe_code != 3 or pipe_out or \
                                refusal_name(pipe_code, pipe_err, "zffmpeg", "-") != "UnsupportedStreamingSize":
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
                    # The output's storage is its codec's (an empty input's
                    # transcode into another storage is read as one).
                    expected = expected_stream(output, codec, channels, rate, frames, generate.CAF_STORAGE[codec],
                                               out_layout)
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
                    # An empty input converts no samples, so its output is
                    # checked as a lossless one is, below.
                    if lossy and frames > 0:
                        if fixture.name in KNOWN_AU_DECODE_DIFFERENCES:
                            # FFmpeg decodes the bytes after the declared
                            # data: its conversion of the input cut there.
                            source = cut_after_samples(path, work)
                            if source is None:
                                problems.append("listed in KNOWN_AU_DECODE_DIFFERENCES, but nothing follows the data")
                            else:
                                problems += check_converted(args, source, input_args, out, output, output_args,
                                                            codec, work)
                            if not problems:
                                understood += 1
                                notes.append("converted: the samples of FFmpeg's own conversion of the input cut "
                                             f"after its declared data ({KNOWN_AU_DECODE_DIFFERENCES[fixture.name]})")
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
    record("zffmpeg outputs (T13b, T23a)", read_ok + rejected_ok + same_ok, read_total + rejected_total + same_total,
           understood=understood)


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
# sections record: their remixed outputs differ by that alone, so each
# differing output must equal FFmpeg's remix of the input cut after its
# samples (`cut_after_samples`); a listed input whose outputs all equal
# FFmpeg's fails as stale.
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

# libswresample's refusal when it has no matrix between two layouts
# (swr_init's auto_matrix failing, libswresample/rematrix.c).
REMIX_REFUSAL = re.compile(r"Rematrix is needed between .* but there is not enough information to do it")


def compare_remix(args, lines, failures):
    """zffmpeg's output -ac and -ch_layout against FFmpeg's (T23c): every
    accepted fixture of every input container, rematrixed into each layout
    of REMIX_OPTIONS and written as raw PCM by both (s16le, or f32le for the
    float encoder), so the samples alone are compared, must give the same
    bytes; where FFmpeg's libswresample cannot mix the layouts (its "Rematrix
    is needed" refusal), zffmpeg must refuse too, with `UnsupportedLayout`
    and no output. The input differences recorded
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
            differed = False
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
                    # Both refuse the mix itself: libswresample has no matrix
                    # for the layouts, and zffmpeg names it UnsupportedLayout.
                    # Any other failure of either side is a problem.
                    if REMIX_REFUSAL.search(text(process.stderr)) and code == 3 and \
                            refusal_name(code, err, "zffmpeg", path) == "UnsupportedLayout" and not ours.exists():
                        refused += 1
                    else:
                        problems.append(f"{label}: FFmpeg refuses ({first_line(text(process.stderr))}), "
                                        f"zffmpeg exited {code} ({first_line(text(err)) or 'no error'}), "
                                        f"where both must refuse the mix (UnsupportedLayout)")
                elif code != 0:
                    problems.append(f"{label}: zffmpeg exited {code} ({first_line(text(err))})")
                elif theirs.read_bytes() != ours.read_bytes():
                    if fixture.name in KNOWN_REMIX_DIFFERENCES:
                        # The recorded input difference alone: FFmpeg's remix
                        # of the input cut after its samples is ours.
                        differed = True
                        source = cut_after_samples(path, work)
                        cut = source and run(args.ffmpeg, "-v", "error", "-nostdin", "-y", *input_args, "-i", source,
                                             *options, "-bitexact", "-f", raw_format, theirs)
                        if cut and cut.returncode == 0 and theirs.read_bytes() == ours.read_bytes():
                            same += 1
                        else:
                            problems.append(f"{label}: the output differs from FFmpeg's for the input cut after its "
                                            f"samples")
                    else:
                        problems.append(f"{label}: the output differs")
                else:
                    same += 1
            if fixture.name in KNOWN_REMIX_DIFFERENCES and not differed:
                problems.append("listed in KNOWN_REMIX_DIFFERENCES, but every output now equals FFmpeg's")
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


# FLAC fixtures zffmpeg converts to WAV differently from the ffmpeg program
# (T26a): fixture -> (zffmpeg's status and error, whether zffmpeg's raw PCM
# in the decoder's storage equals the program's, reason). The WAV conversion
# must fail with exactly that status and error and leave no output while the
# program succeeds; where the raw PCM is compared, the samples must equal the
# program's, so the WAV header is all that differs; otherwise the raw
# conversion must be refused with the same error. A listed fixture that
# converts like the program fails as stale.
KNOWN_FLAC_CONVERSION_DIFFERENCES = {
    "flac_junk_between_frames": (2, "FrameCountMismatch", True,
                                 "FFmpeg's parser drops a valid frame after the junk, so the samples fall short "
                                 "of STREAMINFO's count, which zffmpeg writes in the WAV header first; FFmpeg "
                                 "rewrites its seekable output's header"),
    "flac_bps24": (2, "FrameCountMismatch", True, "no frames for STREAMINFO's 576 samples, as above"),
    "flac_no_total": (3, "UnsupportedStreamingSize", True,
                      "no sample count for the WAV header written first; FFmpeg rewrites its header"),
    "flac_headerless": (3, "UnsupportedStreamingSize", True,
                        "no STREAMINFO, so no sample count for the WAV header written first, as above"),
    "flac_headerless_mid_side": (3, "UnsupportedStreamingSize", True, "headerless, as above"),
    "flac_streaminfo_rate0": (3, "UnsupportedStreamingSize", True,
                              "no sample count in STREAMINFO without a rate, as above"),
    "flac_channel_change": (3, "UnsupportedFormat", False,
                            "a mid-stream channel change, which the output written first cannot follow; the "
                            "ffmpeg program's filters convert it"),
    "flac_rate_change": (3, "UnsupportedFormat", False, "a mid-stream rate change, as above"),
}


def check_flac_conversion_difference(args, path, fixture, known, zr, fr, out_ours):
    """A recorded FLAC-to-WAV difference (KNOWN_FLAC_CONVERSION_DIFFERENCES),
    asserted; returns the problems."""
    code, error, raw_equal, _ = known
    problems = []
    if fr.returncode != 0:
        problems.append(f"the ffmpeg program fails: {first_line(text(fr.stderr))}")
    if zr.returncode != code or tool_error(zr, "zffmpeg", path) != error or out_ours.exists():
        problems.append(f"zffmpeg exited {zr.returncode} ({first_line(text(zr.stderr)) or 'no error'}), output "
                        f"{'left' if out_ours.exists() else 'absent'}; recorded: status {code} with {error}, no output")
    raw_format = "s32le" if fixture.bps > 16 else "s16le"
    ours = run(args.zffmpeg, "-i", path, "-f", raw_format, "-")
    theirs = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", path, "-f", raw_format, "-")
    if raw_equal and (ours.returncode != 0 or theirs.returncode != 0 or ours.stdout != theirs.stdout):
        problems.append(f"the {raw_format} samples differ from the ffmpeg program's (zffmpeg exit {ours.returncode}, "
                        f"{len(ours.stdout)} and {len(theirs.stdout)} bytes)")
    if not raw_equal and (ours.returncode != code or tool_error(ours, "zffmpeg", path) != error):
        problems.append(f"zffmpeg's {raw_format} exited {ours.returncode} "
                        f"({first_line(text(ours.stderr)) or 'no error'}); recorded: status {code} with {error}")
    return problems


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
    matched = total = understood = 0
    converted = set()
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
        # ffmpeg_detect models av_probe_input_buffer2's rounds itself, as the
        # manifest's `detected` field does; it takes the whole file.
        if theirs_detected != generate.ffmpeg_detect(data):
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
                converted.add(fixture.name)
                if same and known:
                    conversion = "identical"
                    problems.append("listed in KNOWN_FLAC_CONVERSION_DIFFERENCES, but the WAV files are now identical")
                elif same:
                    conversion = "identical"
                elif known:
                    known_problems = check_flac_conversion_difference(args, path, fixture, known, zr, fr, out_ours)
                    problems += known_problems
                    understood += not known_problems
                    conversion = f"known: `{known[1]}` (exit {known[0]}): {known[3]}" + (
                        "; the raw PCM equals the program's" if known[2] else "")
                else:
                    conversion = "differs"
                    problems.append(f"zffmpeg exit {zr.returncode} ({first_line(text(zr.stderr))}), ffmpeg exit "
                                    f"{fr.returncode}; the WAV files differ")
        matched += not problems
        result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
        lines.append(f"| `{fixture.name}` | {ours} | {theirs} | {conversion} | {result} |")
        failures.extend(f"{fixture.name}: {problem}" for problem in problems)
    for name in KNOWN_FLAC_CONVERSION_DIFFERENCES.keys() - converted:
        total += 1
        failures.append(f"{name}: listed in KNOWN_FLAC_CONVERSION_DIFFERENCES, but no accepted FLAC fixture has the name")
    lines += ["", f"FLAC fixtures matching the contract and FFmpeg: {matched}/{total}."]
    record("FLAC fixtures (T26a, T26b)", matched, total, understood=understood)


# How a recorded hash difference is asserted (`check_known_hash`); each
# accepts exactly the recorded difference and fails on anything else:
#   "timestamps": both succeed, and the framecrc or framemd5 texts differ
#       only in the packets' dts and pts columns (never for streamhash);
#   "cut": the hash driver's text equals the program's for the input cut
#       after its samples (`cut_after_samples`): what the port does not read
#       is all that differs;
#   ("header", prefix): it equals the program's without its header lines
#       starting with `prefix`, of which there is at least one;
#   "audio map": it equals the program's with `-map 0:a:0`, its audio stream
#       alone;
#   "decoder frames": its framecrc packets are libavcodec's decoded frames
#       (samples, pts and Adler-32) as vectors/flac.txt records them, and
#       its framemd5 and streamhash texts hash the same packets;
#   ("refused", name): the hash driver refuses with `name` (status 2) and
#       the program succeeds.
#
# Fixtures whose hash text differs from the ffmpeg program's, by (fixture,
# mode): (check, reason). A listed (fixture, mode) whose texts all equal the
# program's fails as stale.
KNOWN_HASH_DIFFERENCES = {
    ("flac_rate_streaminfo", "copy"): ("timestamps", "its one packet has no timestamp, which the ffmpeg program "
                                                     "makes 0"),
    ("flac_rate_streaminfo", "decode"): ("timestamps", "its one frame has no timestamp, which the ffmpeg program "
                                                       "makes 0"),
    ("au_trailing_bytes_after_data", "copy"): ("cut", "FFmpeg reads the bytes after the declared data"),
    ("au_trailing_bytes_after_data", "decode"): ("cut", "FFmpeg decodes the bytes after the declared data"),
    ("aiff_chan_after_ssnd", "copy"): ("cut", "CHAN after SSND is not read"),
    ("aiff_chan_after_ssnd", "decode"): ("cut", "CHAN after SSND is not read"),
    ("caf_chan_after_data", "copy"): ("cut", "`chan` after `data` is not read"),
    ("caf_chan_after_data", "decode"): ("cut", "`chan` after `data` is not read"),
    ("caf_chunks_around_data", "copy"): (("header", "#extradata"), "FFmpeg keeps a `kuki` chunk as the stream's "
                                                                   "extradata"),
    ("flac_picture", "copy"): ("audio map", "FFmpeg makes the PICTURE block a second, attached-picture stream; the "
                                            "port keeps it as data"),
    ("flac_picture", "decode"): ("audio map", "the attached-picture stream, as above, which the ffmpeg program "
                                              "cannot encode in this build"),
    ("flac_channel_change", "decode"): ("decoder frames", "the ffmpeg program's filters convert a mid-stream "
                                                          "change; the driver hashes the decoder's frames"),
    ("flac_rate_change", "decode"): ("decoder frames", "a mid-stream rate change, as above"),
    # The driver copies through the codec's raw format, and FFmpeg has none
    # for s64; the decoded stream is still compared.
    ("s64_mono_8k_extensible", "copy"): (("refused", "NoRawFormat"), "the hash driver has no raw format to copy s64 "
                                                                     "into"),
    ("caf_s64be_mono", "copy"): (("refused", "NoRawFormat"), "the hash driver has no raw format to copy s64 into"),
    ("caf_s64le_mono", "copy"): (("refused", "NoRawFormat"), "the hash driver has no raw format to copy s64 into"),
}

# Decoded FLAC frames as libavcodec gives them, from flac_vectors.c's `D`
# lines: fixture -> [(samples, pts, Adler-32)], the pts as framecrc prints
# AV_NOPTS_VALUE.
AV_NOPTS_VALUE = -(1 << 63)


def flac_decoded_frames():
    frames, name = {}, None
    for line in (HERE.parent / "vectors" / "flac.txt").read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == "F":
            name = fields[1]
            frames[name] = []
        elif fields and fields[0] == "D":
            pts = AV_NOPTS_VALUE if fields[2] == "N" else int(fields[2])
            frames[name].append((int(fields[1]), pts, int(fields[3], 16)))
    return frames


def check_known_hash(check, args, path, kind, mode, ours, theirs, rerun, work):
    """Asserts one recorded hash difference (KNOWN_HASH_DIFFERENCES, and the
    Ogg and MP3 copy tables) for a case whose texts differ. `rerun(input,
    options)` runs the program's command for this case again, on another
    input or with output options. Returns the problem, or None."""
    if isinstance(check, tuple) and check[0] == "refused":
        if tool_error(ours, "hash-driver", path) != check[1] or theirs.returncode != 0:
            return (f"the hash driver exited {ours.returncode} ({first_line(text(ours.stderr)) or 'no error'}) and "
                    f"ffmpeg {theirs.returncode}, where the hash driver must refuse with {check[1]}")
        return None
    if ours.returncode != 0:
        return f"the hash driver fails: {first_line(text(ours.stderr)) or f'exit {ours.returncode}'}"
    if check == "audio map":
        reference = rerun(path, ["-map", "0:a:0"])
        return None if reference.returncode == 0 and reference.stdout == ours.stdout else \
            "differs from the program's audio stream alone (`-map 0:a:0`)"
    if theirs.returncode != 0:
        return f"ffmpeg fails: {first_line(text(theirs.stderr))}"
    if check == "timestamps":
        if kind != "streamhash" and packet_columns(ours.stdout, {1, 2}) == packet_columns(theirs.stdout, {1, 2}):
            return None
        return "differs from the program's in more than the packets' timestamps"
    if check == "cut":
        source = cut_after_samples(path, work)
        if source is None:
            return "differs, but nothing follows the input's samples"
        reference = rerun(source, [])
        return None if reference.returncode == 0 and reference.stdout == ours.stdout else \
            "differs from the program's on the input cut after its samples"
    if isinstance(check, tuple) and check[0] == "header":
        kept = [line for line in theirs.stdout.splitlines(keepends=True) if not line.startswith(check[1].encode())]
        if len(kept) < len(theirs.stdout.splitlines()) and b"".join(kept) == ours.stdout:
            return None
        return f"differs from the program's in more than its `{check[1]}` lines"
    if check == "decoder frames":
        expected = flac_decoded_frames().get(path.stem, [])
        framecrc = ours if kind == "framecrc" else run(args.hasher, "framecrc", mode, str(path))
        packets = [line for line in packet_columns(framecrc.stdout, set()) if not isinstance(line, str)]
        got = [(int(p[3]), int(p[2]), int(p[5], 16)) for p in packets if int(p[1]) == int(p[2])]
        if framecrc.returncode != 0 or len(got) != len(packets) or got != expected:
            return "the framecrc packets are not libavcodec's decoded frames (vectors/flac.txt)"
        mine = [line for line in packet_columns(ours.stdout, set()) if not isinstance(line, str)]
        if kind == "framemd5" and [p[:5] for p in mine] != [p[:5] for p in packets]:
            return "the framemd5 packets are not the framecrc ones"
        if kind == "streamhash" and [p[1] for p in mine] != [str(sum(int(p[4]) for p in packets))]:
            return "the streamhash size is not the framecrc packets' total"
        return None
    raise ValueError(f"unknown check {check!r}")


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
    differing = set()
    with tempfile.TemporaryDirectory() as work:
        for path, kinds in cases:
            for kind in kinds:
                for mode in ("copy", "decode"):
                    decoder_codec = "pcm_s32le" if path.stem in s32_inputs else "pcm_s16le"
                    codec = ["-c", "copy"] if mode == "copy" else ["-c:a", decoder_codec]

                    def rerun(source, options, codec=codec, kind=kind):
                        return run(args.ffmpeg, "-nostdin", "-v", "error", "-i", str(source), *options, "-fflags",
                                   "+bitexact", *codec, "-f", kind, "-")

                    theirs = rerun(path, [])
                    ours = run(args.hasher, kind, mode, str(path))
                    total += 1
                    if ours.returncode == 0 and theirs.returncode == 0 and ours.stdout == theirs.stdout:
                        same += 1
                        continue
                    if ours.returncode != 0 and theirs.returncode != 0:
                        # Both refusing the input agrees too (an input only a
                        # forced format opens), when the refusals are the
                        # input's: the program cannot open it, and the hash
                        # driver names zffprobe's error.
                        refusal = tool_error(ours, "hash-driver", path)
                        if ffmpeg_refuses_input(theirs) and refusal is not None and \
                                refusal == tool_error(run(args.zffprobe, path), "zffprobe", path):
                            same += 1
                            continue
                    differing.add((path.stem, mode))
                    entry = KNOWN_HASH_DIFFERENCES.get((path.stem, mode))
                    if entry is not None:
                        problem = check_known_hash(entry[0], args, path, kind, mode, ours, theirs, rerun, work)
                        if problem is None:
                            known += 1
                        else:
                            failures.append(f"{path.name}: {kind} {mode}: {problem} (recorded: {entry[1]})")
                        continue
                    if ours.returncode != 0:
                        failures.append(f"{path.name}: the hash driver failed ({kind}, {mode}): "
                                        f"{first_line(text(ours.stderr)) or f'exit {ours.returncode}'}")
                    elif theirs.returncode != 0:
                        failures.append(f"{path.name}: ffmpeg failed ({kind}, {mode}): {first_line(text(theirs.stderr))}")
                    else:
                        failures.append(f"{path.name}: the {kind} text differs from ffmpeg's ({mode})")
    for name, mode in KNOWN_HASH_DIFFERENCES:
        if (name, mode) not in differing:
            total += 1
            failures.append(f"{name}: listed in KNOWN_HASH_DIFFERENCES ({mode}), but every hash text now equals the "
                            f"program's")
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
    for (name, mode), (check, reason) in KNOWN_HASH_DIFFERENCES.items():
        how = check if isinstance(check, str) else " ".join(map(str, check))
        lines.append(f"| `{name}` | {mode} | {reason} (checked: {how}) |")


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


def flac_pipe_problem(tpipe, zpipe):
    """Why two piped FLAC outputs do not match, or None. Both commands must
    succeed with a FLAC stream: two failures with empty output would
    otherwise compare equal."""
    if tpipe.returncode != 0 or zpipe.returncode != 0:
        return (f"piped: FFmpeg {tpipe.returncode}, zffmpeg {zpipe.returncode} "
                f"({first_line(text(zpipe.stderr))})")
    if not zpipe.stdout.startswith(b"fLaC") or not tpipe.stdout.startswith(b"fLaC"):
        return "piped: no FLAC stream on standard output"
    if tpipe.stdout != zpipe.stdout:
        return "the piped output differs"
    return None


MP2_OUTPUT_OPTIONS = [[], ["-b:a", "64k"], ["-b:a", "128k"], ["-b:a", "256k"], ["-c:a", "mp2fixed"],
                      ["-c:a", "mp2fixed", "-b:a", "192k"], ["-ar", "22050", "-b:a", "64k"], ["-ar", "16000"],
                      ["-ac", "1", "-b:a", "96k"], ["-ar", "32000", "-ac", "2", "-b:a", "80k"], ["-b:a", "100k"]]
MP2_RATES = (44100, 48000, 32000, 22050, 24000, 16000)
# ff_mpa_bitrate_tab's Layer II rates in kbit/s, MPEG-1 and MPEG-2 (LSF).
MP2_KBPS = {False: (32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
            True: (8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)}


def mp2_expected_refusal(rate, channels, opts):
    """The refusal zffmpeg makes where the ffmpeg program converts or fails,
    as (program fails, status, error), or None: a bit rate the encoder has
    no index for fails both ("bitrate %d is not allowed in mp2"); an output
    rate or channel count the encoder does not take is refused by zffmpeg
    (UnsupportedFormat) where the program's filters pick one it takes
    (notes.md "MP2 output scope")."""
    pairs = dict(zip(opts[0::2], opts[1::2]))
    out_rate = int(pairs.get("-ar", rate))
    out_channels = int(pairs.get("-ac", channels))
    # The program's filters pick the encoder's nearest rate (8 kHz to 16,
    # 96 kHz to 48), whose version decides the valid bit rates.
    program_rate = min(MP2_RATES, key=lambda r: abs(r - out_rate))
    kbps = int(pairs["-b:a"].rstrip("k")) if "-b:a" in pairs else None
    bad_bit_rate = kbps is not None and kbps not in MP2_KBPS[program_rate < 32000]
    # zffmpeg checks the format before the bit rate, as the encoder's init
    # does; the program, having converted the format, still fails on it.
    if out_rate not in MP2_RATES or out_channels > 2:
        return (bad_bit_rate, 3, "UnsupportedFormat")
    if bad_bit_rate:
        return (True, 1, "InvalidOption")
    return None


def compare_mp2_output(args, lines, failures):
    """zffmpeg's MP2 output (T29d) against the ffmpeg program's with
    `-bitexact`: the same bytes as a file and on a pipe, decoded back by
    FFmpeg and by zffmpeg to the same samples, for every input of
    the FLAC output section and decoded MP3, MP2 and Ogg inputs, at each
    bit rate and quantizer, resampled and downmixed; refusals as
    `mp2_expected_refusal` records them, each with its status and error and
    no output."""
    rows = []
    same = total = understood = 0
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        inputs = {name: (path, None) for name, path in flac_output_inputs(work).items()}
        for fixture in ("mp3/mp3_l3_long_stereo.mp3", "mp3/mp2_layer2_48k.mp3", "ogg/ogg_vorbis_ffmpeg_44k.ogg"):
            inputs[pathlib.Path(fixture).stem] = (FIXTURES / fixture, None)
        for name, (source, _) in inputs.items():
            probe = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=sample_rate,channels", "-of", "default=nw=1:nk=1", source)
            rate, channels = (int(x) for x in text(probe.stdout).split()[:2])
            problems = []
            for opts in MP2_OUTPUT_OPTIONS:
                total += 1
                theirs, ours = work / "theirs.mp2", work / "ours.mp2"
                for path in (theirs, ours):
                    path.unlink(missing_ok=True)
                codec = [] if "-c:a" in opts else ["-c:a", "mp2"]
                tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-bitexact", *codec, *opts, theirs)
                zp = run(args.zffmpeg, "-y", "-i", source, *opts, ours)
                label = " ".join(opts) or "defaults"
                refusal = mp2_expected_refusal(rate, channels, opts)
                if refusal is not None:
                    fails, code, error = refusal
                    program_ok = (tp.returncode != 0 and b"is not allowed in mp2" in tp.stderr) if fails else tp.returncode == 0
                    # A rejected encoder option is status 1 with the input
                    # named, which tool_error (status 2 and up) leaves out.
                    named = (text(zp.stderr) == f"zffmpeg: {source}: {error}" if code == 1
                             else tool_error(zp, "zffmpeg", source) == error)
                    if not program_ok or zp.returncode != code or not named or ours.exists():
                        problems.append(f"{label}: FFmpeg exited {tp.returncode}, zffmpeg {zp.returncode} "
                                        f"({first_line(text(zp.stderr)) or 'no error'}); recorded: zffmpeg refuses "
                                        f"with {error} (status {code}) and writes nothing")
                    else:
                        same += 1
                        understood += not fails
                    continue
                if tp.returncode != 0 or zp.returncode != 0:
                    problems.append(f"{label}: FFmpeg {tp.returncode}, zffmpeg {zp.returncode} "
                                    f"({first_line(text(zp.stderr))})")
                    continue
                if not ours.read_bytes() or theirs.read_bytes() != ours.read_bytes():
                    problems.append(f"{label}: the files differ")
                    continue
                # FFmpeg's mp2float and the port's decoder read the output
                # back to the same samples.
                total += 1
                tdec = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", ours, "-f", "f32le", "-")
                zdec = run(args.zffmpeg, "-i", ours, "-f", "f32le", "-")
                if tdec.returncode != 0 or tdec.stderr or zdec.returncode != 0 or not tdec.stdout \
                        or tdec.stdout != zdec.stdout:
                    problems.append(f"{label}: decoded, FFmpeg {tdec.returncode}, zffmpeg {zdec.returncode}, "
                                    f"{len(tdec.stdout)} and {len(zdec.stdout)} bytes")
                    continue
                same += 1
                total += 1
                tpipe = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", source, "-bitexact", *codec, *opts,
                            "-f", "mp2", "-")
                zpipe = run(args.zffmpeg, "-i", source, *opts, "-f", "mp2", "-")
                if tpipe.returncode != 0 or zpipe.returncode != 0 or not zpipe.stdout or tpipe.stdout != zpipe.stdout:
                    problems.append(f"{label}: piped, FFmpeg {tpipe.returncode}, zffmpeg {zpipe.returncode}, "
                                    f"{len(tpipe.stdout)} and {len(zpipe.stdout)} bytes")
                    continue
                same += 2
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            rows.append(f"| `{name}` | {rate} Hz, {channels} ch | {result} |")
            failures.extend(f"MP2 output {name}: {p}" for p in problems)
    record("MP2 output (T29d)", same, total, understood=understood)
    lines += [
        "",
        "## MP2 output (T29d)",
        "",
        f"zffmpeg's MP2 (mp2 and mp2fixed) equal to the ffmpeg program's with `-bitexact`, as a file and on a "
        f"pipe, and decoded back by FFmpeg and zffmpeg to the same samples, or refused as recorded: {same}/{total}, {understood} of them refusals where the program converts "
        f"the rate or the channels.",
        "",
        "| Input | Format | Result |",
        "| --- | --- | --- |",
    ] + rows


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
                pipe_problem = flac_pipe_problem(tpipe, zpipe)
                if pipe_problem:
                    problems.append(f"{label}: {pipe_problem}")
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
        # Decoded inputs with a rate change: each decoded frame is one
        # aresample call, so the block size follows the decoder's frames.
        for fixture, rate in (("flac/flac_variable_blocksize.flac", "48000"), ("ogg/ogg_opus_ffmpeg_stereo.ogg", "44100"),
                              ("ogg/ogg_opus_ffmpeg_mono.ogg", "22050"), ("ogg/ogg_vorbis_ffmpeg_44k.ogg", "48000")):
            total += 1
            source, theirs, ours = FIXTURES / fixture, work / "theirs.flac", work / "ours.flac"
            for path in (theirs, ours):
                path.unlink(missing_ok=True)
            tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", source, "-bitexact", "-c:a", "flac", "-ar", rate, theirs)
            zp = run(args.zffmpeg, "-y", "-i", source, "-ar", rate, ours)
            tpipe = run(args.ffmpeg, "-nostdin", "-v", "error", "-i", source, "-bitexact", "-c:a", "flac", "-ar", rate,
                        "-f", "flac", "-")
            zpipe = run(args.zffmpeg, "-i", source, "-ar", rate, "-f", "flac", "-")
            name = pathlib.Path(fixture).stem
            if tp.returncode != 0 or zp.returncode != 0:
                problem = f"FFmpeg {tp.returncode}, zffmpeg {zp.returncode} ({first_line(text(zp.stderr))})"
            elif theirs.read_bytes() != ours.read_bytes():
                problem = "the files differ"
            elif flac_pipe_problem(tpipe, zpipe):
                problem = flac_pipe_problem(tpipe, zpipe)
            else:
                problem = None
                same += 1
            rows.append(f"| `{name}` (decoded) | -ar {rate} | {'pass' if problem is None else '**FAIL**: ' + problem} |")
            if problem is not None:
                failures.append(f"FLAC output {name} -ar {rate}: {problem}")
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
        # .opus asks for the Opus encoder: the port has none, and the
        # reference build's native one is experimental, which the program
        # refuses without -strict experimental. Each refusal must be that one.
        total += 1
        tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", inputs["s16_stereo_44k1"], "-bitexact",
                 work / "theirs.opus")
        zp = run(args.zffmpeg, "-y", "-i", inputs["s16_stereo_44k1"], work / "ours.opus")
        experimental = "The encoder 'opus' is experimental but experimental codecs are not enabled"
        if tp.returncode != 0 and experimental in text(tp.stderr) and zp.returncode == 3 and \
                tool_error(zp, "zffmpeg", inputs["s16_stereo_44k1"]) == "UnsupportedOperation" and \
                not (work / "ours.opus").exists():
            same += 1
        else:
            failures.append(f"Ogg output: .opus: FFmpeg {tp.returncode} ({first_line(text(tp.stderr))}), zffmpeg "
                            f"{zp.returncode} ({first_line(text(zp.stderr)) or 'no error'}), where FFmpeg must refuse "
                            f"its experimental encoder and zffmpeg with UnsupportedOperation")
    record("Ogg output (T27b)", same, total)
    lines += [
        "",
        "## Ogg output (T27b)",
        "",
        f"zffmpeg's FLAC in Ogg equal to the ffmpeg program's (`-bitexact`) as `.ogg` and `.oga` files and on "
        f"pipes, and decoded by FFmpeg as the same conversion to FLAC; `.opus`, refused by "
        f"zffmpeg (no Opus encoder, UnsupportedOperation) before any output and by FFmpeg (its encoder is "
        f"experimental): {same}/{total}.",
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


# Ogg decodes that differ from the ffmpeg program's for an understood
# reason: (fixture, options or None for every output) -> (check, reason).
# "granules": both succeed, the two Ogg files are the same pages but for
# their granule positions (and so their CRCs), and FFmpeg decodes both to
# the same samples. ("refused", status, name): zffmpeg fails with that status
# and error before creating the output file, and the program succeeds. A
# listed cell whose outputs are equal fails as stale.
KNOWN_OGG_DECODE_DIFFERENCES = {
    ("ogg_chained_opus", "-f ogg"): ("granules", "the same samples; the first page's granule differs: the chain's "
                                                 "timestamps restart and the program's muxing fixes them up "
                                                 "(mux_fixup_ts, T53)"),
    ("ogg_opus_silk", "-f ogg"): ("granules", "the same packets and samples; their timestamps differ: the program's "
                                              "decoded frames keep the Opus packets' timestamps, with gaps where the "
                                              "SILK resampler delays samples, and the Ogg muxer's granules follow "
                                              "them (the program's timestamps, T53)"),
    ("ogg_opus_frame_counts", "-f ogg"): ("granules", "the same samples; the last granule differs: the program's "
                                                      "decoded frames keep the packets' timestamps, so the packets "
                                                      "the decoder refuses leave gaps the Ogg muxer's granules "
                                                      "follow (the program's timestamps, T53)"),
    ("ogg_opus_multistream", "-f ogg"): ("granules", "the same samples; their timestamps differ: the program's "
                                                     "decoded frames keep the packets' timestamps, with gaps where "
                                                     "the streams' sync buffers shorten a frame, and the Ogg muxer's "
                                                     "granules follow them (T53)"),
    ("ogg_opus_mapped", "-f ogg"): ("granules", "the same samples; the last granule differs, as for "
                                                "ogg_opus_multistream (T53)"),
    ("ogg_page_without_granule", None): (("refused", 2, "InvalidOgg"),
                                         "the demuxer fails mid-stream (a granule above 2^62): the ffmpeg program "
                                         "ends the input there and exits 0, zffmpeg fails (port.md: a late parse "
                                         "error stays a failure), before any output from a file"),
}


def ogg_packets(args, path):
    """An Ogg file's packets without their timestamps, as ffprobe reads
    them: size, duration and data hash, one line each; None when ffprobe
    fails or finds none."""
    p = run(args.ffprobe, "-v", "error", "-show_data_hash", "md5", "-show_entries", "packet=size,duration,data_hash",
            "-of", "csv=p=0", path)
    return text(p.stdout) if p.returncode == 0 and p.stdout else None


def check_ogg_decode_difference(args, check, path, tp, zp, theirs, ours):
    """Asserts one recorded decode difference into Ogg or another output;
    returns the problem, or None. "granules": both succeed and the Ogg pages
    differ only in their granule positions; "timestamps": both succeed with
    the same packets (sizes, durations, data) in other pages, timestamps
    aside; both with the same samples decoded. ("refused", status, name):
    the program succeeds, zffmpeg refuses before any output. ("other
    refusal", the program's last line, status, name): both refuse, each for
    the reason recorded, zffmpeg before any output."""
    if check in ("granules", "timestamps"):
        if tp.returncode != 0 or zp.returncode != 0:
            return f"FFmpeg exited {tp.returncode}, zffmpeg {zp.returncode} ({first_line(text(zp.stderr))})"
        if check == "granules":
            pages = ogg_without_granules(ours.read_bytes())
            if pages is None or pages != ogg_without_granules(theirs.read_bytes()):
                return "the Ogg pages differ in more than their granules"
        else:
            packets = ogg_packets(args, ours)
            if packets is None or packets != ogg_packets(args, theirs):
                return "the Ogg packets differ in more than their timestamps"
        decoded = [run(args.ffmpeg, "-nostdin", "-v", "error", "-i", f, "-c:a", "pcm_s32le", "-f", "s32le", "-")
                   for f in (theirs, ours)]
        if any(d.returncode != 0 for d in decoded) or decoded[0].stdout != decoded[1].stdout:
            return "FFmpeg decodes the two Ogg files to different samples"
        return None
    if check[0] == "other refusal":
        _, reason, code, error = check
        last = text(tp.stderr).splitlines()[-1:]
        if (tp.returncode == 0 or last != [reason] or zp.returncode != code
                or tool_error(zp, "zffmpeg", path) != error or ours.exists()):
            return (f"FFmpeg exited {tp.returncode} ({last}), zffmpeg {zp.returncode} "
                    f"({first_line(text(zp.stderr)) or 'no error'}), output {'created' if ours.exists() else 'absent'}; "
                    f"recorded: FFmpeg fails with {reason!r}, zffmpeg refuses with {error} (status {code})")
        return None
    _, code, error = check
    if tp.returncode != 0 or zp.returncode != code or tool_error(zp, "zffmpeg", path) != error or ours.exists():
        return (f"FFmpeg exited {tp.returncode}, zffmpeg {zp.returncode} "
                f"({first_line(text(zp.stderr)) or 'no error'}), output {'created' if ours.exists() else 'absent'}; "
                f"recorded: zffmpeg refuses with {error} (status {code}) and writes nothing")
    return None


def compare_opus_vectors(args, lines, failures):
    """RFC 6716's test vectors as updated by RFC 8251 (T28, optional): each
    `.bit` decoded by av.opusdec into stereo and into mono must equal
    FFmpeg's decoding (vectors/opus_rfc.txt, printed by
    opus_rfc_vectors.c), sample for sample. opus_compare's verdict and the
    packets whose final range differs from the encoder's are reported
    beside it: FFmpeg's SILK path, resampled by libswresample, fails
    opus_compare on some vectors, and its mono SILK decoding reads other
    bits than libopus' (notes.md "Opus")."""
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


def same_decode_refusal(ffmpeg_process, error):
    """Whether zffmpeg's refusal `error` (`tool_error`) is the one the ffmpeg
    program's failure shows: an input that does not open, a decode error
    rate past `-max_error_rate` (`DecodeErrorRate`), or a stream without a
    decoder in the reference build, MP1 and MP2 (`UnsupportedOperation`)."""
    if error is None or ffmpeg_process.returncode == 0:
        return False
    if ffmpeg_refuses_input(ffmpeg_process):
        return True
    if b"Decoding requested, but no decoder found for: " in ffmpeg_process.stderr:
        return error == "UnsupportedOperation"
    return b"Decode error rate " in ffmpeg_process.stderr and error == "DecodeErrorRate"


def check_pipe_decode(args, path, opts, known, work=None):
    """zffmpeg decoding an Ogg or MP3 fixture from standard input to raw PCM on
    standard output against the ffmpeg program doing the same (M17): equal
    bytes, or the same refusal (from a pipe, a junk prefix leaves FFmpeg's
    probe nothing to detect, as it does zffmpeg's: no file name). With
    `work`, the output is a file there instead, whose header both rewrite at
    the end (no count ahead from a pipe). A recorded refusal must come with
    its status and error. Returns the problem, or None."""
    data = path.read_bytes()
    theirs_file = ours_file = None
    if work is not None:
        theirs_file, ours_file = work / "theirs_pipe.out", work / "ours_pipe.out"
        for f in (theirs_file, ours_file):
            f.unlink(missing_ok=True)
    theirs = subprocess.run([str(part) for part in (args.ffmpeg, "-v", "error", "-y", "-i", "pipe:", "-bitexact", *opts,
                                                    theirs_file or "-")], input=data, capture_output=True, timeout=120)
    ours = subprocess.run([str(part) for part in (args.zffmpeg, "-y", "-i", "-", *opts, ours_file or "-")], input=data,
                          capture_output=True, timeout=120)
    if work is not None:
        # Compared as the stdout of the other cells: the file's bytes.
        theirs.stdout = theirs_file.read_bytes() if theirs_file.exists() else b""
        ours.stdout = ours_file.read_bytes() if ours_file.exists() else b""
    error = tool_error(ours, "zffmpeg", "-")
    if known is not None and isinstance(known[0], tuple) and known[0][0] == "refused":
        _, code, name = known[0]
        if theirs.returncode != 0 or ours.returncode != code or error != name:
            return (f"FFmpeg exited {theirs.returncode}, zffmpeg {ours.returncode} "
                    f"({first_line(text(ours.stderr)) or 'no error'}); recorded: zffmpeg refuses with {name}")
        return None
    if theirs.returncode != 0:
        if not same_decode_refusal(theirs, error):
            return (f"FFmpeg refuses ({text(theirs.stderr).splitlines()[-1:]}), zffmpeg exited {ours.returncode} "
                    f"({first_line(text(ours.stderr)) or 'no error'})")
        if ffmpeg_refuses_input(theirs) and ours.stdout:
            return "zffmpeg writes output for an input neither opens"
        return None
    if ours.returncode != 0 or ours.stdout != theirs.stdout:
        return (f"zffmpeg exited {ours.returncode} ({first_line(text(ours.stderr)) or 'no error'}) with "
                f"{len(ours.stdout)} bytes, FFmpeg's {len(theirs.stdout)} differ")
    return None


def decode_cells(args, paths, known_table, table_name, label_prefix, failures):
    """The decoded-input cells for `paths` ((fixture, codec) pairs): each
    fixture converted by zffmpeg and by the ffmpeg program with `-bitexact`
    into every `OGG_DECODE_OUTPUTS` output, byte for byte, and each raw PCM
    output again through pipes (`check_pipe_decode`); a cell in
    `known_table` must show the difference it records. Returns the rows,
    the equal and total cells, the understood ones with their notes, and
    the (fixture, options) keys compared."""
    rows = []
    same = total = understood = 0
    understood_notes = set()
    compared = set()
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        for path, codec in paths:
            problems = []
            for opts, ext in OGG_DECODE_OUTPUTS:
                total += 1
                theirs, ours = work / f"theirs.{ext}", work / f"ours.{ext}"
                for f in (theirs, ours):
                    f.unlink(missing_ok=True)
                tp = run(args.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", path, "-bitexact", *opts, theirs)
                zp = run(args.zffmpeg, "-y", "-i", path, *opts, ours)
                label = " ".join(opts)
                known = (known_table.get((path.stem, label))
                         or known_table.get((path.stem, None)))
                equal = tp.returncode == 0 and zp.returncode == 0 and theirs.read_bytes() == ours.read_bytes()
                if known and equal:
                    problems.append(f"{label}: listed in {table_name}, but the outputs are now equal")
                elif known:
                    problem = check_ogg_decode_difference(args, known[0], path, tp, zp, theirs, ours)
                    if problem is None:
                        same += 1
                        understood += 1
                        understood_notes.add(f"`{path.stem}`: {known[1]}")
                    else:
                        problems.append(f"{label}: {problem}")
                elif tp.returncode != 0 and zp.returncode != 0:
                    # Both refuse, zffmpeg before any output and for the
                    # program's reason (a decode error rate past
                    # -max_error_rate).
                    if not same_decode_refusal(tp, tool_error(zp, "zffmpeg", path)) or ours.exists():
                        problems.append(f"{label}: FFmpeg refuses ({text(tp.stderr).splitlines()[-1:]}), zffmpeg "
                                        f"exited {zp.returncode} ({first_line(text(zp.stderr)) or 'no error'}), "
                                        f"output {'created' if ours.exists() else 'absent'}")
                    else:
                        same += 1
                elif tp.returncode != 0 or zp.returncode != 0:
                    problems.append(f"{label}: FFmpeg {tp.returncode}, zffmpeg {zp.returncode} "
                                    f"({first_line(text(zp.stderr))})")
                elif not equal:
                    problems.append(f"{label}: the outputs differ")
                else:
                    same += 1
                if ext == "raw":
                    # The same decode with the input on a pipe (non-seekable)
                    # and the output on stdout, against the program's.
                    total += 1
                    problem = check_pipe_decode(args, path, opts, known)
                    if problem is None:
                        same += 1
                    else:
                        problems.append(f"{label} through pipes: {problem}")
                if opts == ["-f", "wav"]:
                    # From a pipe into a WAV file: no count ahead, the header
                    # rewritten at the end, as the program's.
                    total += 1
                    problem = check_pipe_decode(args, path, opts, known, work)
                    if problem is None:
                        same += 1
                    else:
                        problems.append(f"{label} from a pipe into a file: {problem}")
            result = "pass" if not problems else "**FAIL**: " + "; ".join(problems)
            rows.append(f"| `{path.stem}` | {codec} | {result} |")
            failures.extend(f"{label_prefix} {path.stem}: {p}" for p in problems)
            compared.add((path.stem, None))
            compared.update((path.stem, " ".join(opts)) for opts, _ in OGG_DECODE_OUTPUTS)
    return rows, same, total, understood, understood_notes, compared


def compare_ogg_decode(args, lines, failures):
    """Ogg decoded (T27d, T28a): every Ogg fixture FFmpeg decodes (Vorbis,
    Opus, FLAC in Ogg) converted by zffmpeg and by the ffmpeg program with `-bitexact`
    into each output, byte for byte, and each raw PCM output again with the
    input on a pipe and the output on stdout, against the program doing the
    same; then FATE's Vorbis decode tests (optional), as
    `tests/fate/vorbis.mak` runs them (s16le), byte for byte against the
    ffmpeg program's."""
    paths = []
    for path in sorted((FIXTURES / "ogg").glob("*.ogg")):
        probe = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
                    "-of", "default=nw=1:nk=1", path)
        codec = text(probe.stdout).strip()
        if probe.returncode != 0 or codec not in ("vorbis", "flac", "opus") or path.stem == "ogg_multiplexed":
            continue
        paths.append((path, codec))
    rows, same, total, understood, understood_notes, compared = decode_cells(
        args, paths, KNOWN_OGG_DECODE_DIFFERENCES, "KNOWN_OGG_DECODE_DIFFERENCES", "Ogg decode", failures)
    total += unmatched_entries(KNOWN_OGG_DECODE_DIFFERENCES, compared, "KNOWN_OGG_DECODE_DIFFERENCES", failures)
    record("Ogg decoding (T27d, T28a)", same, total, understood=understood)
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
        f"Ogg fixtures decoded by zffmpeg into WAV, AU, AIFF, FLAC, Ogg and raw PCM (and resampled, and downmixed), "
        f"into raw PCM from a pipe to stdout, and from a pipe into a WAV file, equal to the ffmpeg program's with `-bitexact`: {same}/{total}, "
        f"{understood} of them as understood "
        f"differences:",
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


# MP3 decodes that differ from the ffmpeg program's for an understood reason:
# (fixture, options or None for every output) -> (check, reason), as
# KNOWN_OGG_DECODE_DIFFERENCES.
MP3_OGG_GRANULES = ("granules", "the same samples; the last granule differs: the program's decoded frames keep "
                                "the packets' timestamps, so the frames the decoder refuses leave gaps the Ogg "
                                "muxer's granules follow (the program's timestamps, T53)")
MP3_APIC = (("other refusal", "Error opening output files: Encoder not found", 2, "DecodeErrorRate"),
            "the program maps the attached picture to a video stream, which AIFF, FLAC and Ogg can carry, and the "
            "reference build has no encoder for it; zffmpeg converts the audio stream alone and fails on the decode "
            "error rate the program reaches into WAV, AU and raw PCM (notes.md \"MP3 decoding\")")
KNOWN_MP3_DECODE_DIFFERENCES = {
    ("mp3_l3_bad_big_values", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_l3_bad_block_type", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_mpeg2_l3_16k_mono", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_mpeg2_l3_22k", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_xing_mpeg2_mono", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_layer_change", "-f ogg"): MP3_OGG_GRANULES,
    ("mp3_mpeg25_l3_12k", "-f ogg"): ("timestamps", "the same packets and samples; their timestamps differ, as for "
                                                    "the granules above, and so the pages they fill (T53)"),
    ("mp3_mpeg25_l3_8k", "-f ogg"): ("timestamps", "the same packets and samples; their timestamps differ, as for "
                                                   "the granules above, and so the pages they fill (T53)"),
    ("mp3_apic_chap", "-f aiff"): MP3_APIC,
    ("mp3_apic_chap", "-f flac"): MP3_APIC,
    ("mp3_apic_chap", "-f ogg"): MP3_APIC,
}


def compare_mp3_decode(args, lines, failures):
    """MPEG audio decoded (T29b, T29c): every MP3, MP2 and MP1 fixture
    converted by zffmpeg and by the ffmpeg program with `-bitexact` into each
    output, byte for byte, each raw PCM output again through pipes and the
    WAV from a pipe into a file; damaged streams past the decode error rate
    are refused by both."""
    paths = [(path, "mp3") for path in sorted((FIXTURES / "mp3").glob("*.mp3"))]
    rows, same, total, understood, understood_notes, compared = decode_cells(
        args, paths, KNOWN_MP3_DECODE_DIFFERENCES, "KNOWN_MP3_DECODE_DIFFERENCES", "MP3 decode", failures)
    total += unmatched_entries(KNOWN_MP3_DECODE_DIFFERENCES, compared, "KNOWN_MP3_DECODE_DIFFERENCES", failures)
    record("MPEG audio decoding (T29b, T29c)", same, total, understood=understood)
    lines += [
        "",
        "## MPEG audio decoding (T29b, T29c)",
        "",
        f"MPEG audio fixtures (MP3, MP2, MP1) decoded by zffmpeg into WAV, AU, AIFF, FLAC, Ogg and raw PCM (and resampled, and "
        f"downmixed), into raw PCM from a pipe to stdout, and from a pipe into a WAV file, equal to the ffmpeg program's with `-bitexact`, "
        f"or refused by both: {same}/{total}, {understood} of them as understood differences:",
        "",
    ] + [f"- {note}" for note in sorted(understood_notes)] + [
        "",
        "| Fixture | Codec | Result |",
        "| --- | --- | --- |",
    ] + rows


# Ogg fixtures whose copy the ffmpeg program changes past libavformat
# (T27a): ogg.txt holds what av_read_frame gives for every one. Fixture ->
# (check, reason), asserted by `check_known_hash`.
KNOWN_OGG_COPY_DIFFERENCES = {
    "ogg_multiplexed": (("refused", "SeveralAudioStreams"),
                        "two audio streams: the ffmpeg program's choice of one is not modeled"),
    "ogg_chained_opus": ("timestamps", "the chain's timestamps restart, and the program's muxing holds a "
                                       "non-increasing dts at the last one (mux_fixup_ts, T53)"),
}


# MP3 stream copies that differ from the ffmpeg program's for an understood
# reason: fixture -> (check, reason), asserted by `check_known_hash`. The
# reference command takes `-copyts`, as the hash driver hashes the packets
# with libavformat's timestamps (vectors/mp3.txt): without it the program
# shifts every timestamp by the stream's start time, the gapless skip of a
# Xing, Info or iTunSMPB header (the program's timestamps, T53).
KNOWN_MP3_COPY_DIFFERENCES = {
    "mp3_apic_chap": ("audio map", "FFmpeg's attached-picture stream, which the port does not model"),
}
MP3_COPY_OPTIONS = ("-copyts",)


def unmatched_entries(table, compared, title, failures):
    """Entries of a known-difference table, keyed by fixture or by (fixture,
    cell), that name nothing the section compared: stale, each a failure.
    Returns their count, for the section's total."""
    stale = sorted(str(key) for key in table if key not in compared)
    failures.extend(f"{key}: listed in {title}, but nothing compared has that name" for key in stale)
    return len(stale)


def check_framecrc_copy(args, path, known, probe, reference_options=()):
    """The hash driver's stream copy against `ffmpeg -i <path> -c copy -f
    framecrc` (with `reference_options` before `-i`): equal text, the
    recorded difference `known` (asserted by `check_known_hash`), or the
    same refusal: the program cannot open the input, and the hash driver
    names the error zffprobe's run `probe` names. Returns the problems."""
    def rerun(source, options):
        return run(args.ffmpeg, "-nostdin", "-v", "error", *reference_options, "-i", source, *options, "-c", "copy",
                   "-fflags", "+bitexact", "-f", "framecrc", "-")

    ref = rerun(path, [])
    mine = run(args.hasher, "framecrc", "copy", path)
    if ref.returncode == 0 and ref.stdout:
        equal = mine.returncode == 0 and mine.stdout == ref.stdout
        if known is None:
            return [] if equal else ["the framecrc copy differs" if mine.returncode == 0
                                     else f"the hash driver fails: {first_line(text(mine.stderr)) or 'no error'}"]
        if equal:
            return ["listed as a known copy difference, but the framecrc copy now equals the program's"]
        with tempfile.TemporaryDirectory() as work:
            problem = check_known_hash(known[0], args, path, "framecrc", "copy", mine, ref, rerun, work)
        return [] if problem is None else [f"framecrc copy: {problem} (recorded: {known[1]})"]
    if known is not None:
        return [f"listed as a known copy difference, but ffmpeg fails: {first_line(text(ref.stderr))}"]
    if not ffmpeg_refuses_input(ref):
        return [f"ffmpeg fails, not refusing the input: {text(ref.stderr).splitlines()[-1:]}"]
    refusal = tool_error(mine, "hash-driver", path)
    if refusal is None or refusal != tool_error(probe, "zffprobe", path):
        return [f"FFmpeg refuses the input; the hash driver exited {mine.returncode} "
                f"({first_line(text(mine.stderr)) or 'no error'}), not with zffprobe's error"]
    return []


def compare_mp3(args, lines, failures):
    """The MP3 fixtures (T29a): zffprobe against ffprobe's first audio
    stream (codec, sample format, channels, layout, rate, and the duration
    in the stream's time base), or the same refusal, and the hash driver's
    stream copy against `ffmpeg -copyts -c copy -f framecrc`."""
    rows = []
    passed = understood = 0
    fixtures = sorted((FIXTURES / "mp3").glob("*.mp3"))
    for path in fixtures:
        name = path.stem
        problems = []
        theirs = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                     "stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,duration_ts,time_base", "-of",
                     "default=nw=1", path)
        ours = run(args.zffprobe, path)
        if theirs.returncode != 0 or not theirs.stdout.strip():
            if tool_error(ours, "zffprobe", path) is None:
                problems.append(f"zffprobe exited {ours.returncode} ({first_line(text(ours.stderr)) or 'no error'}) "
                                f"where ffprobe refuses")
        elif ours.returncode != 0:
            problems.append(f"zffprobe refuses: {first_line(text(ours.stderr))}")
        else:
            f = dict(line.split("=", 1) for line in text(theirs.stdout).splitlines() if "=" in line)
            o = dict(line.split("=", 1) for line in text(ours.stdout).splitlines() if "=" in line)
            den = f.get("time_base", "1/0").split("/")[1]
            want = {"codec": f.get("codec_name"), "sample_fmt": f.get("sample_fmt"), "channels": f.get("channels"),
                    "channel_layout": f.get("channel_layout"), "sample_rate": f.get("sample_rate"),
                    "duration_num": f.get("duration_ts"), "duration_den": den if f.get("duration_ts") != "N/A" else "N/A"}
            for key, value in want.items():
                if o.get(key) != value:
                    problems.append(f"{key}: zffprobe {o.get(key)}, ffprobe {value}")
        known = KNOWN_MP3_COPY_DIFFERENCES.get(name)
        problems += check_framecrc_copy(args, path, known, ours, MP3_COPY_OPTIONS)
        if problems:
            failures.extend(f"mp3 {name}: {p}" for p in problems)
            rows.append(f"| `{name}` | **FAIL**: {'; '.join(problems)} |")
        else:
            passed += 1
            understood += known is not None
            rows.append(f"| `{name}` | pass{' (copy: ' + known[1] + ')' if known else ''} |")
    lines += [
        "",
        "## MP3 fixtures (T29a)",
        "",
        f"MP3 fixtures whose zffprobe report equals ffprobe's (or both refuse) and whose copy equals "
        f"`ffmpeg -copyts -c copy -f framecrc`: {passed}/{len(fixtures)} (vectors/mp3.txt holds every packet "
        f"av_read_frame gives, vectors/seek_mp3.txt every seek).",
        "",
        "| Fixture | Result |",
        "| --- | --- |",
    ] + rows
    stale = unmatched_entries(KNOWN_MP3_COPY_DIFFERENCES, {p.stem for p in fixtures}, "KNOWN_MP3_COPY_DIFFERENCES",
                              failures)
    record("MP3 fixtures (T29a)", passed, len(fixtures) + stale, understood=understood)


def compare_ogg(args, lines, failures):
    """The Ogg fixtures (T27a): zffprobe against ffprobe's first audio
    stream (codec, sample format, channels, layout, rate, duration), and
    the hash driver's stream copy against `ffmpeg -c copy -f framecrc`."""
    rows = []
    passed = understood = 0
    fixtures = sorted((FIXTURES / "ogg").glob("*.ogg"))
    for path in fixtures:
        name = path.stem
        problems = []
        theirs = run(args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                     "stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,duration_ts", "-of",
                     "default=nw=1", path)
        ours = run(args.zffprobe, path)
        if theirs.returncode != 0 or not theirs.stdout.strip():
            if tool_error(ours, "zffprobe", path) is None:
                problems.append(f"zffprobe exited {ours.returncode} ({first_line(text(ours.stderr)) or 'no error'}) "
                                f"where ffprobe refuses")
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
        known = KNOWN_OGG_COPY_DIFFERENCES.get(name)
        problems += check_framecrc_copy(args, path, known, ours)
        if problems:
            failures.extend(f"ogg {name}: {p}" for p in problems)
            rows.append(f"| `{name}` | **FAIL**: {'; '.join(problems)} |")
        else:
            passed += 1
            understood += known is not None
            rows.append(f"| `{name}` | pass{' (copy: ' + known[1] + ')' if known else ''} |")
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
    stale = unmatched_entries(KNOWN_OGG_COPY_DIFFERENCES, {p.stem for p in fixtures}, "KNOWN_OGG_COPY_DIFFERENCES",
                              failures)
    record("Ogg fixtures (T27a)", passed, len(fixtures) + stale, understood=understood)


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
    two sets must be equal both ways, and every field must match; a codec
    only a demuxer names must be listed when zffprobe reports it."""
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
    # Two-sided: every codec the reference build decodes or encodes (a
    # decoder alone, an encoder alone, or a recorded flag difference) has a
    # descriptor in the registry, whose fields the loop below checks; every
    # descriptor the registry lists is FFmpeg's.
    their_active = {name for name, (flags, _) in their_codecs.items() if flags[0] == "D" or flags[1] == "E"}
    if their_active - set(codecs):
        problems.append(f"codecs FFmpeg decodes or encodes that the registry lacks: {sorted(their_active - set(codecs))}")
    # A codec only a demuxer names (mp1, mp2 and mp3, T29a) is in neither
    # set above. zffprobe's codec for every fixture it accepts is FFmpeg's
    # (each fixture section compares it with ffprobe's), so each one it
    # reports needs a descriptor here.
    reported = set()
    for directory in ("wav", "au", "aiff", "caf", "flac", "ogg", "mp3"):
        for path in sorted((FIXTURES / directory).glob(f"*.{directory}")):
            probe = run(args.zffprobe, path)
            if probe.returncode == 0:
                reported |= {line.partition("=")[2] for line in text(probe.stdout).splitlines()
                             if line.startswith("codec=")}
    if not reported or reported - set(codecs):
        problems.append(f"codecs zffprobe reports for the fixtures {sorted(reported)}; the registry lacks "
                        f"{sorted(reported - set(codecs))}")
    # A recorded flag difference holds exactly: listed but now equal is stale.
    for name in sorted(known_codecs):
        ours_flags = codecs[name][0] if name in codecs else None
        theirs_flags = their_codecs[name][0] if name in their_codecs else None
        if (ours_flags, theirs_flags) != KNOWN_REGISTRY_DIFFERENCES[("codec", name)][0]:
            problems.append(f"codec {name}: flags ours {ours_flags}, FFmpeg's {theirs_flags}, where "
                            f"KNOWN_REGISTRY_DIFFERENCES records {KNOWN_REGISTRY_DIFFERENCES[('codec', name)][0]}")
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
    if not hash_muxers <= set(their_formats):
        problems.append(f"FFmpeg's formats {sorted(their_formats)} lack the recorded {sorted(hash_muxers)}")
    # Each demuxing format has its demuxer line and each muxing one its
    # muxer line, and no line names another format.
    for kind, lines_of, column in (("demuxer", demuxers, 0), ("muxer", muxers, 1)):
        expected = {name for name, (flags, _) in formats.items() if flags[column] != "."}
        if set(lines_of) != expected:
            problems.append(f"{kind} lines for {sorted(lines_of)}, the formats' flags name {sorted(expected)}")
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


def check_oracle_predicates():
    """Fault injection for the predicates that decide a pass: each must reject
    a wrong status or a failed command, or a broken tool could pass."""
    Done = collections.namedtuple("Done", "returncode stdout stderr")
    line = b"zffmpeg: in.wav: UnsupportedLayout\n"
    assert refusal_name(3, line, "zffmpeg", "in.wav") == "UnsupportedLayout"
    for wrong in (-6, 0, 1, 2, 4, 5, 6):
        assert refusal_name(wrong, line, "zffmpeg", "in.wav") is None, wrong
    assert refusal_name(3, b"zffmpeg: other.wav: UnsupportedLayout\n", "zffmpeg", "in.wav") is None
    assert refusal_name(4, b"zffmpeg: in.wav: ReadFailed\n", "zffmpeg", "in.wav") == "ReadFailed"
    good = Done(0, b"fLaC" + bytes(40), b"")
    failed = Done(1, b"", b"error\n")
    assert flac_pipe_problem(good, good) is None
    for theirs, ours in ((failed, failed), (good, failed), (failed, good), (Done(0, b"", b""), Done(0, b"", b""))):
        assert flac_pipe_problem(theirs, ours), (theirs, ours)
    assert flac_pipe_problem(good, Done(0, b"fLaC" + bytes(41), b""))
    no_decoder = Done(234, b"", b"[aist#0:0/mp1] Decoding requested, but no decoder found for: mp1\n"
                                b"Error opening output files: Invalid argument\n")
    assert same_decode_refusal(no_decoder, "UnsupportedOperation")
    for error in (None, "DecodeErrorRate", "InvalidMp3"):
        assert not same_decode_refusal(no_decoder, error), error
    assert not same_decode_refusal(no_decoder._replace(returncode=0), "UnsupportedOperation")
    rate = Done(69, b"", b"Decode error rate 0.958333 exceeds maximum 0.666667\n")
    assert same_decode_refusal(rate, "DecodeErrorRate") and not same_decode_refusal(rate, "UnsupportedOperation")


def main():
    check_oracle_predicates()
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
    compare_mp3(args, lines, failures)
    compare_ogg_decode(args, lines, failures)
    compare_mp3_decode(args, lines, failures)
    compare_mp2_output(args, lines, failures)
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
