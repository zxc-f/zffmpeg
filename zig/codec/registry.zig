// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/codec_desc.c and allcodecs.c at the pinned reference revision
// give the names, long names and properties recorded here.
//! Codec descriptors and the decoder and encoder registries (TODO.md T16).
//!
//! Every codec the port implements has one descriptor, as FFmpeg's
//! `AVCodecDescriptor`: its media type, FFmpeg's name and long name, and the
//! properties `ffmpeg -codecs` shows. The codec identity is `pcm.Codec` while
//! every implemented codec is PCM; the first other codec widens it into a
//! general identifier. The decoder and encoder registries list the
//! implementations by name, as `allcodecs.c` registers them, and say which
//! run as send/receive stages.
//!
//! Everything is checked at compile time: one descriptor per codec, in the
//! enum's order (so a lookup is an index), unique names, a decoder and an
//! encoder for every codec, and stage types that keep the signatures of
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

pub const Descriptor = struct {
    codec: pcm.Codec,
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

/// One per `pcm.Codec`, in its order.
pub const descriptors = [_]Descriptor{
    .{ .codec = .u8, .media_type = .audio, .long_name = "PCM unsigned 8-bit", .props = linear },
    .{ .codec = .s8, .media_type = .audio, .long_name = "PCM signed 8-bit", .props = linear },
    .{ .codec = .s16le, .media_type = .audio, .long_name = "PCM signed 16-bit little-endian", .props = linear },
    .{ .codec = .s16be, .media_type = .audio, .long_name = "PCM signed 16-bit big-endian", .props = linear },
    .{ .codec = .s24le, .media_type = .audio, .long_name = "PCM signed 24-bit little-endian", .props = linear },
    .{ .codec = .s24be, .media_type = .audio, .long_name = "PCM signed 24-bit big-endian", .props = linear },
    .{ .codec = .s32le, .media_type = .audio, .long_name = "PCM signed 32-bit little-endian", .props = linear },
    .{ .codec = .s32be, .media_type = .audio, .long_name = "PCM signed 32-bit big-endian", .props = linear },
    .{ .codec = .s64le, .media_type = .audio, .long_name = "PCM signed 64-bit little-endian", .props = linear },
    .{ .codec = .s64be, .media_type = .audio, .long_name = "PCM signed 64-bit big-endian", .props = linear },
    .{ .codec = .f32le, .media_type = .audio, .long_name = "PCM 32-bit floating point little-endian", .props = linear },
    .{ .codec = .f32be, .media_type = .audio, .long_name = "PCM 32-bit floating point big-endian", .props = linear },
    .{ .codec = .f64le, .media_type = .audio, .long_name = "PCM 64-bit floating point little-endian", .props = linear },
    .{ .codec = .f64be, .media_type = .audio, .long_name = "PCM 64-bit floating point big-endian", .props = linear },
    .{ .codec = .alaw, .media_type = .audio, .long_name = "PCM A-law / G.711 A-law", .props = companded },
    .{ .codec = .mulaw, .media_type = .audio, .long_name = "PCM mu-law / G.711 mu-law", .props = companded },
};

pub fn descriptor(codec: pcm.Codec) *const Descriptor {
    return &descriptors[@backingInt(codec)];
}

/// The codec FFmpeg names `name`, such as `pcm_s16le`, if the port implements it.
pub fn find(name: []const u8) ?pcm.Codec {
    for (&descriptors) |*d| {
        if (std.mem.eql(u8, d.name(), name)) return d.codec;
    }
    return null;
}

/// One decoder or encoder implementation, as `allcodecs.c` registers it.
pub const Implementation = struct {
    /// FFmpeg's decoder or encoder name; for PCM, the codec's name.
    name: []const u8,
    codec: pcm.Codec,
    /// Runs as a send/receive stage (`pcm.Decoder` or `pcm.Encoder`), which
    /// takes the codecs stored as s16 until T23a; the others decode and
    /// encode through the `pcm.decode` and `pcm.encode` kernels only.
    stage: bool,
};

/// Every PCM codec has a decoder and an encoder, named as the codec.
fn implementations() [descriptors.len]Implementation {
    var list: [descriptors.len]Implementation = undefined;
    for (&list, descriptors) |*entry, d| {
        entry.* = .{ .name = d.name(), .codec = d.codec, .stage = d.codec.storage() == .s16 };
    }
    return list;
}

pub const decoders: [descriptors.len]Implementation = implementations();
pub const encoders: [descriptors.len]Implementation = implementations();

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
    const tags = @typeInfo(pcm.Codec).@"enum".field_names;
    if (descriptors.len != tags.len) @compileError("every codec needs exactly one descriptor");
    for (descriptors, 0..) |d, i| {
        if (@backingInt(d.codec) != i) @compileError("descriptors must follow pcm.Codec's order: " ++ d.name());
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
    try std.testing.expectEqualStrings("PCM signed 24-bit big-endian", descriptor(.s24be).long_name);
    try std.testing.expectEqual(pcm.Codec.mulaw, find("pcm_mulaw"));
    try std.testing.expectEqual(null, find("pcm_s16"));
    try std.testing.expect(descriptor(.alaw).props.lossy and !descriptor(.alaw).props.lossless);
    try std.testing.expect(descriptor(.f64le).props.lossless and descriptor(.f64le).props.intra_only);
}

test "every codec has a decoder and an encoder; the s16-stored ones run as stages" {
    for (descriptors) |d| {
        const decoder = findDecoder(d.name()) orelse return error.TestExpectedValue;
        const encoder = findEncoder(d.name()) orelse return error.TestExpectedValue;
        try std.testing.expectEqual(d.codec, decoder.codec);
        try std.testing.expectEqual(d.codec, encoder.codec);
        try std.testing.expectEqual(d.codec.storage() == .s16, decoder.stage);
    }
    try std.testing.expectEqual(null, findDecoder("pcm_dvd"));
}
