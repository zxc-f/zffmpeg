// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// av_strtod in libavutil/eval.c and parse_number in fftools/cmdutils.c at
// the pinned reference revision describe the behavior, and the SI prefix
// values are theirs; C's strtod and strtoul are followed as glibc reads
// them in the C locale.
//! FFmpeg's number syntax for options (TODO.md T17a): `av_strtod`, C's
//! `strtod` (or, for a text starting with `0x`, `strtoul` in base 16)
//! followed by an SI prefix (`k`, `M`, `Gi`, ...: decimal, or binary with
//! `i`), `dB` or `B`, and `parse_number`, which fftools' command line uses
//! for its numeric options: the whole text a number, within a range, an
//! integer when the option is one. Equal to FFmpeg's on
//! zig/testing/vectors/number.txt.
//!
//! Decimal and hexadecimal floats round to nearest as glibc's `strtod`
//! does. `dB` is `ff_exp10`, `exp2(log2(10) * x)`, with Zig's `exp2`, which
//! may differ from the C library's in the last bit.

const std = @import("std");

pub const Number = struct {
    value: f64,
    /// Bytes of the text the number took; 0 when there was none.
    end: usize,
};

const Prefix = struct { exp: i8, bin: f64, dec: f64 };

/// eval.c's `si_prefixes`, by character from 'E' to 'z'.
fn prefix(c: u8) ?Prefix {
    return switch (c) {
        'y' => .{ .exp = -24, .bin = 8.271806125530276749e-25, .dec = 1e-24 },
        'z' => .{ .exp = -21, .bin = 8.4703294725430034e-22, .dec = 1e-21 },
        'a' => .{ .exp = -18, .bin = 8.6736173798840355e-19, .dec = 1e-18 },
        'f' => .{ .exp = -15, .bin = 8.8817841970012523e-16, .dec = 1e-15 },
        'p' => .{ .exp = -12, .bin = 9.0949470177292824e-13, .dec = 1e-12 },
        'n' => .{ .exp = -9, .bin = 9.3132257461547852e-10, .dec = 1e-9 },
        'u' => .{ .exp = -6, .bin = 9.5367431640625e-7, .dec = 1e-6 },
        'm' => .{ .exp = -3, .bin = 9.765625e-4, .dec = 1e-3 },
        'c' => .{ .exp = -2, .bin = 9.8431332023036951e-3, .dec = 1e-2 },
        'd' => .{ .exp = -1, .bin = 9.921256574801246e-2, .dec = 1e-1 },
        'h' => .{ .exp = 2, .bin = 1.0159366732596479e2, .dec = 1e2 },
        'k', 'K' => .{ .exp = 3, .bin = 1.024e3, .dec = 1e3 },
        'M' => .{ .exp = 6, .bin = 1.048576e6, .dec = 1e6 },
        'G' => .{ .exp = 9, .bin = 1.073741824e9, .dec = 1e9 },
        'T' => .{ .exp = 12, .bin = 1.099511627776e12, .dec = 1e12 },
        'P' => .{ .exp = 15, .bin = 1.125899906842624e15, .dec = 1e15 },
        'E' => .{ .exp = 18, .bin = 1.152921504606847e18, .dec = 1e18 },
        'Z' => .{ .exp = 21, .bin = 1.1805916207174113e21, .dec = 1e21 },
        'Y' => .{ .exp = 24, .bin = 1.2089258196146292e24, .dec = 1e24 },
        else => null,
    };
}

fn at(text: []const u8, i: usize) u8 {
    return if (i < text.len) text[i] else 0;
}

fn startsWithIgnoreCase(text: []const u8, i: usize, word: []const u8) bool {
    return i + word.len <= text.len and std.ascii.eqlIgnoreCase(text[i..][0..word.len], word);
}

