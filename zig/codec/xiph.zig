// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/xiph.c (avpriv_split_xiph_headers) at the pinned reference
// revision describes the behavior, restated here.
//! Xiph codecs' header packets in one extradata buffer (TODO.md T27b,
//! T27d): FFmpeg's Ogg muxer and Vorbis decoder split them alike.

const std = @import("std");
const testing = std.testing;

/// avpriv_split_xiph_headers: three headers each after a 16-bit size
/// (the first size `first_header_size`), or in Xiph lacing (2, then the
/// first two sizes in 255-byte steps, the third the rest); null where
/// FFmpeg's fails.
pub fn splitHeaders(extradata: []const u8, first_header_size: u16) ?[3][]const u8 {
    var out: [3][]const u8 = undefined;
    if (extradata.len >= 6 and std.mem.readInt(u16, extradata[0..2], .big) == first_header_size) {
        // The three size fields count from the start.
        var overall: usize = 6;
        var p: usize = 0;
        for (&out) |*h| {
            // In bounds: the previous header's check left room for this
            // size field.
            const len = std.mem.readInt(u16, extradata[p..][0..2], .big);
            p += 2;
            if (len > extradata.len or overall > extradata.len - len) return null;
            h.* = extradata[p..][0..len];
            p += len;
            overall += len;
        }
        return out;
    }
    if (extradata.len >= 3 and extradata.len < std.math.maxInt(i32) - 0x1ff and extradata[0] == 2) {
        // The type byte and the two last lacing bytes, then each 255-step
        // lacing byte with what it adds; `p` stays below `overall`.
        var overall: usize = 3;
        var p: usize = 1;
        var lens: [3]usize = undefined;
        for (lens[0..2]) |*len| {
            len.* = 0;
            while (overall < extradata.len and extradata[p] == 0xff) : (p += 1) {
                len.* += 0xff;
                overall += 0xff + 1;
            }
            len.* += extradata[p];
            overall += extradata[p];
            p += 1;
            if (overall > extradata.len) return null;
        }
        lens[2] = extradata.len - overall;
        for (&out, lens) |*h, len| {
            h.* = extradata[p..][0..len];
            p += len;
        }
        return out;
    }
    return null;
}

test "Xiph lacing and 16-bit sizes split as FFmpeg's" {
    const laced = [_]u8{ 2, 2, 1, 'a', 'b', 'c', 'd', 'e' };
    const parts = splitHeaders(&laced, 30).?;
    try testing.expectEqualStrings("ab", parts[0]);
    try testing.expectEqualStrings("c", parts[1]);
    try testing.expectEqualStrings("de", parts[2]);
    const sized = [_]u8{ 0, 2, 'a', 'b', 0, 1, 'c', 0, 1, 'd' };
    const p2 = splitHeaders(&sized, 2).?;
    try testing.expectEqualStrings("ab", p2[0]);
    try testing.expectEqualStrings("c", p2[1]);
    try testing.expectEqualStrings("d", p2[2]);
    try testing.expectEqual(null, splitHeaders(&[_]u8{ 2, 0xff, 0xff }, 30));
    try testing.expectEqual(null, splitHeaders(&[_]u8{ 2, 9, 1, 'a' }, 30));
    try testing.expectEqual(null, splitHeaders(&[_]u8{ 3, 0, 0 }, 30));
}
