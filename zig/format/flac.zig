// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/flacdec.c (flac_read_header, flac_probe, raw_flac_probe),
// rawdec.c (ff_raw_read_partial_packet), demux.c (read_frame_internal,
// parse_packet, compute_pkt_fields, update_initial_timestamps,
// update_initial_durations, avformat_find_stream_info's read-ahead,
// av_read_frame) and libavcodec/flac.c at the pinned reference revision
// describe the behavior, restated here; see
// zig/testing/fixtures/flac/README.md.
//! The FLAC demuxer (TODO.md T26a): native FLAC's metadata, then packets as
//! libavformat gives them to the ffmpeg program.
//!
//! The header is `fLaC` and metadata blocks, STREAMINFO first; the contract
//! in zig/testing/fixtures/flac/README.md says which are accepted. The
//! frames that follow go through FFmpeg's FLAC parser (flac_parser.zig) in
//! 1024-byte reads, and each packet gets libavformat's timestamps for a
//! parsed raw stream: the parser's frame-number timestamp where it has
//! one, otherwise the running time, kept relative until the first real
//! timestamp, as avformat_find_stream_info's read-ahead and av_read_frame
//! leave them.
//!
//! The demuxer allocates its parser's buffer, which holds about ten frames,
//! and the packets it has read ahead; a returned packet is borrowed until the
//! next call.

const std = @import("std");
const flac = @import("../codec/flac.zig");
/// The decoder for the demuxer's packets.
pub const decoder = @import("../codec/flacdec.zig");
const flac_parser = @import("../codec/flac_parser.zig");
const packet = @import("../core/packet.zig");
const time = @import("../core/time.zig");
const channel_layout = @import("../core/channel_layout.zig");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const diagnostics = @import("../core/diagnostics.zig");
const metadata = @import("../core/metadata.zig");
const bits = @import("../codec/bits.zig");

/// Contract errors (see the FLAC fixture README), plus `IoFailure` for a
/// failing reader and `OutOfMemory`.
pub const Error = error{
    InvalidFlac,
    Truncated,
    UnsupportedFormat,
    /// The decoded samples differ from STREAMINFO's count, which an output
    /// header written before them already holds (`DecodedReader`).
    FrameCountMismatch,
    /// STREAMINFO's MD5 differs from the decoded samples' (`DecodedReader`
    /// with `verify_md5`).
    Md5Mismatch,
    IoFailure,
    OutOfMemory,
};

/// A PICTURE block (ff_flac_parse_picture), which FFmpeg turns into an
/// attached picture; owned by the `Info`.
pub const Picture = struct {
    /// The ID3v2 picture type, 0 for one out of range.
    picture_type: u32,
    mime: []const u8,
    /// The codec FFmpeg gives the picture by its MIME type.
    codec: []const u8,
    description: []const u8,
    width: u32,
    height: u32,
    data: []const u8,
};

/// A CUESHEET track before the lead-out, which FFmpeg makes a chapter: from
/// its offset to the next track's, in samples, titled by its ISRC.
pub const Chapter = struct {
    start: u64,
    end: u64,
    title: []const u8,
};

/// A SEEKTABLE point.
pub const SeekPoint = struct {
    /// The first sample of the target frame; all ones for a placeholder.
    sample: u64,
    /// The frame's byte offset from the first frame.
    offset: u64,
    samples: u16,
};

/// The stream the header describes.
pub const Info = struct {
    /// Null for headerless input, whose parameters come from its first
    /// frame header.
    stream_info: ?flac.StreamInfo,
    /// The STREAMINFO block's bytes, FFmpeg's extradata for the stream.
    extradata: ?[flac.streaminfo_size]u8,
    channels: u8,
    layout: channel_layout.Layout,
    /// The rate the stream reports: STREAMINFO's, else the first frame's.
    sample_rate: u32,
    /// 4 to 32; 0 when neither STREAMINFO nor the first frame gives it.
    bps: u8,
    /// 1 / STREAMINFO's rate; for headerless input, 1 / the rate FFmpeg
    /// reads from the first frame's code; else FFmpeg's default 1/90000.
    time_base: time.TimeBase,
    /// Samples per channel, when STREAMINFO gives them with a rate.
    duration: ?u64,
    /// The frames' first bytes, already read past the metadata, which the
    /// demuxer reads first.
    prefix: [prefix_capacity]u8 = undefined,
    prefix_len: u8 = 0,
    /// Kept with an allocator (`readHeaderAlloc`): the format tags as FFmpeg
    /// reports them, the pictures, chapters and seek points.
    tags: metadata.Dictionary = .empty,
    pictures: []Picture = &.{},
    chapters: []Chapter = &.{},
    seek_points: []SeekPoint = &.{},

    pub fn deinit(info: *Info, gpa: std.mem.Allocator) void {
        info.tags.deinit(gpa);
        for (info.pictures) |p| {
            gpa.free(p.mime);
            gpa.free(p.description);
            gpa.free(p.data);
        }
        gpa.free(info.pictures);
        for (info.chapters) |c| gpa.free(c.title);
        gpa.free(info.chapters);
        gpa.free(info.seek_points);
        info.* = undefined;
    }

    /// The decoded storage: s16 up to 16 bits, else s32.
    pub fn sampleFormat(info: Info) audio.SampleFormat {
        return if (info.bps > 16) .s32 else .s16;
    }
};

/// The longest frame header with its first subframe byte.
const prefix_capacity = 17;

/// FFmpeg's `RAW_PACKET_SIZE`: the demuxer's reads.
pub const raw_packet_size = 1024;

/// The most bytes `probeScore` reads.
pub const probe_bytes = 4 + 4 + 13;

/// FFmpeg's content probe (flac_probe, raw_flac_probe), for the first bytes
/// of a stream: `fLaC` and a plausible STREAMINFO score 100, other `fLaC`
/// input 50, and a frame header at the start 13.
pub fn probeScore(head: []const u8) u8 {
    // The probe reads a zero-padded buffer.
    var padded: [probe_bytes]u8 = @splat(0);
    @memcpy(padded[0..@min(head.len, probe_bytes)], head[0..@min(head.len, probe_bytes)]);
    if (head.len > 0 and std.mem.readInt(u16, padded[0..2], .big) & 0xfffe == 0xfff8) {
        if (padded[2] & 0xf0 == 0) return 0; // block size code
        if (padded[2] & 0x0f == 0x0f) return 0; // sample rate code
        if (padded[3] & 0xf0 >= (flac.max_channels + 2) << 4) return 0; // channel mode
        if (padded[3] & 0x06 == 0x06) return 0; // sample size code
        if (padded[3] & 0x01 == 0x01) return 0; // reserved bit
        return 50 / 4 + 1;
    }
    if (head.len < probe_bytes or !std.mem.eql(u8, head[0..4], "fLaC")) return 0;
    const block_type = head[4] & 0x7f;
    const size = std.mem.readInt(u24, head[5..8], .big);
    const min_block = std.mem.readInt(u16, head[8..10], .big);
    const max_block = std.mem.readInt(u16, head[10..12], .big);
    const rate = std.mem.readInt(u24, head[18..21], .big) >> 4;
    if (block_type == 0 and size == flac.streaminfo_size and min_block >= 16 and max_block >= min_block and
        rate != 0 and rate <= 655350) return 100;
    return 50;
}

