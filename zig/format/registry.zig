// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/allformats.c and the demuxer and muxer descriptors of wavdec.c,
// wavenc.c, au.c, aiffdec.c, aiffenc.c, cafdec.c and flacdec.c at the
// pinned reference revision
// give the names, long names, extensions, MIME types and default codecs.
//! The format registry (TODO.md T16): every container's FFmpeg name and long
//! name, its demuxer's content probe, and its muxer's file-name extensions,
//! MIME type, default audio codec and carried codecs, as FFmpeg's
//! `AVInputFormat` and `AVOutputFormat` describe them.
//!
//! The parsers and writers stay behind exhaustive switches on `Container`
//! (in `detect.zig` and `convert.zig`), which the compiler makes every new
//! format handle; this table owns the facts tools look up by name. It is
//! checked at compile time: one entry per container in the enum's order (so a
//! lookup is an index), names equal to the tags, file-name extensions
//! lowercase and unique across muxers, and each muxer carrying its default
//! codec. A demuxer without a content probe, such as raw PCM (T22c), is never
//! chosen by probing. zig/testing/reference/compare.py compares the table with
//! the reference build's `ffmpeg -formats` and `ffmpeg -h muxer=...`.

const std = @import("std");
const builtin = @import("builtin");
const pcm = @import("../codec/pcm.zig");
const codecs = @import("../codec/registry.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const aiff = @import("aiff.zig");
const raw = @import("raw.zig");
const caf = @import("caf.zig");
const flac = @import("flac.zig");
const ogg = @import("ogg.zig");
const mp3 = @import("mp3.zig");
const aac = @import("aac.zig");

pub const Container = enum {
    wav,
    /// Sony Wave64, read and written by format/wav.zig.
    w64,
    au,
    /// AIFF and AIFF-C.
    aiff,
    /// Apple Core Audio Format, read only (T22d).
    caf,
    /// Native FLAC (T26a), written since T26c.
    flac,
    /// Ogg, read since T27a and written since T27b.
    ogg,
    /// FFmpeg's Ogg Audio and Ogg Opus muxers (T27b): Ogg, written only.
    oga,
    opus,
    /// MPEG audio (T29a), read only; decoded since T29b and T29c.
    mp3,
    /// FFmpeg's mp2 muxer (T29d): MP2 packets, written only (the mp3
    /// demuxer reads them).
    mp2,
    /// Raw ADTS AAC (T30a), read without decoding: FFmpeg's `aac` demuxer.
    aac,
    /// FFmpeg's ADTS muxer (T30a): AAC packets, written only (the aac
    /// demuxer reads them); no encoder here gives it any yet.
    adts,
    // Raw PCM (T22c), one format per codec FFmpeg has a raw format for, named
    // as the codec: every PCM codec but s64.
    u8,
    s8,
    s16le,
    s16be,
    s24le,
    s24be,
    s32le,
    s32be,
    f32le,
    f32be,
    f64le,
    f64be,
    alaw,
    mulaw,

    /// The parser and writer family that reads and writes a container.
    pub const Family = enum { wav, au, aiff, caf, flac, ogg, mp3, mp2, aac, adts, raw };

    pub fn family(container: Container) Family {
        return switch (container) {
            .wav, .w64 => .wav,
            .au => .au,
            .aiff => .aiff,
            .caf => .caf,
            .flac => .flac,
            .ogg, .oga, .opus => .ogg,
            .mp3 => .mp3,
            .mp2 => .mp2,
            .aac => .aac,
            .adts => .adts,
            // Checked below: exactly the raw formats, each named as its codec.
            else => .raw,
        };
    }

    /// A demuxer with `FF_INFMT_FLAG_ID3V2_AUTO` whose leading ID3v2 tags
    /// detection reads before the parser (`detect.Input.readLeadingTags`),
    /// as avformat_open_input reads them: WAV (not Wave64) and FLAC. The
    /// MP3 demuxer, which has the flag too, reads its own.
    pub fn readsLeadingId3v2(container: Container) bool {
        return container == .wav or container == .flac;
    }

    /// The codec of a raw PCM format, which shares its name; null otherwise.
    pub fn rawCodec(container: Container) ?pcm.Codec {
        return switch (container) {
            .wav, .w64, .au, .aiff, .caf, .flac, .ogg, .oga, .opus, .mp3, .mp2, .aac, .adts => null,
            // Compiles only if every other tag names a codec.
            inline else => |tag| @field(pcm.Codec, @tagName(tag)),
        };
    }

    pub fn format(container: Container) *const Format {
        return &formats[@backingInt(container)];
    }

    /// FFmpeg's format name, as in probe output.
    pub fn name(container: Container) []const u8 {
        return container.format().name;
    }

    /// The container of a stream the WAV parser read.
    pub fn ofWav(variant: wav.Variant) Container {
        return switch (variant) {
            .wav => .wav,
            .w64 => .w64,
        };
    }

    /// Whether this container's muxer can carry the PCM codec `codec`.
    pub fn carries(container: Container, codec: pcm.Codec) bool {
        return container.carriesCodec(.{ .pcm = codec });
    }

    /// Whether this container's muxer can carry `codec`.
    pub fn carriesCodec(container: Container, codec: codecs.Codec) bool {
        const muxer = container.format().muxer orelse return false;
        return muxer.carries(codec);
    }

    /// The codec transcoding writes unless asked otherwise: FFmpeg's default
    /// audio codec for the muxer, or null for a container without one.
    pub fn defaultCodec(container: Container) ?codecs.Codec {
        const muxer = container.format().muxer orelse return null;
        return muxer.audio_codec;
    }
};

pub const Demuxer = struct {
    /// FFmpeg's `read_probe`: a score from 0 to 100 for the probe buffer
    /// (the stream's first bytes, after any ID3v2 tag probing skipped; FFmpeg
    /// pads it with zeros). Null for a format without a content signature,
    /// which content alone never chooses.
    probe: ?*const fn (head: []const u8) u8,
    /// FFmpeg's `extensions`, lowercase without the dot: a file-name hint for
    /// detection (`detect.zig`).
    extensions: []const []const u8 = &.{},
};

pub const Muxer = struct {
    /// FFmpeg's `extensions`: lowercase, without the dot.
    extensions: []const []const u8,
    mime_type: ?[]const u8,
    /// FFmpeg's `audio_codec`, the one an output gets unless asked otherwise.
    audio_codec: codecs.Codec,
    carries: *const fn (codec: codecs.Codec) bool,
};

pub const Format = struct {
    container: Container,
    /// FFmpeg's short name, such as `wav`; the tag of `container`.
    name: []const u8,
    long_name: []const u8,
    demuxer: ?Demuxer,
    muxer: ?Muxer,
};

/// One per `Container`, in its order.
pub const formats = [_]Format{
    .{
        .container = .wav,
        .name = "wav",
        .long_name = "WAV / WAVE (Waveform Audio)",
        .demuxer = .{ .probe = wav.probeScore },
        .muxer = .{ .extensions = &.{"wav"}, .mime_type = "audio/x-wav", .audio_codec = .{ .pcm = .s16le }, .carries = wavCodecs },
    },
    .{
        .container = .w64,
        .name = "w64",
        .long_name = "Sony Wave64",
        .demuxer = .{ .probe = wav.w64ProbeScore },
        .muxer = .{ .extensions = &.{"w64"}, .mime_type = null, .audio_codec = .{ .pcm = .s16le }, .carries = pcmOnly(wav.carries) },
    },
    .{
        .container = .au,
        .name = "au",
        .long_name = "Sun AU",
        .demuxer = .{ .probe = au.probeScore },
        .muxer = .{ .extensions = &.{"au"}, .mime_type = "audio/basic", .audio_codec = .{ .pcm = .s16be }, .carries = pcmOnly(au.carries) },
    },
    .{
        .container = .aiff,
        .name = "aiff",
        .long_name = "Audio IFF",
        .demuxer = .{ .probe = aiff.probeScore },
        .muxer = .{
            .extensions = &.{ "aif", "aiff", "afc", "aifc" },
            .mime_type = "audio/aiff",
            .audio_codec = .{ .pcm = .s16be },
            .carries = pcmOnly(aiff.carries),
        },
    },
    .{
        .container = .caf,
        .name = "caf",
        .long_name = "Apple CAF (Core Audio Format)",
        .demuxer = .{ .probe = caf.probeScore },
        // FFmpeg's CAF muxer is not ported (T22d is demux only).
        .muxer = null,
    },
    .{
        .container = .flac,
        .name = "flac",
        .long_name = "raw FLAC",
        .demuxer = .{ .probe = flac.probeScore, .extensions = &.{"flac"} },
        // FFmpeg's FLAC muxer (T26c), which carries FLAC only.
        .muxer = .{ .extensions = &.{"flac"}, .mime_type = "audio/x-flac", .audio_codec = .flac, .carries = flacOnly },
    },
    .{
        .container = .ogg,
        .name = "ogg",
        .long_name = "Ogg",
        .demuxer = .{ .probe = ogg.probeScore, .extensions = &.{"ogg"} },
        // FFmpeg's Ogg muxer (T27b). Its extensions take those of the Ogg
        // Video and Speex muxers, which the reference build does not have;
        // its default is FLAC, the reference build having no libvorbis.
        .muxer = .{ .extensions = &.{ "ogg", "ogv", "spx" }, .mime_type = "application/ogg", .audio_codec = .flac, .carries = oggCodecs },
    },
    .{
        .container = .oga,
        .name = "oga",
        .long_name = "Ogg Audio",
        .demuxer = null,
        .muxer = .{ .extensions = &.{"oga"}, .mime_type = "audio/ogg", .audio_codec = .flac, .carries = oggCodecs },
    },
    .{
        .container = .opus,
        .name = "opus",
        .long_name = "Ogg Opus",
        .demuxer = null,
        // Opus by default, which no encoder here writes; ogg_init takes
        // every Ogg codec whatever the muxer's name.
        .muxer = .{ .extensions = &.{"opus"}, .mime_type = "audio/ogg", .audio_codec = .opus, .carries = oggCodecs },
    },
    .{
        .container = .mp3,
        .name = "mp3",
        .long_name = "MP2/3 (MPEG audio layer 2/3)",
        // FFmpeg's mp3 demuxer (T29a); the reference build has no mp3 muxer.
        .demuxer = .{ .probe = mp3.probeScore, .extensions = &.{ "mp2", "mp3", "m2a", "mpa" } },
        .muxer = null,
    },
    .{
        .container = .mp2,
        .name = "mp2",
        .long_name = "MP2 (MPEG audio layer 2)",
        // FFmpeg's raw mp2 muxer (T29d), which carries MP2 only.
        .demuxer = null,
        .muxer = .{ .extensions = &.{ "mp2", "m2a", "mpa" }, .mime_type = "audio/mpeg", .audio_codec = .mp2, .carries = mp2Only },
    },
    .{
        .container = .aac,
        .name = "aac",
        .long_name = "raw ADTS AAC (Advanced Audio Coding)",
        // FFmpeg's aac demuxer (T30a); its adts muxer is another format.
        .demuxer = .{ .probe = aac.probeScore, .extensions = &.{"aac"} },
        .muxer = null,
    },
    .{
        .container = .adts,
        .name = "adts",
        .long_name = "ADTS AAC (Advanced Audio Coding)",
        // FFmpeg's adts muxer (T30a), which carries AAC only.
        .demuxer = null,
        .muxer = .{ .extensions = &.{ "aac", "adts" }, .mime_type = "audio/aac", .audio_codec = .aac, .carries = aacOnly },
    },
    rawFormat(.u8, "PCM unsigned 8-bit", &.{"ub"}),
    rawFormat(.s8, "PCM signed 8-bit", &.{"sb"}),
    // FFmpeg gives `sw` to the native byte order's 16-bit format (`AV_NE`).
    rawFormat(.s16le, "PCM signed 16-bit little-endian", if (native_endian == .little) &.{"sw"} else &.{}),
    rawFormat(.s16be, "PCM signed 16-bit big-endian", if (native_endian == .big) &.{"sw"} else &.{}),
    rawFormat(.s24le, "PCM signed 24-bit little-endian", &.{}),
    rawFormat(.s24be, "PCM signed 24-bit big-endian", &.{}),
    rawFormat(.s32le, "PCM signed 32-bit little-endian", &.{}),
    rawFormat(.s32be, "PCM signed 32-bit big-endian", &.{}),
    rawFormat(.f32le, "PCM 32-bit floating-point little-endian", &.{}),
    rawFormat(.f32be, "PCM 32-bit floating-point big-endian", &.{}),
    rawFormat(.f64le, "PCM 64-bit floating-point little-endian", &.{}),
    rawFormat(.f64be, "PCM 64-bit floating-point big-endian", &.{}),
    rawFormat(.alaw, "PCM A-law", &.{"al"}),
    rawFormat(.mulaw, "PCM mu-law", &.{"ul"}),
};

const native_endian = builtin.cpu.arch.endian();

/// A raw PCM format (pcmdec.c, pcmenc.c): no probe, the same extensions for
/// the demuxer and the muxer, which carries only its own codec.
fn rawFormat(comptime container: Container, long_name: []const u8, extensions: []const []const u8) Format {
    const codec = container.rawCodec() orelse unreachable; // a raw container, by its callers
    return .{
        .container = container,
        .name = @tagName(container),
        .long_name = long_name,
        .demuxer = .{ .probe = null, .extensions = extensions },
        .muxer = .{ .extensions = extensions, .mime_type = null, .audio_codec = .{ .pcm = codec }, .carries = onlyCodec(codec) },
    };
}

fn onlyCodec(comptime codec: pcm.Codec) *const fn (codecs.Codec) bool {
    return struct {
        fn carries(other: codecs.Codec) bool {
            return other.eql(.{ .pcm = codec });
        }
    }.carries;
}

/// A PCM muxer's `carries`, which carries no FLAC.
fn pcmOnly(comptime carries: fn (pcm.Codec) bool) *const fn (codecs.Codec) bool {
    return struct {
        fn f(codec: codecs.Codec) bool {
            return switch (codec) {
                .pcm => |p| carries(p),
                .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac => false,
            };
        }
    }.f;
}

/// The WAV muxer's codecs: its PCM encodings, and IMA WAV and Microsoft
/// ADPCM (T31a), which the Wave64 writer does not port (notes.md "ADPCM").
fn wavCodecs(codec: codecs.Codec) bool {
    return switch (codec) {
        .pcm => |p| wav.carries(p),
        .adpcm_ima_wav, .adpcm_ms => true,
        .flac, .vorbis, .opus, .mp1, .mp2, .mp3, .aac, .alac => false,
    };
}

fn flacOnly(codec: codecs.Codec) bool {
    return codec == .flac;
}

fn aacOnly(codec: codecs.Codec) bool {
    return codec == .aac;
}

fn mp2Only(codec: codecs.Codec) bool {
    return codec == .mp2;
}

/// The Ogg muxers' codecs (ogg_init): FLAC, Opus and Vorbis, of those the
/// port names.
fn oggCodecs(codec: codecs.Codec) bool {
    return switch (codec) {
        .flac, .opus, .vorbis => true,
        .pcm, .mp1, .mp2, .mp3, .aac, .adpcm_ima_wav, .adpcm_ms, .alac => false,
    };
}

/// The container FFmpeg names `name`, if it has a demuxer (an input `-f`).
pub fn findDemuxer(name: []const u8) ?Container {
    const format = find(name) orelse return null;
    return if (format.demuxer != null) format.container else null;
}

/// The container FFmpeg names `name`, if it has a muxer (an output `-f`).
pub fn findMuxer(name: []const u8) ?Container {
    const format = find(name) orelse return null;
    return if (format.muxer != null) format.container else null;
}

fn find(name: []const u8) ?*const Format {
    for (&formats) |*format| {
        if (std.mem.eql(u8, format.name, name)) return format;
    }
    return null;
}

/// The muxer for a file name's extension, as `std.fs.path.extension` gives
/// it (`.aif`), compared without regard to case as FFmpeg's `av_match_ext`.
pub fn muxerForExtension(extension: []const u8) ?Container {
    if (extension.len < 2 or extension[0] != '.') return null;
    for (&formats) |*format| {
        const muxer = format.muxer orelse continue;
        for (muxer.extensions) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, extension[1..])) return format.container;
        }
    }
    return null;
}

