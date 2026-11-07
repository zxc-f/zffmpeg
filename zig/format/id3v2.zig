// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/id3v2.c (ff_id3v2_match,
// ff_id3v2_tag_len, get_size, is_syncsafe, size_to_syncsafe, is_tag,
// check_tag, decode_str, read_ttag, read_lang_descr_tag, read_priv,
// id3v2_parse, id3v2_read_internal, merge_date, ff_id3v2_parse_priv_dict,
// the metadata conversion tables) and libavutil/common.h (PUT_UTF8,
// GET_UTF16) at the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! ID3v2 tags (TODO.md T29a), as FFmpeg's `ff_id3v2_read_dict` reads them
//! at the start of an input before the demuxer: versions 2.2 to 2.4,
//! unsynchronisation, extended headers and footers, v2.4 frame sizes
//! written as v2.3's (FFmpeg's heuristic), text frames (TXXX with its own
//! key, a numeric genre named), COMM and USLT keyed by descriptor and
//! language, and PRIV frames, which FFmpeg adds to the format's tags
//! after the demuxer's header (`addPriv`). Every value is FFmpeg's
//! UTF-8, from ISO-8859-1, UTF-16 with or without a BOM, or UTF-8.
//!
//! Not modeled (notes.md "MP3"): APIC pictures and CHAP chapters, which
//! FFmpeg makes an attached-picture stream and chapters; GEOB, which it
//! reads and drops. Compressed frames are skipped, as the reference build
//! has no zlib, and so are encrypted ones. FFmpeg tests v2.3 frames' flags
//! with v2.4's bit positions; so does this.
//!
//! A tag is parsed from memory: the caller reads its body (`bodyLen`
//! bytes after the 10-byte header, fewer at the end of the input, where
//! FFmpeg's reads give zeros).

const std = @import("std");
const metadata = @import("../core/metadata.zig");
const id3v1 = @import("id3v1.zig");
const avlanguage = @import("avlanguage.zig");

pub const header_size = 10;

pub const Error = std.mem.Allocator.Error;

/// `ff_id3v2_match` with `ID3v2_DEFAULT_MAGIC`: an `ID3` header whose
/// version bytes are not 0xFF and whose size bytes have no top bit.
pub fn match(buf: []const u8) bool {
    if (buf.len < header_size) return false;
    return buf[0] == 'I' and buf[1] == 'D' and buf[2] == '3' and buf[3] != 0xff and buf[4] != 0xff and
        buf[6] & 0x80 == 0 and buf[7] & 0x80 == 0 and buf[8] & 0x80 == 0 and buf[9] & 0x80 == 0;
}

/// The declared length after the header (its four 7-bit size bytes).
fn declaredLen(buf: *const [header_size]u8) u32 {
    return (@as(u32, buf[6] & 0x7f) << 21) | (@as(u32, buf[7] & 0x7f) << 14) | (@as(u32, buf[8] & 0x7f) << 7) | (buf[9] & 0x7f);
}

/// `ff_id3v2_tag_len`: the whole tag's bytes, header and footer included.
pub fn tagLen(buf: *const [header_size]u8) u32 {
    var len = declaredLen(buf) + header_size;
    if (buf[5] & 0x10 != 0) len += header_size;
    return len;
}

/// The bytes after the header that `Reader.parseTag` reads: the declared
/// length, and a v2.4 footer's 10 bytes.
pub fn bodyLen(buf: *const [header_size]u8) u32 {
    return declaredLen(buf) + if (buf[3] == 4 and buf[5] & 0x10 != 0) @as(u32, header_size) else 0;
}

/// Where `Reader.parseTag` resumes, in bytes after the header, from the
/// header and the body's first 4 bytes alone (fewer at the end of the
/// input read as zeros): the declared length, less a v2.4 footer that a
/// malformed extended header stops `id3v2_parse` before counting. A caller
/// that only skips the tag needs no allocation.
pub fn resumeLen(header: *const [header_size]u8, body: []const u8) u64 {
    const len: i64 = declaredLen(header);
    const version = header[3];
    const flags = header[5];
    if (version != 3 and version != 4) return @intCast(len);
    if (flags & 0x40 != 0) {
        var c: Cursor = .{ .bytes = body[0..@min(body.len, 4)] };
        var extlen: i64 = getSize(&c, 4);
        if (version == 4) extlen -= 4;
        if (extlen < 0 or len - (extlen + 4) < 0) return @intCast(len);
    }
    return @as(u64, @intCast(len)) + if (version == 4 and flags & 0x10 != 0) @as(u64, header_size) else 0;
}

