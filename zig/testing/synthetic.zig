// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Synthetic input for tests past 4 GiB (TODO.md T21b): `ZeroStream` reads a
//! header, then any number of zero bytes produced on demand, then a trailer,
//! in constant memory. Skipping (`discard`) moves past the zeros without
//! producing them, so a parser can validate a 5 GiB stream instantly.

const std = @import("std");

pub const ZeroStream = struct {
    head: []const u8,
    zeros: u64,
    tail: []const u8,
    /// Bytes consumed so far, across all three parts.
    position: u64 = 0,
    interface: std.Io.Reader,

    /// `buffer` is the reader buffer; any size works, including none.
    pub fn init(head: []const u8, zeros: u64, tail: []const u8, buffer: []u8) ZeroStream {
        return .{
            .head = head,
            .zeros = zeros,
            .tail = tail,
            .interface = .{
                .vtable = &.{ .stream = stream, .discard = discard },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn total(s: *const ZeroStream) u64 {
        return s.head.len + s.zeros + s.tail.len;
    }

    /// The bytes of the part that holds `position`, from there on; the zero
    /// part is served from a fixed block of zeros.
    fn current(s: *const ZeroStream) []const u8 {
        const zero_block: [4096]u8 = comptime @splat(0);
        if (s.position < s.head.len) return s.head[@intCast(s.position)..];
        const in_zeros = s.position - s.head.len;
        if (in_zeros < s.zeros) return zero_block[0..@min(s.zeros - in_zeros, zero_block.len)];
        return s.tail[@intCast(in_zeros - s.zeros)..];
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *ZeroStream = @alignCast(@fieldParentPtr("interface", r));
        if (s.position == s.total()) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(s.current()));
        s.position += n;
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const s: *ZeroStream = @alignCast(@fieldParentPtr("interface", r));
        if (s.position == s.total()) return error.EndOfStream;
        const n = limit.minInt64(s.total() - s.position);
        s.position += n;
        return n;
    }
};

test "the parts arrive in order, and skipping is free" {
    var buffer: [3]u8 = undefined;
    var stream: ZeroStream = .init("ab", 5, "yz", &buffer);
    const r = &stream.interface;
    var out: [9]u8 = undefined;
    try r.readSliceAll(&out);
    try std.testing.expectEqualSlices(u8, "ab\x00\x00\x00\x00\x00yz", &out);
    try std.testing.expectError(error.EndOfStream, r.takeByte());

    var big: ZeroStream = .init("h", 5 << 30, "t", &.{});
    try big.interface.discardAll64(1 + (5 << 30));
    var last: [1]u8 = undefined;
    try big.interface.readSliceAll(&last);
    try std.testing.expectEqual('t', last[0]);
}
