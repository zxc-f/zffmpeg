// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/rational.c and .h (av_reduce, av_mul_q, av_div_q, av_add_q,
// av_sub_q, av_cmp_q, av_d2q, av_nearer_q), mathematics.c (av_gcd,
// av_rescale_rnd, av_rescale_q_rnd, av_compare_ts, av_compare_mod,
// av_rescale_delta, av_add_stable) and common.h (av_sat_add64,
// av_sat_sub64) at the pinned reference revision describe the behavior,
// restated here.
//! FFmpeg's rational arithmetic and timestamp helpers (TODO.md T15), with
//! FFmpeg's exact results: its `AVRational` of two `int`s, reduction with a
//! bound, and the 64-bit helpers whose overflow behavior, sentinels and
//! wrap-around are part of what demuxers and muxers compute.
//!
//! Where FFmpeg's C relies on unsigned wrap-around (or on what its compiler
//! does with a signed overflow its inputs never reach), this does the same
//! with wrapping operators, so every result equals libavutil's for the inputs
//! in vectors/rational.txt. `time.rescale` stays the checked API for new
//! code: it reports overflow instead of returning FFmpeg's `INT64_MIN`; use
//! these where the port models FFmpeg's own arithmetic.

const std = @import("std");

/// FFmpeg's `AVRational`: `num / den`, either possibly zero or negative.
pub const Rational = struct {
    num: i32,
    den: i32,

    pub fn init(num: i32, den: i32) Rational {
        return .{ .num = num, .den = den };
    }

    /// `av_q2d`.
    pub fn toFloat(q: Rational) f64 {
        const num: f64 = @floatFromInt(q.num);
        const den: f64 = @floatFromInt(q.den);
        return num / den;
    }
};

/// `AV_NOPTS_VALUE`, which these helpers take and return as FFmpeg does.
pub const nopts: i64 = std.math.minInt(i64);

/// FFmpeg's `AVRounding`, with `AV_ROUND_PASS_MINMAX` as a flag.
pub const Rounding = struct {
    mode: Mode,
    /// Pass `INT64_MIN` and `INT64_MAX` through unchanged.
    pass_minmax: bool = false,

    pub const Mode = enum(u3) {
        zero = 0,
        inf = 1,
        down = 2,
        up = 3,
        near_inf = 5,
    };

    pub const zero: Rounding = .{ .mode = .zero };
    pub const inf: Rounding = .{ .mode = .inf };
    pub const down: Rounding = .{ .mode = .down };
    pub const up: Rounding = .{ .mode = .up };
    pub const near_inf: Rounding = .{ .mode = .near_inf };
};

fn unsigned(v: i64) u64 {
    return @bitCast(v);
}

fn signed(v: u64) i64 {
    return @bitCast(v);
}

/// `av_gcd`, Stein's algorithm; `INT64_MIN` is outside its domain.
pub fn gcd(a: i64, b: i64) i64 {
    std.debug.assert(a != std.math.minInt(i64) and b != std.math.minInt(i64));
    if (a == 0) return b;
    if (b == 0) return a;
    const za: u6 = @intCast(@ctz(unsigned(a)));
    const zb: u6 = @intCast(@ctz(unsigned(b)));
    const k = @min(za, zb);
    var u: u64 = @abs(a >> za);
    var v: u64 = @abs(b >> zb);
    while (u != v) {
        if (u > v) std.mem.swap(u64, &u, &v);
        v -= u;
        v >>= @intCast(@ctz(v));
    }
    return signed(u << k);
}

pub const Reduced = struct {
    q: Rational,
    /// The reduction is exact (`av_reduce`'s return value).
    exact: bool,
};