/// The bytes `ff_id3v2_read_dict` takes from the start of `bytes`: each
/// ID3v2 tag that follows the one before, resumed as `resumeLen` says
/// (past the end of `bytes` when a tag claims more).
pub fn leadingLen(bytes: []const u8) u64 {
    var pos: u64 = 0;
    while (pos + header_size <= bytes.len) {
        const at: usize = @intCast(pos);
        if (!match(bytes[at..])) break;
        pos += header_size + resumeLen(bytes[at..][0..header_size], bytes[at + header_size ..]);
    }
    return pos;
}

/// An `AVIOContext` over a tag's bytes: a read past them gives zeros (a
/// short read) and stops the position at their end; a seek may go past.
const Cursor = struct {
    bytes: []const u8,
    pos: u64 = 0,

    fn r8(c: *Cursor) u8 {
        if (c.pos >= c.bytes.len) return 0;
        defer c.pos += 1;
        return c.bytes[@intCast(c.pos)];
    }

    fn rb16(c: *Cursor) u32 {
        const hi: u32 = c.r8();
        return hi << 8 | c.r8();
    }

    fn rl16(c: *Cursor) u32 {
        const lo: u32 = c.r8();
        return lo | @as(u32, c.r8()) << 8;
    }

    fn rb24(c: *Cursor) u32 {
        const hi: u32 = c.rb16();
        return hi << 8 | c.r8();
    }

    fn rb32(c: *Cursor) u32 {
        const hi: u32 = c.rb16();
        return hi << 16 | c.rb16();
    }

    /// `avio_read`: the bytes copied, fewer at the end.
    fn read(c: *Cursor, dst: []u8) usize {
        if (c.pos >= c.bytes.len) return 0;
        const n = @min(dst.len, c.bytes.len - @as(usize, @intCast(c.pos)));
        @memcpy(dst[0..n], c.bytes[@intCast(c.pos)..][0..n]);
        c.pos += n;
        return n;
    }

    /// The bytes `read` would give, without copying.
    fn take(c: *Cursor, n: usize) []const u8 {
        if (c.pos >= c.bytes.len) return &.{};
        const at: usize = @intCast(c.pos);
        const got = @min(n, c.bytes.len - at);
        c.pos += got;
        return c.bytes[at..][0..got];
    }
};

/// `get_size`: `len` bytes of 7 bits each.
fn getSize(c: *Cursor, len: u32) i32 {
    var v: i32 = 0;
    for (0..len) |_| v = (v << 7) + (c.r8() & 0x7f);
    return v;
}

fn isSyncsafe(size: u32) bool {
    return size & 0x80808080 == 0;
}

fn sizeToSyncsafe(size: u32) u32 {
    return (size & 0x7f) + ((size & 0x7f00) >> 1) + ((size & 0x7f0000) >> 2) + ((size & 0x7f000000) >> 3);
}

