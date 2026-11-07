// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/parser.c (ff_combine_frame) and
// parser.h (ParseContext) at the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// Copyright (c) 2003 Michael Niedermayer
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! libavcodec's frame-assembling `ParseContext` (`ff_combine_frame`), which
//! the MPEG audio (T29a) and AAC (T30a) parsers share: bytes held until a
//! parser finds where its frame ends, and the bytes "overread" when that
//! end lies before the call's buffer, which the next call starts with.

const std = @import("std");

pub const ParseContext = struct {
    /// FFmpeg's `buffer`: the held bytes are `items[0..index]`; after a
    /// frame that ended early, the overread bytes follow at
    /// `overread_index`.
    buffer: std.ArrayList(u8) = .empty,
    index: usize = 0,
    last_index: usize = 0,
    overread: usize = 0,
    overread_index: usize = 0,
    /// The last bytes seen, MSB first: a parser's sync state, which an
    /// overread updates.
    state: u32 = 0,
    state64: u64 = 0,

    pub fn deinit(pc: *ParseContext, gpa: std.mem.Allocator) void {
        pc.buffer.deinit(gpa);
        pc.* = undefined;
    }

    /// `ff_combine_frame` with `next` the frame's end in `buf`, null for
    /// END_NOT_FOUND (the bytes are held; at the end, with `buf` empty,
    /// what is held is the frame). A negative `next` ends the frame
    /// `-next` bytes before `buf`, among the held bytes, which the next
    /// call serves first. Returns the frame, valid until the next call, or
    /// null when none is complete (also for a `next` past `buf`, which
    /// FFmpeg refuses with EINVAL and no other effect).
    pub fn combine(pc: *ParseContext, gpa: std.mem.Allocator, next_in: ?i64, buf: []const u8) std.mem.Allocator.Error!?[]const u8 {
        // The bytes overread by the last frame come first.
        while (pc.overread > 0) : (pc.overread -= 1) {
            pc.buffer.items[pc.index] = pc.buffer.items[pc.overread_index];
            pc.index += 1;
            pc.overread_index += 1;
        }
        var next = next_in;
        const buf_len: i64 = @intCast(buf.len);
        if (next) |n| if (n > buf_len) return null;
        // At the end, flush what is held.
        if (buf.len == 0 and next == null) next = 0;
        pc.last_index = pc.index;
        const n = next orelse {
            try pc.buffer.resize(gpa, pc.index);
            try pc.buffer.appendSlice(gpa, buf);
            pc.index += buf.len;
            return null;
        };
        const held: i64 = @intCast(pc.index);
        // A parser ends a frame before its buffer only inside the held
        // bytes (`pc->index + next > 0` in the AAC parser), so the frame
        // is never negative.
        const size: usize = @intCast(@max(0, held + n));
        pc.overread_index = size;
        var frame: []const u8 = undefined;
        if (pc.index > 0) {
            try pc.buffer.resize(gpa, pc.index);
            try pc.buffer.appendSlice(gpa, buf[0..@intCast(@max(n, 0))]);
            pc.index = 0;
            frame = pc.buffer.items[0..size];
        } else {
            frame = buf[0..size];
        }
        // The overread bytes: the last 8 enter the state. Only held bytes
        // can be overread (FFmpeg would read before its buffer otherwise).
        var back = @max(n, -held);
        if (back < -8) {
            pc.overread += @intCast(-8 - back);
            back = -8;
        }
        const last: i64 = @intCast(pc.last_index);
        while (back < 0) : (back += 1) {
            const byte = pc.buffer.items[@intCast(last + back)];
            pc.state = pc.state << 8 | byte;
            pc.state64 = pc.state64 << 8 | byte;
            pc.overread += 1;
        }
        return frame;
    }
};

const testing = std.testing;

test "held bytes join the next frame; a frame may end among them" {
    const gpa = testing.allocator;
    var pc: ParseContext = .{};
    defer pc.deinit(gpa);
    try testing.expectEqual(null, try pc.combine(gpa, null, "abc"));
    // The frame ends two bytes before this buffer: "a", and "bc" overread.
    try testing.expectEqualStrings("a", (try pc.combine(gpa, -2, "def")).?);
    try testing.expectEqual(2, pc.overread);
    try testing.expectEqual(@as(u32, 'b') << 8 | 'c', pc.state & 0xffff);
    // The overread bytes start the next frame.
    try testing.expectEqualStrings("bcxy", (try pc.combine(gpa, 2, "xyz")).?);
    // Nothing held: the caller's bytes themselves.
    const buf = "12345";
    const frame = (try pc.combine(gpa, 3, buf)).?;
    try testing.expectEqual(@as([*]const u8, buf.ptr), frame.ptr);
    try testing.expectEqual(null, try pc.combine(gpa, 9, buf));
    // The end flushes what is held.
    try testing.expectEqual(null, try pc.combine(gpa, null, "tail"));
    try testing.expectEqualStrings("tail", (try pc.combine(gpa, null, "")).?);
}