/// `av_reduce`: `num / den` reduced, its terms at most `max`, by continued
/// fractions when it must be approximated. `INT64_MIN` is outside its
/// domain.
pub fn reduce(num_in: i64, den_in: i64, max: i64) Reduced {
    std.debug.assert(num_in != std.math.minInt(i64) and den_in != std.math.minInt(i64));
    var a0: Rational = .{ .num = 0, .den = 1 };
    var a1: Rational = .{ .num = 1, .den = 0 };
    const sign = (num_in < 0) != (den_in < 0);
    var num = num_in;
    var den = den_in;
    // Neither is INT64_MIN, so both magnitudes fit.
    const abs_num: i64 = @intCast(@abs(num));
    const abs_den: i64 = @intCast(@abs(den));
    const g = gcd(abs_num, abs_den);
    if (g != 0) {
        num = @divTrunc(abs_num, g);
        den = @divTrunc(abs_den, g);
    }
    if (num <= max and den <= max) {
        a1 = .{ .num = @truncate(num), .den = @truncate(den) };
        den = 0;
    }
    // The C mixes `uint64_t` and `int64_t`; the wrapping operators keep its
    // modular results.
    while (den != 0) {
        var x: u64 = unsigned(@divTrunc(num, den));
        const next_den = signed(unsigned(num) -% unsigned(den) *% x);
        const a2n = signed(x *% unsigned(a1.num) +% unsigned(a0.num));
        const a2d = signed(x *% unsigned(a1.den) +% unsigned(a0.den));
        if (a2n > max or a2d > max) {
            if (a1.num != 0) x = unsigned(@divTrunc(max - a0.num, a1.num));
            if (a1.den != 0) x = @min(x, unsigned(@divTrunc(max - a0.den, a1.den)));
            const lhs = unsigned(den) *% (2 *% x *% unsigned(a1.den) +% unsigned(a0.den));
            const rhs = unsigned(num *% a1.den);
            if (lhs > rhs) {
                a1 = .{
                    .num = @truncate(signed(x *% unsigned(a1.num) +% unsigned(a0.num))),
                    .den = @truncate(signed(x *% unsigned(a1.den) +% unsigned(a0.den))),
                };
            }
            break;
        }
        a0 = a1;
        a1 = .{ .num = @truncate(a2n), .den = @truncate(a2d) };
        num = den;
        den = next_den;
    }
    return .{ .q = .{ .num = if (sign) -%a1.num else a1.num, .den = a1.den }, .exact = den == 0 };
}

const int_max: i64 = std.math.maxInt(i32);

/// `av_mul_q`.
pub fn mul(b: Rational, c: Rational) Rational {
    return reduce(@as(i64, b.num) * c.num, @as(i64, b.den) * c.den, int_max).q;
}

/// `av_div_q`.
pub fn div(b: Rational, c: Rational) Rational {
    return mul(b, .{ .num = c.den, .den = c.num });
}

/// `av_add_q`.
pub fn add(b: Rational, c: Rational) Rational {
    return reduce(@as(i64, b.num) * c.den +% @as(i64, c.num) * b.den, @as(i64, b.den) * c.den, int_max).q;
}

/// `av_sub_q`.
pub fn sub(b: Rational, c: Rational) Rational {
    return reduce(@as(i64, b.num) * c.den -% @as(i64, c.num) * b.den, @as(i64, b.den) * c.den, int_max).q;
}

/// `av_cmp_q`: -1, 0 or 1, and `INT_MIN` when either is 0/0.
pub fn cmp(a: Rational, b: Rational) i32 {
    const tmp = @as(i64, a.num) * b.den - @as(i64, b.num) * a.den;
    if (tmp != 0) return @as(i32, @truncate((tmp ^ a.den ^ b.den) >> 63)) | 1;
    if (b.den != 0 and a.den != 0) return 0;
    if (a.num != 0 and b.num != 0) return (a.num >> 31) - (b.num >> 31);
    return std.math.minInt(i32);
}

/// `av_nearer_q`: 1 if `q1` is nearer `q` than `q2`, -1 if `q2` is, 0 when
/// they are as near.
pub fn nearer(q: Rational, q1: Rational, q2: Rational) i32 {
    const a = @as(i64, q1.num) * q2.den + @as(i64, q2.num) * q1.den;
    const b = 2 * @as(i64, q1.den) * q2.den;
    const x_up = rescaleRnd(a, q.den, b, .up);
    const x_down = rescaleRnd(a, q.den, b, .down);
    const above: i32 = @intFromBool(x_up > q.num);
    const below: i32 = @intFromBool(x_down < q.num);
    return (above - below) * cmp(q2, q1);
}

