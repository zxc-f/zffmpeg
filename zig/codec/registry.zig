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
//! name, as `allcodecs.c` registers them.
//!
//! Everything is checked at compile time: one descriptor per codec, PCM in
//! `pcm.Codec`'s order (so a lookup is an index) and then FLAC, unique
//! names, a decoder for every codec and an encoder for every PCM codec
//! (FLAC's comes with T26c), and the PCM stages (`pcm.Decoder`,
//! `pcm.Encoder`, every PCM codec since T23a) keeping the signatures of
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

/// A codec the port knows: one it decodes or encodes, or one only a
/// demuxer names (Vorbis and Opus before their decoders, T27a; MPEG audio,
/// T29a), as FFmpeg's descriptor does.
pub const Codec = union(enum) {
    pcm: pcm.Codec,
    flac,
    vorbis,
    opus,
    mp1,
    mp2,
    mp3,
    /// AAC (T30a): named by the ADTS demuxer and muxer; decoded since
    /// T30b.
    aac,
    /// IMA WAV and Microsoft ADPCM (T31a), in WAV.
    adpcm_ima_wav,
    adpcm_ms,
    /// ALAC (T31b).
    alac,
    /// G.722 and little-endian G.726 (T31c), in AU.
    adpcm_g722,
    adpcm_g726le,
    /// AC-3 (T32a), raw.
    ac3,

    /// FFmpeg's codec name, such as `pcm_s16le` or `flac`.
    pub fn name(c: Codec) []const u8 {
        return switch (c) {
            .pcm => |p| p.name(),
            .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 => @tagName(c),
        };
    }

    /// The PCM encoding, or null for a compressed codec.
    pub fn pcmCodec(c: Codec) ?pcm.Codec {
        return switch (c) {
            .pcm => |p| p,
            .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 => null,
        };
    }

    pub fn eql(a: Codec, b: Codec) bool {
        return switch (a) {
            .pcm => |p| b == .pcm and b.pcm == p,
            .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 => std.meta.activeTag(a) == std.meta.activeTag(b),
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
    // Named by the MP3 demuxer's parser (T29a); decoded (T29b, T29c).
    .{ .codec = .mp1, .media_type = .audio, .long_name = "MP1 (MPEG audio layer 1)", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .mp2, .media_type = .audio, .long_name = "MP2 (MPEG audio layer 2)", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .mp3, .media_type = .audio, .long_name = "MP3 (MPEG audio layer 3)", .props = .{ .intra_only = true, .lossy = true } },
    // Not intra-only in FFmpeg's descriptor: AAC frames depend on the one
    // before (the MDCT's overlap and LTP).
    .{ .codec = .aac, .media_type = .audio, .long_name = "AAC (Advanced Audio Coding)", .props = .{ .lossy = true } },
    // Every block decodes alone.
    .{ .codec = .adpcm_ima_wav, .media_type = .audio, .long_name = "ADPCM IMA WAV", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .adpcm_ms, .media_type = .audio, .long_name = "ADPCM Microsoft", .props = .{ .intra_only = true, .lossy = true } },
    // Every frame decodes alone.
    .{ .codec = .alac, .media_type = .audio, .long_name = "ALAC (Apple Lossless Audio Codec)", .props = .{ .intra_only = true, .lossless = true } },
    // Intra-only in FFmpeg's descriptors, though each packet's state
    // carries into the next.
    .{ .codec = .adpcm_g722, .media_type = .audio, .long_name = "G.722 ADPCM", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .adpcm_g726le, .media_type = .audio, .long_name = "G.726 ADPCM little-endian", .props = .{ .intra_only = true, .lossy = true } },
    .{ .codec = .ac3, .media_type = .audio, .long_name = "ATSC A/52A (AC-3)", .props = .{ .intra_only = true, .lossy = true } },
};

/// The descriptors after the PCM ones, in their order.
const compressed = [_]std.meta.Tag(Codec){ .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 };

fn pcmDescriptor(codec: pcm.Codec, long_name: []const u8, props: Props) Descriptor {
    return .{ .codec = .{ .pcm = codec }, .media_type = .audio, .long_name = long_name, .props = props };
}

pub fn descriptor(codec: Codec) *const Descriptor {
    return switch (codec) {
        .pcm => |p| &descriptors[@backingInt(p)],
        .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 => &descriptors[pcm_count + std.mem.findScalar(std.meta.Tag(Codec), &compressed, std.meta.activeTag(codec)).?],
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
};

const pcm_count = @typeInfo(pcm.Codec).@"enum".field_names.len;

/// Every PCM codec has a decoder and an encoder, named as the codec.
fn pcmImplementations() [pcm_count]Implementation {
    var list: [pcm_count]Implementation = undefined;
    for (&list, descriptors[0..pcm_count]) |*entry, d| {
        entry.* = .{ .name = d.name(), .codec = d.codec };
    }
    return list;
}

/// The PCM decoders, then FLAC's (T26a), Vorbis' (T27d), Opus' (T28),
/// MPEG audio's (the float decoders the reference build enables, one
/// implementation for every layer: mp3float, T29b; mp1float and mp2float,
/// T29c) and AAC's (the float `aac`, T30b), which have their own APIs.
pub const decoders = pcmImplementations() ++ [_]Implementation{
    .{ .name = "flac", .codec = .flac },
    .{ .name = "vorbis", .codec = .vorbis },
    .{ .name = "opus", .codec = .opus },
    .{ .name = "mp3float", .codec = .mp3 },
    .{ .name = "mp1float", .codec = .mp1 },
    .{ .name = "mp2float", .codec = .mp2 },
    .{ .name = "aac", .codec = .aac },
    .{ .name = "adpcm_ima_wav", .codec = .adpcm_ima_wav },
    .{ .name = "adpcm_ms", .codec = .adpcm_ms },
    .{ .name = "alac", .codec = .alac },
    .{ .name = "g722", .codec = .adpcm_g722 },
    .{ .name = "g726le", .codec = .adpcm_g726le },
    .{ .name = "ac3", .codec = .ac3 },
};
/// The PCM encoders, then FLAC's (T26c) and MP2's (T29d).
pub const encoders = pcmImplementations() ++ [_]Implementation{
    .{ .name = "flac", .codec = .flac },
    // FFmpeg's MP2 encoders (T29d), in allcodecs.c's order.
    .{ .name = "mp2", .codec = .mp2 },
    .{ .name = "mp2fixed", .codec = .mp2 },
    // FFmpeg's ADPCM encoders (T31a).
    .{ .name = "adpcm_ima_wav", .codec = .adpcm_ima_wav },
    .{ .name = "adpcm_ms", .codec = .adpcm_ms },
    .{ .name = "alac", .codec = .alac },
    .{ .name = "g722", .codec = .adpcm_g722 },
    .{ .name = "g726le", .codec = .adpcm_g726le },
};

/// The decoder FFmpeg names `name`, if registered.
pub fn findDecoder(name: []const u8) ?*const Implementation {
    return findIn(&decoders, name);
}

/// The encoder FFmpeg names `name`, if registered.
pub fn findEncoder(name: []const u8) ?*const Implementation {
    return findIn(&encoders, name);
}

/// fftools' find_codec for an encoder: the encoder named `name`, else the
/// first one registered for the codec named `name` (`-c:a adpcm_g722`
/// finds `g722`).
pub fn findEncoderOrCodec(name: []const u8) ?*const Implementation {
    if (findEncoder(name)) |found| return found;
    for (&descriptors) |*d| {
        if (!std.mem.eql(u8, d.name(), name)) continue;
        for (&encoders) |*entry| if (entry.codec.eql(d.codec)) return entry;
        return null;
    }
    return null;
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
            .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac, .adpcm_g722, .adpcm_g726le, .ac3 => if (i < pcm_count or compressed[i - pcm_count] != std.meta.activeTag(d.codec)) @compileError("the compressed codecs' descriptors follow the PCM ones in order"),
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

test "every PCM codec has a decoder and an encoder" {
    for (descriptors[0..pcm_count]) |d| {
        const decoder = findDecoder(d.name()) orelse return error.TestExpectedValue;
        const encoder = findEncoder(d.name()) orelse return error.TestExpectedValue;
        try std.testing.expect(d.codec.eql(decoder.codec));
        try std.testing.expect(d.codec.eql(encoder.codec));
    }
    try std.testing.expectEqual(null, findDecoder("pcm_dvd"));
    // FLAC decodes (T26a) and encodes (T26c).
    try std.testing.expect(findDecoder("flac").?.codec.eql(.flac));
    try std.testing.expect(findEncoder("flac").?.codec.eql(.flac));
    // MPEG audio decodes (T29b, T29c).
    try std.testing.expect(findDecoder("mp3float").?.codec.eql(.mp3));
    try std.testing.expect(findDecoder("mp2float").?.codec.eql(.mp2));
    try std.testing.expect(findDecoder("mp1float").?.codec.eql(.mp1));
    // AAC decodes (T30b); the port has no AAC encoder.
    try std.testing.expect(findDecoder("aac").?.codec.eql(.aac));
    try std.testing.expectEqual(null, findEncoder("aac"));
}
