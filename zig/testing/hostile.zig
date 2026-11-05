// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Hostile-input helpers for the demuxers' tests (TODO.md G3):
//! allocation-failure injection, the seed encoding of their bounded fuzz
//! entries, and a deterministic mutation smoke run over those seeds.
//!
//! `checkAll` is `std.testing.checkAllAllocationFailures` with every
//! resize and remap failing as well, so each growth takes a fresh
//! allocation and a copy that can fail in turn (`ArrayList.toOwnedSlice`
//! after a failed remap, the path of a double free in the Ogg demuxer's
//! metadata update). It also keeps the count of allocations deterministic:
//! with resizes passed through, whether one succeeds in place depends on
//! the backing allocator's state, which earlier runs change. Every
//! allocation a run with working resizes makes is made here too, so no
//! failure point is lost. The sweep runs on `std.testing.allocator`, so a
//! double free panics and a leak fails.
//!
//! `fuzzSeed` lays out a corpus entry as `std.testing.Smith` reads one
//! outside the fuzzer: a slice is a little-endian `u32` length and its
//! bytes, each value a little-endian `u64`.
//!
//! `mutationSmoke` is the bounded smoke run `zig build test` can make
//! without the fuzzer (`std.testing.fuzz` runs only the seeds there): each
//! seed's slice mutated `rounds` times by a fixed-seed PRNG (bytes
//! overwritten, flipped, duplicated or cut off) and passed to the entry's
//! callback, in every optimization mode.
//!
//! `TestPlan` and `runTestPlan` are what those sweeps and entries do with
//! an opened demuxer: the generic layer's read-ahead, the packets, and a
//! seek after the first (`drawTestPlan` draws one from a fuzz input).

const std = @import("std");
const demux = @import("../format/demux.zig");
const seek = @import("../format/seek.zig");

/// What the demuxers' allocation-failure sweeps and fuzz entries do with
/// an opened input.
pub const TestPlan = struct {
    /// A seek after the first packet returned, then reading on.
    seek: ?Seek = null,
    /// Packets returned at most, so a fuzzed input's work stays bounded.
    max_packets: u32 = 4096,

    pub const Seek = struct {
        /// `seekFile` (avformat_seek_file, as `-ss` calls it) or
        /// `seekFrame` (av_seek_frame).
        file: bool = true,
        stream: i32 = -1,
        ts: i64,
        flags: seek.Flags = .{},
        /// `seekFile` with both bounds at `ts`, rather than open as `-ss`
        /// leaves them, so no fallback seek runs. The allocation-failure
        /// sweeps use it: seek.zig's `seekFile` falls back after any error
        /// of the first seek, running out of memory included, and the
        /// fallback can then succeed.
        exact: bool = false,
    };
};

/// A plan drawn from a fuzz input: seven values, always drawn, in the
/// order `seedValues` lays them out; the seek only on a seekable input.
pub fn drawTestPlan(smith: *std.testing.Smith, seekable: bool) TestPlan {
    const wants_seek = smith.value(bool);
    const file = smith.value(bool);
    const choice: i32 = smith.valueRangeAtMost(u8, 0, 2);
    const stream = choice - 1;
    const ts = smith.value(i64);
    const flags: seek.Flags = .{ .backward = smith.value(bool), .any = smith.value(bool), .byte = smith.value(bool) };
    return .{
        .seek = if (seekable and wants_seek) .{ .file = file, .stream = stream, .ts = ts, .flags = flags } else null,
        .max_packets = 512,
    };
}

/// `drawTestPlan`'s values for a seed (`fuzzSeed`).
pub fn seedValues(comptime s: ?TestPlan.Seek) [7]u64 {
    const t = s orelse return @splat(0);
    return .{ 1, @intFromBool(t.file), @intCast(t.stream + 1), @bitCast(t.ts), @intFromBool(t.flags.backward), @intFromBool(t.flags.any), @intFromBool(t.flags.byte) };
}

/// The read-ahead, then up to `plan.max_packets` packets, with the seek
/// after the first; the packets returned. Only running out of memory
/// fails it: a demuxer's error ends the reading, as a refused seek ends
/// the seek.
pub fn runTestPlan(comptime Source: type, gpa: std.mem.Allocator, src: *Source, plan: TestPlan) error{OutOfMemory}!u32 {
    var l = demux.Layer(Source).init(gpa, src);
    defer l.deinit();
    l.findStreamInfo() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    var count: u32 = 0;
    while (count < plan.max_packets) : (count += 1) {
        const p = l.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return count,
        } orelse return count;
        if (p.stream >= src.streamCount()) @panic("a packet of a stream the demuxer does not have");
        if (count != 0) continue;
        const s = plan.seek orelse continue;
        const result = if (s.file)
            l.seekFile(s.stream, if (s.exact) s.ts else std.math.minInt(i64), s.ts, if (s.exact) s.ts else std.math.maxInt(i64), s.flags)
        else
            l.seekFrame(s.stream, s.ts, s.flags);
        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    return count;
}

