// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/oggenc.c (ogg_init, ogg_build_flac_headers,
// ogg_build_opus_headers, ogg_write_vorbiscomment, ogg_buffer_data,
// ogg_buffer_page, ogg_write_page, ogg_write_pages, ogg_write_header,
// ogg_write_packet_internal, ogg_write_trailer, ogg_bitexact_serial),
// libavcodec/xiph.c (avpriv_split_xiph_headers) and libavformat/mux.c's
// AVFMT_FLAG_BITEXACT path at the pinned reference revision describe the
// behavior, restated here.
//! FFmpeg's Ogg muxer (TODO.md T27b) for FLAC, Opus and Vorbis streams, as
//! the ffmpeg program runs it under `-fflags +bitexact`: the serial
//! numbers derived from the headers (or `serial_offset`), the vendor
//! string `ffmpeg`.
//!
//! Each stream's packets are laced into pages of at most 255 segments; a
//! data page ends when it holds `page_duration` (one second by default)
//! or would have to continue a packet that fits the next page. Finished
//! pages wait in a list ordered by their granule's time and are written
//! while their stream has another page waiting, so the last page of each
//! stream gets the end-of-stream flag at `finish`.
//!
//! The granule of a packet's page is its end: `pts + duration`, for Opus
//! plus the initial padding. The caller gives packets in the stream's
//! time base (`timeBase`), timestamps increasing, as libavformat's
//! interleaving gives them to the muxer for one stream.

const std = @import("std");
const metadata = @import("../core/metadata.zig");
const rational = @import("../core/rational.zig");
const ogg = @import("ogg.zig");
const vorbiscomment = @import("vorbiscomment.zig");
const xiph = @import("../codec/xiph.zig");

/// MAX_PAGE_SIZE: 255 segments of 255 bytes.
pub const max_page_size = 255 * 255;

const flac_streaminfo_size = 34;
const opus_header_size = 19;
const vendor = "ffmpeg";
const nopts: i64 = std.math.minInt(i64);

pub const Codec = enum { flac, opus, vorbis };

pub const Stream = struct {
    codec: Codec,
    /// `codecpar->sample_rate`: the time base's (FLAC, Vorbis), and for
    /// Opus the initial padding's unit.
    sample_rate: u32,
    initial_padding: u32 = 0,
    /// FLAC's STREAMINFO (at least 34 bytes), the OpusHead (at least 19),
    /// or Vorbis' three headers in Xiph lacing (or with 16-bit sizes).
    extradata: []const u8,
    /// The stream's tags, under FFmpeg's generic names.
    tags: ?*const metadata.Dictionary = null,
};

pub const Options = struct {
    /// `page_duration`, microseconds; 0 fills every page.
    page_duration: i64 = 1_000_000,
    /// `serial_offset`: stream i's serial is `i + offset`; null derives it
    /// from the stream's headers (FFmpeg's -1).
    serial_offset: ?u31 = null,
    /// The format's tags, which a stream without the same key takes.
    format_tags: ?*const metadata.Dictionary = null,
};

pub const InitError = error{
    /// The extradata is too short or malformed (FFmpeg's EINVAL for FLAC,
    /// INVALIDDATA for Opus and Vorbis).
    InvalidExtradata,
    /// A comment header past `INT_MAX` bytes (FFmpeg's ENOMEM).
    TagsTooLong,
    OutOfMemory,
};

pub const WriteError = std.Io.Writer.Error || error{OutOfMemory};

/// One page being filled or waiting to be written (`OGGPage`).
const Page = struct {
    start_granule: i64 = 0,
    granule: i64 = -1,
    stream: usize,
    flags: u8 = 0,
    segments_count: u8 = 0,
    segments: [255]u8 = undefined,
    size: u16 = 0,
    data: [max_page_size]u8 = undefined,
};

