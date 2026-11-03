// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/format.c (probe_input_format_internal, av_probe_input_buffer2),
// wavdec.c, au.c and aiffdec.c at the pinned reference revision describe the
// scoring followed here.
//! Format detection (TODO.md T12c, T16): the content probes of the demuxers
//! in the format registry (`registry.zig`), scored as FFmpeg scores them, so
//! each stream gets FFmpeg's winner.
//!
//! `Input.open` reads up to `probe_len` bytes, FFmpeg's first probe size, and
//! asks every demuxer for a score from 0 to 100. The highest nonzero score
//! wins; a tie at the highest means no winner, as in FFmpeg, and a stream no
//! demuxer scores is `UnknownFormat`. The bytes probing read are served again
//! to the chosen parser through a `Replay` reader, so non-seekable input
//! loses nothing and any source buffer size works. A caller can force a
//! format instead (`ffprobe -f`), which skips probing.
//!
//! FFmpeg reads more and probes again while the best score is at most 25
//! (`AVPROBE_SCORE_RETRY`). Every registered probe decides within its first
//! bytes and scores 0, 99 or 100, so that loop could never change a winner;
//! this file checks at compile time that each probe needs no more than
//! `probe_len` bytes. A probe that can score low must add the loop. A demuxer
//! without a probe (a format without a content signature) is never chosen.
//! Extensions and MIME types, only hints in FFmpeg, are not used: none of
//! these demuxers declares one.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const metadata = @import("../core/metadata.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const aiff = @import("aiff.zig");
const registry = @import("registry.zig");
const Replay = @import("replay.zig").Replay;

pub const Container = registry.Container;

/// The WAV, AU and AIFF contract errors, which share their common names, and
/// `UnknownFormat` for a stream no demuxer recognizes.
pub const Error = wav.Error || au.Error || aiff.Error || error{
    /// No demuxer's probe scored the stream, as FFmpeg's "Invalid data found
    /// when processing input"; force a format to parse it anyway.
    UnknownFormat,
};

pub const Limits = struct {
    wav: wav.Limits = .{},
    au: au.Limits = .{},
    aiff: aiff.Limits = .{},
};

/// FFmpeg's first probe size (`PROBE_BUF_MIN`).
pub const probe_len = 2048;

/// `AVPROBE_SCORE_MAX`.
const max_score = 100;

comptime {
    for (registry.formats) |format| {
        const demuxer = format.demuxer orelse continue;
        if (demuxer.probe_bytes > probe_len) @compileError("a probe reads past the probe buffer: " ++ format.name);
    }
}

/// FFmpeg's winner for `head`, the first bytes of a stream: the demuxer with
/// the highest nonzero score, or none when no demuxer scores or the highest
/// score is tied.
pub fn probeHead(head: []const u8) ?Container {
    return winner(&registry.formats, head[0..@min(head.len, probe_len)]);
}

/// The winner among `formats`. FFmpeg's order only matters for ties, which
/// mean no winner whatever the order.
fn winner(formats: []const registry.Format, head: []const u8) ?Container {
    var best: u8 = 0;
    var chosen: ?Container = null;
    for (formats) |format| {
        const demuxer = format.demuxer orelse continue;
        const score_head = demuxer.probe orelse continue;
        const score = score_head(head);
        std.debug.assert(score <= max_score);
        if (score > best) {
            best = score;
            chosen = format.container;
        } else if (score == best) {
            chosen = null;
        }
    }
    return chosen;
}