const block_streaminfo = 0;
const block_seektable = 3;
const block_vorbis_comment = 4;
const block_cuesheet = 5;
const block_picture = 6;

/// flacdec.c's rates for headerless input, by the first frame's code, in
/// units of 50 Hz.
const headerless_rates = [16]u16{ 0, 1764, 3528, 3840, 160, 320, 441, 480, 640, 882, 960, 1920, 0, 0, 0, 0 };

/// Reads the header without keeping tags, pictures, chapters or the seek
/// table: what probing needs, without allocating.
pub fn readHeader(reader: *std.Io.Reader) Error!Info {
    return readHeaderWith(reader, null);
}

/// Reads the header and keeps tags, pictures, chapters and the seek table,
/// allocated with `gpa`; free them with `Info.deinit`.
pub fn readHeaderAlloc(reader: *std.Io.Reader, gpa: std.mem.Allocator) Error!Info {
    return readHeaderWith(reader, gpa);
}

/// flac_read_header: `fLaC` and the metadata blocks, or headerless input.
fn readHeaderWith(reader: *std.Io.Reader, gpa: ?std.mem.Allocator) Error!Info {
    var marker: [4]u8 = undefined;
    try readExact(reader, &marker);
    if (!std.mem.eql(u8, &marker, "fLaC")) return headerless(reader, marker);

    var info: Info = .{
        .stream_info = null,
        .extradata = null,
        .channels = 0,
        .layout = .{ .unspecified = 0 },
        .sample_rate = 0,
        .bps = 0,
        .time_base = time.TimeBase.init(1, 90000) catch unreachable,
        .duration = null,
    };
    errdefer if (gpa) |a| info.deinit(a);
    var builder: TagBuilder = .{};
    defer if (gpa) |a| builder.deinit(a);
    var pictures: std.ArrayList(Picture) = .empty;
    var chapters: std.ArrayList(Chapter) = .empty;
    defer if (gpa) |a| {
        for (pictures.items) |p| {
            a.free(p.mime);
            a.free(p.description);
            a.free(p.data);
        }
        pictures.deinit(a);
        for (chapters.items) |c| a.free(c.title);
        chapters.deinit(a);
    };
    var channel_mask: ?u64 = null;
    var last = false;
    while (!last) {
        var block: [4]u8 = undefined;
        try readExact(reader, &block);
        last = block[0] & 0x80 != 0;
        const block_type = block[0] & 0x7f;
        const size = std.mem.readInt(u24, block[1..4], .big);
        switch (block_type) {
            block_streaminfo => {
                if (info.extradata != null or size != flac.streaminfo_size) return error.InvalidFlac;
                var body: [flac.streaminfo_size]u8 = undefined;
                try readExact(reader, &body);
                info.extradata = body;
                info.stream_info = flac.StreamInfo.parse(&body);
            },
            // FFmpeg reads these before STREAMINFO too.
            block_seektable => {
                if (gpa) |a| {
                    info.seek_points = try readSeekTable(reader, a, size);
                } else try skipBytes(reader, size);
            },
            block_cuesheet => try readCueSheet(reader, size, gpa, &chapters),
            block_picture => try readPicture(reader, size, gpa, &pictures),
            else => {
                // STREAMINFO must come first among the rest.
                if (info.extradata == null) return error.InvalidFlac;
                if (block_type == block_vorbis_comment) {
                    try readVorbisComment(reader, size, gpa, &builder, &channel_mask);
                } else try skipBytes(reader, size);
            },
        }
    }
    const si = info.stream_info orelse return error.InvalidFlac;
    // ff_flac_parse_streaminfo refuses these, and with them the decoder.
    if (si.max_blocksize < flac.min_blocksize or si.bps < 4) return error.InvalidFlac;
    info.channels = si.channels;
    info.layout = flac.channelLayout(si.channels);
    if (channel_mask) |mask| info.layout = .{ .native = mask };
    info.bps = si.bps;
    info.sample_rate = si.sample_rate;
    if (si.sample_rate > 0) {
        info.time_base = time.TimeBase.ofSampleRate(si.sample_rate) catch unreachable;
        if (si.samples > 0) info.duration = si.samples;
    } else {
        // The frames give the rate.
        try peekFirstFrame(reader, &info);
    }
    if (gpa) |a| {
        // ff_compute_chapters_end: each chapter ends where the next starts,
        // the last where the stream does.
        const items = chapters.items;
        for (items, 0..) |*c, i| {
            c.end = if (i + 1 < items.len) items[i + 1].start else @max(c.start, info.duration orelse c.start);
        }
        info.tags = try builder.finish(a);
        info.pictures = try pictures.toOwnedSlice(a);
        info.chapters = try chapters.toOwnedSlice(a);
    }
    return info;
}

/// FFmpeg's headerless mode: the marker is the first frame's start, its
/// rate code giving the time base; the first frame header gives the rest.
fn headerless(reader: *std.Io.Reader, marker: [4]u8) Error!Info {
    const rate = 50 * @as(u32, headerless_rates[marker[2] & 0xf]);
    var info: Info = .{
        .stream_info = null,
        .extradata = null,
        .channels = 0,
        .layout = .{ .unspecified = 0 },
        .sample_rate = 0,
        .bps = 0,
        .time_base = if (rate != 0) time.TimeBase.ofSampleRate(rate) catch unreachable else time.TimeBase.init(1, 90000) catch unreachable,
        .duration = null,
    };
    @memcpy(info.prefix[0..4], &marker);
    info.prefix_len = 4;
    try peekFirstFrame(reader, &info);
    if (info.channels == 0) return error.UnsupportedFormat;
    return info;
}

