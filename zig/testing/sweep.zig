// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test helpers for TODO.md's G3 (allocation-failure injection and fuzz
//! seeds) shared by the codec tests: `checkAllocationFailures` is std's
//! `checkAllAllocationFailures` run twice, the second time with every
//! remap and resize failing too, so code that grows or shrinks a buffer
//! takes its fallback path; `Seed` writes a `std.testing.Smith` input in
//! the layout `Smith` reads without the fuzzer; `oggPackets` splits a
//! single-stream Ogg file into its packets for decoder seeds.

const std = @import("std");

/// Whether remaps and resizes succeed or fail in a sweep. Failing them
/// reaches every allocation the succeeding pass makes, and the copies a
/// failed remap falls back to, so `.fail` alone bounds a slow sweep.
pub const Remaps = enum { both, fail };

/// Runs `run(gpa, context)` once to count its allocations, then once with
/// each allocation failing in turn; `run` must then fail with
/// `OutOfMemory` and free everything. Both passes are made with remaps and
/// resizes succeeding, then failing (`resize_fail_index = 0`). Any other
/// error from `run` fails the check.
pub fn checkAllocationFailures(
    backing: std.mem.Allocator,
    context: anytype,
    comptime run: fn (std.mem.Allocator, @TypeOf(context)) anyerror!void,
) !void {
    return checkAllocationFailuresWith(backing, .both, context, run);
}

/// `checkAllocationFailures` with remaps and resizes as `remaps` says.
pub fn checkAllocationFailuresWith(
    backing: std.mem.Allocator,
    remaps: Remaps,
    context: anytype,
    comptime run: fn (std.mem.Allocator, @TypeOf(context)) anyerror!void,
) !void {
    const modes: []const usize = switch (remaps) {
        .both => &.{ std.math.maxInt(usize), 0 },
        .fail => &.{0},
    };
    for (modes) |resize_fail_index| {
        const needed = needed: {
            var failing: std.testing.FailingAllocator = .init(backing, .{ .resize_fail_index = resize_fail_index });
            try run(failing.allocator(), context);
            if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
            break :needed failing.alloc_index;
        };
        for (0..needed) |fail_index| {
            var failing: std.testing.FailingAllocator = .init(backing, .{
                .fail_index = fail_index,
                .resize_fail_index = resize_fail_index,
            });
            if (run(failing.allocator(), context)) |_| {
                return if (failing.has_induced_failure) error.SwallowedOutOfMemoryError else error.NondeterministicMemoryUsage;
            } else |err| switch (err) {
                error.OutOfMemory => if (failing.allocated_bytes != failing.freed_bytes) {
                    std.debug.print("fail_index {d}/{d}, resize_fail_index {d}: {d} bytes allocated, {d} freed\n", .{
                        fail_index, needed, resize_fail_index, failing.allocated_bytes, failing.freed_bytes,
                    });
                    return error.MemoryLeakDetected;
                },
                else => return err,
            }
        }
    }
}

/// A `std.testing.Smith` input as `Smith` reads it without the fuzzer:
/// a value is 8 bytes little-endian (out of range reads as the range's
/// minimum), a slice is a 4-byte little-endian length then its bytes, an
/// end-of-stream flag is one byte.
pub const Seed = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(s: *Seed, gpa: std.mem.Allocator) void {
        s.bytes.deinit(gpa);
    }

    pub fn value(s: *Seed, gpa: std.mem.Allocator, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try s.bytes.appendSlice(gpa, &b);
    }

    pub fn slice(s: *Seed, gpa: std.mem.Allocator, data: []const u8) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(data.len), .little);
        try s.bytes.appendSlice(gpa, &b);
        try s.bytes.appendSlice(gpa, data);
    }

    pub fn eos(s: *Seed, gpa: std.mem.Allocator, end: bool) !void {
        try s.bytes.append(gpa, @intFromBool(end));
    }

    pub fn toOwnedSlice(s: *Seed, gpa: std.mem.Allocator) ![]u8 {
        return s.bytes.toOwnedSlice(gpa);
    }
};

/// The first `out.len` packets of an Ogg file's single logical stream,
/// each its pages' segments joined (no CRC or sequence check).
pub fn oggPackets(gpa: std.mem.Allocator, file: []const u8, out: []std.ArrayList(u8)) !void {
    var count: usize = 0;
    var pos: usize = 0;
    while (count < out.len) {
        if (file.len - pos < 27 or !std.mem.eql(u8, file[pos..][0..4], "OggS")) return error.TestUnexpectedResult;
        const segments = file[pos + 26];
        var body = pos + 27 + segments;
        for (file[pos + 27 ..][0..segments]) |len| {
            try out[count].appendSlice(gpa, file[body..][0..len]);
            body += len;
            if (len < 255) {
                count += 1;
                if (count == out.len) return;
            }
        }
        pos = body;
    }
}

/// Xiph lacing of a Vorbis stream's three header packets, as Ogg's
/// extradata carries them.
pub fn xiphExtradata(gpa: std.mem.Allocator, headers: [3][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, 2);
    for (headers[0..2]) |h| {
        var n = h.len;
        while (n >= 255) : (n -= 255) try out.append(gpa, 255);
        try out.append(gpa, @intCast(n));
    }
    for (headers) |h| try out.appendSlice(gpa, h);
    return out.toOwnedSlice(gpa);
}
