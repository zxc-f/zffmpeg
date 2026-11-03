// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! The WAV fixture contract (TODO.md T02) and the AU fixture contract (T12a)
//! as typed test data.
//!
//! `all` is imported at compile time from fixtures/manifest.zon, and `au.all`
//! from fixtures/au/manifest.zon; fixtures/generate.py writes both. `bytes` and
//! `au.bytes` embed a fixture file, so a missing file fails the build. The rules,
//! decisions and error precedence are documented in fixtures/README.md and
//! fixtures/au/README.md.

const std = @import("std");

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
    pcm_s16le,
    pcm_s16be,
    pcm_s24le,
    pcm_s32le,
    pcm_s64le,
    pcm_f32le,
    pcm_f64le,
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
    sample_rate: u32,
    samples: Samples,

    pub fn frameCount(stream: Stream) usize {
        return stream.samples.len() / stream.channels;
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
    /// The writer (T08) must produce exactly these bytes from `expected.accept`.
    writer_output: bool = false,
    /// ... with `rf64 = .always` (T21b), rather than the default.
    writer_rf64: bool = false,
    /// The result with the parser's `unknown_length` option (T21b), where it
    /// differs from `expected`.
    unknown_length: ?Expected = null,

    /// The expected result with the `unknown_length` option off or on.
    pub fn result(fixture: Fixture, unknown_length: bool) Expected {
        if (unknown_length) return fixture.unknown_length orelse fixture.expected;
        return fixture.expected;
    }
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
        /// The AU writer (T12b) must produce exactly these bytes from `expected.accept`.
        writer_output: bool = false,
    };

    pub const all: []const Au.Fixture = @import("fixtures/au/manifest.zon");

    /// The bytes of fixtures/au/<name>.au, embedded at compile time.
    pub fn bytes(comptime name: []const u8) []const u8 {
        return @embedFile("fixtures/au/" ++ name ++ ".au");
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
        expectValidResult(fixture.name, fixture.expected);
        if (fixture.expected == .reject and fixture.writer_output) {
            @compileError("only accepted fixtures can be writer output: " ++ fixture.name);
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
            if (stream.channels != 1 and stream.channels != 2) {
                @compileError("accepted fixtures are mono or stereo: " ++ name);
            }
            if (stream.samples.len() % stream.channels != 0) {
                @compileError("samples do not fill whole frames: " ++ name);
            }
        },
        .reject => {},
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
    }
}

test "every fixture file is present and matches its recorded SHA-256" {
    try expectHashes(wav_contract);
    try expectHashes(au);
}

test "AU fixture names do not collide with WAV fixture names" {
    comptime {
        @setEvalBranchQuota(200_000);
        for (au.all) |au_fixture| {
            for (all) |wav_fixture| {
                if (std.mem.eql(u8, au_fixture.name, wav_fixture.name)) {
                    @compileError("fixture name used by both contracts: " ++ au_fixture.name);
                }
            }
        }
    }
}
