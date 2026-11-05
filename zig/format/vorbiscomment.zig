// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/oggparsevorbis.c (ff_vorbis_comment,
// vorbis_parse_single_comment, ogm_chapter), metadata.c (ff_metadata_conv)
// and vorbiscomment.c (ff_vorbiscomment_metadata_conv) at the pinned
// reference revision describe the behavior, restated here.
//! Vorbis comments as FFmpeg reads them for Ogg streams (TODO.md T27a):
//! the vendor string, then `KEY=value` comments into a tag dictionary,
//! a repeated key's values joined with `;`, then five keys renamed.
//!
//! A comment is a C string to FFmpeg, so a NUL ends it. A comment without
//! `=`, or with an empty key or value, is not a tag; neither is a picture
//! (`METADATA_BLOCK_PICTURE`, which FFmpeg makes an attached-picture
//! stream) nor an OGM chapter (`CHAPTERnnn` and `CHAPTERnnnNAME`, which
//! FFmpeg makes chapters): the port has no picture streams or chapters
//! yet, so it drops them (port.md "Ogg contract"). The FLAC demuxer reads
//! its VORBIS_COMMENT blocks here too, as FFmpeg's calls ff_vorbis_comment.
//!
//! A key repeated n times costs time linear in its values' length: the
//! comments of one call gather in a working list whose values grow in
//! place, where joining the whole value again on every repeat would be
//! quadratic.

const std = @import("std");
const metadata = @import("../core/metadata.zig");

pub const Error = error{
    /// Shorter than the vendor length and the comment count, or a vendor
    /// string that does not fit (FFmpeg's AVERROR_INVALIDDATA).
    InvalidComment,
    OutOfMemory,
};

/// ff_vorbiscomment_metadata_conv: the VORBIS_COMMENT names and FFmpeg's.
const conv = [_]struct { native: []const u8, generic: []const u8 }{
    .{ .native = "ALBUMARTIST", .generic = "album_artist" },
    .{ .native = "TRACKNUMBER", .generic = "track" },
    .{ .native = "DISCNUMBER", .generic = "disc" },
    .{ .native = "DISCSUBTITLE", .generic = "disc_subtitle" },
    .{ .native = "DESCRIPTION", .generic = "comment" },
};

/// The chapters a demuxer has made (FFmpeg's `AVFormatContext`
/// chapters): their numbers, which a later `CHAPTERnnnNAME` refers to.
/// OGM chapter comments add theirs; FLAC's CUESHEET adds its tracks'.
pub const Chapters = struct {
    ids: std.ArrayList(i32) = .empty,

    pub fn deinit(c: *Chapters, gpa: std.mem.Allocator) void {
        c.ids.deinit(gpa);
    }

    fn has(c: *const Chapters, id: i32) bool {
        return std.mem.findScalar(i32, c.ids.items, id) != null;
    }

    /// avpriv_new_chapter's identity: a number already made is that
    /// chapter again, not a new one.
    pub fn add(c: *Chapters, gpa: std.mem.Allocator, id: i32) error{OutOfMemory}!void {
        if (!c.has(id)) try c.ids.append(gpa, id);
    }
};

/// A comment's key and value as vorbis_parse_single_comment reads them.
pub const Comment = struct {
    key: []const u8,
    value: []const u8,
};

/// vorbis_parse_single_comment's split: at the first `=`, null without one
/// or with nothing before or after it. FFmpeg puts NULs where '=' and the
/// end are, so an earlier NUL ends the key or the value as a C string.
pub fn splitComment(raw: []const u8) ?Comment {
    const eq = std.mem.findScalar(u8, raw, '=') orelse return null;
    const key_full = raw[0..eq];
    const value_full = raw[eq + 1 ..];
    if (key_full.len == 0 or value_full.len == 0) return null;
    return .{
        .key = key_full[0 .. std.mem.findScalar(u8, key_full, 0) orelse key_full.len],
        .value = value_full[0 .. std.mem.findScalar(u8, value_full, 0) orelse value_full.len],
    };
}