/// glibc's `strtod` in the C locale: leading white space, a sign, then
/// `inf`/`infinity`, `nan` (with an optional `(chars)`), a hexadecimal
/// float or a decimal one; `end` 0 when nothing converts.
pub fn strtod(text: []const u8) Number {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    const number_start = i;
    var negative = false;
    if (at(text, i) == '+' or at(text, i) == '-') {
        negative = at(text, i) == '-';
        i += 1;
    }
    const sign: f64 = if (negative) -1 else 1;
    if (startsWithIgnoreCase(text, i, "inf")) {
        const end = if (startsWithIgnoreCase(text, i, "infinity")) i + 8 else i + 3;
        return .{ .value = sign * std.math.inf(f64), .end = end };
    }
    if (startsWithIgnoreCase(text, i, "nan")) {
        var end = i + 3;
        if (at(text, end) == '(') {
            var k = end + 1;
            while (std.ascii.isAlphanumeric(at(text, k)) or at(text, k) == '_') k += 1;
            if (at(text, k) == ')') end = k + 1;
        }
        return .{ .value = std.math.nan(f64), .end = end };
    }
    // A hexadecimal float needs a digit after `0x`, before or after a point.
    if (at(text, i) == '0' and at(text, i + 1) | 0x20 == 'x' and
        (std.ascii.isHex(at(text, i + 2)) or (at(text, i + 2) == '.' and std.ascii.isHex(at(text, i + 3)))))
    {
        var j = i + 2;
        while (std.ascii.isHex(at(text, j))) j += 1;
        if (at(text, j) == '.') {
            j += 1;
            while (std.ascii.isHex(at(text, j))) j += 1;
        }
        j = exponent(text, j, 'p');
        return .{ .value = parse(text[number_start..j]), .end = j };
    }
    var j = i;
    var digits = false;
    while (std.ascii.isDigit(at(text, j))) : (j += 1) digits = true;
    if (at(text, j) == '.') {
        j += 1;
        while (std.ascii.isDigit(at(text, j))) : (j += 1) digits = true;
    }
    if (!digits) return .{ .value = 0, .end = 0 };
    j = exponent(text, j, 'e');
    return .{ .value = parse(text[number_start..j]), .end = j };
}

/// An exponent (`e` or `p`, a sign, digits) at `j`, if complete.
fn exponent(text: []const u8, j: usize, letter: u8) usize {
    if (at(text, j) | 0x20 != letter) return j;
    var k = j + 1;
    if (at(text, k) == '+' or at(text, k) == '-') k += 1;
    if (!std.ascii.isDigit(at(text, k))) return j;
    while (std.ascii.isDigit(at(text, k))) k += 1;
    return k;
}

/// A prefix `strtod` accepted, rounded to nearest as glibc does.
fn parse(prefix_text: []const u8) f64 {
    // The scanner gave a well-formed float; a point with no digits after
    // it is still one.
    return std.fmt.parseFloat(f64, prefix_text) catch unreachable;
}

/// glibc's `strtoul` in base 16 after `0x`: hexadecimal digits, saturating
/// at 2^64 - 1; just the `0` when no digit follows.
fn strtoulHex(text: []const u8) Number {
    var j: usize = 2;
    if (!std.ascii.isHex(at(text, j))) return .{ .value = 0, .end = 1 };
    var value: u64 = 0;
    var saturated = false;
    while (std.ascii.isHex(at(text, j))) : (j += 1) {
        const digit = std.fmt.charToDigit(text[j], 16) catch unreachable;
        if (!saturated) {
            const times = std.math.mul(u64, value, 16) catch null;
            const sum = if (times) |t| std.math.add(u64, t, digit) catch null else null;
            if (sum) |v| value = v else saturated = true;
        }
    }
    const result: u64 = if (saturated) std.math.maxInt(u64) else value;
    return .{ .value = @floatFromInt(result), .end = j };
}

/// `av_strtod`: a number, then a suffix: `dB` (decibels: 10^(v / 20)), an
/// SI prefix, decimal or, followed by `i`, binary, then `B` (bytes, times 8).
pub fn avStrtod(text: []const u8) Number {
    var n = if (at(text, 0) == '0' and at(text, 1) | 0x20 == 'x') strtoulHex(text) else strtod(text);
    if (n.end == 0) return n;
    var next = n.end;
    if (at(text, next) == 'd' and at(text, next + 1) == 'B') {
        // ff_exp10: exp2(M_LOG2_10 * x).
        n.value = @exp2(log2_10 * (n.value / 20));
        next += 2;
    } else if (prefix(at(text, next))) |p| {
        if (at(text, next + 1) == 'i') {
            n.value *= p.bin;
            next += 2;
        } else {
            n.value *= p.dec;
            next += 1;
        }
    }
    if (at(text, next) == 'B') {
        n.value *= 8;
        next += 1;
    }
    n.end = next;
    return n;
}

