// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! The WAV fixture contract (TODO.md T02), the AU fixture contract (T12a),
//! the AIFF fixture contract (T22b), the raw PCM contract (T22c), the CAF
//! contract (T22d) and the FLAC contract (T26a) as typed test data.
//!
//! `all` is imported at compile time from fixtures/manifest.zon, `au.all` from
//! fixtures/au/manifest.zon, `aiff.all`, `raw.all` and `caf.all` from the
//! manifests in fixtures/aiff, fixtures/raw, fixtures/caf and fixtures/flac;
//! fixtures/generate.py writes them. `bytes`, `au.bytes` and `aiff.bytes`
//! embed a fixture file, so a missing file fails the build. The rules,
//! decisions and error precedence are documented in fixtures/README.md,
//! fixtures/au/README.md and fixtures/aiff/README.md.

const std = @import("std");
const channel_layout = @import("../core/channel_layout.zig");

/// Errors of the first WAV contract (port.md), named exactly as the parser's
/// errors. This enum stays independent of the parser; the WAV tests map each
/// tag to the expected error value with an exhaustive switch.
pub const Failure = enum {
    InvalidRiff,
    InvalidWave,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
};

/// The encodings the contracts accept, by FFmpeg codec name. Independent of
/// `pcm.Codec`, so the manifests never depend on the implementation.
pub const Codec = enum {
    pcm_u8,
    pcm_s8,
    pcm_s16le,
    pcm_s16be,
    pcm_s24le,
    pcm_s24be,
    pcm_s32le,
    pcm_s32be,
    pcm_s64le,
    pcm_s64be,
    pcm_f32le,
    pcm_f32be,
    pcm_f64le,
    pcm_f64be,
    pcm_alaw,
    pcm_mulaw,
};

/// Decoded samples as FFmpeg stores them, tagged by sample format: integers by
/// value, floats as their IEEE bit patterns, interleaved.
pub const Samples = union(enum) {
    u8: []const u8,
    s16: []const i16,
    s32: []const i32,
    s64: []const i64,
    flt: []const u32,
    dbl: []const u64,

    pub fn len(samples: Samples) usize {
        return switch (samples) {
            inline else => |values| values.len,
        };
    }

    /// The samples serialized little-endian into the start of `out`, as
    /// FFmpeg's `pcm_<storage>le` writes them; `out` must be large enough.
    pub fn littleEndian(samples: Samples, out: []u8) []const u8 {
        switch (samples) {
            inline else => |values| {
                const T = @typeInfo(@TypeOf(values)).pointer.child;
                for (values, 0..) |value, i| std.mem.writeInt(T, out[i * @sizeOf(T) ..][0..@sizeOf(T)], value, .little);
                return out[0 .. values.len * @sizeOf(T)];
            },
        }
    }
};

/// A stream the parser must accept.
pub const Stream = struct {
    codec: Codec,
    channels: u16,
    /// The channel layout as ffprobe prints it (T23b): FFmpeg's
    /// description, or `unknown` when the container leaves it unspecified.
    layout: []const u8,
    sample_rate: u32,
    samples: Samples,

    pub fn frameCount(stream: Stream) usize {
        return stream.samples.len() / stream.channels;
    }

    /// The stream's layout as a value: unspecified for `unknown`, else what
    /// FFmpeg parses its description as.
    pub fn channelLayout(stream: Stream) channel_layout.Layout {
        if (std.mem.eql(u8, stream.layout, "unknown")) return .{ .unspecified = stream.channels };
        // generate.py writes FFmpeg's descriptions, which FFmpeg parses back.
        return channel_layout.Layout.parse(stream.layout) catch unreachable;
    }

    /// Checks that `layout` is the stream's, as ffprobe would print it.
    pub fn expectLayout(stream: Stream, layout: channel_layout.Layout) !void {
        var buffer: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        switch (layout) {
            .unspecified => try w.writeAll("unknown"),
            .native, .custom => try layout.describe(&w),
        }
        try std.testing.expectEqualStrings(stream.layout, w.buffered());
        try std.testing.expectEqual(stream.channels, layout.channelCount());
    }
};

pub const Expected = union(enum) {
    accept: Stream,
    reject: Failure,
};

