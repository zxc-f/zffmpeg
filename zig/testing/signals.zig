// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! The vector generators' test signals (alac_vectors.c, g72x_vectors.c):
//! their xorshift and their tone, smoothed noise, noise, silence and
//! full-scale extremes, so an encoder's test feeds the samples the pinned
//! FFmpeg's encoder was given.

const std = @import("std");

/// The generators' xorshift.
pub const Rng = struct {
    state: u32,

    pub fn next(r: *Rng) u32 {
        var x = r.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        r.state = x;
        return x;
    }
};

/// alac_vectors.c's `sample`: sample `i` of channel `c` at 16 bits, or at
/// 24 with 8 more noise bits; `state` holds each channel's smoothed noise.
/// g72x_vectors.c's is channel 0's at 16 bits.
pub fn sample(rng: *Rng, signal: []const u8, c: usize, i: usize, state: *[8]i32, bps: u32) i32 {
    const noise: i32 = @as(i32, @intCast(rng.next() & 0xffff)) - 0x8000;
    var v: i32 = undefined;
    if (std.mem.eql(u8, signal, "tone")) {
        const period: i32 = 64 + 24 * @as(i32, @intCast(c));
        const phase: i32 = @intCast(@rem(@as(i64, @intCast(i)), period));
        const tri = if (phase < @divTrunc(period, 2)) phase else period - phase;
        v = @divTrunc((tri * 2 - @divTrunc(period, 2)) * 16384, @divTrunc(period, 2)) + @divTrunc(noise, 8);
    } else if (std.mem.eql(u8, signal, "smooth")) {
        state[c] += @divTrunc(noise - state[c], 8);
        v = state[c] * 2;
    } else if (std.mem.eql(u8, signal, "noise")) {
        v = noise;
    } else if (std.mem.eql(u8, signal, "silence")) {
        v = 0;
    } else {
        v = if ((i + c) & 1 != 0) 32767 else -32768;
        if (rng.next() & 1 != 0) v = -32768;
    }
    v = std.math.clamp(v, -32768, 32767);
    if (bps == 24 and !std.mem.eql(u8, signal, "silence")) v = v * 256 + @as(i32, @intCast(rng.next() & 0xff));
    return v;
}