/// `OGGStreamContext`.
const StreamState = struct {
    codec: Codec,
    time_base: rational.Rational,
    sample_rate: u32,
    initial_padding: u32,
    /// The three headers' bytes; owned.
    header: [3][]u8 = .{ &.{}, &.{}, &.{} },
    serial: u32 = 0,
    page_counter: u32 = 0,
    /// Pages of this stream in the waiting list.
    page_count: u32 = 0,
    /// The page being filled; owned.
    page: *Page,
    last_granule: i64 = 0,

    fn deinit(s: *StreamState, gpa: std.mem.Allocator) void {
        for (s.header) |h| gpa.free(h);
        gpa.destroy(s.page);
    }

    fn resetPage(s: *StreamState) void {
        s.page.granule = -1;
        s.page.flags = 0;
        s.page.segments_count = 0;
        s.page.size = 0;
    }
};

pub const Muxer = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    page_duration: i64,
    streams: []StreamState,
    /// Finished pages, ordered by their granule's time; owned.
    pages: std.ArrayList(*Page) = .empty,

    /// ogg_init: each stream's headers and serial number. Writes nothing.
    pub fn init(gpa: std.mem.Allocator, out: *std.Io.Writer, streams: []const Stream, options: Options) InitError!Muxer {
        const states = try gpa.alloc(StreamState, streams.len);
        var done: usize = 0;
        errdefer {
            for (states[0..done]) |*s| s.deinit(gpa);
            gpa.free(states);
        }
        for (streams, states, 0..) |params, *s, i| {
            const page = try gpa.create(Page);
            page.* = .{ .stream = i };
            s.* = .{
                .codec = params.codec,
                // Opus has a fixed 48 kHz clock.
                .time_base = .{ .num = 1, .den = if (params.codec == .opus) 48000 else @intCast(params.sample_rate) },
                .sample_rate = params.sample_rate,
                .initial_padding = params.initial_padding,
                .page = page,
            };
            done += 1;
            var tags = try streamTags(gpa, params.tags, options.format_tags);
            defer tags.deinit(gpa);
            try buildHeaders(gpa, s, params, &tags);
            var serial: u32 = if (options.serial_offset) |offset| @as(u32, @intCast(i)) +% offset else bitexactSerial(s, @intCast(i));
            while (serialInUse(states[0..i], serial)) serial +%= 1;
            s.serial = serial;
        }
        return .{ .gpa = gpa, .out = out, .page_duration = options.page_duration, .streams = states };
    }

    pub fn deinit(m: *Muxer) void {
        for (m.pages.items) |p| m.gpa.destroy(p);
        m.pages.deinit(m.gpa);
        for (m.streams) |*s| s.deinit(m.gpa);
        m.gpa.free(m.streams);
        m.* = undefined;
    }

    /// The time base stream `i`'s timestamps are in.
    pub fn timeBase(m: *const Muxer, i: usize) rational.Rational {
        return m.streams[i].time_base;
    }

    /// ogg_write_header: each stream's first header on its own page (BOS),
    /// then the other headers, each stream's ending a page; all written.
    pub fn writeHeader(m: *Muxer) WriteError!void {
        for (m.streams) |*s| {
            try m.bufferData(s, s.header[0], 0, true);
            s.page.flags |= 2; // beginning of stream
            try m.bufferPage(s);
        }
        for (m.streams) |*s| {
            for (s.header[1..]) |h| {
                if (h.len > 0) try m.bufferData(s, h, 0, true);
            }
            try m.bufferPage(s);
        }
        // FFmpeg marks only the last stream's next page as starting at its
        // first packet.
        if (m.streams.len > 0) m.streams[m.streams.len - 1].page.start_granule = nopts;
        try m.writePages(.all);
    }

    /// ogg_write_packet_internal: a packet of stream `i` with its pts and
    /// duration in the stream's time base.
    pub fn writePacket(m: *Muxer, i: usize, data: []const u8, pts: i64, duration: i64) WriteError!void {
        const s = &m.streams[i];
        var granule = pts +% duration;
        if (s.codec == .opus) granule +%= rational.rescaleQ(s.initial_padding, .{ .num = 1, .den = @intCast(s.sample_rate) }, s.time_base);
        if (s.page.start_granule == nopts) s.page.start_granule = pts;
        try m.bufferData(s, data, granule, false);
        try m.writePages(.full);
        s.last_granule = granule;
    }

    /// ogg_write_trailer: every stream's last page, each stream's final
    /// one marked end of stream; then the output flushed.
    pub fn finish(m: *Muxer) WriteError!void {
        for (m.streams) |*s| {
            if (s.page.segments_count > 0) try m.bufferPage(s);
        }
        try m.writePages(.end);
        try m.out.flush();
    }

    /// ogg_buffer_data: `data` laced into the stream's pages.
    fn bufferData(m: *Muxer, s: *StreamState, data: []const u8, granule: i64, header: bool) WriteError!void {
        // Rather than continue a packet on the next page, start one.
        if (!header and s.page.size > 0 and max_page_size - @as(usize, s.page.size) < data.len) try m.bufferPage(s);
        const total_segments = data.len / 255 + 1;
        var rest = data;
        var i: usize = 0;
        while (i < total_segments) {
            const page = s.page;
            const segments = @min(total_segments - i, 255 - @as(usize, page.segments_count));
            if (i != 0 and page.segments_count == 0) page.flags |= 1; // continued packet
            @memset(page.segments[page.segments_count..][0 .. segments - 1], 255);
            page.segments_count += @intCast(segments - 1);
            const len = @min(rest.len, segments * 255);
            page.segments[page.segments_count] = @intCast(len - (segments - 1) * 255);
            page.segments_count += 1;
            @memcpy(page.data[page.size..][0..len], rest[0..len]);
            rest = rest[len..];
            i += segments;
            page.size += @intCast(len);
            if (i == total_segments) page.granule = granule;
            const start = rational.rescaleQ(page.start_granule, s.time_base, time_base_q);
            const next = rational.rescaleQ(page.granule, s.time_base, time_base_q);
            if (page.segments_count == 255) {
                try m.bufferPage(s);
            } else if (!header and m.page_duration > 0 and next -% start >= m.page_duration) {
                try m.bufferPage(s);
            }
        }
    }

    const time_base_q: rational.Rational = .{ .num = 1, .den = 1_000_000 };

    /// ogg_buffer_page: the stream's page into the waiting list, before
    /// the first page that ends later; a fresh page starts at its granule.
    fn bufferPage(m: *Muxer, s: *StreamState) WriteError!void {
        const done = s.page;
        const fresh = try m.gpa.create(Page);
        errdefer m.gpa.destroy(fresh);
        fresh.* = .{ .stream = done.stream, .start_granule = done.granule };
        var at: usize = 0;
        while (at < m.pages.items.len) : (at += 1) {
            if (m.laterGranule(m.pages.items[at], done)) break;
        }
        try m.pages.insert(m.gpa, at, done);
        s.page = fresh;
        s.page_count += 1;
    }

    /// ogg_compare_granule: `next` ends after `page`, both granules set.
    fn laterGranule(m: *const Muxer, next: *const Page, page: *const Page) bool {
        if (next.granule == -1 or page.granule == -1) return false;
        const next_us = rational.rescaleQ(next.granule, m.streams[next.stream].time_base, time_base_q);
        const page_us = rational.rescaleQ(page.granule, m.streams[page.stream].time_base, time_base_q);
        return next_us > page_us;
    }

    const Flush = enum {
        /// Only pages whose stream has another waiting (ogg_write_pages 0).
        full,
        /// Every page, the last of each stream marked end of stream (1).
        end,
        /// Every page (2).
        all,
    };

    /// ogg_write_pages.
    fn writePages(m: *Muxer, flush: Flush) WriteError!void {
        var written: usize = 0;
        defer {
            for (m.pages.items[0..written]) |p| m.gpa.destroy(p);
            m.pages.replaceRangeAssumeCapacity(0, written, &.{});
        }
        for (m.pages.items) |p| {
            const s = &m.streams[p.stream];
            if (s.page_count < 2 and flush == .full) break;
            const eos: u8 = if (flush == .end and s.page_count == 1) 4 else 0;
            try m.writePage(s, p, eos);
            written += 1;
        }
    }

    /// ogg_write_page: the 27-byte header, the segment table and the body,
    /// with Ogg's CRC.
    fn writePage(m: *Muxer, s: *StreamState, page: *const Page, extra_flags: u8) WriteError!void {
        var head: [27 + 255]u8 = undefined;
        @memcpy(head[0..4], "OggS");
        head[4] = 0;
        head[5] = page.flags | extra_flags;
        std.mem.writeInt(u64, head[6..14], @bitCast(page.granule), .little);
        std.mem.writeInt(u32, head[14..18], s.serial, .little);
        std.mem.writeInt(u32, head[18..22], s.page_counter, .little);
        s.page_counter +%= 1;
        @memset(head[22..26], 0);
        head[26] = page.segments_count;
        const head_len = 27 + @as(usize, page.segments_count);
        @memcpy(head[27..head_len], page.segments[0..page.segments_count]);
        var crc: ogg.Crc = .init();
        crc.update(head[0..head_len]);
        crc.update(page.data[0..page.size]);
        std.mem.writeInt(u32, head[22..26], crc.final(), .little);
        try m.out.writeAll(head[0..head_len]);
        try m.out.writeAll(page.data[0..page.size]);
        s.page_count -= 1;
    }
};