pub const Fixture = struct {
    /// The file is fixtures/wav/<name>.wav.
    name: []const u8,
    /// Lowercase hexadecimal SHA-256 of the file.
    sha256: []const u8,
    expected: Expected,
    /// The format FFmpeg's content probing picks for the file, or null for
    /// none (T16); detection must agree before any parser runs.
    detected: ?Container,
    /// The writer (T08) must produce exactly these bytes from `expected.accept`.
    writer_output: bool = false,
    /// ... with this header (T21b): RIFF is the default; RF64 is written
    /// with `rf64 = .always`.
    writer_header: WriterHeader = .riff,
    /// The result with the parser's `unknown_length` option (T21b), where it
    /// differs from `expected`.
    unknown_length: ?Expected = null,
    /// The tags an accepted stream reports (T21c), under FFmpeg's names and
    /// in its order, written by hand from the fixture's chunks.
    tags: []const Tag = &.{},
    /// For writer output: the tags given to the writer, when not `tags`
    /// (the `bext` names, which reading renames).
    writer_tags: ?[]const Tag = null,
    /// For writer output: written with the `bext` option.
    writer_bext: bool = false,

    /// The expected result with the `unknown_length` option off or on.
    pub fn result(fixture: Fixture, unknown_length: bool) Expected {
        if (unknown_length) return fixture.unknown_length orelse fixture.expected;
        return fixture.expected;
    }

    /// Writer output with the writer's default options: plain RIFF, no tags.
    pub fn plainWriterOutput(fixture: Fixture) bool {
        return fixture.writer_output and fixture.writer_header == .riff and fixture.untagged();
    }

    /// Written, or read, without tags.
    pub fn untagged(fixture: Fixture) bool {
        return fixture.tags.len == 0 and fixture.writer_tags == null and !fixture.writer_bext;
    }
};

pub const WriterHeader = enum { riff, rf64, w64 };

/// The formats content probing can choose (T16), by FFmpeg's names.
pub const Container = enum { wav, w64, au, aiff, caf, flac, mp3 };

/// One tag as bytes: values may hold any byte but NUL.
pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

pub const all: []const Fixture = @import("fixtures/manifest.zon");

/// The bytes of fixtures/wav/<name>.wav, embedded at compile time.
pub fn bytes(comptime name: []const u8) []const u8 {
    return @embedFile("fixtures/wav/" ++ name ++ ".wav");
}

/// The AU contract (port.md "AU contract"): known-length Sun AU with signed
/// 16-bit big-endian PCM. It shares `Stream` with the WAV contract.
pub const au = struct {
    // Inside this namespace the WAV contract's `Failure`, `Expected`, `Fixture`
    // and `all` are also in scope, so references to the AU ones are qualified.
    const Au = @This();

    /// Errors of the AU contract, named exactly as the AU parser's errors.
    pub const Failure = enum {
        InvalidAu,
        InvalidFormat,
        Truncated,
        UnsupportedFormat,
        UnsupportedStreamingSize,
        LimitExceeded,
    };

    pub const Expected = union(enum) {
        accept: Stream,
        reject: Au.Failure,
    };

    pub const Fixture = struct {
        /// The file is fixtures/au/<name>.au.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Au.Expected,
        /// The format FFmpeg's content probing picks, or null for none (T16).
        detected: ?Container,
        /// The AU writer (T12b) must produce exactly these bytes from `expected.accept`.
        writer_output: bool = false,
        /// The result with the parser's `unknown_length` option (T22a), where
        /// it differs from `expected`.
        unknown_length: ?Au.Expected = null,

        /// The expected result with the `unknown_length` option off or on.
        pub fn result(fixture: Au.Fixture, unknown_length: bool) Au.Expected {
            if (unknown_length) return fixture.unknown_length orelse fixture.expected;
            return fixture.expected;
        }
    };

    pub const all: []const Au.Fixture = @import("fixtures/au/manifest.zon");

    /// The bytes of fixtures/au/<name>.au, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/au/" ++ name ++ ".au");
    }
};

