// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// The rounding modes and results follow av_rescale_rnd and av_rescale_q_rnd in
// libavutil/mathematics.c at the pinned reference revision; see port.md.
//! Time bases and timestamp rescaling.
//!
//! A time base is a positive rational number of seconds per tick. Rescaling
//! computes `value * from / to` exactly with 128-bit integers and rounds once,
//! so repeated conversions never accumulate floating-point error. PCM timing
//! uses the sample-rate time base `1/sample_rate`, in which a timestamp is a
//! sample-frame count.
//!
//! A missing timestamp is `null` (`?i64`), never a sentinel value.

const std = @import("std");

pub const TimeBase = struct {
    /// One tick lasts `num / den` seconds. Both must be nonzero: build values
    /// with `init` or `ofSampleRate`; `rescale` rejects zero fields.
    num: u32,
    den: u32,

    pub const Error = error{InvalidTimeBase};

    pub fn init(num: u32, den: u32) Error!TimeBase {
        if (num == 0 or den == 0) return error.InvalidTimeBase;
        return .{ .num = num, .den = den };
    }

    /// The time base whose ticks are sample frames at `sample_rate` Hz.
    pub fn ofSampleRate(sample_rate: u32) Error!TimeBase {
        return init(1, sample_rate);
    }
};

/// How `rescale` rounds a result that is not an exact integer.
pub const Rounding = enum {
    /// Toward zero (FFmpeg `AV_ROUND_ZERO`).
    toward_zero,
    /// Away from zero (`AV_ROUND_INF`).
    away_from_zero,
    /// Toward negative infinity (`AV_ROUND_DOWN`).
    down,
    /// Toward positive infinity (`AV_ROUND_UP`).
    up,
    /// To the nearest integer, halfway cases away from zero
    /// (`AV_ROUND_NEAR_INF`, which `av_rescale_q` uses).
    nearest,
};

pub const RescaleError = error{
    /// A time base has a zero numerator or denominator.
    InvalidTimeBase,
    /// The rounded result does not fit in `i64`.
    Overflow,
};

/// Converts `value` ticks of `from` into ticks of `to`, rounding once.
///
/// Matches FFmpeg's `av_rescale_q_rnd` for every result that fits, with two
/// deliberate differences: overflow is `error.Overflow` rather than INT64_MIN,
/// and `minInt(i64)` is rescaled exactly rather than treated as -INT64_MAX.
pub fn rescale(value: i64, from: TimeBase, to: TimeBase, rounding: Rounding) RescaleError!i64 {
    if (from.num == 0 or from.den == 0 or to.num == 0 or to.den == 0) return error.InvalidTimeBase;
    // |value| <= 2^63 and every factor is below 2^32, so the numerator stays
    // below 2^127 and the denominator below 2^64: neither can overflow i128.
    const wide_value: i128 = value;
    const numerator = wide_value * from.num * to.den;
    const wide_to_num: i128 = to.num;
    const denominator = wide_to_num * from.den;
    return std.math.cast(i64, divide(numerator, denominator, rounding)) orelse error.Overflow;
}

/// Rescales a possibly missing timestamp; a missing timestamp stays missing.
pub fn rescaleTimestamp(timestamp: ?i64, from: TimeBase, to: TimeBase, rounding: Rounding) RescaleError!?i64 {
    const value = timestamp orelse return null;
    return try rescale(value, from, to, rounding);
}

fn divide(numerator: i128, denominator: i128, rounding: Rounding) i128 {
    std.debug.assert(denominator > 0);
    const quotient = @divTrunc(numerator, denominator);
    const remainder = @rem(numerator, denominator);
    if (remainder == 0) return quotient;
    const away: i128 = if (numerator < 0) -1 else 1;
    return switch (rounding) {
        .toward_zero => quotient,
        .away_from_zero => quotient + away,
        .down => if (numerator < 0) quotient - 1 else quotient,
        .up => if (numerator < 0) quotient else quotient + 1,
        .nearest => if (2 * @abs(remainder) >= @abs(denominator)) quotient + away else quotient,
    };
}

const modes = [_]Rounding{ .toward_zero, .away_from_zero, .down, .up, .nearest };