/// A stream opened for parsing: its format, and a reader that replays the
/// bytes probing read before the rest of the source.
pub const Input = struct {
    head_buffer: [probe_len]u8,
    replay: Replay,
    container: Container,
    /// The container came from the caller, not from probing.
    forced: bool,

    /// Probes `source`, or with `format` takes it without reading anything.
    /// Fills `input` in place; it must not move afterward, because `reader`
    /// points into it. Only a failing source, or a stream no demuxer
    /// recognizes, is an error.
    pub fn open(input: *Input, source: *std.Io.Reader, format: ?Container) error{ IoFailure, UnknownFormat }!void {
        if (format) |container| {
            input.* = .{ .head_buffer = undefined, .replay = .init(&.{}, source), .container = container, .forced = true };
            return;
        }
        const len = source.readSliceShort(&input.head_buffer) catch return error.IoFailure;
        input.replay = .init(input.head_buffer[0..len], source);
        input.container = probeHead(input.head_buffer[0..len]) orelse return error.UnknownFormat;
        input.forced = false;
    }

    pub fn reader(input: *Input) *std.Io.Reader {
        return &input.replay.interface;
    }

    /// A WAV parser for a `wav` or `w64` input, which accepts only that
    /// variant, as FFmpeg's demuxers do when forced.
    pub fn wavParser(input: *Input, limits: wav.Limits) wav.Parser {
        const variant: wav.Variant = switch (input.container) {
            .wav => .wav,
            .w64 => .w64,
            .au, .aiff => unreachable, // the caller dispatches on the container
        };
        return .initVariant(input.reader(), limits, variant);
    }
};

pub const Probed = struct {
    container: Container,
    /// The stream's encoding, as FFmpeg's `codec_name` names it.
    codec: pcm.Codec,
    /// `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in the stream; null for data of unknown length
    /// (`unknown_length`).
    frame_count: ?u64,
};

pub const Options = struct {
    /// Parse as this container instead of probing (`ffprobe -f`).
    format: ?Container = null,
    /// Also add the stream's tags to the empty `tags.dictionary`, under
    /// FFmpeg's names (`wav.genericTags`). Only RIFF and RF64 streams carry
    /// tags so far. On failure the dictionary may hold some of them.
    tags: ?wav.Tags = null,
};

/// Detects the container, then validates the whole stream without decoding
/// its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Probed {
    return probeWith(reader, limits, .{});
}

/// `probe`, with a forced format or tags.
pub fn probeWith(reader: *std.Io.Reader, limits: Limits, options: Options) Error!Probed {
    var input: Input = undefined;
    try input.open(reader, options.format);
    switch (input.container) {
        .wav, .w64 => {
            var parser = input.wavParser(limits.wav);
            var stored: metadata.Dictionary = .empty;
            defer if (options.tags) |t| stored.deinit(t.gpa);
            if (options.tags) |t| {
                std.debug.assert(t.dictionary.count() == 0);
                parser.collectTags(.{ .gpa = t.gpa, .dictionary = &stored });
            }
            const info = try parser.readHeader();
            try parser.finish();
            if (options.tags) |t| {
                const generic = try wav.genericTags(t.gpa, &stored);
                t.dictionary.deinit(t.gpa);
                t.dictionary.* = generic;
            }
            std.debug.assert(Container.ofWav(info.variant) == input.container);
            return .{ .container = input.container, .codec = info.codec, .format = info.format, .frame_count = info.frame_count };
        },
        .au => {
            var parser: au.Parser = .init(input.reader(), limits.au);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .au, .codec = info.codec, .format = info.format, .frame_count = info.frame_count };
        },
        .aiff => {
            var parser: aiff.Parser = .init(input.reader(), limits.aiff);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .aiff, .codec = info.codec, .format = info.format, .frame_count = info.frame_count };
        },
    }
}

const fixtures = @import("../testing/fixtures.zig");

/// The implementation's container for a manifest's.
fn containerOf(comptime container: fixtures.Container) Container {
    return comptime std.meta.stringToEnum(Container, @tagName(container)).?;
}

/// Compares a probe through detection with one container parser's own probe.
fn expectSameResult(expected: anytype, got: Error!Probed, container: Container) !void {
    if (expected) |info| {
        const probed = try got;
        try std.testing.expectEqual(container, probed.container);
        try std.testing.expectEqual(info.format, probed.format);
        try std.testing.expectEqual(info.frame_count, probed.frame_count);
    } else |want| {
        try std.testing.expectError(want, got);
    }
}