/// The AIFF contract (port.md "AIFF contract"): known-length AIFF and AIFF-C
/// with the PCM encodings of FFmpeg's AIFF table. It shares `Stream` with the
/// WAV contract.
pub const aiff = struct {
    // As in `au`, the WAV contract's names are in scope here too.
    const Aiff = @This();

    /// Errors of the AIFF contract, named exactly as the AIFF parser's errors.
    pub const Failure = enum {
        InvalidAiff,
        InvalidFormat,
        Truncated,
        UnsupportedFormat,
        LimitExceeded,
    };

    pub const Expected = union(enum) {
        accept: Stream,
        reject: Aiff.Failure,
    };

    pub const Fixture = struct {
        /// The file is fixtures/aiff/<name>.aiff.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Aiff.Expected,
        /// The format FFmpeg's content probing picks, or null for none (T16).
        detected: ?Container,
        /// The AIFF writer must produce exactly these bytes from `expected.accept`.
        writer_output: bool = false,
    };

    pub const all: []const Aiff.Fixture = @import("fixtures/aiff/manifest.zon");

    /// The bytes of fixtures/aiff/<name>.aiff, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/aiff/" ++ name ++ ".aiff");
    }
};

/// The raw PCM contract (port.md "Raw PCM contract"): header-less samples
/// read with the parameters each fixture records. It shares `Stream` with the
/// WAV contract.
pub const raw = struct {
    const Raw = @This();

    /// Errors of the raw PCM contract, named exactly as the raw parser's errors.
    pub const Failure = enum {
        InvalidFormat,
        Truncated,
        LimitExceeded,
    };

    pub const Expected = union(enum) {
        accept: Stream,
        reject: Raw.Failure,
    };

    /// FFmpeg's raw PCM formats, named as their codecs without `pcm_`.
    pub const Format = enum { u8, s8, s16le, s16be, s24le, s24be, s32le, s32be, f32le, f32be, f64le, f64be, alaw, mulaw };

    /// The stream parameters a fixture is read with (`-sample_rate`,
    /// `-ch_layout`): the channel count and the layout text.
    pub const Params = struct {
        sample_rate: u32,
        channels: u16,
        /// FFmpeg's `-ch_layout` text, which `channel_layout.Layout.parse` reads.
        layout: []const u8,
    };

    pub const Fixture = struct {
        /// The file is fixtures/raw/<name>.raw.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Raw.Expected,
        /// Content detection: always null, since no probe recognizes raw PCM
        /// and `.raw` is no raw format's extension.
        detected: ?Container,
        format: Format,
        /// Null: FFmpeg's defaults, 44100 Hz mono.
        params: ?Params,
        /// The raw writer, given the accepted stream, must produce exactly
        /// these bytes.
        writer_output: bool = false,
    };

    pub const all: []const Raw.Fixture = @import("fixtures/raw/manifest.zon");

    /// The bytes of fixtures/raw/<name>.raw, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/raw/" ++ name ++ ".raw");
    }
};

/// The CAF contract (port.md "CAF contract"): linear PCM, A-law and µ-law in
/// Core Audio Format, read only. It shares `Stream` with the WAV contract.
pub const caf = struct {
    const Caf = @This();

    /// Errors of the CAF contract, named exactly as the CAF parser's errors.
    pub const Failure = enum {
        InvalidCaf,
        InvalidFormat,
        Truncated,
        UnsupportedFormat,
        UnsupportedStreamingSize,
        LimitExceeded,
    };

    pub const Expected = union(enum) {
        accept: Stream,
        reject: Caf.Failure,
    };

    pub const Fixture = struct {
        /// The file is fixtures/caf/<name>.caf.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Caf.Expected,
        /// The format FFmpeg's content probing picks, or null for none (T16).
        detected: ?Container,
        /// The result with the parser's `unknown_length` option, where it
        /// differs from `expected`.
        unknown_length: ?Caf.Expected = null,

        /// The expected result with the `unknown_length` option off or on.
        pub fn result(fixture: Caf.Fixture, unknown_length: bool) Caf.Expected {
            if (unknown_length) return fixture.unknown_length orelse fixture.expected;
            return fixture.expected;
        }
    };

    pub const all: []const Caf.Fixture = @import("fixtures/caf/manifest.zon");

    /// The bytes of fixtures/caf/<name>.caf, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/caf/" ++ name ++ ".caf");
    }
};