/// Reads the first frame's header into `info.prefix` and takes the stream's
/// parameters FFmpeg's parser reports from it: the channels and layout, the
/// rate and the sample size where STREAMINFO lacks them.
fn peekFirstFrame(reader: *std.Io.Reader, info: *Info) Error!void {
    const start = info.prefix_len;
    const n = reader.readSliceShort(info.prefix[start..]) catch return error.IoFailure;
    info.prefix_len += @intCast(n);
    var r = bits.BitReader.init(info.prefix[0..info.prefix_len]) catch unreachable;
    const fi = switch (flac.decodeFrameHeader(&r)) {
        .ok => |fi| fi,
        // No frame where the stream starts: what FFmpeg's parser finds
        // later is not modeled.
        .invalid => return,
    };
    if (info.stream_info == null) {
        info.channels = fi.channels;
        info.layout = flac.channelLayout(fi.channels);
        info.bps = fi.bps;
    }
    if (info.sample_rate == 0) info.sample_rate = fi.sample_rate;
}

fn readExact(reader: *std.Io.Reader, buffer: []u8) Error!void {
    reader.readSliceAll(buffer) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

fn skipBytes(reader: *std.Io.Reader, n: u64) Error!void {
    reader.discardAll64(n) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

fn readBytes(reader: *std.Io.Reader, gpa: std.mem.Allocator, n: usize) Error![]u8 {
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    try readExact(reader, out);
    return out;
}

/// A SEEKTABLE body: 18-byte points; a remainder is ignored, as FFmpeg's
/// division does.
fn readSeekTable(reader: *std.Io.Reader, gpa: std.mem.Allocator, size: u24) Error![]SeekPoint {
    const count = size / 18;
    const points = try gpa.alloc(SeekPoint, count);
    errdefer gpa.free(points);
    for (points) |*p| {
        var raw: [18]u8 = undefined;
        try readExact(reader, &raw);
        p.* = .{
            .sample = std.mem.readInt(u64, raw[0..8], .big),
            .offset = std.mem.readInt(u64, raw[8..16], .big),
            .samples = std.mem.readInt(u16, raw[16..18], .big),
        };
    }
    try skipBytes(reader, size % 18);
    return points;
}

/// The CUESHEET as flac_read_header reads it: at least 431 bytes, the track
/// count at offset 395, each track but the lead-out a chapter of its
/// offset, number and ISRC; a track without index points is `InvalidFlac`.
fn readCueSheet(reader: *std.Io.Reader, size: u24, gpa: ?std.mem.Allocator, chapters: *std.ArrayList(Chapter)) Error!void {
    if (size < 431) return error.InvalidFlac;
    try skipBytes(reader, 395);
    var count_byte: [1]u8 = undefined;
    try readExact(reader, &count_byte);
    var used: u64 = 396;
    const tracks = @as(i32, count_byte[0]) - 1;
    if (tracks <= 0) return error.InvalidFlac;
    var starts: [255]u64 = undefined;
    var titles: [255][12]u8 = undefined;
    for (0..@intCast(tracks)) |i| {
        if (used + 36 > size) return error.InvalidFlac;
        var track: [36]u8 = undefined;
        try readExact(reader, &track);
        used += 36;
        starts[i] = std.mem.readInt(u64, track[0..8], .big);
        @memcpy(&titles[i], track[9..21]);
        const index_points = track[35];
        if (index_points == 0) return error.InvalidFlac;
        // The index points are skipped; FFmpeg does not bound them.
        const skip = @as(u64, index_points) * 12;
        if (used + skip > size) return error.Truncated;
        try skipBytes(reader, skip);
        used += skip;
    }
    try skipBytes(reader, size - used);
    const a = gpa orelse return;
    for (0..@intCast(tracks)) |i| {
        // avpriv_new_chapter gives each chapter its own start and no end;
        // FFmpeg's chapter end is the next one's start, or unknown.
        const title_len = std.mem.findScalar(u8, &titles[i], 0) orelse 12;
        const title = try a.dupe(u8, titles[i][0..title_len]);
        errdefer a.free(title);
        try chapters.append(a, .{ .start = starts[i], .end = 0, .title = title });
    }
}

/// ff_flac_parse_picture without AV_EF_EXPLODE: a malformed block is
/// skipped, as FFmpeg skips it with a log message.
fn readPicture(reader: *std.Io.Reader, size: u24, gpa: ?std.mem.Allocator, pictures: *std.ArrayList(Picture)) Error!void {
    const a = gpa orelse return skipBytes(reader, size);
    const body = try readBytes(reader, a, size);
    defer a.free(body);
    if (body.len < 34) return;
    var at: usize = 0;
    const field = struct {
        fn be32(b: []const u8, i: *usize) u32 {
            const v = std.mem.readInt(u32, b[i.*..][0..4], .big);
            i.* += 4;
            return v;
        }
    }.be32;
    var picture_type = field(body, &at);
    if (picture_type >= id3v2_picture_types) picture_type = 0;
    const mime_len = field(body, &at);
    if (mime_len == 0 or mime_len >= 64) return;
    if (mime_len + 24 > body.len - at) return;
    const mime = body[at..][0..mime_len];
    at += mime_len;
    const codec = pictureCodec(mime) orelse return;
    const desc_len = field(body, &at);
    if (desc_len > body.len - at -| 20 or body.len - at < 20) return;
    const description = body[at..][0..desc_len];
    at += desc_len;
    const width = field(body, &at);
    const height = field(body, &at);
    at += 8;
    const data_len = field(body, &at);
    // FFmpeg's workaround for a 24-bit block size is not modeled: such a
    // picture runs past its block, which the parser refuses here.
    if (data_len == 0 or data_len > body.len - at) return;
    const owned_mime = try a.dupe(u8, mime);
    errdefer a.free(owned_mime);
    const owned_desc = try a.dupe(u8, description);
    errdefer a.free(owned_desc);
    const data = try a.dupe(u8, body[at..][0..data_len]);
    errdefer a.free(data);
    try pictures.append(a, .{
        .picture_type = picture_type,
        .mime = owned_mime,
        .codec = codec,
        .description = owned_desc,
        .width = width,
        .height = height,
        .data = data,
    });
}

/// `ff_id3v2_picture_types`' length.
const id3v2_picture_types = 21;

/// `ff_id3v2_mime_tags`: the codec FFmpeg gives a picture's MIME type.
fn pictureCodec(mime: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "image/gif", "gif" },
        .{ "image/jpeg", "mjpeg" },
        .{ "image/jpg", "mjpeg" },
        .{ "image/png", "png" },
        .{ "image/tiff", "tiff" },
        .{ "image/bmp", "bmp" },
        .{ "image/webp", "webp" },
        .{ "image/jxl", "jpegxl" },
        .{ "JPG", "mjpeg" },
        .{ "PNG", "png" },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], mime)) return entry[1];
    return null;
}