/// `is_tag`: capital letters and digits only.
fn isTag(buf: []const u8) bool {
    if (buf.len == 0) return false;
    for (buf) |b| {
        if (!((b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9'))) return false;
    }
    return true;
}

/// `check_tag`: 1 when what follows `offset` (with `rem` bytes of the tag
/// left) is the end, zero padding or a plausible frame header, 0 when not,
/// -1 when a read falls short.
fn checkTag(c: *Cursor, offset: u64, rem: u32) i32 {
    if (rem == 0) return 1;
    c.pos = offset;
    if (rem < 4) {
        for (0..rem) |_| {
            if (c.r8() != 0) return 0;
        }
        return 1;
    }
    var tag: [4]u8 = undefined;
    if (c.read(&tag) < 4) return -1;
    if (std.mem.readInt(u32, &tag, .big) == 0) return 1;
    if (rem < header_size or !isTag(&tag)) return 0;
    const nsize = c.rb32();
    const nlen = if (isSyncsafe(nsize)) sizeToSyncsafe(nsize) else nsize;
    return @intFromBool(nlen <= rem - header_size);
}

const Encoding = enum(u8) { iso8859 = 0, utf16bom = 1, utf16be = 2, utf8 = 3, _ };

/// `PUT_UTF8`.
fn putUtf8(out: *std.ArrayList(u8), gpa: std.mem.Allocator, val: u32) Error!void {
    if (val < 0x80) return out.append(gpa, @intCast(val));
    const bytes: u5 = @intCast((std.math.log2_int(u32, val) + 4) / 5);
    var shift: u5 = (bytes - 1) * 6;
    const lead: u32 = (@as(u32, 256) - (@as(u32, 256) >> bytes)) | (val >> shift);
    try out.append(gpa, @truncate(lead));
    while (shift >= 6) {
        shift -= 6;
        try out.append(gpa, @intCast(0x80 | ((val >> shift) & 0x3f)));
    }
}

/// `decode_str`: a string of `encoding` from at most `maxread` bytes,
/// converted to UTF-8 up to its NUL, `maxread` lowered by the bytes read;
/// null where FFmpeg fails (a UTF-16 BOM missing or wrong).
fn decodeStr(gpa: std.mem.Allocator, c: *Cursor, encoding: u8, maxread: *i32) Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var left = maxread.*;
    var ch: u32 = 1;
    if (left != 0) switch (@as(Encoding, @fromBackingInt(@intCast(encoding)))) {
        .iso8859 => while (left != 0 and ch != 0) {
            ch = c.r8();
            try putUtf8(&out, gpa, ch);
            left -= 1;
        },
        .utf16bom, .utf16be => |e| utf16: {
            var little = false;
            if (e == .utf16bom) {
                left -= 2;
                if (left < 0) {
                    out.deinit(gpa);
                    return null;
                }
                switch (c.rb16()) {
                    0xfffe => little = true,
                    0xfeff => {},
                    // An empty string without a BOM.
                    0 => break :utf16,
                    else => {
                        out.deinit(gpa);
                        maxread.* = left;
                        return null;
                    },
                }
            }
            while (left > 1 and ch != 0) {
                // GET_UTF16, each unit read while `left` allows.
                left -= 2;
                ch = if (left >= 0) (if (little) c.rl16() else c.rb16()) else 0;
                const hi = ch -% 0xd800;
                if (hi < 0x800) {
                    left -= 2;
                    ch = (if (left >= 0) (if (little) c.rl16() else c.rb16()) else 0) -% 0xdc00;
                    if (ch > 0x3ff or hi > 0x3ff) break;
                    ch += (hi << 10) + 0x10000;
                }
                try putUtf8(&out, gpa, ch);
            }
            // The last unit was not read.
            if (left < 0) left += 2;
        },
        .utf8 => while (left != 0 and ch != 0) {
            ch = c.r8();
            try out.append(gpa, @intCast(ch));
            left -= 1;
        },
        // FFmpeg warns of an unknown encoding and reads nothing.
        _ => {},
    };
    maxread.* = left;
    // FFmpeg's string ends at its first NUL.
    const end = std.mem.findScalar(u8, out.items, 0) orelse out.items.len;
    out.shrinkRetainingCapacity(end);
    return try out.toOwnedSlice(gpa);
}

/// `ff_id3v2_34_metadata_conv`, `id3v2_2_metadata_conv` and
/// `ff_id3v2_4_metadata_conv`, applied in that order.
const Conv = struct { native: []const u8, generic: []const u8 };
const conv_34 = [_]Conv{
    .{ .native = "COMM", .generic = "comment" },   .{ .native = "TALB", .generic = "album" },
    .{ .native = "TCOM", .generic = "composer" },  .{ .native = "TCON", .generic = "genre" },
    .{ .native = "TCOP", .generic = "copyright" }, .{ .native = "TENC", .generic = "encoded_by" },
    .{ .native = "TIT2", .generic = "title" },     .{ .native = "TLAN", .generic = "language" },
    .{ .native = "TPE1", .generic = "artist" },    .{ .native = "TPE2", .generic = "album_artist" },
    .{ .native = "TPE3", .generic = "performer" }, .{ .native = "TPOS", .generic = "disc" },
    .{ .native = "TPUB", .generic = "publisher" }, .{ .native = "TRCK", .generic = "track" },
    .{ .native = "TSSE", .generic = "encoder" },   .{ .native = "USLT", .generic = "lyrics" },
};
const conv_2 = [_]Conv{
    .{ .native = "TAL", .generic = "album" },        .{ .native = "TCO", .generic = "genre" },
    .{ .native = "TCP", .generic = "compilation" },  .{ .native = "TT2", .generic = "title" },
    .{ .native = "TEN", .generic = "encoded_by" },   .{ .native = "TP1", .generic = "artist" },
    .{ .native = "TP2", .generic = "album_artist" }, .{ .native = "TP3", .generic = "performer" },
    .{ .native = "TRK", .generic = "track" },
};
const conv_4 = [_]Conv{
    .{ .native = "TCMP", .generic = "compilation" }, .{ .native = "TDRC", .generic = "date" },
    .{ .native = "TDRL", .generic = "date" },        .{ .native = "TDEN", .generic = "creation_time" },
    .{ .native = "TSOA", .generic = "album-sort" },  .{ .native = "TSOP", .generic = "artist-sort" },
    .{ .native = "TSOT", .generic = "title-sort" },  .{ .native = "TSST", .generic = "disc_subtitle" },
    .{ .native = "TIT1", .generic = "grouping" },
};

/// One PRIV frame: its owner (UTF-8) and data.
pub const Priv = struct {
    owner: []u8,
    data: []u8,
};

/// What FFmpeg's ID3v2 reading collects: the tags (`id3v2_meta`) and
/// the PRIV frames of its extra metadata.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    tags: metadata.Dictionary = .empty,
    privs: std.ArrayList(Priv) = .empty,

    pub fn init(gpa: std.mem.Allocator) Reader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Reader) void {
        r.tags.deinit(r.gpa);
        for (r.privs.items) |p| {
            r.gpa.free(p.owner);
            r.gpa.free(p.data);
        }
        r.privs.deinit(r.gpa);
        r.* = undefined;
    }

    /// `av_dict_set` with `AV_DICT_DONT_OVERWRITE`, keeping an earlier
    /// value of the key. Values end at their NUL, so none holds one.
    fn set(r: *Reader, key: []const u8, value: []const u8) Error!void {
        r.tags.put(r.gpa, key, value, .keep_existing) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable,
        };
    }

    /// `id3v2_parse`: one tag, `header` its first 10 bytes (`match`
    /// holds), `body` the bytes after them (`bodyLen`, fewer at the end of
    /// the input). Returns where reading resumes, in bytes after the header.
    pub fn parseTag(r: *Reader, header: *const [header_size]u8, body: []const u8) Error!u64 {
        var len: i64 = declaredLen(header);
        const version = header[3];
        const flags = header[5];
        var end: u64 = @intCast(len);
        var c: Cursor = .{ .bytes = body };
        var isv34 = true;
        var taghdrlen: i64 = 10;
        var comm_frame: []const u8 = "COMM";
        switch (version) {
            2 => {
                // Compression: the tag is skipped.
                if (flags & 0x40 != 0) return end;
                isv34 = false;
                taghdrlen = 6;
                comm_frame = "COM";
            },
            3, 4 => {},
            else => return end,
        }
        const unsync = flags & 0x80 != 0;
        if (isv34 and flags & 0x40 != 0) {
            // The extended header, skipped.
            var extlen: i64 = getSize(&c, 4);
            if (version == 4) extlen -= 4;
            if (extlen < 0) return end;
            c.pos +%= @intCast(extlen);
            len -= extlen + 4;
            if (len < 0) return end;
        }
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(r.gpa);
        while (len >= taghdrlen) {
            var tag_bytes: [4]u8 = @splat(0);
            var tlen: u32 = undefined;
            var tflags: u32 = 0;
            if (isv34) {
                if (c.read(&tag_bytes) < 4) break;
                tlen = c.rb32();
                if (version == 4 and tlen > 0x7f) {
                    // Some encoders write v2.3 sizes: the next frame
                    // header decides which reading holds.
                    const rem: u32 = @intCast(len - taghdrlen);
                    if (tlen <= rem) {
                        const cur = c.pos;
                        const ss_tlen = sizeToSyncsafe(tlen);
                        if (isSyncsafe(tlen) and checkTag(&c, cur + 2 + ss_tlen, rem - ss_tlen) == 1) {
                            tlen = ss_tlen;
                        } else if (checkTag(&c, cur + 2 + tlen, rem - tlen) != 1) break;
                        c.pos = cur;
                    } else if (isSyncsafe(tlen)) tlen = sizeToSyncsafe(tlen);
                }
                tflags = c.rb16();
            } else {
                if (c.read(tag_bytes[0..3]) < 3) break;
                tlen = c.rb24();
            }
            if (tlen > 1 << 28) break;
            len -= taghdrlen + tlen;
            if (len < 0) break;
            const next = c.pos + tlen;
            // An empty frame is skipped.
            if (tlen == 0) continue;
            const tag = tag_bytes[0 .. std.mem.findScalar(u8, &tag_bytes, 0) orelse 4];
            if (tflags & 0x0001 != 0) {
                // The data length indicator.
                if (tlen < 4) break;
                _ = c.rb32();
                tlen -= 4;
            }
            const tunsync = tflags & 0x0002 != 0;
            const tencr = tflags & 0x0004 != 0;
            const tcomp = tflags & 0x0008 != 0;
            const kind: enum { text, lyrics, comment, priv, other } = if (tag.len > 0 and tag[0] == 'T')
                .text
            else if (std.mem.eql(u8, tag, "USLT"))
                .lyrics
            else if (std.mem.eql(u8, tag, comm_frame))
                .comment
            else if (tag.len >= 3 and std.mem.eql(u8, tag[0..if (isv34) @min(tag.len, 4) else 3], if (isv34) "PRIV" else "PRI"))
                .priv
            else
                .other;
            if (tencr or tcomp) {
                // Encrypted, or compressed without zlib: skipped.
            } else if (kind != .other) {
                var frame_cursor = c;
                var frame_len = tlen;
                if (unsync or tunsync) {
                    // The zero after each 0xFF removed.
                    const raw = c.take(tlen);
                    if (raw.len != tlen) {
                        c.pos = next;
                        continue;
                    }
                    buffer.clearRetainingCapacity();
                    try buffer.ensureTotalCapacity(r.gpa, tlen);
                    var i: usize = 0;
                    while (i < raw.len) {
                        buffer.appendAssumeCapacity(raw[i]);
                        i += 1;
                        if (i < raw.len and raw[i - 1] == 0xff and raw[i] == 0) i += 1;
                    }
                    frame_cursor = .{ .bytes = buffer.items };
                    frame_len = @intCast(buffer.items.len);
                }
                switch (kind) {
                    .text => try r.readTextTag(&frame_cursor, frame_len, tag),
                    .lyrics => try r.readLangDescrTag(&frame_cursor, "lyrics", frame_len),
                    .comment => try r.readLangDescrTag(&frame_cursor, "comment", frame_len),
                    .priv => try r.readPriv(&frame_cursor, frame_len),
                    .other => unreachable,
                }
            } else if (tag_bytes[0] == 0) {
                // Padding.
                break;
            }
            c.pos = next;
        }
        // A v2.4 footer, always 10 bytes.
        if (version == 4 and flags & 0x10 != 0) end += 10;
        return end;
    }

    /// `read_ttag`.
    fn readTextTag(r: *Reader, c: *Cursor, taglen_in: u32, key: []const u8) Error!void {
        if (taglen_in < 1) return;
        const encoding = c.r8();
        var taglen: i32 = @intCast(taglen_in - 1);
        const dst = try decodeStr(r.gpa, c, encoding, &taglen) orelse return;
        defer r.gpa.free(dst);
        if (std.mem.eql(u8, key, "TCON") or std.mem.eql(u8, key, "TCO")) {
            if (genreNumber(dst)) |genre| return r.set(key, id3v1.genres[genre]);
        }
        if (std.mem.eql(u8, key, "TXXX") or std.mem.eql(u8, key, "TXX")) {
            const value = try decodeStr(r.gpa, c, encoding, &taglen) orelse return;
            defer r.gpa.free(value);
            return r.set(dst, value);
        }
        if (dst.len == 0) return;
        try r.set(key, dst);
    }

    /// `read_lang_descr_tag`: COMM and USLT, keyed
    /// `<key>[-<descriptor>][-<language>]` as FFmpeg keys them.
    fn readLangDescrTag(r: *Reader, c: *Cursor, key: []const u8, taglen_in: u32) Error!void {
        if (taglen_in < 4) return;
        const encoding = c.r8();
        var language: [3]u8 = undefined;
        if (c.read(&language) < 3) return;
        var lang_len: usize = std.mem.findScalar(u8, &language, 0) orelse 3;
        for (language[0..lang_len]) |*b| b.* = std.ascii.toLower(b.*);
        // "xxx" and "und" are no language.
        if (lang_len == 3 and (std.mem.eql(u8, &language, "xxx") or std.mem.eql(u8, &language, "und"))) lang_len = 0;
        const lang = language[0..lang_len];
        var taglen: i32 = @intCast(taglen_in - 4);
        const descriptor = try decodeStr(r.gpa, c, encoding, &taglen) orelse return;
        defer r.gpa.free(descriptor);
        const dst = try decodeStr(r.gpa, c, encoding, &taglen) orelse return;
        defer r.gpa.free(dst);
        var full: std.ArrayList(u8) = .empty;
        defer full.deinit(r.gpa);
        if (descriptor.len != 0) {
            const looks_like_language = avlanguage.isIso6392(descriptor) or
                (descriptor.len > 4 and descriptor[descriptor.len - 4] == '-' and avlanguage.isIso6392(descriptor[descriptor.len - 3 ..]));
            if (lang.len > 0) {
                try full.print(r.gpa, "{s}-{s}-{s}", .{ key, descriptor, lang });
            } else if (looks_like_language) {
                // A trailing language keeps the key unambiguous.
                try full.print(r.gpa, "{s}-{s}-und", .{ key, descriptor });
            } else try full.print(r.gpa, "{s}-{s}", .{ key, descriptor });
        } else if (lang.len == 3) {
            try full.print(r.gpa, "{s}-{s}", .{ key, lang });
        } else try full.appendSlice(r.gpa, key);
        try r.set(full.items, dst);
    }

    /// `read_priv`: the owner, then the rest of the frame as data.
    fn readPriv(r: *Reader, c: *Cursor, taglen_in: u32) Error!void {
        var taglen: i32 = @intCast(taglen_in);
        const owner = try decodeStr(r.gpa, c, 0, &taglen) orelse return;
        errdefer r.gpa.free(owner);
        const data = c.take(@intCast(taglen));
        if (data.len != taglen) {
            r.gpa.free(owner);
            return;
        }
        const copy = try r.gpa.dupe(u8, data);
        errdefer r.gpa.free(copy);
        try r.privs.append(r.gpa, .{ .owner = owner, .data = copy });
    }

    /// After the last tag: `id3v2_read_internal`'s key conversions, then
    /// `merge_date`.
    pub fn finish(r: *Reader) Error!void {
        try convert(r.gpa, &r.tags, &conv_34);
        try convert(r.gpa, &r.tags, &conv_2);
        try convert(r.gpa, &r.tags, &conv_4);
        try mergeDate(r.gpa, &r.tags);
    }

    /// `ff_id3v2_parse_priv_dict`: each PRIV frame as `id3v2_priv.<owner>`,
    /// its bytes outside printable ASCII and backslashes as `\xNN`, unless
    /// `tags` has the key.
    pub fn addPriv(r: *const Reader, tags: *metadata.Dictionary) Error!void {
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(r.gpa);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(r.gpa);
        for (r.privs.items) |p| {
            key.clearRetainingCapacity();
            try key.print(r.gpa, "id3v2_priv.{s}", .{p.owner});
            value.clearRetainingCapacity();
            for (p.data) |b| {
                if (b < 32 or b > 126 or b == '\\') {
                    try value.print(r.gpa, "\\x{x:0>2}", .{b});
                } else try value.append(r.gpa, b);
            }
            tags.put(r.gpa, key.items, value.items, .keep_existing) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTag => unreachable,
            };
        }
    }
};

