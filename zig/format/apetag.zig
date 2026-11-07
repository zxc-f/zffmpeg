// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/apetag.c (ff_ape_parse_tag,
// ape_tag_read_field), with avio_get_str (aviobuf.c) and img2.c's image
// extensions (ff_guess_image2_codec), at the pinned reference revision.
// Copyright (c) 2007 Benjamin Zores
// Copyright (c) 2007 Kostya Shishkov
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's APEv2 tag reader (TODO.md T30a, for the ADTS demuxer): the
//! footer at the end of a seekable file, then its text fields as format
//! tags. A binary field (cover art or another attachment) becomes a stream
//! of its own in FFmpeg, which the port does not model: it is skipped, and
//! only how FFmpeg's read of it ends the field loop is kept (notes.md
//! "APE tags").

const std = @import("std");
const metadata = @import("../core/metadata.zig");

/// `APE_TAG_FOOTER_BYTES`, `APE_TAG_HEADER_BYTES`.
pub const footer_bytes = 32;
pub const header_bytes = 32;
/// `APE_TAG_VERSION`.
const version = 2000;

const flag_contains_header: u32 = 1 << 31;
const flag_is_header: u32 = 1 << 29;
const flag_is_binary: u32 = 1 << 1;

/// The fields of a tag whose footer `ff_ape_parse_tag` accepts.
pub const Tag = struct {
    /// Where the fields start: `file_size - tag_bytes`.
    fields_at: u64,
    fields: u32,
    /// `ff_ape_parse_tag`'s result: where the tag starts, its header
    /// included, before the file's start when the header flag claims one
    /// the file has no room for.
    start: i64,
};

/// `ff_ape_parse_tag`'s checks of the footer, the file's last 32 bytes:
/// null when it is no tag FFmpeg reads.
pub fn locate(footer: *const [footer_bytes]u8, file_size: u64) ?Tag {
    if (file_size < footer_bytes) return null;
    if (!std.mem.eql(u8, footer[0..8], "APETAGEX")) return null;
    if (std.mem.readInt(u32, footer[8..12], .little) > version) return null;
    var tag_bytes: u64 = std.mem.readInt(u32, footer[12..16], .little);
    // `tag_bytes - APE_TAG_FOOTER_BYTES` in 32 bits: below 32 it wraps
    // past the limit.
    if (@as(u32, @truncate(tag_bytes)) -% footer_bytes > 16 << 20) return null;
    if (tag_bytes > file_size - footer_bytes) return null;
    const fields = std.mem.readInt(u32, footer[16..20], .little);
    if (fields > 65536) return null;
    const flags = std.mem.readInt(u32, footer[20..24], .little);
    if (flags & flag_is_header != 0) return null;
    const fields_at = file_size - tag_bytes;
    if (flags & flag_contains_header != 0) tag_bytes += header_bytes;
    // The file's size is an int64_t in FFmpeg.
    const size: i64 = @intCast(@min(file_size, std.math.maxInt(i64)));
    const tag_len: i64 = @intCast(tag_bytes);
    return .{ .fields_at = fields_at, .fields = fields, .start = size - tag_len };
}

/// An `AVIOContext` reading the tag's bytes to the end of the file: a
/// read past them gives zeros and sets `eof_reached`.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    eof_reached: bool = false,

    fn r8(c: *Cursor) u8 {
        if (c.pos >= c.bytes.len) {
            c.eof_reached = true;
            return 0;
        }
        defer c.pos += 1;
        return c.bytes[c.pos];
    }

    fn rl32(c: *Cursor) u32 {
        var v: u32 = 0;
        for (0..4) |i| v |= @as(u32, c.r8()) << @intCast(8 * i);
        return v;
    }

    /// `avio_read`: the bytes read, or null for AVERROR_EOF (nothing read,
    /// at the end, which a read of 0 bytes reports once the end was met).
    fn read(c: *Cursor, size: u64) ?[]const u8 {
        const n: usize = @intCast(@min(size, c.bytes.len - c.pos));
        if (n < size) c.eof_reached = true;
        if (n == 0 and c.eof_reached) return null;
        defer c.pos += n;
        return c.bytes[c.pos..][0..n];
    }
};

