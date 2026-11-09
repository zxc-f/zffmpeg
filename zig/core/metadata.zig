// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/dict.c at the pinned reference revision describes the behavior
// followed here: key matching, the duplicate-key flags and the entry order.
//! Metadata dictionary (TODO.md T17b): container and stream tags as ordered
//! key/value pairs with owned storage.
//!
//! Keys match ASCII case-insensitively, as `av_dict_get` without
//! `AV_DICT_MATCH_CASE`. Keys and values are byte strings without NUL bytes,
//! because FFmpeg's are C strings; nothing else about them is checked. What
//! `put` does with a key the dictionary already has is an explicit
//! `Duplicates` policy, one per `av_dict_set` flag combination the port uses,
//! and it changes the entry order exactly as FFmpeg does, so tags print in
//! FFmpeg's order.
//!
//! The dictionary is unmanaged: each allocating call takes the allocator, and
//! every call on one dictionary must use the same one. It owns copies of its
//! keys and values. A failing `put` or `clone` leaves the dictionary unchanged
//! and allocates nothing that outlives the call.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    /// A key or value contains a NUL byte, which an FFmpeg tag cannot hold.
    InvalidTag,
};

/// One tag. Both slices are owned by the dictionary and stay valid until the
/// dictionary next changes.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    /// The length of the value's allocation when an `append` left room
    /// after it, else 0 (the allocation is the value). The dictionary's
    /// own bookkeeping: it makes repeated appends linear.
    capacity: usize = 0,
};

/// What `put` does when the dictionary already has an entry with the key.
pub const Duplicates = enum {
    /// FFmpeg's default: the first matching entry is removed, the last entry
    /// moves into its place, and the new entry is appended.
    replace,
    /// Append a second entry with the key (`AV_DICT_MULTIKEY`).
    keep,
    /// Append, unless an entry already has the key and exactly this value
    /// (`AV_DICT_MULTIKEY | AV_DICT_DEDUP`).
    keep_distinct,
    /// Nothing, when an entry already has the key (`AV_DICT_DONT_OVERWRITE`).
    keep_existing,
    /// `AV_DICT_APPEND`: the first entry with the key gets the value added
    /// to its own and is replaced as `replace` replaces it (under the new
    /// key's spelling, last); without one, the entry is added.
    append,
};