/// The FLAC contract (port.md "FLAC contract"): native FLAC with 16-bit
/// samples, read only. Decoded samples are recorded by their hash; the
/// stream, packets and frames FFmpeg gives are in vectors/flac.txt.
pub const flac = struct {
    const Flac = @This();

    /// Errors of the FLAC contract, named exactly as the FLAC demuxer's.
    pub const Failure = enum {
        InvalidFlac,
        Truncated,
        UnsupportedFormat,
    };

    pub const Stream = struct {
        channels: u8,
        sample_rate: u32,
        /// Samples per channel the decoder gives.
        frames: u64,
        /// Lowercase hexadecimal SHA-256 of the decoded samples, interleaved
        /// little-endian: s16 for at most 16 bits per sample, else s32,
        /// each shifted to the top of its storage, FFmpeg's output.
        pcm_sha256: []const u8,
        /// STREAMINFO's bits per sample.
        bps: u8 = 16,
    };

    /// STREAMINFO's MD5 against the decoded samples (T26b).
    pub const Md5 = enum { match, mismatch };

    pub const Expected = union(enum) {
        accept: Flac.Stream,
        reject: Flac.Failure,
        /// Damaged input: only FFmpeg's result (vectors/flac.txt) defines it.
        damaged,
    };

    pub const MadeBy = enum {
        /// fixtures/generate.py writes the file.
        generate,
        /// reference/flac_fixtures.sh made it with FFmpeg's encoder; it is
        /// committed and generate.py checks its hash.
        ffmpeg,
    };

    pub const Fixture = struct {
        /// The file is fixtures/flac/<name>.flac.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        made_by: MadeBy,
        /// The format FFmpeg's content probing picks, or null for none (T16).
        detected: ?Container,
        expected: Flac.Expected,
        /// Null when STREAMINFO has no MD5.
        md5: ?Flac.Md5 = null,
        /// The format tags ffprobe reports, in order (VORBIS_COMMENT).
        tags: []const Tag = &.{},
    };

    pub const all: []const Flac.Fixture = @import("fixtures/flac/manifest.zon");

    /// The bytes of fixtures/flac/<name>.flac, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/flac/" ++ name ++ ".flac");
    }
};

pub const ogg = struct {
    const Ogg = @This();

    /// Whether FFmpeg opens the fixture; what it makes of each one opened
    /// is vectors/ogg.txt (T27a).
    pub const Expected = enum { accept, reject };

    pub const Fixture = struct {
        /// The file is fixtures/ogg/<name>.ogg.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Ogg.Expected,
    };

    pub const all: []const Ogg.Fixture = @import("fixtures/ogg/manifest.zon");

    /// The bytes of fixtures/ogg/<name>.ogg, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/ogg/" ++ name ++ ".ogg");
    }
};

pub const mp3 = struct {
    const Mp3 = @This();

    /// Whether FFmpeg opens the fixture; what it makes of each one opened
    /// is vectors/mp3.txt (T29a).
    pub const Expected = enum { accept, reject };

    pub const Fixture = struct {
        /// The file is fixtures/mp3/<name>.mp3.
        name: []const u8,
        /// Lowercase hexadecimal SHA-256 of the file.
        sha256: []const u8,
        expected: Mp3.Expected,
    };

    pub const all: []const Mp3.Fixture = @import("fixtures/mp3/manifest.zon");

    /// The bytes of fixtures/mp3/<name>.mp3, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/mp3/" ++ name ++ ".mp3");
    }
};

/// This file's own declarations: the WAV contract's `all` and `bytes`.
const wav_contract = @This();