/// ff_vorbis_comment's tags, built as libavutil's dictionary builds them.
const TagBuilder = struct {
    tags: metadata.Dictionary = .empty,

    fn deinit(b: *TagBuilder, gpa: std.mem.Allocator) void {
        b.tags.deinit(gpa);
    }

    /// `av_dict_set` with AV_DICT_APPEND: the old value and `value`, the
    /// entry replaced (the last one moves into its place).
    fn append(b: *TagBuilder, gpa: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
        const old = b.tags.get(key) orelse "";
        const joined = try std.mem.concat(gpa, u8, &.{ old, value });
        defer gpa.free(joined);
        b.tags.put(gpa, key, joined, .replace) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Keys and values from comments hold no NUL here: a comment with
            // one is cut there, as FFmpeg's C strings are.
            else => unreachable,
        };
    }

    /// ff_metadata_conv: five keys renamed, exact duplicates dropped.
    fn finish(b: *TagBuilder, gpa: std.mem.Allocator) Error!metadata.Dictionary {
        var out: metadata.Dictionary = .empty;
        errdefer out.deinit(gpa);
        for (b.tags.items()) |entry| {
            var key = entry.key;
            for (vorbis_conv) |conv| {
                if (std.ascii.eqlIgnoreCase(key, conv[0])) key = conv[1];
            }
            out.put(gpa, key, entry.value, .keep_distinct) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => unreachable,
            };
        }
        return out;
    }
};

/// ff_vorbiscomment_metadata_conv.
const vorbis_conv = [_]struct { []const u8, []const u8 }{
    .{ "ALBUMARTIST", "album_artist" },
    .{ "TRACKNUMBER", "track" },
    .{ "DISCNUMBER", "disc" },
    .{ "DISCSUBTITLE", "disc_subtitle" },
    .{ "DESCRIPTION", "comment" },
};

/// The longest comment `readVorbisComment` reads into memory without an
/// allocator, enough for the channel mask's key and value.
const mask_comment_capacity = 64;

/// ff_vorbis_comment: the vendor string, then comments of `KEY=value`;
/// a comment without '=', an empty key or value, or a picture is not a tag.
/// FFmpeg only logs a malformed block, so it is not an error. The
/// `WAVEFORMATEXTENSIBLE_CHANNEL_MASK` tag sets the layout, as
/// flac_read_header reads it, and is not reported.
fn readVorbisComment(reader: *std.Io.Reader, size: u24, gpa: ?std.mem.Allocator, builder: *TagBuilder, mask: *?u64) Error!void {
    var left: u64 = size;
    if (size < 8) return skipBytes(reader, size);
    var word: [4]u8 = undefined;
    try readExact(reader, &word);
    left -= 4;
    const vendor = std.mem.readInt(u32, &word, .little);
    if (vendor > std.math.maxInt(i32) or left - 4 < vendor) return skipBytes(reader, left);
    try skipBytes(reader, vendor);
    left -= vendor;
    try readExact(reader, &word);
    left -= 4;
    var count = std.mem.readInt(u32, &word, .little);
    var first_mask: ?[]const u8 = null;
    var mask_text: [mask_comment_capacity]u8 = undefined;
    while (left >= 4 and count > 0) : (count -= 1) {
        try readExact(reader, &word);
        left -= 4;
        const len = std.mem.readInt(u32, &word, .little);
        if (len > left or len > std.math.maxInt(i32)) break;
        left -= len;
        if (gpa) |a| {
            const comment = try readBytes(reader, a, len);
            defer a.free(comment);
            try addComment(a, builder, comment);
        } else if (len <= mask_text.len) {
            try readExact(reader, mask_text[0..len]);
            const comment = mask_text[0..len];
            if (first_mask == null) first_mask = maskValue(comment);
        } else try skipBytes(reader, len);
    }
    try skipBytes(reader, left);
    // The mask, by the first comment carrying it (`strtol` stops at the
    // ';' a repeated key's value gets).
    const value = if (gpa != null) builder.tags.get("WAVEFORMATEXTENSIBLE_CHANNEL_MASK") else first_mask;
    if (value) |text| {
        const number = channel_layout.strtol(text, 0);
        const m: u64 = @bitCast(number.value);
        if (m != 0 and m & ~@as(u64, 0x3ffff) == 0) {
            mask.* = m;
            if (gpa) |a| _ = builder.tags.remove(a, "WAVEFORMATEXTENSIBLE_CHANNEL_MASK");
        }
    }
}

/// The channel mask's value in a comment, if it is that tag.
fn maskValue(comment: []const u8) ?[]const u8 {
    const eq = std.mem.findScalar(u8, comment, '=') orelse return null;
    if (!std.ascii.eqlIgnoreCase(comment[0..eq], "WAVEFORMATEXTENSIBLE_CHANNEL_MASK") or eq + 1 == comment.len) return null;
    return comment[eq + 1 ..];
}

/// vorbis_parse_single_comment for one comment.
fn addComment(gpa: std.mem.Allocator, builder: *TagBuilder, raw: []const u8) Error!void {
    // FFmpeg's C strings end at a NUL.
    const comment = raw[0 .. std.mem.findScalar(u8, raw, 0) orelse raw.len];
    const eq = std.mem.findScalar(u8, comment, '=') orelse return;
    const key = comment[0..eq];
    const value = comment[eq + 1 ..];
    if (key.len == 0 or value.len == 0) return;
    // Pictures in comments and OGM chapters are not tags.
    if (std.ascii.eqlIgnoreCase(key, "METADATA_BLOCK_PICTURE")) return;
    if (builder.tags.get(key) != null) try builder.append(gpa, key, ";");
    try builder.append(gpa, key, value);
}

/// libavformat's base for timestamps it counts before knowing the first.
const relative_ts_base: i64 = std.math.maxInt(i64) - (1 << 48);
const nopts: i64 = std.math.minInt(i64);

fn isRelative(ts: i64) bool {
    return ts > relative_ts_base - (1 << 48);
}

/// A packet libavformat holds before returning it, timestamps in its
/// representation (`nopts` for none).
const Queued = struct {
    data: []u8,
    pts: i64,
    dts: i64,
    duration: i64,
};

/// avformat_find_stream_info reads at most this many packets ahead
/// (`max_ts_probe`) while the first timestamp is unknown, and at most
/// `probesize` bytes.
const max_ts_probe = 50;
const probesize = 5_000_000;

