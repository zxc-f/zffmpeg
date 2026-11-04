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
//! yet, so it drops them (port.md "Ogg contract").

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

/// The OGM chapters a demuxer has seen (FFmpeg's `AVFormatContext`
/// chapters): their numbers, which a later `CHAPTERnnnNAME` refers to.
pub const Chapters = struct {
    ids: std.ArrayList(i32) = .empty,

    pub fn deinit(c: *Chapters, gpa: std.mem.Allocator) void {
        c.ids.deinit(gpa);
    }

    fn has(c: *const Chapters, id: i32) bool {
        return std.mem.findScalar(i32, c.ids.items, id) != null;
    }
};

/// `ff_vorbis_comment` into `tags`: returns how many comments became tags
/// (FFmpeg's `updates`). Comments past the end, or a count past them,
/// are not an error, as FFmpeg only logs them.
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
    var updates: usize = 0;
    while (buf.len - p >= 4 and n > 0) : (n -= 1) {
        const s = std.mem.readInt(u32, buf[p..][0..4], .little);
        p += 4;
        if (buf.len - p < s or s > std.math.maxInt(i32)) break;
        if (try single(gpa, tags, chapters, buf[p..][0..s])) updates += 1;
        p += s;
    }
    try convert(gpa, tags);
    return updates;
}

/// vorbis_parse_single_comment: true when the comment became a tag.
fn single(gpa: std.mem.Allocator, tags: *metadata.Dictionary, chapters: *Chapters, raw: []const u8) Error!bool {
    const eq = std.mem.findScalar(u8, raw, '=') orelse return false;
    // FFmpeg puts NULs where '=' and the end are; an earlier NUL ends
    // the key or the value as a C string.
    const key_full = raw[0..eq];
    const value_full = raw[eq + 1 ..];
    if (key_full.len == 0 or value_full.len == 0) return false;
    const key = key_full[0 .. std.mem.findScalar(u8, key_full, 0) orelse key_full.len];
    const value = value_full[0 .. std.mem.findScalar(u8, value_full, 0) orelse value_full.len];
    if (std.ascii.eqlIgnoreCase(key, "METADATA_BLOCK_PICTURE")) return false;
    if (try ogmChapter(gpa, chapters, key, value)) return false;
    if (tags.get(key) != null) try append(gpa, tags, key, ";");
    try append(gpa, tags, key, value);
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
        if (!chapters.has(id)) try chapters.ids.append(gpa, id);
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

/// `av_dict_set` with AV_DICT_APPEND: the old value and `value`, the
/// entry replaced (the last one moves into its place).
fn append(gpa: std.mem.Allocator, tags: *metadata.Dictionary, key: []const u8, value: []const u8) Error!void {
    const old = tags.get(key) orelse "";
    const joined = try std.mem.concat(gpa, u8, &.{ old, value });
    defer gpa.free(joined);
    tags.put(gpa, key, joined, .replace) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // NULs ended the key and the value above.
        error.InvalidTag => unreachable,
    };
}

/// ff_metadata_conv from the VORBIS_COMMENT names: the dictionary
/// rebuilt in order with AV_DICT_MULTIKEY | AV_DICT_DEDUP.
fn convert(gpa: std.mem.Allocator, tags: *metadata.Dictionary) Error!void {
    var out: metadata.Dictionary = .empty;
    errdefer out.deinit(gpa);
    for (tags.items()) |entry| {
        var key = entry.key;
        for (conv) |c| {
            if (std.ascii.eqlIgnoreCase(key, c.native)) {
                key = c.generic;
                break;
            }
        }
        out.put(gpa, key, entry.value, .keep_distinct) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidTag => unreachable,
        };
    }
    tags.deinit(gpa);
    tags.* = out;
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
