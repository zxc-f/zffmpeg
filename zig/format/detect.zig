// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Content detection for the supported containers, WAV and AU (TODO.md T12c).
//!
//! `detect` reads at most `prefix.max_len` bytes and hands them back to the
//! chosen parser, so non-seekable input loses nothing and any reader buffer
//! size works. A stream that starts with AU's `.snd` magic is AU. Anything
//! else, including input shorter than 4 bytes, goes to the WAV parser, whose
//! results and errors stay exactly as before: an unrecognized stream reports
//! `InvalidRiff`. Detection and parser acceptance are separate: the AU parser
//! rejects a wrong magic as `InvalidAu`, but detection never routes such a
//! stream to it. Scored probing over a longer prefix replaces this when a
//! third format lands (TODO.md T16).

const std = @import("std");
const audio = @import("../core/audio.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const prefix = @import("prefix.zig");

pub const Container = enum {
    wav,
    au,

    /// The container name in probe output, as FFmpeg's `format_name`.
    pub fn name(container: Container) []const u8 {
        return @tagName(container);
    }

    /// The codec of the supported subset, as FFmpeg's `codec_name`.
    pub fn codecName(container: Container) []const u8 {
        return switch (container) {
            .wav => "pcm_s16le",
            .au => "pcm_s16be",
        };
    }
};

/// The WAV and AU contract errors, which share their common names.
pub const Error = wav.Error || au.Error;

pub const Limits = struct {
    wav: wav.Limits = .{},
    au: au.Limits = .{},
};

pub const Detected = struct {
    container: Container,
    /// The bytes detection read; the chosen parser reads them first.
    prefix: prefix.Prefix,
};

pub const Probed = struct {
    container: Container,
    format: audio.Format,
    /// Sample frames in the stream.
    frame_count: u64,
};

/// Reads up to `prefix.max_len` bytes and chooses a container. Only a failing
/// reader is an error; a short or empty stream is left to the WAV parser.
pub fn detect(reader: *std.Io.Reader) error{IoFailure}!Detected {
    var bytes: [prefix.max_len]u8 = undefined;
    const len = reader.readSliceShort(&bytes) catch return error.IoFailure;
    const head = bytes[0..len];
    const container: Container = if (std.mem.eql(u8, head, ".snd")) .au else .wav;
    return .{ .container = container, .prefix = .init(head) };
}

/// Detects the container, then validates the whole stream without decoding
/// its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Probed {
    const detected = try detect(reader);
    switch (detected.container) {
        .wav => {
            var parser: wav.Parser = .initPrefixed(reader, limits.wav, detected.prefix);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .wav, .format = info.format, .frame_count = info.frame_count };
        },
        .au => {
            var parser: au.Parser = .initPrefixed(reader, limits.au, detected.prefix);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .au, .format = info.format, .frame_count = info.frame_count };
        },
    }
}

const fixtures = @import("../testing/fixtures.zig");

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

test "detection gives every WAV fixture the WAV parser's result, from one-byte reads" {
    inline for (fixtures.all) |fixture| {
        const bytes = fixtures.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
        source.artificial_limit = .limited(1);
        try expectSameResult(wav.probe(&direct, .{}), probe(&source.interface, .{}), .wav);
    }
}

test "detection gives every AU fixture the AU parser's result, unless its magic is not AU" {
    inline for (fixtures.au.all) |fixture| {
        const bytes = fixtures.au.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
        source.artificial_limit = .limited(1);
        const got = probe(&source.interface, .{});
        if (std.mem.startsWith(u8, bytes, ".snd")) {
            try expectSameResult(au.probe(&direct, .{}), got, .au);
        } else {
            // Not AU by content, so the WAV parser reports it.
            try expectSameResult(wav.probe(&direct, .{}), got, .wav);
        }
    }
}

test "a wrong AU magic is reported by the WAV parser, and a short AU magic is truncated" {
    var bad_magic: std.Io.Reader = .fixed(fixtures.au.bytes("au_bad_magic"));
    try std.testing.expectError(error.InvalidRiff, probe(&bad_magic, .{}));
    var partial_magic: std.Io.Reader = .fixed(".sn");
    try std.testing.expectError(error.Truncated, probe(&partial_magic, .{}));
    var empty: std.Io.Reader = .fixed("");
    try std.testing.expectError(error.Truncated, probe(&empty, .{}));
}

test "detection reports the container and passes limits to its parser" {
    var mono: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_8k"));
    const probed = try probe(&mono, .{});
    try std.testing.expectEqual(Container.au, probed.container);
    try std.testing.expectEqualStrings("pcm_s16be", probed.container.codecName());
    var fast: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&fast, .{ .au = .{ .max_sample_rate = 191_999 } }));
    var wav_fast: std.Io.Reader = .fixed(fixtures.bytes("mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&wav_fast, .{ .wav = .{ .max_sample_rate = 191_999 } }));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    const bytes = input[0..len];
    var direct: std.Io.Reader = .fixed(bytes);
    var detected: std.Io.Reader = .fixed(bytes);
    const got = probe(&detected, .{});
    // Replaying the prefix loses no bytes: detection agrees with the parser
    // that reads the same input directly.
    if (std.mem.startsWith(u8, bytes, ".snd")) {
        try expectSameResult(au.probe(&direct, .{}), got, .au);
    } else {
        try expectSameResult(wav.probe(&direct, .{}), got, .wav);
    }
}

test "fuzz: detection agrees with the direct parser on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.au.bytes("au_mono_8k"),
        fixtures.au.bytes("au_annotation_odd_length"),
        ".sn",
    } });
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
