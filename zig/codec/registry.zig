// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/codec_desc.c and allcodecs.c at the pinned reference revision
// give the names, long names and properties recorded here.
//! Codec descriptors and the decoder and encoder registries (TODO.md T16).
//!
//! Every codec the port implements has one descriptor, as FFmpeg's
//! `AVCodecDescriptor`: its media type, FFmpeg's name and long name, and the
//! properties `ffmpeg -codecs` shows. A codec is identified by `Codec`: a
//! PCM encoding (`pcm.Codec`) or FLAC (T26a), the first codec that is not
//! PCM. The decoder and encoder registries list the implementations by
//! name, as `allcodecs.c` registers them, and say which run as send/receive
//! stages.
//!
//! Everything is checked at compile time: one descriptor per codec, PCM in
//! `pcm.Codec`'s order (so a lookup is an index) and then FLAC, unique
//! names, a decoder for every codec and an encoder for every PCM codec
//! (FLAC's comes with T26c), and stage types that keep the signatures of
//! core/stage.zig. zig/testing/reference/compare.py compares the tables with
//! the reference build's own `ffmpeg -codecs` listing.

const std = @import("std");
const pcm = @import("pcm.zig");
const stage = @import("../core/stage.zig");
const Packet = @import("../core/packet.zig").Packet;
const Frame = @import("../core/frame.zig").Frame;

/// FFmpeg's `AVMediaType`, for the media the port implements.
pub const MediaType = enum { audio };

/// The `AV_CODEC_PROP_*` flags `ffmpeg -codecs` shows as `I`, `L` and `S`.
pub const Props = struct {
    intra_only: bool = false,
    lossy: bool = false,
    lossless: bool = false,
};

/// A codec the port knows: one it decodes or encodes, or, for Vorbis and
/// Opus, one only a demuxer names (T27a), as FFmpeg's descriptor does.
pub const Codec = union(enum) {
    pcm: pcm.Codec,
    flac,
    vorbis,
    opus,

    /// FFmpeg's codec name, such as `pcm_s16le` or `flac`.
    pub fn name(c: Codec) []const u8 {
        return switch (c) {
            .pcm => |p| p.name(),
            .flac, .vorbis, .opus => @tagName(c),
        };
    }

    /// The PCM encoding, or null for a compressed codec.
    pub fn pcmCodec(c: Codec) ?pcm.Codec {
        return switch (c) {
            .pcm => |p| p,
            .flac, .vorbis, .opus => null,
        };
    }

    pub fn eql(a: Codec, b: Codec) bool {
        return switch (a) {
            .pcm => |p| b == .pcm and b.pcm == p,
            .flac, .vorbis, .opus => std.meta.activeTag(a) == std.meta.activeTag(b),
        };
    }
};

pub const Descriptor = struct {
    codec: Codec,
    media_type: MediaType,
    long_name: []const u8,
    props: Props,

    /// FFmpeg's codec name, such as `pcm_s16le`.
    pub fn name(d: *const Descriptor) []const u8 {
        return d.codec.name();
    }
};

/// Linear PCM: every packet decodes alone, exactly.
const linear: Props = .{ .intra_only = true, .lossless = true };
/// G.711 companding: every packet decodes alone, with quantization loss.
const companded: Props = .{ .intra_only = true, .lossy = true };

/// One per `pcm.Codec`, in its order, then FLAC, Vorbis and Opus.
pub const descriptors = [_]Descriptor{
    pcmDescriptor(.u8, "PCM unsigned 8-bit", linear),
    pcmDescriptor(.s8, "PCM signed 8-bit", linear),
    pcmDescriptor(.s16le, "PCM signed 16-bit little-endian", linear),
    pcmDescriptor(.s16be, "PCM signed 16-bit big-endian", linear),
    pcmDescriptor(.s24le, "PCM signed 24-bit little-endian", linear),
    pcmDescriptor(.s24be, "PCM signed 24-bit big-endian", linear),
    pcmDescriptor(.s32le, "PCM signed 32-bit little-endian", linear),
    pcmDescriptor(.s32be, "PCM signed 32-bit big-endian", linear),
    pcmDescriptor(.s64le, "PCM signed 64-bit little-endian", linear),
    pcmDescriptor(.s64be, "PCM signed 64-bit big-endian", linear),
    pcmDescriptor(.f32le, "PCM 32-bit floating point little-endian", linear),
    pcmDescriptor(.f32be, "PCM 32-bit floating point big-endian", linear),
    pcmDescriptor(.f64le, "PCM 64-bit floating point little-endian", linear),
    pcmDescriptor(.f64be, "PCM 64-bit floating point big-endian", linear),
    pcmDescriptor(.alaw, "PCM A-law / G.711 A-law", companded),
    pcmDescriptor(.mulaw, "PCM mu-law / G.711 mu-law", companded),
    // Every FLAC frame decodes alone, exactly.
    .{ .codec = .flac, .media_type = .audio, .long_name = "FLAC (Free Lossless Audio Codec)", .props = .{ .intra_only = true, .lossless = true } },
    // Named by the Ogg demuxer (T27a); not decoded.
    .{ .codec = .vorbis, .media_type = .audio, .long_name = "Vorbis", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .opus, .media_type = .audio, .long_name = "Opus (Opus Interactive Audio Codec)", .props = .{ .intra_only = true, .lossy = true } },
};

/// The descriptors after the PCM ones, in their order.
const compressed = [_]std.meta.Tag(Codec){ .flac, .vorbis, .opus };

fn pcmDescriptor(codec: pcm.Codec, long_name: []const u8, props: Props) Descriptor {
    return .{ .codec = .{ .pcm = codec }, .media_type = .audio, .long_name = long_name, .props = props };
}

