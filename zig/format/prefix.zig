// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Bytes that content detection read ahead of a parser (TODO.md T12c).
//!
//! Detection reads a few bytes to choose a container. Handing them back to the
//! chosen parser through `Prefix` means non-seekable input loses nothing, and
//! it works with any reader buffer size, including none: the bytes live in
//! this small array, not in the reader's buffer.

const std = @import("std");

/// The most bytes detection reads: enough for every supported magic.
pub const max_len = 4;

pub const Prefix = struct {
    bytes: [max_len]u8 = undefined,
    len: u8 = 0,
    /// How many of `bytes` were already handed back.
    pos: u8 = 0,

    /// Copies `bytes`, at most `max_len` of them.
    pub fn init(bytes: []const u8) Prefix {
        std.debug.assert(bytes.len <= max_len);
        var p: Prefix = .{ .len = @intCast(bytes.len) };
        @memcpy(p.bytes[0..bytes.len], bytes);
        return p;
    }

    /// The bytes not yet handed back.
    pub fn pending(p: *const Prefix) []const u8 {
        return p.bytes[p.pos..p.len];
    }

    /// Fills `dest` exactly: first with the pending prefix bytes, then from
    /// `reader`. Fails like `Reader.readSliceAll` when `reader` ends early.
    pub fn readAll(p: *Prefix, reader: *std.Io.Reader, dest: []u8) std.Io.Reader.Error!void {
        const head = p.pending();
        const n = @min(head.len, dest.len);
        @memcpy(dest[0..n], head[0..n]);
        p.pos += @intCast(n);
        try reader.readSliceAll(dest[n..]);
    }
};

test "pending bytes come first, then the reader" {
    var p: Prefix = .init("ab");
    var reader: std.Io.Reader = .fixed("cdef");
    var three: [3]u8 = undefined;
    try p.readAll(&reader, &three);
    try std.testing.expectEqualStrings("abc", &three);
    try std.testing.expectEqual(0, p.pending().len);
    try p.readAll(&reader, &three);
    try std.testing.expectEqualStrings("def", &three);
}

test "a read shorter than the prefix leaves the rest pending" {
    var p: Prefix = .init(".snd");
    var reader: std.Io.Reader = .fixed("X");
    var two: [2]u8 = undefined;
    try p.readAll(&reader, &two);
    try std.testing.expectEqualStrings(".s", &two);
    try std.testing.expectEqualStrings("nd", p.pending());
    var three: [3]u8 = undefined;
    try p.readAll(&reader, &three);
    try std.testing.expectEqualStrings("ndX", &three);
}

test "an empty prefix reads only from the reader, and a short reader ends the stream" {
    var p: Prefix = .{};
    var reader: std.Io.Reader = .fixed("ab");
    var three: [3]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, p.readAll(&reader, &three));
}