/// The dictionary while one call's comments are added: FFmpeg's entry
/// order, with values that grow in place. Keys are borrowed from the
/// dictionary being rebuilt or from the comment buffer, both alive until
/// `parse` returns.
const Pending = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        key: []const u8,
        value: std.ArrayList(u8),
    };

    fn deinit(p: *Pending, gpa: std.mem.Allocator) void {
        for (p.entries.items) |*e| e.value.deinit(gpa);
        p.entries.deinit(gpa);
    }

    /// The first entry whose key matches, as `av_dict_get` without
    /// AV_DICT_MATCH_CASE.
    fn find(p: *const Pending, key: []const u8) ?usize {
        for (p.entries.items, 0..) |e, i| {
            if (std.ascii.eqlIgnoreCase(e.key, key)) return i;
        }
        return null;
    }

    /// An entry appended as it stands (the dictionary's own entries).
    fn add(p: *Pending, gpa: std.mem.Allocator, key: []const u8, value: []const u8) error{OutOfMemory}!void {
        try p.entries.ensureUnusedCapacity(gpa, 1);
        var v: std.ArrayList(u8) = .empty;
        try v.appendSlice(gpa, value);
        p.entries.appendAssumeCapacity(.{ .key = key, .value = v });
    }

    /// `av_dict_set` with AV_DICT_APPEND: an entry with the key gets
    /// `value` added to its own and is replaced, under the new key's
    /// spelling, by the joined value: the last entry moves into its place
    /// and the joined one goes last. Without one, a new entry goes last.
    fn append(p: *Pending, gpa: std.mem.Allocator, key: []const u8, value: []const u8) error{OutOfMemory}!void {
        const index = p.find(key) orelse return p.add(gpa, key, value);
        try p.entries.items[index].value.appendSlice(gpa, value);
        var entry = p.entries.swapRemove(index);
        entry.key = key;
        // swapRemove freed the slot this takes.
        p.entries.appendAssumeCapacity(entry);
    }
};

/// `ff_vorbis_comment` into `tags`: returns how many comments became tags
/// (FFmpeg's `updates`). Comments past the end, or a count past them,
/// are not an error, as FFmpeg only logs them.
/// On failure `tags` is unchanged; `chapters` may hold the chapters of
/// comments read before it.
pub fn parse(gpa: std.mem.Allocator, tags: *metadata.Dictionary, chapters: *Chapters, buf: []const u8) Error!usize {
    if (buf.len < 8) return error.InvalidComment;
    var p: usize = 0;
    const vendor = std.mem.readInt(u32, buf[0..4], .little);
    p = 4;
    // `end - p - 4 < s || s < 0`, the vendor length read as a signed int.
    if (vendor > std.math.maxInt(i32) or buf.len - p - 4 < vendor) return error.InvalidComment;
    p += vendor;
    var n = std.mem.readInt(u32, buf[p..][0..4], .little);
    p += 4;
    var pending: Pending = .{};
    defer pending.deinit(gpa);
    try pending.entries.ensureTotalCapacity(gpa, tags.count());
    for (tags.items()) |entry| try pending.add(gpa, entry.key, entry.value);
    var updates: usize = 0;
    while (buf.len - p >= 4 and n > 0) : (n -= 1) {
        const s = std.mem.readInt(u32, buf[p..][0..4], .little);
        p += 4;
        if (buf.len - p < s or s > std.math.maxInt(i32)) break;
        if (try single(gpa, &pending, chapters, buf[p..][0..s])) updates += 1;
        p += s;
    }
    const converted = try convert(gpa, &pending);
    tags.deinit(gpa);
    tags.* = converted;
    return updates;
}

/// vorbis_parse_single_comment: true when the comment became a tag.
fn single(gpa: std.mem.Allocator, pending: *Pending, chapters: *Chapters, raw: []const u8) Error!bool {
    const c = splitComment(raw) orelse return false;
    if (std.ascii.eqlIgnoreCase(c.key, "METADATA_BLOCK_PICTURE")) return false;
    if (try ogmChapter(gpa, chapters, c.key, c.value)) return false;
    if (pending.find(c.key) != null) try pending.append(gpa, c.key, ";");
    try pending.append(gpa, c.key, c.value);
    return true;
}