pub fn descriptor(codec: Codec) *const Descriptor {
    return switch (codec) {
        .pcm => |p| &descriptors[@backingInt(p)],
        .flac, .vorbis, .opus => &descriptors[pcm_count + std.mem.findScalar(std.meta.Tag(Codec), &compressed, std.meta.activeTag(codec)).?],
    };
}

/// The codec FFmpeg names `name`, such as `pcm_s16le`, if the port implements it.
pub fn find(name: []const u8) ?Codec {
    for (&descriptors) |*d| {
        if (std.mem.eql(u8, d.name(), name)) return d.codec;
    }
    return null;
}

/// One decoder or encoder implementation, as `allcodecs.c` registers it.
pub const Implementation = struct {
    /// FFmpeg's decoder or encoder name; for PCM and FLAC, the codec's name.
    name: []const u8,
    codec: Codec,
    /// Runs as a send/receive stage (`pcm.Decoder` or `pcm.Encoder`), which
    /// takes the codecs stored as s16 until T23a; the others decode and
    /// encode through the `pcm.decode` and `pcm.encode` kernels only, and
    /// FLAC's decoder and encoder have their own APIs (codec/flacdec.zig,
    /// codec/flacenc.zig).
    stage: bool,
};

const pcm_count = @typeInfo(pcm.Codec).@"enum".field_names.len;

/// Every PCM codec has a decoder and an encoder, named as the codec.
fn pcmImplementations() [pcm_count]Implementation {
    var list: [pcm_count]Implementation = undefined;
    for (&list, descriptors[0..pcm_count]) |*entry, d| {
        entry.* = .{ .name = d.name(), .codec = d.codec, .stage = d.codec.pcm.storage() == .s16 };
    }
    return list;
}

/// The PCM decoders, then FLAC's (T26a) and Vorbis' (T27d).
pub const decoders = pcmImplementations() ++ [_]Implementation{
    .{ .name = "flac", .codec = .flac, .stage = false },
    .{ .name = "vorbis", .codec = .vorbis, .stage = false },
};
/// The PCM encoders, then FLAC's (T26c).
pub const encoders = pcmImplementations() ++ [_]Implementation{.{ .name = "flac", .codec = .flac, .stage = false }};

/// The decoder FFmpeg names `name`, if registered.
pub fn findDecoder(name: []const u8) ?*const Implementation {
    return findIn(&decoders, name);
}

/// The encoder FFmpeg names `name`, if registered.
pub fn findEncoder(name: []const u8) ?*const Implementation {
    return findIn(&encoders, name);
}

fn findIn(list: []const Implementation, name: []const u8) ?*const Implementation {
    for (list) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

comptime {
    @setEvalBranchQuota(10_000);
    if (descriptors.len != pcm_count + compressed.len) @compileError("every codec needs exactly one descriptor");
    for (descriptors, 0..) |d, i| {
        switch (d.codec) {
            .pcm => |p| if (@backingInt(p) != i) @compileError("descriptors must follow pcm.Codec's order: " ++ d.name()),
            .flac, .vorbis, .opus => if (i < pcm_count or compressed[i - pcm_count] != std.meta.activeTag(d.codec)) @compileError("the compressed codecs' descriptors follow the PCM ones in order"),
        }
        if (d.props.lossy and d.props.lossless) @compileError("a codec is lossy or lossless, not both: " ++ d.name());
    }
    for ([_][]const Implementation{ &decoders, &encoders }) |list| {
        for (list, 0..) |entry, i| {
            for (list[i + 1 ..]) |other| {
                if (std.mem.eql(u8, entry.name, other.name)) @compileError("a name is registered twice: " ++ entry.name);
            }
        }
    }
    stage.check(pcm.Decoder, Packet, Frame);
    stage.check(pcm.Encoder, Frame, Packet);
}

test "descriptors are found by codec and by FFmpeg's name" {
    try std.testing.expectEqualStrings("PCM signed 24-bit big-endian", descriptor(.{ .pcm = .s24be }).long_name);
    try std.testing.expect(find("pcm_mulaw").?.eql(.{ .pcm = .mulaw }));
    try std.testing.expect(find("flac").?.eql(.flac));
    try std.testing.expectEqual(null, find("pcm_s16"));
    try std.testing.expect(descriptor(.{ .pcm = .alaw }).props.lossy and !descriptor(.{ .pcm = .alaw }).props.lossless);
    try std.testing.expect(descriptor(.{ .pcm = .f64le }).props.lossless and descriptor(.{ .pcm = .f64le }).props.intra_only);
    try std.testing.expectEqualStrings("FLAC (Free Lossless Audio Codec)", descriptor(.flac).long_name);
}

test "every PCM codec has a decoder and an encoder; the s16-stored ones run as stages" {
    for (descriptors[0..pcm_count]) |d| {
        const decoder = findDecoder(d.name()) orelse return error.TestExpectedValue;
        const encoder = findEncoder(d.name()) orelse return error.TestExpectedValue;
        try std.testing.expect(d.codec.eql(decoder.codec));
        try std.testing.expect(d.codec.eql(encoder.codec));
        try std.testing.expectEqual(d.codec.pcm.storage() == .s16, decoder.stage);
    }
    try std.testing.expectEqual(null, findDecoder("pcm_dvd"));
    // FLAC decodes (T26a) and encodes (T26c).
    try std.testing.expect(findDecoder("flac").?.codec.eql(.flac));
    try std.testing.expect(findEncoder("flac").?.codec.eql(.flac));
}