/// Probes one fixture through detection from one-byte reads: a fixture the
/// manifest records as undetected is `UnknownFormat`; any other gives its
/// container's parser result, and forcing that container gives the same.
fn expectDetection(comptime detected: ?fixtures.Container, bytes: []const u8, direct: anytype) !void {
    var buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    source.artificial_limit = .limited(1);
    const got = probe(&source.interface, .{});
    if (detected == null) return std.testing.expectError(error.UnknownFormat, got);
    // Not null: checked just above.
    const container = comptime containerOf(detected.?);
    try expectSameResult(direct, got, container);
    var forced: std.Io.Reader = .fixed(bytes);
    try expectSameResult(direct, probeWith(&forced, .{}, .{ .format = container }), container);
}

test "detection gives every WAV fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.all) |fixture| {
        const bytes = fixtures.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, wav.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "detection gives every AU fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.au.all) |fixture| {
        const bytes = fixtures.au.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, au.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "detection gives every AIFF fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.aiff.all) |fixture| {
        const bytes = fixtures.aiff.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, aiff.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "the probes need FFmpeg's minimum lengths and nonzero AU fields" {
    // A 33-byte RIFF/WAVE start is detected, 32 bytes are not.
    const wav_head = fixtures.bytes("mono_8k");
    try std.testing.expectEqual(Container.wav, probeHead(wav_head[0..33]));
    try std.testing.expectEqual(null, probeHead(wav_head[0..32]));
    // RF64 needs `ds64` at 12.
    var rf64 = fixtures.bytes("rf64")[0..40].*;
    try std.testing.expectEqual(Container.wav, probeHead(&rf64));
    rf64[12] = 'x';
    try std.testing.expectEqual(null, probeHead(&rf64));
    // Wave64: 41 bytes, not 40.
    const w64_head = fixtures.bytes("w64_mono_8k");
    try std.testing.expectEqual(Container.w64, probeHead(w64_head[0..41]));
    try std.testing.expectEqual(null, probeHead(w64_head[0..40]));
    // AU: 24 bytes; a zero data size is not detected.
    try std.testing.expectEqual(Container.au, probeHead(fixtures.au.bytes("au_mono_8k")[0..24]));
    try std.testing.expectEqual(null, probeHead(fixtures.au.bytes("au_mono_8k")[0..23]));
    try std.testing.expectEqual(null, probeHead(fixtures.au.bytes("au_empty_data")));
    // AIFF: 12 bytes, a FORM size of at least 4, and AIFF or AIFC.
    var aiff_head = fixtures.aiff.bytes("aifc_sowt")[0..12].*;
    try std.testing.expectEqual(Container.aiff, probeHead(&aiff_head));
    try std.testing.expectEqual(null, probeHead(aiff_head[0..11]));
    std.mem.writeInt(u32, aiff_head[4..8], 3, .big);
    try std.testing.expectEqual(null, probeHead(&aiff_head));
    try std.testing.expectEqual(null, probeHead(""));
}

fn alwaysProbe(head: []const u8) u8 {
    _ = head;
    return max_score;
}

test "a demuxer without a probe is never chosen, and a tie chooses none" {
    const head = fixtures.bytes("mono_8k");
    // A probe-less demuxer (raw PCM, T22c, will be one) next to WAV.
    const raw: registry.Format = .{
        .container = .au,
        .name = "raw",
        .long_name = "raw",
        .demuxer = .{ .probe = null, .probe_bytes = 0 },
        .muxer = null,
    };
    try std.testing.expectEqual(null, winner(&.{raw}, head));
    try std.testing.expectEqual(Container.wav, winner(&.{ raw, Container.wav.format().* }, head));
    // Two demuxers scoring 100 for the same bytes tie: no winner.
    const always: registry.Demuxer = .{ .probe = alwaysProbe, .probe_bytes = 0 };
    var both = [2]registry.Format{ Container.wav.format().*, Container.aiff.format().* };
    both[0].demuxer = always;
    both[1].demuxer = always;
    try std.testing.expectEqual(null, winner(&both, head));
}

