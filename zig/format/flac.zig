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
const seek = @import("seek.zig");
const rational = @import("../core/rational.zig");
const vorbiscomment = @import("vorbiscomment.zig");

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
    /// As the block holds it; FFmpeg compares it up to its first NUL.
    mime: []const u8,
    /// The codec FFmpeg gives the picture: by its MIME type, or PNG for
    /// data that starts with PNG's signature.
    codec: []const u8,
    /// FFmpeg's `title`: the description up to its first NUL; null for a
    /// block without one.
    description: ?[]const u8,
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
    /// reports them, the pictures, the CUESHEET chapters and every
    /// SEEKTABLE block's points in file order.
    tags: metadata.Dictionary = .empty,
    pictures: []Picture = &.{},
    chapters: []Chapter = &.{},
    seek_points: []SeekPoint = &.{},

    pub fn deinit(info: *Info, gpa: std.mem.Allocator) void {
        info.tags.deinit(gpa);
        for (info.pictures) |p| freePicture(gpa, p);
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
    var tags: metadata.Dictionary = .empty;
    var pictures: std.ArrayList(Picture) = .empty;
    var chapters: std.ArrayList(Chapter) = .empty;
    var seek_points: std.ArrayList(SeekPoint) = .empty;
    // The chapter numbers an OGM `CHAPTERnnnNAME` comment can name.
    var chapter_ids: vorbiscomment.Chapters = .{};
    defer if (gpa) |a| {
        tags.deinit(a);
        for (pictures.items) |p| freePicture(a, p);
        pictures.deinit(a);
        for (chapters.items) |c| a.free(c.title);
        chapters.deinit(a);
        seek_points.deinit(a);
        chapter_ids.deinit(a);
    };
    var mask: MaskState = .{};
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
                    try readSeekTable(reader, a, size, &seek_points);
                } else try skipBytes(reader, size);
            },
            block_cuesheet => try readCueSheet(reader, size, gpa, &chapters, &chapter_ids),
            block_picture => try readPicture(reader, size, gpa, &pictures),
            else => {
                // STREAMINFO must come first among the rest.
                if (info.extradata == null) return error.InvalidFlac;
                if (block_type == block_vorbis_comment) {
                    if (gpa) |a| {
                        try readVorbisComment(reader, a, size, &tags, &chapter_ids, &mask);
                    } else try scanChannelMask(reader, size, &mask);
                } else try skipBytes(reader, size);
            },
        }
    }
    const si = info.stream_info orelse return error.InvalidFlac;
    // ff_flac_parse_streaminfo refuses these, and with them the decoder.
    if (si.max_blocksize < flac.min_blocksize or si.bps < 4) return error.InvalidFlac;
    info.channels = si.channels;
    info.layout = flac.channelLayout(si.channels);
    // ff_flac_set_channel_layout keeps the mask's layout only for as many
    // channels as STREAMINFO has; otherwise the decoder's default replaces
    // it. The tag went either way.
    if (mask.mask) |m| {
        if (@popCount(m) == si.channels) info.layout = .{ .native = m };
    }
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
        info.pictures = try pictures.toOwnedSlice(a);
        info.chapters = try chapters.toOwnedSlice(a);
        info.seek_points = try seek_points.toOwnedSlice(a);
        // Last: nothing after it can fail, so the deferred frees see it
        // empty.
        info.tags = tags;
        tags = .empty;
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

/// A SEEKTABLE body: 18-byte points, appended to `points`, as FFmpeg adds
/// every table's points to its index; a remainder is ignored, as FFmpeg's
/// division does.
fn readSeekTable(reader: *std.Io.Reader, gpa: std.mem.Allocator, size: u24, points: *std.ArrayList(SeekPoint)) Error!void {
    const count = size / 18;
    try points.ensureUnusedCapacity(gpa, count);
    for (0..count) |_| {
        var raw: [18]u8 = undefined;
        try readExact(reader, &raw);
        points.appendAssumeCapacity(.{
            .sample = std.mem.readInt(u64, raw[0..8], .big),
            .offset = std.mem.readInt(u64, raw[8..16], .big),
            .samples = std.mem.readInt(u16, raw[16..18], .big),
        });
    }
    try skipBytes(reader, size % 18);
}