pub const Demuxer = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    info: Info,
    parser: flac_parser.Parser,
    /// avformat_find_stream_info's packets, then the parser's queue: what
    /// the timestamp fix-ups reach.
    packet_buffer: std.ArrayList(Queued) = .empty,
    parse_queue: std.ArrayList(Queued) = .empty,
    /// The packet returned last, freed on the next call.
    current: ?[]u8 = null,
    cur_dts: i64 = relative_ts_base,
    first_dts: i64 = nopts,
    durations_done: bool = false,
    /// The stream's start time, once a timestamp sets it.
    start_time: ?i64 = null,
    probing: bool = true,
    eof: bool = false,

    /// Reads the header, keeping its tags, pictures, chapters and seek
    /// table; packets follow with `next`.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Error!Demuxer {
        const info = try readHeaderAlloc(reader, gpa);
        return .{ .gpa = gpa, .reader = reader, .info = info, .parser = .init(gpa) };
    }

    pub fn deinit(d: *Demuxer) void {
        d.info.deinit(d.gpa);
        for (d.packet_buffer.items) |q| d.gpa.free(q.data);
        for (d.parse_queue.items) |q| d.gpa.free(q.data);
        d.packet_buffer.deinit(d.gpa);
        d.parse_queue.deinit(d.gpa);
        if (d.current) |c| d.gpa.free(c);
        d.parser.deinit();
        d.* = undefined;
    }

    /// The next packet, borrowed until the next call; null at the end.
    pub fn next(d: *Demuxer) Error!?packet.Packet {
        if (d.current) |c| d.gpa.free(c);
        d.current = null;
        if (d.probing) {
            // avformat_find_stream_info: read ahead until a timestamp sets
            // the stream's first.
            var count: usize = 0;
            var bytes: u64 = 0;
            while (d.first_dts == nopts and count < max_ts_probe and bytes < probesize) {
                const q = try d.readFrameInternal() orelse break;
                d.packet_buffer.append(d.gpa, q) catch |err| {
                    d.gpa.free(q.data);
                    return err;
                };
                count += 1;
                bytes += q.data.len;
            }
            d.probing = false;
        }
        const q = if (d.packet_buffer.items.len > 0)
            d.packet_buffer.orderedRemove(0)
        else
            try d.readFrameInternal() orelse return null;
        d.current = q.data;
        var pts = q.pts;
        var dts = q.dts;
        if (isRelative(dts)) dts -= relative_ts_base;
        if (isRelative(pts)) pts -= relative_ts_base;
        return .{
            .data = q.data,
            .time_base = d.info.time_base,
            .pts = if (pts == nopts) null else pts,
            .dts = if (dts == nopts) null else dts,
            .duration = if (q.duration == 0) null else q.duration,
            .flags = .{ .key = true },
        };
    }

    /// read_frame_internal: the parser's next packet, reading and parsing
    /// as needed; at the end of the input the parser is flushed.
    fn readFrameInternal(d: *Demuxer) Error!?Queued {
        while (d.parse_queue.items.len == 0) {
            if (d.eof) {
                // FFmpeg flushes again on every read after the end.
                try d.parsePacket(&.{}, true);
                break;
            }
            var chunk: [raw_packet_size]u8 = undefined;
            // The frame bytes the header peeked come first, as FFmpeg's
            // reads start where the frames do.
            const prefix = d.info.prefix_len;
            @memcpy(chunk[0..prefix], d.info.prefix[0..prefix]);
            d.info.prefix_len = 0;
            const n = prefix + (d.reader.readSliceShort(chunk[prefix..]) catch return error.IoFailure);
            if (n == 0) {
                d.eof = true;
                try d.parsePacket(&.{}, true);
                break;
            }
            try d.parsePacket(chunk[0..n], false);
        }
        if (d.parse_queue.items.len == 0) return null;
        return d.parse_queue.orderedRemove(0);
    }

    /// parse_packet: everything the parser makes of `input`, into the
    /// parse queue with its timestamps.
    fn parsePacket(d: *Demuxer, input: []const u8, flush: bool) Error!void {
        var rest = input;
        var got_output = flush;
        while (rest.len > 0 or (flush and got_output)) {
            const out = try d.parser.parse(rest);
            rest = rest[out.consumed..];
            const frame = out.frame orelse {
                got_output = false;
                continue;
            };
            got_output = true;
            var duration: i64 = 0;
            if (out.sample_rate > 0 and out.duration > 0) {
                // av_rescale_q_rnd from 1/rate to the time base, rounding down.
                const tb = d.info.time_base;
                duration = @intCast(@as(u64, out.duration) * tb.den / (@as(u64, out.sample_rate) * tb.num));
            }
            const data = try d.gpa.dupe(u8, frame);
            errdefer d.gpa.free(data);
            var q: Queued = .{ .data = data, .pts = out.pts orelse nopts, .dts = nopts, .duration = duration };
            d.computePktFields(&q);
            try d.parse_queue.append(d.gpa, q);
        }
    }

    fn queued(d: *Demuxer) bool {
        return d.packet_buffer.items.len > 0 or d.parse_queue.items.len > 0;
    }

    /// compute_pkt_fields for an audio stream without reordering.
    fn computePktFields(d: *Demuxer, q: *Queued) void {
        if (q.duration > 0 and d.queued()) d.updateInitialDurations(q.duration);
        if (q.pts != nopts or q.dts != nopts or q.duration > 0) {
            // Presentation is not delayed: pts and dts are the same.
            if (q.pts == nopts) q.pts = q.dts;
            d.updateInitialTimestamps(q.pts, q.pts);
            if (q.pts == nopts) q.pts = d.cur_dts;
            q.dts = q.pts;
            if (q.pts != nopts) d.cur_dts = q.pts +% q.duration;
        }
        if (q.dts > d.cur_dts) d.cur_dts = q.dts;
    }

    /// Every packet libavformat still holds, in order.
    fn heldPackets(d: *Demuxer) [2][]Queued {
        return .{ d.packet_buffer.items, d.parse_queue.items };
    }

    /// update_initial_timestamps: the first real timestamp fixes the
    /// relative ones held so far, and the start time.
    fn updateInitialTimestamps(d: *Demuxer, dts: i64, pts_in: i64) void {
        const int_min: i64 = std.math.minInt(i32);
        if (d.first_dts != nopts or dts == nopts or d.cur_dts == nopts or
            d.cur_dts < int_min + relative_ts_base or
            dts < int_min + (d.cur_dts - relative_ts_base) or isRelative(dts)) return;
        d.first_dts = dts - (d.cur_dts - relative_ts_base);
        d.cur_dts = dts;
        const shift: i64 = d.first_dts -% relative_ts_base;
        var pts = pts_in;
        if (isRelative(pts)) pts +%= shift;
        for (d.heldPackets()) |list| for (list) |*held| {
            if (isRelative(held.pts)) held.pts +%= shift;
            if (isRelative(held.dts)) held.dts +%= shift;
            if (d.start_time == null and held.pts != nopts) d.start_time = held.pts;
        };
        // update_dts_from_pts: without reordering, a held packet's missing
        // dts becomes its pts.
        for (d.heldPackets()) |list| for (list) |*held| {
            if (held.pts != nopts and held.dts == nopts) held.dts = held.pts;
        };
        if (d.start_time == null) d.start_time = if (pts == nopts) null else pts;
    }

    /// update_initial_durations: held packets with neither timestamps nor a
    /// duration get the first known duration, counted back from the first
    /// timestamp.
    fn updateInitialDurations(d: *Demuxer, duration: i64) void {
        var cur_dts: i64 = relative_ts_base;
        var list_index: usize = 0;
        var item: usize = 0;
        const held = d.heldPackets();
        if (d.first_dts != nopts) {
            if (d.durations_done) return;
            d.durations_done = true;
            cur_dts = d.first_dts;
            // Count back over the leading packets without timestamps.
            var found: ?*Queued = null;
            outer: for (held) |list| for (list) |*p| {
                if (p.pts != p.dts or p.dts != nopts or p.duration != 0) {
                    found = p;
                    break :outer;
                }
                cur_dts -%= duration;
            };
            const first = found orelse return;
            if (first.dts != d.first_dts) return;
            d.first_dts = cur_dts;
        } else if (d.cur_dts != relative_ts_base) return;
        var reached_end = true;
        outer: while (list_index < held.len) : ({
            list_index += 1;
            item = 0;
        }) {
            while (item < held[list_index].len) : (item += 1) {
                const p = &held[list_index][item];
                if ((p.pts == p.dts or p.pts == nopts) and
                    (p.dts == nopts or p.dts == d.first_dts or p.dts == relative_ts_base) and
                    p.duration == 0 and !addOverflows(cur_dts, duration))
                {
                    p.dts = cur_dts;
                    p.pts = cur_dts;
                    p.duration = duration;
                } else {
                    reached_end = false;
                    break :outer;
                }
                cur_dts = p.dts +% p.duration;
            }
        }
        if (reached_end) d.cur_dts = cur_dts;
    }
};