/// `av_d2q`: the rational nearest `d` with terms at most `max`; 0/0 for NaN
/// and ±1/0 beyond `INT_MAX + 3`.
pub fn fromFloat(d: f64, max: i32) Rational {
    if (std.math.isNan(d)) return .{ .num = 0, .den = 0 };
    if (@abs(d) > @as(f64, @floatFromInt(int_max + 3))) return .{ .num = if (d < 0) -1 else 1, .den = 0 };
    const exponent = @max(std.math.frexp(d).exponent - 1, 0);
    const den = @as(i64, 1) << @intCast(62 - exponent);
    const scaled = @floor(d * @as(f64, @floatFromInt(den)) + 0.5);
    return reduce(@intFromFloat(scaled), den, max).q;
}

/// `av_rescale_rnd`: `a * b / c` rounded; `INT64_MIN` when the result
/// overflows or the arguments are invalid (`c <= 0`, `b < 0`), as FFmpeg
/// returns it.
pub fn rescaleRnd(a: i64, b: i64, c: i64, rnd: Rounding) i64 {
    const min = std.math.minInt(i64);
    const max = std.math.maxInt(i64);
    if (c <= 0 or b < 0) return min;
    if (rnd.pass_minmax and (a == min or a == max)) return a;
    var mode: u3 = @backingInt(rnd.mode);
    if (a < 0) {
        // The magnitude, rounded the mirrored way (zero and inf stay, down
        // and up swap).
        mode ^= (mode >> 1) & 1;
        const mirrored: Rounding.Mode = @fromBackingInt(mode);
        return signed(0 -% unsigned(rescaleRnd(-@max(a, -max), b, c, .{ .mode = mirrored })));
    }
    const r: i64 = if (rnd.mode == .near_inf) @divTrunc(c, 2) else if (mode & 1 != 0) c - 1 else 0;
    if (b <= int_max and c <= int_max) {
        if (a <= int_max) return @divTrunc(a * b + r, c);
        const ad = @divTrunc(a, c);
        const a2 = @divTrunc(@rem(a, c) * b + r, c);
        if (ad >= std.math.maxInt(i32) and b != 0 and ad > @divTrunc(max - a2, b)) return min;
        return ad * b + a2;
    }
    // 128-bit product by 32-bit halves and a bit-by-bit division, as
    // FFmpeg's C does it, its wrap-around included.
    const ua = unsigned(a);
    const ub = unsigned(b);
    var a0: u64 = ua & 0xffff_ffff;
    var a1: u64 = ua >> 32;
    const b0: u64 = ub & 0xffff_ffff;
    const b1: u64 = ub >> 32;
    var t1: u64 = a0 *% b1 +% a1 *% b0;
    const t1a = t1 << 32;
    a0 = a0 *% b0 +% t1a;
    a1 = a1 *% b1 +% (t1 >> 32) +% @intFromBool(a0 < t1a);
    a0 +%= unsigned(r);
    a1 +%= @intFromBool(a0 < unsigned(r));
    const uc = unsigned(c);
    var i: u7 = 64;
    while (i > 0) {
        i -= 1;
        a1 +%= a1 +% ((a0 >> @intCast(i)) & 1);
        t1 +%= t1;
        if (uc <= a1) {
            a1 -%= uc;
            t1 +%= 1;
        }
    }
    if (t1 > max) return min;
    return signed(t1);
}

/// `av_rescale`: `av_rescale_rnd` to the nearest.
pub fn rescale(a: i64, b: i64, c: i64) i64 {
    return rescaleRnd(a, b, c, .near_inf);
}

/// `av_rescale_q_rnd`.
pub fn rescaleQRnd(a: i64, bq: Rational, cq: Rational, rnd: Rounding) i64 {
    return rescaleRnd(a, @as(i64, bq.num) * cq.den, @as(i64, cq.num) * bq.den, rnd);
}

/// `av_rescale_q`.
pub fn rescaleQ(a: i64, bq: Rational, cq: Rational) i64 {
    return rescaleQRnd(a, bq, cq, .near_inf);
}

