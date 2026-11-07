// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/aacdec.c (adts_aac_probe,
// adts_aac_resync, adts_aac_read_header, handle_id3,
// adts_aac_read_packet) and the ID3v2 reading of demux.c's
// avformat_open_input at the pinned reference revision.
// Copyright (c) 2008 Michael Niedermayer
// Copyright (c) 2009 Robert Swain
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's raw ADTS demuxer (`aac`, TODO.md T30a), without decoding: the
//! ID3v2 tags libavformat reads before it, ID3v1 and then APE tags at the
//! end of a seekable input, the resync to the first sync word, then one
//! packet per frame header (ID3v2 tags between frames read into the
//! format's tags, junk resynced past), which demux.zig's layer splits again
//! with FFmpeg's AAC parser (codec/adts.zig). Without a decoder the stream
//! has no sample rate, channels or packet timestamps (T30b).

const std = @import("std");
const metadata = @import("../core/metadata.zig");
const rational = @import("../core/rational.zig");
const adts = @import("../codec/adts.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const id3v1 = @import("id3v1.zig");
const id3v2 = @import("id3v2.zig");
const apetag = @import("apetag.zig");

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA: no sync word within the probe size, a
    /// header cut short or claiming under 7 bytes, or 10 bytes that are
    /// neither a header nor an ID3v2 tag cut short.
    InvalidAdts,
    /// FFmpeg's AVERROR_EOF at the open: the input ends before a sync word.
    Truncated,
    /// An ID3v2 tag larger than `Limits.max_id3v2_bytes`.
    LimitExceeded,
    IoFailure,
    OutOfMemory,
};

pub const Limits = struct {
    /// The largest ID3v2 tag read (it is parsed in memory), at the start
    /// or between frames; FFmpeg reads any (notes.md "MP3").
    max_id3v2_bytes: u32 = 64 << 20,
};

pub const nopts: i64 = std.math.minInt(i64);
/// The lcm of every ADTS sample rate, aacdec.c's stream time base.
pub const time_base: rational.Rational = .{ .num = 1, .den = 28224000 };

/// `s->probesize`'s default: how far a resync looks.
const probesize = 5_000_000;
/// `ID3v2_HEADER_SIZE`.
const id3_header = id3v2.header_size;

pub const Packet = demux.SourcePacket;

/// adts_aac_probe on a probe buffer (after any ID3v2 tag probing
/// skipped): the run of frames from each position, by their sync words and
/// lengths, then FFmpeg's thresholds.
pub fn probeScore(buf: []const u8) u8 {
    if (buf.len < adts.header_size) return 0;
    const end = buf.len - adts.header_size;
    var max_frames: u32 = 0;
    var first_frames: u32 = 0;
    var start: usize = 0;
    while (start < end) {
        var pos = start;
        var frames: u32 = 0;
        while (pos < end) : (frames += 1) {
            const header = std.mem.readInt(u16, buf[pos..][0..2], .big);
            if (header & 0xfff6 != 0xfff0) {
                // Not a header after the buffer's start: the run so far was
                // probably a false positive.
                if (start != 0) frames = 0;
                break;
            }
            const fsize: usize = (std.mem.readInt(u32, buf[pos + 3 ..][0..4], .big) >> 13) & 0x1fff;
            if (fsize < adts.header_size) break;
            pos += @min(fsize, end - pos);
        }
        max_frames = @max(max_frames, frames);
        if (start == 0) first_frames = frames;
        start = pos + 1;
    }
    if (first_frames >= 3) return 50 + 1;
    if (max_frames > 100) return 50;
    if (max_frames >= 3) return 50 / 2;
    if (first_frames >= 1) return 1;
    return 0;
}

