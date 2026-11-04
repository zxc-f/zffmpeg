// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/formats.c (the format lists, MERGE_FORMATS, MERGE_REF,
// merge_channel_layouts_internal, check_list,
// ff_formats_check_channel_layouts) at the pinned reference revision
// describes the behavior, restated here.
//! The format lists a filter graph negotiates with (TODO.md T25a): each
//! link has two sides of lists, the one its source filter set (FFmpeg's
//! `incfg`) and the one its destination filter set (`outcfg`), and a list
//! can be shared by several sides: a filter that keeps the format sets one
//! list on its input and its output, and merging two lists makes every
//! side of either refer to their intersection. A pool holds the lists for
//! one negotiation, in an arena, and the sides of every link.
//!
//! Sample formats are kept as FFmpeg's numbers (`SampleFormat.ffmpegId`),
//! so that a list keeps FFmpeg's order. An empty sample rate list means
//! every rate. A layout list is either generic, every layout and every
//! channel count (`ff_all_channel_counts`), or its entries, of which an
//! unspecified layout stands for its channel count. FFmpeg's other generic
//! list, every known layout (`ff_all_channel_layouts`), is not used by any
//! filter the port has.

const std = @import("std");
const Layout = @import("../core/channel_layout.zig").Layout;

/// The kinds of list, in FFmpeg's merge order (`mergers_audio`).
pub const Kind = enum { layouts, samplerates, formats };

/// A list of the pool.
pub const Id = enum(u32) { _ };

/// One side of a link: a list of each kind, or none yet.
pub const Cfg = struct {
    formats: ?Id = null,
    samplerates: ?Id = null,
    layouts: ?Id = null,

    pub fn slot(c: *Cfg, kind: Kind) *?Id {
        return switch (kind) {
            .formats => &c.formats,
            .samplerates => &c.samplerates,
            .layouts => &c.layouts,
        };
    }
};

/// FFmpeg's `incfg` (`.in`, set by the link's source) and `outcfg` (`.out`,
/// set by its destination).
pub const Side = enum { in, out };

pub const Layouts = struct {
    items: std.ArrayList(Layout) = .empty,
    /// Every layout and channel count; `items` is then empty.
    all: bool = false,
};

const List = union(enum) {
    /// Sample formats or rates.
    values: std.ArrayList(i32),
    layouts: Layouts,
};

/// A list FFmpeg's checks refuse (`filter_check_formats`).
pub const CheckError = error{
    /// "Empty sample format list" or "Empty channel layout list".
    EmptyList,
    /// "Duplicated sample format", "Duplicated sample rate", or
    /// "Duplicated or redundant channel layout".
    DuplicateEntry,
};

pub const Error = std.mem.Allocator.Error;