/// `av_compare_ts`: the order of two timestamps in their time bases.
pub fn compareTs(ts_a: i64, tb_a: Rational, ts_b: i64, tb_b: Rational) i32 {
    const a = @as(i64, tb_a.num) * tb_b.den;
    const b = @as(i64, tb_b.num) * tb_a.den;
    if ((@abs(ts_a) | unsigned(a) | @abs(ts_b) | unsigned(b)) <= int_max) {
        const left = ts_a * a;
        const right = ts_b * b;
        return @as(i32, @intFromBool(left > right)) - @intFromBool(left < right);
    }
    if (rescaleRnd(ts_a, a, b, .down) < ts_b) return -1;
    if (rescaleRnd(ts_b, b, a, .down) < ts_a) return 1;
    return 0;
}

/// `av_compare_mod`: `a - b` taken modulo `mod` (a power of two) into the
/// range around zero, for timestamps that wrap.
pub fn compareMod(a: u64, b: u64, mod: u64) i64 {
    var c = signed((a -% b) & (mod -% 1));
    if (unsigned(c) > mod >> 1) c = signed(unsigned(c) -% mod);
    return c;
}

/// `av_sat_add64`.
pub fn satAdd(a: i64, b: i64) i64 {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow == 0) return sum;
    return if (sum < 0) std.math.maxInt(i64) else std.math.minInt(i64);
}

/// `av_sat_sub64`.
pub fn satSub(a: i64, b: i64) i64 {
    const difference, const overflow = @subWithOverflow(a, b);
    if (overflow == 0) return difference;
    return if (difference < 0) std.math.maxInt(i64) else std.math.minInt(i64);
}

/// `av_rescale_delta`: `in_ts` rescaled to `out_tb`, kept on the running
/// `last` (in `fs_tb`, `nopts` at first) within the input's rounding so
/// that consecutive audio frames of `duration` samples do not jitter.
pub fn rescaleDelta(in_tb: Rational, in_ts: i64, fs_tb: Rational, duration: i32, last: *i64, out_tb: Rational) i64 {
    std.debug.assert(in_ts != nopts and duration >= 0);
    if (last.* != nopts and duration != 0 and @as(i64, in_tb.num) * out_tb.den > @as(i64, out_tb.num) * in_tb.den) {
        const a = rescaleQRnd(2 *% in_ts -% 1, in_tb, fs_tb, .down) >> 1;
        const b = (rescaleQRnd(2 *% in_ts +% 1, in_tb, fs_tb, .up) +% 1) >> 1;
        if (!(last.* < 2 *% a -% b or last.* > 2 *% b -% a)) {
            const this = std.math.clamp(last.*, a, b);
            last.* = this +% duration;
            return rescaleQ(this, fs_tb, out_tb);
        }
    }
    last.* = rescaleQ(in_ts, in_tb, fs_tb) +% duration;
    return rescaleQ(in_ts, in_tb, out_tb);
}

/// `av_add_stable`: `ts` plus `inc` units of `inc_tb`, without the error a
/// rounded increment would add up.
pub fn addStable(ts_tb: Rational, ts: i64, inc_tb_in: Rational, inc: i64) i64 {
    var inc_tb = inc_tb_in;
    if (inc != 1) inc_tb = mul(inc_tb, .{ .num = @truncate(inc), .den = 1 });
    const m = @as(i64, inc_tb.num) * ts_tb.den;
    const d = @as(i64, inc_tb.den) * ts_tb.num;
    if (@rem(m, d) == 0 and ts <= std.math.maxInt(i64) - @divTrunc(m, d)) return ts + @divTrunc(m, d);
    if (m < d) return ts;
    const old = rescaleQ(ts, ts_tb, inc_tb);
    const old_ts = rescaleQ(old, inc_tb, ts_tb);
    if (old == std.math.maxInt(i64) or old == nopts or old_ts == nopts) return ts;
    return satAdd(rescaleQ(old + 1, inc_tb, ts_tb), ts - old_ts);
}

const testing = std.testing;
const vectors = @embedFile("../testing/vectors/rational.txt");

