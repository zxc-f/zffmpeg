// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/packet.c and the AVPacket fields in libavcodec/packet.h at the
// pinned reference revision describe the corresponding C type.
//! Encoded media packets (TODO.md T14a).
//!
//! A `Packet` is a view: it never owns `data`, and copying it copies only the
//! view. Whoever produced it says how long `data` stays valid. To keep a packet
//! longer, `clone` it into an `Owned` packet, which owns a copy of the bytes
//! until `deinit`; copying an `Owned` value does not clone it either.

const std = @import("std");
const time = @import("time.zig");

pub const Packet = struct {
    /// The encoded bytes, borrowed from the producer.
    data: []const u8,
    /// The time base of `pts`, `dts` and `duration`.
    time_base: time.TimeBase,
    /// Presentation time, or `null` when unknown.
    pts: ?i64 = null,
    /// Decoding time, or `null` when unknown.
    dts: ?i64 = null,
    /// Duration in `time_base` units, or `null` when unknown.
    duration: ?i64 = null,
    stream_index: u32 = 0,
    flags: Flags = .{},

    pub const Flags = struct {
        /// Decodable on its own (every PCM packet is).
        key: bool = false,
        /// Decoded only to prime a decoder; its output is dropped.
        discard: bool = false,
    };

    /// A packet that owns a copy of its bytes.
    pub const Owned = struct {
        /// `packet.data` is owned; do not free it or point it elsewhere.
        packet: Packet,
        gpa: std.mem.Allocator,

        pub fn deinit(owned: *Owned) void {
            owned.gpa.free(owned.packet.data);
            owned.* = undefined;
        }
    };

    /// Copies the bytes into storage from `gpa`, so the result outlives the
    /// producer's buffer. On failure nothing is allocated.
    pub fn clone(packet: Packet, gpa: std.mem.Allocator) std.mem.Allocator.Error!Owned {
        var copy = packet;
        copy.data = try gpa.dupe(u8, packet.data);
        return .{ .packet = copy, .gpa = gpa };
    }
};

test "a clone owns its bytes and keeps every other field" {
    const gpa = std.testing.allocator;
    var bytes = [_]u8{ 1, 2, 3, 4 };
    const view: Packet = .{
        .data = &bytes,
        .time_base = try .ofSampleRate(8000),
        .pts = -2,
        .dts = -2,
        .duration = 2,
        .stream_index = 1,
        .flags = .{ .key = true },
    };
    var owned = try view.clone(gpa);
    defer owned.deinit();
    bytes[0] = 9; // The producer reuses its buffer.
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, owned.packet.data);
    try std.testing.expectEqual(view.pts, owned.packet.pts);
    try std.testing.expectEqual(view.duration, owned.packet.duration);
    try std.testing.expectEqual(view.flags, owned.packet.flags);
    try std.testing.expectEqual(view.time_base, owned.packet.time_base);
}

fn cloneAndRelease(gpa: std.mem.Allocator) !void {
    const view: Packet = .{ .data = "abcd", .time_base = try .ofSampleRate(8000) };
    var owned = try view.clone(gpa);
    owned.deinit();
}

test "cloning a packet leaks nothing when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneAndRelease, .{});
}
