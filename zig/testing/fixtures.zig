// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! The WAV fixture contract (TODO.md T02) as typed test data.
//!
//! `all` is imported at compile time from fixtures/manifest.zon, which
//! fixtures/generate.py writes. `bytes` embeds a fixture file, so a missing file
//! fails the build. The rules, decisions and error precedence are documented in
//! fixtures/README.md.

const std = @import("std");

/// Errors of the first WAV contract (port.md). The names match the parser's
/// error names exactly so tests can compare them with `@errorName`.
pub const Failure = enum {
    InvalidRiff,
    InvalidWave,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
};

/// A stream the parser must accept.
pub const Stream = struct {
    channels: u16,
    sample_rate: u32,
    /// Interleaved samples; the frame count is `samples.len / channels`.
    samples: []const i16,
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
};

pub const all: []const Fixture = @import("fixtures/manifest.zon");

/// The bytes of fixtures/wav/<name>.wav, embedded at compile time.
pub fn bytes(comptime name: []const u8) []const u8 {
    return @embedFile("fixtures/wav/" ++ name ++ ".wav");
}

test "manifest names are unique and expectations are consistent" {
    comptime {
        @setEvalBranchQuota(100_000);
        for (all, 0..) |fixture, i| {
            for (all[i + 1 ..]) |other| {
                if (std.mem.eql(u8, fixture.name, other.name)) {
                    @compileError("duplicate fixture name: " ++ fixture.name);
                }
            }
            switch (fixture.expected) {
                .accept => |stream| {
                    if (stream.channels != 1 and stream.channels != 2) {
                        @compileError("accepted fixtures are mono or stereo: " ++ fixture.name);
                    }
                    if (stream.samples.len % stream.channels != 0) {
                        @compileError("samples do not fill whole frames: " ++ fixture.name);
                    }
                },
                .reject => if (fixture.writer_output) {
                    @compileError("only accepted fixtures can be writer output: " ++ fixture.name);
                },
            }
        }
    }
}

test "every fixture file is present and matches its recorded SHA-256" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    inline for (all) |fixture| {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes(fixture.name), &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, fixture.sha256, &actual)) {
            std.debug.print("fixture {s}: manifest SHA-256 {s}, file SHA-256 {s}\n", .{
                fixture.name,
                fixture.sha256,
                &actual,
            });
            return error.FixtureHashMismatch;
        }
    }
}