/// The stream's tags with the format's under keys it lacks
/// (`av_dict_copy` with AV_DICT_DONT_OVERWRITE), in VORBIS_COMMENT names.
fn streamTags(gpa: std.mem.Allocator, stream_tags: ?*const metadata.Dictionary, format_tags: ?*const metadata.Dictionary) error{OutOfMemory}!metadata.Dictionary {
    var merged: metadata.Dictionary = if (stream_tags) |t| try t.clone(gpa) else .empty;
    defer merged.deinit(gpa);
    if (format_tags) |f| {
        for (f.items()) |entry| {
            if (merged.get(entry.key) != null) continue;
            merged.put(gpa, entry.key, entry.value, .replace) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidTag => unreachable, // from a dictionary
            };
        }
    }
    return vorbiscomment.toNative(gpa, &merged);
}

/// What `Muxer.init` refuses in a stream's tags (`TagsTooLong`), merged
/// as it merges them, for a caller that checks a request before it
/// creates any output.
pub fn checkTags(gpa: std.mem.Allocator, codec: Codec, stream_tags: ?*const metadata.Dictionary, format_tags: ?*const metadata.Dictionary) InitError!void {
    var tags = try streamTags(gpa, stream_tags, format_tags);
    defer tags.deinit(gpa);
    try checkCommentLength(codec, vorbiscomment.length(vendor, &tags));
}

