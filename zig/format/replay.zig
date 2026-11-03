// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! A reader that serves bytes already read from a stream, then the rest of
//! the stream (TODO.md T16).
//!
//! Probing reads the start of the input to choose a format. `Replay` hands
//! those bytes to the chosen parser before the source's own, so non-seekable
//! input loses nothing. It has no buffer of its own and passes reads straight
//! through, so any source buffer size works, including none. It replaced
//! T12c's 4-byte `Prefix`, which every parser had to handle itself.

const std = @import("std");

pub const Replay = struct {
    /// Borrowed: the bytes to serve first. They must outlive the reader.
    head: []const u8,
    /// How many of `head` were already served.
    pos: usize = 0,
    source: *std.Io.Reader,
    interface: std.Io.Reader,

    /// `head` first, then `source`. The `Replay` must not move once
    /// `interface` is in use.
    pub fn init(head: []const u8, source: *std.Io.Reader) Replay {
        return .{
            .head = head,
            .source = source,
            .interface = .{
                .vtable = &.{ .stream = stream, .discard = discard },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const replay: *Replay = @alignCast(@fieldParentPtr("interface", r));
        if (replay.pos < replay.head.len) {
            const n = try w.write(limit.sliceConst(replay.head[replay.pos..]));
            replay.pos += n;
            return n;
        }
        return replay.source.stream(w, limit);
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const replay: *Replay = @alignCast(@fieldParentPtr("interface", r));
        if (replay.pos < replay.head.len) {
            const n = limit.minInt(replay.head.len - replay.pos);
            replay.pos += n;
            return n;
        }
        // `Reader.discard` drops the source's buffered bytes and then reports
        // the end of the stream, losing their count, so those go first.
        const buffered = replay.source.buffered().len;
        if (buffered > 0) {
            const n = limit.minInt(buffered);
            replay.source.toss(n);
            return n;
        }
        return replay.source.discard(limit);
    }
};

test "the head comes first, then the source, across any read sizes" {
    var source: std.Io.Reader = .fixed("cdef");
    var replay: Replay = .init("ab", &source);
    const r = &replay.interface;
    var three: [3]u8 = undefined;
    try r.readSliceAll(&three);
    try std.testing.expectEqualStrings("abc", &three);
    try r.readSliceAll(&three);
    try std.testing.expectEqualStrings("def", &three);
    try std.testing.expectError(error.EndOfStream, r.readSliceAll(three[0..1]));
}

test "skipping crosses from the head into the source, and a short read stops at the end" {
    var source: std.Io.Reader = .fixed("cdefgh");
    var replay: Replay = .init("ab", &source);
    const r = &replay.interface;
    try r.discardAll(3);
    var rest: [8]u8 = undefined;
    try std.testing.expectEqual(5, try r.readSliceShort(&rest));
    try std.testing.expectEqualStrings("defgh", rest[0..5]);
}

test "a failing source fails the replay once the head is served" {
    var source: std.Io.Reader = .failing;
    var replay: Replay = .init("a", &source);
    var two: [2]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, replay.interface.readSliceAll(&two));
}

test "skipping to the end counts every byte, buffered in the source or not" {
    var source: std.Io.Reader = .fixed("cdefgh");
    var replay: Replay = .init("ab", &source);
    try std.testing.expectEqual(8, try replay.interface.discardShort(1 << 16));
    var empty_head: std.Io.Reader = .fixed("cdefgh");
    var after: Replay = .init("", &empty_head);
    try std.testing.expectEqual(6, try after.interface.discardShort(1 << 16));
}