/// `sscanf(dst, "(%d)", &genre) == 1 || sscanf(dst, "%d", &genre) == 1`,
/// then `genre <= ID3v1_GENRE_MAX` with `genre` unsigned: the number
/// after optional white space (and a parenthesis), when it names a genre.
fn genreNumber(text: []const u8) ?u8 {
    // "(%d)": a parenthesis first, white space allowed before the number;
    // when it scans, `||` does not try "%d".
    if (text.len > 0 and text[0] == '(') {
        if (scanInt(text[1..])) |v| return if (v >= 0 and v <= id3v1.genre_max) @intCast(v) else null;
    }
    const v = scanInt(text) orelse return null;
    return if (v >= 0 and v <= id3v1.genre_max) @intCast(v) else null;
}

/// scanf's `%d`: white space, a sign, digits; the value as glibc stores an
/// out-of-range one in an `int` (strtol's saturation, then truncation).
fn scanInt(text: []const u8) ?i64 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    const start = i;
    var value: i64 = 0;
    var overflow = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = std.math.mul(i64, value, 10) catch blk: {
            overflow = true;
            break :blk value;
        };
        value = std.math.add(i64, value, text[i] - '0') catch blk: {
            overflow = true;
            break :blk value;
        };
    }
    if (i == start) return null;
    // strtol saturates; storing into an int keeps the low 32 bits.
    const long: i64 = if (overflow) (if (negative) std.math.minInt(i64) else std.math.maxInt(i64)) else if (negative) -value else value;
    return @as(i32, @truncate(long));
}