pub const Pool = struct {
    /// The negotiation's arena: lists are not freed one by one.
    arena: std.mem.Allocator,
    lists: std.ArrayList(List) = .empty,
    /// The two sides of each link, by link index.
    links: std.ArrayList([2]Cfg) = .empty,

    pub fn init(arena: std.mem.Allocator) Pool {
        return .{ .arena = arena };
    }

    /// Adds a link with no lists; returns its index.
    pub fn addLink(p: *Pool) Error!u32 {
        try p.links.append(p.arena, .{ .{}, .{} });
        return @intCast(p.links.items.len - 1);
    }

    pub fn cfg(p: *Pool, link: u32, side: Side) *Cfg {
        return &p.links.items[link][@backingInt(side)];
    }

    pub fn slot(p: *Pool, link: u32, side: Side, kind: Kind) *?Id {
        return p.cfg(link, side).slot(kind);
    }

    /// A new list of sample formats (FFmpeg's numbers) or rates.
    pub fn newValues(p: *Pool, items: []const i32) Error!Id {
        var list: std.ArrayList(i32) = .empty;
        try list.appendSlice(p.arena, items);
        try p.lists.append(p.arena, .{ .values = list });
        return @fromBackingInt(@intCast(p.lists.items.len - 1));
    }

    /// A new list of layouts, or the generic one when `all`.
    pub fn newLayouts(p: *Pool, items: []const Layout, all: bool) Error!Id {
        std.debug.assert(!all or items.len == 0);
        var list: Layouts = .{ .all = all };
        try list.items.appendSlice(p.arena, items);
        try p.lists.append(p.arena, .{ .layouts = list });
        return @fromBackingInt(@intCast(p.lists.items.len - 1));
    }

    pub fn values(p: *Pool, id: Id) *std.ArrayList(i32) {
        return &p.lists.items[@backingInt(id)].values;
    }

    pub fn layouts(p: *Pool, id: Id) *Layouts {
        return &p.lists.items[@backingInt(id)].layouts;
    }

    /// How many sides refer to the list (FFmpeg's `refcount`).
    pub fn refcount(p: *Pool, id: Id, kind: Kind) u32 {
        var count: u32 = 0;
        for (p.links.items) |*sides| {
            for (sides) |*side| {
                if (side.slot(kind).* == id) count += 1;
            }
        }
        return count;
    }

    /// Makes every side that refers to `from` refer to `to` (`MERGE_REF`).
    fn retarget(p: *Pool, kind: Kind, from: Id, to: Id) void {
        for (p.links.items) |*sides| {
            for (sides) |*side| {
                const s = side.slot(kind);
                if (s.* == from) s.* = to;
            }
        }
    }

    /// Whether `a` and `b` can merge (FFmpeg's `can_merge`). As FFmpeg's
    /// does, it merges a generic layout list into the other: its check
    /// path moves the references too, which decides where converters go.
    pub fn canMerge(p: *Pool, kind: Kind, a: Id, b: Id) Error!bool {
        return p.mergeOrCheck(kind, a, b, true);
    }

    /// Merges `a` and `b` into their intersection, which every side of
    /// either then refers to, and returns true; or returns false, both
    /// unchanged, when they have nothing in common.
    pub fn merge(p: *Pool, kind: Kind, a: Id, b: Id) Error!bool {
        return p.mergeOrCheck(kind, a, b, false);
    }

    fn mergeOrCheck(p: *Pool, kind: Kind, a: Id, b: Id, check: bool) Error!bool {
        if (a == b) return true;
        return switch (kind) {
            .formats => p.mergeValues(kind, a, b, check, false),
            .samplerates => p.mergeValues(kind, a, b, check, true),
            .layouts => p.mergeLayouts(a, b, check),
        };
    }

    /// `MERGE_FORMATS`: the entries of `a` also in `b`, in `a`'s order; an
    /// empty list, when `empty_allowed` (rates), is every value.
    fn mergeValues(p: *Pool, kind: Kind, a: Id, b: Id, check: bool, empty_allowed: bool) Error!bool {
        const la = p.values(a);
        const lb = p.values(b);
        if (empty_allowed and (la.items.len == 0 or lb.items.len == 0)) {
            if (check) return true;
            // The survivor is the non-empty list, kept here under `a`.
            if (la.items.len == 0) {
                la.clearRetainingCapacity();
                try la.appendSlice(p.arena, lb.items);
            }
            p.retarget(kind, b, a);
            return true;
        }
        var k: usize = 0;
        for (la.items) |x| {
            for (lb.items) |y| {
                if (x == y) {
                    if (check) return true;
                    la.items[k] = x;
                    k += 1;
                    break;
                }
            }
        }
        if (k == 0) return false;
        la.shrinkRetainingCapacity(k);
        p.retarget(kind, b, a);
        return true;
    }

    /// `merge_channel_layouts_internal`.
    fn mergeLayouts(p: *Pool, a_in: Id, b_in: Id, check: bool) Error!bool {
        var a = a_in;
        var b = b_in;
        // The more generic list first.
        if (!p.layouts(a).all and p.layouts(b).all) std.mem.swap(Id, &a, &b);
        if (p.layouts(a).all) {
            // MERGE_REF(b, a): b survives, even when only checking.
            p.retarget(.layouts, a, b);
            return true;
        }
        const la = p.layouts(a).items.items;
        const lb = p.layouts(b).items.items;
        // Entries a match has used up (FFmpeg uninitializes them, after
        // which they match nothing).
        const used_a = try p.arena.alloc(bool, la.len);
        const used_b = try p.arena.alloc(bool, lb.len);
        @memset(used_a, false);
        @memset(used_b, false);
        var result: std.ArrayList(Layout) = .empty;
        // a[known] intersect b[known].
        for (la, 0..) |*x, i| {
            if (!known(x)) continue;
            for (lb, 0..) |*y, j| {
                if (!used_b[j] and x.eql(y)) {
                    if (check) return true;
                    try result.append(p.arena, x.*);
                    used_a[i] = true;
                    used_b[j] = true;
                    break;
                }
            }
        }
        // a[known] intersect b[generic], then b[known] intersect a[generic].
        for (0..2) |round| {
            const xs = if (round == 0) la else lb;
            const ys = if (round == 0) lb else la;
            const used_x = if (round == 0) used_a else used_b;
            const used_y = if (round == 0) used_b else used_a;
            for (xs, 0..) |*x, i| {
                if (used_x[i] or !known(x)) continue;
                const generic: Layout = .{ .unspecified = x.channelCount() };
                for (ys, 0..) |*y, j| {
                    if (!used_y[j] and y.eql(&generic)) {
                        if (check) return true;
                        try result.append(p.arena, x.*);
                    }
                }
            }
        }
        // a[generic] intersect b[generic].
        for (la, 0..) |*x, i| {
            if (used_a[i] or known(x)) continue;
            for (lb, 0..) |*y, j| {
                if (!used_b[j] and x.eql(y)) {
                    if (check) return true;
                    try result.append(p.arena, x.*);
                }
            }
        }
        if (result.items.len == 0) return false;
        p.layouts(a).items = result;
        p.retarget(.layouts, b, a);
        return true;
    }

    /// `ff_formats_check_sample_formats` (`allow_empty` false) or
    /// `ff_formats_check_sample_rates` (true).
    pub fn checkValues(p: *Pool, id: Id, allow_empty: bool) CheckError!void {
        const items = p.values(id).items;
        if (items.len == 0) return if (allow_empty) {} else error.EmptyList;
        for (items, 0..) |x, i| {
            for (items[i + 1 ..]) |y| {
                if (x == y) return error.DuplicateEntry;
            }
        }
    }

    /// `ff_formats_check_channel_layouts`.
    pub fn checkLayouts(p: *Pool, id: Id) CheckError!void {
        const list = p.layouts(id);
        if (list.all) return;
        const items = list.items.items;
        if (items.len == 0) return error.EmptyList;
        for (items, 0..) |*x, i| {
            for (items[i + 1 ..]) |*y| {
                if (compatible(x, y)) return error.DuplicateEntry;
            }
        }
    }
};

