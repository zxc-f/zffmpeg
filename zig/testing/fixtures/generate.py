#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
"""Generate the fixtures for the WAV (TODO.md T02), AU (T12a), AIFF (T22b), raw PCM (T22c), CAF (T22d) and FLAC (T26a) contracts.

Every fixture is defined below and built byte by byte with the Python standard
library, independently of the Zig implementation. From those lists this script
writes:

* wav/<name>.wav       the WAV fixture files
* manifest.zon         WAV expected results, imported by zig/testing/fixtures.zig
* README.md            the WAV table between the GENERATED markers
* au/<name>.au         the AU fixture files
* au/manifest.zon      AU expected results, imported by zig/testing/fixtures.zig
* au/README.md         the AU table between the GENERATED markers
* aiff/<name>.aiff     the AIFF and AIFF-C fixture files (T22b)
* aiff/manifest.zon    AIFF expected results
* aiff/README.md       the AIFF table between the GENERATED markers
* raw/<name>.raw       the raw PCM fixture files (T22c)
* raw/manifest.zon     raw PCM expected results, with each file's parameters
* raw/README.md        the raw PCM table between the GENERATED markers
* caf/<name>.caf       the CAF fixture files (T22d)
* caf/manifest.zon     CAF expected results
* caf/README.md        the CAF table between the GENERATED markers
* flac/<name>.flac     the FLAC fixture files (T26a), except the FFmpeg-made
                       flac_ffmpeg_*.flac, which are committed and checked
                       against their recorded hashes
* flac/manifest.zon    FLAC expected results, with each output's PCM hash
* flac/README.md       the FLAC table between the GENERATED markers

Usage, from the repository root:

    python3 zig/testing/fixtures/generate.py           # rewrite the outputs
    python3 zig/testing/fixtures/generate.py --check   # fail if any output is stale
    python3 zig/testing/fixtures/generate.py --flac-input NAME   # an FFmpeg-made fixture's input
"""

import argparse
import dataclasses
import hashlib
import pathlib
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
WAV_DIR = HERE / "wav"
MANIFEST = HERE / "manifest.zon"
README = HERE / "README.md"
AU_DIR = HERE / "au"
AU_MANIFEST = AU_DIR / "manifest.zon"
AU_README = AU_DIR / "README.md"
AIFF_DIR = HERE / "aiff"
AIFF_MANIFEST = AIFF_DIR / "manifest.zon"
AIFF_README = AIFF_DIR / "README.md"
RAW_DIR = HERE / "raw"
RAW_MANIFEST = RAW_DIR / "manifest.zon"
RAW_README = RAW_DIR / "README.md"
CAF_DIR = HERE / "caf"
CAF_MANIFEST = CAF_DIR / "manifest.zon"
CAF_README = CAF_DIR / "README.md"
TABLE_BEGIN = "<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->\n"
TABLE_END = "<!-- END GENERATED FIXTURE TABLE -->\n"

# Contract errors from port.md ("First WAV contract"), mirrored by the Failure
# enum in zig/testing/fixtures.zig.
ERRORS = (
    "InvalidRiff",
    "InvalidWave",
    "InvalidFormat",
    "Truncated",
    "UnsupportedFormat",
    "UnsupportedStreamingSize",
    "LimitExceeded",
)

MAX_CHUNKS = 4096
MAX_RATE = 192_000

# Hand-picked samples: zero, ±1, both extrema and a few ordinary values.
MONO = [0, 1, -1, 32767, -32768, 12345, -12345, 256]
# Interleaved left/right frames.
STEREO = [0, 0, 32767, -32768, -1, 1, 1000, -1000]


# --- byte builders ---------------------------------------------------------


def u16(value):
    return struct.pack("<H", value)


def u32(value):
    return struct.pack("<I", value)


def pcm(samples):
    return b"".join(struct.pack("<h", s) for s in samples)


def chunk(chunk_id, body, size=None, pad=True):
    """A RIFF chunk. `size` overrides the declared size; odd bodies get a pad byte."""
    assert len(chunk_id) == 4
    out = chunk_id + u32(len(body) if size is None else size) + body
    if pad and len(body) % 2:
        out += b"\0"
    return out