/// The CUESHEET as flac_read_header reads it: at least 431 bytes, the track
/// count at offset 395, each track but the lead-out a chapter of its
/// offset, number and ISRC; a track without index points is `InvalidFlac`.
/// Index points are skipped without a bound of their own: a track must
/// start inside the block, but the last one's points may run past it, as
/// FFmpeg reads them from its zero-padded copy of the block.
fn readCueSheet(reader: *std.Io.Reader, size: u24, gpa: ?std.mem.Allocator, chapters: *std.ArrayList(Chapter), ids: *vorbiscomment.Chapters) Error!void {
    if (size < 431) return error.InvalidFlac;
    try skipBytes(reader, 395);
    var count_byte: [1]u8 = undefined;
    try readExact(reader, &count_byte);
    // FFmpeg's `offset` into the block, and the bytes read of it.
    var offset: u64 = 396;
    var consumed: u64 = 396;
    const tracks = @as(i32, count_byte[0]) - 1;
    if (tracks <= 0) return error.InvalidFlac;
    var starts: [255]u64 = undefined;
    var numbers: [255]u8 = undefined;
    var titles: [255][12]u8 = undefined;
    for (0..@intCast(tracks)) |i| {
        if (offset + 36 > size) return error.InvalidFlac;
        // `offset` only grows, and was within the block here.
        try skipBytes(reader, offset - consumed);
        var track: [36]u8 = undefined;
        try readExact(reader, &track);
        offset += 36;
        consumed = offset;
        starts[i] = std.mem.readInt(u64, track[0..8], .big);
        numbers[i] = track[8];
        @memcpy(&titles[i], track[9..21]);
        const index_points = track[35];
        if (index_points == 0) return error.InvalidFlac;
        offset += @as(u64, index_points) * 12;
    }
    try skipBytes(reader, size - consumed);
    const a = gpa orelse return;
    for (numbers[0..@intCast(tracks)]) |number| try ids.add(a, number);
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
    // `strncmp` on the NUL-terminated copy: the type ends at a NUL.
    var codec = pictureCodec(mime[0 .. std.mem.findScalar(u8, mime, 0) orelse mime.len]) orelse return;
    const desc_len = field(body, &at);
    // At least 20 bytes remain here: the MIME check above kept 24 after it.
    if (desc_len > body.len - at - 20) return;
    const desc = body[at..][0..desc_len];
    // A C string to FFmpeg, which NUL-terminates it where the width starts.
    const description: ?[]const u8 = if (desc_len > 0) desc[0 .. std.mem.findScalar(u8, desc, 0) orelse desc.len] else null;
    at += desc_len;
    const width = field(body, &at);
    const height = field(body, &at);
    at += 8;
    const data_len = field(body, &at);
    // FFmpeg's workaround for a 24-bit block size is not modeled: such a
    // picture runs past its block, which the parser refuses here.
    if (data_len == 0 or data_len > body.len - at) return;
    const picture_data = body[at..][0..data_len];
    // Data with PNG's signature is PNG, whatever the MIME type said.
    if (picture_data.len >= 8 and std.mem.readInt(u64, picture_data[0..8], .big) == png_signature) codec = "png";
    const owned_mime = try a.dupe(u8, mime);
    errdefer a.free(owned_mime);
    const owned_desc = if (description) |d| try a.dupe(u8, d) else null;
    errdefer if (owned_desc) |d| a.free(d);
    const data = try a.dupe(u8, picture_data);
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

fn freePicture(gpa: std.mem.Allocator, p: Picture) void {
    gpa.free(p.mime);
    if (p.description) |d| gpa.free(d);
    gpa.free(p.data);
}

/// `ff_id3v2_picture_types`' length.
const id3v2_picture_types = 21;

/// flac_picture.c's `PNGSIG`.
const png_signature = 0x89504e470d0a1a0a;

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

/// The channel mask as flac_read_header takes it from the format tags after
/// each VORBIS_COMMENT block.
const MaskState = struct {
    /// The last valid mask, which sets the layout.
    mask: ?u64 = null,
    /// An invalid mask stays a tag, and later blocks' values for the key
    /// are appended to it after a ';', where `strtol` stops: no later mask
    /// can be valid. Only `scanChannelMask` tracks this; with an allocator
    /// the tag itself is in the dictionary.
    stuck: bool = false,

    /// The tag's value: when it is a valid mask (`strtol`'s value, nonzero,
    /// no bit above 17), it sets the layout and the tag goes.
    fn take(state: *MaskState, text: []const u8) bool {
        const number = channel_layout.strtol(text, 0);
        const m: u64 = @bitCast(number.value);
        if (m == 0 or m & ~@as(u64, 0x3ffff) != 0) return false;
        state.mask = m;
        return true;
    }
};

const mask_key = "WAVEFORMATEXTENSIBLE_CHANNEL_MASK";

/// A VORBIS_COMMENT block as flac_read_header reads it: ff_vorbis_comment
/// into the format tags (vorbiscomment.zig; OGM chapters may name the
/// CUESHEET's tracks), then the channel mask. FFmpeg only logs a block
/// ff_vorbis_comment refuses, so it is not an error here either.
fn readVorbisComment(reader: *std.Io.Reader, gpa: std.mem.Allocator, size: u24, tags: *metadata.Dictionary, chapters: *vorbiscomment.Chapters, mask: *MaskState) Error!void {
    const body = try readBytes(reader, gpa, size);
    defer gpa.free(body);
    _ = vorbiscomment.parse(gpa, tags, chapters, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidComment => {},
    };
    // The first entry with the key: a repeat's values were joined into it
    // after a ';'.
    const text = tags.get(mask_key) orelse return;
    if (mask.take(text)) _ = tags.remove(gpa, mask_key);
}

/// The longest comment `scanChannelMask` reads; a longer one is skipped
/// unread. Enough for the mask's key and any value FFmpeg accepts short of
/// padding with white space or leading zeros.
const mask_comment_capacity = 64;

/// `readVorbisComment` without an allocator, for the layout only: the first
/// mask comment of the block, as the joined value `strtol` reads is that
/// comment's value.
fn scanChannelMask(reader: *std.Io.Reader, size: u24, mask: *MaskState) Error!void {
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
    var text: [mask_comment_capacity]u8 = undefined;
    var first: ?[]const u8 = null;
    while (left >= 4 and count > 0) : (count -= 1) {
        try readExact(reader, &word);
        left -= 4;
        const len = std.mem.readInt(u32, &word, .little);
        if (len > left or len > std.math.maxInt(i32)) break;
        left -= len;
        if (first != null or len > text.len) {
            try skipBytes(reader, len);
            continue;
        }
        try readExact(reader, text[0..len]);
        const c = vorbiscomment.splitComment(text[0..len]) orelse continue;
        if (std.ascii.eqlIgnoreCase(c.key, mask_key)) first = c.value;
    }
    try skipBytes(reader, left);
    const value = first orelse return;
    if (mask.stuck) return;
    if (!mask.take(value)) mask.stuck = true;
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
    /// The packet's byte position (the parser's frame offset).
    pos: i64,
};

/// av_parser_parse2's byte offsets, from the first read's position.
const ParserOffsets = struct {
    fetched: bool = false,
    cur_offset: i64 = 0,
    next_frame_offset: i64 = 0,
    frame_offset: i64 = 0,

    /// Before a parse call with the read at `pos`.
    fn begin(o: *ParserOffsets, pos: i64) void {
        if (o.fetched) return;
        o.cur_offset = pos;
        o.next_frame_offset = pos;
        o.fetched = true;
    }

    /// After it: a frame's offset is where the last one ended.
    fn end(o: *ParserOffsets, out: flac_parser.Output) void {
        if (out.frame != null) {
            o.frame_offset = o.next_frame_offset;
            o.next_frame_offset = o.cur_offset + out.index;
        }
        o.cur_offset += @max(out.index, 0);
    }
};

/// What a FLAC seek can fail with.
pub const SeekError = Error || seek.Error || error{
    /// FFmpeg's search finds no frame (`-1`).
    SeekFailed,
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
    /// Set by `initSeekable`: the source, and the frames' absolute start
    /// (libavformat's `data_offset`).
    seeker: ?seek.Seeker = null,
    data_offset: u64 = 0,
    /// The offset of the next raw read.
    raw_pos: u64 = 0,
    offsets: ParserOffsets = .{},
    /// The packets returned so far, which the seek search starts from.
    index: seek.Index = .{},

    /// Reads the header, keeping its tags, pictures, chapters and seek
    /// table; packets follow with `next`.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Error!Demuxer {
        const info = try readHeaderAlloc(reader, gpa);
        return .{ .gpa = gpa, .reader = reader, .info = info, .parser = .init(gpa) };
    }

    /// `init` over a seekable source read from its start: packets carry
    /// their byte positions, and `seekFrame` and `seekFile` work (T26b).
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker) Error!Demuxer {
        var d = try init(gpa, reader);
        d.seeker = seeker;
        // The frames start where the bytes the header peeked do.
        d.data_offset = seeker.position() - d.info.prefix_len;
        d.raw_pos = d.data_offset;
        return d;
    }

    pub fn deinit(d: *Demuxer) void {
        d.index.deinit(d.gpa);
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
        // AVFMT_GENERIC_INDEX: every returned keyframe is indexed.
        if (d.seeker != null) try d.index.add(d.gpa, q.pos, if (isRelative(dts)) dts - relative_ts_base else dts);
        if (isRelative(dts)) dts -= relative_ts_base;
        if (isRelative(pts)) pts -= relative_ts_base;
        return .{
            .data = q.data,
            .time_base = d.info.time_base,
            .pts = if (pts == nopts) null else pts,
            .dts = if (dts == nopts) null else dts,
            .duration = if (q.duration == 0) null else q.duration,
            .flags = .{ .key = true },
            .pos = if (d.seeker != null) @intCast(q.pos) else null,
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
            const pos = d.raw_pos;
            d.raw_pos += n;
            try d.parsePacketAt(chunk[0..n], false, pos);
        }
        if (d.parse_queue.items.len == 0) return null;
        return d.parse_queue.orderedRemove(0);
    }

    /// parse_packet: everything the parser makes of `input`, into the
    /// parse queue with its timestamps.
    fn parsePacket(d: *Demuxer, input: []const u8, flush: bool) Error!void {
        return d.parsePacketAt(input, flush, d.raw_pos);
    }

    fn parsePacketAt(d: *Demuxer, input: []const u8, flush: bool, pos: u64) Error!void {
        var rest = input;
        var got_output = flush;
        while (rest.len > 0 or (flush and got_output)) {
            d.offsets.begin(@intCast(pos));
            const out = try d.parser.parse(rest);
            d.offsets.end(out);
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
            var q: Queued = .{ .data = data, .pts = out.pts orelse nopts, .dts = nopts, .duration = duration, .pos = d.offsets.frame_offset };
            d.computePktFields(&q);
            try d.parse_queue.append(d.gpa, q);
        }
    }

    /// ff_read_frame_flush: the queued packets and the parser dropped, the
    /// running timestamp unknown (or relative before any was known).
    fn readFrameFlush(d: *Demuxer) void {
        for (d.packet_buffer.items) |q| d.gpa.free(q.data);
        for (d.parse_queue.items) |q| d.gpa.free(q.data);
        d.packet_buffer.clearRetainingCapacity();
        d.parse_queue.clearRetainingCapacity();
        d.parser.deinit();
        d.parser = .init(d.gpa);
        d.offsets = .{};
        d.cur_dts = if (d.first_dts == nopts) relative_ts_base else nopts;
        d.probing = false;
        d.eof = false;
    }

    fn sourceSize(d: *const Demuxer) i64 {
        const size = d.seeker.?.size() orelse return std.math.maxInt(i64);
        return std.math.cast(i64, size) orelse std.math.maxInt(i64);
    }

    /// flac_read_timestamp: a fresh parser fed the raw reads from `pos.*`
    /// until a frame with a timestamp; `pos.*` becomes that frame's start.
    /// Each read goes to the parser once, as FFmpeg's loop feeds it.
    fn readTimestamp(d: *Demuxer, pos: *i64, pos_limit: i64) Error!i64 {
        _ = pos_limit; // flac_read_timestamp reads on to a frame
        const seeker = d.seeker.?;
        seeker.seekTo(@intCast(pos.*)) catch return error.IoFailure;
        var parser: flac_parser.Parser = .init(d.gpa);
        defer parser.deinit();
        var offsets: ParserOffsets = .{};
        var eof = false;
        while (true) {
            var chunk: [raw_packet_size]u8 = undefined;
            var input: []const u8 = &.{};
            if (!eof) {
                const n = d.reader.readSliceShort(&chunk) catch return error.IoFailure;
                if (n == 0) eof = true else input = chunk[0..n];
            }
            offsets.begin(pos.*);
            const out = try parser.parse(input);
            offsets.end(out);
            if (out.frame) |frame| {
                if (out.pts) |pts| {
                    pos.* = offsets.next_frame_offset - @as(i64, @intCast(frame.len));
                    return pts;
                }
            } else if (eof) return nopts;
        }
    }

    const Search = seek.Search(*Demuxer, Error, readTimestamp);

    /// `av_seek_frame` on FLAC: by byte position (`seek_frame_byte`), or
    /// as FFmpeg seeks without fast seeking, ff_seek_frame_binary over
    /// flac_read_timestamp from the packets read so far. The seek table
    /// plays no part, as in FFmpeg without `-fflags fastseek`. Needs
    /// `initSeekable`. A search that fails leaves the demuxer flushed, as
    /// FFmpeg's does (`SeekFailed`).
    pub fn seekFrame(d: *Demuxer, stream: i32, timestamp: i64, flags: seek.Flags) SeekError!seek.Position {
        const seeker = d.seeker.?; // `initSeekable` is the precondition
        if (flags.byte) {
            var pos: i64 = timestamp;
            const pos_min: i64 = @intCast(d.data_offset);
            const pos_max = d.sourceSize() - 1;
            if (pos < pos_min) {
                pos = pos_min;
            } else if (pos > pos_max) {
                pos = pos_max;
            }
            d.readFrameFlush();
            try d.repositionAt(seeker, pos);
            return .{ .offset = @intCast(pos), .timestamp = null, .at_end = false };
        }
        if (stream != 0 and stream != -1) return error.InvalidStream;
        var ts = timestamp;
        const tb = d.info.time_base;
        if (stream == -1) ts = seek.defaultStreamTimestamp(ts, .{ .num = @intCast(tb.num), .den = @intCast(tb.den) });
        d.readFrameFlush();
        // ff_seek_frame_binary: the bounds from the index.
        const bounds = d.index.bounds(ts, flags.any);
        const found = try Search.genSearch(d, @intCast(d.data_offset), d.sourceSize(), ts, bounds, flags.backward) orelse return error.SeekFailed;
        try d.repositionAt(seeker, found.pos);
        d.readFrameFlush();
        // avpriv_update_cur_dts.
        d.cur_dts = found.ts;
        return .{ .offset = @intCast(found.pos), .timestamp = found.ts, .at_end = false };
    }

    /// `avformat_seek_file` on FLAC: `seekFrame` within the bounds, as
    /// libavformat's fallback runs it.
    pub fn seekFile(d: *Demuxer, stream: i32, min_ts: i64, ts: i64, max_ts: i64, flags: seek.Flags) SeekError!seek.Position {
        return seek.seekFile(d, seekFrame, stream, min_ts, ts, max_ts, flags);
    }

    fn repositionAt(d: *Demuxer, seeker: seek.Seeker, pos: i64) Error!void {
        seeker.seekTo(@intCast(pos)) catch return error.IoFailure;
        d.raw_pos = @intCast(pos);
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
/// header or reconfigure its filters. So does a frame decoded to another
/// storage than the header's (s16 or s32): only headerless input, whose
/// first frame header gives the header's sample size, can have one, where
/// FFmpeg's stream takes the decoder's real format (notes.md "Headerless
/// sample-size change"). With `verify_md5`, `finish` checks STREAMINFO's
/// MD5, when it has one, against the decoded samples (`Md5Mismatch`);
/// FFmpeg never checks it.
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

    /// The sample count of the first decoded frame, which the ffmpeg
    /// program's FLAC encoder takes as its block size (T26c); null for a
    /// stream without frames. The frame is decoded ahead; `readData` still
    /// returns it first.
    pub fn firstFrameSamples(r: *DecodedReader) Error!?u32 {
        std.debug.assert(r.delivered == 0);
        if (r.pendingFrames() == 0 and !try r.nextFrame()) return null;
        return @intCast(r.pendingFrames());
    }

    /// Whole frames of samples into `output`, at least one while any remain
    /// (one frame fits in 32 bytes); empty at the end.
    pub fn readData(r: *DecodedReader, output: []u8) Error![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        // The samples' own storage, which `nextFrame` checked against the
        // header's.
        const width: usize = switch (r.pending) {
            .s16 => 2,
            .s32 => 4,
        };
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
        const storage_bits: u8 = @intCast(width * 8);
        const shift: u5 = @intCast(storage_bits - r.bps);
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
                // The decoder's sample size is fixed once known, but a
                // headerless stream's header took it from a frame header
                // the decoder may have skipped as junk.
                const header_s32 = r.bps > 16;
                if (header_s32 != (f.samples == .s32)) return error.UnsupportedFormat;
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
    try testing.fuzz({}, fuzzOne, .{
        .corpus = &.{
            fixtures.flac.bytes("flac_constant_mono_8k"),
            fixtures.flac.bytes("flac_lpc_zero_shift"),
            fixtures.flac.bytes("flac_junk_between_frames"),
            fixtures.flac.bytes("flac_mid_side"),
            // T26b: other sample sizes, the 33-bit side channel, variable
            // blocking, no STREAMINFO, and metadata blocks.
            fixtures.flac.bytes("flac_bps24_mid_side"),
            fixtures.flac.bytes("flac_bps32_right_side_lpc"),
            fixtures.flac.bytes("flac_variable_blocksize"),
            fixtures.flac.bytes("flac_headerless"),
            fixtures.flac.bytes("flac_metadata_blocks"),
            fixtures.flac.bytes("flac_channel_change"),
        },
    });
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

const seek_vectors = @embedFile("../testing/vectors/seek_flac.txt");

fn seekBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, seek_vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "F ")) continue;
        const at = @intFromPtr(line.ptr) - @intFromPtr(seek_vectors.ptr);
        if (start) |s| return seek_vectors[s..at];
        if (std.mem.eql(u8, line[2..], name)) start = at + line.len + 1;
    }
    return if (start) |s| seek_vectors[s..] else null;
}