/// libavutil's `M_LOG2_10`.
const log2_10: f64 = 3.32192809488736234787;

pub const Kind = enum { int, int64, float, double };

pub const ParseError = error{
    /// The text is not a number from start to end.
    NotANumber,
    /// Outside the option's range.
    OutOfRange,
    /// A fraction (or NaN) for an integer option.
    NotAnInteger,
};

/// `parse_number`: `text` as a whole is `av_strtod`'s number, within
/// `min` and `max`, and an integer for an integer `kind`.
pub fn parseNumber(text: []const u8, kind: Kind, min: f64, max: f64) ParseError!f64 {
    const n = avStrtod(text);
    if (n.end != text.len) return error.NotANumber;
    const d = n.value;
    if (d < min or d > max) return error.OutOfRange;
    switch (kind) {
        .int, .int64 => if (std.math.isNan(d) or @trunc(d) != d) return error.NotAnInteger,
        .float, .double => {},
    }
    return d;
}

/// `parse_number` for an `int` option, FFmpeg's `OPT_TYPE_INT` with its
/// full range, as `-ar` takes it.
pub fn parseInt(text: []const u8) ParseError!i32 {
    const d = try parseNumber(text, .int, std.math.minInt(i32), std.math.maxInt(i32));
    return @intFromFloat(d);
}

pub const DurationError = error{
    /// Not a duration (`AVERROR(EINVAL)`).
    InvalidDuration,
    /// Too large for 64-bit microseconds (`AVERROR(ERANGE)`).
    OutOfRange,
};

/// `av_parse_time` of a duration: `[-][HH:]MM:SS[.m...]` or
/// `[-]S+[.m...]`, then `s`, `ms` or `us`, as microseconds (TODO.md T25b).
pub fn parseDuration(text: []const u8) DurationError!i64 {
    var p: usize = 0;
    var negative = false;
    if (p < text.len and text[p] == '-') {
        negative = true;
        p += 1;
    }
    var t: i64 = undefined;
    var q: usize = undefined;
    if (clock(text, p, true) orelse clock(text, p, false)) |c| {
        t = c.seconds;
        q = c.end;
    } else {
        // strtoll in base 10.
        var i = p;
        while (i < text.len and isCSpace(text[i])) i += 1;
        var minus = false;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            minus = text[i] == '-';
            i += 1;
        }
        const digits_start = i;
        var value: i64 = 0;
        var overflow = false;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            const digit: i64 = text[i] - '0';
            const times = std.math.mul(i64, value, 10) catch null;
            const next = if (times) |m| (if (minus) std.math.sub(i64, m, digit) else std.math.add(i64, m, digit)) catch null else null;
            if (next) |n| value = n else overflow = true;
        }
        if (i == digits_start) return error.InvalidDuration;
        if (overflow) return error.OutOfRange;
        t = value;
        q = i;
    }
    var microseconds: i64 = 0;
    if (q < text.len and text[q] == '.') {
        q += 1;
        var n: i64 = 100000;
        while (n >= 1 and q < text.len and std.ascii.isDigit(text[q])) : ({
            n = @divTrunc(n, 10);
            q += 1;
        }) microseconds += n * (text[q] - '0');
        while (q < text.len and std.ascii.isDigit(text[q])) q += 1;
    }
    var suffix: i64 = 1000000;
    if (std.mem.startsWith(u8, text[q..], "ms")) {
        suffix = 1000;
        microseconds = @divTrunc(microseconds, 1000);
        q += 2;
    } else if (std.mem.startsWith(u8, text[q..], "us")) {
        suffix = 1;
        microseconds = 0;
        q += 2;
    } else if (q < text.len and text[q] == 's') {
        q += 1;
    }
    if (q != text.len) return error.InvalidDuration;
    if (@divTrunc(std.math.maxInt(i64), suffix) < t or t < @divTrunc(std.math.minInt(i64), suffix)) return error.OutOfRange;
    t *= suffix;
    if (std.math.maxInt(i64) - microseconds < t) return error.OutOfRange;
    t += microseconds;
    if (t == std.math.minInt(i64) and negative) return error.OutOfRange;
    return if (negative) -t else t;
}

