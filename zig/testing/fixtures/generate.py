#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
"""Generate the fixtures for the WAV (TODO.md T02), AU (T12a), AIFF (T22b) and raw PCM (T22c) contracts.

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

Usage, from the repository root:

    python3 zig/testing/fixtures/generate.py           # rewrite the outputs
    python3 zig/testing/fixtures/generate.py --check   # fail if any output is stale
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
    raise ValueError(codec)


STORAGE_PACK = {"u8": "<B", "s16": "<h", "s32": "<i", "s64": "<q", "flt": "<I", "dbl": "<Q"}


def storage_bytes(stream):
    """The decoded samples serialized little-endian, as `ffmpeg -c:a pcm_<storage>le` writes them."""
    fmt = STORAGE_PACK[stream.storage]
    return b"".join(struct.pack(fmt, s) for s in stream.stored)


def canonical_wav(codec, channels, rate, data):
    """The writer's output for one known-length stream: the header riffenc.c
    chooses (WAVE_FORMAT_EXTENSIBLE above 48 kHz, or above 16 bits unless
    float), a `fact` chunk for every encoding but tag 1, then `data`."""
    tag, bits, _ = WAV_CODECS[codec]
    frames = len(data) // (channels * bits // 8)
    if rate > WRITER_MAX_PLAIN_RATE or (bits > 16 and tag != 3):
        extension = u16(bits) + u32(CHANNEL_MASK[channels]) + u32(tag) + SUBFORMAT_BASE
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


def canonical_w64(codec, channels, rate, data):
    """The writer's Wave64 output: the same `fmt ` as `canonical_wav`, a `fact`
    chunk with a 64-bit count for every encoding but tag 1, then `data`, with
    sizes that do not count the padding."""
    plain = canonical_wav(codec, channels, rate, data)
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

    def __iter__(self):
        return iter((self.channels, self.rate, self.stored))


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
                               "Extensible with channel mask 0 (unspecified): the default layout applies.",
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
    fx.append(rejected("extensible_mask_mismatch", "extensible",
                       "Stereo with the mono channel mask (front center): layouts beyond mono and stereo wait for T23b.",
                       riff(chunk(b"fmt ", extensible_fmt(channels=2, mask=0x4)), data_chunk(STEREO)),
                       "UnsupportedFormat"))
    fx.append(rejected("extensible_truncated", "extensible", "Input ends inside the 40-byte extensible `fmt `.",
                       riff(chunk(b"fmt ", extensible_fmt()), data_chunk(MONO[:4]))[:50], "Truncated"))
    fx.append(rejected("fmt_channels3", "fmt", "Three channels.",
                       riff(fmt_chunk(channels=3), data_chunk(MONO[:6])), "UnsupportedFormat"))
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
    return fx


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
    bad("au_channels3", "format", "Three channels: only mono and stereo are supported.",
        au(pcm_be(MONO[:6]), channels=3), "UnsupportedFormat")

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
    return fx


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


def canonical_aiff(codec, channels, rate, data):
    """The writer's output: plain AIFF for the NONE encodings, else AIFF-C with
    FVER, a 24-byte COMM holding the compression type, then SSND."""
    compression, bits, _ = AIFF_CODECS[codec]
    frames = len(data) // (channels * bits // 8)
    if compression == b"NONE":
        return form(comm_chunk(channels, frames, bits, rate), ssnd_chunk(data))
    return form(iff_chunk(b"FVER", be32(AIFC_VERSION1)), comm_chunk(channels, frames, bits, rate, compression),
                ssnd_chunk(data), form_type=b"AIFC")


def aiff_stream(codec, channels, rate, payload):
    return Stream(codec, channels, rate, AIFF_CODECS[codec][2], decode_stored(codec, payload))


def build_aiff_fixtures():
    fx = []

    def ok(name, group, rule, data, codec, channels, rate, payload, writer_output=False):
        fx.append(Fixture(name, group, rule, data, accept=aiff_stream(codec, channels, rate, payload),
                          writer_output=writer_output))

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
    bad("aiff_channels3", "comm", "Three channels.", form(comm_chunk(channels=3, frames=2), ssnd_chunk(s16[:12])),
        "UnsupportedFormat")
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
    return fx


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


@dataclasses.dataclass
class RawFixture(Fixture):
    """A raw PCM file and the parameters it is read with (`params` None takes
    FFmpeg's defaults, 44100 Hz mono)."""
    format: str = None
    params: tuple = None  # (sample_rate, channels)


def build_raw_fixtures():
    fx = []

    def stream(fmt, payload, params):
        rate, channels = params or (RAW_DEFAULT_RATE, RAW_DEFAULT_CHANNELS)
        codec = RAW_FORMATS[fmt]
        return Stream(codec, channels, rate, CODEC_STORAGE[codec], decode_stored(codec, payload))

    def ok(name, rule, fmt, payload, params, writer_output=True):
        fx.append(RawFixture(name, "accepted", rule, payload, accept=stream(fmt, payload, params),
                             writer_output=writer_output, format=fmt, params=params))

    def bad(name, rule, fmt, payload, params, error):
        assert error in RAW_ERRORS, error
        fx.append(RawFixture(name, "rejected", rule, payload, reject=error, format=fmt, params=params))

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

    # Rejected.
    bad("raw_partial_frame", "Stereo 16-bit, 6 bytes: the input ends inside its second frame. FFmpeg decodes "
        "the whole frame.", "s16le", pcm(STEREO[:3]), (8000, 2), "Truncated")
    bad("raw_partial_sample", "24-bit mono, 4 bytes: the input ends inside its second sample.", "s24le",
        bytes(4), (8000, 1), "Truncated")
    bad("raw_rate_zero", "Sample rate 0.", "s16le", pcm(MONO[:4]), (0, 1), "InvalidFormat")
    bad("raw_rate_over_limit", f"Sample rate {MAX_RATE + 1} Hz, above the default limit.", "s16le",
        pcm(MONO[:4]), (MAX_RATE + 1, 1), "LimitExceeded")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate raw fixture names"
    return fx


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
            f".sample_rate = {accept.rate}, .samples = .{{ .{accept.storage} = .{sample_list} }} }} }}")