/// The next packet's line and its first 16 decoded sample frames, as
/// seek_vectors.c prints them.
fn nextAfterSeek(gpa: std.mem.Allocator, d: *Demuxer, out: *std.ArrayList(u8)) !void {
    const p = try d.next() orelse return out.appendSlice(gpa, "P EOF\n");
    var a: [24]u8 = undefined;
    const line = try std.fmt.allocPrint(gpa, "P {s} {d} {d}\n", .{ formatTs(&a, p.pts), p.pos.?, p.data.len });
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
    var dec = try flacdec.Decoder.init(gpa, d.info.stream_info);
    defer dec.deinit();
    dec.send(p.data, p.pts);
    const frame = (dec.receive() catch null) orelse return out.appendSlice(gpa, "D none\n");
    const header = try std.fmt.allocPrint(gpa, "D {d} ", .{frame.nb_samples});
    defer gpa.free(header);
    try out.appendSlice(gpa, header);
    const frames = @min(frame.nb_samples, 16);
    switch (frame.samples) {
        inline else => |samples| for (samples[0 .. frames * frame.channels]) |s| {
            var le: [@sizeOf(@TypeOf(s))]u8 = undefined;
            std.mem.writeInt(@TypeOf(s), &le, s, .little);
            const hex = std.fmt.bytesToHex(le, .lower);
            try out.appendSlice(gpa, &hex);
        },
    }
    try out.append(gpa, '\n');
}