pub const Dictionary = struct {
    entries: std.ArrayList(Entry),

    pub const empty: Dictionary = .{ .entries = .empty };

    pub fn deinit(d: *Dictionary, gpa: Allocator) void {
        for (d.entries.items) |entry| freeEntry(gpa, entry);
        d.entries.deinit(gpa);
        d.* = undefined;
    }

    /// Removes every entry and keeps the capacity.
    pub fn clear(d: *Dictionary, gpa: Allocator) void {
        for (d.entries.items) |entry| freeEntry(gpa, entry);
        d.entries.clearRetainingCapacity();
    }

    pub fn count(d: *const Dictionary) usize {
        return d.entries.items.len;
    }

    /// The entries in order; valid until the dictionary next changes.
    pub fn items(d: *const Dictionary) []const Entry {
        return d.entries.items;
    }

    /// The value of the first entry whose key matches.
    pub fn get(d: *const Dictionary, key: []const u8) ?[]const u8 {
        const index = d.find(key, 0) orelse return null;
        return d.entries.items[index].value;
    }

    /// Adds a copy of `key` and `value`, treating an existing key as
    /// `duplicates` says.
    pub fn put(d: *Dictionary, gpa: Allocator, key: []const u8, value: []const u8, duplicates: Duplicates) Error!void {
        try checkTag(key);
        try checkTag(value);
        if (duplicates == .append) if (d.find(key, 0)) |index| return d.appendTo(gpa, index, key, value);
        const replaced: ?usize = switch (duplicates) {
            .replace => d.find(key, 0),
            .keep, .append => null,
            .keep_existing => if (d.find(key, 0) != null) return else null,
            .keep_distinct => blk: {
                var start: usize = 0;
                while (d.find(key, start)) |index| : (start = index + 1) {
                    if (std.mem.eql(u8, d.entries.items[index].value, value)) return;
                }
                break :blk null;
            },
        };
        // Everything that can fail happens before the dictionary changes.
        if (replaced == null) try d.entries.ensureUnusedCapacity(gpa, 1);
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        const owned_value = try gpa.dupe(u8, value);
        if (replaced) |index| freeEntry(gpa, d.entries.swapRemove(index));
        // Either the capacity was ensured, or swapRemove just freed a slot.
        d.entries.appendAssumeCapacity(.{ .key = owned_key, .value = owned_value });
    }

    /// `append` to the entry at `index`: its value grows in place (by
    /// doubling, so repeated appends stay linear), then the entry moves
    /// last under `key`'s spelling.
    fn appendTo(d: *Dictionary, gpa: Allocator, index: usize, key: []const u8, value: []const u8) Error!void {
        const old = d.entries.items[index];
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        const len = std.math.add(usize, old.value.len, value.len) catch return error.OutOfMemory;
        // `put` accepts borrowed values from this dictionary. Remember an
        // aliased range before realloc can move and free its allocation.
        const base = @intFromPtr(old.value.ptr);
        const source = @intFromPtr(value.ptr);
        const offset: ?usize = if (source >= base and source - base <= old.value.len and
            value.len <= old.value.len - (source - base)) source - base else null;
        var storage = storageOf(old);
        if (len > storage.len) {
            const grown = @max(len, storage.len *| 2, 16);
            // On failure the old storage stays the entry's.
            storage = try gpa.realloc(storage, grown);
        }
        const fragment = if (offset) |at| storage[at..][0..value.len] else value;
        @memcpy(storage[old.value.len..len], fragment);
        gpa.free(old.key);
        _ = d.entries.swapRemove(index);
        // swapRemove freed the slot this takes.
        d.entries.appendAssumeCapacity(.{ .key = owned_key, .value = storage[0..len], .capacity = storage.len });
    }

    /// Removes the first entry whose key matches, as `av_dict_set` with no
    /// value: the last entry moves into its place. Returns whether one did.
    pub fn remove(d: *Dictionary, gpa: Allocator, key: []const u8) bool {
        const index = d.find(key, 0) orelse return false;
        freeEntry(gpa, d.entries.swapRemove(index));
        return true;
    }

    /// An independent copy with the same entries in the same order.
    pub fn clone(d: *const Dictionary, gpa: Allocator) Allocator.Error!Dictionary {
        var copy: Dictionary = .empty;
        errdefer copy.deinit(gpa);
        try copy.entries.ensureTotalCapacity(gpa, d.count());
        for (d.entries.items) |entry| {
            const key = try gpa.dupe(u8, entry.key);
            errdefer gpa.free(key);
            const value = try gpa.dupe(u8, entry.value);
            copy.entries.appendAssumeCapacity(.{ .key = key, .value = value });
        }
        return copy;
    }

    /// The first entry at or after `start` whose key matches.
    fn find(d: *const Dictionary, key: []const u8, start: usize) ?usize {
        for (d.entries.items[start..], start..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.key, key)) return index;
        }
        return null;
    }
};

fn checkTag(bytes: []const u8) error{InvalidTag}!void {
    if (std.mem.findScalar(u8, bytes, 0) != null) return error.InvalidTag;
}

/// The allocation an entry's value lives in.
fn storageOf(entry: Entry) []u8 {
    // The dictionary allocated it; `value` is a const view of it.
    return @constCast(entry.value.ptr)[0..@max(entry.value.len, entry.capacity)];
}

fn freeEntry(gpa: Allocator, entry: Entry) void {
    gpa.free(entry.key);
    gpa.free(storageOf(entry));
}

fn expectValue(d: *const Dictionary, key: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, d.get(key) orelse return error.TestExpectedValue);
}

