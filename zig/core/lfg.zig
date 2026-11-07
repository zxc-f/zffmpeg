// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavutil/lfg.c (av_lfg_init) and lfg.h
// (av_lfg_get) at the pinned reference revision.
// Copyright (c) 2008 Michael Niedermayer
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's lagged Fibonacci generator (`AVLFG`), which the AC-3 decoder's
//! dither draws from (TODO.md T32a): `x[n] = x[n-24] + x[n-55]` mod 2^32
//! over 64 words seeded through MD5.

const std = @import("std");

pub const Lfg = struct {
    /// The words `av_lfg_init` leaves unwritten (0 to 7) keep the zeros of
    /// the codec's zeroed context.
    state: [64]u32 = @splat(0),
    index: u32 = 0,

    /// av_lfg_init.
    pub fn init(seed: u32) Lfg {
        var c: Lfg = .{};
        var tmp: [16]u8 = @splat(0);
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, tmp[0..4], seed, .little);
            tmp[4] = @intCast(i);
            std.crypto.hash.Md5.hash(&tmp, &tmp, .{});
            for (0..4) |k| c.state[i + k] = std.mem.readInt(u32, tmp[4 * k ..][0..4], .little);
        }
        return c;
    }

    /// av_lfg_get.
    pub fn get(c: *Lfg) u32 {
        const a = c.state[(c.index -% 24) & 63] +% c.state[(c.index -% 55) & 63];
        c.state[c.index & 63] = a;
        c.index +%= 1;
        return a;
    }
};

test "the generator's first words from seed 0" {
    var c: Lfg = .init(0);
    // index 0: state[40] + state[9].
    const want = c.state[40] +% c.state[9];
    try std.testing.expectEqual(want, c.get());
    try std.testing.expectEqual(1, c.index);
}