/// `ogm_chapter`: `CHAPTER` and a number (`%03d`) with a time
/// (`%02d:%02d:%02d.%03d`) in a key of at most 10 characters makes a
/// chapter; `CHAPTERnnnNAME` names one already made. Either is not a tag.
fn ogmChapter(gpa: std.mem.Allocator, chapters: *Chapters, key: []const u8, value: []const u8) Error!bool {
    if (key.len < 9 or !std.ascii.eqlIgnoreCase(key[0..7], "CHAPTER")) return false;
    const id = (scanInt(key[7..], 3) orelse return false).value;
    if (key.len <= 10) {
        var rest = value;
        for (0..4) |field| {
            const width: usize = if (field == 3) 3 else 2;
            const got = scanInt(rest, width) orelse return false;
            rest = rest[got.used..];
            if (field < 3) {
                const sep: u8 = if (field == 2) '.' else ':';
                if (rest.len == 0 or rest[0] != sep) return false;
                rest = rest[1..];
            }
        }
        try chapters.add(gpa, id);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key[key.len - 4 ..], "NAME")) return chapters.has(id);
    return false;
}

/// sscanf's `%<width>d`: white space skipped, then a sign and digits in
/// at most `width` characters, at least one digit.
fn scanInt(text: []const u8, width: usize) ?struct { value: i32, used: usize } {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    const start = i;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var value: i32 = 0;
    var digits: usize = 0;
    while (i < text.len and i - start < width and std.ascii.isDigit(text[i])) : (i += 1) {
        value = value * 10 + (text[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return .{ .value = if (negative) -value else value, .used = i };
}

/// ff_metadata_conv from the VORBIS_COMMENT names: the dictionary
/// rebuilt in order with AV_DICT_MULTIKEY | AV_DICT_DEDUP.
fn convert(gpa: std.mem.Allocator, pending: *const Pending) Error!metadata.Dictionary {
    var out: metadata.Dictionary = .empty;
    errdefer out.deinit(gpa);
    for (pending.entries.items) |entry| {
        var key = entry.key;
        for (conv) |c| {
            if (std.ascii.eqlIgnoreCase(key, c.native)) {
                key = c.generic;
                break;
            }
        }
        out.put(gpa, key, entry.value.items, .keep_distinct) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The dictionary's own entries hold no NUL, and NULs ended
            // the comments' keys and values (`splitComment`).
            error.InvalidTag => unreachable,
        };
    }
    return out;
}

/// ff_metadata_conv into the VORBIS_COMMENT names, as a muxer writes
/// them: `source` rebuilt in order with AV_DICT_MULTIKEY | AV_DICT_DEDUP,
/// FFmpeg's five generic names restored.
pub fn toNative(gpa: std.mem.Allocator, source: *const metadata.Dictionary) error{OutOfMemory}!metadata.Dictionary {
    var out: metadata.Dictionary = .empty;
    errdefer out.deinit(gpa);
    for (source.items()) |entry| {
        var key = entry.key;
        for (conv) |c| {
            if (std.ascii.eqlIgnoreCase(key, c.generic)) {
                key = c.native;
                break;
            }
        }
        out.put(gpa, key, entry.value, .keep_distinct) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The keys and values came from a dictionary.
            error.InvalidTag => unreachable,
        };
    }
    return out;
}

/// `ff_vorbiscomment_length`: the size `write` writes.
pub fn length(vendor: []const u8, tags: *const metadata.Dictionary) u64 {
    var len: u64 = 4 + vendor.len + 4;
    for (tags.items()) |entry| len += 4 + entry.key.len + 1 + entry.value.len;
    return len;
}

/// `ff_vorbiscomment_write` without chapters: the vendor string, the
/// comment count and each `key=value`, lengths little-endian. A tag of
/// 4 GiB or more is the caller's to refuse (`length` tells).
pub fn write(out: *std.Io.Writer, vendor: []const u8, tags: *const metadata.Dictionary) std.Io.Writer.Error!void {
    var field: [4]u8 = undefined;
    std.mem.writeInt(u32, &field, @intCast(vendor.len), .little);
    try out.writeAll(&field);
    try out.writeAll(vendor);
    std.mem.writeInt(u32, &field, @intCast(tags.count()), .little);
    try out.writeAll(&field);
    for (tags.items()) |entry| {
        std.mem.writeInt(u32, &field, @intCast(entry.key.len + 1 + entry.value.len), .little);
        try out.writeAll(&field);
        try out.writeAll(entry.key);
        try out.writeByte('=');
        try out.writeAll(entry.value);
    }
}

const testing = std.testing;

fn comment(gpa: std.mem.Allocator, vendor: []const u8, entries: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(vendor.len), .little);
    try out.appendSlice(gpa, &word);
    try out.appendSlice(gpa, vendor);
    std.mem.writeInt(u32, &word, @intCast(entries.len), .little);
    try out.appendSlice(gpa, &word);
    for (entries) |e| {
        std.mem.writeInt(u32, &word, @intCast(e.len), .little);
        try out.appendSlice(gpa, &word);
        try out.appendSlice(gpa, e);
    }
    return out.toOwnedSlice(gpa);
}