comptime {
    @setEvalBranchQuota(10_000);
    const tags = @typeInfo(Container).@"enum".field_names;
    if (formats.len != tags.len) @compileError("every container needs exactly one format entry");
    for (formats, tags, 0..) |format, tag, i| {
        if (@backingInt(format.container) != i) @compileError("formats must follow Container's order: " ++ format.name);
        if (!std.mem.eql(u8, format.name, tag)) @compileError("a format name differs from its container's tag: " ++ format.name);
        if (format.demuxer == null and format.muxer == null) @compileError("a format needs a demuxer or a muxer: " ++ format.name);
        if ((format.container.family() == .raw) != (format.container.rawCodec() != null)) {
            @compileError("raw formats are exactly the containers named as a codec: " ++ format.name);
        }
        if (format.container.rawCodec()) |codec| {
            if (!raw.carries(codec)) @compileError("FFmpeg has no raw format for this codec: " ++ format.name);
        }
        if (format.demuxer) |demuxer| checkExtensions(demuxer.extensions, format.name);
        const muxer = format.muxer orelse continue;
        if (!muxer.carries(muxer.audio_codec)) @compileError("a muxer does not carry its default codec: " ++ format.name);
        checkExtensions(muxer.extensions, format.name);
        for (muxer.extensions) |extension| {
            for (formats[i + 1 ..]) |other| {
                const other_muxer = other.muxer orelse continue;
                for (other_muxer.extensions) |other_extension| {
                    if (std.mem.eql(u8, extension, other_extension)) @compileError("an extension names two muxers: " ++ extension);
                }
            }
        }
    }
}