test "every FLAC fixture seeks as FFmpeg seeks it (vectors/seek_flac.txt)" {
    const gpa = testing.allocator;
    var compared: usize = 0;
    inline for (fixtures.flac.all) |fixture| {
        if (fixture.expected != .reject) {
            const block = seekBlock(fixture.name) orelse return error.MissingVector;
            var lines = std.mem.splitScalar(u8, block, '\n');
            // FFmpeg fails every seek in a file whose PICTURE it made a
            // second stream, which the port does not (port.md "FLAC
            // contract"): an understood difference.
            const picture = comptime std.mem.eql(u8, fixture.name, "flac_picture");
            if (!picture and std.mem.eql(u8, lines.next().?, "O ok")) {
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
                    const stream = try std.fmt.parseInt(i32, f.next().?, 10);
                    const ts = try std.fmt.parseInt(i64, f.next().?, 10);
                    var min_ts: i64 = 0;
                    var max_ts: i64 = 0;
                    if (api == 's') {
                        min_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                        max_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                    }
                    const bits_text = f.next().?;
                    const flag_bits = try std.fmt.parseInt(u8, bits_text, 16);
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
                    var reader: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
                    var d = try Demuxer.initSeekable(gpa, &reader, .fixed(&reader));
                    defer d.deinit();
                    _ = try d.next();
                    const result = if (api == 'f') d.seekFrame(stream, ts, flags) else d.seekFile(stream, min_ts, ts, max_ts, flags);
                    var actual: std.ArrayList(u8) = .empty;
                    defer actual.deinit(gpa);
                    if (result) |_| {
                        try nextAfterSeek(gpa, &d, &actual);
                    } else |err| switch (err) {
                        error.InvalidStream => try actual.appendSlice(gpa, "EINVAL"),
                        error.SeekFailed => try actual.appendSlice(gpa, "-1"),
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
    }
    // Every seek of the 50 fixtures FFmpeg opens, flac_picture aside.
    try testing.expectEqual(2692, compared);
}

/// Hand-made FLAC for the tests below: a STREAMINFO of 16-sample blocks,
/// metadata blocks, and mono verbatim frames at 44.1 kHz.
const TestFile = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(f: *TestFile) void {
        f.bytes.deinit(testing.allocator);
    }

    fn add(f: *TestFile, bytes: []const u8) !void {
        try f.bytes.appendSlice(testing.allocator, bytes);
    }

    /// `fLaC` and a mono STREAMINFO of `bps` bits and `samples` samples,
    /// not the last block.
    fn streamInfo(f: *TestFile, bps: u8, samples: u36) !void {
        try f.add("fLaC\x00\x00\x00\x22");
        var body: [flac.streaminfo_size]u8 = @splat(0);
        std.mem.writeInt(u16, body[0..2], 16, .big);
        std.mem.writeInt(u16, body[2..4], 16, .big);
        const fields: u64 = (44100 << 44) | (@as(u64, bps - 1) << 36) | samples;
        std.mem.writeInt(u64, body[10..18], fields, .big);
        try f.add(&body);
    }

    fn block(f: *TestFile, block_type: u7, last: bool, body: []const u8) !void {
        var header: [4]u8 = undefined;
        const last_flag: u8 = if (last) 0x80 else 0;
        header[0] = last_flag | block_type;
        std.mem.writeInt(u24, header[1..4], @intCast(body.len), .big);
        try f.add(&header);
        try f.add(body);
    }

    /// A frame header of a mono 44.1 kHz frame, its CRC-8 included.
    fn frameHeader(w: *bits.BitWriter, blocksize: u32, bps_code: u3, number: u7) void {
        w.bits(15, 0x7ffc);
        w.bits(1, 0);
        w.bits(4, 6); // an 8-bit block size follows
        w.bits(4, 9); // 44.1 kHz
        w.bits(4, 0); // mono
        w.bits(3, bps_code);
        w.bits(1, 0);
        w.bits(8, number);
        w.bits(8, blocksize - 1);
        w.bits(8, bits.Crc8.hash(w.written()));
    }

    /// A verbatim frame of `samples` at `bps` bits (code `bps_code`).
    fn frame(f: *TestFile, number: u7, bps_code: u3, bps: u7, samples: []const i32) !void {
        var storage: [256]u8 = undefined;
        var w: bits.BitWriter = .init(&storage);
        frameHeader(&w, @intCast(samples.len), bps_code, number);
        w.bits(8, 0b0000_0010); // padding, verbatim, no wasted bits
        for (samples) |s| w.signed(bps, s);
        w.flush();
        var crc: [2]u8 = undefined;
        std.mem.writeInt(u16, &crc, bits.Crc16.hash(w.written()), .big);
        std.debug.assert(!w.overflow);
        try f.add(w.written());
        try f.add(&crc);
    }

    /// Three 16-bit frames of 16 samples, the stream's 48.
    fn frames(f: *TestFile) !void {
        var samples: [16]i32 = undefined;
        for (&samples, 0..) |*s, i| s.* = @intCast(i * 100);
        for (0..3) |n| try f.frame(@intCast(n), 4, 16, &samples);
    }

    fn info(f: *const TestFile) !Info {
        var reader: std.Io.Reader = .fixed(f.bytes.items);
        return readHeaderAlloc(&reader, testing.allocator);
    }
};

/// A VORBIS_COMMENT body: an empty vendor string and `comments`.
inline fn testComments(comptime comments: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\x00\x00\x00\x00" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, comments.len));
        for (comments) |c| out = out ++ std.mem.toBytes(std.mem.nativeToLittle(u32, c.len)) ++ c;
        return out;
    }
}

fn expectTags(expected: []const [2][]const u8, tags: *const metadata.Dictionary) !void {
    try testing.expectEqual(expected.len, tags.count());
    for (expected, tags.items()) |want, got| {
        try testing.expectEqualStrings(want[0], got.key);
        try testing.expectEqualStrings(want[1], got.value);
    }
}

test "a headerless stream whose frames change storage is refused, not overrun" {
    // A 16-bit frame header and one subframe byte, which the decoder skips
    // as junk, then 24-bit frames: the header says s16, the frames are s32.
    var f: TestFile = .{};
    defer f.deinit();
    var storage: [16]u8 = undefined;
    var w: bits.BitWriter = .init(&storage);
    TestFile.frameHeader(&w, 16, 4, 0);
    w.bits(8, 0);
    try f.add(w.written());
    var samples: [16]i32 = undefined;
    for (&samples, 0..) |*s, i| {
        const index: i32 = @intCast(i);
        s.* = index * 300_000 - 2_000_000;
    }
    for (0..12) |n| try f.frame(@intCast(n), 6, 24, &samples);

    var reader: std.Io.Reader = .fixed(f.bytes.items);
    var r: DecodedReader = .init(testing.allocator, &reader, null);
    defer r.deinit();
    const header = try r.readHeader();
    try testing.expectEqual(pcm.Codec.s16le, header.codec);
    // Room for one s16 frame of samples, half an s32 one.
    var out: [32]u8 = undefined;
    try testing.expectError(error.UnsupportedFormat, r.readData(&out));
}

test "a channel mask applies only with STREAMINFO's channel count; a valid one is never a tag" {
    const cases = [_]struct { comments: []const u8, layout: channel_layout.Layout, tags: []const [2][]const u8 }{
        // 5.1 for a mono stream: FFmpeg's decoder restores mono.
        .{ .comments = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x3F"}), .layout = .{ .native = 0x4 }, .tags = &.{} },
        .{ .comments = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x1"}), .layout = .{ .native = 0x1 }, .tags = &.{} },
        .{ .comments = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0"}), .layout = .{ .native = 0x4 }, .tags = &.{.{ "WAVEFORMATEXTENSIBLE_CHANNEL_MASK", "0" }} },
    };
    for (cases) |case| {
        var f: TestFile = .{};
        defer f.deinit();
        try f.streamInfo(16, 48);
        try f.block(4, true, case.comments);
        try f.frames();
        var info = try f.info();
        defer info.deinit(testing.allocator);
        try testing.expect(info.layout.eql(&case.layout));
        try expectTags(case.tags, &info.tags);
        var plain: std.Io.Reader = .fixed(f.bytes.items);
        try testing.expect((try readHeader(&plain)).layout.eql(&case.layout));
        // The decoded stream is the header's: one channel.
        var reader: std.Io.Reader = .fixed(f.bytes.items);
        var r: DecodedReader = .init(testing.allocator, &reader, null);
        defer r.deinit();
        try testing.expectEqual(1, (try r.readHeader()).format.channelCount());
        var out: [4096]u8 = undefined;
        try testing.expectEqual(32, (try r.readData(&out)).len);
    }
}

test "masks across comment blocks: the last valid one wins, until an invalid one stays" {
    const cases = [_]struct { first: []const u8, second: []const u8, layout: channel_layout.Layout, tags: []const [2][]const u8 }{
        .{
            .first = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x4"}),
            .second = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x1"}),
            .layout = .{ .native = 0x1 },
            .tags = &.{},
        },
        .{
            .first = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0"}),
            .second = testComments(&.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x1"}),
            .layout = .{ .native = 0x4 },
            .tags = &.{.{ "WAVEFORMATEXTENSIBLE_CHANNEL_MASK", "0;0x1" }},
        },
    };
    for (cases) |case| {
        var f: TestFile = .{};
        defer f.deinit();
        try f.streamInfo(16, 48);
        try f.block(4, false, case.first);
        try f.block(4, true, case.second);
        try f.frames();
        var info = try f.info();
        defer info.deinit(testing.allocator);
        try testing.expect(info.layout.eql(&case.layout));
        try expectTags(case.tags, &info.tags);
        var plain: std.Io.Reader = .fixed(f.bytes.items);
        try testing.expect((try readHeader(&plain)).layout.eql(&case.layout));
    }
}

test "every SEEKTABLE block's points are kept" {
    var f: TestFile = .{};
    defer f.deinit();
    try f.streamInfo(16, 48);
    const point = "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x10";
    try f.block(3, false, point);
    try f.block(3, true, point ++ point);
    try f.frames();
    var info = try f.info();
    defer info.deinit(testing.allocator);
    try testing.expectEqual(3, info.seek_points.len);
    try testing.expectEqual(16, info.seek_points[2].samples);
}

test "comment blocks parse as FFmpeg's ff_vorbis_comment, once per block" {
    {
        // OGM chapters are chapters, not tags; a NUL ends a key.
        var f: TestFile = .{};
        defer f.deinit();
        try f.streamInfo(16, 48);
        try f.block(4, true, testComments(&.{ "TITLE=x", "CHAPTER001=00:00:00.010", "CHAPTER001NAME=Intro", "K\x00X=v" }));
        try f.frames();
        var info = try f.info();
        defer info.deinit(testing.allocator);
        try expectTags(&.{ .{ "TITLE", "x" }, .{ "K", "v" } }, &info.tags);
    }
    {
        // Each block is converted on its own: TRACKNUMBER of the second is
        // not the first's `track`. Within the dictionary a repeat moves
        // its key, in the new spelling, to the end.
        var f: TestFile = .{};
        defer f.deinit();
        try f.streamInfo(16, 48);
        try f.block(4, false, testComments(&.{ "A=1", "B=2", "a=3", "TITLE=x" }));
        try f.block(4, true, testComments(&.{ "title=y", "TRACKNUMBER=1", "track=2" }));
        try f.frames();
        var info = try f.info();
        defer info.deinit(testing.allocator);
        try expectTags(&.{ .{ "B", "2" }, .{ "a", "1;3" }, .{ "title", "x;y" }, .{ "track", "1" }, .{ "track", "2" } }, &info.tags);
    }
    // A chapter name refers to a CUESHEET track read before it.
    for ([_]bool{ true, false }, [_][]const [2][]const u8{
        &.{.{ "TITLE", "t" }},
        &.{ .{ "CHAPTER005NAME", "Five" }, .{ "TITLE", "t" } },
    }) |cue_first, tags| {
        var cue: [432]u8 = @splat(0);
        cue[395] = 2;
        cue[396 + 8] = 5; // the track number
        cue[396 + 35] = 1; // one index point, which runs past the block
        const comments = testComments(&.{ "CHAPTER005NAME=Five", "TITLE=t" });
        var f: TestFile = .{};
        defer f.deinit();
        try f.streamInfo(16, 48);
        if (cue_first) try f.block(5, false, &cue);
        try f.block(4, cue_first, comments);
        if (!cue_first) try f.block(5, true, &cue);
        try f.frames();
        var info = try f.info();
        defer info.deinit(testing.allocator);
        try expectTags(tags, &info.tags);
        try testing.expectEqual(1, info.chapters.len);
    }
}

test "a CUESHEET track must start inside the block; its index points need not end there" {
    var cue: [396 + 36 + 12]u8 = @splat(0);
    cue[395] = 3;
    // Track 1 claims 2 index points: 24 bytes where 12 remain before the
    // block's end, so track 2 would start past it.
    cue[396 + 8] = 1;
    cue[396 + 35] = 2;
    var f: TestFile = .{};
    defer f.deinit();
    try f.streamInfo(16, 48);
    try f.block(5, true, &cue);
    try f.frames();
    try testing.expectError(error.InvalidFlac, f.info());
    var plain: std.Io.Reader = .fixed(f.bytes.items);
    try testing.expectError(error.InvalidFlac, readHeader(&plain));
}

test "PICTURE blocks: the MIME type and description end at a NUL, PNG's signature makes PNG" {
    const picture = struct {
        inline fn of(comptime mime: []const u8, comptime desc: []const u8, comptime data: []const u8) []const u8 {
            const be = struct {
                fn u(v: u32) [4]u8 {
                    return std.mem.toBytes(std.mem.nativeToBig(u32, v));
                }
            }.u;
            return comptime be(3) ++ be(mime.len) ++ mime ++ be(desc.len) ++ desc ++ be(1) ++ be(2) ++ be(24) ++ be(0) ++ be(data.len) ++ data;
        }
    }.of;
    const png = "\x89PNG\r\n\x1a\nrest";
    var f: TestFile = .{};
    defer f.deinit();
    try f.streamInfo(16, 48);
    try f.block(6, false, picture("image/png\x00zz", "ab\x00cd", "jpegdata"));
    try f.block(6, false, picture("image/jpeg", "", png));
    try f.block(6, true, picture("image/bogus", "x", png));
    try f.frames();
    var info = try f.info();
    defer info.deinit(testing.allocator);
    try testing.expectEqual(2, info.pictures.len);
    try testing.expectEqualStrings("png", info.pictures[0].codec);
    try testing.expectEqualStrings("ab", info.pictures[0].description.?);
    try testing.expectEqualStrings("png", info.pictures[1].codec);
    try testing.expectEqual(null, info.pictures[1].description);
}