/// `ff_metadata_conv` from the ID3v2 names: rebuilt in order with
/// `AV_DICT_MULTIKEY | AV_DICT_DEDUP`.
fn convert(gpa: std.mem.Allocator, tags: *metadata.Dictionary, table: []const Conv) Error!void {
    var out: metadata.Dictionary = .empty;
    errdefer out.deinit(gpa);
    for (tags.items()) |entry| {
        var key = entry.key;
        for (table) |c| {
            if (std.ascii.eqlIgnoreCase(key, c.native)) {
                key = c.generic;
                break;
            }
        }
        out.put(gpa, key, entry.value, .keep_distinct) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable,
        };
    }
    tags.deinit(gpa);
    tags.* = out;
}

/// `get_date_tag`: the value of the first entry whose key is exactly
/// `key` (`AV_DICT_MATCH_CASE`), when it is four digits.
fn dateTag(tags: *const metadata.Dictionary, key: []const u8) ?[4]u8 {
    for (tags.items()) |entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        if (entry.value.len != 4) return null;
        for (entry.value) |b| if (!std.ascii.isDigit(b)) return null;
        return entry.value[0..4].*;
    }
    return null;
}

/// `merge_date`: TYER (TYE), TDAT (TDA) and TIME (TIM) into one `date`,
/// `YYYY[-MM-DD[ hh:mm]]`.
fn mergeDate(gpa: std.mem.Allocator, tags: *metadata.Dictionary) Error!void {
    var date: [16]u8 = undefined;
    var n: usize = 0;
    const year = dateTag(tags, "TYER") orelse dateTag(tags, "TYE") orelse return;
    @memcpy(date[0..4], &year);
    n = 4;
    _ = tags.remove(gpa, "TYER");
    _ = tags.remove(gpa, "TYE");
    if (dateTag(tags, "TDAT") orelse dateTag(tags, "TDA")) |day| {
        // DDMM: "-MM-DD".
        @memcpy(date[4..10], &[6]u8{ '-', day[2], day[3], '-', day[0], day[1] });
        n = 10;
        _ = tags.remove(gpa, "TDAT");
        _ = tags.remove(gpa, "TDA");
        if (dateTag(tags, "TIME") orelse dateTag(tags, "TIM")) |time| {
            @memcpy(date[10..16], &[6]u8{ ' ', time[0], time[1], ':', time[2], time[3] });
            n = 16;
            _ = tags.remove(gpa, "TIME");
            _ = tags.remove(gpa, "TIM");
        }
    }
    tags.put(gpa, "date", date[0..n], .replace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTag => unreachable,
    };
}