test "comments become tags as FFmpeg's: joined repeats, renamed keys, pictures and chapters dropped" {
    const gpa = testing.allocator;
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    var chapters: Chapters = .{};
    defer chapters.deinit(gpa);
    const buf = try comment(gpa, "vendor", &.{ "TITLE=One", "ARTIST=A", "title=Two", "TRACKNUMBER=3", "noequals", "=empty", "EMPTY=", "METADATA_BLOCK_PICTURE=AAAA", "CHAPTER001=00:00:01.000", "CHAPTER001NAME=Intro", "CHAPTER002NAME=Unknown", "CHAPTER003=soon", "CUT=a\x00b" });
    defer gpa.free(buf);
    // A name for a chapter not made, and a chapter time that does not
    // scan, stay tags, as FFmpeg's ogm_chapter leaves them.
    try testing.expectEqual(7, try parse(gpa, &tags, &chapters, buf));
    try testing.expectEqualStrings("Unknown", tags.get("CHAPTER002NAME").?);
    try testing.expectEqualStrings("soon", tags.get("CHAPTER003").?);
    try testing.expectEqualStrings("One;Two", tags.get("TITLE").?);
    try testing.expectEqualStrings("A", tags.get("ARTIST").?);
    try testing.expectEqualStrings("3", tags.get("track").?);
    try testing.expectEqualStrings("a", tags.get("CUT").?);
    try testing.expectEqual(null, tags.get("CHAPTER001"));
    try testing.expectEqual(6, tags.count());
    try testing.expectError(error.InvalidComment, parse(gpa, &tags, &chapters, "short"));
    try testing.expectError(error.InvalidComment, parse(gpa, &tags, &chapters, &.{ 0xff, 0, 0, 0, 0, 0, 0, 0 }));
}

test "a key repeated many times keeps FFmpeg's joined value and entry order" {
    const gpa = testing.allocator;
    const n = 5000;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(gpa);
    try entries.append(gpa, "A=x");
    try entries.append(gpa, "B=1");
    for (1..n) |_| try entries.append(gpa, "a=x");
    const buf = try comment(gpa, "", entries.items);
    defer gpa.free(buf);
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    try tags.put(gpa, "C", "old", .replace);
    var chapters: Chapters = .{};
    defer chapters.deinit(gpa);
    try testing.expectEqual(n + 1, try parse(gpa, &tags, &chapters, buf));
    // Each repeat moved the key, in its latest spelling, to the end.
    try testing.expectEqual(3, tags.count());
    try testing.expectEqualStrings("C", tags.items()[0].key);
    try testing.expectEqualStrings("B", tags.items()[1].key);
    try testing.expectEqualStrings("a", tags.items()[2].key);
    const value = tags.items()[2].value;
    try testing.expectEqual(2 * n - 1, value.len);
    for (value, 0..) |c, i| {
        const want: u8 = if (i % 2 == 0) 'x' else ';';
        try testing.expectEqual(want, c);
    }
}

test "a parse that runs out of memory leaves the tags as they were" {
    const buf = try comment(testing.allocator, "v", &.{ "TITLE=Two", "ARTIST=A", "TRACKNUMBER=1", "CHAPTER001=00:00:01.000" });
    defer testing.allocator.free(buf);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            var tags: metadata.Dictionary = .empty;
            defer tags.deinit(gpa);
            try tags.put(gpa, "TITLE", "One", .replace);
            var chapters: Chapters = .{};
            defer chapters.deinit(gpa);
            _ = parse(gpa, &tags, &chapters, bytes) catch |err| {
                try testing.expectEqual(1, tags.count());
                try testing.expectEqualStrings("One", tags.get("TITLE").?);
                return err;
            };
            try testing.expectEqualStrings("One;Two", tags.get("TITLE").?);
        }
    }.run, .{buf});
}