/// The comment header's bounds for a comment of `length` bytes: past
/// INT_MAX with the codec's prefix and framing bit, FFmpeg's
/// ogg_write_vorbiscomment fails (ENOMEM). FLAC's metadata block length
/// has 24 bits: FFmpeg's bytestream_put_be24 keeps the low 24 bits of a
/// longer comment and writes a header that misstates it; the port refuses
/// it (notes.md "Ogg FLAC comment over 16 MiB": whether to write FFmpeg's
/// bytes instead is open).
fn checkCommentLength(codec: Codec, length: u64) InitError!void {
    const extra: u64 = switch (codec) {
        .flac => 4,
        .opus => 8,
        .vorbis => 7 + 1,
    };
    if (extra + length > std.math.maxInt(i32)) return error.TagsTooLong;
    if (codec == .flac and length > std.math.maxInt(u24)) return error.TagsTooLong;
}

/// ogg_write_vorbiscomment: `offset` bytes for the caller's prefix, the
/// comment, and Vorbis' framing bit.
fn comment(gpa: std.mem.Allocator, offset: usize, tags: *const metadata.Dictionary, framing_bit: bool) InitError![]u8 {
    const size = offset + vorbiscomment.length(vendor, tags) + @intFromBool(framing_bit);
    if (size > std.math.maxInt(i32)) return error.TagsTooLong;
    const buf = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(buf);
    @memset(buf[0..offset], 0);
    var w: std.Io.Writer = .fixed(buf[offset..]);
    vorbiscomment.write(&w, vendor, tags) catch unreachable; // sized by `length`
    if (framing_bit) buf[buf.len - 1] = 1;
    return buf;
}

