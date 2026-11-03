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

/// Checks that every file of one contract (`Contract` has `all` and `bytes`)
/// matches the SHA-256 its manifest records.
fn expectHashes(comptime Contract: type) !void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    inline for (Contract.all) |fixture| {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(Contract.bytes(fixture.name), &digest, .{});
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