fn parseQ(text: []const u8) !Rational {
    const slash = std.mem.findScalar(u8, text, '/') orelse return error.BadVector;
    return .{ .num = try std.fmt.parseInt(i32, text[0..slash], 10), .den = try std.fmt.parseInt(i32, text[slash + 1 ..], 10) };
}

fn parseTs(text: []const u8) !i64 {
    if (std.mem.eql(u8, text, "N")) return nopts;
    return std.fmt.parseInt(i64, text, 10);
}

fn roundingOf(value: i32) Rounding {
    return .{ .mode = @fromBackingInt(@intCast(value & 7)), .pass_minmax = value & 8192 != 0 };
}

fn expectQ(want: []const u8, got: Rational) !void {
    const q = try parseQ(want);
    try testing.expectEqual(q, got);
}

test "every vector of the pinned libavutil (vectors/rational.txt)" {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f: [10][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |token| : (n += 1) f[n] = token;
        count += 1;
        errdefer std.debug.print("vector: {s}\n", .{line});
        switch (line[0]) {
            'G' => try testing.expectEqual(try parseTs(f[3]), gcd(try parseTs(f[1]), try parseTs(f[2]))),
            'R' => {
                const r = reduce(try parseTs(f[1]), try parseTs(f[2]), try parseTs(f[3]));
                try testing.expectEqual(try std.fmt.parseInt(i32, f[4], 10), r.q.num);
                try testing.expectEqual(try std.fmt.parseInt(i32, f[5], 10), r.q.den);
                try testing.expectEqual(std.mem.eql(u8, f[6], "1"), r.exact);
            },
            'M' => {
                const b = try parseQ(f[2]);
                const c = try parseQ(f[3]);
                const got = switch (f[1][0]) {
                    'm' => mul(b, c),
                    'd' => div(b, c),
                    'a' => add(b, c),
                    's' => sub(b, c),
                    else => return error.BadVector,
                };
                try expectQ(f[4], got);
            },
            'C' => try testing.expectEqual(try std.fmt.parseInt(i32, f[3], 10), cmp(try parseQ(f[1]), try parseQ(f[2]))),
            'N' => try testing.expectEqual(try std.fmt.parseInt(i32, f[4], 10), nearer(try parseQ(f[1]), try parseQ(f[2]), try parseQ(f[3]))),
            'Q' => {
                const d: f64 = @bitCast(try std.fmt.parseInt(u64, f[1], 16));
                try expectQ(f[3], fromFloat(d, try std.fmt.parseInt(i32, f[2], 10)));
            },
            'S' => try testing.expectEqual(try parseTs(f[5]), rescaleRnd(
                try parseTs(f[1]),
                try parseTs(f[2]),
                try parseTs(f[3]),
                roundingOf(try std.fmt.parseInt(i32, f[4], 10)),
            )),
            'T' => try testing.expectEqual(try std.fmt.parseInt(i32, f[5], 10), compareTs(try parseTs(f[1]), try parseQ(f[2]), try parseTs(f[3]), try parseQ(f[4]))),
            'W' => try testing.expectEqual(try parseTs(f[4]), compareMod(@bitCast(try parseTs(f[1])), @bitCast(try parseTs(f[2])), try std.fmt.parseInt(u64, f[3], 10))),
            'D' => {
                var last = try parseTs(f[5]);
                const got = rescaleDelta(try parseQ(f[1]), try parseTs(f[2]), try parseQ(f[3]), try std.fmt.parseInt(i32, f[4], 10), &last, try parseQ(f[6]));
                try testing.expectEqual(try parseTs(f[7]), got);
                try testing.expectEqual(try parseTs(f[8]), last);
            },
            'A' => try testing.expectEqual(try parseTs(f[5]), addStable(try parseQ(f[1]), try parseTs(f[2]), try parseQ(f[3]), try parseTs(f[4]))),
            'X' => {
                const a = try parseTs(f[1]);
                const b = try parseTs(f[2]);
                try testing.expectEqual(try parseTs(f[3]), satAdd(a, b));
                try testing.expectEqual(try parseTs(f[4]), satSub(a, b));
            },
            else => return error.BadVector,
        }
    }
    try testing.expectEqual(55299, count);
}