fn isCSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// `av_small_strptime` with `%J:%M:%S` (`hours`) or `%M:%S`.
fn clock(text: []const u8, start: usize, hours: bool) ?struct { seconds: i64, end: usize } {
    var p = start;
    var h: i64 = 0;
    if (hours) {
        h = clockNumber(text, &p, std.math.maxInt(i32), 4) orelse return null;
        if (p >= text.len or text[p] != ':') return null;
        p += 1;
    }
    const m = clockNumber(text, &p, 59, 2) orelse return null;
    if (p >= text.len or text[p] != ':') return null;
    p += 1;
    const s = clockNumber(text, &p, 59, 2) orelse return null;
    return .{ .seconds = h * 3600 + m * 60 + s, .end = p };
}

/// `date_get_num`: up to `len_max` digits, at most `max`.
fn clockNumber(text: []const u8, p: *usize, max: i64, len_max: usize) ?i64 {
    var i = p.*;
    var value: i64 = 0;
    while (i < text.len and i - p.* < len_max and std.ascii.isDigit(text[i])) : (i += 1) value = value * 10 + (text[i] - '0');
    if (i == p.*) return null;
    if (value > max) return null;
    p.* = i;
    return value;
}

const vectors = @embedFile("../testing/vectors/number.txt");
const vector_count = 261;

fn unhex(field: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.eql(u8, field, "-")) return "";
    return std.fmt.hexToBytes(buffer[0 .. field.len / 2], field);
}

test "numbers equal av_strtod's and parse_number's on every vector" {
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next().?;
        var buffer: [64]u8 = undefined;
        const text = try unhex(fields.next().?, &buffer);
        errdefer std.debug.print("vector {d}: {s} {s}\n", .{ count + 1, kind, text });
        if (kind[0] == 'N') {
            const value_text = fields.next().?;
            const end = try std.fmt.parseInt(usize, fields.next().?, 10);
            const n = avStrtod(text);
            try std.testing.expectEqual(end, n.end);
            if (std.mem.eql(u8, value_text, "nan")) {
                try std.testing.expect(std.math.isNan(n.value));
            } else if (std.mem.eql(u8, value_text, "inf")) {
                try std.testing.expectEqual(std.math.inf(f64), n.value);
            } else if (std.mem.eql(u8, value_text, "-inf")) {
                try std.testing.expectEqual(-std.math.inf(f64), n.value);
            } else {
                const want = try std.fmt.parseFloat(f64, value_text);
                const want_bits: u64 = @bitCast(want);
                const got_bits: u64 = @bitCast(n.value);
                try std.testing.expectEqual(want_bits, got_bits);
            }
        } else if (kind[0] == 'D') {
            const verdict = fields.next().?;
            const result = parseDuration(text);
            if (std.mem.eql(u8, verdict, "E")) {
                try std.testing.expectError(error.InvalidDuration, result);
            } else if (std.mem.eql(u8, verdict, "R")) {
                try std.testing.expectError(error.OutOfRange, result);
            } else {
                try std.testing.expectEqual(try std.fmt.parseInt(i64, verdict, 10), try result);
            }
        } else {
            const verdict = fields.next().?;
            const result = parseInt(text);
            if (std.mem.eql(u8, verdict, "number")) {
                try std.testing.expectError(error.NotANumber, result);
            } else if (std.mem.eql(u8, verdict, "range")) {
                try std.testing.expectError(error.OutOfRange, result);
            } else if (std.mem.eql(u8, verdict, "integer")) {
                try std.testing.expectError(error.NotAnInteger, result);
            } else {
                try std.testing.expectEqual(try std.fmt.parseInt(i32, verdict, 10), try result);
            }
        }
    }
    try std.testing.expectEqual(vector_count, count);
}