fn checkExtensions(comptime extensions: []const []const u8, comptime name: []const u8) void {
    for (extensions) |extension| {
        if (extension.len == 0) @compileError("an empty extension: " ++ name);
        for (extension) |c| {
            if (c == '.' or std.ascii.isUpper(c)) @compileError("extensions are lowercase, without the dot: " ++ extension);
        }
    }
}

/// FFmpeg's `av_match_ext`'s extension: the text after the name's last
/// dot, `strrchr` over the whole name, so a name that is only `.ogg` has
/// `ogg` (where `std.fs.path.extension` gives none) and `take.ogg/` has
/// none; null without a dot or with nothing after it.
fn fileExtension(file_name: []const u8) ?[]const u8 {
    const dot = std.mem.findScalarLast(u8, file_name, '.') orelse return null;
    const extension = file_name[dot + 1 ..];
    return if (extension.len == 0) null else extension;
}

/// Whether `file_name`'s extension is one of `extensions`, as FFmpeg's
/// `av_match_ext`, without regard to case.
pub fn matchesExtension(file_name: []const u8, extensions: []const []const u8) bool {
    const extension = fileExtension(file_name) orelse return false;
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, extension)) return true;
    }
    return false;
}

/// The muxer for `file_name`'s extension as `av_guess_format` finds it
/// (`av_match_ext`, so `fileExtension`'s rule).
pub fn muxerForFileName(file_name: []const u8) ?Container {
    for (&formats) |*format| {
        const muxer = format.muxer orelse continue;
        if (matchesExtension(file_name, muxer.extensions)) return format.container;
    }
    return null;
}