const testing = std.testing;

fn frame3(id: *const [4]u8, data: []const u8) [10]u8 {
    var h: [10]u8 = undefined;
    @memcpy(h[0..4], id);
    std.mem.writeInt(u32, h[4..8], @intCast(data.len), .big);
    h[8] = 0;
    h[9] = 0;
    return h;
}

test "header matching and lengths" {
    const header = [_]u8{ 'I', 'D', '3', 4, 0, 0x10, 0, 0, 1, 2 };
    try testing.expect(match(&header));
    try testing.expectEqual(130 + 20, tagLen(&header));
    try testing.expectEqual(130 + 10, bodyLen(&header));
    try testing.expect(!match(&[_]u8{ 'I', 'D', '3', 0xff, 0, 0, 0, 0, 0, 0 }));
    try testing.expect(!match(&[_]u8{ 'I', 'D', '3', 3, 0, 0, 0x80, 0, 0, 0 }));
    // A v2.4 footer counts, unless an extended header longer than the tag
    // stops the parse first.
    try testing.expectEqual(130 + 10, resumeLen(&header, &.{}));
    const extended = [_]u8{ 'I', 'D', '3', 4, 0, 0x50, 0, 0, 0, 20 };
    try testing.expectEqual(20 + 10, resumeLen(&extended, &.{ 0, 0, 0, 10 }));
    try testing.expectEqual(20, resumeLen(&extended, &.{ 0, 0, 0, 30 }));
    try testing.expectEqual(20, resumeLen(&extended, &.{ 0, 0, 0, 2 }));
    var r: Reader = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(20, try r.parseTag(&extended, &([_]u8{ 0, 0, 0, 30 } ++ @as([26]u8, @splat(0)))));
}