pub const Demuxer = struct {
    /// The error set demux.zig's layer returns.
    pub const ReadError = Error;

    gpa: std.mem.Allocator,
    src: demux.Window,
    limits: Limits,
    /// The format's tags: ID3v1's, else APE's, else the leading ID3v2
    /// tags; then their PRIV frames, and the tags of ID3v2 tags between
    /// frames as they are read.
    tags: metadata.Dictionary = .empty,
    /// libavformat's `data_offset`, where the frames start.
    data_offset: i64 = 0,
    /// The next read's position.
    pos: i64 = 0,
    start_time: i64 = nopts,
    duration: i64 = nopts,
    /// The packet returned last.
    current: std.ArrayList(u8) = .empty,

    /// The demuxer on a source that cannot seek (a pipe): no ID3v1 or APE
    /// tag, no file size.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, null, limits);
    }

    /// The demuxer on a seekable source read from its start (a file).
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, seeker, limits);
    }

    fn initWith(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, limits: Limits) Error!*Demuxer {
        const d = try gpa.create(Demuxer);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .src = .{ .reader = reader, .seeker = seeker }, .limits = limits };
        errdefer d.deinitFields();
        if (seeker) |sk| {
            d.src.window_start = @intCast(sk.position());
            d.pos = d.src.window_start;
        }
        try d.readHeader();
        return d;
    }

    fn deinitFields(d: *Demuxer) void {
        d.src.deinit(d.gpa);
        d.tags.deinit(d.gpa);
        d.current.deinit(d.gpa);
    }

    pub fn deinit(d: *Demuxer) void {
        d.deinitFields();
        d.gpa.destroy(d);
    }

    /// avformat_open_input's ID3v2 tags, then adts_aac_read_header.
    fn readHeader(d: *Demuxer) Error!void {
        var id3: id3v2.Reader = .init(d.gpa);
        defer id3.deinit();
        try d.src.readId3v2Tags(d.gpa, &d.pos, d.limits.max_id3v2_bytes, &id3);
        // A tag may claim more bytes than the input has: the resync then
        // starts at the end (notes.md "An ID3v2 tag past the end of the
        // input").
        if (d.pos > d.src.windowEnd()) {
            try d.src.fill(d.gpa, d.pos);
            d.src.drop(d.src.windowEnd());
            d.src.window_start = d.pos;
        }
        if (d.src.seeker) |sk| if (sk.size()) |size| {
            // ff_id3v1_read, into the format's tags (the ID3v2 tags are
            // still apart).
            if (size > id3v1.tag_size) {
                var tag: std.ArrayList(u8) = .empty;
                defer tag.deinit(d.gpa);
                try d.src.readElsewhere(d.gpa, @intCast(size - id3v1.tag_size), id3v1.tag_size, &tag);
                if (tag.items.len == id3v1.tag_size) try id3v1.parse(d.gpa, tag.items[0..id3v1.tag_size], &d.tags);
            }
            // ff_ape_parse_tag when ID3v1 gave none.
            if (d.tags.count() == 0) try d.readApeTag(size);
        };
        d.resync() catch |err| return switch (err) {
            error.EndOfStream => error.Truncated,
            else => |e| e,
        };
        d.data_offset = d.pos;
        // avformat_open_input: the ID3v2 tags only when the demuxer set
        // none, then their PRIV frames.
        if (d.tags.count() == 0) std.mem.swap(metadata.Dictionary, &d.tags, &id3.tags);
        try id3.addPriv(&d.tags);
    }

    /// `ff_ape_parse_tag` on a seekable file of `size` bytes.
    fn readApeTag(d: *Demuxer, size: u64) Error!void {
        if (size < apetag.footer_bytes) return;
        var footer: std.ArrayList(u8) = .empty;
        defer footer.deinit(d.gpa);
        try d.src.readElsewhere(d.gpa, @intCast(size - apetag.footer_bytes), apetag.footer_bytes, &footer);
        if (footer.items.len != apetag.footer_bytes) return;
        const tag = apetag.locate(footer.items[0..apetag.footer_bytes], size) orelse return;
        var fields: std.ArrayList(u8) = .empty;
        defer fields.deinit(d.gpa);
        // At most 16 MiB and 32 bytes, within the file.
        try d.src.readElsewhere(d.gpa, @intCast(tag.fields_at), @intCast(size - tag.fields_at), &fields);
        try apetag.readFields(d.gpa, tag, fields.items, &d.tags);
    }

    /// adts_aac_resync from the read position: the bytes up to the next
    /// 12-bit sync word, within `probesize`; `EndOfStream` (AVERROR_EOF) at
    /// the end of the input.
    fn resync(d: *Demuxer) (Error || error{EndOfStream})!void {
        const start = d.pos;
        var state: u16 = 0;
        var first = true;
        var eof = false;
        scan: while (true) {
            const chunk = try d.src.bytesAt(d.gpa, d.pos, 4096);
            if (chunk.len == 0) {
                eof = true;
                break;
            }
            for (chunk) |b| {
                // The first byte is read before the loop, whose condition
                // is checked before every later one.
                if (!first and d.pos - start >= probesize) break :scan;
                state = (state << 8) | b;
                d.pos += 1;
                if (!first and state >> 4 == 0xfff) {
                    d.pos -= 2;
                    break :scan;
                }
                first = false;
            }
            // Keep the last two bytes: a match steps back over them.
            d.src.drop(d.pos - 2);
        }
        d.src.drop(@min(d.pos, d.src.windowEnd()));
        if (eof) return error.EndOfStream;
        if (state >> 4 != 0xfff) return error.InvalidAdts;
    }

    pub fn streamCount(d: *const Demuxer) usize {
        _ = d;
        return 1;
    }

    pub fn setup(d: *const Demuxer, i: usize) demux.Setup {
        _ = d;
        std.debug.assert(i == 0);
        return .{
            .known = true,
            .time_base = time_base,
            .sample_rate = 0,
            .channels = 0,
            .parser = .aac,
        };
    }

    /// adts_aac_read_packet: a frame's header and the bytes it claims, after
    /// any ID3v2 tags (read into the format's tags) and junk (resynced
    /// past); null at the end.
    pub fn next(d: *Demuxer) Error!?Packet {
        return d.readPacket() catch |err| switch (err) {
            error.EndOfStream => null,
            else => |e| e,
        };
    }

    fn readPacket(d: *Demuxer) (Error || error{EndOfStream})!Packet {
        while (true) {
            const pos = d.pos;
            // av_get_packet(pb, pkt, ADTS_HEADER_SIZE).
            const head = try d.src.bytesAt(d.gpa, pos, adts.header_size);
            if (head.len == 0) return error.EndOfStream;
            d.current.clearRetainingCapacity();
            try d.current.appendSlice(d.gpa, head);
            d.pos += @intCast(head.len);
            if (head.len < adts.header_size) return error.InvalidAdts;
            if (std.mem.readInt(u16, head[0..2], .big) >> 4 != 0xfff) {
                // Up to an ID3v2 header: a tag between frames, else junk.
                const more = try d.src.bytesAt(d.gpa, d.pos, id3_header - adts.header_size);
                try d.current.appendSlice(d.gpa, more);
                d.pos += @intCast(more.len);
                if (more.len != id3_header - adts.header_size) return error.InvalidAdts;
                const header = d.current.items[0..id3_header];
                if (!id3v2.match(header)) {
                    d.src.drop(d.pos);
                    try d.resync();
                } else {
                    try d.readTagBetween(header[0..id3_header].*);
                }
                continue;
            }
            const fsize: u32 = (std.mem.readInt(u32, head[3..7], .big) >> 13) & 0x1fff;
            if (fsize < adts.header_size) return error.InvalidAdts;
            const rest = try d.src.bytesAt(d.gpa, d.pos, fsize - adts.header_size);
            // av_append_packet: nothing at the end is AVERROR_EOF, and the
            // header read is lost.
            if (rest.len == 0 and fsize > adts.header_size) return error.EndOfStream;
            try d.current.appendSlice(d.gpa, rest);
            d.pos += @intCast(rest.len);
            d.src.drop(d.pos);
            return .{ .stream = 0, .data = d.current.items, .pts = nopts, .dts = nopts, .duration = 0, .flags = demux.key_flag, .pos = pos };
        }
    }

    /// handle_id3: the tag whose `header` was read, its bytes appended
    /// (`ff_id3v2_tag_len`, fewer at the end), read as `ff_id3v2_read_dict`
    /// reads a buffer, its PRIV frames added, and its tags copied over the
    /// format's.
    fn readTagBetween(d: *Demuxer, header: [id3_header]u8) (Error || error{EndOfStream})!void {
        const want = id3v2.tagLen(&header) - id3_header;
        if (want > d.limits.max_id3v2_bytes) return error.LimitExceeded;
        const body = try d.src.bytesAt(d.gpa, d.pos, want);
        // An append of nothing at the end is AVERROR_EOF.
        if (body.len == 0 and want > 0) return error.EndOfStream;
        d.pos += @intCast(body.len);
        var id3: id3v2.Reader = .init(d.gpa);
        defer id3.deinit();
        _ = try id3.parseTag(&header, body[0..@min(body.len, id3v2.bodyLen(&header))]);
        try id3.finish();
        try id3.addPriv(&id3.tags);
        for (id3.tags.items()) |e| d.tags.put(d.gpa, e.key, e.value, .replace) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable, // the ID3v2 reader's keys and values hold no NUL
        };
        d.src.drop(d.pos);
    }

    pub fn durationOf(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.duration;
    }

    pub fn startTime(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.start_time;
    }

    pub fn fileSize(d: *const Demuxer) ?u64 {
        const sk = d.src.seeker orelse return null;
        return sk.size();
    }

    pub fn dataOffset(d: *const Demuxer) i64 {
        return d.data_offset;
    }

    /// libavformat's `avio_seek`: `IoFailure` on a pipe.
    pub fn reposition(d: *Demuxer, pos: i64) Error!void {
        try d.src.seekTo(pos);
        d.pos = pos;
    }

    pub fn ioRepositioned(d: *Demuxer) void {
        _ = d;
    }

    /// No `read_timestamp`: the generic layer seeks without it.
    pub fn readTimestamp(d: *Demuxer, i: usize, pos: *i64, pos_limit: i64) Error!i64 {
        _ = d;
        _ = i;
        _ = pos;
        _ = pos_limit;
        return nopts;
    }

    /// No `read_seek`: the generic index code.
    pub fn readSeek(d: *Demuxer, layer: anytype, i: usize, ts: i64, flags: seek.Flags) Error!bool {
        _ = d;
        _ = layer;
        _ = i;
        _ = ts;
        _ = flags;
        return false;
    }
};

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const vectors = @embedFile("../testing/vectors/aac.txt");

