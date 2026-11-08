// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/demux_utils.c (avpriv_new_chapter) and
// libavformat/demux.c (compute_chapters_end, chapter_start_cmp) at the
// pinned reference revision.
// Copyright (c) 2000-2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! A format's chapters as libavformat keeps them (`AVFormatContext`'s
//! `chapters`, TODO.md T33a2): `avpriv_new_chapter`, which makes a chapter
//! or retitles the one with the same id, and `compute_chapters_end`, which
//! avformat_find_stream_info runs to end each chapter without one at the
//! next chapter's start or the format's end.

const std = @import("std");
const rational = @import("../core/rational.zig");
const metadata = @import("../core/metadata.zig");

const nopts: i64 = std.math.minInt(i64);

/// An `AVChapter`.
pub const Chapter = struct {
    id: i64,
    time_base: rational.Rational,
    start: i64,
    /// `AV_NOPTS_VALUE` until `computeEnds`.
    end: i64,
    tags: metadata.Dictionary = .empty,
};

pub const Chapters = struct {
    items: std.ArrayList(Chapter) = .empty,
    /// `chapter_ids_monotonic`: every id so far above the one before.
    monotonic: bool = false,
    /// The last chapter made with each id: where FFmpeg's search over every
    /// chapter, which keeps the last match, lands, without the search.
    by_id: std.AutoHashMapUnmanaged(i64, usize) = .empty,

    pub fn deinit(c: *Chapters, gpa: std.mem.Allocator) void {
        for (c.items.items) |*ch| ch.tags.deinit(gpa);
        c.items.deinit(gpa);
        c.by_id.deinit(gpa);
    }

    /// avpriv_new_chapter: none when it ends before it starts; else the
    /// chapter with `id` again (when the ids are not rising, or this one
    /// does not rise) or a new one, given `title` (none removes it) and
    /// the times.
    pub fn add(c: *Chapters, gpa: std.mem.Allocator, id: i64, time_base: rational.Rational, start: i64, end: i64, title: ?[]const u8) error{OutOfMemory}!void {
        if (end != nopts and start > end) return;
        var found: ?usize = null;
        const list = c.items.items;
        if (list.len == 0) {
            c.monotonic = true;
        } else if (!c.monotonic or list[list.len - 1].id >= id) {
            found = c.by_id.get(id);
            if (found == null) c.monotonic = false;
        }
        const index = found orelse blk: {
            try c.items.ensureUnusedCapacity(gpa, 1);
            try c.by_id.ensureUnusedCapacity(gpa, 1);
            c.items.appendAssumeCapacity(.{ .id = id, .time_base = time_base, .start = start, .end = end });
            const i = c.items.items.len - 1;
            c.by_id.putAssumeCapacity(id, i);
            break :blk i;
        };
        const ch = &c.items.items[index];
        if (title) |t| {
            // A C string: the title ends at its first NUL.
            const cut = t[0 .. std.mem.findScalar(u8, t, 0) orelse t.len];
            ch.tags.put(gpa, "title", cut, .replace) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTag => unreachable, // cut at its NUL; the key is a literal
            };
        } else {
            _ = ch.tags.remove(gpa, "title");
        }
        ch.id = id;
        ch.time_base = time_base;
        ch.start = start;
        ch.end = end;
    }

    /// compute_chapters_end from the format's start time and duration
    /// (AV_TIME_BASE units, `AV_NOPTS_VALUE` when unknown): each chapter
    /// without an end, in start order, ends at the next one's start when
    /// that is later and before the format's end, else at the format's end
    /// (its own start when that is unknown or earlier).
    pub fn computeEnds(c: *Chapters, gpa: std.mem.Allocator, start_time: i64, duration: i64) error{OutOfMemory}!void {
        const list = c.items.items;
        if (list.len == 0) return;
        var max_time: i64 = 0;
        if (duration > 0 and start_time < std.math.maxInt(i64) - duration)
            max_time = duration + (if (start_time == nopts) 0 else start_time);
        const order = try gpa.alloc(usize, list.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        std.sort.pdq(usize, order, list, startLessThan);
        for (order, 0..) |at, i| {
            const ch = &list[at];
            if (ch.end != nopts) continue;
            var end: i64 = if (max_time != 0) rational.rescaleQ(max_time, .{ .num = 1, .den = 1_000_000 }, ch.time_base) else std.math.maxInt(i64);
            if (i + 1 < order.len) {
                const next = &list[order[i + 1]];
                const next_start = rational.rescaleQ(next.start, next.time_base, ch.time_base);
                if (next_start > ch.start and next_start < end) end = next_start;
            }
            ch.end = if (end == std.math.maxInt(i64) or end < ch.start) ch.start else end;
        }
    }

    /// chapter_start_cmp: by start, then by id (ids are distinct, so the
    /// order is total and qsort's instability does not show).
    fn startLessThan(list: []const Chapter, a: usize, b: usize) bool {
        const x = &list[a];
        const y = &list[b];
        const delta = rational.compareTs(x.start, x.time_base, y.start, y.time_base);
        if (delta != 0) return delta < 0;
        return x.id < y.id;
    }
};

const testing = std.testing;

test "avpriv_new_chapter: the same id retitles its chapter, a falling id searches, a bad range makes none" {
    const gpa = testing.allocator;
    var c: Chapters = .{};
    defer c.deinit(gpa);
    const tb: rational.Rational = .{ .num = 1, .den = 1000 };
    try c.add(gpa, 0, tb, 0, nopts, "a");
    try c.add(gpa, 1, tb, 10, nopts, "b");
    try c.add(gpa, 2, tb, 30, 20, "bad");
    try testing.expectEqual(2, c.items.items.len);
    // A falling id that exists: that chapter, retitled and moved.
    try c.add(gpa, 0, tb, 5, nopts, "a2\x00cut");
    try testing.expectEqual(2, c.items.items.len);
    try testing.expectEqualStrings("a2", c.items.items[0].tags.get("title").?);
    try testing.expectEqual(5, c.items.items[0].start);
    // No title removes it.
    try c.add(gpa, 1, tb, 10, nopts, null);
    try testing.expectEqual(null, c.items.items[1].tags.get("title"));
    // A new id after a search: no longer monotonic, so 7 then 7 again is one.
    try c.add(gpa, 7, tb, 40, nopts, "x");
    try c.add(gpa, 7, tb, 41, nopts, "y");
    try testing.expectEqual(3, c.items.items.len);
    try c.computeEnds(gpa, 0, 50_000);
    try testing.expectEqual(10, c.items.items[0].end);
    try testing.expectEqual(41, c.items.items[1].end);
    try testing.expectEqual(50, c.items.items[2].end);
}

test "compute_chapters_end: no duration ends a chapter at its own start or the next one's" {
    const gpa = testing.allocator;
    var c: Chapters = .{};
    defer c.deinit(gpa);
    try c.add(gpa, 0, .{ .num = 1, .den = 10 }, 20, nopts, "late");
    try c.add(gpa, 1, .{ .num = 1, .den = 100 }, 50, nopts, "early");
    try c.computeEnds(gpa, nopts, nopts);
    // Sorted by start: 0.5 s, then 2 s.
    try testing.expectEqual(200, c.items.items[1].end);
    try testing.expectEqual(20, c.items.items[0].end);
}