/// A FLAC input as the conversion pipeline reads PCM (format/convert.zig):
/// the decoder's frames as pcm_s16le bytes, or pcm_s32le above 16 bits per
/// sample, whole frames per read.
///
/// A packet the decoder refuses is reported to the diagnostic sink and
/// skipped, as the ffmpeg program skips it. Because the pipeline writes an
/// output header holding STREAMINFO's sample count, rate and channels
/// before the samples, a stream that decodes to another count fails with
/// `FrameCountMismatch` (before the extra samples, or at `finish` for
/// missing ones), and a frame that changes the rate or the channels with
/// `UnsupportedFormat`, where FFmpeg would rewrite a seekable output's
/// header or reconfigure its filters. With `verify_md5`, `finish` checks
/// STREAMINFO's MD5, when it has one, against the decoded samples
/// (`Md5Mismatch`); FFmpeg never checks it.
pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    sink: ?diagnostics.Sink,
    verify_md5: bool = false,
    demuxer: ?Demuxer = null,
    decoder: ?decoder.Decoder = null,
    /// The current frame's samples not yet delivered, borrowed from the
    /// decoder.
    pending: decoder.Samples = .{ .s16 = &.{} },
    channels: u8 = 0,
    sample_rate: u32 = 0,
    bps: u8 = 0,
    delivered: u64 = 0,
    expected: ?u64 = null,
    ended: bool = false,
    md5: std.crypto.hash.Md5 = .init(.{}),

    pub const Header = struct {
        /// The encoding of the bytes `readData` gives.
        codec: pcm.Codec,
        format: audio.Format,
        /// STREAMINFO's sample count, when it has one.
        frame_count: ?u64,
    };

    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, sink: ?diagnostics.Sink) DecodedReader {
        return .{ .gpa = gpa, .reader = reader, .sink = sink };
    }

    pub fn deinit(r: *DecodedReader) void {
        if (r.decoder) |*d| d.deinit();
        if (r.demuxer) |*d| d.deinit();
        r.* = undefined;
    }

    pub fn readHeader(r: *DecodedReader) Error!Header {
        std.debug.assert(r.demuxer == null);
        r.demuxer = try Demuxer.init(r.gpa, r.reader);
        const info = r.demuxer.?.info;
        r.decoder = decoder.Decoder.init(r.gpa, info.stream_info) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // readHeader refused what the decoder refuses.
            error.InvalidData => unreachable,
        };
        // A rate or sample size neither STREAMINFO nor the first frame gives
        // cannot head an output.
        if (info.sample_rate == 0 or info.bps == 0) return error.UnsupportedFormat;
        r.channels = info.channels;
        r.sample_rate = info.sample_rate;
        r.bps = info.bps;
        r.expected = info.duration;
        const format = audio.Format.initLayout(info.sample_rate, info.layout, info.sampleFormat()) catch return error.UnsupportedFormat;
        return .{ .codec = if (info.bps > 16) .s32le else .s16le, .format = format, .frame_count = info.duration };
    }

    fn pendingFrames(r: *const DecodedReader) usize {
        return switch (r.pending) {
            inline else => |s| s.len / r.channels,
        };
    }

    /// Whole frames of samples into `output`, at least one while any remain
    /// (one frame fits in 32 bytes); empty at the end.
    pub fn readData(r: *DecodedReader, output: []u8) Error![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const width: usize = if (r.bps > 16) 4 else 2;
        const frame_bytes = width * r.channels;
        const frames = @min(output.len / frame_bytes, r.pendingFrames());
        std.debug.assert(frames > 0);
        if (r.expected) |expected| {
            if (r.delivered + frames > expected) return error.FrameCountMismatch;
        }
        const count = frames * r.channels;
        switch (r.pending) {
            .s16 => |s| {
                for (s[0..count], 0..) |sample, i| std.mem.writeInt(i16, output[2 * i ..][0..2], sample, .little);
                r.pending = .{ .s16 = s[count..] };
            },
            .s32 => |s| {
                for (s[0..count], 0..) |sample, i| std.mem.writeInt(i32, output[4 * i ..][0..4], sample, .little);
                r.pending = .{ .s32 = s[count..] };
            },
        }
        r.delivered += frames;
        const data = output[0 .. frames * frame_bytes];
        if (r.verify_md5) r.hashSamples(data, width);
        return data;
    }

    /// The FLAC format's MD5 input: each sample unshifted, signed
    /// little-endian in the fewest whole bytes holding `bps`.
    fn hashSamples(r: *DecodedReader, data: []const u8, width: usize) void {
        const shift: u5 = @intCast(@as(u8, @intCast(width * 8)) - r.bps);
        const bytes_out = (r.bps + 7) / 8;
        var i: usize = 0;
        while (i < data.len) : (i += width) {
            const stored: i32 = if (width == 2) std.mem.readInt(i16, data[i..][0..2], .little) else std.mem.readInt(i32, data[i..][0..4], .little);
            var le: [4]u8 = undefined;
            std.mem.writeInt(i32, &le, stored >> shift, .little);
            r.md5.update(le[0..bytes_out]);
        }
    }

    /// The next decoded frame into `pending`; false at the end.
    fn nextFrame(r: *DecodedReader) Error!bool {
        if (r.ended) return false;
        const dec = &r.decoder.?;
        while (true) {
            const frame = dec.receive() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidData => {
                    diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                    continue;
                },
            };
            if (frame) |f| {
                if (f.channels != r.channels or f.sample_rate != r.sample_rate) return error.UnsupportedFormat;
                r.pending = f.samples;
                return true;
            }
            const p = try r.demuxer.?.next() orelse {
                r.ended = true;
                return false;
            };
            dec.send(p.data, p.pts);
        }
    }

    /// Checks that the stream decoded to STREAMINFO's count and, with
    /// `verify_md5`, to its MD5.
    pub fn finish(r: *DecodedReader) Error!void {
        std.debug.assert(r.pendingFrames() == 0);
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
        if (r.verify_md5) {
            const info = r.demuxer.?.info.stream_info orelse return;
            if (std.mem.allEqual(u8, &info.md5, 0)) return;
            var digest: [16]u8 = undefined;
            r.md5.final(&digest);
            if (!std.mem.eql(u8, &digest, &info.md5)) return error.Md5Mismatch;
        }
    }
};