test "UTF-16 strings: either BOM, surrogate pairs, and the NUL that ends them" {
    const gpa = testing.allocator;
    // "a", U+1F600 as a surrogate pair, NUL, then more.
    const bytes = [_]u8{ 0xff, 0xfe, 'a', 0, 0x3d, 0xd8, 0x00, 0xde, 0, 0, 'x', 0 };
    var c: Cursor = .{ .bytes = &bytes };
    var left: i32 = bytes.len;
    const s = (try decodeStr(gpa, &c, 1, &left)).?;
    defer gpa.free(s);
    try testing.expectEqualStrings("a\u{1F600}", s);
    try testing.expectEqual(2, left);
    // A wrong BOM fails.
    var bad: Cursor = .{ .bytes = &[_]u8{ 0x12, 0x34, 'a', 0 } };
    var bad_left: i32 = 4;
    try testing.expectEqual(null, try decodeStr(gpa, &bad, 1, &bad_left));
}

test "a text frame, a TXXX and a numeric genre; keys converted and the date merged" {
    const gpa = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const frames = [_]struct { id: *const [4]u8, data: []const u8 }{
        .{ .id = "TIT2", .data = "\x00Title" },
        .{ .id = "TIT2", .data = "\x00Second" },
        .{ .id = "TCON", .data = "\x00(17)" },
        .{ .id = "TXXX", .data = "\x00KEY\x00value" },
        .{ .id = "TYER", .data = "\x002009" },
        .{ .id = "TDAT", .data = "\x000301" },
    };
    for (frames) |f| {
        try body.appendSlice(gpa, &frame3(f.id, f.data));
        try body.appendSlice(gpa, f.data);
    }
    var header = [_]u8{ 'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0 };
    header[9] = @intCast(body.items.len & 0x7f);
    header[8] = @intCast(body.items.len >> 7);
    var r: Reader = .init(gpa);
    defer r.deinit();
    try testing.expectEqual(body.items.len, try r.parseTag(&header, body.items));
    try r.finish();
    try testing.expectEqualStrings("Title", r.tags.get("title").?);
    try testing.expectEqualStrings("Rock", r.tags.get("genre").?);
    try testing.expectEqualStrings("value", r.tags.get("KEY").?);
    try testing.expectEqualStrings("2009-01-03", r.tags.get("date").?);
    try testing.expectEqual(null, r.tags.get("TYER"));
}

test "genre numbers as scanf reads them" {
    try testing.expectEqual(17, genreNumber("(17)"));
    try testing.expectEqual(17, genreNumber("(17"));
    try testing.expectEqual(3, genreNumber(" 3abc"));
    try testing.expectEqual(null, genreNumber("192"));
    try testing.expectEqual(null, genreNumber("(-1)"));
    try testing.expectEqual(null, genreNumber("Rock"));
}

const fixtures = @import("../testing/fixtures.zig");
const mp3_vectors = @embedFile("../testing/vectors/mp3.txt");

/// The format's tags FFmpeg reports for a fixture (vectors/mp3.txt): its
/// G lines after the B line, before any chapter or packet.
fn expectedFormatTags(name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, mp3_vectors, '\n');
    var in_fixture = false;
    var start: ?usize = null;
    while (lines.next()) |line| {
        const at = @intFromPtr(line.ptr) - @intFromPtr(mp3_vectors.ptr);
        if (std.mem.startsWith(u8, line, "F ")) {
            if (in_fixture) return if (start) |s| mp3_vectors[s..at] else "";
            in_fixture = std.mem.eql(u8, line[2..], name);
            continue;
        }
        if (!in_fixture) continue;
        if (std.mem.startsWith(u8, line, "O ") and !std.mem.eql(u8, line, "O ok")) return null;
        if (std.mem.startsWith(u8, line, "B ")) {
            start = at + line.len + 1;
        } else if (start) |s| {
            if (!std.mem.startsWith(u8, line, "G ")) return mp3_vectors[s..at];
        }
    }
    return if (start) |s| mp3_vectors[s..] else null;
}