/// Runs `test_fn(gpa, extra_args...)` failing each allocation in turn,
/// every resize failing; prints the failed allocation's stack when its
/// error is swallowed or memory leaks. A result besides the error is
/// ignored.
pub fn checkAll(comptime test_fn: anytype, extra_args: anytype) !void {
    const no_resize: std.testing.FailingAllocator.Config = .{ .resize_fail_index = 0 };
    const needed = needed: {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, no_resize);
        _ = try @call(.auto, test_fn, .{failing.allocator()} ++ extra_args);
        break :needed failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        const result = @call(.auto, test_fn, .{failing.allocator()} ++ extra_args);
        if (result) |_| {
            if (!failing.has_induced_failure) return error.NondeterministicMemoryUsage;
        } else |err| if (err != error.OutOfMemory) return err;
        const swallowed = if (result) |_| true else |_| false;
        if (swallowed or failing.allocated_bytes != failing.freed_bytes) {
            std.debug.print("fail_index {d}/{d}: {s}; {d} bytes allocated, {d} freed; the failed allocation:\n{f}", .{
                fail_index,
                needed,
                if (swallowed) "OutOfMemory swallowed" else "leak",
                failing.allocated_bytes,
                failing.freed_bytes,
                std.debug.FormatStackTrace{ .stack_trace = failing.getStackTrace() },
            });
            return if (swallowed) error.SwallowedOutOfMemoryError else error.MemoryLeakDetected;
        }
    }
}

/// A corpus entry whose first `Smith.slice` is `bytes` and whose next
/// `Smith.value*` calls return `values` in turn.
pub fn fuzzSeed(comptime bytes: []const u8, comptime values: []const u64) []const u8 {
    return comptime seed: {
        @setEvalBranchQuota(10 * bytes.len + 1000);
        var out: []const u8 = &littleEndian(u32, @intCast(bytes.len));
        out = out ++ bytes;
        for (values) |v| out = out ++ &littleEndian(u64, v);
        const done = out[0..out.len].*;
        break :seed &done;
    };
}

/// The most bytes a mutation adds to a seed's slice: callbacks size their
/// input buffers for the largest seed plus this.
pub const max_growth = 256;

/// Runs `testOne` on `rounds` mutations of each seed (`fuzzSeed`'s
/// layout), from a PRNG seeded with `prng_seed`.
pub fn mutationSmoke(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *std.testing.Smith) anyerror!void,
    seeds: []const []const u8,
    rounds: u32,
    prng_seed: u64,
) !void {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(prng_seed);
    const random = prng.random();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    for (seeds) |seed| {
        if (seed.len < 4) continue;
        const seed_len = @min(std.mem.readInt(u32, seed[0..4], .little), seed.len - 4);
        const original = seed[4..][0..seed_len];
        const values = seed[4 + seed_len ..];
        for (0..rounds) |_| {
            body.clearRetainingCapacity();
            try body.appendSlice(gpa, original);
            try mutate(gpa, random, &body);
            input.clearRetainingCapacity();
            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_bytes, @intCast(body.items.len), .little);
            try input.appendSlice(gpa, &len_bytes);
            try input.appendSlice(gpa, body.items);
            try input.appendSlice(gpa, values);
            // Now and then one of the values changes too.
            if (values.len >= 8 and random.uintLessThan(u8, 4) == 0) {
                const at = input.items.len - values.len + 8 * random.uintLessThan(usize, values.len / 8);
                const v: u64 = if (random.boolean()) random.uintLessThan(u64, 4) else random.int(u64);
                std.mem.writeInt(u64, input.items[at..][0..8], v, .little);
            }
            var smith: std.testing.Smith = .{ .in = input.items };
            try testOne(context, &smith);
        }
    }
}

/// One to four edits: bytes overwritten, a bit flipped, the end cut off,
/// a span removed or a span repeated (at most `max_growth` bytes).
fn mutate(gpa: std.mem.Allocator, random: std.Random, body: *std.ArrayList(u8)) !void {
    var grown: usize = 0;
    for (0..1 + random.uintLessThan(u8, 4)) |_| {
        const len = body.items.len;
        if (len == 0) return;
        switch (random.uintLessThan(u8, 5)) {
            0 => for (0..1 + random.uintLessThan(u8, 8)) |_| {
                body.items[random.uintLessThan(usize, len)] = random.int(u8);
            },
            1 => body.items[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3),
            2 => body.shrinkRetainingCapacity(random.uintLessThan(usize, len)),
            3 => {
                const start = random.uintLessThan(usize, len);
                const end = start + random.uintAtMost(usize, @min(len - start, 64));
                body.replaceRangeAssumeCapacity(start, end - start, &.{});
            },
            else => {
                if (grown >= max_growth) continue;
                const start = random.uintLessThan(usize, len);
                const span = random.uintAtMost(usize, @min(len - start, max_growth - grown));
                const at = random.uintAtMost(usize, len);
                var copy: [max_growth]u8 = undefined;
                @memcpy(copy[0..span], body.items[start..][0..span]);
                try body.insertSlice(gpa, at, copy[0..span]);
                grown += span;
            },
        }
    }
}

fn littleEndian(comptime T: type, comptime value: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, value, .little);
    return out;
}

test fuzzSeed {
    const seed = fuzzSeed("ab", &.{3});
    var smith: std.testing.Smith = .{ .in = seed };
    var buf: [4]u8 = undefined;
    const len = smith.slice(&buf);
    try std.testing.expectEqualStrings("ab", buf[0..len]);
    try std.testing.expectEqual(3, smith.valueRangeAtMost(u8, 0, 7));
    // Past the seed's values every value is its range's least.
    try std.testing.expectEqual(0, smith.valueRangeAtMost(u8, 0, 7));
}

test checkAll {
    try checkAll(struct {
        fn run(gpa: std.mem.Allocator, n: usize) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(gpa);
            for (0..n) |i| try list.append(gpa, @truncate(i));
            const owned = try list.toOwnedSlice(gpa);
            gpa.free(owned);
        }
    }.run, .{100});
}