/// The vector lines of one fixture, after its `F` line.
fn block(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, vectors, at, '\n') orelse vectors.len;
        const end = std.mem.findPos(u8, vectors, line_end, "\nF ") orelse vectors.len;
        if (std.mem.eql(u8, vectors[at + 2 .. line_end], name)) return vectors[line_end + 1 .. @min(end + 1, vectors.len)];
        start = end;
    }
    return null;
}

/// Adler-32 from 0, as `av_adler32_update(0, ...)` gives it.
fn adler(data: []const u8) u32 {
    var a: u32 = 0;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeTs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ts: ?i64) !void {
    if (ts) |v| {
        if (v != nopts) return out.print(gpa, " {d}", .{v});
    }
    try out.appendSlice(gpa, " N");
}

/// mp3_vectors.c's lines for a fixture, from the demuxer and libavformat's
/// layer (demux.zig).
fn vectorLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{}) catch |err| switch (err) {
        error.InvalidAdts => return out.appendSlice(gpa, "O INVALIDDATA\n"),
        error.Truncated => return out.appendSlice(gpa, "O EOF\n"),
        else => return err,
    };
    defer d.deinit();
    var layer = demux.Layer(Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    try out.appendSlice(gpa, "O ok\n");
    const params = try layer.codecParams(0);
    try out.print(gpa, "S 0 a aac {d} {d} 1/28224000", .{ params.sample_rate, params.channels });
    try writeTs(out, gpa, d.duration);
    try writeTs(out, gpa, d.start_time);
    try out.print(gpa, " 0 {d} 0\n", .{params.bit_rate});
    try out.appendSlice(gpa, "B");
    try writeTs(out, gpa, layer.start_time);
    try writeTs(out, gpa, layer.duration);
    try out.print(gpa, " {d}\n", .{layer.bit_rate});
    for (d.tags.items()) |e| try out.print(gpa, "G {s}={s}\n", .{ e.key, e.value });
    while (true) {
        const p = layer.next() catch |err| switch (err) {
            error.InvalidAdts => return out.appendSlice(gpa, "R INVALIDDATA\n"),
            else => return err,
        } orelse break;
        try out.print(gpa, "P {d} {d}", .{ p.stream, p.data.len });
        try writeTs(out, gpa, p.pts);
        try writeTs(out, gpa, p.dts);
        try out.print(gpa, " {d} {x} {d} {d}\n", .{ p.duration, p.flags, p.pos, adler(p.data) });
    }
    try out.appendSlice(gpa, "R EOF\n");
}