/// `ape_tag_read_field` for every field of `tag`, `bytes` the file from
/// `tag.fields_at` to its end: text fields into `tags` (replacing a key
/// already there, as `av_dict_set`), until a field fails.
pub fn readFields(gpa: std.mem.Allocator, tag: Tag, bytes: []const u8, tags: *metadata.Dictionary) std.mem.Allocator.Error!void {
    var c: Cursor = .{ .bytes = bytes };
    for (0..tag.fields) |_| if (!try readField(gpa, &c, tags)) break;
}

/// One field; false when it fails, which ends the loop.
fn readField(gpa: std.mem.Allocator, c: *Cursor, tags: *metadata.Dictionary) std.mem.Allocator.Error!bool {
    const size: u64 = c.rl32();
    const flags = c.rl32();
    var key: [1024]u8 = undefined;
    var len: usize = 0;
    var byte: u8 = 0;
    while (len < key.len - 1) : (len += 1) {
        byte = c.r8();
        if (byte < 0x20 or byte > 0x7e) break;
        key[len] = byte;
    }
    // "Invalid APE tag key": a key that does not end with a NUL.
    if (byte != 0) return false;
    // "APE tag size too large".
    if (size > std.math.maxInt(i32) - 64) return false;
    if (flags & flag_is_binary != 0) return readBinary(c, size);
    const value = c.read(size) orelse return false;
    // The value is a C string: it ends at its first NUL.
    const text = value[0 .. std.mem.findScalar(u8, value, 0) orelse value.len];
    tags.put(gpa, key[0..len], text, .replace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTag => unreachable, // neither holds a NUL
    };
    return true;
}

/// A binary field: `avio_get_str`'s file name, then the data, which
/// FFmpeg reads as an attached picture (any bytes do) when the name has
/// an image extension, else as extradata (all of it, or the field fails).
fn readBinary(c: *Cursor, size_in: u64) bool {
    // `avio_get_str(pb, size, filename, sizeof(filename))`: the name's
    // first 1023 bytes kept, up to `size` read, ending after a NUL.
    const maxlen = size_in;
    var name: [1023]u8 = undefined;
    var name_len: usize = 0;
    var got: u64 = maxlen;
    var i: u64 = 0;
    while (i < maxlen) : (i += 1) {
        const b = c.r8();
        if (b == 0) {
            got = i + 1;
            break;
        }
        if (name_len < name.len) {
            name[name_len] = b;
            name_len += 1;
        }
    }
    // "Skipping binary tag": nothing after the name.
    if (size_in <= got) return true;
    const size = size_in - got;
    if (isImage(name[0..name_len])) {
        // av_get_packet: any bytes read will do; none at the end fails.
        return c.read(size) != null;
    }
    // ff_get_extradata: exactly `size` bytes.
    const data = c.read(size) orelse return false;
    return data.len == size;
}

/// `ff_guess_image2_codec`: the name's extension, after its last dot, is
/// one of img2.c's image extensions (any case).
fn isImage(name: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (image_extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// img2.c's `IMG_TAGS` extensions.
const image_extensions = [_][]const u8{
    "jpeg",   "jpg",  "jps", "mpo", "ljpg",  "jls",  "png",  "pns",    "mng",   "ppm",  "pnm",  "pgm",
    "pgmyuv", "pbm",  "pam", "pfm", "phm",   "cri",  "pix",  "dds",    "img",   "y",    "raw",  "bmp",
    "tga",    "tiff", "tif", "dng", "rw2",   "sgi",  "ptx",  "pcd",    "pcx",   "pic",  "pct",  "pict",
    "sun",    "ras",  "rs",  "im1", "im8",   "im24", "im32", "sunras", "svg",   "svgz", "j2c",  "jp2",
    "jpc",    "j2k",  "dpx", "exr", "yuv10", "webp", "xbm",  "xpm",    "xface", "xwd",  "ximg", "timg",
    "vbn",    "jxl",  "jxs", "qoi", "hdr",   "wbmp",
};

const testing = std.testing;

/// A field: its size, flags, key and value.
fn field(comptime key: []const u8, comptime value: []const u8, comptime flags: u32) []const u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, value.len)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, flags)) ++ key ++ "\x00" ++ value;
}