/// The codec's header packets: ogg_build_flac_headers,
/// ogg_build_opus_headers, or Vorbis' headers with the comment rebuilt.
fn buildHeaders(gpa: std.mem.Allocator, s: *StreamState, params: Stream, tags: *const metadata.Dictionary) InitError!void {
    const extradata = params.extradata;
    switch (params.codec) {
        .flac => {
            if (extradata.len < flac_streaminfo_size) return error.InvalidExtradata;
            const first = try gpa.alloc(u8, 51);
            s.header[0] = first;
            @memcpy(first[0..9], "\x7fFLAC\x01\x00\x00\x01");
            @memcpy(first[9..17], "fLaC\x00\x00\x00\x22");
            @memcpy(first[17..51], extradata[0..flac_streaminfo_size]);
            try checkCommentLength(.flac, vorbiscomment.length(vendor, tags));
            const second = try comment(gpa, 4, tags, false);
            s.header[1] = second;
            // The last metadata block, a VORBIS_COMMENT.
            second[0] = 0x84;
            std.mem.writeInt(u24, second[1..4], @intCast(second.len - 4), .big);
        },
        .opus => {
            if (extradata.len < opus_header_size) return error.InvalidExtradata;
            s.header[0] = try gpa.dupe(u8, extradata);
            const second = try comment(gpa, 8, tags, false);
            s.header[1] = second;
            @memcpy(second[0..8], "OpusTags");
        },
        .vorbis => {
            const parts = xiph.splitHeaders(extradata, 30) orelse return error.InvalidExtradata;
            s.header[0] = try gpa.dupe(u8, parts[0]);
            s.header[2] = try gpa.dupe(u8, parts[2]);
            const second = try comment(gpa, 7, tags, true);
            s.header[1] = second;
            @memcpy(second[0..7], "\x03vorbis");
        },
    }
}

/// ogg_bitexact_serial: FFmpeg's `av_crc` over the headers, seeded with
/// the stream index. Its IEEE table works on the byte-swapped register of
/// Ogg's MSB-first CRC, hence the swaps.
fn bitexactSerial(s: *const StreamState, seed: u32) u32 {
    var crc: ogg.Crc = .{ .crc = @byteSwap(seed) };
    for (s.header) |h| crc.update(h);
    return @byteSwap(crc.final());
}

fn serialInUse(states: []const StreamState, serial: u32) bool {
    for (states) |s| if (s.serial == serial) return true;
    return false;
}

const testing = std.testing;
const vectors = @embedFile("../testing/vectors/oggmux.txt");

/// oggmux_vectors.c's make_extradata.
fn caseExtradata(codec: Codec, rate: u32, channels: u8, padding: u32, cut: usize, out: []u8) []u8 {
    var n: usize = 0;
    switch (codec) {
        .flac => {
            while (n < 34) : (n += 1) out[n] = @truncate(n * 5 + 1);
        },
        .opus => {
            @memcpy(out[0..8], "OpusHead");
            out[8] = 1;
            out[9] = channels;
            std.mem.writeInt(u16, out[10..12], @intCast(padding), .little);
            std.mem.writeInt(u32, out[12..16], rate, .little);
            std.mem.writeInt(u16, out[16..18], 0, .little);
            out[18] = 0;
            n = 19;
        },
        .vorbis => {
            @memcpy(out[0..3], &[_]u8{ 2, 30, 17 });
            n = 3;
            @memcpy(out[n..][0..7], "\x01vorbis");
            for (7..30) |j| out[n + j] = @intCast(j);
            n += 30;
            @memcpy(out[n..][0..7], "\x03vorbis");
            @memset(out[n + 7 ..][0..10], 'x');
            n += 17;
            @memcpy(out[n..][0..7], "\x05vorbis");
            for (7..47) |j| out[n + j] = @truncate(j * 3);
            n += 47;
        },
    }
    if (cut != 0 and cut < n) n = cut;
    return out[0..n];
}