def ffmpeg_detect(data):
    """The format FFmpeg's content probing picks for `data`, or None (T16).

    An independent reading of the probes in wavdec.c (wav_probe, w64_probe),
    au.c (au_probe) and aiffdec.c (aiff_probe) and of format.c's choice: the highest nonzero score wins, a
    tie at the highest means none. The first probe buffer holds 2048 bytes, and
    these probes never ask for more. File-name extensions (T22c) play no part:
    no fixture's extension is a raw format's."""
    head = data[:2048]
    scores = {"wav": 0, "w64": 0, "au": 0, "aiff": 0}
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
    best = max(scores.values())
    winners = [name for name, score in scores.items() if score == best]
    return winners[0] if best > 0 and len(winners) == 1 else None


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
            params = "null" if f.params is None else f".{{ .sample_rate = {f.params[0]}, .channels = {f.params[1]} }}"
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
    layout = {1: "mono", 2: "stereo"}[channels]
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


def outputs(fixtures, au_fixtures, aiff_fixtures, raw_fixtures):
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
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if any generated output is missing or stale")
    args = parser.parse_args()

    fixtures = build_fixtures()
    au_fixtures = build_au_fixtures()
    aiff_fixtures = build_aiff_fixtures()
    raw_fixtures = build_raw_fixtures()
    expected = outputs(fixtures, au_fixtures, aiff_fixtures, raw_fixtures)
    stale = [path for path, content in expected.items() if not path.exists() or path.read_bytes() != content]
    extra = sorted((set(WAV_DIR.glob("*.wav")) | set(AU_DIR.glob("*.au")) | set(AIFF_DIR.glob("*.aiff"))
             | set(RAW_DIR.glob("*.raw"))) - set(expected))

    if args.check:
        for path in stale:
            print(f"stale or missing: {path.relative_to(HERE)}", file=sys.stderr)
        for path in extra:
            print(f"not generated by generate.py: {path.relative_to(HERE)}", file=sys.stderr)
        if stale or extra:
            print("run: python3 zig/testing/fixtures/generate.py", file=sys.stderr)
            return 1
        print(f"{len(fixtures)} WAV, {len(au_fixtures)} AU, {len(aiff_fixtures)} AIFF and {len(raw_fixtures)} raw PCM fixtures, manifests and README tables are current")
        return 0

    WAV_DIR.mkdir(exist_ok=True)
    AU_DIR.mkdir(exist_ok=True)
    AIFF_DIR.mkdir(exist_ok=True)
    RAW_DIR.mkdir(exist_ok=True)
    for path in extra:
        path.unlink()
    for path in stale:
        path.write_bytes(expected[path])
    print(f"wrote {len(stale)} file(s), removed {len(extra)}; {len(fixtures)} WAV, {len(au_fixtures)} AU, {len(aiff_fixtures)} AIFF and {len(raw_fixtures)} raw PCM fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