fn testFooter(comptime tag_bytes: u32, comptime fields: u32, comptime flags: u32) [footer_bytes]u8 {
    return "APETAGEX".* ++ std.mem.toBytes(std.mem.nativeToLittle(u32, version)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, tag_bytes)) ++
        std.mem.toBytes(std.mem.nativeToLittle(u32, fields)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, flags)) ++ @as([8]u8, @splat(0));
}

test "an APE tag's text fields, a skipped binary field, and the footer's checks" {
    const gpa = testing.allocator;
    const fields = comptime field("Title", "A title", 0) ++ field("Cover Art (Front)", "front.jpg\x00\xff\xd8", flag_is_binary) ++ field("Artist", "Someone\x00ignored", 0) ++ field("title", "Again", 0);
    const tag_bytes = fields.len + footer_bytes;
    // The tag needs 32 bytes before it ("Invalid tag size" otherwise).
    const file = @as([40]u8, @splat('a')) ++ fields ++ testFooter(tag_bytes, 4, 0);
    const tag = locate(file[file.len - footer_bytes ..][0..footer_bytes], file.len).?;
    try testing.expectEqual(40, tag.fields_at);
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    try readFields(gpa, tag, file[tag.fields_at..], &tags);
    // `title` replaced `Title`, moving to the end.
    try testing.expectEqual(2, tags.count());
    try testing.expectEqualStrings("Someone", tags.get("artist").?);
    try testing.expectEqualStrings("Again", tags.get("title").?);

    try testing.expectEqual(null, locate(&testFooter(tag_bytes, 4, flag_is_header), file.len));
    try testing.expectEqual(null, locate(&testFooter(16, 4, 0), file.len));
    try testing.expectEqual(null, locate(&testFooter(tag_bytes, 65537, 0), file.len));
    try testing.expectEqual(null, locate(&testFooter(tag_bytes + 9, 4, 0), file.len));
    try testing.expectEqual(@as(i64, file.len) - tag_bytes - header_bytes, locate(&testFooter(tag_bytes, 4, flag_contains_header), file.len).?.start);
}

test "a field past the tag reads zeros and fails at the end; a key needs its NUL" {
    const gpa = testing.allocator;
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    // Three fields declared, one present: the second reads a zero size,
    // flags and key past the end, and its value's read of 0 bytes there is
    // AVERROR_EOF.
    const bytes = comptime field("Album", "X", 0);
    try readFields(gpa, .{ .fields_at = 0, .fields = 3, .start = 0 }, bytes, &tags);
    try testing.expectEqual(1, tags.count());
    // An empty field inside the tag is an empty key and value.
    try readFields(gpa, .{ .fields_at = 0, .fields = 2, .start = 0 }, comptime field("", "", 0) ++ field("B", "b", 0), &tags);
    try testing.expectEqualStrings("", tags.get("").?);
    // A key without its NUL ends the fields.
    tags.deinit(gpa);
    tags = .empty;
    try readFields(gpa, .{ .fields_at = 0, .fields = 2, .start = 0 }, comptime ("\x01\x00\x00\x00\x00\x00\x00\x00Key\x01v" ++ field("Next", "N", 0)), &tags);
    try testing.expectEqual(0, tags.count());
    try testing.expect(isImage("cover.JPG") and !isImage("notes.txt") and !isImage("jpg"));
}