/// Expected results in `modes` order. The vectors were computed with exact
/// rational arithmetic (Python `fractions`) and agree with a transcription of
/// FFmpeg's `av_rescale_rnd` except where noted.
fn expectRescale(value: i64, from: TimeBase, to: TimeBase, expected: [modes.len]i64) !void {
    for (modes, expected) |mode, want| {
        try std.testing.expectEqual(want, try rescale(value, from, to, mode));
    }
}

fn expectOverflow(value: i64, from: TimeBase, to: TimeBase) !void {
    for (modes) |mode| {
        try std.testing.expectError(error.Overflow, rescale(value, from, to, mode));
    }
}

const one: TimeBase = .{ .num = 1, .den = 1 };

test "time bases must have a nonzero numerator and denominator" {
    try std.testing.expectError(error.InvalidTimeBase, TimeBase.init(0, 1));
    try std.testing.expectError(error.InvalidTimeBase, TimeBase.init(1, 0));
    try std.testing.expectError(error.InvalidTimeBase, TimeBase.ofSampleRate(0));
    const cd = try TimeBase.ofSampleRate(44100);
    try std.testing.expectEqual(1, cd.num);
    try std.testing.expectEqual(44100, cd.den);
    try std.testing.expectError(error.InvalidTimeBase, rescale(1, .{ .num = 0, .den = 1 }, one, .nearest));
    try std.testing.expectError(error.InvalidTimeBase, rescale(1, one, .{ .num = 1, .den = 0 }, .nearest));
}

test "rounding modes on positive and negative fractions" {
    const third: TimeBase = .{ .num = 1, .den = 3 };
    const half: TimeBase = .{ .num = 1, .den = 2 };
    // Columns: toward_zero, away_from_zero, down, up, nearest.
    try expectRescale(2, third, one, .{ 0, 1, 0, 1, 1 }); // 2/3
    try expectRescale(-2, third, one, .{ 0, -1, -1, 0, -1 }); // -2/3
    try expectRescale(1, half, one, .{ 0, 1, 0, 1, 1 }); // 1/2: tie goes away from zero
    try expectRescale(-1, half, one, .{ 0, -1, -1, 0, -1 }); // -1/2
    try expectRescale(3, half, one, .{ 1, 2, 1, 2, 2 }); // 3/2
    try expectRescale(-3, half, one, .{ -1, -2, -2, -1, -2 }); // -3/2
}

test "PCM frame counts convert exactly between sample-rate time bases" {
    const rate_8k = try TimeBase.ofSampleRate(8000);
    const rate_44k1 = try TimeBase.ofSampleRate(44100);
    const millisecond: TimeBase = .{ .num = 1, .den = 1000 };
    try expectRescale(8000, rate_8k, rate_44k1, @splat(44100)); // one second
    try expectRescale(44100, rate_44k1, millisecond, @splat(1000));
    try expectRescale(1, rate_44k1, millisecond, .{ 0, 1, 0, 1, 0 }); // 0.0227 ms
}

test "extreme values rescale exactly or report overflow" {
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try expectRescale(max, one, one, @splat(max));
    // FFmpeg treats INT64_MIN as -INT64_MAX here; this rescales it exactly.
    try expectRescale(min, one, one, @splat(min));
    const half: TimeBase = .{ .num = 1, .den = 2 };
    try expectRescale(max, half, one, .{ 4611686018427387903, 4611686018427387904, 4611686018427387903, 4611686018427387904, 4611686018427387904 });
    try expectOverflow(max, .{ .num = 2, .den = 1 }, one);

    const u32_max = std.math.maxInt(u32);
    // (2^32 - 1)^2 ticks exceed the i64 range.
    try expectOverflow(1, .{ .num = u32_max, .den = 1 }, .{ .num = 1, .den = u32_max });
    // 1 / (2^32 - 1)^2 of a tick.
    try expectRescale(1, .{ .num = 1, .den = u32_max }, .{ .num = u32_max, .den = 1 }, .{ 0, 1, 0, 1, 0 });
    try expectRescale(-1, .{ .num = 1, .den = u32_max }, .{ .num = u32_max, .den = 1 }, .{ 0, -1, -1, 0, 0 });
}

test "missing timestamps stay missing" {
    const millisecond: TimeBase = .{ .num = 1, .den = 1000 };
    try std.testing.expectEqual(null, try rescaleTimestamp(null, one, millisecond, .nearest));
    try std.testing.expectEqual(5000, (try rescaleTimestamp(5, one, millisecond, .nearest)).?);
}