/// Checks the entries, in order, against `expected` key/value pairs.
fn expectEntries(d: *const Dictionary, expected: []const [2][]const u8) !void {
    try std.testing.expectEqual(expected.len, d.count());
    for (expected, d.items()) |want, entry| {
        try std.testing.expectEqualStrings(want[0], entry.key);
        try std.testing.expectEqualStrings(want[1], entry.value);
    }
}

test "replace keeps FFmpeg's order: the last entry fills the gap and the new one is appended" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "a", "1", .replace);
    try d.put(gpa, "b", "2", .replace);
    try d.put(gpa, "c", "3", .replace);
    try d.put(gpa, "d", "4", .replace);
    // av_dict_set("B", "5"): elems[1] = elems[3], then append.
    try d.put(gpa, "B", "5", .replace);
    try expectEntries(&d, &.{ .{ "a", "1" }, .{ "d", "4" }, .{ "c", "3" }, .{ "B", "5" } });
    // Replacing the last entry keeps it last.
    try d.put(gpa, "b", "6", .replace);
    try expectEntries(&d, &.{ .{ "a", "1" }, .{ "d", "4" }, .{ "c", "3" }, .{ "b", "6" } });
}

test "keys match ASCII case-insensitively; get and replace take the first match" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "Title", "one", .keep);
    try d.put(gpa, "TITLE", "two", .keep);
    try expectValue(&d, "title", "one");
    try std.testing.expectEqual(null, d.get("titl"));
    try std.testing.expectEqual(null, d.get("titles"));
    // Only the first of the two is replaced.
    try d.put(gpa, "title", "three", .replace);
    try expectEntries(&d, &.{ .{ "TITLE", "two" }, .{ "title", "three" } });
    // Non-ASCII bytes compare exactly.
    try d.put(gpa, "\xc3\xa9", "e", .keep);
    try std.testing.expectEqual(null, d.get("\xc3\x89"));
}

test "keep appends every duplicate; keep_distinct skips an equal key and value" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "track", "1", .keep);
    try d.put(gpa, "track", "1", .keep);
    try d.put(gpa, "TRACK", "1", .keep_distinct);
    try d.put(gpa, "track", "2", .keep_distinct);
    try expectEntries(&d, &.{ .{ "track", "1" }, .{ "track", "1" }, .{ "track", "2" } });
    // Values compare exactly, unlike keys.
    try d.put(gpa, "track", "X", .keep_distinct);
    try d.put(gpa, "track", "x", .keep_distinct);
    try std.testing.expectEqual(5, d.count());
}

test "append joins values as AV_DICT_APPEND, moving the entry last under the new spelling" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "artist", "A", .append);
    try d.put(gpa, "x", "1", .replace);
    try d.put(gpa, "y", "2", .replace);
    try d.put(gpa, "ARTIST", ";", .append);
    try expectEntries(&d, &.{ .{ "y", "2" }, .{ "x", "1" }, .{ "ARTIST", "A;" } });
    try d.put(gpa, "artist", "B", .append);
    try expectEntries(&d, &.{ .{ "y", "2" }, .{ "x", "1" }, .{ "artist", "A;B" } });
    // Many appends grow one allocation; the clone copies the value alone.
    for (0..1000) |_| try d.put(gpa, "artist", "xy", .append);
    try std.testing.expectEqual(3 + 2000, d.get("artist").?.len);
    var copy = try d.clone(gpa);
    defer copy.deinit(gpa);
    try expectValue(&copy, "artist", d.get("artist").?);
    try d.put(gpa, "artist", "", .replace);
    try expectValue(&d, "artist", "");
}