test "formats are found by name, with a demuxer or a muxer" {
    try std.testing.expectEqual(Container.aiff, findDemuxer("aiff"));
    try std.testing.expectEqual(Container.w64, findMuxer("w64"));
    try std.testing.expectEqual(Container.mp3, findDemuxer("mp3"));
    try std.testing.expectEqual(null, findDemuxer("ac3"));
    try std.testing.expectEqual(null, findMuxer("mp3")); // read only (T29a)
    try std.testing.expectEqual(null, findMuxer("WAV")); // names are exact, as FFmpeg's
    try std.testing.expectEqualStrings("Audio IFF", Container.aiff.format().long_name);
    try std.testing.expectEqualStrings("au", Container.au.name());
}

test "muxers are found by extension without regard to case" {
    try std.testing.expectEqual(Container.aiff, muxerForExtension(".aifc"));
    try std.testing.expectEqual(Container.aiff, muxerForExtension(".AIF"));
    try std.testing.expectEqual(Container.w64, muxerForExtension(".w64"));
    try std.testing.expectEqual(null, muxerForExtension("wav"));
    try std.testing.expectEqual(null, muxerForExtension("."));
    try std.testing.expectEqual(null, muxerForExtension(".mp3"));
}

test "raw formats are named as their codecs, have no probe, and carry only their codec" {
    try std.testing.expectEqual(pcm.Codec.alaw, Container.alaw.rawCodec());
    try std.testing.expectEqual(null, Container.aiff.rawCodec());
    try std.testing.expectEqual(Container.Family.raw, Container.u8.family());
    try std.testing.expectEqual(Container.Family.wav, Container.w64.family());
    try std.testing.expectEqual(Container.mulaw, findDemuxer("mulaw"));
    try std.testing.expectEqual(null, findDemuxer("s64le")); // FFmpeg has none
    try std.testing.expect(Container.s24be.carries(.s24be) and !Container.s24be.carries(.s24le));
    try std.testing.expect(Container.f32le.defaultCodec().?.eql(.{ .pcm = .f32le }));
    try std.testing.expectEqual(null, Container.alaw.format().demuxer.?.probe); // `alaw` has a demuxer
    try std.testing.expectEqual(Container.alaw, muxerForExtension(".AL"));
    const native: Container = if (native_endian == .little) .s16le else .s16be;
    try std.testing.expectEqual(native, muxerForExtension(".sw"));
}

