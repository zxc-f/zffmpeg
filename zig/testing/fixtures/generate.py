#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
"""Generate the fixtures for the WAV contract (TODO.md T02) and the AU contract (T12a).

Every fixture is defined below and built byte by byte with the Python standard
library, independently of the Zig implementation. From those lists this script
writes:

* wav/<name>.wav       the WAV fixture files
* manifest.zon         WAV expected results, imported by zig/testing/fixtures.zig
* README.md            the WAV table between the GENERATED markers
* au/<name>.au         the AU fixture files
* au/manifest.zon      AU expected results, imported by zig/testing/fixtures.zig
* au/README.md         the AU table between the GENERATED markers

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


# --- fixtures --------------------------------------------------------------


@dataclasses.dataclass
class Fixture:
    name: str
    group: str
    rule: str
    data: bytes
    accept: tuple = None  # (channels, sample_rate, samples)
    reject: str = None  # contract error name
    writer_output: bool = False


def accepted(name, group, rule, data, channels, rate, samples, writer_output=False):
    return Fixture(name, group, rule, data, accept=(channels, rate, list(samples)),
                   writer_output=writer_output)


def rejected(name, group, rule, data, error):
    assert error in ERRORS, error
    return Fixture(name, group, rule, data, reject=error)


EXTENSIBLE_PCM_GUID = bytes.fromhex("0100000000001000800000aa00389b71")
W64_RIFF_GUID = bytes.fromhex("72696666" "2e91cf11a5d628db04c10000")
W64_WAVE_GUID = bytes.fromhex("77617665" "f3acd3118cd100c04f8edb8a")


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
                       "High-rate stereo with a plain tag-1 `fmt `. Intentional difference: FFmpeg's "
                       "writer emits WAVE_FORMAT_EXTENSIBLE above 48 kHz; ours keeps tag 1.",
                       riff(fmt_chunk(channels=2, rate=96000), data_chunk(STEREO)),
                       2, 96000, STEREO, writer_output=True))
    fx.append(accepted("mono_192k_rate_limit", "accepted", "Sample rate exactly at the 192,000 Hz limit.",
                       riff(fmt_chunk(channels=1, rate=MAX_RATE), data_chunk(MONO[:4])),
                       1, MAX_RATE, MONO[:4], writer_output=True))
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
    ds64 = chunk(b"ds64", bytes(28))
    fx.append(rejected("rf64", "riff header", "RF64 container (64-bit sizes in `ds64`).",
                       riff(ds64, fmt_chunk(), data_chunk(MONO[:4]), tag=b"RF64", size=0xFFFFFFFF),
                       "UnsupportedFormat"))
    fx.append(rejected("bw64", "riff header", "BW64 container (64-bit sizes in `ds64`).",
                       riff(ds64, fmt_chunk(), data_chunk(MONO[:4]), tag=b"BW64", size=0xFFFFFFFF),
                       "UnsupportedFormat"))
    w64 = W64_RIFF_GUID + struct.pack("<Q", 40) + W64_WAVE_GUID
    fx.append(rejected("w64", "riff header", "Sony Wave64 (starts with the lowercase `riff` GUID).",
                       w64, "UnsupportedFormat"))
    fx.append(rejected("riff_size_unknown", "riff header", "`riff_size` is the 0xFFFFFFFF unknown-size sentinel.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), size=0xFFFFFFFF), "UnsupportedStreamingSize"))
    fx.append(rejected("riff_size_zero", "riff header", "`riff_size` is 0, the other unknown-size sentinel.",
                       riff(fmt_chunk(), data_chunk(MONO[:4]), size=0), "UnsupportedStreamingSize"))
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
    fx.append(rejected("fmt_extensible", "fmt", "WAVE_FORMAT_EXTENSIBLE (tag 0xFFFE, 40 bytes), even with a PCM subformat.",
                       riff(chunk(b"fmt ", extensible), data_chunk(MONO[:4])), "UnsupportedFormat"))
    fx.append(rejected("fmt_float32", "fmt", "IEEE float (tag 3, 32-bit).",
                       riff(fmt_chunk(tag=3, bits=32), data_chunk(MONO[:4])), "UnsupportedFormat"))
    fx.append(rejected("fmt_bits24", "fmt", "Tag 1 with 24-bit samples.",
                       riff(fmt_chunk(bits=24), data_chunk(MONO[:3])), "UnsupportedFormat"))
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
                       "Precedence: tag 3 with zero channels reports the unsupported tag first.",
                       riff(fmt_chunk(tag=3, bits=32, channels=0), data_chunk([])), "UnsupportedFormat"))

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
    fx.append(rejected("data_size_unknown", "data length",
                       "`data` size 0xFFFFFFFF; precedence: the sentinel is reported before the extent check.",
                       riff(fmt_chunk(), data_chunk(MONO[:2], size=0xFFFFFFFF)), "UnsupportedStreamingSize"))
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
        fx.append(accepted(name, group, rule, data, channels, rate, samples, writer_output))

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
    bad("au_unknown_size", "size",
        "Data size 0xffffffff (unknown length) is deferred to T22a. FFmpeg reads to the end of input.",
        au(pcm_be(MONO[:4]), size=AU_UNKNOWN_SIZE), "UnsupportedStreamingSize")
    bad("au_data_size_over_limit", "limits",
        f"Data size 0x80000000 is above the 0x{AU_MAX_DATA:08x} limit that FFmpeg's signed read also enforces.",
        au(pcm_be(MONO[:4]), size=AU_MAX_DATA + 1), "LimitExceeded")
    bad("au_data_not_block_aligned", "size", "Stereo data size 6 ends inside a frame.",
        au(pcm_be(STEREO[:3]), channels=2), "InvalidFormat")
    bad("au_truncated_data", "size", "Data size 16, but input ends after 10 data bytes.",
        au(pcm_be(MONO[:5]), size=16), "Truncated")
    bad("au_truncated_mid_sample", "size", "Data size 8, but input ends inside the third sample.",
        au(pcm_be(MONO[:4])[:5], size=8), "Truncated")

    # Encoding, rate and channels.
    bad("au_encoding_mulaw", "format", "Encoding 1 (\u00b5-law) waits for T22a.",
        au(bytes(4), encoding=1), "UnsupportedFormat")
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
        "Data size over the limit and encoding 1: the data size field comes first.",
        au(bytes(4), encoding=1, size=AU_MAX_DATA + 1), "LimitExceeded")
    bad("au_unsupported_before_invalid", "precedence",
        "Encoding 6 (float) and sample rate 0: the encoding field comes first.",
        au(bytes(4), encoding=6, rate=0), "UnsupportedFormat")

    names = [f.name for f in fx]
    assert len(names) == len(set(names)), "duplicate AU fixture names"
    return fx


# --- outputs ---------------------------------------------------------------


def sha256(data):
    return hashlib.sha256(data).hexdigest()


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
        if f.accept is not None:
            channels, rate, samples = f.accept
            sample_list = "{}" if not samples else "{ " + ", ".join(str(s) for s in samples) + " }"
            lines.append(
                f"        .expected = .{{ .accept = .{{ .channels = {channels}, .sample_rate = {rate}, "
                f".samples = .{sample_list} }} }},"
            )
        else:
            lines.append(f"        .expected = .{{ .reject = .{f.reject} }},")
        if f.writer_output:
            lines.append("        .writer_output = true,")
        lines.append("    },")
    lines.append("}")
    return ("\n".join(lines) + "\n").encode()


def describe(f):
    if f.accept is not None:
        channels, rate, samples = f.accept
        layout = {1: "mono", 2: "stereo"}[channels]
        frames = len(samples) // channels
        text = f"accept: {layout}, {rate} Hz, {frames} frame{'s' if frames != 1 else ''}"
        return text + ("; writer output" if f.writer_output else "")
    return f"reject: `{f.reject}`"


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


def outputs(fixtures, au_fixtures):
    files = {WAV_DIR / f"{f.name}.wav": f.data for f in fixtures}
    files[MANIFEST] = render_manifest(
        fixtures, "// Each entry names wav/<name>.wav; see README.md for the rules and decisions.")
    files[README] = render_readme(README, render_table(fixtures, [large_skip_row()]))
    files.update({AU_DIR / f"{f.name}.au": f.data for f in au_fixtures})
    files[AU_MANIFEST] = render_manifest(
        au_fixtures, "// Each entry names au/<name>.au; see au/README.md for the rules and decisions.")
    files[AU_README] = render_readme(AU_README, render_table(au_fixtures))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if any generated output is missing or stale")
    args = parser.parse_args()

    fixtures = build_fixtures()
    au_fixtures = build_au_fixtures()
    expected = outputs(fixtures, au_fixtures)
    stale = [path for path, content in expected.items() if not path.exists() or path.read_bytes() != content]
    extra = sorted((set(WAV_DIR.glob("*.wav")) | set(AU_DIR.glob("*.au"))) - set(expected))

    if args.check:
        for path in stale:
            print(f"stale or missing: {path.relative_to(HERE)}", file=sys.stderr)
        for path in extra:
            print(f"not generated by generate.py: {path.relative_to(HERE)}", file=sys.stderr)
        if stale or extra:
            print("run: python3 zig/testing/fixtures/generate.py", file=sys.stderr)
            return 1
        print(f"{len(fixtures)} WAV and {len(au_fixtures)} AU fixtures, manifests and README tables are current")
        return 0

    WAV_DIR.mkdir(exist_ok=True)
    AU_DIR.mkdir(exist_ok=True)
    for path in extra:
        path.unlink()
    for path in stale:
        path.write_bytes(expected[path])
    print(f"wrote {len(stale)} file(s), removed {len(extra)}; {len(fixtures)} WAV and {len(au_fixtures)} AU fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