fn addOverflows(a: i64, b: i64) bool {
    _ = std.math.add(i64, a, b) catch return true;
    return false;
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");

test "the probe scores FFmpeg's way" {
    try testing.expectEqual(100, probeScore(fixtures.flac.bytes("flac_constant_mono_8k")));
    try testing.expectEqual(50, probeScore(fixtures.flac.bytes("flac_no_streaminfo")));
    try testing.expectEqual(13, probeScore(fixtures.flac.bytes("flac_headerless")));
    try testing.expectEqual(0, probeScore("RIFF"));
    try testing.expectEqual(0, probeScore(""));
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try testing.expectError(error.IoFailure, readHeader(&reader));
}

const vectors = @embedFile("../testing/vectors/flac.txt");

/// The oracle's lines for fixture `name`, without the `F` line.
fn vectorBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "F ")) {
            const at = @intFromPtr(line.ptr) - @intFromPtr(vectors.ptr);
            if (start) |s| return vectors[s..at];
            if (std.mem.eql(u8, line[2..], name)) start = at + line.len + 1;
        }
    }
    if (start) |s| return vectors[s..];
    return null;
}

fn formatTs(buf: []u8, ts: ?i64) []const u8 {
    return if (ts) |t| std.fmt.bufPrint(buf, "{d}", .{t}) catch unreachable else "N";
}

/// The `P` lines the demuxer gives for `bytes`, as flac_vectors.c prints
/// them.
fn packetLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var d = try Demuxer.init(gpa, &reader);
    defer d.deinit();
    while (try d.next()) |p| {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "P {d} {s} {s} {d} 0x{x} 0x{x:0>8}\n", .{
            p.data.len,
            formatTs(&a, p.pts),
            formatTs(&b, p.dts),
            p.duration orelse 0,
            @as(u32, if (p.flags.key) 1 else 0),
            std.hash.Adler32.permute(0, p.data),
        });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
}

test "every fixture's packets equal FFmpeg's (vectors/flac.txt)" {
    const gpa = testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        const bytes = fixtures.flac.bytes(fixture.name);
        const block = vectorBlock(fixture.name) orelse return error.MissingVector;
        switch (fixture.expected) {
            .reject => |failure| {
                var reader: std.Io.Reader = .fixed(bytes);
                const expected: Error = switch (failure) {
                    .InvalidFlac => error.InvalidFlac,
                    .Truncated => error.Truncated,
                    .UnsupportedFormat => error.UnsupportedFormat,
                };
                try testing.expectError(expected, readHeader(&reader));
            },
            .accept, .damaged => {
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                var lines = std.mem.splitScalar(u8, block, '\n');
                while (lines.next()) |line| {
                    if (!std.mem.startsWith(u8, line, "P ")) continue;
                    try expected.appendSlice(gpa, line);
                    try expected.append(gpa, '\n');
                }
                var actual: std.ArrayList(u8) = .empty;
                defer actual.deinit(gpa);
                try packetLines(gpa, bytes, &actual);
                testing.expectEqualStrings(expected.items, actual.items) catch |err| {
                    std.debug.print("fixture {s}\n", .{fixture.name});
                    return err;
                };
            },
        }
    }
}

test "the demuxer's packets do not depend on the reader's buffer" {
    const gpa = testing.allocator;
    const bytes = fixtures.flac.bytes("flac_junk_between_frames");
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(gpa);
    try packetLines(gpa, bytes, &whole);
    var reader: std.testing.Reader = .init(&.{}, &.{.{ .buffer = bytes }});
    reader.artificial_limit = .limited(1);
    var d = try Demuxer.init(gpa, &reader.interface);
    defer d.deinit();
    var count: usize = 0;
    while (try d.next()) |_| count += 1;
    try testing.expectEqual(std.mem.count(u8, whole.items, "\n"), count);
}

const flacdec = decoder;