/// FFmpeg's `KNOWN`: a layout of channels, rather than a channel count.
pub fn known(l: *const Layout) bool {
    return l.* != .unspecified;
}

/// `layouts_compatible`: the same, or a count and a layout of that count.
fn compatible(a: *const Layout, b: *const Layout) bool {
    if (a.eql(b)) return true;
    return known(a) != known(b) and a.channelCount() == b.channelCount();
}

/// The sample formats as FFmpeg lists every one (`ff_all_formats`).
pub fn allFormats() [12]i32 {
    var ids: [12]i32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(i);
    return ids;
}

const testing = std.testing;

fn testPool(arena: *std.heap.ArenaAllocator) !Pool {
    var p: Pool = .init(arena.allocator());
    _ = try p.addLink();
    _ = try p.addLink();
    return p;
}

test "values merge into the first list's order and move the references" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p = try testPool(&arena);
    const a = try p.newValues(&.{ 3, 6, 8 });
    const b = try p.newValues(&.{ 8, 6 });
    p.slot(0, .in, .formats).* = a;
    p.slot(0, .out, .formats).* = b;
    p.slot(1, .in, .formats).* = b;
    try testing.expect(try p.canMerge(.formats, a, b));
    try testing.expectEqual(b, p.slot(1, .in, .formats).*.?);
    try testing.expect(try p.merge(.formats, a, b));
    try testing.expectEqualSlices(i32, &.{ 6, 8 }, p.values(a).items);
    try testing.expectEqual(a, p.slot(1, .in, .formats).*.?);
    try testing.expectEqual(3, p.refcount(a, .formats));
    const c = try p.newValues(&.{1});
    try testing.expect(!try p.canMerge(.formats, a, c));
    try testing.expect(!try p.merge(.formats, a, c));
    try testing.expectEqualSlices(i32, &.{ 6, 8 }, p.values(a).items);
}

test "an empty rate list is every rate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p = try testPool(&arena);
    const all = try p.newValues(&.{});
    const one = try p.newValues(&.{44100});
    p.slot(0, .in, .samplerates).* = all;
    p.slot(0, .out, .samplerates).* = one;
    try testing.expect(try p.merge(.samplerates, all, one));
    try testing.expectEqualSlices(i32, &.{44100}, p.values(all).items);
    try testing.expectEqual(all, p.slot(0, .out, .samplerates).*.?);
}

test "layouts merge as FFmpeg merges them, a generic list even when checked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p = try testPool(&arena);
    const stereo = try p.newLayouts(&.{.stereo}, false);
    const all = try p.newLayouts(&.{}, true);
    p.slot(0, .in, .layouts).* = stereo;
    p.slot(0, .out, .layouts).* = all;
    p.slot(1, .in, .layouts).* = all;
    try testing.expect(try p.canMerge(.layouts, stereo, all));
    try testing.expectEqual(stereo, p.slot(1, .in, .layouts).*.?);
    // A count matches a layout of that many channels, which is kept.
    const two: Layout = .{ .unspecified = 2 };
    const counts = try p.newLayouts(&.{ .mono, two }, false);
    p.slot(1, .out, .layouts).* = counts;
    try testing.expect(try p.merge(.layouts, stereo, counts));
    try testing.expectEqual(1, p.layouts(stereo).items.items.len);
    try testing.expect(p.layouts(stereo).items.items[0].eql(&Layout.stereo));
    const three = try p.newLayouts(&.{.{ .unspecified = 3 }}, false);
    try testing.expect(!try p.merge(.layouts, stereo, three));
}

test "lists FFmpeg's checks refuse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p = try testPool(&arena);
    try testing.expectError(error.EmptyList, p.checkValues(try p.newValues(&.{}), false));
    try p.checkValues(try p.newValues(&.{}), true);
    try testing.expectError(error.DuplicateEntry, p.checkValues(try p.newValues(&.{ 1, 2, 1 }), false));
    try testing.expectError(error.DuplicateEntry, p.checkLayouts(try p.newLayouts(&.{ .stereo, .{ .unspecified = 2 } }, false)));
    try testing.expectError(error.EmptyList, p.checkLayouts(try p.newLayouts(&.{}, false)));
    try p.checkLayouts(try p.newLayouts(&.{}, true));
    try p.checkLayouts(try p.newLayouts(&.{ .stereo, .mono }, false));
}