/// oggmux_vectors.c's make_tags.
fn caseTags(gpa: std.mem.Allocator, set: u8, stream: *metadata.Dictionary, format: *metadata.Dictionary) !void {
    switch (set) {
        1 => {
            try stream.put(gpa, "title", "Title", .replace);
            try stream.put(gpa, "album_artist", "Band", .replace);
            try stream.put(gpa, "track", "3", .replace);
            try stream.put(gpa, "comment", "Hello", .replace);
            try stream.put(gpa, "encoder", "Lavc flac", .replace);
        },
        2 => {
            const value = try gpa.alloc(u8, 70000);
            defer gpa.free(value);
            @memset(value, 'v');
            try stream.put(gpa, "long", value, .replace);
        },
        3 => {
            try stream.put(gpa, "title", "Stream", .replace);
            try format.put(gpa, "title", "Format", .replace);
            try format.put(gpa, "album", "Album", .replace);
            try format.put(gpa, "DISCNUMBER", "2", .replace);
        },
        else => {},
    }
}

/// One case's output lines (H, X, T, P and M), as oggmux_vectors.c prints
/// them.
fn runCase(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    var f = std.mem.tokenizeScalar(u8, line, ' ');
    _ = f.next();
    _ = f.next(); // name
    const codec_name = f.next().?;
    const rate = try std.fmt.parseInt(u32, f.next().?, 10);
    const channels = try std.fmt.parseInt(u8, f.next().?, 10);
    const padding = try std.fmt.parseInt(u32, f.next().?, 10);
    const page_duration = try std.fmt.parseInt(i64, f.next().?, 10);
    const serial_offset = try std.fmt.parseInt(i32, f.next().?, 10);
    const count = try std.fmt.parseInt(usize, f.next().?, 10);
    const base = try std.fmt.parseInt(usize, f.next().?, 10);
    const mod = try std.fmt.parseInt(usize, f.next().?, 10);
    const duration = try std.fmt.parseInt(i64, f.next().?, 10);
    const start = try std.fmt.parseInt(i64, f.next().?, 10);
    const cut = try std.fmt.parseInt(usize, f.next().?, 10);
    const tag_set = try std.fmt.parseInt(u8, f.next().?, 10);
    var text: [128]u8 = undefined;
    // The registry refuses other codecs before a muxer exists (FFmpeg's
    // "Unsupported codec id").
    const codec = std.meta.stringToEnum(Codec, codec_name) orelse return out.appendSlice(gpa, "H EINVAL\n");
    var stream_tags: metadata.Dictionary = .empty;
    defer stream_tags.deinit(gpa);
    var format_tags: metadata.Dictionary = .empty;
    defer format_tags.deinit(gpa);
    try caseTags(gpa, tag_set, &stream_tags, &format_tags);
    var header: [128]u8 = undefined;
    const extradata = caseExtradata(codec, rate, channels, padding, cut, &header);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var options: Options = .{ .format_tags = &format_tags };
    if (page_duration >= 0) options.page_duration = page_duration;
    if (serial_offset >= 0) options.serial_offset = @intCast(serial_offset);
    var m = Muxer.init(gpa, &output.writer, &.{.{ .codec = codec, .sample_rate = rate, .initial_padding = padding, .extradata = extradata, .tags = &stream_tags }}, options) catch |err| switch (err) {
        error.InvalidExtradata => return out.appendSlice(gpa, if (codec == .flac) "H EINVAL\n" else "H INVALIDDATA\n"),
        else => return err,
    };
    defer m.deinit();
    try m.writeHeader();
    try out.appendSlice(gpa, "H 0\n");
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var pts = start;
    for (0..count) |i| {
        const size = base + if (mod != 0) (i * 37) % mod else 0;
        try data.resize(gpa, size);
        for (data.items, 0..) |*b, j| b.* = @truncate(i * 7 + j * 13 + 1);
        try m.writePacket(0, data.items, pts, duration);
        pts += duration;
    }
    try m.finish();
    try out.appendSlice(gpa, "T 0\n");
    const bytes = output.written();
    var pos: usize = 0;
    while (pos + 27 <= bytes.len and std.mem.eql(u8, bytes[pos..][0..4], "OggS")) {
        const nsegs: usize = bytes[pos + 26];
        var body: usize = 0;
        for (bytes[pos + 27 ..][0..nsegs]) |seg| body += seg;
        const granule = std.mem.readInt(i64, bytes[pos + 6 ..][0..8], .little);
        const serial = std.mem.readInt(u32, bytes[pos + 14 ..][0..4], .little);
        const sequence = std.mem.readInt(u32, bytes[pos + 18 ..][0..4], .little);
        try out.appendSlice(gpa, try std.fmt.bufPrint(&text, "P {d} {d} {d} {d} {d} {d} {d}\n", .{ pos, bytes[pos + 5], granule, serial, sequence, nsegs, body }));
        pos += 27 + nsegs + body;
    }
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &digest, .{});
    try out.appendSlice(gpa, try std.fmt.bufPrint(&text, "M {d} {x}\n", .{ bytes.len, digest }));
}