/// avformat_open_input's ID3v2 tags, then mp3_read_header's ID3v1 when
/// they gave none, then the PRIV frames, as G lines.
fn formatTags(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var r: Reader = .init(gpa);
    defer r.deinit();
    var pos: u64 = 0;
    while (pos + header_size <= bytes.len and match(bytes[@intCast(pos)..])) {
        const at: usize = @intCast(pos);
        const header = bytes[at..][0..header_size];
        const rest = bytes[at + header_size ..];
        const resume_at = try r.parseTag(header, rest[0..@min(bodyLen(header), rest.len)]);
        try testing.expectEqual(resume_at, resumeLen(header, rest));
        pos += header_size + resume_at;
    }
    try r.finish();
    if (r.tags.count() == 0 and bytes.len > id3v1.tag_size) try id3v1.parse(gpa, bytes[bytes.len - id3v1.tag_size ..][0..id3v1.tag_size], &r.tags);
    try r.addPriv(&r.tags);
    for (r.tags.items()) |entry| try out.print(gpa, "G {s}={s}\n", .{ entry.key, entry.value });
}

test "every MP3 fixture's ID3v2 and ID3v1 tags are FFmpeg's (vectors/mp3.txt)" {
    const gpa = testing.allocator;
    var checked: usize = 0;
    inline for (fixtures.mp3.all) |fixture| {
        if (expectedFormatTags(fixture.name)) |want| {
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            try formatTags(gpa, fixtures.mp3.bytes(fixture.name), &got);
            testing.expectEqualStrings(want, got.items) catch |err| {
                std.debug.print("mp3 fixture {s}\n", .{fixture.name});
                return err;
            };
            checked += 1;
        }
    }
    try testing.expectEqual(69, checked);
}

const hostile = @import("../testing/hostile.zig");

fn formatTagsUnderFailures(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try formatTags(gpa, bytes, &out);
}

test "the ID3 readers free everything under every allocation failure" {
    inline for (.{
        "mp3_id3v23_tags", "mp3_id3v24_tags", "mp3_id3v22_tags", "mp3_id3v23_unsync",
        "mp3_two_id3v2",   "mp3_apic_chap",   "mp3_id3v1",       "mp3_itunsmpb",
    }) |name| {
        try hostile.checkAll(formatTagsUnderFailures, .{fixtures.mp3.bytes(name)});
    }
}

/// Arbitrary bytes as ID3v2 tags from their start, then ID3v1 at their end
/// when no ID3v2 tag gave a tag, as `formatTags` reads a file.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [16384]u8 = undefined;
    const len = smith.slice(&input);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try formatTags(testing.allocator, input[0..len], &out);
}

/// A fixture's tags with its first frame's bytes after them.
fn fuzzSeed(comptime name: []const u8, comptime len: usize) []const u8 {
    return hostile.fuzzSeed(fixtures.mp3.bytes(name)[0..len], &.{});
}

const fuzz_corpus: []const []const u8 = &.{
    fuzzSeed("mp3_id3v23_tags", 1024),
    fuzzSeed("mp3_id3v24_tags", 900),
    fuzzSeed("mp3_id3v22_tags", 400),
    fuzzSeed("mp3_id3v23_unsync", 300),
    fuzzSeed("mp3_two_id3v2", 300),
    fuzzSeed("mp3_apic_chap", 600),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_id3v1"), &.{}),
};

test "fuzz: the ID3v2 and ID3v1 readers on arbitrary tags" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the ID3 readers on mutated tags" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 512, 0x6964);
}