/// The `P`, `D` and `X` lines of flac_vectors.c for `bytes`, and the SHA-256
/// and count of every decoded sample.
fn decodeLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8), samples_sha: *std.crypto.hash.sha2.Sha256, frames: *u64) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var d = try Demuxer.init(gpa, &reader);
    defer d.deinit();
    var dec = try flacdec.Decoder.init(gpa, d.info.stream_info);
    defer dec.deinit();
    var line_buf: [128]u8 = undefined;
    while (try d.next()) |p| {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&line_buf, "P {d} {s} {s} {d} 0x{x} 0x{x:0>8}\n", .{
            p.data.len, formatTs(&a, p.pts), formatTs(&b, p.dts), p.duration orelse 0, @as(u32, if (p.flags.key) 1 else 0), std.hash.Adler32.permute(0, p.data),
        }));
        dec.send(p.data, p.pts);
        while (true) {
            const frame = dec.receive() catch |err| {
                try out.appendSlice(gpa, switch (err) {
                    error.InvalidData => "X INVALIDDATA\n",
                    error.OutOfMemory => return error.OutOfMemory,
                });
                continue;
            } orelse break;
            var adler: std.hash.Adler32 = .{ .adler = 0 };
            switch (frame.samples) {
                inline else => |samples| for (samples) |s| {
                    var le: [@sizeOf(@TypeOf(s))]u8 = undefined;
                    std.mem.writeInt(@TypeOf(s), &le, s, .little);
                    adler.update(&le);
                    samples_sha.update(&le);
                },
            }
            frames.* += frame.nb_samples;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&line_buf, "D {d} {s} 0x{x:0>8}\n", .{ frame.nb_samples, formatTs(&a, frame.pts), adler.adler }));
        }
    }
}

test "every fixture decodes as FFmpeg decodes it, accepted ones to their samples" {
    const gpa = testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        switch (fixture.expected) {
            .reject => {},
            .accept, .damaged => {
                const block = vectorBlock(fixture.name) orelse return error.MissingVector;
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                var lines = std.mem.splitScalar(u8, block, '\n');
                while (lines.next()) |line| {
                    if (line.len < 2 or std.mem.findScalar(u8, "PDX", line[0]) == null or line[1] != ' ') continue;
                    try expected.appendSlice(gpa, line);
                    try expected.append(gpa, '\n');
                }
                var actual: std.ArrayList(u8) = .empty;
                defer actual.deinit(gpa);
                var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
                var frames: u64 = 0;
                try decodeLines(gpa, fixtures.flac.bytes(fixture.name), &actual, &sha, &frames);
                testing.expectEqualStrings(expected.items, actual.items) catch |err| {
                    std.debug.print("fixture {s}\n", .{fixture.name});
                    return err;
                };
                if (fixture.expected == .accept) {
                    const stream = fixture.expected.accept;
                    try testing.expectEqual(stream.frames, frames);
                    const digest = std.fmt.bytesToHex(sha.finalResult(), .lower);
                    try testing.expectEqualStrings(stream.pcm_sha256, &digest);
                }
            },
        }
    }
}

test "the demuxer frees everything under every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var reader: std.Io.Reader = .fixed(fixtures.flac.bytes("flac_junk_between_frames"));
            var d = try Demuxer.init(gpa, &reader);
            defer d.deinit();
            while (try d.next()) |_| {}
        }
    }.run, .{});
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [4096]u8 = undefined;
    const len = smith.slice(&input);
    // Demux and decode arbitrary bytes: errors are fine, crashes, leaks and
    // unbounded loops are not.
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var r: DecodedReader = .init(testing.allocator, &reader, null);
    defer r.deinit();
    _ = r.readHeader() catch return;
    var out: [4096]u8 = undefined;
    while (true) {
        const data = r.readData(&out) catch return;
        if (data.len == 0) break;
    }
    r.finish() catch {};
}

test "fuzz: the demuxer and decoder on arbitrary input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.flac.bytes("flac_constant_mono_8k"),
        fixtures.flac.bytes("flac_lpc_zero_shift"),
        fixtures.flac.bytes("flac_junk_between_frames"),
        fixtures.flac.bytes("flac_mid_side"),
    } });
}

test "every fixture's tags, chapters and pictures equal FFmpeg's" {
    const gpa = testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        if (fixture.expected != .reject) {
            const block = vectorBlock(fixture.name) orelse return error.MissingVector;
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(gpa);
            var lines = std.mem.splitScalar(u8, block, '\n');
            while (lines.next()) |line| {
                if (line.len < 2 or std.mem.findScalar(u8, "MCA", line[0]) == null or line[1] != ' ') continue;
                try expected.appendSlice(gpa, line);
                try expected.append(gpa, '\n');
            }
            var reader: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
            var info = try readHeaderAlloc(&reader, gpa);
            defer info.deinit(gpa);
            var actual: std.ArrayList(u8) = .empty;
            defer actual.deinit(gpa);
            for (info.tags.items()) |tag| {
                const line = try std.fmt.allocPrint(gpa, "M {s}={s}\n", .{ tag.key, tag.value });
                defer gpa.free(line);
                try actual.appendSlice(gpa, line);
            }
            for (info.chapters) |c| {
                const line = try std.fmt.allocPrint(gpa, "C {d} {d} {d}/{d} {s}\n", .{ c.start, c.end, info.time_base.num, info.time_base.den, c.title });
                defer gpa.free(line);
                try actual.appendSlice(gpa, line);
            }
            for (info.pictures, 1..) |p, i| {
                const line = try std.fmt.allocPrint(gpa, "A {d} {s} {d} 0x{x:0>8}\n", .{ i, p.codec, p.data.len, std.hash.Adler32.permute(0, p.data) });
                defer gpa.free(line);
                try actual.appendSlice(gpa, line);
            }
            testing.expectEqualStrings(expected.items, actual.items) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
            // The manifest's tags, written independently.
            try testing.expectEqual(fixture.tags.len, info.tags.count());
            for (fixture.tags, info.tags.items()) |want, got| {
                try testing.expectEqualStrings(want.key, got.key);
                try testing.expectEqualStrings(want.value, got.value);
            }
        }
    }
}

test "STREAMINFO's MD5 is checked when asked, and only then" {
    const gpa = testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        if (fixture.md5) |md5| {
            for ([_]bool{ false, true }) |verify| {
                var reader: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
                var r: DecodedReader = .init(gpa, &reader, null);
                defer r.deinit();
                r.verify_md5 = verify;
                _ = try r.readHeader();
                var out: [4096]u8 = undefined;
                while ((try r.readData(&out)).len > 0) {}
                if (verify and md5 == .mismatch) {
                    try testing.expectError(error.Md5Mismatch, r.finish());
                } else {
                    try r.finish();
                }
            }
        }
    }
}

test "headers read without an allocator keep nothing and agree" {
    inline for (fixtures.flac.all) |fixture| {
        if (fixture.expected != .reject) {
            var plain: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
            const a = try readHeader(&plain);
            var kept: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
            var b = try readHeaderAlloc(&kept, testing.allocator);
            defer b.deinit(testing.allocator);
            try testing.expectEqual(a.channels, b.channels);
            try testing.expect(a.layout.eql(&b.layout));
            try testing.expectEqual(a.sample_rate, b.sample_rate);
            try testing.expectEqual(a.duration, b.duration);
            try testing.expectEqual(0, a.tags.count());
        }
    }
}