/// Compile-time checks of one contract's manifest: `Contract` has `all`.
fn expectConsistent(comptime Contract: type) void {
    @setEvalBranchQuota(200_000);
    for (Contract.all, 0..) |fixture, i| {
        for (Contract.all[i + 1 ..]) |other| {
            if (std.mem.eql(u8, fixture.name, other.name)) {
                @compileError("duplicate fixture name: " ++ fixture.name);
            }
        }
        // Ogg's and MP3's expectation is a plain accept or reject: what an
        // accepted file holds is its C oracle vector's (vectors/ogg.txt, mp3.txt).
        if (@typeInfo(@TypeOf(fixture.expected)) == .@"union") expectValidResult(fixture.name, fixture.expected);
        if (@hasField(@TypeOf(fixture), "writer_output") and fixture.expected == .reject and fixture.writer_output) {
            @compileError("only accepted fixtures can be writer output: " ++ fixture.name);
        }
        if (@hasField(@TypeOf(fixture), "writer_header")) {
            if (fixture.writer_header != .riff and !fixture.writer_output) {
                @compileError("a writer header needs writer output: " ++ fixture.name);
            }
            if (fixture.tags.len > 0 and fixture.expected != .accept) {
                @compileError("only accepted fixtures report tags: " ++ fixture.name);
            }
        }
        if (@hasField(@TypeOf(fixture), "unknown_length")) {
            if (fixture.unknown_length) |unknown| {
                expectValidResult(fixture.name, unknown);
                // The option only changes what the unknown-size sentinels do.
                if (fixture.expected != .reject or fixture.expected.reject != .UnsupportedStreamingSize) {
                    @compileError("only UnsupportedStreamingSize changes with unknown_length: " ++ fixture.name);
                }
            }
        }
    }
}

fn expectValidResult(comptime name: []const u8, comptime result: anytype) void {
    switch (result) {
        .accept => |stream| {
            if (stream.channels == 0) {
                @compileError("accepted fixtures have channels: " ++ name);
            }
            if (@TypeOf(stream) == flac.Stream) return;
            if (stream.samples.len() % stream.channels != 0) {
                @compileError("samples do not fill whole frames: " ++ name);
            }
        },
        // Rejections, and FLAC's damaged input, which FFmpeg's result defines.
        else => {},
    }
}

/// Checks that every file of one contract (`Contract` has `all` and `bytes`)
/// matches the SHA-256 its manifest records.
fn expectHashes(comptime Contract: type) !void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    inline for (Contract.all) |fixture| {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(Contract.bytes(fixture.name), &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(fixture.sha256, &actual) catch |err| {
            std.debug.print("fixture {s}: the manifest SHA-256 differs from the file's\n", .{fixture.name});
            return err;
        };
    }
}

test "manifest names are unique and expectations are consistent" {
    comptime {
        @setEvalBranchQuota(200_000);
        expectConsistent(wav_contract);
        expectConsistent(au);
        expectConsistent(aiff);
        expectConsistent(raw);
        expectConsistent(caf);
        expectConsistent(flac);
        expectConsistent(ogg);
        expectConsistent(mp3);
    }
}

test "every fixture file is present and matches its recorded SHA-256" {
    try expectHashes(wav_contract);
    try expectHashes(au);
    try expectHashes(aiff);
    try expectHashes(raw);
    try expectHashes(caf);
    try expectHashes(flac);
    try expectHashes(ogg);
    try expectHashes(mp3);
}

test "fixture names do not collide across contracts" {
    comptime {
        @setEvalBranchQuota(400_000);
        expectDistinct(au, wav_contract);
        expectDistinct(aiff, wav_contract);
        expectDistinct(aiff, au);
        expectDistinct(raw, wav_contract);
        expectDistinct(raw, au);
        expectDistinct(raw, aiff);
        expectDistinct(caf, wav_contract);
        expectDistinct(caf, au);
        expectDistinct(caf, aiff);
        expectDistinct(caf, raw);
        expectDistinct(flac, wav_contract);
        expectDistinct(flac, au);
        expectDistinct(flac, aiff);
        expectDistinct(flac, raw);
        expectDistinct(flac, caf);
        expectDistinct(ogg, wav_contract);
        expectDistinct(ogg, au);
        expectDistinct(ogg, aiff);
        expectDistinct(ogg, raw);
        expectDistinct(ogg, caf);
        expectDistinct(ogg, flac);
        expectDistinct(mp3, wav_contract);
        expectDistinct(mp3, au);
        expectDistinct(mp3, aiff);
        expectDistinct(mp3, raw);
        expectDistinct(mp3, caf);
        expectDistinct(mp3, flac);
        expectDistinct(mp3, ogg);
    }
}

fn expectDistinct(comptime A: type, comptime B: type) void {
    for (A.all) |a| {
        for (B.all) |b| {
            if (std.mem.eql(u8, a.name, b.name)) @compileError("fixture name used by two contracts: " ++ a.name);
        }
    }
}