test "a forced format parses what probing would not detect, and only that format" {
    var empty_au: std.Io.Reader = .fixed(fixtures.au.bytes("au_empty_data"));
    try std.testing.expectError(error.UnknownFormat, probe(&empty_au, .{}));
    var forced_au: std.Io.Reader = .fixed(fixtures.au.bytes("au_empty_data"));
    try std.testing.expectEqual(0, (try probeWith(&forced_au, .{}, .{ .format = .au })).frame_count);
    // Forced WAV rejects Wave64, and the other way round, as FFmpeg's demuxers do.
    var w64_as_wav: std.Io.Reader = .fixed(fixtures.bytes("w64_mono_8k"));
    try std.testing.expectError(error.InvalidRiff, probeWith(&w64_as_wav, .{}, .{ .format = .wav }));
    var wav_as_w64: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.InvalidRiff, probeWith(&wav_as_w64, .{}, .{ .format = .w64 }));
    var wav_as_au: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.InvalidAu, probeWith(&wav_as_au, .{}, .{ .format = .au }));
    var au_as_aiff: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_8k"));
    try std.testing.expectError(error.InvalidAiff, probeWith(&au_as_aiff, .{}, .{ .format = .aiff }));
    var small_form: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_form_size_small"));
    try std.testing.expectError(error.UnknownFormat, probe(&small_form, .{}));
}

test "detection reports the container and passes limits to its parser" {
    var mono: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_8k"));
    const probed = try probe(&mono, .{});
    try std.testing.expectEqual(Container.au, probed.container);
    try std.testing.expectEqualStrings("pcm_s16be", probed.codec.name());
    var fast: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&fast, .{ .au = .{ .max_sample_rate = 191_999 } }));
    var wav_fast: std.Io.Reader = .fixed(fixtures.bytes("mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&wav_fast, .{ .wav = .{ .max_sample_rate = 191_999 } }));
    var wave64: std.Io.Reader = .fixed(fixtures.bytes("w64_mono_8k"));
    try std.testing.expectEqual(Container.w64, (try probe(&wave64, .{})).container);
    var aifc: std.Io.Reader = .fixed(fixtures.aiff.bytes("aifc_fl32"));
    const probed_aifc = try probe(&aifc, .{});
    try std.testing.expectEqual(Container.aiff, probed_aifc.container);
    try std.testing.expectEqualStrings("pcm_f32be", probed_aifc.codec.name());
    var aiff_fast: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_mono_8k"));
    try std.testing.expectError(error.LimitExceeded, probe(&aiff_fast, .{ .aiff = .{ .max_sample_rate = 7999 } }));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    const bytes = input[0..len];
    var detected: std.Io.Reader = .fixed(bytes);
    const got = probe(&detected, .{});
    // Replaying the probed bytes loses none: detection agrees with the
    // chosen parser reading the same input directly.
    var direct: std.Io.Reader = .fixed(bytes);
    if (probeHead(bytes)) |container| switch (container) {
        .au => try expectSameResult(au.probe(&direct, .{}), got, .au),
        .aiff => try expectSameResult(aiff.probe(&direct, .{}), got, .aiff),
        .wav, .w64 => try expectSameResult(wav.probe(&direct, .{}), got, container),
    } else try std.testing.expectError(error.UnknownFormat, got);
}

test "fuzz: detection agrees with the direct parser on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.au.bytes("au_mono_8k"),
        fixtures.au.bytes("au_annotation_odd_length"),
        fixtures.bytes("w64_alaw_mono_8k"),
        fixtures.bytes("rf64"),
        fixtures.aiff.bytes("aifc_sowt"),
        fixtures.aiff.bytes("aiff_other_chunks"),
    } });
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