def fmt_body(channels=1, rate=8000, bits=16, tag=1, block_align=None,
             byte_rate=None, cb_size=None, extra=b""):
    if block_align is None:
        block_align = channels * (bits // 8)
    if byte_rate is None:
        byte_rate = rate * block_align
    body = u16(tag) + u16(channels) + u32(rate) + u32(byte_rate) + u16(block_align) + u16(bits)
    if cb_size is not None:
        body += u16(cb_size) + extra
    return body


def fmt_chunk(**fields):
    return chunk(b"fmt ", fmt_body(**fields))


def data_chunk(samples, size=None):
    return chunk(b"data", pcm(samples), size=size)


def riff(*chunks, tag=b"RIFF", size=None, form=b"WAVE", size_delta=0):
    """A RIFF file. `size` overrides riff_size; `size_delta` adjusts the computed one."""
    payload = form + b"".join(chunks)
    declared = len(payload) + size_delta if size is None else size
    return tag + u32(declared) + payload


def mono_8k():
    return riff(fmt_chunk(channels=1, rate=8000), data_chunk(MONO))


# --- encodings (T21a) --------------------------------------------------------

# The WAV encodings of the contract: FFmpeg codec name -> (format tag, bits per
# sample, storage). Storage is the sample format FFmpeg's decoder gives.
WAV_CODECS = {
    "pcm_u8": (1, 8, "u8"),
    "pcm_s16le": (1, 16, "s16"),
    "pcm_s24le": (1, 24, "s32"),
    "pcm_s32le": (1, 32, "s32"),
    "pcm_s64le": (1, 64, "s64"),
    "pcm_f32le": (3, 32, "flt"),
    "pcm_f64le": (3, 64, "dbl"),
    "pcm_alaw": (6, 8, "s16"),
    "pcm_mulaw": (7, 8, "s16"),
}
# KSDATAFORMAT_SUBTYPE_*: the format tag as a little-endian u32, then this.
SUBFORMAT_BASE = bytes.fromhex("00001000800000aa00389b71")
CHANNEL_MASK = {1: 0x4, 2: 0x3}  # front center; front left | front right
WRITER_MAX_PLAIN_RATE = 48_000  # riffenc.c: WAVE_FORMAT_EXTENSIBLE above this
WRITER_MAX_MASK = 0x40000  # riffenc.c: a mask with a later position is written as 0
MAX_CHANNELS = 64  # the parsers' default limit (T23b)

# Channel layouts (T23b), restated from libavutil/channel_layout.h and .c:
# each speaker position's short name by its bit, and the named layouts in
# FFmpeg's order. ffprobe prints a stream's layout with these, or `unknown`.
CHANNEL_NAMES = {
    0: "FL", 1: "FR", 2: "FC", 3: "LFE", 4: "BL", 5: "BR", 6: "FLC", 7: "FRC", 8: "BC", 9: "SL", 10: "SR",
    11: "TC", 12: "TFL", 13: "TFC", 14: "TFR", 15: "TBL", 16: "TBC", 17: "TBR", 29: "DL", 30: "DR", 31: "WL",
    32: "WR", 33: "SDL", 34: "SDR", 35: "LFE2", 36: "TSL", 37: "TSR", 38: "BFC", 39: "BFL", 40: "BFR",
    41: "SSL", 42: "SSR", 43: "TTL", 44: "TTR", 61: "BIL", 62: "BIR",
}


def channel_bits(*names):
    by_name = {name: bit for bit, name in CHANNEL_NAMES.items()}
    return sum(1 << by_name[name] for name in names)


NAMED_LAYOUTS = [
    ("mono", channel_bits("FC")),
    ("stereo", channel_bits("FL", "FR")),
    ("2.1", channel_bits("FL", "FR", "LFE")),
    ("3.0", channel_bits("FL", "FR", "FC")),
    ("3.0(back)", channel_bits("FL", "FR", "BC")),
    ("4.0", channel_bits("FL", "FR", "FC", "BC")),
    ("quad", channel_bits("FL", "FR", "BL", "BR")),
    ("quad(side)", channel_bits("FL", "FR", "SL", "SR")),
    ("3.1", channel_bits("FL", "FR", "FC", "LFE")),
    ("5.0", channel_bits("FL", "FR", "FC", "BL", "BR")),
    ("5.0(side)", channel_bits("FL", "FR", "FC", "SL", "SR")),
    ("4.1", channel_bits("FL", "FR", "FC", "LFE", "BC")),
    ("5.1", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR")),
    ("5.1(side)", channel_bits("FL", "FR", "FC", "LFE", "SL", "SR")),
    ("6.0", channel_bits("FL", "FR", "FC", "BC", "SL", "SR")),
    ("6.0(front)", channel_bits("FL", "FR", "FLC", "FRC", "SL", "SR")),
    ("3.1.2", channel_bits("FL", "FR", "FC", "LFE", "TFL", "TFR")),
    ("hexagonal", channel_bits("FL", "FR", "FC", "BL", "BR", "BC")),
    ("6.1", channel_bits("FL", "FR", "FC", "LFE", "BC", "SL", "SR")),
    ("6.1(back)", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "BC")),
    ("6.1(front)", channel_bits("FL", "FR", "LFE", "FLC", "FRC", "SL", "SR")),
    ("7.0", channel_bits("FL", "FR", "FC", "BL", "BR", "SL", "SR")),
    ("7.0(front)", channel_bits("FL", "FR", "FC", "FLC", "FRC", "SL", "SR")),
    ("7.1", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR")),
    ("7.1(wide)", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC")),
    ("7.1(wide-side)", channel_bits("FL", "FR", "FC", "LFE", "FLC", "FRC", "SL", "SR")),
    ("5.1.2", channel_bits("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR")),
    ("5.1.2(back)", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "TFL", "TFR")),
    ("octagonal", channel_bits("FL", "FR", "FC", "BL", "BC", "BR", "SL", "SR")),
    ("cube", channel_bits("FL", "FR", "BL", "BR", "TFL", "TFR", "TBL", "TBR")),
    ("5.1.4", channel_bits("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR", "TBL", "TBR")),
    ("5.1.6", channel_bits("FL", "FR", "FC", "LFE", "SL", "SR", "TFL", "TFR", "TBL", "TBR", "TFC", "TC")),
    ("7.1.2", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR")),
    ("7.1.4", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR")),
    ("7.1.6", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR", "TFC", "TC")),
    ("7.2.3", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBC", "LFE2")),
    ("9.1.4", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR",
                           "FLC", "FRC")),
    ("9.1.6", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR",
                           "FLC", "FRC", "TSL", "TSR")),
    ("hexadecagonal", channel_bits("FL", "FR", "FC", "BL", "BC", "BR", "SL", "SR", "WL", "WR", "TBL", "TBR",
                                   "TBC", "TFC", "TFL", "TFR")),
    ("binaural", channel_bits("BIL", "BIR")),
    ("downmix", channel_bits("DL", "DR")),
    ("22.2", channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR",
                          "FLC", "FRC", "TSL", "TSR", "BC", "LFE2", "TFC", "TC", "TBC", "BFC", "BFL", "BFR")),
]


def describe_mask(mask):
    """FFmpeg's description of a native layout: its name, else its channels."""
    for name, named in NAMED_LAYOUTS:
        if named == mask:
            return name
    channels = [CHANNEL_NAMES.get(bit, f"USR{bit}") for bit in range(64) if mask >> bit & 1]
    return f"{len(channels)} channels ({'+'.join(channels)})"


def default_mask(channels):
    """`av_channel_layout_default`: the first named layout with `channels`, or None."""
    return next((mask for _, mask in NAMED_LAYOUTS if bin(mask).count("1") == channels), None)


def alaw_to_linear(code):
    """G.711 A-law expansion, as in the ITU recommendation's reference code."""
    a = code ^ 0x55
    t = (a & 0x0F) << 4
    seg = (a & 0x70) >> 4
    t = t + 8 if seg == 0 else (t + 0x108) << (seg - 1)
    return t if a & 0x80 else -t


def mulaw_to_linear(code):
    """G.711 mu-law expansion with the 0x84 bias."""
    u = ~code & 0xFF
    t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
    return 0x84 - t if u & 0x80 else t - 0x84


def decode_stored(codec, data):
    """The decoded samples as FFmpeg stores them: integers, floats as bit patterns."""
    if codec == "pcm_u8":
        return list(data)
    if codec == "pcm_s16le":
        return [s for (s,) in struct.iter_unpack("<h", data)]
    if codec == "pcm_s24le":
        raws = [int.from_bytes(data[i:i + 3], "little") for i in range(0, len(data), 3)]
        return [struct.unpack("<i", struct.pack("<I", (raw << 8) & 0xFFFFFFFF))[0] for raw in raws]
    if codec == "pcm_s32le":
        return [s for (s,) in struct.iter_unpack("<i", data)]
    if codec == "pcm_s64le":
        return [s for (s,) in struct.iter_unpack("<q", data)]
    if codec == "pcm_f32le":
        return [s for (s,) in struct.iter_unpack("<I", data)]
    if codec == "pcm_f64le":
        return [s for (s,) in struct.iter_unpack("<Q", data)]
    if codec == "pcm_alaw":
        return [alaw_to_linear(b) for b in data]
    if codec == "pcm_mulaw":
        return [mulaw_to_linear(b) for b in data]
    # The big-endian and signed 8-bit encodings (AU, T22a). FFmpeg stores s8
    # as u8, offset by 128.
    if codec == "pcm_s8":
        return [b ^ 0x80 for b in data]
    if codec == "pcm_s16be":
        return [s for (s,) in struct.iter_unpack(">h", data)]
    if codec == "pcm_s24be":
        raws = [int.from_bytes(data[i:i + 3], "big") for i in range(0, len(data), 3)]
        return [struct.unpack("<i", struct.pack("<I", (raw << 8) & 0xFFFFFFFF))[0] for raw in raws]
    if codec == "pcm_s32be":
        return [s for (s,) in struct.iter_unpack(">i", data)]
    if codec == "pcm_f32be":
        return [s for (s,) in struct.iter_unpack(">I", data)]
    if codec == "pcm_f64be":
        return [s for (s,) in struct.iter_unpack(">Q", data)]
    if codec == "pcm_s64be":  # CAF (T22d)
        return [s for (s,) in struct.iter_unpack(">q", data)]
    raise ValueError(codec)


STORAGE_PACK = {"u8": "<B", "s16": "<h", "s32": "<i", "s64": "<q", "flt": "<I", "dbl": "<Q"}


def storage_bytes(stream):
    """The decoded samples serialized little-endian, as `ffmpeg -c:a pcm_<storage>le` writes them."""
    fmt = STORAGE_PACK[stream.storage]
    return b"".join(struct.pack(fmt, s) for s in stream.stored)


def canonical_wav(codec, channels, rate, data, mask="default"):
    """The writer's output for one known-length stream with a native layout of
    `mask` (by default mono's or stereo's; None for an unspecified layout):
    the header riffenc.c chooses (WAVE_FORMAT_EXTENSIBLE for a native layout
    other than mono and stereo, above 48 kHz, or above 16 bits unless float,
    with the mask when its positions are WAVE's first 18), a `fact` chunk for
    every encoding but tag 1, then `data`."""
    tag, bits, _ = WAV_CODECS[codec]
    if mask == "default":
        mask = CHANNEL_MASK.get(channels)
    frames = len(data) // (channels * bits // 8)
    named_order = mask is not None and mask not in CHANNEL_MASK.values()
    if named_order or rate > WRITER_MAX_PLAIN_RATE or (bits > 16 and tag != 3):
        written = mask if mask is not None and mask < WRITER_MAX_MASK else 0
        extension = u16(bits) + u32(written) + u32(tag) + SUBFORMAT_BASE
        fmt = fmt_body(channels, rate, bits, tag=0xFFFE, cb_size=22, extra=extension)
    elif tag == 1:
        fmt = fmt_body(channels, rate, bits, tag=1)
    else:
        fmt = fmt_body(channels, rate, bits, tag=tag, cb_size=0)
    chunks = [chunk(b"fmt ", fmt)]
    if tag != 1:
        chunks.append(chunk(b"fact", u32(frames)))
    chunks.append(chunk(b"data", data))
    return riff(*chunks)


def rf64_wav(*chunks, tag=b"RF64", data_size=None, frames=0, riff_field=0xFFFFFFFF, riff_size=None,
             ds64_size=28, table=0):
    """An RF64/BW64 file: `ds64` first, with the 64-bit sizes, then `chunks`.
    `data_size` is the `ds64` data size; `riff_size` overrides its RIFF size."""
    body = struct.pack("<QQQI", 0, data_size or 0, frames, table) + bytes(max(ds64_size - 28, 0))
    rest = b"".join(chunks)
    declared = 4 + 8 + ds64_size + (ds64_size & 1) + len(rest) if riff_size is None else riff_size
    body = struct.pack("<Q", declared) + body[8:]
    return tag + u32(riff_field) + b"WAVE" + chunk(b"ds64", body[:ds64_size]) + rest


def canonical_rf64(codec, channels, rate, data):
    """The writer's RF64 output (`rf64 = .always`): the same `fmt ` and `fact`
    as `canonical_wav`, with 0xFFFFFFFF in the 32-bit RIFF and `data` sizes."""
    plain = canonical_wav(codec, channels, rate, data)
    tag, bits, _ = WAV_CODECS[codec]
    frames = len(data) // (channels * bits // 8)
    chunks = plain[12:]  # fmt, optional fact, data
    data_at = chunks.index(b"data" + u32(len(data)))
    chunks = chunks[:data_at] + b"data" + u32(0xFFFFFFFF) + chunks[data_at + 8:]
    return rf64_wav(chunks, data_size=len(data), frames=frames)


# Sony Wave64 (T21b): GUIDs for the chunk IDs and 64-bit sizes that count the
# 24-byte chunk header; chunks are padded to 8 bytes. libavformat/w64.c.
W64_RIFF_GUID = b"riff" + bytes.fromhex("2e91cf11a5d628db04c10000")
W64_SUFFIX = bytes.fromhex("f3acd3118cd100c04f8edb8a")
W64_HEADER_LEN = 40  # riff GUID, file size, wave GUID
W64_UNKNOWN_DATA = 0x7FFFFFFFFFFFFFFF  # what FFmpeg's muxer leaves in `data` on a pipe


def w64_guid(code):
    return code + W64_SUFFIX


def w64_chunk(guid, body, size=None, pad=True):
    """A Wave64 chunk. `size` overrides the declared size, which by default counts
    the header and body but not the padding, as the Sony specification has it."""
    declared = 24 + len(body) if size is None else size
    out = guid + struct.pack("<Q", declared) + body
    if pad:
        out += bytes(-len(out) % 8)
    return out


def w64(*chunks, size=None, size_delta=0, riff_guid=W64_RIFF_GUID, wave_guid=None):
    """A Wave64 file. `size` overrides the file size; `size_delta` adjusts the computed one."""
    rest = b"".join(chunks)
    declared = W64_HEADER_LEN + len(rest) + size_delta if size is None else size
    return riff_guid + struct.pack("<Q", declared) + (wave_guid or w64_guid(b"wave")) + rest


def canonical_w64(codec, channels, rate, data, mask="default"):
    """The writer's Wave64 output: the same `fmt ` as `canonical_wav`, a `fact`
    chunk with a 64-bit count for every encoding but tag 1, then `data`, with
    sizes that do not count the padding."""
    plain = canonical_wav(codec, channels, rate, data, mask)
    tag, bits, _ = WAV_CODECS[codec]
    frames = len(data) // (channels * bits // 8)
    fmt_len = int.from_bytes(plain[16:20], "little")
    chunks = [w64_chunk(w64_guid(b"fmt "), plain[20:20 + fmt_len])]
    if tag != 1:
        chunks.append(w64_chunk(w64_guid(b"fact"), struct.pack("<Q", frames)))
    chunks.append(w64_chunk(w64_guid(b"data"), data))
    return w64(*chunks)


# Tags (T21c): LIST/INFO subchunks and the bext chunk (EBU Tech 3285).


def info_list(*subchunks, list_type=b"INFO"):
    """A LIST chunk of the given type holding `subchunks` (already built)."""
    return chunk(b"LIST", list_type + b"".join(subchunks))


def info_tag(code, value, terminate=True, pad=True):
    """One INFO subchunk: `value` plus a NUL terminator, as writers store it."""
    return chunk(code, value + (b"\0" if terminate else b""), pad=pad)


def bext_chunk(description=b"", originator=b"", originator_reference=b"", date=b"", time=b"",
               time_reference=0, version=1, umid=bytes(64), coding_history=b""):
    """A bext chunk: the 602 fixed bytes, then the coding history."""
    def field(value, size):
        assert len(value) <= size
        return value + bytes(size - len(value))
    body = (field(description, 256) + field(originator, 32) + field(originator_reference, 32)
            + field(date, 10) + field(time, 8) + struct.pack("<QH", time_reference, version)
            + field(umid, 64) + bytes(190))
    assert len(body) == 602
    return chunk(b"bext", body + coding_history)


def tagged_wav(*before_data, after_data=(), samples=MONO[:4]):
    """A 16-bit mono 8 kHz WAV with chunks between `fmt ` and `data`, and after it."""
    return riff(fmt_chunk(), *before_data, data_chunk(samples), *after_data)


def extensible_fmt(channels=1, rate=8000, bits=16, sub_tag=1, valid=None, mask=None,
                   cb_size=22, block_align=None, subformat=None):
    """A 40-byte WAVE_FORMAT_EXTENSIBLE `fmt ` body; every field can be overridden."""
    valid = bits if valid is None else valid
    mask = CHANNEL_MASK.get(channels, 0) if mask is None else mask
    guid = u32(sub_tag) + SUBFORMAT_BASE if subformat is None else subformat
    return fmt_body(channels, rate, bits, tag=0xFFFE, block_align=block_align, cb_size=cb_size,
                    extra=u16(valid) + u32(mask) + guid)


# --- fixtures --------------------------------------------------------------


@dataclasses.dataclass
class Stream:
    """An accepted stream. Iterating gives (channels, rate, stored), as the s16-only
    tuple used to."""
    codec: str
    channels: int
    rate: int
    storage: str
    stored: list  # decoded samples as stored: integers; floats as IEEE bit patterns
    # The channel layout ffprobe prints (T23b): FFmpeg's description, or
    # `unknown` when the container leaves it unspecified. Set by each
    # builder's `with_layouts`.
    layout: str = None

    def __iter__(self):
        return iter((self.channels, self.rate, self.stored))


def wav_fmt(data):
    """The `fmt ` body of a RIFF, RF64 or Wave64 file, or None."""
    if data[:16] == W64_RIFF_GUID:
        pos = W64_HEADER_LEN
        while pos + 24 <= len(data):
            size = struct.unpack("<Q", data[pos + 16:pos + 24])[0]
            if data[pos:pos + 16] == w64_guid(b"fmt "):
                return data[pos + 24:pos + size]
            pos += size + (-size % 8)
        return None
    pos = 12
    while pos + 8 <= len(data):
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if data[pos:pos + 4] == b"fmt ":
            return data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    return None


def wav_layout(data, stream):
    """The layout FFmpeg reads from a WAV `fmt ` (riffdec.c): an extensible
    mask naming exactly the channels, else unspecified."""
    body = wav_fmt(data)
    tag, channels = struct.unpack("<HH", body[:4])
    if tag == 0xFFFE and len(body) >= 40:
        mask = struct.unpack("<I", body[20:24])[0]
        if mask and bin(mask).count("1") == channels:
            return describe_mask(mask)
    return "unknown"


def with_layouts(fixtures, layout_of):
    """Gives every accepted stream of `fixtures` its layout, `layout_of(data,
    stream)` unless set."""
    for f in fixtures:
        for stream in (f.accept, f.unknown_accept):
            if stream is not None and stream.layout is None:
                stream.layout = layout_of(f.data, stream)
    return fixtures


@dataclasses.dataclass
class Fixture:
    name: str
    group: str
    rule: str
    data: bytes
    accept: Stream = None
    reject: str = None  # contract error name
    writer_output: bool = False
    writer_header: str = "riff"  # writer output as riff, rf64 (`rf64 = .always`) or w64
    # The result with the parser's `unknown_length` option (T21b), where it differs.
    unknown_accept: Stream = None
    unknown_reject: str = None
    # The tags an accepted stream reports (T21c): (key, value) byte pairs under
    # FFmpeg's names and in its order, written by hand.
    tags: list = dataclasses.field(default_factory=list)
    # Writer output: the tags given to the writer when not `tags`, and the bext option.
    writer_tags: list = None
    writer_bext: bool = False


def streaming(name, group, rule, data, accept=None, reject=None):
    """A WAV fixture with an unknown-size sentinel: `UnsupportedStreamingSize` by
    default; `accept` (a Stream) or `reject` (an error) with `unknown_length`."""
    assert (accept is None) != (reject is None) and reject in (None, *ERRORS)
    return Fixture(name, group, rule, data, reject="UnsupportedStreamingSize",
                   unknown_accept=accept, unknown_reject=reject)


def wav_stream(codec, channels, rate, encoded):
    """The accepted stream of a WAV `data` payload in any contract encoding."""
    return Stream(codec, channels, rate, WAV_CODECS[codec][2], decode_stored(codec, encoded))


def accepted(name, group, rule, data, channels, rate, samples, writer_output=False, codec=None):
    """An accepted s16 stream (`pcm_s16le`, or the AU contract's `pcm_s16be`)."""
    return Fixture(name, group, rule, data,
                   accept=Stream(codec or "pcm_s16le", channels, rate, "s16", list(samples)),
                   writer_output=writer_output)


def accepted_encoded(name, group, rule, data, codec, channels, rate, encoded, writer_output=False):
    """An accepted WAV stream of any contract encoding; `encoded` is its `data` payload."""
    return Fixture(name, group, rule, data, accept=wav_stream(codec, channels, rate, encoded),
                   writer_output=writer_output)


def rejected(name, group, rule, data, error):
    assert error in ERRORS, error
    return Fixture(name, group, rule, data, reject=error)


EXTENSIBLE_PCM_GUID = bytes.fromhex("0100000000001000800000aa00389b71")


def build_fixtures():
    canonical = mono_8k()
    header_len = 12 + 8 + 16 + 8  # RIFF header, fmt chunk, data chunk header
    fx = []

    # Accepted streams.
    fx.append(accepted("mono_8k", "accepted", "Canonical mono: 16-byte `fmt `, tag 1, 8 kHz.",
                       canonical, 1, 8000, MONO, writer_output=True))
    fx.append(accepted("stereo_44k1", "accepted", "Canonical stereo at 44.1 kHz; samples interleave left/right.",
                       riff(fmt_chunk(channels=2, rate=44100), data_chunk(STEREO)),
                       2, 44100, STEREO, writer_output=True))
    fx.append(accepted("stereo_96k_tag1", "accepted",
                       "High-rate stereo with a plain tag-1 `fmt `, as older writers produce. The writer "
                       "emits WAVE_FORMAT_EXTENSIBLE above 48 kHz (`s16_stereo_96k_extensible`).",
                       riff(fmt_chunk(channels=2, rate=96000), data_chunk(STEREO)),
                       2, 96000, STEREO))
    fx.append(accepted("mono_192k_rate_limit", "accepted",
                       "Sample rate exactly at the 192,000 Hz limit, with a plain tag-1 `fmt `.",
                       riff(fmt_chunk(channels=1, rate=MAX_RATE), data_chunk(MONO[:4])),
                       1, MAX_RATE, MONO[:4]))
    fx.append(accepted("empty_data", "accepted", "`data` size 0 is an empty stream, not read-to-EOF.",
                       riff(fmt_chunk(), data_chunk([])), 1, 8000, [], writer_output=True))
    fx.append(accepted("fmt18_cbsize0", "accepted", "18-byte `fmt ` with `cbSize == 0`.",
                       riff(chunk(b"fmt ", fmt_body(cb_size=0)), data_chunk(MONO[:4])),
                       1, 8000, MONO[:4]))
    fx.append(accepted("byte_rate_mismatch", "accepted", "Inconsistent `byte_rate` is ignored.",
                       riff(fmt_chunk(byte_rate=12345), data_chunk(MONO[:4])), 1, 8000, MONO[:4]))
    fx.append(accepted("unknown_chunks", "accepted",
                       "Unknown chunks before `fmt `, between `fmt ` and `data`, and after `data` "
                       "(odd-sized, padded) are skipped.",
                       riff(chunk(b"LIST", b"INFO"), fmt_chunk(), chunk(b"JUNK", bytes(6)),
                            data_chunk(MONO[:4]), chunk(b"id3 ", b"ID3")),
                       1, 8000, MONO[:4]))
    fx.append(accepted("odd_chunk_padded", "accepted",
                       "An odd-sized chunk before `data` is followed by its pad byte, which is skipped.",
                       riff(fmt_chunk(), chunk(b"note", b"abc"), data_chunk(MONO[:4])),
                       1, 8000, MONO[:4]))
    fx.append(accepted("odd_final_chunk_pad_outside_extent", "accepted",
                       "The final odd-sized chunk ends at the RIFF extent and the file ends there: the "
                       "pad byte would lie outside the extent, so it is not read.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), chunk(b"note", b"abc", pad=False)),
                       1, 8000, MONO[:4]))
    fx.append(accepted("trailing_bytes_after_riff", "accepted",
                       "Bytes after the declared RIFF extent are ignored.",
                       riff(fmt_chunk(), data_chunk(MONO[:4])) + b"TRAILING",
                       1, 8000, MONO[:4]))
    fx.append(accepted("chunks_at_limit", "accepted",
                       f"Exactly {MAX_CHUNKS} chunks: `fmt `, {MAX_CHUNKS - 2} empty `JUNK`, `data`.",
                       riff(fmt_chunk(), *([chunk(b"JUNK", b"")] * (MAX_CHUNKS - 2)), data_chunk(MONO[:2])),
                       1, 8000, MONO[:2]))

    # Encodings (T21a): every contract encoding as the writer emits it.
    u8_bytes = bytes([0, 1, 127, 128, 129, 255, 64, 200])
    s24_bytes = b"".join((v & 0xFFFFFF).to_bytes(3, "little")
                         for v in [0, 1, -1, 0x7FFFFF, -0x800000, 123456, -654321, 256])
    s32_bytes = b"".join(struct.pack("<i", v) for v in
                         [0, 1, -1, 0x7FFFFFFF, -0x80000000, 123456789, -987654321, 65536])
    s64_bytes = b"".join(struct.pack("<q", v) for v in
                         [0, 1, -1, 2**63 - 1, -2**63, 1234567890123, -42, 1 << 40])
    # Zero, negative zero, +-1, 0.5, infinity, the smallest subnormal, a NaN with a payload.
    f32_bytes = b"".join(struct.pack("<I", v) for v in
                         [0, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x7F800000, 1, 0x7FC00001])
    f64_bytes = b"".join(struct.pack("<Q", v) for v in
                         [0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
                          0x7FF0000000000000, 1, 0x7FF8000000000001, 0x3FE0000000000000])
    # Each code's smallest and largest magnitudes of both signs, and two more.
    alaw_bytes = bytes([0xD5, 0x55, 0xAA, 0x2A, 0x00, 0x80, 0x7F, 0xFF])
    # Not 0x7F: mu-law's negative zero decodes like 0xFF, and every encoder,
    # FFmpeg's included, writes zero as 0xFF, so it cannot be writer output.
    mulaw_bytes = bytes([0xFF, 0x70, 0x80, 0x00, 0x01, 0x81, 0xFE, 0x7E])
    encoded = [
        ("u8_mono_8k", "pcm_u8", 1, 8000, u8_bytes,
         "Unsigned 8-bit (tag 1, 8 bits) with a 16-byte `fmt `; silence is 128."),
        ("s24_stereo_48k_extensible", "pcm_s24le", 2, 48000, s24_bytes,
         "24-bit stereo; above 16 bits the writer uses WAVE_FORMAT_EXTENSIBLE with the channel mask."),
        ("s32_mono_8k_extensible", "pcm_s32le", 1, 8000, s32_bytes, "32-bit integers, extensible."),
        ("s64_mono_8k_extensible", "pcm_s64le", 1, 8000, s64_bytes, "64-bit integers, extensible."),
        ("f32_mono_8k", "pcm_f32le", 1, 8000, f32_bytes,
         "IEEE float (tag 3) up to 48 kHz: an 18-byte `fmt ` with `cbSize` 0 and a `fact` chunk. "
         "Every bit is kept, NaN payload included."),
        ("f64_stereo_96k_extensible", "pcm_f64le", 2, 96000, f64_bytes,
         "64-bit float above 48 kHz: extensible with the IEEE float subformat, and a `fact` chunk."),
        ("alaw_mono_8k", "pcm_alaw", 1, 8000, alaw_bytes,
         "A-law (tag 6): an 18-byte `fmt ` and a `fact` chunk; decodes to s16."),
        ("mulaw_mono_8k", "pcm_mulaw", 1, 8000, mulaw_bytes,
         "mu-law (tag 7): an 18-byte `fmt ` and a `fact` chunk; decodes to s16. Its negative zero "
         "(0x7F) is left out: it reads as zero, which every encoder writes as 0xFF."),
        ("s16_stereo_96k_extensible", "pcm_s16le", 2, 96000, pcm(STEREO),
         "16-bit stereo above 48 kHz: the writer uses WAVE_FORMAT_EXTENSIBLE, as FFmpeg's does."),
        ("s16_mono_192k_extensible", "pcm_s16le", 1, MAX_RATE, pcm(MONO[:4]),
         "16-bit mono at the 192 kHz limit, extensible."),
    ]
    for name, codec, channels, rate, payload, rule in encoded:
        fx.append(accepted_encoded(name, "encodings", rule, canonical_wav(codec, channels, rate, payload),
                                   codec, channels, rate, payload, writer_output=True))
    fx.append(accepted_encoded("extensible_mask_zero", "encodings",
                               "Extensible with channel mask 0: FFmpeg leaves the layout unspecified.",
                               riff(chunk(b"fmt ", extensible_fmt(mask=0)), data_chunk(MONO[:4])),
                               "pcm_s16le", 1, 8000, pcm(MONO[:4])))
    fx.append(accepted_encoded("extensible_valid_bits_zero", "encodings",
                               "Extensible 24-bit stereo with `wValidBitsPerSample` 0: all bits are valid.",
                               riff(chunk(b"fmt ", extensible_fmt(channels=2, bits=24, valid=0)),
                                    chunk(b"data", s24_bytes)),
                               "pcm_s24le", 2, 8000, s24_bytes))

    # Tags (T21c): LIST/INFO and bext, read as FFmpeg's demuxer does and
    # reported under its names. The expected tags are written by hand.
    def tagged(name, rule, data, tags, samples=MONO[:4], writer_output=False):
        fixture = accepted(name, "tags", rule, data, 1, 8000, samples, writer_output=writer_output)
        fixture.tags = tags
        return fixture

    fx.append(tagged("info_tags",
                     "A LIST/INFO chunk between `fmt ` and `data`, NUL-terminated values in the order FFmpeg's "
                     "writer uses; the codes report as FFmpeg's names.",
                     tagged_wav(info_list(info_tag(b"IART", b"Artist"), info_tag(b"ICMT", b"A comment"),
                                          info_tag(b"ICRD", b"2024"), info_tag(b"IGNR", b"Speech"),
                                          info_tag(b"INAM", b"Title"))),
                     [(b"artist", b"Artist"), (b"comment", b"A comment"), (b"date", b"2024"),
                      (b"genre", b"Speech"), (b"title", b"Title")], writer_output=True))
    bext_umid = b"0x060A2B34" + b"01" * 28
    fx.append(tagged("bext_written",
                     "The writer's `bext` option: the 602 fixed bytes from the `bext`-named tags, version 1, "
                     "the UMID parsed back to bytes, and the coding history with its NUL. Read back, the "
                     "fields report under FFmpeg's names.",
                     tagged_wav(bext_chunk(description=b"Desc", originator=b"Orig", originator_reference=b"Ref",
                                           date=b"2024-01-01", time=b"10:11:12", time_reference=96000,
                                           umid=bytes.fromhex(bext_umid[2:].decode()) + bytes(32),
                                           coding_history=b"A=PCM\r\n\0")),
                     [(b"comment", b"Desc"), (b"encoded_by", b"Orig"), (b"originator_reference", b"Ref"),
                      (b"date", b"2024-01-01"), (b"creation_time", b"10:11:12"), (b"time_reference", b"96000"),
                      (b"umid", bext_umid), (b"coding_history", b"A=PCM\r\n")], writer_output=True))
    fx[-1].writer_bext = True
    fx[-1].writer_tags = [(b"description", b"Desc"), (b"originator", b"Orig"), (b"originator_reference", b"Ref"),
                          (b"origination_date", b"2024-01-01"), (b"origination_time", b"10:11:12"),
                          (b"time_reference", b"96000"), (b"umid", bext_umid), (b"coding_history", b"A=PCM\r\n")]
    fx.append(tagged("info_after_data",
                     "A lowercase `list` INFO chunk after `data`: read with the trailing chunks.",
                     tagged_wav(after_data=[chunk(b"list", b"INFO" + info_tag(b"INAM", b"Late"))]),
                     [(b"title", b"Late")]))
    fx.append(tagged("info_duplicates",
                     "INAM twice: the second replaces the first, which moves the last tag into its place; "
                     "IPRT and ITRK both report as `track`.",
                     tagged_wav(info_list(info_tag(b"INAM", b"First"), info_tag(b"IPRT", b"1"),
                                          info_tag(b"ITRK", b"2"), info_tag(b"INAM", b"Second"))),
                     [(b"track", b"2"), (b"track", b"1"), (b"title", b"Second")]))
    fx.append(tagged("info_values",
                     "An unterminated odd value with its pad, an embedded NUL, an empty value, a lowercase "
                     "code, an unknown code, an all-zero code (skipped) and a code cut at its NUL.",
                     tagged_wav(info_list(info_tag(b"IGNR", b"Pop", terminate=False), info_tag(b"IKEY", b"a\0b"),
                                          chunk(b"ISBJ", b""), info_tag(b"inam", b"lower"),
                                          info_tag(b"IENG", b"Engineer"), chunk(bytes(4), b"zz"),
                                          info_tag(b"IA\0X", b"v"))),
                     [(b"genre", b"Pop"), (b"IKEY", b"a"), (b"ISBJ", b""), (b"title", b"lower"),
                      (b"IENG", b"Engineer"), (b"IA", b"v")]))
    fx.append(tagged("info_missing_pad",
                     "A 3-byte value without its pad byte: the next header is one byte early, which "
                     "FFmpeg's reader recovers from by reading it again one byte back.",
                     tagged_wav(info_list(info_tag(b"IART", b"ab", pad=False), info_tag(b"INAM", b"Name"))),
                     [(b"artist", b"ab"), (b"title", b"Name")]))
    fx.append(tagged("info_malformed",
                     "A subchunk declaring 200 bytes in a shorter list ends the list; the tag before it is "
                     "kept and the stream is valid.",
                     tagged_wav(info_list(info_tag(b"INAM", b"Kept"), chunk(b"IART", b"x", size=200))),
                     [(b"title", b"Kept")]))
    fx.append(tagged("list_adtl", "A LIST of type `adtl` (cue labels) is skipped: no tags.",
                     tagged_wav(info_list(chunk(b"labl", b"abcd"), list_type=b"adtl")), []))
    basic_umid = bytes.fromhex("060a2b34") + b"\x01" * 28
    fx.append(tagged("bext_tags",
                     "A version 1 bext with every text field, a basic UMID and a coding history, then INFO: "
                     "ICMT equals the description, so only one `comment` remains.",
                     tagged_wav(bext_chunk(description=b"Same note", originator=b"Recorder",
                                           originator_reference=b"REF123", date=b"2024-05-06", time=b"07:08:09",
                                           time_reference=48000, umid=basic_umid + bytes(32),
                                           coding_history=b"A=PCM,F=8000\r\n"),
                                info_list(info_tag(b"ICMT", b"Same note"), info_tag(b"ITCH", b"Tech"))),
                     [(b"comment", b"Same note"), (b"encoded_by", b"Recorder"), (b"originator_reference", b"REF123"),
                      (b"date", b"2024-05-06"), (b"creation_time", b"07:08:09"), (b"time_reference", b"48000"),
                      (b"umid", b"0x060A2B34" + b"01" * 28),
                      (b"coding_history", b"A=PCM,F=8000\r\n"), (b"encoded_by", b"Tech")]))
    fx.append(tagged("bext_version0",
                     "A version 0 bext with empty text: only the time reference, even 0, is reported; the "
                     "UMID bytes are ignored before version 1.",
                     tagged_wav(bext_chunk(version=0, umid=b"\x01" * 64)), [(b"time_reference", b"0")]))
    fx.append(tagged("bext_extended_umid", "A 64-byte (extended) UMID: all eight parts are reported.",
                     tagged_wav(bext_chunk(umid=bytes(range(1, 65)))),
                     [(b"time_reference", b"0"), (b"umid", b"0x" + bytes(range(1, 65)).hex().upper().encode())]))
    rf64_tag_data = pcm(MONO[:4])
    fx.append(tagged("rf64_info", "RF64 carries LIST/INFO like RIFF.",
                     rf64_wav(fmt_chunk(), info_list(info_tag(b"INAM", b"Big")),
                              chunk(b"data", rf64_tag_data, size=0xFFFFFFFF), data_size=len(rf64_tag_data), frames=4),
                     [(b"title", b"Big")]))

    # RIFF header.
    fx.append(rejected("empty_input", "riff header", "No bytes at all.", b"", "Truncated"))
    fx.append(rejected("truncated_riff_header", "riff header", "Input ends inside the RIFF size field.",
                       canonical[:6], "Truncated"))
    fx.append(rejected("not_riff", "riff header", "Unknown container tag `JUNK`.",
                       b"JUNK" + canonical[4:], "InvalidRiff"))
    fx.append(rejected("rifx_big_endian", "riff header", "Big-endian RIFX container.",
                       b"RIFX" + canonical[4:], "UnsupportedFormat"))
    fx.append(rejected("rifx_truncated", "riff header",
                       "Precedence: the container tag is checked as soon as it is read, before the "
                       "input runs out.", b"RIFX\x24\x00", "UnsupportedFormat"))
    # RF64 and BW64 (T21b): 64-bit sizes in a leading `ds64` chunk.
    rf64_data = pcm(MONO[:4])
    rf64_rest = fmt_chunk() + chunk(b"data", rf64_data, size=0xFFFFFFFF)
    fx.append(accepted("rf64", "rf64",
                       "RF64 as the writer emits it with `rf64 = .always`: 0xFFFFFFFF in the 32-bit RIFF and "
                       "`data` sizes, the real ones in `ds64` (rejected before T21b).",
                       canonical_rf64("pcm_s16le", 1, 8000, rf64_data), 1, 8000, MONO[:4], writer_output=True))
    fx[-1].writer_header = "rf64"
    fx.append(accepted("bw64", "rf64", "BW64, the EBU's RF64 (rejected before T21b).",
                       rf64_wav(rf64_rest, tag=b"BW64", data_size=len(rf64_data), frames=4), 1, 8000, MONO[:4]))
    fx.append(accepted("rf64_data_size_in_chunk", "rf64",
                       "RF64 whose small `data` chunk holds its own size: `ds64`'s is used only for 0xFFFFFFFF.",
                       rf64_wav(fmt_chunk(), data_chunk(MONO[:4]), data_size=0xFFFF, frames=4), 1, 8000, MONO[:4]))
    fx.append(rejected("rf64_riff_size_not_sentinel", "rf64",
                       "RF64 with a 32-bit RIFF size other than 0xFFFFFFFF. FFmpeg ignores the field.",
                       rf64_wav(rf64_rest, data_size=len(rf64_data), riff_field=56), "InvalidRiff"))
    fx.append(rejected("rf64_missing_ds64", "rf64", "RF64 whose first chunk is `fmt `, not `ds64`.",
                       b"RF64" + u32(0xFFFFFFFF) + b"WAVE" + rf64_rest, "InvalidRiff"))
    fx.append(rejected("rf64_ds64_short", "rf64",
                       "A 24-byte `ds64` without the table count. FFmpeg accepts 24 bytes.",
                       rf64_wav(rf64_rest, data_size=len(rf64_data), ds64_size=24), "InvalidRiff"))
    fx.append(rejected("rf64_ds64_table", "rf64", "A `ds64` with one table entry (64-bit sizes of other chunks).",
                       rf64_wav(rf64_rest, data_size=len(rf64_data), table=1), "UnsupportedFormat"))
    fx.append(rejected("rf64_data_exceeds_extent", "rf64",
                       "`ds64` declares 64 data bytes, but the RF64 extent ends after 8.",
                       rf64_wav(rf64_rest, data_size=64), "InvalidRiff"))
    fx.append(rejected("rf64_truncated_ds64", "rf64", "Input ends inside `ds64`.",
                       rf64_wav(rf64_rest, data_size=len(rf64_data))[:30], "Truncated"))
    # Sony Wave64 (T21b): GUIDs and 64-bit sizes, chunks padded to 8 bytes.
    for name, codec, channels, payload, rule in [
        ("w64_mono_8k", "pcm_s16le", 1, pcm(MONO),
         "Wave64 as the writer emits it: the `fmt ` of WAV, sizes that count the 24-byte chunk header."),
        ("w64_u8_odd", "pcm_u8", 1, bytes([0x00, 0x80, 0xFF]),
         "Three u8 frames: `data` declares 27 bytes and 5 pad bytes follow, outside its size."),
        ("w64_alaw_mono_8k", "pcm_alaw", 1, alaw_bytes,
         "A-law: the 18-byte `fmt ` is padded to 8 bytes, and a `fact` chunk holds a 64-bit count."),
        ("w64_s24_stereo_extensible", "pcm_s24le", 2, s24_bytes, "24-bit stereo: the extensible `fmt `."),
    ]:
        fx.append(accepted_encoded(name, "w64", rule, canonical_w64(codec, channels, 8000, payload),
                                   codec, channels, 8000, payload, writer_output=True))
        fx[-1].writer_header = "w64"
    w64_quad = pcm(MONO)
    fx.append(accepted_encoded("w64_4point0", "w64",
                               "Four channels with the 4.0 mask (FL, FR, FC, BC): the extensible `fmt ` a named "
                               "layout other than mono and stereo gets (T23b).",
                               canonical_w64("pcm_s16le", 4, 8000, w64_quad, mask=channel_bits("FL", "FR", "FC", "BC")),
                               "pcm_s16le", 4, 8000, w64_quad, writer_output=True))
    fx[-1].writer_header = "w64"
    w64_fmt = w64_chunk(w64_guid(b"fmt "), fmt_body())
    w64_data = w64_chunk(w64_guid(b"data"), pcm(MONO[:4]))
    fx.append(accepted_encoded("w64_ffmpeg_padded_sizes", "w64",
                               "Float as FFmpeg's muxer writes it: its sizes count the padding, so the 18-byte "
                               "`fmt ` declares 48 bytes, a 24-byte body whose last 6 are skipped.",
                               w64(w64_chunk(w64_guid(b"fmt "), fmt_body(tag=3, bits=32, cb_size=0) + bytes(6)),
                                   w64_chunk(w64_guid(b"fact"), struct.pack("<Q", 4)),
                                   w64_chunk(w64_guid(b"data"), f32_bytes[:16])),
                               "pcm_f32le", 1, 8000, f32_bytes[:16]))
    summary_list = bytes.fromhex("bc945f925a52d21186dc00c04f8edb8a")
    fx.append(accepted_encoded("w64_unknown_chunks", "w64",
                               "A `summarylist` GUID chunk with a 5-byte body before `data` and a `levl` chunk "
                               "after it are skipped, with their padding.",
                               w64(w64_fmt, w64_chunk(summary_list, b"abcde"), w64_data,
                                   w64_chunk(w64_guid(b"levl"), b"xyz")),
                               "pcm_s16le", 1, 8000, pcm(MONO[:4])))
    fx.append(accepted("w64_pad_outside_extent", "w64",
                       "The file size ends with 3 frames (6 data bytes); the 2 pad bytes after them are absent.",
                       w64(w64_fmt, w64_chunk(w64_guid(b"data"), pcm(MONO[:3]), pad=False)), 1, 8000, MONO[:3]))
    fx.append(rejected("w64_pad_missing", "w64",
                       "The file size counts the 2 pad bytes after 6 data bytes, but the input ends before them.",
                       w64(w64_fmt, w64_chunk(w64_guid(b"data"), pcm(MONO[:3])))[:-2], "Truncated"))
    fx.append(rejected("w64_no_chunks", "w64", "A Wave64 header with no chunks: `fmt ` and `data` are missing.",
                       w64(), "InvalidWave"))
    fx.append(rejected("w64_bad_riff_guid", "w64", "`riff` followed by another GUID's last 12 bytes.",
                       w64(w64_fmt, w64_data, riff_guid=b"riff" + W64_SUFFIX), "InvalidRiff"))
    fx.append(rejected("w64_bad_wave_guid", "w64", "The form GUID is not `wave`'s.",
                       w64(w64_fmt, w64_data, wave_guid=w64_guid(b"WAVE")), "InvalidWave"))
    fx.append(rejected("w64_size_too_small", "w64", "A file size of 39, less than the 40-byte header.",
                       w64(w64_fmt, w64_data, size=39), "InvalidRiff"))
    fx.append(rejected("w64_chunk_size_below_header", "w64",
                       "A `fmt ` chunk declaring 16 bytes, less than its own 24-byte header.",
                       w64(w64_chunk(w64_guid(b"fmt "), fmt_body(), size=16), w64_data), "InvalidRiff"))
    fx.append(rejected("w64_data_exceeds_extent", "w64", "`data` declares 64 bytes past the file size.",
                       w64(w64_fmt, w64_chunk(w64_guid(b"data"), pcm(MONO[:4]), size=24 + 8 + 64)),
                       "InvalidRiff"))
    fx.append(rejected("w64_fmt_size_20", "w64",
                       "A plain `fmt ` of 20 bytes: Wave64 adds only FFmpeg's padded 24 to 16 and 18.",
                       w64(w64_chunk(w64_guid(b"fmt "), fmt_body(cb_size=2, extra=b"\0\0")), w64_data),
                       "UnsupportedFormat"))
    fx.append(rejected("w64_truncated_chunk_header", "w64", "Input ends inside the `data` chunk's GUID.",
                       w64(w64_fmt, w64_data)[:W64_HEADER_LEN + len(w64_fmt) + 10], "Truncated"))
    fx.append(streaming("w64_unknown_length_pipe", "w64",
                        "As FFmpeg's muxer writes Wave64 to a pipe: file size all ones, `data` size INT64_MAX.",
                        w64(w64_fmt, w64_chunk(w64_guid(b"data"), pcm(MONO), size=W64_UNKNOWN_DATA, pad=False),
                            size=0xFFFFFFFFFFFFFFFF),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO))))
    fx.append(streaming("w64_data_size_unknown", "w64",
                        "A known file size with `data` size all ones: with `unknown_length` the rest of the stream.",
                        w64(w64_fmt, w64_chunk(w64_guid(b"data"), pcm(MONO[:2]), size=0xFFFFFFFFFFFFFFFF, pad=False)),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:2]))))
    fx.append(streaming("riff_size_unknown", "riff header",
                        "`riff_size` is the 0xFFFFFFFF unknown-size sentinel. With `unknown_length` the extent "
                        "is the rest of the stream.",
                        riff(fmt_chunk(), data_chunk(MONO[:4]), size=0xFFFFFFFF),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:4]))))
    fx.append(streaming("riff_size_zero", "riff header", "`riff_size` is 0, the other unknown-size sentinel.",
                        riff(fmt_chunk(), data_chunk(MONO[:4]), size=0),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:4]))))
    fx.append(rejected("riff_size_too_small", "riff header", "`riff_size` 2 cannot hold the form type.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), size=2), "InvalidRiff"))
    fx.append(rejected("not_wave_form", "riff header", "RIFF form type `AVI ` instead of `WAVE`.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), form=b"AVI "), "InvalidWave"))
    fx.append(rejected("no_chunks", "riff header", "A WAVE form with no chunks: `fmt ` and `data` are missing.",
                       riff(), "InvalidWave"))

    # fmt chunk.
    fx.append(rejected("fmt_size_14", "fmt", "A complete `fmt ` chunk declaring only 14 bytes.",
                       riff(chunk(b"fmt ", fmt_body()[:14]), data_chunk(MONO[:4])), "InvalidFormat"))
    fx.append(rejected("fmt_truncated", "fmt", "Input ends inside the `fmt ` body.",
                       canonical[:30], "Truncated"))
    fx.append(rejected("fmt20_cbsize2", "fmt", "20-byte `fmt ` with `cbSize == 2` and two extension bytes.",
                       riff(chunk(b"fmt ", fmt_body(cb_size=2, extra=b"\0\0")), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    extensible = fmt_body(tag=0xFFFE, cb_size=22, extra=u16(16) + u32(4) + EXTENSIBLE_PCM_GUID)
    fx.append(accepted_encoded("fmt_extensible", "fmt",
                               "WAVE_FORMAT_EXTENSIBLE (tag 0xFFFE, 40 bytes) with the PCM subformat and "
                               "the mono mask: 16-bit PCM (rejected before T21a).",
                               riff(chunk(b"fmt ", extensible), data_chunk(MONO[:4])),
                               "pcm_s16le", 1, 8000, pcm(MONO[:4])))
    fx.append(accepted_encoded("fmt_float32", "fmt",
                               "IEEE float (tag 3, 32-bit) with a 16-byte `fmt ` and no `fact` chunk, which is "
                               "optional (rejected before T21a).",
                               riff(fmt_chunk(tag=3, bits=32), data_chunk(MONO[:4])),
                               "pcm_f32le", 1, 8000, pcm(MONO[:4])))
    fx.append(accepted_encoded("fmt_bits24", "fmt",
                               "Tag 1 with 24-bit samples and a plain 16-byte `fmt ` (rejected before T21a).",
                               riff(fmt_chunk(bits=24), data_chunk(MONO[:3])),
                               "pcm_s24le", 1, 8000, pcm(MONO[:3])))
    fx.append(rejected("fmt_bits12", "fmt",
                       "Tag 1 with 12 bits in 2-byte samples: only whole-byte depths. FFmpeg rounds up and "
                       "reads s16.", riff(fmt_chunk(bits=12, block_align=2), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    fx.append(rejected("fmt_float_bits16", "fmt", "Tag 3 with 16-bit samples: float is 32 or 64 bits.",
                       riff(fmt_chunk(tag=3, bits=16), data_chunk(MONO[:4])), "UnsupportedFormat"))
    fx.append(rejected("fmt_alaw_bits16", "fmt", "A-law (tag 6) declaring 16 bits: A-law is 8 bits.",
                       riff(fmt_chunk(tag=6, bits=16), data_chunk(MONO[:4])), "UnsupportedFormat"))
    fx.append(rejected("fmt_adpcm", "fmt", "Tag 2 (Microsoft ADPCM) is not a contract encoding.",
                       riff(fmt_chunk(tag=2, bits=4, block_align=1), data_chunk(MONO[:4])), "UnsupportedFormat"))
    fx.append(rejected("fmt_s24_block_align_mismatch", "fmt", "24-bit stereo with `block_align` 4 instead of 6.",
                       riff(fmt_chunk(channels=2, bits=24, block_align=4), data_chunk(STEREO[:4])),
                       "InvalidFormat"))
    fx.append(rejected("extensible_fmt18", "extensible", "Tag 0xFFFE in an 18-byte `fmt ` with `cbSize` 0.",
                       riff(chunk(b"fmt ", fmt_body(tag=0xFFFE, cb_size=0)), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    fx.append(rejected("extensible_cbsize_short", "extensible", "A 40-byte extensible `fmt ` declaring `cbSize` 10.",
                       riff(chunk(b"fmt ", extensible_fmt(cb_size=10)), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    fx.append(rejected("extensible_unknown_subformat", "extensible",
                       "An extensible `fmt ` whose subformat is the AC-3 GUID.",
                       riff(chunk(b"fmt ", extensible_fmt(
                           subformat=bytes.fromhex("2c806de046dbcf11b4d100805f6cbbea"))), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    fx.append(rejected("extensible_subformat_adpcm", "extensible",
                       "The base subformat GUID with tag 2 (ADPCM).",
                       riff(chunk(b"fmt ", extensible_fmt(sub_tag=2, bits=4, block_align=1)), data_chunk(MONO[:4])),
                       "UnsupportedFormat"))
    fx.append(rejected("extensible_valid_bits_mismatch", "extensible",
                       "24-bit samples declaring 20 valid bits: only all bits valid. FFmpeg reads them as s24.",
                       riff(chunk(b"fmt ", extensible_fmt(channels=2, bits=24, valid=20)), chunk(b"data", bytes(12))),
                       "UnsupportedFormat"))
    fx.append(accepted_encoded("extensible_mask_mismatch", "extensible",
                               "Stereo with the mono channel mask (front center): FFmpeg ignores a mask that does "
                               "not name exactly the channels, so the layout is unspecified (rejected before T23b).",
                               riff(chunk(b"fmt ", extensible_fmt(channels=2, mask=0x4)), data_chunk(STEREO)),
                               "pcm_s16le", 2, 8000, pcm(STEREO)))
    fx.append(rejected("extensible_truncated", "extensible", "Input ends inside the 40-byte extensible `fmt `.",
                       riff(chunk(b"fmt ", extensible_fmt()), data_chunk(MONO[:4]))[:50], "Truncated"))
    fx.append(accepted_encoded("fmt_channels3", "fmt",
                               "Three channels in a plain header: the layout is unspecified (rejected before T23b).",
                               riff(fmt_chunk(channels=3), data_chunk(MONO[:6])), "pcm_s16le", 3, 8000,
                               pcm(MONO[:6])))
    # Channel layouts (T23b): FFmpeg's layout is the extensible mask when it
    # names exactly the channels, else unspecified; the writer emits the mask
    # of a native layout as riffenc.c does.
    six = pcm(MONO + MONO[:4])
    fx.append(accepted_encoded("extensible_5point1", "layouts",
                               "Six channels with the 5.1 mask (FL, FR, FC, LFE, BL, BR): a named layout other "
                               "than mono and stereo makes the writer use WAVE_FORMAT_EXTENSIBLE even at 16 bits.",
                               canonical_wav("pcm_s16le", 6, 8000, six, mask=channel_bits("FL", "FR", "FC", "LFE", "BL", "BR")),
                               "pcm_s16le", 6, 8000, six, writer_output=True))
    eight = bytes(range(1, 25))
    fx.append(accepted_encoded("extensible_7point1_s24", "layouts",
                               "Eight 24-bit channels with the 7.1 mask (5.1(side) and BL, BR).",
                               canonical_wav("pcm_s24le", 8, 8000, eight,
                                             mask=channel_bits("FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR")),
                               "pcm_s24le", 8, 8000, eight, writer_output=True))
    fx.append(accepted_encoded("fmt_channels6", "layouts",
                               "Six channels in a plain header: unspecified, written back the same way.",
                               canonical_wav("pcm_s16le", 6, 8000, six, mask=None),
                               "pcm_s16le", 6, 8000, six, writer_output=True))
    fx.append(accepted_encoded("extensible_mask_high", "layouts",
                               "Three channels whose mask has FL, FR and position 20, which WAVE does not define: "
                               "native all the same, described by its positions.",
                               riff(chunk(b"fmt ", extensible_fmt(channels=3, mask=0x100003)), data_chunk(MONO[:6])),
                               "pcm_s16le", 3, 8000, pcm(MONO[:6])))
    fx.append(accepted_encoded("extensible_mask_extra", "layouts",
                               "Stereo with a three-channel mask: unspecified.",
                               riff(chunk(b"fmt ", extensible_fmt(channels=2, mask=0x7)), data_chunk(STEREO)),
                               "pcm_s16le", 2, 8000, pcm(STEREO)))
    wide = pcm([i - 32 for i in range(MAX_CHANNELS)])
    fx.append(accepted_encoded("fmt_channels64", "layouts",
                               f"{MAX_CHANNELS} channels, the default limit, in a plain header: one frame.",
                               riff(fmt_chunk(channels=MAX_CHANNELS), chunk(b"data", wide)),
                               "pcm_s16le", MAX_CHANNELS, 8000, wide))
    fx.append(rejected("fmt_channels65", "layouts",
                       f"{MAX_CHANNELS + 1} channels, above the default limit (FFmpeg reads them).",
                       riff(fmt_chunk(channels=MAX_CHANNELS + 1), chunk(b"data", bytes(2 * (MAX_CHANNELS + 1)))),
                       "LimitExceeded"))
    fx.append(rejected("fmt_channels0", "fmt", "Zero channels.",
                       riff(fmt_chunk(channels=0), data_chunk([])), "InvalidFormat"))
    fx.append(rejected("fmt_rate0", "fmt", "Zero sample rate.",
                       riff(fmt_chunk(rate=0), data_chunk(MONO[:4])), "InvalidFormat"))
    fx.append(rejected("fmt_rate_over_limit", "fmt", "Sample rate 192,001 Hz, above the default limit.",
                       riff(fmt_chunk(rate=MAX_RATE + 1), data_chunk(MONO[:4])), "LimitExceeded"))
    fx.append(rejected("fmt_block_align_mismatch", "fmt", "Stereo with `block_align` 2 instead of 4.",
                       riff(fmt_chunk(channels=2, block_align=2), data_chunk(STEREO)), "InvalidFormat"))
    fx.append(rejected("fmt_unsupported_before_invalid", "fmt",
                       "Precedence: tag 2 (ADPCM) with zero channels reports the unsupported tag first.",
                       riff(fmt_chunk(tag=2, bits=4, channels=0, block_align=1), data_chunk([])),
                       "UnsupportedFormat"))

    # Chunk order and duplicates.
    fx.append(rejected("data_before_fmt", "order", "`data` appears before any `fmt `.",
                       riff(data_chunk(MONO[:4]), fmt_chunk()), "InvalidWave"))
    fx.append(rejected("missing_data", "order", "`fmt ` but no `data` within the RIFF extent.",
                       riff(fmt_chunk()), "InvalidWave"))
    fx.append(rejected("duplicate_fmt", "order", "Two `fmt ` chunks (FFmpeg ignores the second).",
                       riff(fmt_chunk(), fmt_chunk(), data_chunk(MONO[:4])), "InvalidWave"))
    fx.append(rejected("duplicate_data", "order",
                       "A second `data` chunk after the first; reported after the first chunk's 2 frames.",
                       riff(fmt_chunk(), data_chunk(MONO[:2]), data_chunk(MONO[:2])), "InvalidWave"))

    # Data length.
    fx.append(streaming("data_size_unknown", "data length",
                        "`data` size 0xFFFFFFFF; precedence: the sentinel is reported before the extent check. "
                        "With `unknown_length` the data is the rest of the stream.",
                        riff(fmt_chunk(), data_chunk(MONO[:2], size=0xFFFFFFFF)),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:2]))))

    # Unknown length (T21b): read to the end of the stream with `unknown_length`.
    unknown = 0xFFFFFFFF
    fx.append(streaming("unknown_length_pipe", "unknown length",
                        "RIFF and `data` sizes 0xFFFFFFFF, as FFmpeg's muxer leaves them on a pipe.",
                        riff(fmt_chunk(), data_chunk(MONO, size=unknown), size=unknown),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO))))
    u8_data = bytes([0x00, 0x80, 0xFF])
    fx.append(streaming("unknown_length_odd_u8", "unknown length",
                        "Three u8 frames of unknown length: odd data at the end of the stream needs no pad byte.",
                        riff(fmt_chunk(bits=8), chunk(b"data", u8_data, size=unknown, pad=False), size=unknown),
                        accept=wav_stream("pcm_u8", 1, 8000, u8_data)))
    fx.append(streaming("unknown_length_partial_frame", "unknown length",
                        "Stereo data of unknown length ending after 1.5 frames.",
                        riff(fmt_chunk(channels=2), data_chunk(STEREO[:3], size=unknown), size=unknown),
                        reject="Truncated"))
    trailer = chunk(b"JUNK", bytes(4))
    fx.append(streaming("unknown_length_reads_past_chunks", "unknown length",
                        "`data` size 0xFFFFFFFF in a known RIFF extent: the data is the rest of the stream, so the "
                        "chunk after it decodes as samples and the RIFF size goes unchecked, as in FFmpeg.",
                        riff(fmt_chunk(), data_chunk(MONO[:2], size=unknown), trailer, size_delta=-4),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:2]) + trailer)))
    fx.append(streaming("unknown_riff_chunk_after_data", "unknown length",
                        "Unknown `riff_size` with a known `data` size: the chunks after `data` are read to the end "
                        "of the stream.",
                        riff(fmt_chunk(), data_chunk(MONO[:2]), trailer, size=0),
                        accept=wav_stream("pcm_s16le", 1, 8000, pcm(MONO[:2]))))
    fx.append(streaming("unknown_riff_empty_data", "unknown length",
                        "Unknown `riff_size` with `data` size 0: still an empty stream.",
                        riff(fmt_chunk(), data_chunk([]), size=unknown),
                        accept=wav_stream("pcm_s16le", 1, 8000, b"")))
    fx.append(streaming("unknown_riff_partial_chunk_header", "unknown length",
                        "Unknown `riff_size`: the stream ends 3 bytes into the chunk header after `data`.",
                        riff(fmt_chunk(), data_chunk(MONO[:2]), b"abc", size=unknown), reject="Truncated"))
    fx.append(streaming("unknown_riff_missing_data", "unknown length",
                        "Unknown `riff_size`: the stream ends after `fmt `, between chunks, with no `data`.",
                        riff(fmt_chunk(), size=unknown), reject="InvalidWave"))
    fx.append(streaming("unknown_riff_pad_missing", "unknown length",
                        "Unknown `riff_size`: odd u8 data of known size, and the stream ends before its pad byte.",
                        riff(fmt_chunk(bits=8), chunk(b"data", u8_data, pad=False), size=unknown),
                        reject="Truncated"))
    fx.append(rejected("data_not_block_aligned", "data length", "Stereo `data` of 6 bytes (1.5 frames).",
                       riff(fmt_chunk(channels=2), data_chunk(STEREO[:3])), "InvalidFormat"))

    # Bounds, padding and truncation.
    fx.append(rejected("data_exceeds_riff_extent", "bounds",
                       "`data` declares 64 bytes but the RIFF extent ends after 16.",
                       riff(fmt_chunk(), data_chunk(MONO, size=64)), "InvalidRiff"))
    fx.append(rejected("chunk_exceeds_riff_extent", "bounds",
                       "A chunk after `data` declares more bytes than the RIFF extent has left.",
                       riff(fmt_chunk(), data_chunk(MONO[:2]), chunk(b"JUNK", bytes(4), size=100)),
                       "InvalidRiff"))
    fx.append(rejected("partial_chunk_header_in_extent", "bounds",
                       "The RIFF extent leaves 3 bytes after `data`, too few for a chunk header.",
                       riff(fmt_chunk(), data_chunk(MONO[:2]), b"abc"), "InvalidRiff"))
    fx.append(rejected("odd_final_chunk_pad_missing", "bounds",
                       "`riff_size` counts the final chunk's pad byte, but the input ends before it.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), chunk(b"note", b"abc", pad=False), size_delta=1),
                       "Truncated"))
    fx.append(rejected("riff_size_exceeds_input", "bounds",
                       "`riff_size` claims 16 more bytes than the input holds after complete chunks.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), size_delta=16), "Truncated"))
    fx.append(rejected("truncated_data", "bounds", "Input ends after 5 of the 8 declared samples.",
                       canonical[:header_len + 10], "Truncated"))
    fx.append(rejected("truncated_mid_sample", "bounds", "Input ends inside a sample (7 data bytes).",
                       canonical[:header_len + 7], "Truncated"))
    with_trailer = riff(fmt_chunk(), data_chunk(MONO[:2]), chunk(b"JUNK", bytes(4)))
    fx.append(rejected("truncated_chunk_header_after_data", "bounds",
                       "Input ends inside the chunk header that follows `data`.",
                       with_trailer[:len(with_trailer) - 9], "Truncated"))

    # Limits.
    fx.append(rejected("chunks_over_limit", "limits",
                       f"{MAX_CHUNKS + 1} chunks: `fmt `, {MAX_CHUNKS - 1} empty `JUNK`, `data`.",
                       riff(fmt_chunk(), *([chunk(b"JUNK", b"")] * (MAX_CHUNKS - 1)), data_chunk(MONO[:2])),
                       "LimitExceeded"))

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate fixture names"
    return with_layouts(fx, wav_layout)


def large_skip_vector():
    """Synthesized at test time rather than committed: a 2 MiB LIST chunk is skipped."""
    return riff(fmt_chunk(), chunk(b"LIST", bytes(2 * 1024 * 1024)), data_chunk(MONO[:4]))


# --- AU fixtures (T12a) ----------------------------------------------------

# Contract errors from port.md ("AU contract"), mirrored by `au.Failure` in
# zig/testing/fixtures.zig.
AU_ERRORS = (
    "InvalidAu",
    "InvalidFormat",
    "Truncated",
    "UnsupportedFormat",
    "UnsupportedStreamingSize",
    "LimitExceeded",
)

AU_HEADER_LEN = 24
# The writer's header: the 24 header bytes, then 8 zero annotation bytes, which
# is what FFmpeg's AU muxer writes when there is no metadata.
AU_CANONICAL_ANNOTATION = bytes(8)
AU_UNKNOWN_SIZE = 0xFFFFFFFF
AU_MAX_DATA = 0x7FFFFFFF
AU_MAX_ANNOTATION = 1 << 20
AU_PCM_S16BE = 3
# The PCM encodings of au.c's tag table (T22a): codec -> (encoding, bytes per
# sample, storage). 23 to 26 are G.72x, which wait for T31c.
AU_CODECS = {
    "pcm_mulaw": (1, 1, "s16"),
    "pcm_s8": (2, 1, "u8"),
    "pcm_s16be": (3, 2, "s16"),
    "pcm_s24be": (4, 3, "s32"),
    "pcm_s32be": (5, 4, "s32"),
    "pcm_f32be": (6, 4, "flt"),
    "pcm_f64be": (7, 8, "dbl"),
    "pcm_alaw": (27, 1, "s16"),
}


def au_stream(codec, channels, rate, payload):
    """The accepted stream of an AU data payload in any contract encoding."""
    return Stream(codec, channels, rate, AU_CODECS[codec][2], decode_stored(codec, payload))


def be32(value):
    return struct.pack(">I", value)


def pcm_be(samples):
    return b"".join(struct.pack(">h", s) for s in samples)


def au(data=b"", channels=1, rate=8000, encoding=AU_PCM_S16BE,
       annotation=AU_CANONICAL_ANNOTATION, offset=None, size=None):
    """An AU file. `offset` and `size` override the declared header size and data size."""
    declared_offset = AU_HEADER_LEN + len(annotation) if offset is None else offset
    declared_size = len(data) if size is None else size
    header = b".snd" + be32(declared_offset) + be32(declared_size) + be32(encoding) + be32(rate) + be32(channels)
    return header + annotation + data


def build_au_fixtures():
    canonical = au(pcm_be(MONO))
    fx = []

    def ok(name, group, rule, data, channels, rate, samples, writer_output=False):
        fx.append(accepted(name, group, rule, data, channels, rate, samples, writer_output, codec="pcm_s16be"))

    def bad(name, group, rule, data, error):
        assert error in AU_ERRORS, error
        fx.append(Fixture(name, group, rule, data, reject=error))

    # Accepted.
    ok("au_mono_8k", "accepted",
       "Canonical writer output: 24-byte header, 8 zero annotation bytes, encoding 3, 8 kHz mono.",
       canonical, 1, 8000, MONO, writer_output=True)
    ok("au_stereo_44k1", "accepted", "Canonical stereo at 44.1 kHz; samples interleave left/right.",
       au(pcm_be(STEREO), channels=2, rate=44100), 2, 44100, STEREO, writer_output=True)
    ok("au_mono_192k_rate_limit", "accepted", "Sample rate exactly at the 192,000 Hz limit.",
       au(pcm_be(MONO[:4]), rate=MAX_RATE), 1, MAX_RATE, MONO[:4], writer_output=True)
    ok("au_empty_data", "accepted",
       "Data size 0 is an empty stream. FFmpeg's content probe needs a nonzero data size, so it does "
       "not detect this file; forced with `-f au` it reads it.",
       au(), 1, 8000, [], writer_output=True)
    ok("au_header_24", "accepted", "Data offset 24: the minimal header, with no annotation.",
       au(pcm_be(MONO[:4]), annotation=b""), 1, 8000, MONO[:4])
    ok("au_annotation_text", "accepted",
       "A 16-byte text annotation (offset 40) is skipped and ignored; FFmpeg reads it as metadata.",
       au(pcm_be(MONO[:4]), annotation=b"title=AU test\0\0\0"), 1, 8000, MONO[:4])
    ok("au_annotation_odd_length", "accepted",
       "A 5-byte annotation (offset 29): the data offset needs no alignment.",
       au(pcm_be(MONO[:4]), annotation=b"note\0"), 1, 8000, MONO[:4])
    ok("au_one_frame_stereo", "accepted", "One stereo frame holding both extrema, at 48 kHz.",
       au(pcm_be([32767, -32768]), channels=2, rate=48000), 2, 48000, [32767, -32768])
    ok("au_trailing_bytes_after_data", "accepted",
       "Two samples after the declared data are ignored and never read. FFmpeg decodes them.",
       au(pcm_be(MONO[:4])) + pcm_be([7, -7]), 1, 8000, MONO[:4])

    # The other encodings (T22a), each as the writer emits it.
    def encoded(name, rule, codec, channels, payload, rate=8000):
        fixture = Fixture(name, "encodings", rule, au(payload, channels=channels, rate=rate,
                                                      encoding=AU_CODECS[codec][0]),
                          accept=au_stream(codec, channels, rate, payload), writer_output=True)
        fx.append(fixture)

    def be_values(fmt, values):
        return b"".join(struct.pack(fmt, v) for v in values)

    s24_values = [0, 1, -1, 0x7FFFFF, -0x800000, 123456, -654321, 256]
    encoded("au_mulaw_mono_8k", "Encoding 1, µ-law; decodes to s16. Its negative zero (0x7F) is left out, as "
            "for WAV: every encoder writes zero as 0xFF.", "pcm_mulaw", 1,
            bytes([0xFF, 0x70, 0x80, 0x00, 0x01, 0x81, 0xFE, 0x7E]))
    encoded("au_s8_mono_8k", "Encoding 2, signed 8-bit; stored as u8, offset by 128, as FFmpeg's decoder does.",
            "pcm_s8", 1, bytes([0x00, 0x7F, 0x80, 0xFF, 0x01, 0x81, 0x40, 0xC0]))
    encoded("au_s24_stereo", "Encoding 4, 24-bit big-endian; stored as s32 in the top 24 bits.", "pcm_s24be", 2,
            b"".join(struct.pack(">i", v)[1:] for v in s24_values))
    encoded("au_s32_mono", "Encoding 5, 32-bit big-endian.", "pcm_s32be", 1,
            be_values(">i", [0, 1, -1, 0x7FFFFFFF, -0x80000000, 123456789, -987654321, 65536]))
    encoded("au_f32_mono", "Encoding 6, 32-bit float; every bit kept, NaN payload included.", "pcm_f32be", 1,
            be_values(">I", [0, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x7F800000, 1, 0x7FC00001]))
    encoded("au_f64_stereo_96k", "Encoding 7, 64-bit float, at 96 kHz.", "pcm_f64be", 2,
            be_values(">Q", [0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
                             0x7FF0000000000000, 1, 0x7FF8000000000001, 0x3FE0000000000000]), rate=96000)
    encoded("au_alaw_mono_8k", "Encoding 27, A-law; decodes to s16.", "pcm_alaw", 1,
            bytes([0xD5, 0x55, 0xAA, 0x2A, 0x00, 0x80, 0x7F, 0xFF]))

    # Header.
    bad("au_empty_input", "header", "Zero-byte input.", b"", "Truncated")
    bad("au_truncated_header", "header", "Input ends inside the 24-byte header.", canonical[:20], "Truncated")
    bad("au_bad_magic", "header", "Magic `.sne` instead of `.snd`.", b".sne" + canonical[4:], "InvalidAu")
    bad("au_offset_too_small", "header",
        "Data offset 16 is below the 24-byte header. FFmpeg ignores it and reads data from byte 24.",
        au(pcm_be(MONO[:4]), annotation=b"", offset=16), "InvalidAu")
    bad("au_annotation_over_limit", "limits",
        f"Data offset {AU_HEADER_LEN + AU_MAX_ANNOTATION + 1} declares one byte more than the "
        f"{AU_MAX_ANNOTATION:,}-byte annotation limit; rejected from the header, before any annotation is read.",
        au(pcm_be(MONO[:4]), annotation=b"", offset=AU_HEADER_LEN + AU_MAX_ANNOTATION + 1), "LimitExceeded")
    bad("au_truncated_annotation", "header", "Data offset 40, but input ends after 8 annotation bytes.",
        au(annotation=bytes(8), offset=40, size=8), "Truncated")

    # Data size.
    def unknown(name, rule, data, accept=None, reject=None):
        fx.append(Fixture(name, "size", rule, data, reject="UnsupportedStreamingSize",
                          unknown_accept=accept, unknown_reject=reject))

    unknown("au_unknown_size",
            "Data size 0xffffffff, unknown length, as FFmpeg's muxer writes to a pipe: with `unknown_length` the "
            "data is the rest of the input (T22a).",
            au(pcm_be(MONO[:4]), size=AU_UNKNOWN_SIZE), accept=au_stream("pcm_s16be", 1, 8000, pcm_be(MONO[:4])))
    unknown("au_unknown_size_mulaw", "Unknown length with 3 µ-law frames: any byte count is whole frames.",
            au(bytes([0xFF, 0x80, 0x00]), size=AU_UNKNOWN_SIZE, encoding=1),
            accept=au_stream("pcm_mulaw", 1, 8000, bytes([0xFF, 0x80, 0x00])))
    unknown("au_unknown_size_partial_frame", "Unknown length, stereo, ending after 1.5 frames.",
            au(pcm_be(STEREO[:3]), channels=2, size=AU_UNKNOWN_SIZE), reject="Truncated")
    bad("au_data_size_over_limit", "limits",
        f"Data size 0x80000000 is above the 0x{AU_MAX_DATA:08x} limit that FFmpeg's signed read also enforces.",
        au(pcm_be(MONO[:4]), size=AU_MAX_DATA + 1), "LimitExceeded")
    bad("au_data_not_block_aligned", "size", "Stereo data size 6 ends inside a frame.",
        au(pcm_be(STEREO[:3]), channels=2), "InvalidFormat")
    bad("au_s24_data_not_block_aligned", "size", "24-bit mono data size 4: frames follow the encoding's width.",
        au(bytes(4), encoding=4), "InvalidFormat")
    bad("au_truncated_data", "size", "Data size 16, but input ends after 10 data bytes.",
        au(pcm_be(MONO[:5]), size=16), "Truncated")
    bad("au_truncated_mid_sample", "size", "Data size 8, but input ends inside the third sample.",
        au(pcm_be(MONO[:4])[:5], size=8), "Truncated")

    # Encoding, rate and channels.
    bad("au_encoding_g726", "format", "Encoding 23 (4-bit G.726) waits for T31c.",
        au(bytes(4), encoding=23), "UnsupportedFormat")
    bad("au_encoding_unknown", "format", "Encoding 99 is not an AU encoding.",
        au(bytes(4), encoding=99), "UnsupportedFormat")
    bad("au_rate_zero", "format", "Sample rate 0.", au(pcm_be(MONO[:4]), rate=0), "InvalidFormat")
    bad("au_rate_over_limit", "limits", f"Sample rate {MAX_RATE + 1}, one above the limit.",
        au(pcm_be(MONO[:4]), rate=MAX_RATE + 1), "LimitExceeded")
    bad("au_channels_zero", "format", "Zero channels.", au(pcm_be(MONO[:4]), channels=0), "InvalidFormat")
    # Channels (T23b): any count up to the limit, in an unspecified layout,
    # since the header holds only the count.
    ok("au_channels3", "channels",
       "Three channels: the layout is unspecified, as for every AU stream (rejected before T23b).",
       au(pcm_be(MONO[:6]), channels=3), 3, 8000, MONO[:6])
    six = MONO + MONO[:4]
    ok("au_channels6", "channels",
       "Six channels, written back the same way; FFmpeg's command line guesses 5.1 for them.",
       au(pcm_be(six), channels=6), 6, 8000, six, writer_output=True)
    wide = [i - 32 for i in range(MAX_CHANNELS)]
    ok("au_channels64", "channels", f"{MAX_CHANNELS} channels, the default limit: one frame.",
       au(pcm_be(wide), channels=MAX_CHANNELS), MAX_CHANNELS, 8000, wide)
    bad("au_channels65", "channels",
        f"{MAX_CHANNELS + 1} channels, above the default limit (FFmpeg reads them).",
        au(bytes(2 * (MAX_CHANNELS + 1)), channels=MAX_CHANNELS + 1), "LimitExceeded")

    # Precedence: the first violated field in header order wins.
    bad("au_limit_before_unsupported", "precedence",
        "Data size over the limit and encoding 99: the data size field comes first.",
        au(bytes(4), encoding=99, size=AU_MAX_DATA + 1), "LimitExceeded")
    bad("au_unsupported_before_invalid", "precedence",
        "Encoding 24 (G.722) and sample rate 0: the encoding field comes first. (Before T22a it used "
        "encoding 6, now supported.)",
        au(bytes(4), encoding=24, rate=0), "UnsupportedFormat")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate AU fixture names"
    return with_layouts(fx, lambda data, stream: "unknown")


# --- AIFF fixtures (T22b) ----------------------------------------------------

AIFF_ERRORS = (
    "InvalidAiff",
    "InvalidFormat",
    "Truncated",
    "UnsupportedFormat",
    "LimitExceeded",
)
AIFC_VERSION1 = 0xA2805140
# The writer's encodings: codec -> (compression type, sample size, storage).
# "NONE" is plain AIFF; the others are AIFF-C, as FFmpeg's ff_codec_aiff_tags
# picks them (first match per codec).
AIFF_CODECS = {
    "pcm_s8": (b"NONE", 8, "u8"),
    "pcm_s16be": (b"NONE", 16, "s16"),
    "pcm_s24be": (b"NONE", 24, "s32"),
    "pcm_s32be": (b"NONE", 32, "s32"),
    "pcm_u8": (b"raw ", 8, "u8"),
    "pcm_s16le": (b"sowt", 16, "s16"),
    "pcm_f32be": (b"fl32", 32, "flt"),
    "pcm_f64be": (b"fl64", 64, "dbl"),
    "pcm_alaw": (b"alaw", 8, "s16"),
    "pcm_mulaw": (b"ulaw", 8, "s16"),
}


def be16(value):
    return struct.pack(">H", value)


def ieee_extended(rate):
    """The 80-bit extended form of a positive integer rate."""
    top = rate.bit_length() - 1
    return be16(16383 + top) + struct.pack(">Q", rate << (63 - top))


def iff_chunk(chunk_id, body, size=None, pad=True):
    """A big-endian IFF chunk. `size` overrides the declared size; odd bodies get a pad byte."""
    assert len(chunk_id) == 4
    out = chunk_id + be32(len(body) if size is None else size) + body
    if pad and len(body) % 2:
        out += b"\0"
    return out


def comm_chunk(channels=1, frames=4, bits=16, rate=8000, compression=None, rate_bytes=None, size=None):
    body = be16(channels) + be32(frames) + be16(bits) + (rate_bytes or ieee_extended(rate))
    if compression is not None:
        body += compression + b"\0\0"  # an empty Pascal-string name and its pad
    return iff_chunk(b"COMM", body, size=size)


def ssnd_chunk(data, offset=0, size=None, pad=True):
    return iff_chunk(b"SSND", be32(offset) + be32(0) + bytes(offset) + data, size=size, pad=pad)


def form(*chunks, form_type=b"AIFF", size=None, size_delta=0):
    """A FORM file. `size` overrides the FORM size; `size_delta` adjusts the computed one."""
    rest = form_type + b"".join(chunks)
    declared = len(rest) + size_delta if size is None else size
    return b"FORM" + be32(declared) + rest


# Apple's channel layout tags (T23b): the tag number shifted by 16 and the
# channel count, from Core Audio's CoreAudioBaseTypes.h, which FFmpeg's
# mov_chan.h restates.
CHAN_USE_DESCRIPTIONS = 0
CHAN_USE_BITMAP = 1 << 16
CHAN_QUADRAPHONIC = 108 << 16 | 4
CHAN_MPEG_5_1_A = 121 << 16 | 6  # L R C LFE Ls Rs


def chan_chunk(tag=CHAN_USE_DESCRIPTIONS, bitmap=0, labels=(), count=None, size=None):
    """A `CHAN` chunk: the layout tag, the bitmap, the description count, then
    a 20-byte description per Core Audio label (flags and coordinates 0)."""
    body = be32(tag) + be32(bitmap) + be32(len(labels) if count is None else count)
    body += b"".join(be32(label) + bytes(16) for label in labels)
    return iff_chunk(b"CHAN", body, size=size)


def canonical_aiff(codec, channels, rate, data, chan=None):
    """The writer's output: plain AIFF for the NONE encodings, else AIFF-C with
    FVER, a 24-byte COMM holding the compression type, then SSND. FFmpeg's
    muxer puts `chan`, a CHAN chunk for a native layout of more than two
    channels, after COMM."""
    compression, bits, _ = AIFF_CODECS[codec]
    frames = len(data) // (channels * bits // 8)
    after_comm = [chan] if chan is not None else []
    if compression == b"NONE":
        return form(comm_chunk(channels, frames, bits, rate), *after_comm, ssnd_chunk(data))
    return form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(channels, frames, bits, rate, compression),
                *after_comm, ssnd_chunk(data), form_type=b"AIFC")


def aiff_stream(codec, channels, rate, payload):
    return Stream(codec, channels, rate, AIFF_CODECS[codec][2], decode_stored(codec, payload))


def build_aiff_fixtures():
    fx = []

    def ok(name, group, rule, data, codec, channels, rate, payload, writer_output=False, layout=None):
        stream = aiff_stream(codec, channels, rate, payload)
        stream.layout = layout
        fx.append(Fixture(name, group, rule, data, accept=stream, writer_output=writer_output))

    def bad(name, group, rule, data, error):
        assert error in AIFF_ERRORS, error
        fx.append(Fixture(name, group, rule, data, reject=error))

    def be_values(fmt, values):
        return b"".join(struct.pack(fmt, v) for v in values)

    s16 = be_values(">h", MONO)
    stereo = be_values(">h", STEREO)
    s24 = b"".join(struct.pack(">i", v)[1:] for v in [0, 1, -1, 0x7FFFFF, -0x800000, 123456, -654321, 256])
    f32 = be_values(">I", [0, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x7F800000, 1, 0x7FC00001])
    f64 = be_values(">Q", [0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
                           0x7FF0000000000000, 1, 0x7FF8000000000001, 0x3FE0000000000000])
    alaw = bytes([0xD5, 0x55, 0xAA, 0x2A, 0x00, 0x80, 0x7F, 0xFF])
    mulaw = bytes([0xFF, 0x70, 0x80, 0x00, 0x01, 0x81, 0xFE, 0x7E])

    # Writer output: every encoding as FFmpeg's muxer writes it.
    for name, codec, channels, rate, payload, rule in [
        ("aiff_mono_8k", "pcm_s16be", 1, 8000, s16, "Plain AIFF, 16-bit mono: FORM, an 18-byte COMM, SSND."),
        ("aiff_stereo_44k1", "pcm_s16be", 2, 44100, stereo, "16-bit stereo at 44.1 kHz."),
        ("aiff_s8_mono", "pcm_s8", 1, 8000, bytes([0x00, 0x7F, 0x80, 0xFF, 0x01, 0x81, 0x40, 0xC0]),
         "8-bit samples are signed in AIFF; stored as u8, offset by 128."),
        ("aiff_s24_stereo", "pcm_s24be", 2, 48000, s24, "24-bit stereo at 48 kHz; stored as s32."),
        ("aiff_s32_mono", "pcm_s32be", 1, 8000,
         be_values(">i", [0, 1, -1, 0x7FFFFFFF, -0x80000000, 123456789, -987654321, 65536]), "32-bit mono."),
        ("aiff_empty", "pcm_s16be", 1, 8000, b"", "No frames: SSND holds only its offset and block size."),
        ("aifc_u8_raw", "pcm_u8", 1, 8000, bytes([0x00, 0x80, 0xFF, 0x7F, 0x01, 0x81, 0x40, 0xC0]),
         "AIFF-C `raw `: unsigned 8-bit, with FVER and a 24-byte COMM."),
        ("aifc_sowt", "pcm_s16le", 1, 8000, pcm(MONO), "AIFF-C `sowt`: 16-bit little-endian."),
        ("aifc_fl32", "pcm_f32be", 1, 8000, f32, "AIFF-C `fl32`: 32-bit float; every bit kept."),
        ("aifc_fl64_stereo_96k", "pcm_f64be", 2, 96000, f64, "AIFF-C `fl64` at 96 kHz."),
        ("aifc_alaw", "pcm_alaw", 1, 8000, alaw, "AIFF-C `alaw`, COMM sample size 8; decodes to s16."),
        ("aifc_ulaw", "pcm_mulaw", 1, 8000, mulaw,
         "AIFF-C `ulaw`; its negative zero (0x7F) is left out, as for WAV and AU."),
    ]:
        ok(name, "writer", rule, canonical_aiff(codec, channels, rate, payload), codec, channels, rate, payload,
           writer_output=True)

    comm = comm_chunk()
    four = s16[:8]
    # Other accepted layouts.
    ok("aifc_none_twos", "accepted", "AIFF-C `twos` with 24-bit samples: the codec follows the sample size.",
       form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(bits=24, compression=b"twos"), ssnd_chunk(s24[:12]),
            form_type=b"AIFC"), "pcm_s24be", 1, 8000, s24[:12])
    ok("aifc_uppercase_type", "accepted", "`FL32` matches `fl32`: types compare case-insensitively, as in FFmpeg.",
       form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(bits=32, compression=b"FL32"), ssnd_chunk(f32[:16]),
            form_type=b"AIFC"), "pcm_f32be", 1, 8000, f32[:16])
    ok("aifc_in24", "accepted", "AIFF-C `in24` is 24-bit big-endian, whatever the sample size says.",
       form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(bits=16, compression=b"in24"), ssnd_chunk(s24[:12]),
            form_type=b"AIFC"), "pcm_s24be", 1, 8000, s24[:12])
    ok("aifc_short_comm", "accepted", "AIFF-C with an 18-byte COMM, no room for a type: read as plain AIFF.",
       form(comm, ssnd_chunk(four), form_type=b"AIFC"), "pcm_s16be", 1, 8000, four)
    ok("aifc_without_fver_version", "accepted",
       "An FVER that is not version 1 makes COMM carry no type: its `fl32` is ignored and 32 bits read as s32.",
       form(iff_chunk(b"FVER", be32(0)), comm_chunk(bits=32, compression=b"fl32"), ssnd_chunk(f32[:16]),
            form_type=b"AIFC"), "pcm_s32be", 1, 8000, f32[:16])
    ok("aiff_ssnd_offset", "accepted", "SSND with a data offset of 4: the 4 bytes before the samples are skipped.",
       form(comm, ssnd_chunk(four, offset=4)), "pcm_s16be", 1, 8000, four)
    ok("aiff_other_chunks", "accepted",
       "NAME, an odd-sized ANNO and a chunk after SSND are skipped with their pad bytes.",
       form(iff_chunk(b"NAME", b"Title"), comm, iff_chunk(b"ANNO", b"odd"), ssnd_chunk(four), iff_chunk(b"APPL", b"x")),
       "pcm_s16be", 1, 8000, four)
    ok("aiff_odd_data", "accepted", "Three s8 frames: SSND is odd and a pad byte follows it.",
       form(comm_chunk(frames=3, bits=8), ssnd_chunk(b"\x01\x02\x03")), "pcm_s8", 1, 8000, b"\x01\x02\x03",
       writer_output=True)
    ok("aiff_rate_fraction", "accepted", "An 80-bit rate of 8000.5 Hz rounds half up to 8001, as FFmpeg's does.",
       form(comm_chunk(rate_bytes=bytes.fromhex("400bfa04000000000000")), ssnd_chunk(four)),
       "pcm_s16be", 1, 8001, four)

    # Rejected.
    bad("aiff_empty_input", "header", "No bytes at all.", b"", "Truncated")
    bad("aiff_not_form", "header", "The file starts with `RIFF`, not `FORM`.",
        b"RIFF" + form(comm, ssnd_chunk(four))[4:], "InvalidAiff")
    bad("aiff_bad_form_type", "header", "FORM type `WAVE`.", form(comm, ssnd_chunk(four), form_type=b"WAVE"), "InvalidAiff")
    bad("aiff_form_size_small", "header", "FORM size 2 cannot hold the form type.", form(comm, size=2), "InvalidAiff")
    bad("aiff_truncated_header", "header", "Input ends inside the 12-byte FORM header.", form(comm)[:10], "Truncated")
    bad("aiff_missing_ssnd", "order", "COMM, but no SSND within the FORM extent.", form(comm), "InvalidAiff")
    bad("aiff_ssnd_before_comm", "order",
        "SSND before COMM: a sequential reader cannot know the format. FFmpeg reads it from a seekable file.",
        form(ssnd_chunk(four), comm), "InvalidAiff")
    bad("aiff_duplicate_comm", "order", "Two COMM chunks.", form(comm, comm, ssnd_chunk(four)), "InvalidAiff")
    bad("aiff_comm_short", "comm", "A COMM chunk declaring 16 bytes.",
        form(iff_chunk(b"COMM", comm[8:24]), ssnd_chunk(four)), "InvalidFormat")
    bad("aiff_truncated_comm", "comm", "Input ends inside COMM.", form(comm, ssnd_chunk(four))[:24], "Truncated")
    bad("aiff_channels0", "comm", "Zero channels.", form(comm_chunk(channels=0), ssnd_chunk(b"")), "InvalidFormat")
    # Channels and layouts (T23b): any count up to the limit, unspecified
    # unless a CHAN chunk before SSND gives a layout, as FFmpeg reads it.
    ok("aiff_channels3", "channels", "Three channels without CHAN: unspecified (rejected before T23b).",
       form(comm_chunk(channels=3, frames=2), ssnd_chunk(s16[:12])), "pcm_s16be", 3, 8000, s16[:12])
    six = s16 + s16[:8]
    ok("aiff_channels6", "channels",
       "Six channels without CHAN, written back the same way; FFmpeg's command line guesses 5.1 for them.",
       canonical_aiff("pcm_s16be", 6, 8000, six), "pcm_s16be", 6, 8000, six, writer_output=True)
    wide = be_values(">h", [i - 32 for i in range(MAX_CHANNELS)])
    ok("aiff_channels64", "channels", f"{MAX_CHANNELS} channels, the default limit: one frame.",
       form(comm_chunk(channels=MAX_CHANNELS, frames=1), ssnd_chunk(wide)), "pcm_s16be", MAX_CHANNELS, 8000, wide)
    bad("aiff_channels65", "channels", f"{MAX_CHANNELS + 1} channels, above the default limit (FFmpeg reads them).",
        form(comm_chunk(channels=MAX_CHANNELS + 1, frames=1), ssnd_chunk(bytes(2 * (MAX_CHANNELS + 1)))),
        "LimitExceeded")
    ok("aiff_chan_5point1", "channels",
       "CHAN with the tag MPEG_5_1_A (L, R, C, LFE, Ls, Rs) after COMM: 5.1(side), as FFmpeg's muxer writes it.",
       canonical_aiff("pcm_s16be", 6, 8000, six, chan=chan_chunk(CHAN_MPEG_5_1_A)), "pcm_s16be", 6, 8000, six,
       writer_output=True, layout=describe_mask(channel_bits("FL", "FR", "FC", "LFE", "SL", "SR")))
    six_one = channel_bits("FL", "FR", "FC", "LFE", "BC", "SL", "SR")
    ok("aiff_chan_bitmap", "channels",
       "CHAN with a channel bitmap, 6.1, which no tag names, as FFmpeg's muxer writes it in AIFF-C `sowt`.",
       canonical_aiff("pcm_s16le", 7, 8000, pcm(MONO + MONO[:6]),
                      chan=chan_chunk(CHAN_USE_BITMAP, bitmap=six_one)), "pcm_s16le", 7, 8000,
       pcm(MONO + MONO[:6]), writer_output=True, layout=describe_mask(six_one))
    ok("aiff_chan_descriptions", "channels",
       "CHAN with channel descriptions C, L, R: a custom order, as FFmpeg reads it.",
       form(comm_chunk(channels=3, frames=2), chan_chunk(labels=(3, 1, 2)), ssnd_chunk(s16[:12])),
       "pcm_s16be", 3, 8000, s16[:12], layout="3 channels (FC+FL+FR)")
    ok("aiff_chan_before_comm", "channels",
       "CHAN (the quadraphonic tag) before COMM: the tag's count must be COMM's, as FFmpeg checks.",
       form(chan_chunk(CHAN_QUADRAPHONIC), comm_chunk(channels=4, frames=2), ssnd_chunk(s16[:16])),
       "pcm_s16be", 4, 8000, s16[:16], layout=describe_mask(channel_bits("FL", "FR", "BL", "BR")))
    ok("aiff_chan_count_mismatch", "channels",
       "CHAN with a six-channel tag on a four-channel stream is ignored, as FFmpeg ignores it.",
       form(comm_chunk(channels=4, frames=2), chan_chunk(CHAN_MPEG_5_1_A), ssnd_chunk(s16[:16])),
       "pcm_s16be", 4, 8000, s16[:16])
    ok("aiff_chan_after_ssnd", "channels",
       "CHAN after SSND is not read: a sequential reader has reported the stream by then. FFmpeg reads it "
       "from a seekable file.",
       form(comm_chunk(channels=4, frames=2), ssnd_chunk(s16[:16]), chan_chunk(CHAN_QUADRAPHONIC)),
       "pcm_s16be", 4, 8000, s16[:16])
    bad("aiff_chan_before_comm_mismatch", "channels",
        "CHAN (a four-channel tag) before a two-channel COMM: FFmpeg rejects it too.",
        form(chan_chunk(CHAN_QUADRAPHONIC), comm_chunk(channels=2, frames=2), ssnd_chunk(s16[:8])),
        "InvalidFormat")
    bad("aiff_chan_short", "channels", "A CHAN chunk of 8 bytes, short of the 12 fixed ones: FFmpeg rejects it too.",
        form(comm, iff_chunk(b"CHAN", bytes(8)), ssnd_chunk(four)), "InvalidFormat")
    bad("aiff_chan_too_few_descriptions", "channels",
        "One channel description for two channels: FFmpeg rejects it too.",
        form(comm_chunk(channels=2, frames=2), chan_chunk(labels=(1,)), ssnd_chunk(s16[:8])), "InvalidFormat")
    bad("aiff_chan_descriptions_overflow", "channels",
        "CHAN declaring two descriptions in room for one. FFmpeg keeps the layout and reads on from the "
        "middle of the chunk.",
        form(comm_chunk(channels=2, frames=2), chan_chunk(labels=(1,), count=2), ssnd_chunk(s16[:8])),
        "InvalidFormat")
    bad("aiff_rate_zero", "comm", "An 80-bit rate of 0.", form(comm_chunk(rate_bytes=bytes(10)), ssnd_chunk(four)),
        "InvalidFormat")
    bad("aiff_rate_exponent", "comm", "An 80-bit rate whose exponent needs a shift beyond 63.",
        form(comm_chunk(rate_bytes=bytes.fromhex("7fff8000000000000000")), ssnd_chunk(four)), "InvalidFormat")
    bad("aiff_rate_over_limit", "comm", f"Sample rate {MAX_RATE + 1} Hz, above the default limit.",
        form(comm_chunk(rate=MAX_RATE + 1), ssnd_chunk(four)), "LimitExceeded")
    bad("aiff_bits12", "comm", "12-bit samples: whole bytes only. FFmpeg rounds them up to 16.",
        form(comm_chunk(bits=12), ssnd_chunk(four)), "UnsupportedFormat")
    bad("aifc_unknown_type", "comm", "AIFF-C type `ima4` (IMA ADPCM) is not a contract encoding.",
        form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(compression=b"ima4"), ssnd_chunk(four),
             form_type=b"AIFC"), "UnsupportedFormat")
    bad("aiff_frames_mismatch", "sound", "COMM declares 5 frames, SSND holds 4. FFmpeg decodes the 4.",
        form(comm_chunk(frames=5), ssnd_chunk(four)), "InvalidFormat")
    bad("aiff_data_not_block_aligned", "sound", "Stereo 16-bit data of 6 bytes.",
        form(comm_chunk(channels=2, frames=1), ssnd_chunk(stereo[:6])), "InvalidFormat")
    bad("aiff_ssnd_short", "sound", "An SSND declaring 4 bytes, less than its offset and block size.",
        form(comm, iff_chunk(b"SSND", be32(0)), ssnd_chunk(four)), "InvalidAiff")
    bad("aiff_ssnd_offset_too_big", "sound", "A data offset past the end of SSND.",
        form(comm, iff_chunk(b"SSND", be32(100) + be32(0) + four)), "InvalidAiff")
    bad("aiff_chunk_exceeds_form", "bounds", "SSND declares more bytes than the FORM extent has left.",
        form(comm, ssnd_chunk(four, size=200)), "InvalidAiff")
    bad("aiff_truncated_data", "bounds", "Input ends inside the samples.",
        form(comm, ssnd_chunk(four))[:-3], "Truncated")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate AIFF fixture names"
    return with_layouts(fx, lambda data, stream: "unknown")


# --- raw PCM fixtures (T22c) -------------------------------------------------

RAW_ERRORS = ("InvalidFormat", "Truncated", "LimitExceeded")
# FFmpeg's raw formats for the contract's codecs (pcmdec.c; none for s64):
# format name -> codec. The name is the codec's without `pcm_`.
RAW_FORMATS = {name: f"pcm_{name}" for name in (
    "u8", "s8", "s16le", "s16be", "s24le", "s24be", "s32le", "s32be",
    "f32le", "f32be", "f64le", "f64be", "alaw", "mulaw")}
# Storage of each codec, as FFmpeg's decoder gives it.
CODEC_STORAGE = {**{codec: storage for codec, (_, _, storage) in WAV_CODECS.items()},
                 **{codec: storage for codec, (_, _, storage) in AU_CODECS.items()}}
# FFmpeg's raw demuxer defaults (pcm_options in pcmdec.c).
RAW_DEFAULT_RATE = 44100
RAW_DEFAULT_CHANNELS = 1


# The `-ch_layout` text of mono and stereo.
RAW_LAYOUT_TEXT = {1: "mono", 2: "stereo"}


@dataclasses.dataclass
class RawFixture(Fixture):
    """A raw PCM file and the parameters it is read with (`params` None takes
    FFmpeg's defaults, 44100 Hz mono)."""
    format: str = None
    params: tuple = None  # (sample_rate, channels, the -ch_layout text)


def build_raw_fixtures():
    fx = []

    def full(params):
        """(rate, channels) takes the -ch_layout text of mono or stereo."""
        if params is not None and len(params) == 2:
            return params + (RAW_LAYOUT_TEXT[params[1]],)
        return params

    def stream(fmt, payload, params, layout):
        rate, channels, _ = params or (RAW_DEFAULT_RATE, RAW_DEFAULT_CHANNELS, "mono")
        codec = RAW_FORMATS[fmt]
        accepted = Stream(codec, channels, rate, CODEC_STORAGE[codec], decode_stored(codec, payload))
        accepted.layout = layout
        return accepted

    def ok(name, rule, fmt, payload, params, writer_output=True, layout=None):
        params = full(params)
        fx.append(RawFixture(name, "accepted", rule, payload, accept=stream(fmt, payload, params, layout),
                             writer_output=writer_output, format=fmt, params=params))

    def bad(name, rule, fmt, payload, params, error):
        assert error in RAW_ERRORS, error
        fx.append(RawFixture(name, "rejected", rule, payload, reject=error, format=fmt, params=full(params)))

    def values(fmt, items):
        return b"".join(struct.pack(fmt, v) for v in items)

    s24 = [0, 1, -1, 0x7FFFFF, -0x800000, 123456, -654321, 256]
    s32 = [0, 1, -1, 0x7FFFFFFF, -0x80000000, 123456789, -987654321, 65536]
    f32 = [0, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x7F800000, 1, 0x7FC00001]
    f64 = [0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
           0x7FF0000000000000, 1, 0x7FF8000000000001, 0x3FE0000000000000]

    # One per raw format, read with explicit parameters; each is also writer
    # output, which for raw PCM is the payload itself.
    ok("raw_u8_mono_8k", "Unsigned 8-bit mono at 8 kHz.", "u8",
       bytes([0x00, 0x80, 0xFF, 0x7F, 0x01, 0x81, 0x40, 0xC0]), (8000, 1))
    ok("raw_s8_mono_8k", "Signed 8-bit; stored as u8, offset by 128.", "s8",
       bytes([0x00, 0x7F, 0x80, 0xFF, 0x01, 0x81, 0x40, 0xC0]), (8000, 1))
    ok("raw_s16le_mono_8k", "16-bit little-endian mono.", "s16le", pcm(MONO), (8000, 1))
    ok("raw_s16be_stereo_44k1", "16-bit big-endian stereo at 44.1 kHz.", "s16be", values(">h", STEREO), (44100, 2))
    ok("raw_s24le_stereo_48k", "24-bit little-endian stereo at 48 kHz; stored as s32.", "s24le",
       b"".join(struct.pack("<i", v)[:3] for v in s24), (48000, 2))
    ok("raw_s24be_mono_8k", "24-bit big-endian mono.", "s24be", b"".join(struct.pack(">i", v)[1:] for v in s24),
       (8000, 1))
    ok("raw_s32le_mono_8k", "32-bit little-endian mono.", "s32le", values("<i", s32), (8000, 1))
    ok("raw_s32be_stereo_8k", "32-bit big-endian stereo.", "s32be", values(">i", s32), (8000, 2))
    ok("raw_f32le_mono_8k", "32-bit float little-endian; every bit kept.", "f32le", values("<I", f32), (8000, 1))
    ok("raw_f32be_mono_8k", "32-bit float big-endian.", "f32be", values(">I", f32), (8000, 1))
    ok("raw_f64le_stereo_96k", "64-bit float little-endian stereo at 96 kHz.", "f64le", values("<Q", f64), (96000, 2))
    ok("raw_f64be_mono_8k", "64-bit float big-endian.", "f64be", values(">Q", f64), (8000, 1))
    ok("raw_alaw_mono_8k", "A-law; decodes to s16.", "alaw", bytes([0xD5, 0x55, 0xAA, 0x2A, 0x00, 0x80, 0x7F, 0xFF]),
       (8000, 1))
    ok("raw_mulaw_mono_8k", "µ-law; its negative zero (0x7F) is left out, as for WAV and AU.", "mulaw",
       bytes([0xFF, 0x70, 0x80, 0x00, 0x01, 0x81, 0xFE, 0x7E]), (8000, 1))
    ok("raw_s16le_defaults", "No parameters: FFmpeg's defaults, 44100 Hz mono.", "s16le", pcm(MONO), None,
       writer_output=False)
    ok("raw_empty", "No bytes: an empty stream of 0 frames.", "s16le", b"", (8000, 1))
    # Channel layouts (T23b): any `-ch_layout` FFmpeg parses, up to the limit.
    six = pcm(MONO + MONO[:4])
    ok("raw_s16le_5point1", "Six channels read as `5.1`.", "s16le", six, (8000, 6, "5.1"), layout="5.1")
    ok("raw_s16le_6c", "Six channels read as `6C`, a count only: unspecified, as FFmpeg reads `-ac 6`.", "s16le",
       six, (8000, 6, "6C"), layout="unknown")
    ok("raw_s16le_custom", "Three channels in a custom order, `FC+FL+FR`.", "s16le", pcm(MONO[:6]),
       (8000, 3, "FC+FL+FR"), layout="3 channels (FC+FL+FR)")
    ok("raw_s16le_channels64", f"{MAX_CHANNELS} channels, the default limit: one frame.", "s16le",
       pcm([i - 32 for i in range(MAX_CHANNELS)]), (8000, MAX_CHANNELS, f"{MAX_CHANNELS}C"), layout="unknown")

    # Rejected.
    bad("raw_partial_frame", "Stereo 16-bit, 6 bytes: the input ends inside its second frame. FFmpeg decodes "
        "the whole frame.", "s16le", pcm(STEREO[:3]), (8000, 2), "Truncated")
    bad("raw_partial_sample", "24-bit mono, 4 bytes: the input ends inside its second sample.", "s24le",
        bytes(4), (8000, 1), "Truncated")
    bad("raw_rate_zero", "Sample rate 0.", "s16le", pcm(MONO[:4]), (0, 1), "InvalidFormat")
    bad("raw_rate_over_limit", f"Sample rate {MAX_RATE + 1} Hz, above the default limit.", "s16le",
        pcm(MONO[:4]), (MAX_RATE + 1, 1), "LimitExceeded")
    bad("raw_s16le_channels65", f"{MAX_CHANNELS + 1} channels, above the default limit (FFmpeg reads them).",
        "s16le", bytes(2 * (MAX_CHANNELS + 1)), (8000, MAX_CHANNELS + 1, f"{MAX_CHANNELS + 1}C"), "LimitExceeded")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate raw fixture names"
    return with_layouts(fx, lambda data, stream: describe_mask(CHANNEL_MASK[stream.channels]))


# --- CAF fixtures (T22d) -----------------------------------------------------

CAF_ERRORS = (
    "InvalidCaf",
    "InvalidFormat",
    "Truncated",
    "UnsupportedFormat",
    "UnsupportedStreamingSize",
    "LimitExceeded",
)
CAF_FLOAT = 1
CAF_LITTLE = 2
# Codec -> (format ID, flags, bits per channel), as a CAF writer describes it.
CAF_CODECS = {
    "pcm_s8": (b"lpcm", 0, 8),
    "pcm_s16be": (b"lpcm", 0, 16),
    "pcm_s16le": (b"lpcm", CAF_LITTLE, 16),
    "pcm_s24be": (b"lpcm", 0, 24),
    "pcm_s24le": (b"lpcm", CAF_LITTLE, 24),
    "pcm_s32be": (b"lpcm", 0, 32),
    "pcm_s32le": (b"lpcm", CAF_LITTLE, 32),
    "pcm_s64be": (b"lpcm", 0, 64),
    "pcm_s64le": (b"lpcm", CAF_LITTLE, 64),
    "pcm_f32be": (b"lpcm", CAF_FLOAT, 32),
    "pcm_f32le": (b"lpcm", CAF_FLOAT | CAF_LITTLE, 32),
    "pcm_f64be": (b"lpcm", CAF_FLOAT, 64),
    "pcm_f64le": (b"lpcm", CAF_FLOAT | CAF_LITTLE, 64),
    "pcm_alaw": (b"alaw", 0, 8),
    "pcm_mulaw": (b"ulaw", 0, 8),
}
CAF_STORAGE = {**CODEC_STORAGE, "pcm_s64be": "s64"}


def caf_chunk(chunk_id, body, size=None):
    """A CAF chunk: no padding, a signed 64-bit big-endian size."""
    assert len(chunk_id) == 4
    return chunk_id + struct.pack(">q", len(body) if size is None else size) + body


def caf_desc(rate=8000, format_id=b"lpcm", flags=0, bytes_per_packet=2, frames_per_packet=1, channels=1, bits=16,
             rate_bytes=None):
    body = (rate_bytes or struct.pack(">d", rate)) + format_id + struct.pack(
        ">IIIII", flags, bytes_per_packet, frames_per_packet, channels, bits)
    return caf_chunk(b"desc", body)


def caf_data(payload, size=None, edit_count=0):
    return caf_chunk(b"data", struct.pack(">I", edit_count) + payload, size=size)


def caf(*chunks, magic=b"caff", version=1):
    return magic + struct.pack(">HH", version, 0) + b"".join(chunks)


def caf_chan(tag=0, bitmap=0, labels=(), count=None):
    """A `chan` chunk: the body of AIFF's CHAN (`chan_chunk`), unpadded."""
    body = be32(tag) + be32(bitmap) + be32(len(labels) if count is None else count)
    return caf_chunk(b"chan", body + b"".join(be32(label) + bytes(16) for label in labels))


def caf_for(codec, channels, rate, payload, before=(), after=()):
    format_id, flags, bits = CAF_CODECS[codec]
    width = 1 if bits == 8 else bits // 8
    desc = caf_desc(rate, format_id, flags, width * channels, 1, channels, bits)
    return caf(desc, *before, caf_data(payload), *after)


def build_caf_fixtures():
    fx = []

    def stream(codec, channels, rate, payload):
        return Stream(codec, channels, rate, CAF_STORAGE[codec], decode_stored(codec, payload))

    def ok(name, rule, codec, channels, rate, payload, data=None, group="accepted", layout=None):
        accepted_stream = stream(codec, channels, rate, payload)
        accepted_stream.layout = layout
        fx.append(Fixture(name, group, rule, data or caf_for(codec, channels, rate, payload),
                          accept=accepted_stream))

    def bad(name, group, rule, data, error):
        assert error in CAF_ERRORS, error
        fx.append(Fixture(name, group, rule, data, reject=error))

    def values(fmt, items):
        return b"".join(struct.pack(fmt, v) for v in items)

    s24 = [0, 1, -1, 0x7FFFFF, -0x800000, 123456, -654321, 256]
    s32 = [0, 1, -1, 0x7FFFFFFF, -0x80000000, 123456789, -987654321, 65536]
    s64 = [0, 1, -1, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000, 1 << 40, -(1 << 50), 255]
    f32 = [0, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0x7F800000, 1, 0x7FC00001]
    f64 = [0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
           0x7FF0000000000000, 1, 0x7FF8000000000001, 0x3FE0000000000000]

    # Every encoding.
    ok("caf_s16be_mono_8k", "`lpcm`, big-endian 16-bit mono: the encoding afconvert writes by default.",
       "pcm_s16be", 1, 8000, values(">h", MONO))
    ok("caf_s16le_stereo_44k1", "`lpcm` with the little-endian flag, stereo at 44.1 kHz.", "pcm_s16le", 2, 44100,
       pcm(STEREO))
    ok("caf_s8_mono", "8-bit `lpcm` is signed (FFmpeg passes the signed flag); stored as u8, offset by 128.",
       "pcm_s8", 1, 8000, bytes([0x00, 0x7F, 0x80, 0xFF, 0x01, 0x81, 0x40, 0xC0]))
    ok("caf_s24le_stereo_48k", "24-bit little-endian stereo at 48 kHz; stored as s32.", "pcm_s24le", 2, 48000,
       b"".join(struct.pack("<i", v)[:3] for v in s24))
    ok("caf_s24be_mono", "24-bit big-endian.", "pcm_s24be", 1, 8000, b"".join(struct.pack(">i", v)[1:] for v in s24))
    ok("caf_s32be_mono", "32-bit big-endian.", "pcm_s32be", 1, 8000, values(">i", s32))
    ok("caf_s32le_mono", "32-bit little-endian.", "pcm_s32le", 1, 8000, values("<i", s32))
    ok("caf_s64be_mono", "64-bit big-endian integers.", "pcm_s64be", 1, 8000, values(">q", s64))
    ok("caf_s64le_mono", "64-bit little-endian integers.", "pcm_s64le", 1, 8000, values("<q", s64))
    ok("caf_f32be_mono", "32-bit float (`lpcm` with the float flag); every bit kept.", "pcm_f32be", 1, 8000,
       values(">I", f32))
    ok("caf_f32le_mono", "32-bit float, little-endian.", "pcm_f32le", 1, 8000, values("<I", f32))
    ok("caf_f64be_stereo_96k", "64-bit float stereo at 96 kHz.", "pcm_f64be", 2, 96000, values(">Q", f64))
    ok("caf_f64le_mono", "64-bit float, little-endian.", "pcm_f64le", 1, 8000, values("<Q", f64))
    ok("caf_alaw_mono_8k", "Format ID `alaw`; decodes to s16.", "pcm_alaw", 1, 8000,
       bytes([0xD5, 0x55, 0xAA, 0x2A, 0x00, 0x80, 0x7F, 0xFF]))
    ok("caf_ulaw_mono_8k", "Format ID `ulaw`; decodes to s16.", "pcm_mulaw", 1, 8000,
       bytes([0xFF, 0x70, 0x80, 0x00, 0x01, 0x81, 0xFE, 0x7E]))

    four = values(">h", MONO[:4])
    desc = caf_desc()
    # Other accepted layouts.
    ok("caf_empty_data", "A `data` chunk of 4 bytes, its edit count only: 0 frames.", "pcm_s16be", 1, 8000, b"")
    ok("caf_chunks_around_data", "`free`, `info` and `kuki` before `data` and `free` after it are skipped; "
       "`chan` before it, the mono layout tag, gives the layout (skipped before T23b).",
       "pcm_s16be", 1, 8000, four, layout="mono",
       data=caf(desc, caf_chunk(b"free", bytes(6)), caf_chunk(b"chan", struct.pack(">III", 0x640001, 0, 0)),
                caf_chunk(b"info", b"\0\0\0\x01title\0T\0"), caf_chunk(b"kuki", b"\x01"),
                caf_data(four), caf_chunk(b"free", b"")))
    ok("caf_rate_fraction", "A rate of 8000.75 Hz is truncated to 8000, as FFmpeg's int conversion does.",
       "pcm_s16be", 1, 8000, four, data=caf(caf_desc(rate=8000.75), caf_data(four)))
    ok("caf_edit_count", "A nonzero edit count is skipped.", "pcm_s16be", 1, 8000, four,
       data=caf(desc, caf_data(four, edit_count=7)))

    # Unknown length: data size -1 runs to the end of the input, with the option.
    def unknown(name, rule, data, accept=None, reject=None):
        fx.append(Fixture(name, "size", rule, data, reject="UnsupportedStreamingSize",
                          unknown_accept=accept, unknown_reject=reject))

    unknown("caf_data_size_unknown", "`data` size -1, as a writer that could not seek back leaves it: with "
            "`unknown_length` the data is the rest of the input.", caf(desc, caf_data(four, size=-1)),
            accept=stream("pcm_s16be", 1, 8000, four))
    unknown("caf_unknown_size_partial_frame", "Size -1, stereo, ending after 1.5 frames.",
            caf(caf_desc(bytes_per_packet=4, channels=2), caf_data(values(">h", STEREO[:3]), size=-1)),
            reject="Truncated")

    # Header and description.
    bad("caf_empty_input", "header", "No bytes at all.", b"", "Truncated")
    bad("caf_bad_magic", "header", "Magic `cafe`.", caf(desc, caf_data(four), magic=b"cafe"), "InvalidCaf")
    bad("caf_version2", "header", "File version 2: only version 1 exists. FFmpeg's probe rejects it, and its "
        "demuxer, forced, reads it.", caf(desc, caf_data(four), version=2), "InvalidCaf")
    bad("caf_desc_missing", "header", "The first chunk is `free`, not `desc`.",
        caf(caf_chunk(b"free", bytes(32)), desc, caf_data(four)), "InvalidCaf")
    bad("caf_desc_size", "header", "A `desc` chunk of size 36.",
        caf(caf_chunk(b"desc", desc[12:] + bytes(4)), caf_data(four)), "InvalidCaf")
    bad("caf_truncated_desc", "header", "Input ends inside `desc`.", caf(desc)[:30], "Truncated")
    bad("caf_rate_zero", "desc", "Sample rate 0.", caf(caf_desc(rate=0), caf_data(four)), "InvalidFormat")
    bad("caf_rate_nan", "desc", "Sample rate NaN.", caf(caf_desc(rate_bytes=bytes.fromhex("7ff8000000000000")),
                                                        caf_data(four)), "InvalidFormat")
    bad("caf_rate_over_limit", "desc", f"Sample rate {MAX_RATE + 1} Hz, above the default limit.",
        caf(caf_desc(rate=MAX_RATE + 1), caf_data(four)), "LimitExceeded")
    bad("caf_format_aac", "desc", "Format ID `aac ` waits for its decoder.",
        caf(caf_desc(format_id=b"aac ", bytes_per_packet=0, frames_per_packet=1024, bits=0), caf_data(four)),
        "UnsupportedFormat")
    bad("caf_lpcm_bits12", "desc", "12-bit `lpcm`: whole bytes only. FFmpeg rounds up to 16.",
        caf(caf_desc(bits=12), caf_data(four)), "UnsupportedFormat")
    bad("caf_float_bits16", "desc", "A 16-bit float: no codec.", caf(caf_desc(flags=CAF_FLOAT), caf_data(four)),
        "UnsupportedFormat")
    bad("caf_channels0", "desc", "Zero channels.", caf(caf_desc(bytes_per_packet=0, channels=0), caf_data(b"")),
        "InvalidFormat")
    # Channels and layouts (T23b): any count up to the limit, unspecified
    # unless a `chan` chunk before `data` gives a layout, as FFmpeg reads it.
    s16_six = values(">h", MONO + MONO[:4])
    ok("caf_channels3", "Three channels without `chan`: unspecified (rejected before T23b).", "pcm_s16be", 3, 8000,
       values(">h", MONO[:6]), group="channels")
    ok("caf_channels6", "Six channels without `chan`; FFmpeg's command line guesses 5.1 for them.", "pcm_s16be", 6,
       8000, s16_six, group="channels")
    wide = values(">h", [i - 32 for i in range(MAX_CHANNELS)])
    ok("caf_channels64", f"{MAX_CHANNELS} channels, the default limit: one frame.", "pcm_s16be", MAX_CHANNELS, 8000,
       wide, group="channels")
    bad("caf_channels65", "channels", f"{MAX_CHANNELS + 1} channels, above the default limit (FFmpeg reads them).",
        caf_for("pcm_s16be", MAX_CHANNELS + 1, 8000, bytes(2 * (MAX_CHANNELS + 1))), "LimitExceeded")
    ok("caf_chan_5point1", "`chan` with the tag MPEG_5_1_A (L, R, C, LFE, Ls, Rs): 5.1(side).", "pcm_s16be", 6, 8000,
       s16_six, group="channels", layout=describe_mask(channel_bits("FL", "FR", "FC", "LFE", "SL", "SR")),
       data=caf_for("pcm_s16be", 6, 8000, s16_six, before=(caf_chan(CHAN_MPEG_5_1_A),)))
    five_one = channel_bits("FL", "FR", "FC", "LFE", "BL", "BR")
    ok("caf_chan_bitmap", "`chan` with the 5.1 bitmap.", "pcm_s16le", 6, 8000, pcm(MONO + MONO[:4]),
       group="channels", layout=describe_mask(five_one),
       data=caf_for("pcm_s16le", 6, 8000, pcm(MONO + MONO[:4]), before=(caf_chan(CHAN_USE_BITMAP, bitmap=five_one),)))
    ok("caf_chan_descriptions", "`chan` with channel descriptions R, L: a custom order, as FFmpeg reads it.",
       "pcm_s16be", 2, 8000, values(">h", STEREO), group="channels", layout="2 channels (FR+FL)",
       data=caf_for("pcm_s16be", 2, 8000, values(">h", STEREO), before=(caf_chan(labels=(2, 1)),)))
    ok("caf_chan_count_mismatch", "`chan` with a four-channel tag on a stereo stream is ignored, as FFmpeg "
       "ignores it.", "pcm_s16be", 2, 8000, values(">h", STEREO), group="channels",
       data=caf_for("pcm_s16be", 2, 8000, values(">h", STEREO), before=(caf_chan(CHAN_QUADRAPHONIC),)))
    ok("caf_chan_after_data", "`chan` after `data` is skipped: a sequential reader has reported the stream by "
       "then. FFmpeg reads it from a seekable file.", "pcm_s16be", 4, 8000, values(">h", MONO), group="channels",
       data=caf_for("pcm_s16be", 4, 8000, values(">h", MONO), after=(caf_chan(CHAN_QUADRAPHONIC),)))
    bad("caf_chan_short", "channels", "A `chan` of 8 bytes, short of the 12 fixed ones: FFmpeg rejects it too.",
        caf(desc, caf_chunk(b"chan", bytes(8)), caf_data(four)), "InvalidFormat")
    bad("caf_chan_size_negative", "channels", "A `chan` of size -1: FFmpeg rejects it too.",
        caf(desc, caf_chunk(b"chan", b"", size=-1), caf_data(four)), "InvalidCaf")
    bad("caf_chan_descriptions_overflow", "channels",
        "A `chan` declaring two descriptions in room for one. FFmpeg keeps the layout and, on a seekable file, "
        "goes on after the chunk.",
        caf(caf_desc(bytes_per_packet=4, channels=2), caf_chan(labels=(1,), count=2), caf_data(values(">h", STEREO))),
        "InvalidFormat")
    bad("caf_bytes_per_packet", "desc", "4 bytes per packet for 16-bit mono.",
        caf(caf_desc(bytes_per_packet=4), caf_data(four)), "InvalidFormat")
    bad("caf_frames_per_packet", "desc", "2 frames per packet: PCM has one.",
        caf(caf_desc(frames_per_packet=2, bytes_per_packet=4), caf_data(four)), "InvalidFormat")

    # Chunks and data.
    bad("caf_missing_data", "chunks", "`desc`, then the end of the input.", caf(desc), "InvalidCaf")
    bad("caf_truncated_chunk_header", "chunks", "Input ends inside a chunk header.", caf(desc) + b"data\0\0",
        "Truncated")
    bad("caf_chunk_size_negative", "chunks", "A `free` chunk of size -2.",
        caf(desc, caf_chunk(b"free", b"", size=-2), caf_data(four)), "InvalidCaf")
    bad("caf_free_size_unknown", "chunks", "A `free` chunk of size -1: only `data` may have an unknown size.",
        caf(desc, caf_chunk(b"free", b"", size=-1), caf_data(four)), "InvalidCaf")
    bad("caf_pakt", "chunks", "A packet table, with which FFmpeg trims priming and remainder frames.",
        caf(desc, caf_chunk(b"pakt", bytes(24)), caf_data(four)), "UnsupportedFormat")
    bad("caf_data_size_small", "data", "A `data` chunk of size 2, short of its edit count.",
        caf(desc, caf_chunk(b"data", b"\0\0")), "InvalidCaf")
    bad("caf_data_not_whole_frames", "data", "Stereo 16-bit data of 6 bytes. FFmpeg reads the whole frame.",
        caf(caf_desc(bytes_per_packet=4, channels=2), caf_data(values(">h", STEREO[:3]))), "InvalidFormat")
    bad("caf_truncated_data", "data", "Input ends inside the samples.", caf(desc, caf_data(four))[:-3], "Truncated")
    bad("caf_second_data", "data", "A second `data` chunk after the first.",
        caf(desc, caf_data(four), caf_data(four)), "InvalidCaf")
    bad("caf_trailing_partial_header", "data", "5 bytes after `data`: a cut chunk header.",
        caf(desc, caf_data(four)) + b"free\0", "Truncated")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate CAF fixture names"
    return with_layouts(fx, lambda data, stream: "unknown")


# --- outputs ---------------------------------------------------------------


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def zig_string(data):
    """A Zig string literal for arbitrary bytes."""
    escapes = {0x22: '\\"', 0x5C: "\\\\", 0x0A: "\\n", 0x0D: "\\r", 0x09: "\\t"}
    return '"' + "".join(escapes.get(b) or (chr(b) if 0x20 <= b < 0x7F else f"\\x{b:02x}") for b in data) + '"'


def render_expected(accept, reject):
    if accept is None:
        return f".{{ .reject = .{reject} }}"
    # Float samples are bit patterns, clearest in hexadecimal.
    text = (lambda v: f"0x{v:x}") if accept.storage in ("flt", "dbl") else str
    sample_list = "{}" if not accept.stored else "{ " + ", ".join(text(v) for v in accept.stored) + " }"
    return (f".{{ .accept = .{{ .codec = .{accept.codec}, .channels = {accept.channels}, "
            f".layout = {zig_string(accept.layout.encode())}, "
            f".sample_rate = {accept.rate}, .samples = .{{ .{accept.storage} = .{sample_list} }} }} }}")


def mp3_probe_score(buf):
    """mp3dec.c's mp3_read_probe on a probe buffer (T29a): runs of frames
    from every position, a run ending at a header that fails
    ff_mpa_check_header, is free format, or is emulated more than twice
    inside the frame."""
    if len(buf) < 4:
        return 0
    end = len(buf) - 4
    mask = 0xFFFE0CCF
    buf0 = 0
    while buf0 < end and buf[buf0] == 0:
        buf0 += 1
    max_frames = max_framesizes = first_frames = 0
    start = buf0
    while start < end:
        pos, frames, framesizes = start, 0, 0
        while pos < end:
            header = struct.unpack(">I", buf[pos:pos + 4])[0]
            size = mpa_header_frame_size(header)
            if size is None:
                break
            available = min(size, end - pos)
            emu = sum(1 for at in range(pos + 4, pos + available)
                      if struct.unpack(">I", buf[at:at + 4])[0] & mask == header & mask)
            if emu > 2:
                break
            framesizes += size
            if available < size:
                frames += 1
                break
            pos += size
            frames += 1
        max_frames = max(max_frames, frames)
        max_framesizes = max(max_framesizes, framesizes)
        if start == buf0:
            first_frames = frames
        start = pos + 1
    if first_frames >= 7:
        return 52
    if max_frames > 200 and len(buf) < 2 * max_framesizes:
        return 50
    if max_frames >= 4 and len(buf) < 2 * max_framesizes:
        return 25
    head = (buf[buf0:] + bytes(10))[:10]
    if id3v2_match(head) and 2 * id3v2_tag_len(head) >= len(buf):
        return 12 if len(buf) < 1 << 20 else 48
    if max_frames >= 1 and len(buf) < 10 * max_framesizes:
        return 1
    return 0


def mpa_header_frame_size(header):
    """ff_mpegaudio_decode_header's frame size, or None for a header
    ff_mpa_check_header refuses or free format."""
    if header & 0xFFE00000 != 0xFFE00000 or header & (3 << 19) == 1 << 19 or header & (3 << 17) == 0 \
            or header & (0xF << 12) == 0xF << 12 or header & (3 << 10) == 3 << 10:
        return None
    if header & (1 << 20):
        lsf, mpeg25 = (0 if header & (1 << 19) else 1), 0
    else:
        lsf, mpeg25 = 1, 1
    layer = 4 - ((header >> 17) & 3)
    rate = MPA_FREQS[(header >> 10) & 3] >> (lsf + mpeg25)
    index = (header >> 12) & 0xF
    if index == 0:
        return None
    kbps = MPA_BITRATES[lsf][layer - 1][index]
    padding = (header >> 9) & 1
    if layer == 1:
        return (kbps * 12000 // rate + padding) * 4
    if layer == 2:
        return kbps * 144000 // rate + padding
    return kbps * 144000 // (rate << lsf) + padding


def id3v2_match(buf):
    return (len(buf) >= 10 and buf[:3] == b"ID3" and buf[3] != 0xFF and buf[4] != 0xFF
            and all(b & 0x80 == 0 for b in buf[6:10]))


def id3v2_tag_len(buf):
    length = ((buf[6] & 0x7F) << 21) + ((buf[7] & 0x7F) << 14) + ((buf[8] & 0x7F) << 7) + (buf[9] & 0x7F) + 10
    return length + 10 if buf[5] & 0x10 else length


def ffmpeg_probe_round(buf):
    """probe_input_format_internal for one probe buffer, without file names
    (no fixture's extension is a demuxer's): the ID3v2 tags skipped, each
    probe's score, the best one's format (None on a tie) and score."""
    nodat = None
    while len(buf) > 10 and id3v2_match(buf):
        id3len = id3v2_tag_len(buf)
        if len(buf) > id3len + 16:
            buf = buf[id3len:]
        else:
            nodat = "greater" if id3len < 1 << 20 else "greater_max"
            break
    scores = {"wav": 0, "w64": 0, "au": 0, "aiff": 0, "caf": 0, "flac": 0, "mp3": mp3_probe_score(buf)}
    head = buf[:2048]
    if len(head) > 32 and head[8:12] == b"WAVE":
        if head[:4] in (b"RIFF", b"RIFX"):
            scores["wav"] = 99
        elif head[:4] in (b"RF64", b"BW64") and head[12:16] == b"ds64":
            scores["wav"] = 100
    if len(head) > 40 and head[:16] == W64_RIFF_GUID and head[24:40] == w64_guid(b"wave"):
        scores["w64"] = 100
    if len(head) >= 24 and head[:4] == b".snd" and all(head[i:i + 4] != bytes(4) for i in range(4, 24, 4)):
        scores["au"] = 100
    # aiffdec.c reads 12 bytes of the zero-padded probe buffer.
    padded = head + bytes(12)
    if padded[:4] == b"FORM" and struct.unpack(">I", padded[4:8])[0] >= 4 and padded[8:12] in (b"AIFF", b"AIFC"):
        scores["aiff"] = 100
    # cafdec.c reads 20 bytes of the zero-padded buffer.
    padded = head + bytes(20)
    if (padded[:4] == b"caff" and padded[4:6] == b"\x00\x01" and padded[8:12] == b"desc"
            and struct.unpack(">Q", padded[12:20])[0] == 32):
        scores["caf"] = 100
    # flacdec.c's flac_probe and raw_flac_probe (T26a), on the padded buffer.
    padded = head + bytes(32)
    if len(head) and (struct.unpack(">H", padded[:2])[0] & 0xFFFE) == 0xFFF8:
        # The channel bound is FLAC_MAX_CHANNELS + FLAC_CHMODE_MID_SIDE: codes 0 to 10 pass.
        if ((padded[2] & 0xF0) != 0 and (padded[2] & 0x0F) != 0x0F and (padded[3] & 0xF0) < (8 + 3) << 4
                and (padded[3] & 0x06) != 0x06 and (padded[3] & 0x01) == 0):
            scores["flac"] = 50 // 4 + 1
    elif len(head) >= 4 + 4 + 13 and head[:4] == b"fLaC":
        size = int.from_bytes(head[5:8], "big")
        min_block, max_block = struct.unpack(">HH", head[8:12])
        rate = int.from_bytes(head[18:21], "big") >> 4
        if ((head[4] & 0x7F) == 0 and size == 34 and min_block >= 16 and max_block >= min_block
                and 0 < rate <= 655350):
            scores["flac"] = 100
        else:
            scores["flac"] = 50
    best = max(scores.values())
    winners = [name for name, score in scores.items() if score == best]
    if nodat == "greater":
        best = min(24, best)
    return (winners[0] if len(winners) == 1 and best > 0 else None), best


def ffmpeg_detect(data):
    """The format FFmpeg's content probing picks for `data`, or None (T16,
    T29a).

    An independent reading of the probes in wavdec.c (wav_probe, w64_probe),
    au.c (au_probe), aiffdec.c (aiff_probe), cafdec.c (probe), flacdec.c
    (flac_probe, raw_flac_probe) and mp3dec.c (mp3_read_probe), and of
    format.c's choice: probe_input_format_internal skips leading ID3v2 tags,
    the highest nonzero score wins, a tie at the highest means none; and
    av_probe_input_buffer2's rounds, a buffer of 2048 bytes doubled up to
    1 MiB, a winner taken above 25, or above 0 once a read finds nothing
    more or the buffer is at its largest. File-name extensions (T22c) play
    no part: no fixture's extension is a demuxer's."""
    probe_size, offset = 2048, 0
    while True:
        threshold = 25 if probe_size < 1 << 20 else 0
        want = probe_size - offset
        got = min(want, len(data) - offset)
        if got == 0:
            threshold = 0
        offset += got
        fmt, score = ffmpeg_probe_round(data[:offset])
        if score > threshold and fmt is not None:
            return fmt
        if got == 0 or probe_size >= 1 << 20:
            return None
        probe_size = min(probe_size * 2, 1 << 20)


def render_manifest(fixtures, entry_note):
    lines = [
        "// Generated by zig/testing/fixtures/generate.py from its FIXTURES list; do not edit.",
        entry_note,
        ".{",
    ]
    for f in fixtures:
        lines.append("    .{")
        lines.append(f'        .name = "{f.name}",')
        lines.append(f'        .sha256 = "{sha256(f.data)}",')
        lines.append(f"        .expected = {render_expected(f.accept, f.reject)},")
        detected = ffmpeg_detect(f.data)
        lines.append(f"        .detected = {'.' + detected if detected else 'null'},")
        if isinstance(f, RawFixture):
            lines.append(f"        .format = .{f.format},")
            params = "null" if f.params is None else (
                f'.{{ .sample_rate = {f.params[0]}, .channels = {f.params[1]}, .layout = "{f.params[2]}" }}')
            lines.append(f"        .params = {params},")
        if f.writer_output:
            lines.append("        .writer_output = true,")
        if f.writer_header != "riff":
            lines.append(f"        .writer_header = .{f.writer_header},")
        if f.unknown_accept is not None or f.unknown_reject is not None:
            lines.append(f"        .unknown_length = {render_expected(f.unknown_accept, f.unknown_reject)},")
        for field, tags in (("tags", f.tags), ("writer_tags", f.writer_tags)):
            if tags:
                lines.append(f"        .{field} = .{{")
                for key, value in tags:
                    lines.append(f"            .{{ .key = {zig_string(key)}, .value = {zig_string(value)} }},")
                lines.append("        },")
        if f.writer_bext:
            lines.append("        .writer_bext = true,")
        lines.append("    },")
    lines.append("}")
    return ("\n".join(lines) + "\n").encode()


def describe_result(accept, reject):
    if accept is None:
        return f"reject: `{reject}`"
    channels, rate, samples = accept
    count = f"{channels} channel{'s' if channels != 1 else ''}"
    layout = count if accept.layout == "unknown" else f"{accept.layout} ({count})"
    frames = len(samples) // channels
    text = f"accept: {layout}, {rate} Hz, {frames} frame{'s' if frames != 1 else ''}"
    if accept.codec not in ("pcm_s16le", "pcm_s16be"):
        text += f", `{accept.codec}`"
    return text


def describe(f):
    text = describe_result(f.accept, f.reject) + ("; writer output" if f.writer_output else "")
    if isinstance(f, RawFixture):
        params = "defaults" if f.params is None else f"{f.params[0]} Hz, {f.params[1]} channel{'s' if f.params[1] != 1 else ''}"
        text = f"`-f {f.format}`, {params}; " + text
    if f.tags:
        text += f"; {len(f.tags)} tag{'s' if len(f.tags) != 1 else ''}"
    if f.unknown_accept is not None or f.unknown_reject is not None:
        text += f"; with `unknown_length`, {describe_result(f.unknown_accept, f.unknown_reject)}"
    if ffmpeg_detect(f.data) is None:
        text += "; not detected (probing picks no format)"
    return text


def render_table(fixtures, extra_rows=()):
    rows = [
        TABLE_BEGIN,
        "| Fixture | Group | Bytes | Expected | Rule | SHA-256 |\n",
        "| --- | --- | ---: | --- | --- | --- |\n",
    ]
    for f in fixtures:
        rows.append(f"| `{f.name}` | {f.group} | {len(f.data)} | {describe(f)} | {f.rule} | `{sha256(f.data)}` |\n")
    rows.extend(extra_rows)
    rows.append(TABLE_END)
    return "".join(rows)


def large_skip_row():
    large = large_skip_vector()
    return (
        f"| `large_skip_2mib` (synthesized, not committed) | accepted | {len(large)} | accept: mono, 8000 Hz, 4 frames "
        f"| A 2 MiB `LIST` chunk before `data` is skipped; skipped bytes do not count toward the 1 MiB retained "
        f"limit. Build it in the test: `fmt ` as in `mono_8k`, then `LIST` with 2,097,152 zero bytes, then `data` "
        f"with the first 4 `mono_8k` samples. | `{sha256(large)}` |\n"
    )


def render_readme(path, table):
    text = path.read_bytes().decode()
    begin = text.index(TABLE_BEGIN)
    end = text.index(TABLE_END) + len(TABLE_END)
    return (text[:begin] + table + text[end:]).encode()


# --- FLAC fixtures (T26a) -----------------------------------------------------
#
# A FLAC writer built from the format's description (xiph.org's format.html),
# independently of FFmpeg and of the Zig decoder: it writes constant,
# verbatim, fixed and LPC subframes with Rice-coded residuals, every channel
# assignment, wasted bits, and the header's code forms. Each accepted
# fixture records the samples it encodes; the decoder must give them back.
# The flac_ffmpeg_* fixtures are FFmpeg's encoder's output, made by
# zig/testing/reference/flac_fixtures.sh from inputs this script writes
# (--flac-input); they are committed, their hashes are recorded here and
# checked, and their expected samples are their inputs.

FLAC_DIR = HERE / "flac"
FLAC_MANIFEST = FLAC_DIR / "manifest.zon"
FLAC_README = FLAC_DIR / "README.md"

# The contract's errors for FLAC (zig/testing/fixtures.zig FlacFailure).
FLAC_ERRORS = (
    "InvalidFlac",
    "Truncated",
    "UnsupportedFormat",
)


class BitWriter:
    """MSB-first bits."""

    def __init__(self):
        self.value = 0
        self.count = 0

    def put(self, bits, value):
        assert bits >= 0
        if bits:
            assert 0 <= value < (1 << bits), (bits, value)
        self.value = (self.value << bits) | value
        self.count += bits

    def put_signed(self, bits, value):
        assert -(1 << (bits - 1)) <= value < (1 << (bits - 1)), (bits, value)
        self.put(bits, value & ((1 << bits) - 1))

    def unary(self, zeros):
        self.put(zeros + 1, 1)

    def align(self):
        self.put(-self.count % 8, 0)

    def bytes(self):
        assert self.count % 8 == 0
        return self.value.to_bytes(self.count // 8, "big") if self.count else b""


def flac_crc8(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def flac_crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def flac_utf8(value):
    """The frame number in FLAC's extended UTF-8."""
    if value < 0x80:
        return bytes([value])
    for length in range(2, 8):
        if value < (1 << (5 * length + 1)):
            break
    out = []
    for _ in range(length - 1):
        out.append(0x80 | (value & 0x3F))
        value >>= 6
    first = ((0xFF << (8 - length)) & 0xFF) | value
    return bytes([first] + out[::-1])


FLAC_BLOCK_CODES = {192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9, 1024: 10, 2048: 11,
                    4096: 12, 8192: 13, 16384: 14, 32768: 15}
FLAC_RATE_CODES = {88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6, 24000: 7, 32000: 8,
                   44100: 9, 48000: 10, 96000: 11}


def fixed_residual(samples, order):
    """The residual of fixed predictor `order`."""
    coeffs = {0: [], 1: [1], 2: [2, -1], 3: [3, -3, 1], 4: [4, -6, 4, -1]}[order]
    res = []
    for i in range(order, len(samples)):
        pred = sum(c * samples[i - 1 - k] for k, c in enumerate(coeffs))
        res.append(samples[i] - pred)
    return res


def rice_bits(values, param):
    total = 0
    for v in values:
        u = (v << 1) ^ (v >> 63)  # zigzag
        total += (u >> param) + 1 + param
    return total


def best_param(values, limit):
    return min(range(limit + 1), key=lambda k: rice_bits(values, k))


def write_residual(w, residual, block, order, partition_order=0, method=0, params=None, escape=()):
    """A residual: partitions of `block >> partition_order` samples, the
    first short by the predictor order; Rice parameters chosen or given;
    partitions in `escape` written raw (a 5-bit size, then the values)."""
    w.put(2, method)
    w.put(4, partition_order)
    limit = 14 if method == 0 else 30
    escape_code = 15 if method == 0 else 31
    parts = 1 << partition_order
    size = block >> partition_order
    at = 0
    for p in range(parts):
        n = size - (order if p == 0 else 0)
        values = residual[at:at + n]
        at += n
        if p in escape:
            bits = max((max(abs(v) for v in values) if values else 0).bit_length() + 1, 1)
            w.put(4 if method == 0 else 5, escape_code)
            w.put(5, bits)
            for v in values:
                w.put_signed(bits, v)
            continue
        k = params[p] if params else best_param(values, limit)
        w.put(4 if method == 0 else 5, k)
        for v in values:
            u = (v << 1) ^ (v >> 63)
            w.unary(u >> k)
            w.put(k, u & ((1 << k) - 1))
    assert at == len(residual)


def lpc_coefficients(samples, order, precision):
    """Quantized LPC coefficients for `samples` (autocorrelation with a
    Welch window, Levinson-Durbin), FLAC's way: `precision` bits each and the
    largest shift that keeps them in range, at most 15."""
    n = len(samples)
    window = [1.0 - ((2.0 * i - (n - 1)) / (n + 1)) ** 2 for i in range(n)]
    x = [s * w for s, w in zip(samples, window)]
    autoc = [sum(x[i] * x[i - lag] for i in range(lag, n)) for lag in range(order + 1)]
    autoc[0] = autoc[0] * (1.0 + 1e-9) + 1e-9
    lpc = [0.0] * order
    error = autoc[0]
    for i in range(order):
        r = -autoc[i + 1]
        for j in range(i):
            r -= lpc[j] * autoc[i - j]
        r /= error
        new = lpc[:]
        new[i] = r
        for j in range(i):
            new[j] = lpc[j] + r * lpc[i - 1 - j]
        lpc = new
        error *= 1.0 - r * r
    coeffs = [-c for c in lpc]  # predict s[i] = sum(coeffs[j] * s[i-1-j])
    limit = (1 << (precision - 1)) - 1
    biggest = max(abs(c) for c in coeffs) or 1.0
    shift = 15
    while shift > 0 and biggest * (1 << shift) > limit:
        shift -= 1
    quantized = [max(-limit - 1, min(limit, round(c * (1 << shift)))) for c in coeffs]
    return quantized, shift


def lpc_residual(samples, coeffs, shift):
    order = len(coeffs)
    return [samples[i] - (sum(c * samples[i - 1 - j] for j, c in enumerate(coeffs)) >> shift)
            for i in range(order, len(samples))]


def write_subframe(w, samples, bps, kind, order=0, wasted=0, precision=12, coeffs=None, shift=None, **residual):
    """One subframe of `samples` (already the channel's, side included) at
    `bps` bits, `wasted` low bits zero and stripped. LPC coefficients are
    computed unless given, with their shift."""
    w.put(1, 0)
    if kind == "constant":
        w.put(6, 0)
    elif kind == "verbatim":
        w.put(6, 1)
    elif kind == "fixed":
        w.put(6, 8 + order)
    else:
        w.put(6, 32 + order - 1)
    if wasted:
        w.put(1, 1)
        w.unary(wasted - 1)
        assert all(v % (1 << wasted) == 0 for v in samples)
        samples = [v >> wasted for v in samples]
        bps -= wasted
    else:
        w.put(1, 0)
    if kind == "constant":
        assert len(set(samples)) == 1
        w.put_signed(bps, samples[0])
    elif kind == "verbatim":
        for v in samples:
            w.put_signed(bps, v)
    elif kind == "fixed":
        for v in samples[:order]:
            w.put_signed(bps, v)
        write_residual(w, fixed_residual(samples, order), len(samples), order, **residual)
    else:
        if coeffs is None:
            coeffs, shift = lpc_coefficients(samples, order, precision)
        assert len(coeffs) == order and 0 <= shift <= 15
        for v in samples[:order]:
            w.put_signed(bps, v)
        w.put(4, precision - 1)
        w.put_signed(5, shift)
        # The bitstream holds the coefficient of the latest sample first.
        for c in coeffs:
            w.put_signed(precision, c)
        write_residual(w, lpc_residual(samples, coeffs, shift), len(samples), order, **residual)


FLAC_BPS_CODES = {8: 1, 12: 2, 16: 4, 20: 5, 24: 6, 32: 7}


def flac_frame(number, channels_data, rate, assignment="independent", subframes=None, block_code=None,
               rate_code=None, corrupt=None, bps=16, bps_code=None, var_size=False):
    """A frame of `bps`-bit samples: `channels_data` per channel; `subframes`
    gives each channel's (kind, options); the header's codes default to the
    table's, else 8 or 16 bits at the end, and a sample size outside the
    table to STREAMINFO's (code 0). With `var_size`, `number` is the first
    sample's number (variable blocking)."""
    block = len(channels_data[0])
    channels = len(channels_data)
    if block_code is None:
        block_code = FLAC_BLOCK_CODES.get(block, 6 if block <= 256 else 7)
    if rate_code is None:
        rate_code = FLAC_RATE_CODES.get(rate, 0)
    if bps_code is None:
        bps_code = FLAC_BPS_CODES.get(bps, 0)
    h = BitWriter()
    h.put(14, 0x3FFE)
    h.put(1, 0)
    h.put(1, 1 if var_size else 0)
    h.put(4, block_code)
    h.put(4, rate_code)
    codes = {"independent": channels - 1, "left_side": 8, "right_side": 9, "mid_side": 10}
    h.put(4, codes[assignment])
    h.put(3, bps_code)
    h.put(1, 0)
    header = h.bytes() + flac_utf8(number)
    if block_code == 6:
        header += bytes([block - 1])
    elif block_code == 7:
        header += struct.pack(">H", block - 1)
    if rate_code == 12:
        header += bytes([rate // 1000])
    elif rate_code == 13:
        header += struct.pack(">H", rate)
    elif rate_code == 14:
        header += struct.pack(">H", rate // 10)
    header += bytes([flac_crc8(header)])
    left = channels_data[0]
    right = channels_data[1] if channels > 1 else None
    if assignment == "left_side":
        coded = [left, [l - r for l, r in zip(left, right)]]
        widths = [bps, bps + 1]
    elif assignment == "right_side":
        coded = [[l - r for l, r in zip(left, right)], right]
        widths = [bps + 1, bps]
    elif assignment == "mid_side":
        coded = [[(l + r) >> 1 for l, r in zip(left, right)], [l - r for l, r in zip(left, right)]]
        widths = [bps, bps + 1]
    else:
        coded = channels_data
        widths = [bps] * channels
    w = BitWriter()
    for i, data in enumerate(coded):
        kind, options = (subframes[i] if subframes else ("fixed", {"order": 2}))
        write_subframe(w, data, widths[i], kind, **options)
    w.align()
    frame = header + w.bytes()
    if corrupt:
        frame = corrupt(frame)
    return frame + struct.pack(">H", flac_crc16(frame))


def flac_block(kind, body, last=False, size=None):
    return bytes([(0x80 if last else 0) | kind]) + struct.pack(">I", len(body) if size is None else size)[1:] + body


def streaminfo(rate, channels, total, min_block=4096, max_block=4096, bps=16, min_frame=0, max_frame=0, md5=None):
    w = BitWriter()
    w.put(16, min_block)
    w.put(16, max_block)
    w.put(24, min_frame)
    w.put(24, max_frame)
    w.put(20, rate)
    w.put(3, channels - 1)
    w.put(5, bps - 1)
    w.put(36, total)
    # No MD5 unless given (FFmpeg never checks it).
    w.put(128, int.from_bytes(md5, "big") if md5 else 0)
    return w.bytes()


def flac_file(rate, channels, frames, total, blocks=(), block_size=None, bps=16, md5=None, sizes=None):
    """fLaC, STREAMINFO, `blocks` (type, body), then the frames."""
    sizes = sizes or [block_size or 4096] * 2
    info = flac_block(0, streaminfo(rate, channels, total, sizes[0], sizes[1], bps, md5=md5), last=not blocks)
    rest = b"".join(flac_block(t, b, last=i == len(blocks) - 1) for i, (t, b) in enumerate(blocks))
    return b"fLaC" + info + rest + b"".join(frames)


def flac_signal(count, channels, seed=1, amplitude=12000):
    """Smoothed pseudo-random 16-bit samples, one list per channel."""
    state = seed
    memory = [0.0] * channels
    out = [[] for _ in range(channels)]
    for _ in range(count):
        for c in range(channels):
            state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
            top = (state >> 32) & 0xFFFFFFFF
            white = (top - (1 << 32) if top & 0x80000000 else top) / 2147483648.0
            memory[c] = memory[c] * 0.9 + white * 0.1
            out[c].append(max(-32768, min(32767, round(memory[c] * amplitude * 4))))
    return out


def interleave(channels_data):
    return [v for frame in zip(*channels_data) for v in frame]


@dataclasses.dataclass
class FlacFixture:
    name: str
    group: str
    rule: str
    data: bytes  # None for FFmpeg-made fixtures, checked by hash
    channels: int = 0
    rate: int = 0
    samples: list = None  # interleaved samples at `bps` bits, the expected output
    reject: str = None
    made_by: str = "generate.py"
    sha256: str = None
    bps: int = 16
    # The format tags ffprobe reports, (key, value) in order, from
    # VORBIS_COMMENT (T26b).
    tags: list = None
    # STREAMINFO's MD5 against the decoded samples: "match", "mismatch" or
    # None when it is unset (T26b).
    md5: str = None


# FFmpeg-made fixtures: name -> (channels, rate, samples per channel, seed,
# the encoder options), and the hash of the file made from them. Inputs are
# flac_signal's; zig/testing/reference/flac_fixtures.sh writes the files.
FLAC_FFMPEG = {
    "flac_ffmpeg_level0_stereo": (2, 44100, 9216, 7, "-compression_level 0 -frame_size 1152",
                                  "77275125d498e5a6ad86f7938ab087aa6a159f53dad295a048172e82511ca1ce"),
    "flac_ffmpeg_level5_stereo": (2, 44100, 9216, 7, "-compression_level 5 -frame_size 1152",
                                  "ce61749e50a18f0a56c141b374cf27948aa57df9d5ac0e260f8e0e2d3ad1a2b8"),
    "flac_ffmpeg_level8_mono": (1, 8000, 4000, 9, "-compression_level 8",
                                "bf42b84a3ee47b00eab083e2d65bd248549ca4cb1b4675a721d0fdcaf7c39b0b"),
    "flac_ffmpeg_level12_stereo": (2, 48000, 6000, 11, "-compression_level 12 -frame_size 2000",
                                   "8eb582889da8376aeffc31c159dfce5e047799fa4dd4602137e2c2f58f1b79dc"),
    "flac_ffmpeg_lpc_orders": (1, 44100, 8192, 13,
                               "-compression_level 12 -lpc_type levinson -min_prediction_order 1 "
                               "-max_prediction_order 32 -frame_size 512",
                               "5cd62bce081c2055ee9786ee6ffdbc3a5bd8c6c8baecfefb10bf7adf34edd103"),
}


def flac_ffmpeg_input(name):
    channels, rate, count, seed, _, _ = FLAC_FFMPEG[name]
    return interleave(flac_signal(count, channels, seed=seed))


def vorbis_comment_block(vendor, comments):
    """A VORBIS_COMMENT body: little-endian lengths, the vendor, the count
    and each `KEY=value`."""
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(comments))
    for c in comments:
        body += struct.pack("<I", len(c)) + c
    return body


# ff_vorbiscomment_metadata_conv's renamings.
VORBIS_CONV = {"ALBUMARTIST": "album_artist", "TRACKNUMBER": "track", "DISCNUMBER": "disc",
               "DISCSUBTITLE": "disc_subtitle", "DESCRIPTION": "comment"}


def vorbis_tags(comments):
    """The format tags FFmpeg makes of `comments` (ff_vorbis_comment, then
    ff_metadata_conv): no '=', an empty key or value skipped; a key seen
    before, in any case, gets `;` and then the value appended, each
    av_dict_set with AV_DICT_APPEND replacing the entry as libavutil does
    (the last entry moves into its slot, the new spelling goes last); five
    keys renamed."""
    tags = []

    def append(key, value):
        for i, tag in enumerate(tags):
            if tag[0].lower() == key.lower():
                old = tag[1]
                last = tags.pop()
                if i < len(tags):
                    tags[i] = last
                tags.append([key, old + value])
                return
        tags.append([key, value])

    for c in comments:
        text = c.decode()
        if "=" not in text:
            continue
        key, value = text.split("=", 1)
        if not key or not value:
            continue
        if any(tag[0].lower() == key.lower() for tag in tags):
            append(key, ";")
        append(key, value)
    out = []
    for key, value in tags:
        key = VORBIS_CONV.get(key.upper(), key)
        if not any(k.lower() == key.lower() and v == value for k, v in out):
            out.append((key, value))
    return out


def seektable_block(points):
    """A SEEKTABLE body: (sample number, byte offset, samples) per point."""
    return b"".join(struct.pack(">QQH", *point) for point in points)


def picture_block(picture_type, mime, description, width, height, depth, colors, data):
    """A PICTURE body, big-endian fields."""
    return (struct.pack(">II", picture_type, len(mime)) + mime + struct.pack(">I", len(description)) + description
            + struct.pack(">IIIII", width, height, depth, colors, len(data)) + data)


def cuesheet_block(lead_in, tracks):
    """A CUESHEET body: (offset, number, ISRC, [(index offset, number)]) per
    track, the lead-out last."""
    body = b"0123456789012" + bytes(128 - 13) + struct.pack(">Q", lead_in) + bytes([0x80]) + bytes(258)
    body += bytes([len(tracks)])
    for offset, number, isrc, indices in tracks:
        body += struct.pack(">QB", offset, number) + isrc + bytes(14) + bytes([len(indices)])
        for index_offset, index_number in indices:
            body += struct.pack(">QB", index_offset, index_number) + bytes(3)
    return body


def scaled_signal(count, channels, bps, seed):
    """flac_signal scaled to `bps` bits."""
    full = flac_signal(count, channels, seed=seed, amplitude=12000)
    shift = bps - 16
    limit = (1 << (bps - 1)) - 1
    return [[max(-limit - 1, min(limit, v << shift if shift >= 0 else v >> -shift)) for v in ch] for ch in full]


def build_flac_fixtures():
    fx = []

    def ok(name, rule, rate, channels_data, frames, blocks=(), group="accepted", block_size=None, bps=16, md5=None,
           tags=None, sizes=None, info_rate=None, total=None):
        total = len(channels_data[0]) if total is None else total
        fx.append(FlacFixture(name, group, rule,
                              flac_file(rate if info_rate is None else info_rate, len(channels_data), frames, total,
                                        blocks, block_size, bps, md5, sizes),
                              channels=len(channels_data), rate=rate, samples=interleave(channels_data), bps=bps,
                              md5=None if md5 is None else ("match" if md5 == flac_md5(interleave(channels_data), bps)
                                                             else "mismatch"),
                              tags=tags))

    def framed(rate, channels_data, block, **frame_options):
        """Frames of `block` samples (the last shorter), with options."""
        frames = []
        for n, start in enumerate(range(0, len(channels_data[0]), block)):
            part = [c[start:start + block] for c in channels_data]
            frames.append(flac_frame(n, part, rate, **frame_options))
        return frames

    def bad(name, group, rule, data, error):
        assert error in FLAC_ERRORS, error
        fx.append(FlacFixture(name, group, rule, data, reject=error))

    mono = flac_signal(576, 1, seed=3)
    stereo = flac_signal(1152, 2, seed=5)

    # Subframe kinds.
    consts = [[0] * 64, [1000] * 64, [-32768] * 64, [32767] * 64]
    ok("flac_constant_mono_8k", "Constant subframes, 64-sample frames (an 8-bit size at the header's end).", 8000,
       [sum(consts, [])], [flac_frame(n, [c], 8000, subframes=[("constant", {})]) for n, c in enumerate(consts)],
       block_size=64)
    ok("flac_verbatim_stereo_44k1", "Verbatim subframes, independent channels, 192-sample frames; the last "
       "frame shorter (a 16-bit size).", 44100, [c[:500] for c in stereo],
       framed(44100, [c[:500] for c in stereo], 192, subframes=[("verbatim", {}), ("verbatim", {})]), block_size=192)
    ok("flac_fixed_orders_mono", "Fixed predictors of orders 0 to 4, one per 576-sample frame, partition "
       "orders 0 to 4.", 44100, [sum(flac_signal(576 * 5, 1, seed=4), [])],
       [flac_frame(n, [part], 44100, subframes=[("fixed", {"order": n, "partition_order": n})])
        for n, part in enumerate(chunks(sum(flac_signal(576 * 5, 1, seed=4), []), 576))], block_size=576)
    lpc_mono = flac_signal(4096 * 4, 1, seed=14)
    orders = [1, 8, 12, 32]
    ok("flac_lpc_orders_mono", "LPC subframes of orders 1, 8, 12 and 32, one per 4096-sample frame, with "
       "12-bit coefficients and partition orders 0, 3, 8 and 6.", 44100, lpc_mono,
       [flac_frame(n, [part], 44100, subframes=[("lpc", {"order": order, "partition_order": po})])
        for n, (order, po, part) in enumerate(zip(orders, [0, 3, 8, 6], chunks(lpc_mono[0], 4096)))])
    ok("flac_lpc_precision", "LPC of order 8 with 15-bit coefficients on the 17-bit side channel "
       "(the 64-bit prediction path) and 5-bit coefficients on the mid channel.", 48000, stereo,
       framed(48000, stereo, 1152, assignment="mid_side",
              subframes=[("lpc", {"order": 8, "precision": 5}), ("lpc", {"order": 8, "precision": 15})]),
       block_size=1152)
    ok("flac_lpc_zero_shift", "LPC of order 2 with given coefficients 2 and -1 and a shift of 0.", 32000, mono,
       framed(32000, mono, 576, subframes=[("lpc", {"order": 2, "coeffs": [2, -1], "shift": 0})]), block_size=576)
    for assignment in ("left_side", "right_side", "mid_side"):
        ok(f"flac_{assignment}", f"Stereo as {assignment.replace('_', '/')}: the side channel has 17 bits.",
           44100, stereo, framed(44100, stereo, 576, assignment=assignment), block_size=576)
    ok("flac_rice_escape", "A residual partition coded raw (Rice escape) beside Rice-coded ones.", 22050, mono,
       framed(22050, mono, 576, subframes=[("fixed", {"order": 1, "partition_order": 2, "escape": (1, 3)})]),
       block_size=576)
    loud = [[(v * 3) // 2 for v in flac_signal(576, 1, seed=8, amplitude=20000)[0]]]
    loud = [[max(-32768, min(32767, v)) for v in loud[0]]]
    ok("flac_rice2_params", "Rice coding with 5-bit parameters (method 1), one above 14.", 48000, loud,
       framed(48000, loud, 576, subframes=[("fixed", {"order": 0, "method": 1, "partition_order": 1,
                                                       "params": [15, 16]})]), block_size=576)
    coarse = [[(v // 4) * 4 for v in mono[0]]]
    ok("flac_wasted_bits", "Samples that are multiples of 4, with two wasted bits.", 16000, coarse,
       framed(16000, coarse, 576, subframes=[("fixed", {"order": 2, "wasted": 2})]), block_size=576)
    many = flac_signal(16 * 300, 1, seed=6)
    ok("flac_many_frames", "300 frames of 16 samples: frame numbers past 127 take two UTF-8 bytes.", 8000, many,
       framed(8000, many, 16, subframes=[("fixed", {"order": 1})]), block_size=16)
    six = flac_signal(256, 6, seed=10)
    ok("flac_six_channels_48k", "Six independent channels; a 256-sample block (code 8).", 48000, six,
       framed(48000, six, 256, subframes=[("fixed", {"order": 2})] * 6), block_size=256)
    for name, rate, code, rule in (("flac_rate_khz", 11000, 12, "A rate in kHz (code 12)."),
                                   ("flac_rate_hz", 12345, 13, "A rate in Hz (code 13)."),
                                   ("flac_rate_tens", 50000, 14, "A rate in tens of Hz (code 14)."),
                                   ("flac_rate_streaminfo", 37800, 0, "The rate from STREAMINFO (code 0).")):
        part = flac_signal(192, 1, seed=12)
        ok(name, rule, rate, part, [flac_frame(0, part, rate, rate_code=code)], block_size=192)
    ok("flac_metadata_blocks", "PADDING, APPLICATION and an unknown block before the frames, skipped.", 44100, mono,
       framed(44100, mono, 576), blocks=((1, bytes(16)), (2, b"zffm" + bytes(4)), (100, b"x" * 7)), block_size=576)

    # Damaged streams: what FFmpeg's parser and decoder make of them is the
    # oracle's (flac_vectors.c).
    frames = framed(44100, mono, 192)
    frames[1] = frames[1][:-6] + bytes([frames[1][-6] ^ 0x10]) + frames[1][-5:]
    ok("flac_corrupt_frame_data", "The second frame's data damaged: its CRC-16 fails.", 44100, mono, frames,
       group="damaged", block_size=192)
    frames = framed(44100, mono, 192)
    frames.insert(1, b"\xff\xf8\x12\x34junk\xff\xf9")
    ok("flac_junk_between_frames", "Junk with false sync codes between the first two frames.", 44100, mono, frames,
       group="damaged", block_size=192)

    # T26b: every sample size, variable blocking, metadata blocks, MD5.
    def depth(name, rule, bps, channels, rate, assignment="independent", subframes=None, block=576, frames_count=2,
              seed=20):
        data = scaled_signal(block * frames_count, channels, bps, seed)
        if bps > 16:
            # Rice2's 5-bit parameters for wide residuals.
            subframes = [(kind, dict(options, method=1) if kind in ("fixed", "lpc") else options)
                         for kind, options in (subframes or [("fixed", {"order": 2})] * channels)]
        ok(name, rule, rate, data, framed(rate, data, block, assignment=assignment, subframes=subframes, bps=bps),
           block_size=block, bps=bps)

    depth("flac_bps8_mono", "8-bit samples, the header's code 1: s16 output shifted by 8.", 8, 1, 8000,
          subframes=[("fixed", {"order": 1})])
    depth("flac_bps12_left_side", "12-bit left/side stereo (a 13-bit side channel).", 12, 2, 22050,
          assignment="left_side")
    depth("flac_bps20_lpc", "20-bit samples with LPC of order 8: s32 output shifted by 12.", 20, 1, 44100,
          subframes=[("lpc", {"order": 8, "precision": 14})])
    depth("flac_bps24_mid_side", "24-bit mid/side with LPC: a 25-bit side channel on the 64-bit prediction path.",
          24, 2, 48000, assignment="mid_side",
          subframes=[("lpc", {"order": 12, "precision": 15}), ("lpc", {"order": 12, "precision": 15})])
    depth("flac_bps32_left_side_fixed", "32-bit left/side: a 33-bit side channel with a fixed predictor.", 32, 2,
          96000, assignment="left_side", subframes=[("fixed", {"order": 1}), ("fixed", {"order": 2})], block=192)
    depth("flac_bps32_right_side_lpc", "32-bit right/side: a 33-bit side channel with LPC.", 32, 2, 96000,
          assignment="right_side", subframes=[("lpc", {"order": 4, "precision": 12}), ("lpc", {"order": 4})],
          block=192)
    depth("flac_bps32_mid_side_verbatim", "32-bit mid/side, verbatim: a 33-bit side channel read raw.", 32, 2,
          44100, assignment="mid_side", subframes=[("verbatim", {}), ("verbatim", {})], block=64)
    data = scaled_signal(256, 1, 32, 21)
    data = [[(v >> 3) << 3 for v in data[0]]]
    ok("flac_bps32_wasted_bits", "32-bit samples with three wasted bits.", 32000, data,
       framed(32000, data, 256, bps=32, subframes=[("fixed", {"order": 2, "wasted": 3, "method": 1})]), block_size=256,
       bps=32)
    depth("flac_bps4_mono", "4-bit samples: the header defers the size to STREAMINFO (code 0).", 4, 1, 8000,
          subframes=[("verbatim", {})], block=192)
    depth("flac_bps10_stereo", "10-bit independent stereo, the size from STREAMINFO.", 10, 2, 16000, block=192)
    depth("flac_bps28_lpc", "28-bit samples with LPC, the size from STREAMINFO.", 28, 1, 48000,
          subframes=[("lpc", {"order": 6, "precision": 12})], block=256)

    sizes_list = [100, 576, 32, 1000, 7]
    data = scaled_signal(sum(sizes_list), 2, 16, 22)
    frames, at = [], 0
    for size in sizes_list:
        frames.append(flac_frame(at, [c[at:at + size] for c in data], 44100, assignment="mid_side", var_size=True))
        at += size
    ok("flac_variable_blocksize", "Variable blocking: frames of 100, 576, 32, 1000 and 7 samples, each numbered by "
       "its first sample.", 44100, data, frames, sizes=[7, 1000])

    mono = flac_signal(576, 1, seed=3)
    comments = [b"TITLE=Fixture", b"ARTIST=first", b"ALBUMARTIST=both", b"artist=second", b"DESCRIPTION=notes",
                b"NOEQUALSIGN", b"=novalue", b"EMPTY=", "LANGUAGE=Português".encode(), b"TRACKNUMBER=3"]
    ok("flac_vorbis_comment", "VORBIS_COMMENT: tags, a repeated key joined with ';', FFmpeg's renamings, entries "
       "without a key or value skipped.", 44100, mono, framed(44100, mono, 576),
       blocks=((4, vorbis_comment_block(b"zffmpeg fixtures", comments)),), block_size=576,
       tags=vorbis_tags(comments))
    ok("flac_vorbis_comment_truncated", "VORBIS_COMMENT claiming more comments than it holds: the ones present are "
       "read.", 44100, mono, framed(44100, mono, 576),
       blocks=((4, struct.pack("<I", 1) + b"v" + struct.pack("<I", 10) + struct.pack("<I", 10) + b"TITLE=kept"),),
       block_size=576,
       tags=[("TITLE", "kept")])
    two = flac_signal(1152, 1, seed=23)
    frames = framed(44100, two, 576)
    ok("flac_seektable", "A SEEKTABLE with two points and a placeholder before the frames.", 44100, two, frames,
       blocks=((3, seektable_block([(0, 0, 576), (576, len(frames[0]), 576), (0xFFFFFFFFFFFFFFFF, 0, 0)])),),
       block_size=576)
    png = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000")
    ok("flac_picture", "A PICTURE block (a front cover in PNG) and PADDING.", 44100, mono, framed(44100, mono, 576),
       blocks=((6, picture_block(3, b"image/png", b"cover", 1, 1, 32, 0, png)), (1, bytes(8))), block_size=576)
    ok("flac_cuesheet", "A CUESHEET of two tracks and the lead-out: FFmpeg's chapters.", 44100, two,
       framed(44100, two, 576),
       blocks=((5, cuesheet_block(88200, [(0, 1, b"ABCDE1234567", [(0, 1)]), (576, 2, bytes(12), [(0, 1)]),
                                          (1152, 170, bytes(12), [])])),), block_size=576)
    ok("flac_md5_match", "STREAMINFO's MD5 matches the samples.", 44100, mono, framed(44100, mono, 576),
       block_size=576, md5=flac_md5(interleave(mono), 16))
    ok("flac_md5_mismatch", "STREAMINFO's MD5 does not match: decoding is unaffected; verification fails.", 44100,
       mono, framed(44100, mono, 576), block_size=576, md5=bytes(range(16)))
    ok("flac_streaminfo_rate0", "STREAMINFO's rate is 0: the frames give it.", 22050, mono, framed(22050, mono, 576),
       block_size=576, info_rate=0)
    ok("flac_no_total", "STREAMINFO without a sample count.", 44100, mono, framed(44100, mono, 576), block_size=576,
       total=0)
    ok("flac_headerless", "Frames without fLaC or metadata: FFmpeg's headerless mode.", 44100, mono,
       framed(44100, mono, 576))
    fx[-1].data = b"".join(framed(44100, mono, 576))
    ok("flac_headerless_mid_side", "Headerless mid/side frames: raw_flac_probe accepts channel code 10.", 44100,
       stereo, framed(44100, stereo, 576, assignment="mid_side"))
    fx[-1].data = b"".join(framed(44100, stereo, 576, assignment="mid_side"))
    first = flac_signal(576, 1, seed=24)
    second = flac_signal(576, 2, seed=25)
    fx.append(FlacFixture("flac_channel_change", "damaged", "Mono, then a stereo frame: FFmpeg follows the change.",
                          flac_file(44100, 1, [flac_frame(0, first, 44100), flac_frame(1, second, 44100)], 1152,
                                    block_size=576)))
    fx.append(FlacFixture("flac_rate_change", "damaged", "44.1 kHz, then a 48 kHz frame: FFmpeg follows the change.",
                          flac_file(44100, 1, [flac_frame(0, first, 44100), flac_frame(1, first, 48000)], 1152,
                                    block_size=576)))

    # Refused.
    info = streaminfo(44100, 1, 576)
    fx.append(FlacFixture("flac_bps24", "accepted", "24-bit STREAMINFO and no frames: an empty stream.",
                          b"fLaC" + flac_block(0, streaminfo(44100, 1, 576, bps=24), last=True), channels=1,
                          rate=44100, samples=[], bps=24))
    bad("flac_bps3", "rejected", "STREAMINFO's sample size of 3 bits, below FLAC's 4.",
        b"fLaC" + flac_block(0, streaminfo(44100, 1, 576, bps=3), last=True), "InvalidFlac")
    bad("flac_second_streaminfo", "rejected", "A second STREAMINFO.",
        b"fLaC" + flac_block(0, info) + flac_block(0, info, last=True), "InvalidFlac")
    bad("flac_no_streaminfo", "rejected", "The first block is PADDING: STREAMINFO must come first.",
        b"fLaC" + flac_block(1, bytes(8)) + flac_block(0, info, last=True), "InvalidFlac")
    bad("flac_streaminfo_short", "rejected", "STREAMINFO of 33 bytes.",
        b"fLaC" + flac_block(0, info[:33], last=True), "InvalidFlac")
    bad("flac_truncated_metadata", "rejected", "The file ends inside STREAMINFO.",
        b"fLaC" + flac_block(0, info, last=True)[:20], "Truncated")

    for name, (channels, rate, count, seed, options, digest) in FLAC_FFMPEG.items():
        fx.append(FlacFixture(name, "ffmpeg", f"FFmpeg's encoder, `{options}`; VORBIS_COMMENT and PADDING "
                              "blocks.", None,
                              channels=channels, rate=rate, samples=flac_ffmpeg_input(name), made_by="ffmpeg",
                              sha256=digest))
    return fx


def chunks(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def flac_output_bytes(samples, bps):
    """The decoder's output, FFmpeg's: s16 for at most 16 bits, else s32,
    each sample shifted to the top of its storage, little-endian."""
    if bps <= 16:
        return b"".join(struct.pack("<h", v << (16 - bps)) for v in samples)
    return b"".join(struct.pack("<i", v << (32 - bps)) for v in samples)


def flac_pcm_sha256(samples, bps=16):
    return hashlib.sha256(flac_output_bytes(samples, bps)).hexdigest()


def flac_md5(samples, bps):
    """STREAMINFO's MD5, the FLAC format's definition: the interleaved
    samples, signed little-endian in the fewest whole bytes holding `bps`."""
    width = (bps + 7) // 8
    return hashlib.md5(b"".join(v.to_bytes(width, "little", signed=True) for v in samples)).digest()


def render_flac_manifest(fixtures):
    lines = ["// Generated by zig/testing/fixtures/generate.py from its FLAC fixtures; do not edit.",
             "// Each entry names flac/<name>.flac; see flac/README.md for the rules and decisions.",
             ".{"]
    for f in fixtures:
        digest = f.sha256 if f.made_by == "ffmpeg" else hashlib.sha256(f.data).hexdigest()
        lines.append("    .{")
        lines.append(f'        .name = "{f.name}",')
        lines.append(f'        .sha256 = "{digest}",')
        lines.append(f"        .made_by = .{'ffmpeg' if f.made_by == 'ffmpeg' else 'generate'},")
        # FFmpeg's muxer always starts with fLaC and a valid STREAMINFO.
        detected = ffmpeg_detect(f.data) if f.data is not None else "flac"
        lines.append(f"        .detected = {'.' + detected if detected else 'null'},")
        if f.reject:
            lines.append(f"        .expected = .{{ .reject = .{f.reject} }},")
        elif f.group == "damaged":
            lines.append("        .expected = .damaged,")
        else:
            extra = "" if f.bps == 16 else f", .bps = {f.bps}"
            lines.append(f"        .expected = .{{ .accept = .{{ .channels = {f.channels}, .sample_rate = {f.rate}, "
                         f".frames = {len(f.samples) // f.channels}, .pcm_sha256 = \"{flac_pcm_sha256(f.samples, f.bps)}\"{extra} }} }},")
        if f.md5:
            lines.append(f"        .md5 = .{f.md5},")
        if f.tags:
            lines.append("        .tags = .{")
            for key, value in f.tags:
                lines.append(f"            .{{ .key = {zig_string(key.encode())}, .value = {zig_string(value.encode())} }},")
            lines.append("        },")
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_flac_table(fixtures):
    rows = [TABLE_BEGIN.rstrip("\n"), "| Fixture | Group | Made by | Expected | Rule |", "| --- | --- | --- | --- | --- |"]
    for f in fixtures:
        if f.reject:
            expected = f"`{f.reject}`"
        elif f.group == "damaged":
            expected = "FFmpeg's result (flac_vectors.c)"
        else:
            expected = f"{f.channels} ch, {f.rate} Hz, {len(f.samples) // f.channels} frames"
        rows.append(f"| `{f.name}` | {f.group} | {f.made_by} | {expected} | {f.rule} |")
    rows.append(TABLE_END.rstrip("\n"))
    return "\n".join(rows) + "\n"


# Ogg fixtures (T27a): pages with Ogg's CRC-32, the FLAC, Opus and Vorbis
# mappings, and multiplexed, chained and damaged streams. Their expected
# packets and timestamps are FFmpeg's, from zig/testing/reference/
# ogg_vectors.c (vectors/ogg.txt); the manifest records whether FFmpeg
# opens each one.

OGG_DIR = HERE / "ogg"
OGG_MANIFEST = OGG_DIR / "manifest.zon"
OGG_README = OGG_DIR / "README.md"


def _ogg_crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else (r << 1)
        table.append(r & 0xFFFFFFFF)
    return table


OGG_CRC_TABLE = _ogg_crc_table()


def ogg_crc(data):
    """Ogg's CRC-32: polynomial 0x04C11DB7, initial 0, MSB first, no final
    XOR."""
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ OGG_CRC_TABLE[((crc >> 24) ^ b) & 0xFF]
    return crc


def ogg_page(serial, seq, granule, body_segments, flags=0, version=0, crc=None):
    """One page: `body_segments` are its lacing values' bytes, each at most
    255 (a 255 continues the packet). A granule of None is -1."""
    lacing = bytes(len(seg) for seg in body_segments)
    assert len(lacing) <= 255
    gp = 0xFFFFFFFFFFFFFFFF if granule is None else granule & 0xFFFFFFFFFFFFFFFF
    header = (b"OggS" + bytes([version, flags]) + struct.pack("<QII", gp, serial, seq) + b"\0\0\0\0"
              + bytes([len(lacing)]) + lacing)
    body = b"".join(body_segments)
    page = bytearray(header + body)
    value = ogg_crc(bytes(page)) if crc is None else crc
    page[22:26] = struct.pack("<I", value)
    return bytes(page)


def ogg_lace(packet):
    """A packet's lacing: 255-byte segments, then one shorter (possibly
    empty)."""
    segs = [packet[i:i + 255] for i in range(0, len(packet) - len(packet) % 255, 255)]
    segs.append(packet[len(packet) - len(packet) % 255:])
    return segs


def ogg_stream_pages(serial, packets, granules, per_page=None, bos=True, eos=True, seq=0, max_segments=255):
    """Pages for a logical stream as libogg lays them out: `packets` with
    the granule each one ends at; a page is cut after `per_page` packets
    (or when its segments run out), and its granule is that of the last
    packet completed on it, or -1. The first packet (the codec's first
    header) has a page of its own."""
    pages = []
    segments = []  # (segment bytes, packet index or None while it continues)
    for n, packet in enumerate(packets):
        laced = ogg_lace(packet)
        for k, seg in enumerate(laced):
            segments.append((seg, n if k == len(laced) - 1 else None))
    current, completed, cont, page_index = [], [], False, 0

    def flush(last):
        nonlocal current, completed, cont, page_index, seq
        if not current:
            return
        flags = (1 if cont else 0) | (2 if bos and page_index == 0 else 0) | (4 if eos and last else 0)
        granule = granules[completed[-1]] if completed else None
        pages.append(ogg_page(serial, seq, granule, [seg for seg, _ in current], flags))
        cont = current[-1][1] is None
        seq += 1
        page_index += 1
        current, completed = [], []

    for i, (seg, ends) in enumerate(segments):
        current.append((seg, ends))
        if ends is not None:
            completed.append(ends)
        full = len(current) == max_segments
        cut = ends is not None and (ends == 0 or (per_page and len(completed) == per_page))
        if full or cut:
            flush(i == len(segments) - 1)
    flush(True)
    return pages


def ogg_interleave(*streams):
    """Pages of several streams, the first page of each first (the BOS
    pages), then the rest in turn."""
    out = [p[0] for p in streams]
    rest = [list(p[1:]) for p in streams]
    while any(rest):
        for r in rest:
            if r:
                out.append(r.pop(0))
    return b"".join(out)


def vorbis_comment_packet(prefix, vendor, tags, framing):
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(tags))
    for tag in tags:
        body += struct.pack("<I", len(tag)) + tag
    return prefix + body + (b"\x01" if framing else b"")


def ogg_flac_headers(rate, channels, total, block, tags=(b"TITLE=Ogg FLAC",)):
    """The FLAC mapping's first packet (0x7F, "FLAC", version 1.0, the
    header count, "fLaC", STREAMINFO's block) and a VORBIS_COMMENT."""
    info = streaminfo(rate, channels, total, block, block)
    first = b"\x7fFLAC\x01\x00\x00\x01fLaC" + b"\x00" + (34).to_bytes(3, "big") + info
    comment = vorbis_comment_packet(b"", b"generate.py", list(tags), framing=False)
    return [first, b"\x84" + len(comment).to_bytes(3, "big") + comment]


def ogg_flac_stream(serial, rate=44100, channels=2, count=2000, block=576, per_page=1, seed=7, **pages):
    data = flac_signal(count, channels, seed=seed)
    frames = []
    granules = [0, 0]
    for n, start in enumerate(range(0, count, block)):
        part = [c[start:start + block] for c in data]
        frames.append(flac_frame(n, part, rate))
        granules.append(min(start + block, count))
    packets = ogg_flac_headers(rate, channels, count, block) + frames
    return ogg_stream_pages(serial, packets, granules, per_page=per_page, **pages)


def opus_head(channels=2, pre_skip=312, rate=48000):
    return b"OpusHead" + bytes([1, channels]) + struct.pack("<HIhB", pre_skip, rate, 0, 0)


def opus_head_mapped(family, streams, coupled, mapping, gain=0, pre_skip=312):
    """An OpusHead with a channel mapping table (families 1 and 255): one
    output channel per `mapping` entry, a decoded channel's index or 255
    for silence."""
    return (b"OpusHead" + bytes([1, len(mapping)]) + struct.pack("<HIhB", pre_skip, 48000, gain, family)
            + bytes([streams, coupled]) + bytes(mapping))


def opus_self_delimited(packet):
    """A code 0 packet in RFC 6716's self-delimiting framing (appendix B),
    as a multistream packet carries every stream but its last: the
    frame's length (one byte, or two from 252) after the TOC byte."""
    assert packet[0] & 3 == 0
    n = len(packet) - 1
    size = bytes([n]) if n < 252 else bytes([252 + (n - 252) % 4, (n - 252) // 4])
    return packet[:1] + size + packet[1:]


def opus_multistream_packet(parts):
    return b"".join(opus_self_delimited(p) for p in parts[:-1]) + parts[-1]


OPUS_TAGS = vorbis_comment_packet(b"OpusTags", b"generate.py", [b"TITLE=Ogg Opus"], framing=False)


def opus_packet(config, count_code, frames=None, size=40, fill=0x55):
    """A packet with a TOC byte (config, stereo, frame count code) and
    `size` bytes after it; with code 3, the frame count byte."""
    toc = (config << 3) | 4 | count_code
    body = bytes([toc]) + (bytes([frames]) if count_code == 3 else b"")
    return body + bytes([fill] * (size - len(body)))


def opus_random_packet(config, stereo, seed, size, count_code=0, frames=None):
    """A packet of `config` with random bytes after its TOC byte (any bytes
    decode): a 32-bit LCG from `seed`, its high bytes."""
    toc = (config << 3) | (4 if stereo else 0) | count_code
    body = bytearray([toc]) + (bytes([frames]) if count_code == 3 else b"")
    state = seed
    while len(body) < size:
        state = (state * 1103515245 + 12345) & 0xFFFFFFFF
        body.append(state >> 24)
    return bytes(body)


def opus_duration(packet):
    toc = packet[0]
    config, code = toc >> 3, toc & 3
    frame = max(480, 960 * (config & 3)) if config < 12 else (480 << (config & 1)) if config < 16 else 120 << (config & 3)
    count = (packet[1] & 0x3F) if code == 3 else 2 if code else 1
    return frame * count


def ogg_opus_stream(serial, packets, pre_skip=312, granule_end=None, per_page=4, head=None, **pages):
    total = 0
    granules = [0, 0]
    for packet in packets:
        total += opus_duration(packet)
        granules.append(total)
    if granule_end is not None:
        granules[-1] = granule_end
    allp = [head if head is not None else opus_head(pre_skip=pre_skip), OPUS_TAGS] + packets
    return ogg_stream_pages(serial, allp, granules, per_page=per_page, **pages)


def vorbis_id_header(channels=2, rate=44100, bs0=8, bs1=11):
    return (b"\x01vorbis" + struct.pack("<IBIiii", 0, channels, rate, 0, 128000, 0)
            + bytes([(bs1 << 4) | bs0, 1]))


def vorbis_setup_header(blockflags):
    """A setup header FFmpeg's vorbis_parser.c reads: filler where the
    codebooks, floors, residues and mappings would be (0xFF bytes, which
    its backward scan cannot mistake for modes), then the mode table and
    the framing bit, packed LSB first as Vorbis packs it."""
    bits = []

    def put(value, n):
        for i in range(n):
            bits.append((value >> i) & 1)

    put(len(blockflags) - 1, 6)
    for flag in blockflags:
        put(flag, 1)
        put(0, 16)
        put(0, 16)
        put(0, 8)
    put(1, 1)
    while len(bits) % 8:
        bits.append(0)
    packed = bytes(sum(bits[i + k] << k for k in range(8)) for i in range(0, len(bits), 8))
    return b"\x05vorbis" + b"\xff" * 16 + packed


def vorbis_audio_packet(mode, prev_long=0, next_long=0, size=30, mode_bits=1):
    first = (mode << 1) | (prev_long << (1 + mode_bits)) | (next_long << (2 + mode_bits))
    return bytes([first & 0xFF]) + bytes([0x33] * (size - 1))


def vorbis_durations(packets, bs=(256, 2048), blockflags=(0, 1)):
    """Each audio packet's duration as vorbis_parser.c gives it, from the
    first packet's start (the previous block taken as short)."""
    previous = bs[0]
    out = []
    for packet in packets:
        mode = (packet[0] >> 1) & 1 if len(blockflags) > 1 else 0
        prev = previous
        if blockflags[mode]:
            prev = bs[(packet[0] >> 2) & 1]
        current = bs[blockflags[mode]]
        out.append((prev + current) >> 2)
        previous = current
    return out


def ogg_vorbis_stream(serial, packets, per_page=4, granule_shift=0, zero_granules=False, **pages):
    headers = [vorbis_id_header(),
               vorbis_comment_packet(b"\x03vorbis", b"generate.py", [b"TITLE=Ogg Vorbis"], framing=True),
               vorbis_setup_header([0, 1])]
    durations = vorbis_durations(packets)
    granules = [0, 0, 0]
    total = 0
    for d in durations:
        total += d
        granules.append(0 if zero_granules else max(total - durations[0] + granule_shift, 0))
    return ogg_stream_pages(serial, headers + packets, granules, per_page=per_page, **pages)


@dataclasses.dataclass
class OggFixture:
    name: str
    group: str
    rule: str
    data: bytes
    # FFmpeg opens it ("accept") or fails with this error.
    reject: str = None
    # "ffmpeg" for a committed file FFmpeg's encoder made, checked by hash.
    made_by: str = "generate.py"


# Ogg fixtures made by FFmpeg's native encoders (T27d's Vorbis, stereo only;
# T28's Opus, CELT only, 48 kHz mono or stereo): name -> (channels, rate,
# samples, seed, encoder and options, sha256). zig/testing/reference/
# ogg_fixtures.sh makes them from --ogg-input NAME; they are committed, as
# the FFmpeg-made FLAC fixtures.
OGG_FFMPEG = {
    "ogg_vorbis_ffmpeg_44k": (2, 44100, 30000, 7, "-c:a vorbis",
                                "5766dab378033cdec1196bf8b3e59549bede9b88335f27d8c61312a4f4e5bdea"),
    "ogg_vorbis_ffmpeg_8k": (2, 8000, 6000, 9, "-c:a vorbis",
                                "50a22821911613c98f043df31c15607b37fb094d1187ec699e480d70f45ee745"),
    "ogg_vorbis_ffmpeg_48k_q8": (2, 48000, 20000, 11, "-c:a vorbis -q:a 8",
                                "40ee2ad8d98fc7407a49e8a83fd91ce48b22640e451da800bf0f816ef5cf1d96"),
    "ogg_vorbis_ffmpeg_22k_short": (2, 22050, 1000, 13, "-c:a vorbis",
                                "84770150a5782b3bd98725519e5506a5ecb552662a515ad3c7c7f98db909c6c0"),
    "ogg_opus_ffmpeg_stereo": (2, 48000, 20000, 15, "-c:a opus",
                                 "acef96f8854baa489f1ace051a0f78f90b8212722bd9dded6a5576f4d8a8f82a"),
    "ogg_opus_ffmpeg_mono": (1, 48000, 15000, 17, "-c:a opus",
                                 "7d4a072051e8487df04b103144c063b06d2c72a5f68ec14b2105ed04f81c3cee"),
    "ogg_opus_ffmpeg_32k": (2, 48000, 20000, 19, "-c:a opus -b:a 32k",
                                 "1d1ddf96a835d8b6ec2e06884ecf4be761bd70d682be60ec7ed84598b184ef89"),
    "ogg_opus_ffmpeg_delay10": (2, 48000, 12000, 21, "-c:a opus -opus_delay 10",
                                 "f07c2375eeda092753c45335ba4ae072cec7d6e29f10febd2ade7ea367d2c5c3"),
    "ogg_opus_ffmpeg_no_phase_inv": (2, 48000, 12000, 23, "-c:a opus -apply_phase_inv 0",
                                 "ce6e83609c1dc4198626553883e3c719373a607fde63f7cb39ed247a243983c5"),
}


def ogg_ffmpeg_input(name):
    channels, _, count, seed, _, _ = OGG_FFMPEG[name]
    return interleave(flac_signal(count, channels, seed=seed))


def vorbis_packets(count):
    """Short and long blocks in a pattern with the window flags long
    blocks carry."""
    out = []
    for i in range(count):
        long_block = i % 3 == 2
        out.append(vorbis_audio_packet(1 if long_block else 0, prev_long=0, next_long=0, size=20 + i % 7))
    return out


def build_ogg_fixtures():
    fx = []

    def ok(name, rule, data, group="accepted"):
        fx.append(OggFixture(name, group, rule, data))

    def bad(name, rule, data, error, group="rejected"):
        fx.append(OggFixture(name, group, rule, data, reject=error))

    opus_ps = [opus_packet(31, 0, size=40 + i % 5) for i in range(12)]
    vorbis_ps = vorbis_packets(20)

    flac_pages = ogg_flac_stream(0x1001)
    ok("ogg_flac_stereo", "FLAC in Ogg (the 0x7F FLAC mapping): STREAMINFO and a VORBIS_COMMENT as headers, one "
       "576-sample frame per page.", b"".join(flac_pages))
    ok("ogg_flac_packed_pages", "FLAC frames, four to a page; a page's granule is its last frame's end.",
       b"".join(ogg_flac_stream(0x1002, per_page=4)))
    ok("ogg_opus_stereo", "Opus: OpusHead (pre-skip 312) and OpusTags, then 20 ms CELT packets four to a page; "
       "the EOS page's granule ends the stream exactly.", b"".join(ogg_opus_stream(0x2001, opus_ps)))
    ok("ogg_opus_end_trim", "Opus whose EOS granule falls inside the last packet: FFmpeg trims its end "
       "(skip-samples side data).", b"".join(ogg_opus_stream(0x2002, opus_ps, granule_end=12 * 960 - 500)))
    ok("ogg_opus_frame_counts", "Opus TOC frame counts 1, 2 (codes 1 and 2) and code 3 with a count byte, and "
       "configurations of 2.5 to 60 ms.", b"".join(ogg_opus_stream(0x2003, [
           opus_packet(0, 0), opus_packet(1, 1), opus_packet(3, 2), opus_packet(16, 3, frames=3),
           opus_packet(13, 0), opus_packet(19, 3, frames=6), opus_packet(31, 0), opus_packet(31, 0)])))
    silk = [
        # (config, stereo, size, count code, frames): narrow, medium and wide band,
        # 10 to 60 ms, mono and stereo, a CELT packet between (the resampler
        # flushed), rate changes and frames large enough for redundancy.
        (0, False, 30, 0, None), (1, True, 60, 0, None), (6, False, 90, 0, None), (11, True, 200, 0, None),
        (9, False, 120, 1, None), (31, True, 80, 0, None), (9, True, 150, 0, None), (4, False, 40, 0, None),
        (5, True, 170, 0, None), (1, False, 90, 3, 3), (3, True, 160, 0, None), (10, False, 100, 0, None),
        (31, False, 60, 0, None), (8, True, 70, 0, None), (2, False, 140, 0, None), (7, True, 190, 0, None),
    ]
    silk_ps = [opus_random_packet(c, st, 0x5000 + i, size, code, frames) for i, (c, st, size, code, frames) in
               enumerate(silk)]
    ok("ogg_opus_silk", "Opus SILK packets of random bytes (any bytes decode): narrow, medium and wide band, 10 to "
       "60 ms, mono and stereo, frame count codes 0, 1 and 3, CELT packets between and frames large enough to "
       "carry redundancy (T28b).", b"".join(ogg_opus_stream(0x2004, silk_ps)))
    hybrid = [
        # (config, stereo, size, seed, count code, frames): super-wide and full band, 10 and 20 ms, the
        # seeds whose frames carry a redundancy frame (found by decoding: random bytes carry one in 4096)
        # before (pos 1) or after (pos 0) the frame, a SILK wide band packet at the same rate between (no
        # flush, the held-back CELT samples kept), CELT packets (the resampler and the CELT samples flushed).
        (13, True, 160, 49960, 0, None), (13, True, 150, 0x6001, 0, None), (15, False, 120, 46340, 0, None),
        (13, True, 130, 0x6003, 0, None), (9, True, 140, 0x6004, 0, None), (14, True, 140, 19536, 0, None),
        (12, False, 100, 13757, 0, None), (31, True, 90, 0x6007, 0, None), (12, False, 100, 17464, 0, None),
        (12, True, 200, 0x6009, 3, 3), (15, False, 120, 13782, 0, None), (14, True, 140, 52892, 0, None),
        (13, True, 160, 229909, 0, None), (30, False, 70, 0x600d, 0, None), (15, True, 180, 0x600e, 0, None),
    ]
    hybrid_ps = [opus_random_packet(c, st, seed, size, code, frames) for c, st, size, seed, code, frames in hybrid]
    ok("ogg_opus_hybrid", "Opus hybrid packets of random bytes: super-wide and full band, 10 and 20 ms, mono "
       "and stereo, frame count code 3, redundancy frames before and after the frame, SILK and CELT packets "
       "between (T28c).", b"".join(ogg_opus_stream(0x2005, hybrid_ps)))
    multistream = [
        # Per packet, each stream's (config, stereo, size): streams 0 and 1 coupled. SILK at 8, 12 and
        # 16 kHz, hybrid and CELT side by side, so the streams' resampler delays differ and the
        # sync buffers even them out.
        [(1, True, 60), (9, True, 90), (31, False, 50), (15, False, 110)],
        [(5, True, 70), (13, True, 140), (1, False, 50), (31, False, 40)],
        [(31, True, 80), (31, True, 80), (9, False, 70), (5, False, 60)],
        [(0, True, 40), (12, True, 100), (30, False, 40), (8, False, 50)],
        [(2, True, 120), (6, True, 130), (10, False, 110), (10, False, 90)],
        [(13, True, 150), (1, True, 60), (15, False, 120), (9, False, 80)],
        [(31, True, 90), (31, True, 90), (31, False, 60), (31, False, 50)],
        [(9, True, 300), (9, True, 90), (9, False, 70), (9, False, 260)],
    ]
    ms_ps = [opus_multistream_packet([opus_random_packet(c, st, 0x7100 + 4 * i + j, size)
                                      for j, (c, st, size) in enumerate(streams)])
             for i, streams in enumerate(multistream)]
    ok("ogg_opus_multistream", "Opus 5.1 (mapping family 1): four streams, two coupled, each packet's streams "
       "self-delimited but the last, their modes and SILK rates mixed, so their delays differ (FFmpeg's sync "
       "buffers, T28c).", b"".join(ogg_opus_stream(0x2006, ms_ps, head=opus_head_mapped(
           1, 4, 2, [0, 4, 1, 2, 3, 5]))))
    mapped = [
        [(9, True, 90), (31, False, 50), (1, False, 60)],
        [(13, True, 140), (9, False, 70), (15, False, 110)],
        [(31, True, 80), (31, False, 60), (31, False, 50)],
        [(5, True, 70), (1, False, 50), (9, False, 80)],
    ]
    mapped_ps = [opus_multistream_packet([opus_random_packet(c, st, 0x7200 + 4 * i + j, size)
                                          for j, (c, st, size) in enumerate(streams)])
                 for i, streams in enumerate(mapped)]
    ok("ogg_opus_mapped", "Opus of mapping family 255 with a gain of -3 dB: a silenced channel, a channel "
       "copying another (the gain applied twice, as FFmpeg's), and a stream mapped to no channel (T28c).",
       b"".join(ogg_opus_stream(0x2007, mapped_ps, head=opus_head_mapped(
           255, 3, 1, [255, 0, 1, 2, 0], gain=-768))))
    ok("ogg_vorbis_stereo", "Vorbis: identification, comment and a setup header whose mode table (a short and a "
       "long mode) the parser reads; packet durations from the block sizes, four packets to a page.",
       b"".join(ogg_vorbis_stream(0x3001, vorbis_ps)))
    ok("ogg_vorbis_granule_zero", "Vorbis data pages whose granule is 0: FFmpeg drops their timestamps "
       "(trac ticket 3710).", b"".join(ogg_vorbis_stream(0x3002, vorbis_ps, zero_granules=True)))
    ok("ogg_multiplexed", "Two logical streams, FLAC and Opus, their BOS pages first, then pages interleaved.",
       ogg_interleave(ogg_flac_stream(0x4001), ogg_opus_stream(0x4002, opus_ps)))
    ok("ogg_chained_opus", "Two Opus streams one after the other (a chain): the second replaces the first, "
       "its first packet without timestamps.",
       b"".join(ogg_opus_stream(0x5001, opus_ps[:6])) + b"".join(ogg_opus_stream(0x5002, opus_ps[:6])))
    ok("ogg_packet_spanning_pages", "A 700-byte FLAC frame continued across pages of at most 2 segments.",
       b"".join(ogg_flac_stream(0x6001, count=1152, block=1152, max_segments=2)))
    ok("ogg_junk_before_first_page", "64 zero bytes before the first page: no probe scores it, so detection "
       "falls back on the .ogg extension, and the demuxer resyncs on the capture pattern.",
       b"\x00" * 64 + b"".join(ogg_opus_stream(0x7001, opus_ps)), group="damaged")
    pages = ogg_opus_stream(0x7002, opus_ps)
    broken = bytearray(pages[3])
    broken[-1] ^= 0xFF
    ok("ogg_bad_crc_page", "A data page with a wrong CRC: FFmpeg skips it and resyncs on the next page.",
       b"".join(pages[:3]) + bytes(broken) + b"".join(pages[4:]), group="damaged")
    pages = ogg_opus_stream(0x7003, opus_ps)
    v1 = bytearray(pages[3])
    v1[4] = 1
    v1[22:26] = b"\0\0\0\0"
    v1[22:26] = struct.pack("<I", ogg_crc(bytes(v1)))
    ok("ogg_version1_page", "A data page of stream structure version 1 (with a valid CRC): FFmpeg skips it.",
       b"".join(pages[:3]) + bytes(v1) + b"".join(pages[4:]), group="damaged")
    pages = ogg_flac_stream(0x7004, count=1152, block=1152, max_segments=2)
    ok("ogg_lost_continued_page", "The first page of a packet spanning pages is lost: the next page starts with "
       "a continuation, which FFmpeg discards.", b"".join(pages[:3]) + b"".join(pages[4:]), group="damaged")
    data = b"".join(ogg_opus_stream(0x7005, opus_ps))
    ok("ogg_truncated", "The file ends inside a data page.", data[:len(data) - 30], group="damaged")
    ok("ogg_unknown_codec", "A stream of an unknown codec beside an Opus one: FFmpeg keeps it without a codec "
       "and returns none of its packets.",
       ogg_interleave(ogg_stream_pages(0x8001, [b"\x80unknown-codec", b"data" * 10], [0, 100], per_page=1),
                      ogg_opus_stream(0x8002, opus_ps)), group="damaged")
    pages = ogg_opus_stream(0x7006, opus_ps, per_page=2)
    nogp = bytearray(pages[3])
    nogp[6:14] = b"\xff" * 8
    nogp[22:26] = b"\0\0\0\0"
    nogp[22:26] = struct.pack("<I", ogg_crc(bytes(nogp)))
    ok("ogg_page_without_granule", "An Opus data page whose granule is -1 although packets end on it: "
       "FFmpeg's Opus mapping refuses the granule (above 2^62) and reading stops with an error.",
       b"".join(pages[:3]) + bytes(nogp) + b"".join(pages[4:]), group="damaged")
    granules = [0, 0, 0] + [960 * (i + 1) for i in range(len(opus_ps))]
    ok("ogg_opus_empty_first_packet", "The first Opus data packet is empty: the Opus mapping refuses it during "
       "avformat_find_stream_info's read-ahead, which ends there as at the end of the input (eof_reached), so "
       "FFmpeg opens the file and reads on after it.",
       b"".join(ogg_stream_pages(0x7007, [opus_head(), OPUS_TAGS, b""] + opus_ps, granules)), group="damaged")
    flac_data = flac_signal(1152, 2, seed=11)
    flac_frames = [flac_frame(n, [c[n * 576:(n + 1) * 576] for c in flac_data], 44100) for n in range(2)]
    first, comment = ogg_flac_headers(44100, 2, 1152, 576)
    ok("ogg_flac_empty_header_packet", "An empty FLAC header packet before a second STREAMINFO packet on the "
       "same page: FFmpeg's block type is bytestream2_get_byte's 0 for it, not the next packet's 0x7F, so the "
       "packet is skipped as a header and the file opens.",
       b"".join(ogg_stream_pages(0x7008, [first, b"", first, comment] + flac_frames, [0, 0, 0, 0, 576, 1152],
                                 per_page=3)), group="damaged")

    def opus_tags(title):
        return vorbis_comment_packet(b"OpusTags", b"generate.py", [b"TITLE=" + title], framing=False)

    ok("ogg_opus_tags_twice", "Two OpusTags packets in a row after a data packet: the second replaces the "
       "first's tags and strings-metadata side data before the next data packet takes it.",
       b"".join(ogg_stream_pages(0x7009, [opus_head(), OPUS_TAGS, opus_ps[0], opus_tags(b"first"),
                                          opus_tags(b"second")] + opus_ps[1:6],
                                 [0, 0, 960, 960, 960] + [960 * (i + 2) for i in range(5)])))

    def flac_comment(title):
        body = vorbis_comment_packet(b"", b"generate.py", [b"TITLE=" + title], framing=False)
        return b"\x84" + len(body).to_bytes(3, "big") + body

    ok("ogg_flac_comment_twice", "Two VORBIS_COMMENT packets in a row after a FLAC frame: the second replaces "
       "the first's tags and strings-metadata side data before the next frame takes it.",
       b"".join(ogg_stream_pages(0x700a, [first, comment, flac_frames[0], flac_comment(b"first"),
                                          flac_comment(b"second"), flac_frames[1]],
                                 [0, 0, 576, 576, 576, 1152], per_page=2)))
    bad("ogg_opus_short_head", "An OpusHead shorter than 19 bytes.",
        b"".join(ogg_opus_stream(0x9001, opus_ps, head=opus_head()[:15])), "INVALIDDATA")
    bad("ogg_no_pages", "OggS and nothing else: the input ends before a page.", b"OggS\x00\x02", "EOF")
    for name, (channels, rate, count, seed, options, digest) in OGG_FFMPEG.items():
        path = OGG_DIR / f"{name}.ogg"
        codec = "Vorbis" if "vorbis" in options else "Opus"
        fx.append(OggFixture(name, codec.lower(), f"FFmpeg's {codec} encoder, {count} samples at {rate} Hz, "
                             f"`{options}`; decoded by the {'T27d' if codec == 'Vorbis' else 'T28'} oracle.",
                             path.read_bytes() if path.exists() else b"", made_by="ffmpeg"))
    bad("ogg_vorbis_bad_setup", "A Vorbis setup header without a mode table the parser can find.",
        b"".join(ogg_stream_pages(0x9002, [vorbis_id_header(),
                                           vorbis_comment_packet(b"\x03vorbis", b"x", [], framing=True),
                                           b"\x05vorbis" + b"\xff" * 20] + vorbis_ps,
                                  [0, 0, 0] + list(range(100, 2100, 100)), per_page=4)), "UNKNOWN")
    return fx


def render_ogg_manifest(fixtures):
    lines = ["// Generated by zig/testing/fixtures/generate.py from its Ogg fixtures; do not edit.",
             "// Each entry names ogg/<name>.ogg; see ogg/README.md. Packets and timestamps are",
             "// FFmpeg's, in zig/testing/vectors/ogg.txt.",
             ".{"]
    for f in fixtures:
        lines.append("    .{")
        lines.append(f'        .name = "{f.name}",')
        lines.append(f'        .sha256 = "{hashlib.sha256(f.data).hexdigest()}",')
        lines.append(f'        .expected = {".accept" if f.reject is None else "." + "reject"},')
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_ogg_table(fixtures):
    rows = [TABLE_BEGIN.rstrip("\n"), "| Fixture | Group | FFmpeg opens it | Rule |", "| --- | --- | --- | --- |"]
    for f in fixtures:
        rows.append(f"| `{f.name}` | {f.group} | {'yes' if f.reject is None else '`' + f.reject + '`'} | {f.rule} |")
    rows.append(TABLE_END.rstrip("\n"))
    return "\n".join(rows) + "\n"


# MPEG audio fixtures (TODO.md T29a): frames with valid headers and arbitrary
# payloads, which FFmpeg's demuxer and parser never decode, with every kind
# of tag and info header mp3dec.c reads. What FFmpeg makes of each is
# mp3_vectors.c's (vectors/mp3.txt); the manifest records whether FFmpeg
# opens each one.

MP3_DIR = HERE / "mp3"
MP3_MANIFEST = MP3_DIR / "manifest.zon"
MP3_README = MP3_DIR / "README.md"

# mpegaudiotabs.h: kbit/s by [lsf][layer - 1][index], and the MPEG-1 rates.
MPA_BITRATES = (
    ((0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),
     (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
     (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)),
    ((0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),
     (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
     (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)),
)
MPA_FREQS = (44100, 48000, 32000)
MPA_VERSION_BITS = {"1": 3, "2": 2, "2.5": 0}


def mpa_frame_size(version, layer, bitrate, rate, padding):
    """The frame's bytes as ff_mpegaudio_decode_header computes them."""
    lsf = 0 if version == "1" else 1
    mpeg25 = 1 if version == "2.5" else 0
    sr = MPA_FREQS[rate] >> (lsf + mpeg25)
    kbps = MPA_BITRATES[lsf][layer - 1][bitrate]
    if layer == 1:
        return (kbps * 12000 // sr + padding) * 4
    if layer == 2:
        return kbps * 144000 // sr + padding
    return kbps * 144000 // (sr << lsf) + padding


def mpa_header(version="1", layer=3, bitrate=9, rate=0, padding=0, mode=0, mode_ext=0, crc=False, private=0,
               copyright=0, original=1, emphasis=0):
    h = (0xFFE00000 | MPA_VERSION_BITS[version] << 19 | (4 - layer) << 17 | (0 if crc else 1) << 16
         | bitrate << 12 | rate << 10 | padding << 9 | private << 8 | mode << 6 | mode_ext << 4
         | copyright << 3 | original << 2 | emphasis)
    return struct.pack(">I", h)


def mpa_payload(seed, n):
    """`n` bytes of a 32-bit LCG's high bytes, 0xFF made 0xFE so that no
    frame payload holds a sync word."""
    out = bytearray()
    state = seed & 0xFFFFFFFF
    while len(out) < n:
        state = (state * 1103515245 + 12345) & 0xFFFFFFFF
        b = state >> 24
        out.append(0xFE if b == 0xFF else b)
    return bytes(out)


def mpa_frame(seed, body=b"", **header):
    """A frame: the header, then `body`, then payload bytes to its size."""
    size = mpa_frame_size(header.get("version", "1"), header.get("layer", 3), header.get("bitrate", 9),
                          header.get("rate", 0), header.get("padding", 0))
    head = mpa_header(**header) + body
    assert len(head) <= size
    return head + mpa_payload(seed, size - len(head))


def mpa_frames(count, seed=1, pad_every=3, **header):
    """`count` frames, every `pad_every`th padded (none for 0)."""
    return [mpa_frame(seed * 1000 + i, padding=1 if pad_every and i % pad_every == 0 else 0, **header)
            for i in range(count)]


# --- Layer III streams that decode to audio (T29b) -------------------------
#
# The reference build has no MP3 encoder, so these streams are written here:
# side information, scalefactors and spectra coded with FFmpeg's own
# Huffman tables (mpegaudiodec_common.c at the pinned revision, transcribed
# below), laid out in frames with the bit reservoir as ISO 11172-3 and
# 13818-3 define it. Nothing here models a psychoacoustic encoder: the
# spectra are pseudo-random within each Huffman table's range, chosen so that
# every table, block type, stereo mode and scalefactor layout the decoder
# reads appears. What FFmpeg's mp3float decoder makes of each stream is
# mp3_decode_vectors.c's (vectors/mp3_decode.txt).

# mpegaudiodec_common.c's Layer III tables, transcribed (FFmpeg 5d5a38a; LGPL-2.1-or-later,
# copyright the FFmpeg authors): code lengths and symbols per Huffman table in
# ff_vlc_init_from_lengths order, table sizes, ff_mpa_huff_data's (table,
# linbits) by table_select, the count1 tables, scalefactor sizes, the LSF
# scalefactor partitions and the scalefactor band sizes by sample rate index.
MPA_HUFFLENS = (
    3, 3, 2, 1, 6, 6, 5, 5, 5, 3, 3, 3, 1, 6, 6, 5, 5, 5, 3, 2, 2, 2, 8, 8, 7, 6, 7, 7, 7, 7, 6, 6, 6, 6, 3, 3,
    3, 1, 7, 7, 6, 6, 6, 5, 5, 5, 5, 4, 4, 4, 3, 2, 3, 3, 10, 10, 10, 10, 9, 9, 9, 9, 8, 8, 9, 9, 8, 9, 9, 8, 8,
    7, 7, 7, 8, 8, 8, 8, 7, 7, 7, 7, 6, 5, 6, 6, 4, 3, 3, 1, 11, 11, 10, 9, 10, 10, 9, 9, 9, 8, 8, 9, 9, 9, 9,
    8, 8, 8, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 6, 4, 4, 2, 3, 3, 2, 9, 9, 8, 8, 9, 9, 8, 8, 8, 8, 7, 7, 7, 8, 8,
    7, 7, 7, 7, 6, 6, 6, 6, 5, 5, 6, 6, 5, 5, 4, 4, 4, 3, 3, 3, 3, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10,
    10, 10, 11, 11, 10, 9, 9, 10, 10, 9, 9, 10, 10, 9, 10, 10, 8, 8, 9, 9, 10, 10, 9, 9, 10, 10, 8, 8, 8, 9, 9,
    9, 9, 9, 9, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 6, 6, 6, 6, 4, 3, 3, 1, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10,
    10, 9, 9, 9, 10, 10, 10, 10, 8, 8, 9, 9, 7, 8, 8, 8, 8, 8, 9, 9, 9, 9, 8, 7, 8, 8, 7, 7, 8, 8, 8, 9, 9, 8,
    8, 8, 8, 8, 8, 7, 7, 6, 6, 7, 7, 6, 5, 4, 5, 5, 3, 3, 3, 2, 10, 10, 9, 9, 9, 9, 9, 9, 9, 8, 8, 9, 9, 8, 8,
    8, 8, 8, 8, 9, 9, 8, 8, 8, 8, 8, 9, 9, 7, 7, 7, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 8, 8, 7, 7, 7, 6, 6, 6, 6, 7,
    7, 6, 5, 5, 5, 4, 4, 5, 5, 4, 3, 3, 3, 19, 19, 18, 17, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 15,
    15, 16, 16, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 16, 16, 15, 16, 16, 14, 14, 15, 15, 15, 15, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 14, 13, 14, 14, 13, 13, 14, 14, 13, 14, 14, 13, 14, 14, 13, 14, 14,
    13, 13, 14, 14, 12, 12, 12, 13, 13, 13, 13, 13, 13, 12, 13, 13, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    13, 13, 13, 12, 12, 13, 13, 12, 12, 12, 12, 13, 13, 13, 13, 12, 13, 13, 12, 11, 12, 12, 12, 12, 12, 12, 12,
    12, 11, 11, 11, 11, 12, 12, 11, 11, 12, 12, 11, 12, 12, 12, 12, 11, 11, 12, 12, 11, 12, 12, 11, 12, 12, 11,
    12, 12, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 11, 11, 10, 11, 11, 10, 11, 11, 11, 11,
    10, 10, 11, 11, 10, 10, 11, 11, 11, 11, 11, 11, 9, 9, 10, 10, 10, 10, 10, 11, 11, 9, 9, 9, 10, 10, 9, 9, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 8, 9, 9, 9, 9, 9, 9, 10, 10, 9, 9, 9, 8, 8, 9, 9, 9, 9, 9, 9, 8, 7, 8,
    8, 8, 8, 7, 7, 7, 7, 7, 6, 6, 6, 6, 4, 4, 3, 1, 13, 13, 13, 13, 12, 13, 13, 13, 13, 13, 13, 12, 13, 13, 12,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 11, 11, 12,
    12, 12, 12, 11, 11, 11, 11, 11, 11, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 11, 11, 11, 11, 11, 11,
    10, 11, 11, 11, 11, 11, 11, 10, 10, 11, 11, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10,
    10, 10, 10, 10, 11, 11, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 9, 10, 10, 9,
    10, 10, 10, 10, 10, 10, 10, 10, 9, 9, 9, 9, 9, 9, 9, 10, 10, 9, 9, 9, 9, 9, 9, 10, 10, 9, 9, 9, 9, 9, 9, 8,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 8, 8, 8, 8, 8, 8, 9, 9, 8, 8, 8, 8, 8, 8,
    8, 9, 9, 8, 7, 8, 8, 7, 7, 7, 7, 8, 8, 7, 7, 7, 7, 7, 6, 7, 7, 6, 6, 7, 7, 6, 6, 6, 5, 5, 5, 5, 5, 3, 4, 4,
    3, 11, 11, 11, 11, 11, 11, 11, 11, 10, 11, 11, 11, 11, 10, 10, 10, 10, 10, 8, 10, 10, 9, 9, 9, 9, 10, 16,
    17, 17, 15, 15, 16, 16, 14, 15, 15, 14, 14, 15, 15, 14, 14, 15, 15, 15, 15, 14, 15, 15, 14, 13, 8, 9, 9, 8,
    8, 13, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 13, 13, 14, 14, 14, 14, 13, 14, 14, 13, 13, 13, 14, 14, 14,
    14, 13, 13, 14, 14, 13, 14, 14, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 12, 13, 13, 13,
    13, 13, 13, 12, 13, 13, 12, 12, 13, 13, 11, 12, 12, 12, 12, 12, 12, 12, 13, 13, 11, 12, 12, 12, 12, 11, 12,
    12, 12, 12, 12, 12, 12, 12, 11, 12, 12, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 11, 12, 12, 11, 12,
    12, 11, 12, 12, 11, 12, 12, 11, 10, 10, 11, 11, 11, 11, 11, 11, 10, 10, 11, 11, 10, 10, 11, 11, 11, 11, 11,
    11, 11, 11, 10, 11, 11, 10, 10, 10, 11, 11, 10, 10, 11, 11, 10, 10, 11, 11, 10, 9, 9, 10, 10, 10, 10, 10,
    10, 9, 9, 9, 10, 10, 9, 10, 10, 9, 9, 8, 9, 9, 9, 9, 9, 9, 9, 9, 8, 8, 9, 9, 8, 8, 7, 7, 8, 8, 7, 6, 6, 6,
    6, 4, 4, 3, 1, 8, 8, 8, 8, 8, 8, 8, 8, 7, 8, 8, 7, 7, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 9, 11,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    4, 11, 11, 11, 11, 12, 12, 11, 10, 11, 11, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 10, 11,
    11, 10, 9, 10, 10, 10, 10, 11, 11, 10, 9, 9, 10, 10, 9, 10, 10, 10, 10, 9, 9, 10, 10, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 9, 9, 9, 10,
    10, 8, 9, 9, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 8, 8, 8, 8, 8, 8, 9, 9, 7, 8, 8, 7, 7, 7, 7, 7, 8,
    8, 7, 7, 6, 6, 7, 7, 6, 5, 5, 6, 6, 4, 4, 4, 4,
)
MPA_HUFFSYMBOLS = (
    0x11, 0x01, 0x10, 0x00, 0x22, 0x02, 0x12, 0x21, 0x20, 0x11, 0x01, 0x10, 0x00, 0x22, 0x02, 0x12, 0x21, 0x20,
    0x10, 0x11, 0x01, 0x00, 0x33, 0x23, 0x32, 0x31, 0x13, 0x03, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0x33, 0x03, 0x23, 0x32, 0x30, 0x13, 0x31, 0x22, 0x02, 0x12, 0x21, 0x20, 0x01, 0x11, 0x10, 0x00,
    0x55, 0x45, 0x54, 0x53, 0x35, 0x44, 0x25, 0x52, 0x15, 0x51, 0x05, 0x34, 0x50, 0x43, 0x33, 0x24, 0x42, 0x14,
    0x41, 0x40, 0x04, 0x23, 0x32, 0x03, 0x13, 0x31, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01, 0x10, 0x00,
    0x55, 0x54, 0x45, 0x53, 0x35, 0x44, 0x25, 0x52, 0x05, 0x15, 0x51, 0x34, 0x43, 0x50, 0x33, 0x24, 0x42, 0x14,
    0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x02, 0x20, 0x12, 0x21, 0x11, 0x01, 0x10, 0x00,
    0x55, 0x45, 0x35, 0x53, 0x54, 0x05, 0x44, 0x25, 0x52, 0x15, 0x51, 0x34, 0x43, 0x50, 0x04, 0x24, 0x42, 0x33,
    0x40, 0x14, 0x41, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x02, 0x12, 0x21, 0x20, 0x11, 0x01, 0x10, 0x00,
    0x77, 0x67, 0x76, 0x57, 0x75, 0x66, 0x47, 0x74, 0x56, 0x65, 0x37, 0x73, 0x46, 0x55, 0x54, 0x63, 0x27, 0x72,
    0x64, 0x07, 0x70, 0x62, 0x45, 0x35, 0x06, 0x53, 0x44, 0x17, 0x71, 0x36, 0x26, 0x25, 0x52, 0x15, 0x51, 0x34,
    0x43, 0x16, 0x61, 0x60, 0x05, 0x50, 0x24, 0x42, 0x33, 0x04, 0x14, 0x41, 0x40, 0x23, 0x32, 0x03, 0x13, 0x31,
    0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01, 0x10, 0x00, 0x77, 0x67, 0x76, 0x75, 0x66, 0x47, 0x74, 0x57,
    0x55, 0x56, 0x65, 0x37, 0x73, 0x46, 0x45, 0x54, 0x35, 0x53, 0x27, 0x72, 0x64, 0x07, 0x71, 0x17, 0x70, 0x36,
    0x63, 0x60, 0x44, 0x25, 0x52, 0x05, 0x15, 0x62, 0x26, 0x06, 0x16, 0x61, 0x51, 0x34, 0x50, 0x43, 0x33, 0x24,
    0x42, 0x14, 0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x21, 0x12, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0x77, 0x67, 0x76, 0x57, 0x75, 0x66, 0x47, 0x74, 0x65, 0x56, 0x37, 0x73, 0x55, 0x27, 0x72, 0x46,
    0x64, 0x17, 0x71, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x44, 0x06, 0x05, 0x26, 0x62, 0x61, 0x16, 0x60, 0x35,
    0x53, 0x25, 0x52, 0x15, 0x51, 0x34, 0x43, 0x50, 0x04, 0x24, 0x42, 0x14, 0x33, 0x41, 0x23, 0x32, 0x40, 0x03,
    0x30, 0x13, 0x31, 0x22, 0x12, 0x21, 0x02, 0x20, 0x00, 0x11, 0x01, 0x10, 0xFE, 0xFC, 0xFD, 0xED, 0xFF, 0xEF,
    0xDF, 0xEE, 0xCF, 0xDE, 0xBF, 0xFB, 0xCE, 0xDC, 0xAF, 0xE9, 0xEC, 0xDD, 0xFA, 0xCD, 0xBE, 0xEB, 0x9F, 0xF9,
    0xEA, 0xBD, 0xDB, 0x8F, 0xF8, 0xCC, 0xAE, 0x9E, 0x8E, 0x7F, 0x7E, 0xF7, 0xDA, 0xAD, 0xBC, 0xCB, 0xF6, 0x6F,
    0xE8, 0x5F, 0x9D, 0xD9, 0xF5, 0xE7, 0xAC, 0xBB, 0x4F, 0xF4, 0xCA, 0xE6, 0xF3, 0x3F, 0x8D, 0xD8, 0x2F, 0xF2,
    0x6E, 0x9C, 0x0F, 0xC9, 0x5E, 0xAB, 0x7D, 0xD7, 0x4E, 0xC8, 0xD6, 0x3E, 0xB9, 0x9B, 0xAA, 0x1F, 0xF1, 0xF0,
    0xBA, 0xE5, 0xE4, 0x8C, 0x6D, 0xE3, 0xE2, 0x2E, 0x0E, 0x1E, 0xE1, 0xE0, 0x5D, 0xD5, 0x7C, 0xC7, 0x4D, 0x8B,
    0xB8, 0xD4, 0x9A, 0xA9, 0x6C, 0xC6, 0x3D, 0xD3, 0x7B, 0x2D, 0xD2, 0x1D, 0xB7, 0x5C, 0xC5, 0x99, 0x7A, 0xC3,
    0xA7, 0x97, 0x4B, 0xD1, 0x0D, 0xD0, 0x8A, 0xA8, 0x4C, 0xC4, 0x6B, 0xB6, 0x3C, 0x2C, 0xC2, 0x5B, 0xB5, 0x89,
    0x1C, 0xC1, 0x98, 0x0C, 0xC0, 0xB4, 0x6A, 0xA6, 0x79, 0x3B, 0xB3, 0x88, 0x5A, 0x2B, 0xA5, 0x69, 0xA4, 0x78,
    0x87, 0x94, 0x77, 0x76, 0xB2, 0x1B, 0xB1, 0x0B, 0xB0, 0x96, 0x4A, 0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2, 0x1A,
    0xA1, 0x0A, 0x68, 0xA0, 0x86, 0x49, 0x93, 0x39, 0x58, 0x85, 0x67, 0x29, 0x92, 0x57, 0x75, 0x38, 0x83, 0x66,
    0x47, 0x74, 0x56, 0x65, 0x73, 0x19, 0x91, 0x09, 0x90, 0x48, 0x84, 0x72, 0x46, 0x64, 0x28, 0x82, 0x18, 0x37,
    0x27, 0x17, 0x71, 0x55, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x35, 0x81, 0x08, 0x80, 0x16, 0x61,
    0x06, 0x60, 0x53, 0x44, 0x25, 0x52, 0x05, 0x15, 0x51, 0x34, 0x43, 0x50, 0x24, 0x42, 0x33, 0x14, 0x41, 0x04,
    0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01, 0x10, 0x00, 0xFF, 0xEF,
    0xFE, 0xDF, 0xEE, 0xFD, 0xCF, 0xFC, 0xDE, 0xED, 0xBF, 0xFB, 0xCE, 0xEC, 0xDD, 0xAF, 0xFA, 0xBE, 0xEB, 0xCD,
    0xDC, 0x9F, 0xF9, 0xEA, 0xBD, 0xDB, 0x8F, 0xF8, 0xCC, 0x9E, 0xE9, 0x7F, 0xF7, 0xAD, 0xDA, 0xBC, 0x6F, 0xAE,
    0x0F, 0xCB, 0xF6, 0x8E, 0xE8, 0x5F, 0x9D, 0xF5, 0x7E, 0xE7, 0xAC, 0xCA, 0xBB, 0xD9, 0x8D, 0x4F, 0xF4, 0x3F,
    0xF3, 0xD8, 0xE6, 0x2F, 0xF2, 0x6E, 0xF0, 0x1F, 0xF1, 0x9C, 0xC9, 0x5E, 0xAB, 0xBA, 0xE5, 0x7D, 0xD7, 0x4E,
    0xE4, 0x8C, 0xC8, 0x3E, 0x6D, 0xD6, 0xE3, 0x9B, 0xB9, 0x2E, 0xAA, 0xE2, 0x1E, 0xE1, 0x0E, 0xE0, 0x5D, 0xD5,
    0x7C, 0xC7, 0x4D, 0x8B, 0xD4, 0xB8, 0x9A, 0xA9, 0x6C, 0xC6, 0x3D, 0xD3, 0xD2, 0x2D, 0x0D, 0x1D, 0x7B, 0xB7,
    0xD1, 0x5C, 0xD0, 0xC5, 0x8A, 0xA8, 0x4C, 0xC4, 0x6B, 0xB6, 0x99, 0x0C, 0x3C, 0xC3, 0x7A, 0xA7, 0xA6, 0xC0,
    0x0B, 0xC2, 0x2C, 0x5B, 0xB5, 0x1C, 0x89, 0x98, 0xC1, 0x4B, 0xB4, 0x6A, 0x3B, 0x79, 0xB3, 0x97, 0x88, 0x2B,
    0x5A, 0xB2, 0xA5, 0x1B, 0xB1, 0xB0, 0x69, 0x96, 0x4A, 0xA4, 0x78, 0x87, 0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2,
    0x1A, 0xA1, 0x0A, 0xA0, 0x68, 0x86, 0x49, 0x94, 0x39, 0x93, 0x77, 0x09, 0x58, 0x85, 0x29, 0x67, 0x76, 0x92,
    0x91, 0x19, 0x90, 0x48, 0x84, 0x57, 0x75, 0x38, 0x83, 0x66, 0x47, 0x28, 0x82, 0x18, 0x81, 0x74, 0x08, 0x80,
    0x56, 0x65, 0x37, 0x73, 0x46, 0x27, 0x72, 0x64, 0x17, 0x55, 0x71, 0x07, 0x70, 0x36, 0x63, 0x45, 0x54, 0x26,
    0x62, 0x16, 0x06, 0x60, 0x35, 0x61, 0x53, 0x44, 0x25, 0x52, 0x15, 0x51, 0x05, 0x50, 0x34, 0x43, 0x24, 0x42,
    0x33, 0x41, 0x14, 0x04, 0x23, 0x32, 0x40, 0x03, 0x13, 0x31, 0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01,
    0x10, 0x00, 0xEF, 0xFE, 0xDF, 0xFD, 0xCF, 0xFC, 0xBF, 0xFB, 0xAF, 0xFA, 0x9F, 0xF9, 0xF8, 0x8F, 0x7F, 0xF7,
    0x6F, 0xF6, 0xFF, 0x5F, 0xF5, 0x4F, 0xF4, 0xF3, 0xF0, 0x3F, 0xCE, 0xEC, 0xDD, 0xDE, 0xE9, 0xEA, 0xD9, 0xEE,
    0xED, 0xEB, 0xBE, 0xCD, 0xDC, 0xDB, 0xAE, 0xCC, 0xAD, 0xDA, 0x7E, 0xAC, 0xCA, 0xC9, 0x7D, 0x5E, 0xBD, 0xF2,
    0x2F, 0x0F, 0x1F, 0xF1, 0x9E, 0xBC, 0xCB, 0x8E, 0xE8, 0x9D, 0xE7, 0xBB, 0x8D, 0xD8, 0x6E, 0xE6, 0x9C, 0xAB,
    0xBA, 0xE5, 0xD7, 0x4E, 0xE4, 0x8C, 0xC8, 0x3E, 0x6D, 0xD6, 0x9B, 0xB9, 0xAA, 0xE1, 0xD4, 0xB8, 0xA9, 0x7B,
    0xB7, 0xD0, 0xE3, 0x0E, 0xE0, 0x5D, 0xD5, 0x7C, 0xC7, 0x4D, 0x8B, 0x9A, 0x6C, 0xC6, 0x3D, 0x5C, 0xC5, 0x0D,
    0x8A, 0xA8, 0x99, 0x4C, 0xB6, 0x7A, 0x3C, 0x5B, 0x89, 0x1C, 0xC0, 0x98, 0x79, 0xE2, 0x2E, 0x1E, 0xD3, 0x2D,
    0xD2, 0xD1, 0x3B, 0x97, 0x88, 0x1D, 0xC4, 0x6B, 0xC3, 0xA7, 0x2C, 0xC2, 0xB5, 0xC1, 0x0C, 0x4B, 0xB4, 0x6A,
    0xA6, 0xB3, 0x5A, 0xA5, 0x2B, 0xB2, 0x1B, 0xB1, 0x0B, 0xB0, 0x69, 0x96, 0x4A, 0xA4, 0x78, 0x87, 0xA3, 0x3A,
    0x59, 0x2A, 0x95, 0x68, 0xA1, 0x86, 0x77, 0x94, 0x49, 0x57, 0x67, 0xA2, 0x1A, 0x0A, 0xA0, 0x39, 0x93, 0x58,
    0x85, 0x29, 0x92, 0x76, 0x09, 0x19, 0x91, 0x90, 0x48, 0x84, 0x75, 0x38, 0x83, 0x66, 0x28, 0x82, 0x47, 0x74,
    0x18, 0x81, 0x80, 0x08, 0x56, 0x37, 0x73, 0x65, 0x46, 0x27, 0x72, 0x64, 0x55, 0x07, 0x17, 0x71, 0x70, 0x36,
    0x63, 0x45, 0x54, 0x26, 0x62, 0x16, 0x61, 0x06, 0x60, 0x53, 0x35, 0x44, 0x25, 0x52, 0x51, 0x15, 0x05, 0x34,
    0x43, 0x50, 0x24, 0x42, 0x33, 0x14, 0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03, 0x30, 0x22, 0x12, 0x21,
    0x02, 0x20, 0x11, 0x01, 0x10, 0x00, 0xEF, 0xFE, 0xDF, 0xFD, 0xCF, 0xFC, 0xBF, 0xFB, 0xFA, 0xAF, 0x9F, 0xF9,
    0xF8, 0x8F, 0x7F, 0xF7, 0x6F, 0xF6, 0x5F, 0xF5, 0x4F, 0xF4, 0x3F, 0xF3, 0x2F, 0xF2, 0xF1, 0x1F, 0xF0, 0x0F,
    0xEE, 0xDE, 0xED, 0xCE, 0xEC, 0xDD, 0xBE, 0xEB, 0xCD, 0xDC, 0xAE, 0xEA, 0xBD, 0xDB, 0xCC, 0x9E, 0xE9, 0xAD,
    0xDA, 0xBC, 0xCB, 0x8E, 0xE8, 0x9D, 0xD9, 0x7E, 0xE7, 0xAC, 0xFF, 0xCA, 0xBB, 0x8D, 0xD8, 0x0E, 0xE0, 0x0D,
    0xE6, 0x6E, 0x9C, 0xC9, 0x5E, 0xBA, 0xE5, 0xAB, 0x7D, 0xD7, 0xE4, 0x8C, 0xC8, 0x4E, 0x2E, 0x3E, 0x6D, 0xD6,
    0xE3, 0x9B, 0xB9, 0xAA, 0xE2, 0x1E, 0xE1, 0x5D, 0xD5, 0x7C, 0xC7, 0x4D, 0x8B, 0xB8, 0xD4, 0x9A, 0xA9, 0x6C,
    0xC6, 0x3D, 0xD3, 0x2D, 0xD2, 0x1D, 0x7B, 0xB7, 0xD1, 0x5C, 0xC5, 0x8A, 0xA8, 0x99, 0x4C, 0xC4, 0x6B, 0xB6,
    0xD0, 0x0C, 0x3C, 0xC3, 0x7A, 0xA7, 0x2C, 0xC2, 0x5B, 0xB5, 0x1C, 0x89, 0x98, 0xC1, 0x4B, 0xC0, 0x0B, 0x3B,
    0xB0, 0x0A, 0x1A, 0xB4, 0x6A, 0xA6, 0x79, 0x97, 0xA0, 0x09, 0x90, 0xB3, 0x88, 0x2B, 0x5A, 0xB2, 0xA5, 0x1B,
    0xB1, 0x69, 0x96, 0xA4, 0x4A, 0x78, 0x87, 0x3A, 0xA3, 0x59, 0x95, 0x2A, 0xA2, 0xA1, 0x68, 0x86, 0x77, 0x49,
    0x94, 0x39, 0x93, 0x58, 0x85, 0x29, 0x67, 0x76, 0x92, 0x19, 0x91, 0x48, 0x84, 0x57, 0x75, 0x38, 0x83, 0x66,
    0x28, 0x82, 0x18, 0x47, 0x74, 0x81, 0x08, 0x80, 0x56, 0x65, 0x17, 0x07, 0x70, 0x73, 0x37, 0x27, 0x72, 0x46,
    0x64, 0x55, 0x71, 0x36, 0x63, 0x45, 0x54, 0x26, 0x62, 0x16, 0x61, 0x06, 0x60, 0x35, 0x53, 0x44, 0x25, 0x52,
    0x15, 0x05, 0x50, 0x51, 0x34, 0x43, 0x24, 0x42, 0x33, 0x14, 0x41, 0x04, 0x40, 0x23, 0x32, 0x13, 0x31, 0x03,
    0x30, 0x22, 0x12, 0x21, 0x02, 0x20, 0x11, 0x01, 0x10, 0x00,
)
MPA_HUFF_SIZES = (4, 9, 9, 16, 16, 36, 36, 36, 64, 64, 64, 256, 256, 256, 256)
MPA_HUFF_DATA = ((0, 0), (1, 0), (2, 0), (3, 0), (0, 0), (4, 0), (5, 0), (6, 0), (7, 0), (8, 0), (9, 0), (10, 0), (11, 0), (12, 0), (0, 0), (13, 0), (14, 1), (14, 2), (14, 3), (14, 4), (14, 6), (14, 8), (14, 10), (14, 13), (15, 4), (15, 5), (15, 6), (15, 7), (15, 8), (15, 9), (15, 11), (15, 13))
MPA_QUAD_CODES = (
    (1, 5, 4, 5, 6, 5, 4, 4, 7, 3, 6, 0, 7, 2, 3, 1,),
    (15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,),
)
MPA_QUAD_BITS = (
    (1, 4, 4, 5, 4, 6, 5, 6, 4, 5, 5, 6, 5, 6, 6, 6,),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,),
)
MPA_SLEN = (
    (0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4,),
    (0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3,),
)
MPA_LSF_NSF = (
    ((6, 5, 5, 5), (9, 9, 9, 9), (6, 9, 9, 9)),
    ((6, 5, 7, 3), (9, 9, 12, 6), (6, 9, 12, 6)),
    ((11, 10, 0, 0), (18, 18, 0, 0), (15, 18, 0, 0)),
    ((7, 7, 7, 0), (12, 12, 12, 0), (6, 15, 12, 0)),
    ((6, 6, 6, 3), (12, 9, 9, 6), (6, 12, 9, 6)),
    ((8, 8, 5, 0), (15, 12, 9, 0), (6, 18, 9, 0)),
)
MPA_BAND_SIZE_LONG = (
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158,),
    (4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192,),
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26,),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54,),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36,),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54,),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54,),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54,),
    (12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2,),
)
MPA_BAND_SIZE_SHORT = (
    (4, 4, 4, 4, 6, 8, 10, 12, 14, 18, 22, 30, 56,),
    (4, 4, 4, 4, 6, 6, 10, 12, 14, 16, 20, 26, 66,),
    (4, 4, 4, 4, 6, 8, 12, 16, 20, 26, 34, 42, 12,),
    (4, 4, 4, 6, 6, 8, 10, 14, 18, 26, 32, 42, 18,),
    (4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 32, 44, 12,),
    (4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18,),
    (4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18,),
    (4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18,),
    (8, 8, 8, 12, 16, 20, 24, 28, 36, 2, 2, 2, 26,),
)
MPA_PRETAB = (
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,),
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0,),
)


def mpa_huff_codes(table):
    """Huffman table `table` (1-15, the decoder's ff_huff_vlc index) as
    {(x, y): (code, bits)}, with the codes ff_vlc_init_from_lengths assigns:
    in table order, each the next left-aligned 32-bit code of its length."""
    start = sum(MPA_HUFF_SIZES[:table - 1])
    codes = {}
    code = 0
    for i in range(MPA_HUFF_SIZES[table - 1]):
        length, symbol = MPA_HUFFLENS[start + i], MPA_HUFFSYMBOLS[start + i]
        codes[(symbol >> 4, symbol & 15)] = (code >> (32 - length), length)
        code += 1 << (32 - length)
    assert code == 1 << 32, table
    return codes


MPA_HUFF_CODES = {t: mpa_huff_codes(t) for t in range(1, 16)}
# The largest |value| each table_select codes: its table's largest symbol,
# plus its linbits beyond 15 (0 for the empty tables 0, 4 and 14).
MPA_TABLE_MAX = tuple(
    0 if not table else (15 + (1 << linbits) - 1 if max(x for x, _ in MPA_HUFF_CODES[table]) == 15 else
                         max(x for x, _ in MPA_HUFF_CODES[table]))
    for table, linbits in MPA_HUFF_DATA)
MPA_BAND_INDEX_LONG = tuple(tuple(sum(size >> 1 for size in row[:j]) for j in range(23)) for row in MPA_BAND_SIZE_LONG)


class Lcg:
    """A 32-bit LCG (Numerical Recipes), stable across Python versions."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self):
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.state

    def below(self, n):
        return (self.next() >> 8) % n

    def chance(self, numerator, denominator):
        return self.below(denominator) < numerator


def mpa_crc16(data, crc=0xFFFF):
    """ISO 11172-3's CRC-16 (polynomial 0x8005), MSB first."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class L3Granule:
    """One granule of one channel: its side information and spectrum."""

    def __init__(self):
        self.block_type = 0
        self.window_switching = False
        self.mixed = False
        self.table_select = [0, 0, 0]
        self.subblock_gain = [0, 0, 0]
        self.region0 = 0  # region_address1 (long blocks)
        self.region1 = 0  # region_address2
        self.global_gain = 160
        self.scalefac_compress = 0
        self.scalefac_scale = 0
        self.preflag = 0
        self.count1table = 0
        self.scalefactors = []  # (bits, value) in bitstream order
        self.values = [0] * 576  # quantized spectrum, bitstream order
        self.big_values = 0
        self.count1_end = 0  # samples covered by big values and count1 quads
        self.part2_3_length = None  # set by `encode`, or forced
        self.bits = None


def l3_regions(g, rate_index):
    """region_size[0..2] in pairs, as the decoder's init_*_region and
    region_offset2size compute them from the side information."""
    if g.window_switching:
        if g.block_type == 2:
            sizes = [72 // 2 if rate_index == 8 else 36 // 2, 576 // 2]
        elif rate_index <= 2:
            sizes = [36 // 2, 576 // 2]
        elif rate_index != 8:
            sizes = [54 // 2, 576 // 2]
        else:
            sizes = [108 // 2, 576 // 2]
    else:
        index = MPA_BAND_INDEX_LONG[rate_index]
        sizes = [index[g.region0 + 1], index[min(g.region0 + g.region1 + 2, 22)]]
    sizes.append(576 // 2)
    out, j = [], 0
    for s in sizes:
        k = min(s, g.big_values)
        out.append(k - j)
        j = k
    return out


def l3_encode(g, rate_index):
    """The granule's part 2 and 3 (scalefactors, then the Huffman-coded
    spectrum) as a BitWriter, in the order huffman_decode reads it."""
    w = BitWriter()
    for bits, value in g.scalefactors:
        w.put(bits, value)
    s = 0
    for region, pairs in enumerate(l3_regions(g, rate_index)):
        table, linbits = MPA_HUFF_DATA[g.table_select[region]]
        for _ in range(pairs):
            x, y = g.values[s], g.values[s + 1]
            s += 2
            if not table:
                assert x == 0 and y == 0, "a value in a region of an empty table"
                continue
            ax, ay = abs(x), abs(y)
            assert max(ax, ay) <= MPA_TABLE_MAX[g.table_select[region]], (g.table_select[region], ax, ay)
            code, length = MPA_HUFF_CODES[table][(min(ax, 15), min(ay, 15))]
            w.put(length, code)
            for v, a in ((x, ax), (y, ay)):
                if a >= 15 and linbits:
                    w.put(linbits, a - 15)
                if a:
                    w.put(1, 1 if v < 0 else 0)
    while s < g.count1_end:
        quad = g.values[s:s + 4]
        assert all(abs(v) <= 1 for v in quad)
        q = sum(1 << (3 - i) for i, v in enumerate(quad) if v)
        w.put(MPA_QUAD_BITS[g.count1table][q], MPA_QUAD_CODES[g.count1table][q])
        for v in quad:
            if v:
                w.put(1, 1 if v < 0 else 0)
        s += 4
    return w


def l3_side_info(granules, lsf, channels, main_data_begin, scfsi, private=0):
    """The side information as mp_decode_layer3 reads it."""
    w = BitWriter()
    if lsf:
        w.put(8, main_data_begin)
        w.put(channels, private)
    else:
        w.put(9, main_data_begin)
        w.put(5 if channels == 1 else 3, private)
        for ch in range(channels):
            w.put(4, scfsi[ch])
    for gr in granules:
        for g in gr:
            w.put(12, g.part2_3_length)
            w.put(9, g.big_values)
            w.put(8, g.global_gain)
            w.put(9 if lsf else 4, g.scalefac_compress)
            w.put(1, 1 if g.window_switching else 0)
            if g.window_switching:
                w.put(2, g.block_type)
                w.put(1, 1 if g.mixed else 0)
                for t in g.table_select[:2]:
                    w.put(5, t)
                for sb in g.subblock_gain:
                    w.put(3, sb)
            else:
                for t in g.table_select:
                    w.put(5, t)
                w.put(4, g.region0)
                w.put(3, g.region1)
            if not lsf:
                w.put(1, g.preflag)
            w.put(1, g.scalefac_scale)
            w.put(1, g.count1table)
    w.align()
    return w.bytes()


def l3_scalefactors(rng, g, lsf, gr, scfsi, intensity_ch1=False, is_scale=0, shared=None):
    """Chooses `g.scalefac_compress` and its scalefactors, written into
    `g.scalefactors`. For MPEG-1 granule 1, `scfsi`'s groups are not sent
    (the decoder copies granule 0's)."""
    g.scalefactors = []
    if not lsf:
        g.scalefac_compress = rng.below(16)
        slen1, slen2 = MPA_SLEN[0][g.scalefac_compress], MPA_SLEN[1][g.scalefac_compress]
        if g.block_type == 2:
            for count, slen in ((17 if g.mixed else 18, slen1), (18, slen2)):
                g.scalefactors += [(slen, rng.below(1 << slen) if slen else 0) for _ in range(count) if slen]
            return
        for k, n in enumerate((6, 5, 5, 5)):
            if gr == 1 and scfsi & (8 >> k):
                continue
            slen = slen1 if k < 2 else slen2
            if slen:
                g.scalefactors += [(slen, rng.below(1 << slen)) for _ in range(n)]
        return
    # MPEG-2 and 2.5: a case of the decoder's split, then scalefactor
    # sizes within its moduli, composed into the 9-bit scalefac_compress
    # lsf_sf_expand splits again (a modulus of 1 is a size of 0).
    tindex = (2 if g.mixed else 1) if g.block_type == 2 else 0
    if intensity_ch1:
        cases = ((0, (5, 6, 6, 1), 3), (180, (4, 4, 4, 1), 4), (244, (4, 3, 1, 1), 5))
    else:
        cases = ((0, (5, 5, 4, 4), 0), (400, (5, 5, 4, 1), 1), (500, (4, 3, 1, 1), 2))
    base, moduli, tindex2 = cases[rng.below(3)]
    slen = [rng.below(m) for m in moduli]
    sf = slen[0]
    for v, m in zip(slen[1:], moduli[1:]):
        if m > 1:
            sf = sf * m + v
    sf += base
    g.scalefac_compress = sf << 1 | is_scale if intensity_ch1 else sf
    if tindex2 == 2:
        g.preflag = 1  # the decoder sets it for this case
    for k in range(4):
        n, sl = MPA_LSF_NSF[tindex2][tindex][k], slen[k]
        if sl:
            g.scalefactors += [(sl, rng.below(1 << sl)) for _ in range(n)]


def l3_spectrum(rng, g, rate_index, budget_bits, peak):
    """Fills `g`'s spectrum, tables and regions within `budget_bits` of
    part 2 and 3: big values whose size decays with frequency, up to `peak`,
    then count1 quads. Shrinks until it fits."""
    nonzero = min(576, max(8, budget_bits // 3))
    while True:
        g.values = [0] * 576
        bv = min(288, nonzero // 2)
        g.big_values = bv
        for i in range(2 * bv):
            top = max(1, peak * (2 * bv - i) // (2 * bv) // (1 + i // 64))
            v = rng.below(top + 1) if rng.chance(3, 4) else 0
            g.values[i] = -v if v and rng.chance(1, 2) else v
        quads = min((576 - 2 * bv) // 4, rng.below(24) if bv < 288 else 0)
        g.count1_end = 2 * bv + 4 * quads
        for i in range(2 * bv, g.count1_end):
            g.values[i] = (-1 if rng.chance(1, 2) else 1) if rng.chance(1, 3) else 0
        regions = l3_regions(g, rate_index)
        s = 0
        for r, pairs in enumerate(regions):
            # Now and then a silent region, coded by an empty table (0, 4
            # or 14); otherwise the smallest table that fits or any other.
            if r and pairs and rng.chance(1, 5):
                g.values[s:s + 2 * pairs] = [0] * (2 * pairs)
            top = max((abs(v) for v in g.values[s:s + 2 * pairs]), default=0)
            fits = [t for t in range(32) if MPA_TABLE_MAX[t] >= top]
            smallest = min(fits, key=lambda t: (MPA_TABLE_MAX[t], t))
            g.table_select[r] = smallest if rng.chance(1, 2) else fits[rng.below(len(fits))]
            s += 2 * pairs
        bits = l3_encode(g, rate_index)
        if bits.count <= budget_bits or nonzero <= 8:
            g.bits = bits
            g.part2_3_length = bits.count
            return
        nonzero = nonzero * 3 // 4
        peak = max(1, peak * 3 // 4)


def mpa_l3_stream(count, seed, version="1", bitrate=9, rate=0, mode=0, mode_ext=0, crc=False, pad_every=3,
                  reservoir=True, blocks="long", peak=40, fill=(9, 10), scfsi=True, damage=None):
    """`count` decodable Layer III frames. `blocks` is "long", "switch"
    (long, start, short, stop windows in turn, some mixed) or "short";
    `fill` the fraction of each frame's main data a frame's granules use
    (alternating values let the reservoir carry bits over); `damage`
    {frame index: kind} breaks single frames: "big_values" (over 288),
    "block_type" (window switching with type 0), "long_part" (a
    part2_3_length past the data), "short_part" (one cut short),
    "main_data_begin" (a reservoir reaching before the stream)."""
    rng = Lcg(seed)
    lsf = version != "1"
    channels = 1 if mode == 3 else 2
    granules_per_frame = 1 if lsf else 2
    rate_index = rate + 3 * (lsf + (version == "2.5"))
    side_size = (9 if channels == 1 else 17) if lsf else (17 if channels == 1 else 32)
    limit = 255 if lsf else 511
    damage = damage or {}
    frames, payloads, begins = [], [], []
    stream_pos = 0  # main-data bytes before this frame's slot
    used_end = 0  # end of the main data already placed
    window = ("long", "start", "short", "stop")
    sequence = 0
    for k in range(count):
        padding = 1 if pad_every and k % pad_every == 0 else 0
        size = mpa_frame_size(version, 3, bitrate, rate, padding)
        capacity = size - 4 - (2 if crc else 0) - side_size
        # The frame's main data may start where the reservoir allows, and
        # must end within its own slot.
        begin = max(used_end, stream_pos - limit) if reservoir else max(used_end, stream_pos)
        available = stream_pos + capacity - begin
        f = fill[k % len(fill)]
        budget = available * 8 * f // 10 // (granules_per_frame * channels)
        frame_scfsi = [rng.below(16) if scfsi and not lsf and blocks == "long" and rng.chance(1, 2) else 0
                       for _ in range(channels)]
        granules = []
        for gr in range(granules_per_frame):
            kind = "long"
            if blocks == "switch":
                kind = window[sequence % 4]
                sequence += 1
            elif blocks == "short":
                kind = "short"
            row = []
            for ch in range(channels):
                g = L3Granule()
                if kind != "long":
                    g.window_switching = True
                    g.block_type = {"start": 1, "short": 2, "stop": 3}[kind]
                    g.mixed = g.block_type == 2 and rng.chance(1, 3)
                    g.subblock_gain = [rng.below(8) for _ in range(3)]
                else:
                    g.region0, g.region1 = rng.below(16), rng.below(8)
                g.global_gain = 150 + rng.below(30)
                g.scalefac_scale = rng.below(2)
                g.preflag = 0 if lsf else rng.below(2)
                g.count1table = rng.below(2)
                intensity_ch1 = lsf and mode == 1 and mode_ext & 1 and ch == 1
                l3_scalefactors(rng, g, lsf, gr, frame_scfsi[ch] if gr == 1 else 0, intensity_ch1, rng.below(2))
                part2 = sum(bits for bits, _ in g.scalefactors)
                # With intensity stereo the right channel's upper bands are
                # left empty for the decoder to fill from the left.
                ch_peak = peak if not (mode == 1 and mode_ext & 1 and ch == 1) else max(1, peak // 4)
                l3_spectrum(rng, g, rate_index, max(part2 + 16, budget) - part2, ch_peak)
                if mode == 1 and mode_ext & 1 and ch == 1:
                    cut = 2 * (g.big_values // 3)
                    for i in range(cut, 576):
                        g.values[i] = 0
                    g.big_values = cut // 2
                    g.count1_end = cut
                    g.bits = l3_encode(g, rate_index)
                    g.part2_3_length = g.bits.count
                row.append(g)
            granules.append(row)
        kind = damage.get(k)
        data = BitWriter()
        for row in granules:
            for g in row:
                data.put(g.bits.count, g.bits.value)
        data.align()
        main = data.bytes()
        if kind == "big_values":
            granules[0][0].big_values = 289
        elif kind == "block_type":
            granules[0][0].window_switching = True
            granules[0][0].block_type = 0
        elif kind == "long_part":
            granules[-1][-1].part2_3_length = min(4095, granules[-1][-1].part2_3_length + 400)
        elif kind == "short_part":
            granules[0][0].part2_3_length = granules[0][0].part2_3_length // 2
        assert begin + len(main) <= stream_pos + capacity, (k, begin, len(main), stream_pos, capacity)
        main_data_begin = stream_pos - begin
        if kind == "main_data_begin":
            main_data_begin = min(limit, main_data_begin + 200)
        used_end = begin + len(main)
        payloads.append((begin, main))
        side = l3_side_info(granules, lsf, channels, main_data_begin, frame_scfsi, private=0)
        header = mpa_header(version=version, layer=3, bitrate=bitrate, rate=rate, padding=padding, mode=mode,
                            mode_ext=mode_ext, crc=crc)
        frames.append((header, side, capacity))
        stream_pos += capacity
    # Lay the main data out across the frames' slots.
    main_stream = bytearray(stream_pos)
    for begin, main in payloads:
        main_stream[begin:begin + len(main)] = main
    out, pos = [], 0
    for header, side, capacity in frames:
        crc_bytes = b""
        if crc:
            crc_bytes = struct.pack(">H", mpa_crc16(header[2:4] + side))
        out.append(header + crc_bytes + side + bytes(main_stream[pos:pos + capacity]))
        pos += capacity
    return out


def crc16_arc(data):
    """FFmpeg's ff_crcA001_update from 0: CRC-16/ARC, the LAME tag's CRC."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def xing_frame(seed, tag=b"Xing", frames=None, size=None, toc=True, quality=None, encoder=b"LAME3.100",
               delay=576, padding=1104, radio=None, audiophile=None, peak=0, good_crc=True, **header):
    """A Layer III frame carrying a Xing (or Info) tag with LAME's extension
    at FFmpeg's offset (xing_offtbl: after the side information)."""
    version = header.get("version", "1")
    mono = header.get("mode", 0) == 3
    side = ((32, 17), (17, 9))[version != "1"][mono]
    flags = (1 if frames is not None else 0) | (2 if size is not None else 0) | (4 if toc else 0) \
        | (8 if quality is not None else 0)
    body = bytearray(bytes(side) + tag + struct.pack(">I", flags))
    if frames is not None:
        body += struct.pack(">I", frames)
    if size is not None:
        body += struct.pack(">I", size)
    if toc:
        body += bytes(min(255, i * 256 // 100) for i in range(100))
    if quality is not None:
        body += struct.pack(">I", quality)
    body += (encoder + b"\0" * 9)[:9]
    body += bytes([0x24, 0x9C])                              # revision and VBR method, lowpass
    body += struct.pack(">I", peak)
    body += struct.pack(">H", radio if radio is not None else 0)
    body += struct.pack(">H", audiophile if audiophile is not None else 0)
    body += bytes([0x00, 128])                               # encoding flags and ATH, bitrate
    body += bytes([delay >> 4, (delay & 15) << 4 | padding >> 8, padding & 0xFF])
    body += bytes([0, 0]) + struct.pack(">H", 0) + struct.pack(">I", 0) + struct.pack(">H", 0)
    frame = bytearray(mpa_frame(seed, bytes(body), **header))
    at = 4 + len(body)
    crc = crc16_arc(bytes(frame[:at]))
    frame[at:at + 2] = struct.pack(">H", crc if good_crc else crc ^ 0x5A5A)
    return bytes(frame)


def vbri_frame(seed, size, frames, **header):
    """A Layer III frame with Fraunhofer's VBRI header 32 bytes after the
    frame header (mp3_parse_vbri_tag)."""
    body = bytes(32) + b"VBRI" + struct.pack(">HHHII", 1, 1105, 75, size, frames) + struct.pack(">HHHH", 0, 1, 2, 1)
    return mpa_frame(seed, body, **header)


def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def id3_text(encoding, text):
    """A text in ID3v2's encodings, NUL-terminated: 0 ISO-8859-1, 1 UTF-16
    with a BOM (little-endian here), 2 UTF-16BE, 3 UTF-8; 4 is 1 with a
    big-endian BOM."""
    if encoding == 0:
        return text.encode("latin-1") + b"\0"
    if encoding == 1:
        return b"\xff\xfe" + text.encode("utf-16-le") + b"\0\0"
    if encoding == 4:
        return b"\xfe\xff" + text.encode("utf-16-be") + b"\0\0"
    if encoding == 2:
        return text.encode("utf-16-be") + b"\0\0"
    return text.encode("utf-8") + b"\0"


def id3_text_frame(fid, encoding, text, version=3, **kw):
    return id3_frame(fid, bytes([1 if encoding == 4 else encoding]) + id3_text(encoding, text), version, **kw)


def id3_lang_frame(fid, encoding, lang, descriptor, text, version=3):
    """A COMM or USLT frame: encoding, language, descriptor, text."""
    enc = 1 if encoding == 4 else encoding
    return id3_frame(fid, bytes([enc]) + lang + id3_text(encoding, descriptor) + id3_text(encoding, text), version)


def id3_frame(fid, data, version=3, flags=0, v3_size=False, unsync=False):
    """A frame: 3-byte id and size in v2.2; 4-byte id, size (syncsafe in
    v2.4 unless `v3_size`, the encoders' common bug) and flags otherwise.
    `unsync` inserts a zero after every 0xFF of the data."""
    if unsync:
        data = data.replace(b"\xff", b"\xff\x00")
    if version == 2:
        return fid + struct.pack(">I", len(data))[1:] + data
    size = syncsafe(len(data)) if version == 4 and not v3_size else struct.pack(">I", len(data))
    return fid + size + struct.pack(">H", flags) + data


def id3v2_tag(frames, version=3, flags=0, padding=0, extended=b"", footer=False):
    body = extended + b"".join(frames) + bytes(padding)
    flags |= (0x10 if footer else 0) | (0x40 if extended else 0)
    head = b"ID3" + bytes([version, 0, flags]) + syncsafe(len(body))
    tag = head + body
    if footer:
        tag += b"3DI" + bytes([version, 0, flags]) + syncsafe(len(body))
    return tag


def id3v1_tag(title=b"", artist=b"", album=b"", year=b"", comment=b"", track=None, genre=255):
    def field(b, n):
        return (b + bytes(n))[:n]
    if track is not None:
        comment_bytes = field(comment, 28) + b"\0" + bytes([track])
    else:
        comment_bytes = field(comment, 30)
    return b"TAG" + field(title, 30) + field(artist, 30) + field(album, 30) + field(year, 4) + comment_bytes \
        + bytes([genre])


def ape_tag(items, header=True):
    """An APEv2 tag: optional header, items, footer (32 bytes each)."""
    body = b"".join(struct.pack("<II", len(v), 0) + k + b"\0" + v for k, v in items)
    size = len(body) + 32
    flags = 0x80000000 if header else 0
    head = b"APETAGEX" + struct.pack("<IIII", 2000, size, len(items), flags | 0x20000000) + bytes(8)
    foot = b"APETAGEX" + struct.pack("<IIII", 2000, size, len(items), flags) + bytes(8)
    return (head if header else b"") + body + foot


@dataclasses.dataclass
class Mp3Fixture:
    name: str
    group: str
    rule: str
    data: bytes
    # FFmpeg opens it ("accept") or fails with this error.
    reject: str = None


def build_mp3_fixtures():
    fx = []

    def ok(name, rule, data, group="accepted"):
        fx.append(Mp3Fixture(name, group, rule, data))

    def bad(name, rule, data, error, group="rejected"):
        fx.append(Mp3Fixture(name, group, rule, data, reject=error))

    j = b"".join
    ok("mp3_mpeg1_l3_stereo", "MPEG-1 Layer III, 44100 Hz, 128 kbit/s stereo, every third frame padded.",
       j(mpa_frames(24, seed=1)))
    ok("mp3_mpeg1_l3_mono_48k", "MPEG-1 Layer III, 48000 Hz, 64 kbit/s mono.",
       j(mpa_frames(20, seed=2, rate=1, bitrate=5, mode=3)))
    ok("mp3_mpeg1_l3_32k_crc", "MPEG-1 Layer III, 32000 Hz, 96 kbit/s joint stereo with the mode extension, "
       "frames protected by a CRC.", j(mpa_frames(20, seed=3, rate=2, bitrate=7, mode=1, mode_ext=2, crc=True)))
    ok("mp3_mpeg2_l3_22k", "MPEG-2 Layer III (LSF), 22050 Hz, 64 kbit/s stereo: 576 samples a frame.",
       j(mpa_frames(30, seed=4, version="2", bitrate=8)))
    ok("mp3_mpeg2_l3_16k_mono", "MPEG-2 Layer III, 16000 Hz, 32 kbit/s mono.",
       j(mpa_frames(30, seed=5, version="2", rate=2, bitrate=4, mode=3)))
    ok("mp3_mpeg25_l3_8k", "MPEG-2.5 Layer III, 8000 Hz, 16 kbit/s mono.",
       j(mpa_frames(30, seed=6, version="2.5", rate=2, bitrate=2, mode=3)))
    ok("mp3_mpeg25_l3_12k", "MPEG-2.5 Layer III, 12000 Hz, 32 kbit/s stereo.",
       j(mpa_frames(30, seed=7, version="2.5", rate=1, bitrate=4)))
    ok("mp3_vbr_bitrates", "MPEG-1 Layer III frames of every bit rate, 32 to 320 kbit/s, in turn.",
       j(mpa_frame(800 + i, bitrate=1 + i % 14, padding=i % 2) for i in range(28)))
    ok("mp2_layer2_48k", "MPEG-1 Layer II, 48000 Hz, 192 kbit/s stereo: codec mp2.",
       j(mpa_frames(20, seed=8, layer=2, rate=1, bitrate=10, pad_every=0)))
    ok("mp2_layer2_mpeg2_24k", "MPEG-2 Layer II, 24000 Hz, 64 kbit/s mono.",
       j(mpa_frames(20, seed=9, version="2", layer=2, rate=1, bitrate=8, mode=3)))
    ok("mp1_layer1_44k", "MPEG-1 Layer I, 44100 Hz, 384 kbit/s stereo, padded slots of 4 bytes: codec mp1.",
       j(mpa_frames(30, seed=10, layer=1, bitrate=12)))
    # Layers I and II have no Huffman coding: any payload is a frame the
    # decoder reads (T29c), so these pseudo-random ones reach every bit
    # allocation, scale factor code and grouped quantizer; the headers pick
    # each Layer II allocation table (ff_mpa_l2_select_table), the joint
    # stereo bounds (every mode extension) and the CRC field.
    ok("mp1_layer1_mono_32k", "MPEG-1 Layer I, 32000 Hz, 128 kbit/s mono.",
       j(mpa_frames(24, seed=41, layer=1, rate=2, bitrate=4, mode=3)))
    ok("mp1_layer1_joint_crc", "MPEG-1 Layer I, 48000 Hz, 256 kbit/s joint stereo, the mode extension (the "
       "intensity bound) cycling through 0 to 3, frames protected by a CRC.",
       j(mpa_frame(42 * 1000 + i, layer=1, rate=1, bitrate=8, mode=1, mode_ext=i % 4, crc=True,
                   padding=1 if i % 3 == 0 else 0) for i in range(24)))
    ok("mp1_layer1_mpeg2_22k", "MPEG-2 Layer I, 22050 Hz, 96 kbit/s stereo.",
       j(mpa_frames(24, seed=43, version="2", layer=1, bitrate=6)))
    ok("mp2_layer2_44k_dual", "MPEG-1 Layer II, 44100 Hz, 192 kbit/s dual channel: allocation table 1 (96 "
       "kbit/s a channel, not 48 kHz).", j(mpa_frames(20, seed=44, layer=2, bitrate=10, mode=2)))
    ok("mp2_layer2_44k_mono_48", "MPEG-1 Layer II, 44100 Hz, 48 kbit/s mono: allocation table 2.",
       j(mpa_frames(20, seed=45, layer=2, bitrate=3, mode=3)))
    ok("mp2_layer2_32k_mono", "MPEG-1 Layer II, 32000 Hz, 32 kbit/s mono: allocation table 3.",
       j(mpa_frames(20, seed=46, layer=2, rate=2, bitrate=1, mode=3)))
    ok("mp2_layer2_joint_crc", "MPEG-1 Layer II, 48000 Hz, 128 kbit/s joint stereo (allocation table 0), the "
       "mode extension cycling through 0 to 3, frames protected by a CRC.",
       j(mpa_frame(47 * 1000 + i, layer=2, rate=1, bitrate=8, mode=1, mode_ext=i % 4, crc=True)
         for i in range(20)))
    ok("mp2_layer2_mpeg2_joint", "MPEG-2 Layer II, 22050 Hz, 64 kbit/s joint stereo (allocation table 4), the "
       "mode extension cycling.",
       j(mpa_frame(48 * 1000 + i, version="2", layer=2, bitrate=8, mode=1, mode_ext=i % 4,
                   padding=1 if i % 3 == 0 else 0) for i in range(24)))
    ok("mp2_layer2_mpeg25_8k", "MPEG-2.5 Layer II, 8000 Hz, 32 kbit/s stereo.",
       j(mpa_frames(24, seed=49, version="2.5", layer=2, rate=2, bitrate=4)))

    vbr = [mpa_frame(900 + i, bitrate=(9, 11, 7, 13, 10)[i % 5], padding=i % 2) for i in range(30)]
    vbr_bytes = sum(len(f) for f in vbr)
    ok("mp3_xing_lame", "A Xing tag (frame count, byte count, TOC, quality) with LAME's extension (delay 576, "
       "padding 1104, radio and audiophile gains, a peak) and its valid CRC, then 30 VBR frames: the gapless "
       "start and end, the encoder tag and ReplayGain.",
       j([xing_frame(11, frames=30, size=vbr_bytes + 418, quality=78, radio=0x2000 | 0x0200 | 65,
                     audiophile=0x4000 | 31, peak=1 << 22)] + vbr))
    cbr = mpa_frames(24, seed=12)
    ok("mp3_info_lame", "An Info tag (CBR) with LAME's extension and valid CRC, then 24 CBR frames.",
       j([xing_frame(12, tag=b"Info", frames=24, size=sum(map(len, cbr)) + 418, delay=1105, padding=300)] + cbr))
    ok("mp3_xing_bad_crc", "A Xing tag whose LAME CRC is wrong: the delays still apply, but not the encoder "
       "tag or ReplayGain.",
       j([xing_frame(13, frames=30, size=vbr_bytes + 418, good_crc=False, radio=0x2000 | 50)] + vbr))
    ok("mp3_xing_frames_only", "A Xing tag with only a frame count and no LAME extension: no delays.",
       j([xing_frame(14, frames=30, toc=False, encoder=b"\0" * 9, delay=0, padding=0)] + vbr))
    ok("mp3_xing_lavf", "A Xing tag written by libavformat (encoder Lavf): its delays apply as LAME's.",
       j([xing_frame(15, frames=30, size=vbr_bytes + 418, encoder=b"Lavf61.7.", delay=0, padding=1000)] + vbr))
    ok("mp3_xing_size_mismatch", "A Xing tag whose byte count is far below the file's: FFmpeg takes it for a "
       "concatenated file and drops the frame count.",
       j([xing_frame(16, frames=30, size=2000)] + vbr))
    ok("mp3_xing_mpeg2_mono", "A Xing tag in an MPEG-2 mono frame (side information of 9 bytes).",
       j([xing_frame(17, frames=20, size=20 * 144 + 144, version="2", rate=2, bitrate=8, mode=3)]
         + mpa_frames(20, seed=17, version="2", rate=2, bitrate=8, mode=3, pad_every=0)))
    ok("mp3_vbri", "A Fraunhofer VBRI header: its frame and byte counts give the duration.",
       j([vbri_frame(18, sum(map(len, vbr)) + 418, 30)] + vbr))

    smpb = " 00000000 00000840 0000037C 0000000000006F84 00000000 00000000 00000000"
    ok("mp3_itunsmpb", "Gapless data in an iTunSMPB comment (an ID3v2.3 COMM frame), as Apple's encoders "
       "write it instead of LAME's tag.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "iTunes"), id3_lang_frame(b"COMM", 0, b"eng", "iTunSMPB", smpb)])
       + j(mpa_frames(25, seed=19)))
    ok("mp3_itunsmpb_bare_0x", "An iTunSMPB comment whose priming field is a bare 0x: glibc's sscanf fails "
       "to match it, so FFmpeg ignores the tag and keeps no gapless counts.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "iTunes"),
                  id3_lang_frame(b"COMM", 0, b"eng", "iTunSMPB", smpb.replace(" 00000840 ", " 0x "))])
       + j(mpa_frames(25, seed=19)))

    v23 = [
        id3_text_frame(b"TIT2", 0, "Latin-1 title \xe9"),
        id3_text_frame(b"TPE1", 1, "Artist é中"),
        id3_text_frame(b"TALB", 4, "Album big-endian BOM"),
        id3_text_frame(b"TYER", 0, "2009"),
        id3_text_frame(b"TDAT", 0, "0301"),
        id3_text_frame(b"TIME", 0, "1230"),
        id3_text_frame(b"TCON", 0, "(17)"),
        id3_text_frame(b"TRCK", 0, "3/12"),
        id3_text_frame(b"TPE2", 1, ""),
        id3_text_frame(b"TXXX", 0, "MOOD") + b"",
        id3_lang_frame(b"COMM", 0, b"eng", "", "a plain comment"),
        id3_lang_frame(b"COMM", 0, b"und", "note", "no language"),
        id3_lang_frame(b"COMM", 0, b"XXX", "fra", "descriptor like a language"),
        id3_lang_frame(b"COMM", 0, b"xxx", "Foo-eng", "descriptor ending in a language"),
        id3_lang_frame(b"COMM", 0, b"ger", "Bar", "a descriptor and a language"),
        id3_lang_frame(b"USLT", 3, b"eng", "", "la la la"),
        id3_frame(b"PRIV", b"com.example.owner\0" + bytes([0, 1, 0x5C, 0x41, 0x7F, 0x20])),
        id3_frame(b"TXXX", b"\0REPLAYGAIN_TRACK_GAIN\0-6.50 dB"),
        id3_frame(b"TXXX", b"\0REPLAYGAIN_TRACK_PEAK\x000.988"),
        id3_frame(b"WXXX", b"\0\0http://example.com"),
    ]
    v23[9] = id3_frame(b"TXXX", b"\0MOOD\0calm")
    ok("mp3_id3v23_tags", "ID3v2.3: text frames in every encoding (ISO-8859-1, UTF-16 with either BOM), TYER, "
       "TDAT and TIME merged into a date, a numeric genre, TXXX, COMM frames with and without a language and "
       "descriptor, USLT, PRIV, ReplayGain in TXXX and an unread WXXX, with padding.",
       id3v2_tag(v23, padding=64) + j(mpa_frames(20, seed=20)))
    v24 = [
        id3_text_frame(b"TIT2", 3, "UTF-8 title é", version=4),
        id3_text_frame(b"TDRC", 3, "2011-05-06", version=4),
        id3_text_frame(b"TSOP", 2, "Sort, Artist", version=4),
        id3_text_frame(b"TCMP", 3, "1", version=4),
        id3_frame(b"TPE1", b"\3" + "A v2.3-style size: ".encode() + b"x" * 140 + b"\0", version=4, v3_size=True),
        id3_frame(b"TALB", b"\0\0\0\x0a\3Data len\0", version=4, flags=0x0001),
        id3_frame(b"TCOM", b"\3compressed?\0", version=4, flags=0x0008),
        id3_frame(b"TEXT", b"\3encrypted?\0", version=4, flags=0x0004),
        id3_frame(b"TCOP", b"\0\xff\xfe copyright", version=4, flags=0x0002, unsync=True),
        id3_frame(b"TENC", b"", version=4),
    ]
    ok("mp3_id3v24_tags", "ID3v2.4: an extended header, UTF-8 and UTF-16BE texts, TDRC, sort and compilation "
       "frames, a frame sized as v2.3 by mistake, a data length indicator, a compressed and an encrypted frame "
       "(both skipped), an unsynchronised frame, an empty frame, padding and a footer.",
       id3v2_tag(v24, version=4, extended=syncsafe(6) + b"\x01\x00", padding=32, footer=True)
       + j(mpa_frames(20, seed=21)))
    v22 = [
        id3_text_frame(b"TT2", 0, "v2.2 title", version=2),
        id3_text_frame(b"TP1", 0, "v2.2 artist", version=2),
        id3_text_frame(b"TAL", 1, "v2.2 album", version=2),
        id3_text_frame(b"TCO", 0, "Rock", version=2),
        id3_text_frame(b"TYE", 0, "1999", version=2),
        id3_text_frame(b"TRK", 0, "7", version=2),
        id3_lang_frame(b"COM", 0, b"eng", "", "v2.2 comment", version=2),
        id3_frame(b"TXX", b"\0KEY\0value", version=2),
        id3_frame(b"TBP", b"", version=2),
    ]
    ok("mp3_id3v22_tags", "ID3v2.2: three-letter frames (TT2, TP1, TAL, TCO, TYE, TRK, COM, TXX) and an empty "
       "one.", id3v2_tag(v22, version=2, padding=10) + j(mpa_frames(20, seed=22)))
    unsync_tag = id3v2_tag([id3_text_frame(b"TIT2", 0, "unsync ÿÿ end"),
                            id3_frame(b"TPE1", b"\0\xff\xfe\xff\0artist\0", unsync=True)], flags=0x80)
    ok("mp3_id3v23_unsync", "An ID3v2.3 tag with the unsynchronisation flag: zeros after 0xFF removed from each "
       "frame.", unsync_tag + j(mpa_frames(20, seed=23)))
    ok("mp3_two_id3v2", "Two ID3v2 tags in a row: FFmpeg reads both.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "first")]) + id3v2_tag([id3_text_frame(b"TPE1", 0, "second")])
       + j(mpa_frames(20, seed=24)))
    ok("mp3_large_id3v2", "A 6000-byte ID3v2 tag: probing skips it only once the probe buffer holds more than "
       "it, so FFmpeg probes again with more data.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "large")], padding=6000) + j(mpa_frames(20, seed=25)))
    ok("mp3_id3v1", "An ID3v1 tag at the end (title, artist with trailing spaces, album, year, a track number, "
       "genre 13) and no ID3v2 tag: FFmpeg reads it; its parser drops the tag at the end.",
       j(mpa_frames(20, seed=26)) + id3v1_tag(b"v1 title", b"v1 artist   ", b"v1 album", b"2001", b"v1 comment",
                                              track=5, genre=13))
    ok("mp3_id3v1_and_v2", "Both ID3v2 and ID3v1 tags: FFmpeg reads the ID3v1 tag only without ID3v2 tags.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "v2 title")]) + j(mpa_frames(20, seed=27))
       + id3v1_tag(b"v1 title", genre=255))
    ok("mp3_apic_chap", "An ID3v2.3 tag with an APIC picture and a CHAP chapter (with its own TIT2): FFmpeg "
       "adds an attached-picture stream and a chapter, which the port does not model.",
       id3v2_tag([id3_text_frame(b"TIT2", 0, "with picture"),
                  id3_frame(b"APIC", b"\0image/png\0\x03cover\0" + b"\x89PNG\r\n\x1a\n" + bytes(40)),
                  id3_frame(b"CHAP", b"ch0\0" + struct.pack(">IIII", 0, 500, 0xFFFFFFFF, 0xFFFFFFFF)
                            + id3_text_frame(b"TIT2", 0, "chapter one"))])
       + j(mpa_frames(20, seed=28)))
    ok("mp3_ape_tag", "An APEv2 tag (with its header) after the frames: the parser drops it at the end.",
       j(mpa_frames(20, seed=29)) + ape_tag([(b"Title", b"ape title")]))
    ok("mp3_ape_footer_only", "An APEv2 tag without its header: the parser keeps its bytes as a last packet.",
       j(mpa_frames(20, seed=30)) + ape_tag([(b"Title", b"ape title")], header=False))
    ok("mp3_junk_before", "300 bytes of junk before the first frame: the demuxer resyncs on two consecutive "
       "frames.", mpa_payload(31, 300) + j(mpa_frames(20, seed=31)), group="damaged")
    ok("mp3_zeros_before", "1000 zero bytes before the first frame: the probe skips leading zeros.",
       bytes(1000) + j(mpa_frames(20, seed=32)), group="damaged")
    frames = mpa_frames(24, seed=33)
    ok("mp3_junk_between", "Junk between frames: the parser resyncs on the next frame header.",
       j(frames[:10]) + mpa_payload(330, 77) + j(frames[10:]), group="damaged")
    frames = mpa_frames(20, seed=34)
    ok("mp3_truncated", "The last frame cut short: the parser returns the partial frame at the end.",
       j(frames)[:-150], group="damaged")
    ok("mp3_rate_change", "A sample-rate change mid-stream, 44100 to 48000 Hz.",
       j(mpa_frames(12, seed=35)) + j(mpa_frames(12, seed=36, rate=1)), group="damaged")
    ok("mp3_layer_change", "Layer III frames followed by Layer II frames.",
       j(mpa_frames(12, seed=37)) + j(mpa_frames(12, seed=38, layer=2, bitrate=10, pad_every=0)), group="damaged")
    emu = [mpa_frame(39 * 1000 + i, body=mpa_header()[:3] * 0 + b"\x00" * 10 + mpa_header() * 3) for i in range(20)]
    ok("mp3_header_emulation", "Frames whose payload holds copies of the header: the probe stops counting a "
       "run where more than two emulate it.", j(emu), group="damaged")
    ok("mp3_short", "Three frames only: the probe's lowest scores.", j(mpa_frames(3, seed=40)), group="damaged")
    ok("mp3_six_frames", "Six frames: below the seven a first-run score needs.", j(mpa_frames(6, seed=41)),
       group="damaged")
    # T29b: streams that decode to audio, then damaged ones.
    def l3(name, rule, group="decoded", **kw):
        ok(name, rule, j(mpa_l3_stream(**kw)), group=group)

    l3("mp3_l3_long_stereo", "Decodable MPEG-1 Layer III, 44100 Hz, 128 kbit/s stereo: long blocks, every "
       "Huffman table, both count1 tables, scfsi, preflag and scalefac_scale.", count=24, seed=101)
    l3("mp3_l3_reservoir_mono", "Decodable MPEG-1 Layer III, 48000 Hz, 64 kbit/s mono: frames alternately use "
       "40% and all of the space left, so the bit reservoir carries data across frames.",
       count=24, seed=102, rate=1, bitrate=5, mode=3, fill=(4, 10))
    l3("mp3_l3_window_switching", "Decodable MPEG-1 Layer III stereo: long, start, short and stop windows in "
       "turn, some short granules mixed, with subblock gains.", count=24, seed=103, blocks="switch")
    l3("mp3_l3_short_ms", "Decodable MPEG-1 Layer III, 32000 Hz, joint stereo with M/S only: short blocks.",
       count=16, seed=104, rate=2, bitrate=8, blocks="short", mode=1, mode_ext=2)
    l3("mp3_l3_intensity_ms", "Decodable MPEG-1 Layer III joint stereo with intensity and M/S stereo: the "
       "right channel's upper bands empty.", count=16, seed=105, mode=1, mode_ext=3)
    l3("mp3_l3_intensity", "Decodable MPEG-1 Layer III joint stereo with intensity stereo only, window "
       "switching.", count=16, seed=106, mode=1, mode_ext=1, blocks="switch")
    l3("mp3_l3_mpeg2_22k_intensity", "Decodable MPEG-2 Layer III, 22050 Hz, 64 kbit/s joint stereo with "
       "intensity stereo: the LSF intensity scalefactor partitions.", count=24, seed=107, version="2",
       bitrate=8, mode=1, mode_ext=1)
    l3("mp3_l3_mpeg2_24k_switch", "Decodable MPEG-2 Layer III, 24000 Hz stereo, window switching: the LSF "
       "short and mixed partitions.", count=24, seed=108, version="2", rate=1, bitrate=9, blocks="switch")
    l3("mp3_l3_mpeg2_16k_mono", "Decodable MPEG-2 Layer III, 16000 Hz, 32 kbit/s mono, long blocks.",
       count=24, seed=109, version="2", rate=2, bitrate=4, mode=3)
    l3("mp3_l3_mpeg25_8k_switch", "Decodable MPEG-2.5 Layer III, 8000 Hz mono, window switching: the 8 kHz "
       "regions and band tables (FFmpeg logs its switch-point request).", count=24, seed=110, version="2.5",
       rate=2, bitrate=2, mode=3, blocks="switch")
    l3("mp3_l3_mpeg25_11k_ms", "Decodable MPEG-2.5 Layer III, 11025 Hz joint stereo with M/S.", count=24,
       seed=111, version="2.5", bitrate=4, mode=1, mode_ext=2)
    l3("mp3_l3_crc_linbits", "Decodable MPEG-1 Layer III, 320 kbit/s, CRC-protected frames, values up to "
       "3000 (escape tables with up to 13 linbits).", count=12, seed=112, crc=True, peak=3000, bitrate=14)
    gapless = mpa_l3_stream(count=30, seed=113)
    ok("mp3_l3_gapless", "Decodable MPEG-1 Layer III after an Info tag with LAME's delays (576 and 1104): "
       "the decoder's output is trimmed at both ends.",
       j([xing_frame(114, tag=b"Info", frames=30, size=sum(map(len, gapless)) + 418, delay=576, padding=1104)]
         + gapless), group="decoded")
    l3("mp3_l3_bad_big_values", "Decodable Layer III whose sixth frame declares 289 big-value pairs: that "
       "frame fails to decode.", group="decoded, damaged", count=12, seed=115, damage={5: "big_values"})
    l3("mp3_l3_bad_block_type", "Decodable Layer III whose sixth frame switches windows with block type 0: "
       "that frame fails to decode.", group="decoded, damaged", count=12, seed=116, damage={5: "block_type"})
    l3("mp3_l3_long_part", "Decodable Layer III whose fifth frame's last granule declares 400 bits more than "
       "its data: the Huffman decoding reads into the next frame's data.", group="decoded, damaged",
       count=12, seed=117, damage={4: "long_part"})
    l3("mp3_l3_short_part", "Decodable Layer III whose fifth frame's first granule declares half its bits: "
       "the decoding stops early and the next granule starts mid-data.", group="decoded, damaged",
       count=12, seed=118, damage={4: "short_part"})
    l3("mp3_l3_reservoir_missing", "Decodable Layer III whose first frame's main data begins 200 bytes "
       "before the stream: its granules decode as silence.", group="decoded, damaged", count=12, seed=119,
       damage={0: "main_data_begin"})
    ok("mp3_l3_truncated", "Decodable Layer III cut in its last frame's main data.",
       j(mpa_l3_stream(count=12, seed=120))[:-200], group="decoded, damaged")
    bad("mp3_free_format", "Free-format frames (bit rate index 0), whose size FFmpeg's header decoding does not "
        "compute: no frame is recognized.",
        j(mpa_header(bitrate=0) + mpa_payload(42 + i, 400) for i in range(20)), "INVALIDDATA")
    bad("mp3_no_frames", "Arbitrary bytes and no frame.", mpa_payload(43, 5000), "INVALIDDATA")
    return fx


def render_mp3_manifest(fixtures):
    lines = ["// Generated by zig/testing/fixtures/generate.py from its MP3 fixtures; do not edit.",
             "// Each entry names mp3/<name>.mp3; see mp3/README.md. Streams, tags and packets are",
             "// FFmpeg's, in zig/testing/vectors/mp3.txt.",
             ".{"]
    for f in fixtures:
        lines.append("    .{")
        lines.append(f'        .name = "{f.name}",')
        lines.append(f'        .sha256 = "{hashlib.sha256(f.data).hexdigest()}",')
        lines.append(f'        .expected = {".accept" if f.reject is None else "." + "reject"},')
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def outputs(fixtures, au_fixtures, aiff_fixtures, raw_fixtures, caf_fixtures, flac_fixtures, ogg_fixtures,
            mp3_fixtures):
    files = {WAV_DIR / f"{f.name}.wav": f.data for f in fixtures}
    files[MANIFEST] = render_manifest(
        fixtures, "// Each entry names wav/<name>.wav; see README.md for the rules and decisions.")
    files[README] = render_readme(README, render_table(fixtures, [large_skip_row()]))
    files.update({AU_DIR / f"{f.name}.au": f.data for f in au_fixtures})
    files[AU_MANIFEST] = render_manifest(
        au_fixtures, "// Each entry names au/<name>.au; see au/README.md for the rules and decisions.")
    files[AU_README] = render_readme(AU_README, render_table(au_fixtures))
    files.update({AIFF_DIR / f"{f.name}.aiff": f.data for f in aiff_fixtures})
    files[AIFF_MANIFEST] = render_manifest(
        aiff_fixtures, "// Each entry names aiff/<name>.aiff; see aiff/README.md for the rules and decisions.")
    files[AIFF_README] = render_readme(AIFF_README, render_table(aiff_fixtures))
    files.update({RAW_DIR / f"{f.name}.raw": f.data for f in raw_fixtures})
    files[RAW_MANIFEST] = render_manifest(
        raw_fixtures, "// Each entry names raw/<name>.raw; see raw/README.md for the rules and decisions.")
    files[RAW_README] = render_readme(RAW_README, render_table(raw_fixtures))
    files.update({CAF_DIR / f"{f.name}.caf": f.data for f in caf_fixtures})
    files[CAF_MANIFEST] = render_manifest(
        caf_fixtures, "// Each entry names caf/<name>.caf; see caf/README.md for the rules and decisions.")
    files[CAF_README] = render_readme(CAF_README, render_table(caf_fixtures))
    files.update({FLAC_DIR / f"{f.name}.flac": f.data for f in flac_fixtures if f.made_by != "ffmpeg"})
    files[FLAC_MANIFEST] = render_flac_manifest(flac_fixtures).encode()
    files[FLAC_README] = render_readme(FLAC_README, render_flac_table(flac_fixtures))
    files.update({OGG_DIR / f"{f.name}.ogg": f.data for f in ogg_fixtures if f.made_by != "ffmpeg"})
    files[OGG_MANIFEST] = render_ogg_manifest(ogg_fixtures).encode()
    files[OGG_README] = render_readme(OGG_README, render_ogg_table(ogg_fixtures))
    files.update({MP3_DIR / f"{f.name}.mp3": f.data for f in mp3_fixtures})
    files[MP3_MANIFEST] = render_mp3_manifest(mp3_fixtures).encode()
    files[MP3_README] = render_readme(MP3_README, render_ogg_table(mp3_fixtures))
    return files


def check_ffmpeg_made(flac_fixtures):
    """FFmpeg-made fixtures are committed, not generated: each must exist
    with its recorded hash (zig/testing/reference/flac_fixtures.sh and
    ogg_fixtures.sh)."""
    problems = []
    for name, (*_, digest) in OGG_FFMPEG.items():
        path = OGG_DIR / f"{name}.ogg"
        if not path.exists():
            problems.append(f"missing FFmpeg-made fixture: {path.relative_to(HERE)}")
        elif digest is None or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            problems.append(f"FFmpeg-made fixture differs from its recorded hash: {path.relative_to(HERE)}")
    for f in flac_fixtures:
        if f.made_by != "ffmpeg":
            continue
        path = FLAC_DIR / f"{f.name}.flac"
        if not path.exists():
            problems.append(f"missing FFmpeg-made fixture: {path.relative_to(HERE)}")
        elif f.sha256 is None or hashlib.sha256(path.read_bytes()).hexdigest() != f.sha256:
            problems.append(f"FFmpeg-made fixture differs from its recorded hash: {path.relative_to(HERE)}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if any generated output is missing or stale")
    parser.add_argument("--flac-input", metavar="NAME",
                        help="write the s16le input of FFmpeg-made FLAC fixture NAME to stdout and stop")
    parser.add_argument("--ogg-input", metavar="NAME",
                        help="write the s16le input of FFmpeg-made Ogg fixture NAME to stdout and stop")
    args = parser.parse_args()
    if args.flac_input:
        sys.stdout.buffer.write(b"".join(struct.pack("<h", v) for v in flac_ffmpeg_input(args.flac_input)))
        return 0
    if args.ogg_input:
        sys.stdout.buffer.write(b"".join(struct.pack("<h", v) for v in ogg_ffmpeg_input(args.ogg_input)))
        return 0

    fixtures = build_fixtures()
    au_fixtures = build_au_fixtures()
    aiff_fixtures = build_aiff_fixtures()
    raw_fixtures = build_raw_fixtures()
    caf_fixtures = build_caf_fixtures()
    flac_fixtures = build_flac_fixtures()
    ogg_fixtures = build_ogg_fixtures()
    mp3_fixtures = build_mp3_fixtures()
    expected = outputs(fixtures, au_fixtures, aiff_fixtures, raw_fixtures, caf_fixtures, flac_fixtures, ogg_fixtures,
                       mp3_fixtures)
    stale = [path for path, content in expected.items() if not path.exists() or path.read_bytes() != content]
    ffmpeg_made = ({FLAC_DIR / f"{f.name}.flac" for f in flac_fixtures if f.made_by == "ffmpeg"}
                   | {OGG_DIR / f"{name}.ogg" for name in OGG_FFMPEG})
    extra = sorted((set(WAV_DIR.glob("*.wav")) | set(AU_DIR.glob("*.au")) | set(AIFF_DIR.glob("*.aiff"))
             | set(RAW_DIR.glob("*.raw")) | set(CAF_DIR.glob("*.caf")) | set(FLAC_DIR.glob("*.flac"))
             | set(OGG_DIR.glob("*.ogg")) | set(MP3_DIR.glob("*.mp3")))
                   - set(expected) - ffmpeg_made)
    problems = check_ffmpeg_made(flac_fixtures)
    counts = (f"{len(fixtures)} WAV, {len(au_fixtures)} AU, {len(aiff_fixtures)} AIFF, {len(raw_fixtures)} raw PCM, "
              f"{len(caf_fixtures)} CAF, {len(flac_fixtures)} FLAC, {len(ogg_fixtures)} Ogg and {len(mp3_fixtures)} MP3 "
              f"fixtures")

    if args.check:
        for path in stale:
            print(f"stale or missing: {path.relative_to(HERE)}", file=sys.stderr)
        for path in extra:
            print(f"not generated by generate.py: {path.relative_to(HERE)}", file=sys.stderr)
        for problem in problems:
            print(problem, file=sys.stderr)
        if stale or extra:
            print("run: python3 zig/testing/fixtures/generate.py", file=sys.stderr)
        if problems:
            print("run: zig/testing/reference/flac_fixtures.sh", file=sys.stderr)
        if stale or extra or problems:
            return 1
        print(f"{counts}, manifests and README tables are current")
        return 0

    WAV_DIR.mkdir(exist_ok=True)
    AU_DIR.mkdir(exist_ok=True)
    AIFF_DIR.mkdir(exist_ok=True)
    RAW_DIR.mkdir(exist_ok=True)
    CAF_DIR.mkdir(exist_ok=True)
    FLAC_DIR.mkdir(exist_ok=True)
    OGG_DIR.mkdir(exist_ok=True)
    MP3_DIR.mkdir(exist_ok=True)
    for path in extra:
        path.unlink()
    for path in stale:
        path.write_bytes(expected[path])
    print(f"wrote {len(stale)} file(s), removed {len(extra)}; {counts}")
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