test "extensions match as FFmpeg's av_match_ext does" {
    try std.testing.expect(matchesExtension("take.al", &.{"al"}));
    try std.testing.expect(matchesExtension("dir.x" ++ std.fs.path.sep_str ++ "TAKE.AL", &.{ "ul", "al" }));
    try std.testing.expect(!matchesExtension("take.al.wav", &.{"al"}));
    try std.testing.expect(!matchesExtension("al", &.{"al"}));
    try std.testing.expect(!matchesExtension("take.", &.{"al"}));
    // A name that is only a dot and the extension, alone or after a
    // directory, still has it.
    try std.testing.expect(matchesExtension(".ogg", &.{"ogg"}));
    try std.testing.expect(matchesExtension("dir" ++ std.fs.path.sep_str ++ ".OGG", &.{"ogg"}));
    // The last dot of the whole name, a directory's included.
    try std.testing.expect(!matchesExtension("dir.ogg" ++ std.fs.path.sep_str ++ "take", &.{"ogg"}));
    try std.testing.expect(!matchesExtension("take.ogg" ++ std.fs.path.sep_str, &.{"ogg"}));
    try std.testing.expectEqual(Container.au, muxerForFileName(".au"));
    try std.testing.expectEqual(Container.aiff, muxerForFileName("dir" ++ std.fs.path.sep_str ++ "take.AIFC"));
    try std.testing.expectEqual(null, muxerForFileName("take.mp3"));
    try std.testing.expectEqual(null, muxerForFileName("take"));
}

test "the default codecs are FFmpeg's and each muxer carries them" {
    try std.testing.expect(Container.wav.defaultCodec().?.eql(.{ .pcm = .s16le }));
    try std.testing.expect(Container.w64.defaultCodec().?.eql(.{ .pcm = .s16le }));
    try std.testing.expect(Container.au.defaultCodec().?.eql(.{ .pcm = .s16be }));
    try std.testing.expect(Container.aiff.defaultCodec().?.eql(.{ .pcm = .s16be }));
    try std.testing.expect(Container.aiff.carries(.s16le) and !Container.au.carries(.s16le));
    // FLAC carries FLAC only (T26c); no PCM muxer carries it.
    try std.testing.expect(Container.flac.defaultCodec().?.eql(.flac));
    try std.testing.expect(Container.flac.carriesCodec(.flac) and !Container.flac.carries(.s16le));
    try std.testing.expect(!Container.wav.carriesCodec(.flac));
    try std.testing.expectEqual(Container.flac, muxerForExtension(".flac"));
}