fn appendAliases(gpa: Allocator) !void {
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "tag", "0123456789abcdef", .replace);
    try d.put(gpa, "other", "value", .replace);
    const entry = d.items()[0];
    d.put(gpa, entry.key, entry.value, .append) catch |err| {
        try expectEntries(&d, &.{ .{ "tag", "0123456789abcdef" }, .{ "other", "value" } });
        return err;
    };
    try expectEntries(&d, &.{ .{ "other", "value" }, .{ "tag", "0123456789abcdef0123456789abcdef" } });
    const previous = d.get("tag").?;
    try d.put(gpa, "tag", previous[2..6], .append);
    try expectValue(&d, "tag", "0123456789abcdef0123456789abcdef2345");
    // Spare capacity: this append must also accept an aliased substring.
    try d.put(gpa, "tag", d.get("tag").?[0..2], .append);
    try expectValue(&d, "tag", "0123456789abcdef0123456789abcdef234501");
}

test "metadata append rebases borrowed values and keys across moving growth" {
    try appendAliases(std.testing.allocator);
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try appendAliases(moving.allocator());
    try @import("../testing/hostile.zig").checkAll(appendAliases, .{});
}

test "remove takes the first match and moves the last entry into its place" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c", "b" }, 0..) |key, i| {
        const digit: u8 = @intCast(i);
        const value: [1]u8 = .{'0' + digit};
        try d.put(gpa, key, &value, .keep);
    }
    try std.testing.expect(d.remove(gpa, "B"));
    try expectEntries(&d, &.{ .{ "a", "0" }, .{ "b", "3" }, .{ "c", "2" } });
    try std.testing.expect(!d.remove(gpa, "z"));
    d.clear(gpa);
    try std.testing.expectEqual(0, d.count());
}

test "the dictionary owns copies; a clone is independent" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    var key: [3]u8 = "key".*;
    var value: [5]u8 = "value".*;
    try d.put(gpa, &key, &value, .replace);
    @memset(&key, 'x');
    @memset(&value, 'y');
    try expectValue(&d, "KEY", "value");

    var copy = try d.clone(gpa);
    defer copy.deinit(gpa);
    try d.put(gpa, "key", "changed", .replace);
    try expectValue(&copy, "key", "value");
    try std.testing.expectEqual(1, copy.count());
}

test "NUL bytes are rejected, empty keys and values are kept" {
    const gpa = std.testing.allocator;
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    try std.testing.expectError(error.InvalidTag, d.put(gpa, "a\x00b", "v", .replace));
    try std.testing.expectError(error.InvalidTag, d.put(gpa, "k", "v\x00", .keep));
    try std.testing.expectEqual(0, d.count());
    try d.put(gpa, "", "", .replace);
    try expectValue(&d, "", "");
}

/// Builds a dictionary through every policy, then clones it; under each
/// induced allocation failure the calls before it must have taken effect and
/// the failing call none.
fn buildUnderFailures(gpa: Allocator) !void {
    var d: Dictionary = .empty;
    defer d.deinit(gpa);
    const steps = [_]struct { key: []const u8, value: []const u8, duplicates: Duplicates }{
        .{ .key = "a", .value = "1", .duplicates = .replace },
        .{ .key = "b", .value = "2", .duplicates = .keep },
        .{ .key = "A", .value = "3", .duplicates = .replace },
        .{ .key = "b", .value = "2", .duplicates = .keep_distinct },
        .{ .key = "b", .value = "4", .duplicates = .keep_distinct },
        .{ .key = "c", .value = "x", .duplicates = .append },
        .{ .key = "C", .value = "yz", .duplicates = .append },
    };
    for (steps) |step| {
        var saved = try d.clone(gpa);
        defer saved.deinit(gpa);
        d.put(gpa, step.key, step.value, step.duplicates) catch |err| {
            // A failed put changed nothing.
            try std.testing.expectEqual(saved.count(), d.count());
            for (saved.items(), d.items()) |want, got| {
                try std.testing.expectEqualStrings(want.key, got.key);
                try std.testing.expectEqualStrings(want.value, got.value);
            }
            return err;
        };
    }
    try expectEntries(&d, &.{ .{ "b", "2" }, .{ "A", "3" }, .{ "b", "4" }, .{ "C", "xyz" } });
    var copy = try d.clone(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqual(4, copy.count());
}

test "every allocation failure leaves the dictionary unchanged and leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildUnderFailures, .{});
}