/// The lines of the streams FFmpeg makes of an APE tag's binary items,
/// which the port does not model (notes.md "APE tags"), and the format
/// line their duration enters.
fn withoutAttachments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > 2 and (line[0] == 'S' or line[0] == 'M' or line[0] == 'P') and !std.mem.startsWith(u8, line[1..], " 0 ")) continue;
        if (std.mem.startsWith(u8, line, "B ")) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "every ADTS fixture demuxes as FFmpeg's demuxer and parser demux it (vectors/aac.txt)" {
    const gpa = testing.allocator;
    inline for (fixtures.aac.all) |fixture| {
        const want = block(fixture.name) orelse return error.MissingVector;
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try vectorLines(gpa, fixtures.aac.bytes(fixture.name), &got);
        const attachments = comptime std.mem.eql(u8, fixture.name, "aac_ape_binary");
        const expected = if (attachments) try withoutAttachments(gpa, want) else try gpa.dupe(u8, want);
        defer gpa.free(expected);
        const actual = if (attachments) try withoutAttachments(gpa, got.items) else try gpa.dupe(u8, got.items);
        defer gpa.free(actual);
        testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("aac fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "the probe's thresholds" {
    const frame = [_]u8{ 0xff, 0xf1, 0x50, 0x80, 0x01, 0x1f, 0xfc } ++ @as([1]u8, @splat(0x21));
    try testing.expectEqual(0, probeScore(frame[0..6]));
    try testing.expectEqual(1, probeScore(&frame));
    try testing.expectEqual(1, probeScore(&(frame ++ frame)));
    try testing.expectEqual(51, probeScore(&(frame ++ frame ++ frame ++ frame)));
    try testing.expectEqual(25, probeScore(&([_]u8{0x21} ++ frame ++ frame ++ frame ++ frame)));
}

const seek_vectors = @embedFile("../testing/vectors/seek_aac.txt");

fn seekBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var at: usize = 0;
    while (at < seek_vectors.len) {
        const end = std.mem.findScalarPos(u8, seek_vectors, at, '\n') orelse seek_vectors.len;
        const line = seek_vectors[at..end];
        if (std.mem.startsWith(u8, line, "F ")) {
            if (start) |s| return seek_vectors[s..at];
            if (std.mem.eql(u8, line[2..], name)) start = end + 1;
        }
        at = end + 1;
    }
    return if (start) |s| seek_vectors[s..] else null;
}

/// The next packet's lines, as seek_vectors.c prints them: without a
/// decoder, `D none`; a read that fails, its error.
fn nextAfterSeek(gpa: std.mem.Allocator, layer: anytype, out: *std.ArrayList(u8)) !void {
    const next_packet = layer.next() catch |err| switch (err) {
        error.InvalidAdts => return out.appendSlice(gpa, "P INVALIDDATA\n"),
        else => return err,
    };
    const p = next_packet orelse return out.appendSlice(gpa, "P EOF\n");
    try out.appendSlice(gpa, "P");
    try writeTs(out, gpa, p.pts);
    try out.print(gpa, " {d} {d}\n", .{ p.pos, p.data.len });
    if (p.skip) |skip| try out.print(gpa, "Z {d} {d}\n", .{ skip[0], skip[1] });
    try out.appendSlice(gpa, "D none\n");
}

test "every ADTS fixture seeks as FFmpeg seeks it (vectors/seek_aac.txt)" {
    const gpa = testing.allocator;
    var compared: usize = 0;
    inline for (fixtures.aac.all) |fixture| {
        // FFmpeg queues the APE tag's picture again after each seek, which
        // the port does not model (notes.md "APE tags").
        if (comptime std.mem.eql(u8, fixture.name, "aac_ape_binary")) continue;
        const block_text = seekBlock(fixture.name) orelse return error.MissingVector;
        var lines = std.mem.splitScalar(u8, block_text, '\n');
        if (std.mem.eql(u8, lines.next().?, "O ok")) {
            _ = lines.next(); // I
            var pending = lines.next();
            while (pending) |k_line| {
                pending = lines.next();
                if (k_line.len == 0) continue;
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                var f = std.mem.tokenizeScalar(u8, k_line, ' ');
                _ = f.next();
                const api = f.next().?[0];
                const stream_index = try std.fmt.parseInt(i32, f.next().?, 10);
                const ts = try std.fmt.parseInt(i64, f.next().?, 10);
                var min_ts: i64 = 0;
                var max_ts: i64 = 0;
                if (api == 's') {
                    min_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                    max_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                }
                const flag_bits = try std.fmt.parseInt(u8, f.next().?, 16);
                const flags: seek.Flags = .{ .backward = flag_bits & 1 != 0, .byte = flag_bits & 2 != 0, .any = flag_bits & 4 != 0 };
                const ret = f.next().?;
                if (std.mem.eql(u8, ret, "0")) {
                    while (pending) |next_line| {
                        if (next_line.len == 0 or next_line[0] == 'K') break;
                        try expected.appendSlice(gpa, next_line);
                        try expected.append(gpa, '\n');
                        pending = lines.next();
                    }
                }
                var reader: std.Io.Reader = .fixed(fixtures.aac.bytes(fixture.name));
                const d = try Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
                defer d.deinit();
                var layer = demux.Layer(Demuxer).init(gpa, d);
                defer layer.deinit();
                try layer.findStreamInfo();
                // seek_vectors.c reads a packet first, whatever it gives.
                _ = layer.next() catch |err| switch (err) {
                    error.InvalidAdts => null,
                    else => return err,
                };
                const result = if (api == 'f') layer.seekFrame(stream_index, ts, flags) else layer.seekFile(stream_index, min_ts, ts, max_ts, flags);
                var actual: std.ArrayList(u8) = .empty;
                defer actual.deinit(gpa);
                if (result) |_| {
                    try nextAfterSeek(gpa, &layer, &actual);
                } else |err| switch (err) {
                    error.InvalidStream => try actual.appendSlice(gpa, "EINVAL"),
                    error.SeekFailed, error.InvalidRange => try actual.appendSlice(gpa, "-1"),
                    else => return err,
                }
                const want = if (std.mem.eql(u8, ret, "0")) expected.items else ret;
                testing.expectEqualStrings(want, actual.items) catch |err| {
                    std.debug.print("fixture {s}: {s}\n", .{ fixture.name, k_line });
                    return err;
                };
                compared += 1;
            }
        }
    }
    try testing.expect(compared > 1000);
}

const hostile = @import("../testing/hostile.zig");

/// Opens ADTS bytes from a file or a pipe with `limits` and runs `plan` on
/// them; the packets returned (0 when opening fails).
fn exercise(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, limits: Limits, plan: hostile.TestPlan) error{OutOfMemory}!u32 {
    var reader: std.Io.Reader = .fixed(bytes);
    const opened = if (seekable) Demuxer.initSeekable(gpa, &reader, .fixed(&reader), limits) else Demuxer.init(gpa, &reader, limits);
    const d = opened catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    defer d.deinit();
    return hostile.runTestPlan(Demuxer, gpa, d, plan);
}

/// As `exercise` from a pipe that gives one byte per read.
fn exerciseFragmented(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!u32 {
    var buffer: [64]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    source.artificial_limit = .limited(1);
    const d = Demuxer.init(gpa, &source.interface, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    defer d.deinit();
    return hostile.runTestPlan(Demuxer, gpa, d, .{});
}

test "the ADTS demuxer from a pipe of one-byte reads frees everything under every allocation failure" {
    inline for (.{ "aac_id3v2_between", "aac_junk_between", "aac_bad_rate_index" }) |name| {
        const bytes = fixtures.aac.bytes(name);
        const expected = try exercise(testing.allocator, bytes, false, .{}, .{});
        try testing.expect(expected > 0);
        try testing.expectEqual(expected, try exerciseFragmented(testing.allocator, bytes));
        try hostile.checkAll(exerciseFragmented, .{bytes});
    }
}

test "the ADTS demuxer, its tags and the generic layer free everything under every allocation failure" {
    inline for (.{
        "aac_lc_stereo_44k", "aac_id3v2_leading", "aac_id3v2_between",  "aac_id3v1",          "aac_ape_tag",
        "aac_ape_binary",    "aac_junk_between",  "aac_bad_rate_index", "aac_frame_length_6", "aac_truncated",
    }) |name| {
        const bytes = fixtures.aac.bytes(name);
        try hostile.checkAll(exercise, .{ bytes, false, Limits{}, hostile.TestPlan{} });
        try hostile.checkAll(exercise, .{ bytes, true, Limits{}, hostile.TestPlan{ .seek = .{ .file = false, .stream = 0, .ts = 900, .flags = .{ .byte = true } } } });
    }
}

/// Arbitrary bytes as ADTS, from a file or a pipe (the first value), with
/// an ID3v2 limit (the second: FFmpeg's none, 0 or 1 KiB), then
/// `hostile.drawTestPlan`'s plan.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

fn fuzzRun(smith: *std.testing.Smith) error{OutOfMemory}!u32 {
    var input: [16000 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const seekable = !smith.value(bool);
    const limits: Limits = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .{},
        1 => .{ .max_id3v2_bytes = 0 },
        else => .{ .max_id3v2_bytes = 1024 },
    };
    return exercise(testing.allocator, input[0..len], seekable, limits, hostile.drawTestPlan(smith, seekable));
}

fn fuzzSeed(comptime name: []const u8, comptime pipe: bool, comptime limit: u64, comptime s: ?hostile.TestPlan.Seek) []const u8 {
    return hostile.fuzzSeed(fixtures.aac.bytes(name), &([2]u64{ @intFromBool(pipe), limit } ++ hostile.seedValues(s)));
}

const fuzz_corpus: []const []const u8 = &.{
    fuzzSeed("aac_lc_stereo_44k", false, 0, .{ .file = false, .stream = 0, .ts = 2000, .flags = .{ .byte = true } }),
    fuzzSeed("aac_id3v2_between", true, 0, null),
    fuzzSeed("aac_id3v2_leading", false, 2, null),
    fuzzSeed("aac_ape_tag", false, 0, .{ .ts = 100000 }),
    fuzzSeed("aac_ape_binary", false, 0, null),
    fuzzSeed("aac_junk_between", true, 0, null),
    fuzzSeed("aac_bad_rate_index", false, 0, null),
    fuzzSeed("aac_length_short", true, 0, null),
    fuzzSeed("aac_four_blocks", false, 0, .{ .file = false, .stream = 0, .ts = 1500, .flags = .{ .byte = true, .backward = true } }),
};

test "fuzz: the ADTS demuxer on arbitrary input, from a file or a pipe, with ID3v2 limits and a seek" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the ADTS fuzz entry opens and returns packets" {
    for (fuzz_corpus, 0..) |seed, i| {
        errdefer std.debug.print("ADTS fuzz seed {d}\n", .{i});
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the ADTS demuxer on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 128, 0x616163);
}