test "every case muxes as FFmpeg's Ogg muxer does (vectors/oggmux.txt)" {
    const gpa = testing.allocator;
    var cases: usize = 0;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var case_line = lines.next();
    while (case_line) |c_line| {
        if (c_line.len == 0) {
            case_line = lines.next();
            continue;
        }
        try testing.expect(std.mem.startsWith(u8, c_line, "C "));
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        case_line = null;
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "C ")) {
                case_line = l;
                break;
            }
            if (l.len == 0) continue;
            try expected.appendSlice(gpa, l);
            try expected.append(gpa, '\n');
        }
        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(gpa);
        try runCase(gpa, c_line, &actual);
        testing.expectEqualStrings(expected.items, actual.items) catch |err| {
            std.debug.print("case: {s}\n", .{c_line});
            return err;
        };
        cases += 1;
    }
    try testing.expectEqual(28, cases);
}

test "an Ogg FLAC comment block past 24 bits of length is refused before any output" {
    const gpa = testing.allocator;
    const streaminfo: [flac_streaminfo_size]u8 = @splat(0);
    // The block: the vendor's length and bytes, the count, and one entry,
    // its length and `X=` before the value.
    const fixed = 4 + vendor.len + 4 + 4 + "X=".len;
    for ([_]bool{ false, true }) |over| {
        const value = try gpa.alloc(u8, std.math.maxInt(u24) - fixed + @intFromBool(over));
        defer gpa.free(value);
        @memset(value, 'a');
        var tags: metadata.Dictionary = .empty;
        defer tags.deinit(gpa);
        try tags.put(gpa, "X", value, .replace);
        var storage: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&storage);
        const streams = [_]Stream{.{ .codec = .flac, .sample_rate = 44100, .extradata = &streaminfo, .tags = &tags }};
        if (over) {
            try testing.expectError(error.TagsTooLong, checkTags(gpa, .flac, &tags, null));
            try testing.expectError(error.TagsTooLong, Muxer.init(gpa, &w, &streams, .{}));
            // Opus' and Vorbis' comment packets have no 24-bit bound.
            try checkTags(gpa, .opus, &tags, null);
            try checkTags(gpa, .vorbis, null, &tags);
        } else {
            try checkTags(gpa, .flac, &tags, null);
            var m = try Muxer.init(gpa, &w, &streams, .{});
            defer m.deinit();
            const block = m.streams[0].header[1];
            try testing.expectEqual(0x84, block[0]);
            try testing.expectEqual(std.math.maxInt(u24), std.mem.readInt(u24, block[1..4], .big));
            try testing.expectEqual(std.math.maxInt(u24), block.len - 4);
        }
        try testing.expectEqual(0, w.end);
    }
}
