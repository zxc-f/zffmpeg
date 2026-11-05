// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/flacenc.c (flac_init, flac_write_header, flac_finish_header,
// flac_write_block_comment, flac_write_block_padding, flac_write_trailer),
// flacenc_header.c (ff_flac_write_header, ff_flac_is_native_layout),
// vorbiscomment.c (ff_vorbiscomment_write, ff_vorbiscomment_metadata_conv),
// metadata.c (ff_metadata_conv) and fftools/ffmpeg_enc.c (the encoder's
// frame size from the first frame) at the pinned reference revision describe
// the behavior, restated here.
//! FFmpeg's FLAC muxer with the FLAC encoder before it (TODO.md T26c): a
//! PCM writer, as the other containers' writers are, that encodes what it
//! is given.
//!
//! The ffmpeg program opens the FLAC encoder with its first frame, whose
//! sample count becomes the block size (the encoder cannot take frames of
//! other sizes), and the muxer writes its header then: `fLaC`, the
//! encoder's first STREAMINFO, a VORBIS_COMMENT with the vendor `ffmpeg`
//! (FFmpeg's under `-fflags +bitexact`) and the tags, and 8192 bytes of
//! padding. So the writer holds samples until it knows the first frame's
//! size (`first_frame`, or the whole stream when it ends sooner), then
//! writes the header and each frame as it fills. At the end the encoder's
//! final STREAMINFO (sample count, frame sizes, MD5) replaces the first
//! when the output can seek back, as FFmpeg's muxer rewrites a seekable
//! output's; on a pipe it stays as first written, as FFmpeg's does.
//!
//! The same encoder feeds FFmpeg's Ogg muxer (T27b, format/oggmux.zig)
//! when `WriteOptions.container` is `ogg`: the first STREAMINFO becomes
//! the stream's header, each frame a packet with its timestamp and
//! duration, and nothing is rewritten at the end, as FFmpeg's Ogg muxer
//! ignores the encoder's final STREAMINFO.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const metadata = @import("../core/metadata.zig");
const pcm = @import("../codec/pcm.zig");
const flac = @import("../codec/flac.zig");
const flacenc = @import("../codec/flacenc.zig");
const seek = @import("seek.zig");
const vorbiscomment = @import("vorbiscomment.zig");
const oggmux = @import("oggmux.zig");

pub const WriteOptions = struct {
    encoder: flacenc.Options = .{},
    /// `-metadata_header_padding`: the PADDING block's size; null is
    /// FFmpeg's default of 8192 bytes, 0 none.
    padding: ?u24 = null,
    /// The tags, under FFmpeg's generic names (VORBIS_COMMENT's are
    /// restored); null for none. In Ogg, the format's tags.
    tags: ?*const metadata.Dictionary = null,
    container: Container = .flac,

    pub const Container = union(enum) {
        /// FFmpeg's FLAC muxer (`padding` and the channel-mask tag apply).
        flac,
        /// FFmpeg's Ogg muxer, with the stream's own tags, which come
        /// before the format's.
        ogg: struct { stream_tags: ?*const metadata.Dictionary = null },
    };
};

pub const HeaderError = error{
    /// The stream is not packed s16 or s32 PCM, or the encoder refuses it
    /// (channels, rate, a first frame outside 16 to 65535 samples), as
    /// FFmpeg's `avcodec_open2` does.
    UnsupportedFormat,
    /// The encoder refuses its options.
    InvalidOption,
    /// The VORBIS_COMMENT does not fit its 24-bit size (FFmpeg's EINVAL).
    TagsTooLong,
};

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// The output failed to seek back for the final STREAMINFO.
    IoFailure,
    OutOfMemory,
};

const channel_mask_key = "WAVEFORMATEXTENSIBLE_CHANNEL_MASK";

/// The encoder's sample format for a PCM codec: packed s16 or s32 only.
fn sampleFormat(codec: pcm.Codec, format: audio.Format) ?flacenc.SampleFormat {
    return switch (codec) {
        .s16le => if (format.sample_format == .s16) .s16 else null,
        .s32le => if (format.sample_format == .s32) .s32 else null,
        else => null,
    };
}

fn encoderParams(codec: pcm.Codec, format: audio.Format, bits_per_raw_sample: u8, frame_size: u32) HeaderError!flacenc.Params {
    return .{
        .sample_format = sampleFormat(codec, format) orelse return error.UnsupportedFormat,
        .bits_per_raw_sample = bits_per_raw_sample,
        .channels = std.math.cast(u8, format.channelCount()) orelse return error.UnsupportedFormat,
        .sample_rate = format.sample_rate,
        .frame_size = frame_size,
    };
}

/// The tags the muxer writes: `tags`, then the channel mask flac_init adds
/// for a native layout FLAC does not have (unless a tag already gives one),
/// renamed by `ff_metadata_conv` with AV_DICT_MULTIKEY | AV_DICT_DEDUP.
fn muxerTags(gpa: std.mem.Allocator, tags: ?*const metadata.Dictionary, layout: channel_layout.Layout) metadata.Error!metadata.Dictionary {
    var source: metadata.Dictionary = if (tags) |t| try t.clone(gpa) else .empty;
    defer source.deinit(gpa);
    switch (layout) {
        .native => |mask| if (mask & ~@as(u64, 0x3ffff) == 0 and !flac.isNativeLayout(mask) and source.get(channel_mask_key) == null) {
            var text: [32]u8 = undefined;
            const value = std.fmt.bufPrint(&text, "0x{x}", .{mask}) catch unreachable;
            try source.put(gpa, channel_mask_key, value, .replace);
        },
        .unspecified, .custom => {},
    }
    return vorbiscomment.toNative(gpa, &source);
}

const vendor = "ffmpeg";

/// `ff_flac_write_header` and `flac_finish_header`: `fLaC`, STREAMINFO,
/// VORBIS_COMMENT and the padding.
fn writeHeader(out: *std.Io.Writer, streaminfo: *const [flac.streaminfo_size]u8, tags: *const metadata.Dictionary, padding: u24) std.Io.Writer.Error!void {
    try out.writeAll(&.{ 'f', 'L', 'a', 'C', 0x00, 0x00, 0x00, 0x22 });
    try out.writeAll(streaminfo);
    const len: u24 = @intCast(vorbiscomment.length(vendor, tags));
    var block: [4]u8 = undefined;
    block[0] = if (padding == 0) 0x84 else 0x04;
    std.mem.writeInt(u24, block[1..4], len, .big);
    try out.writeAll(&block);
    try vorbiscomment.write(out, vendor, tags);
    if (padding != 0) {
        block[0] = 0x81;
        std.mem.writeInt(u24, block[1..4], padding, .big);
        try out.writeAll(&block);
        try out.splatByteAll(0, padding);
    }
}

pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    /// Lets `finish` rewrite STREAMINFO; null on an output that cannot seek.
    seeker: ?seek.OutputSeeker,
    params: flacenc.Params,
    options: WriteOptions,
    tags: metadata.Dictionary,
    /// The first frame's sample count, the block size unless the stream
    /// ends sooner; null until the caller knows it (`setFirstFrame`).
    first_frame: ?u32,
    frame_bytes: usize,
    /// Samples not yet encoded, from `pending_start`.
    pending: std.ArrayList(u8) = .empty,
    pending_start: usize = 0,
    /// The encoder's input for one block.
    block: Block = .{ .s16 = &.{} },
    encoder: ?*flacenc.Encoder = null,
    /// The Ogg muxer, once the encoder is open, for an Ogg container.
    ogg: ?oggmux.Muxer = null,
    /// Where STREAMINFO's bytes start in the output.
    streaminfo_offset: u64 = 0,
    pts: i64 = 0,

    const Block = union(flacenc.SampleFormat) {
        s16: []i16,
        s32: []i32,
    };

    /// What `begin` checks, without a writer: the encoder's stream and
    /// options (the block size aside) and, in FLAC's container, the tags'
    /// size (Ogg's comment packet has no 24-bit bound).
    pub fn check(gpa: std.mem.Allocator, codec: pcm.Codec, format: audio.Format, bits_per_raw_sample: u8, options: WriteOptions) (HeaderError || error{OutOfMemory})!void {
        try flacenc.Encoder.validate(try encoderParams(codec, format, bits_per_raw_sample, 0), options.encoder);
        if (options.container != .flac) return;
        var tags = muxerTags(gpa, options.tags, format.layout) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The tags came from a dictionary, which holds no NUL.
            error.InvalidTag => unreachable,
        };
        defer tags.deinit(gpa);
        if (vorbiscomment.length(vendor, &tags) >= (1 << 24) - 4) return error.TagsTooLong;
    }

    /// A writer of `codec` (pcm_s16le or pcm_s32le, the encoder's input)
    /// in `format`, whose decoded source has `bits_per_raw_sample` (above
    /// 24 encodes 32 bits under `strict_experimental`). Writes nothing yet.
    pub fn begin(gpa: std.mem.Allocator, out: *std.Io.Writer, seeker: ?seek.OutputSeeker, codec: pcm.Codec, format: audio.Format, bits_per_raw_sample: u8, first_frame: ?u32, options: WriteOptions) (HeaderError || error{OutOfMemory})!Writer {
        try check(gpa, codec, format, bits_per_raw_sample, options);
        // Ogg's muxer takes the caller's tags as they are.
        const tags: metadata.Dictionary = if (options.container == .flac) muxerTags(gpa, options.tags, format.layout) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable,
        } else .empty;
        return .{
            .gpa = gpa,
            .out = out,
            .seeker = seeker,
            .params = try encoderParams(codec, format, bits_per_raw_sample, 0),
            .options = options,
            .tags = tags,
            .first_frame = first_frame,
            .frame_bytes = codec.bytesPerSample() * format.channelCount(),
        };
    }

    pub fn deinit(w: *Writer) void {
        if (w.ogg) |*m| m.deinit();
        if (w.encoder) |e| e.deinit();
        switch (w.block) {
            inline else => |b| w.gpa.free(b),
        }
        w.pending.deinit(w.gpa);
        w.tags.deinit(w.gpa);
        w.* = undefined;
    }

    /// The first frame's size, when the caller learns it after `begin`
    /// (a resampler's first output); before any sample is written.
    pub fn setFirstFrame(w: *Writer, frames: u32) void {
        std.debug.assert(w.encoder == null and w.first_frame == null);
        w.first_frame = frames;
    }

    /// Samples, packed little-endian, whole frames per call.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        if (data.len % w.frame_bytes != 0) return error.IncompleteFrame;
        try w.pending.appendSlice(w.gpa, data);
        try w.drain(false);
    }

    fn pendingFrames(w: *const Writer) usize {
        return (w.pending.items.len - w.pending_start) / w.frame_bytes;
    }

    /// Opens the encoder with a block of `frame_size` samples (0 lets it
    /// choose) and writes the header. The writer takes the encoder, its
    /// block and the Ogg muxer only once the header is written, so on
    /// failure they are freed here alone and `deinit` frees nothing twice.
    fn open(w: *Writer, frame_size: u32) WriteError!void {
        var params = w.params;
        params.frame_size = frame_size;
        const e = flacenc.Encoder.init(w.gpa, params, w.options.encoder) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedFormat => return error.UnsupportedFormat,
            error.InvalidOption => return error.InvalidOption,
        };
        errdefer e.deinit();
        const count = @as(usize, e.frame_size) * w.params.channels;
        const block: Block = switch (w.params.sample_format) {
            .s16 => .{ .s16 = try w.gpa.alloc(i16, count) },
            .s32 => .{ .s32 = try w.gpa.alloc(i32, count) },
        };
        errdefer switch (block) {
            inline else => |b| w.gpa.free(b),
        };
        const streaminfo = e.initialStreaminfo();
        var ogg: ?oggmux.Muxer = null;
        errdefer if (ogg) |*m| m.deinit();
        var streaminfo_offset: u64 = 0;
        switch (w.options.container) {
            .flac => {
                if (w.seeker) |s| streaminfo_offset = s.position() + 8;
                try writeHeader(w.out, &streaminfo, &w.tags, w.options.padding orelse 8192);
            },
            .ogg => |o| {
                const streams = [_]oggmux.Stream{.{ .codec = .flac, .sample_rate = w.params.sample_rate, .extradata = &streaminfo, .tags = o.stream_tags }};
                ogg = oggmux.Muxer.init(w.gpa, w.out, &streams, .{ .format_tags = w.options.tags }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.TagsTooLong => error.TagsTooLong,
                    error.InvalidExtradata => unreachable, // a whole STREAMINFO
                };
                try ogg.?.writeHeader();
            },
        }
        // Nothing fails past here.
        w.encoder = e;
        w.block = block;
        w.ogg = ogg;
        w.streaminfo_offset = streaminfo_offset;
    }

    /// Encodes whole blocks, and at the end what is left; opens the encoder
    /// once the first frame's size is known.
    fn drain(w: *Writer, final: bool) WriteError!void {
        if (w.encoder == null) {
            const have: u32 = std.math.cast(u32, w.pendingFrames()) orelse std.math.maxInt(u32);
            if (w.first_frame) |first| {
                if (have >= first) {
                    try w.open(first);
                } else if (final) {
                    try w.open(have);
                } else return;
            } else if (final) {
                try w.open(have);
            } else return;
        }
        const e = w.encoder.?;
        const block = e.frame_size;
        while (w.pendingFrames() >= block or (final and w.pendingFrames() > 0)) {
            const n: u32 = @intCast(@min(block, w.pendingFrames()));
            try w.encodeBlock(e, n);
        }
        // Keep the buffer from growing: move what is left to its start.
        if (w.pending_start > 0) {
            const rest = w.pending.items[w.pending_start..];
            std.mem.copyForwards(u8, w.pending.items[0..rest.len], rest);
            w.pending.shrinkRetainingCapacity(rest.len);
            w.pending_start = 0;
        }
    }

    fn encodeBlock(w: *Writer, e: *flacenc.Encoder, n: u32) WriteError!void {
        const count = @as(usize, n) * w.params.channels;
        const bytes = w.pending.items[w.pending_start..][0 .. count * (w.frame_bytes / w.params.channels)];
        const input: flacenc.Input = switch (w.block) {
            .s16 => |b| blk: {
                for (b[0..count], 0..) |*s, i| s.* = std.mem.readInt(i16, bytes[2 * i ..][0..2], .little);
                break :blk .{ .s16 = b[0..count] };
            },
            .s32 => |b| blk: {
                for (b[0..count], 0..) |*s, i| s.* = std.mem.readInt(i32, bytes[4 * i ..][0..4], .little);
                break :blk .{ .s32 = b[0..count] };
            },
        };
        const packet = e.encode(input, n, w.pts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The writer gives whole blocks, the last one shorter.
            error.InvalidFrame => unreachable,
        };
        if (w.ogg) |*m| {
            try m.writePacket(0, packet.data, packet.pts, packet.duration);
        } else try w.out.writeAll(packet.data);
        w.pts += n;
        w.pending_start += bytes.len;
    }

    /// Encodes the rest, flushes the encoder, rewrites STREAMINFO when the
    /// output can seek back, and flushes the output.
    pub fn finish(w: *Writer) WriteError!void {
        try w.drain(true);
        const final = w.encoder.?.flush();
        if (w.ogg) |*m| return m.finish();
        try w.out.flush();
        if (w.seeker) |s| {
            const end = s.position();
            try s.seekTo(w.streaminfo_offset);
            try w.out.writeAll(&final.streaminfo);
            try s.seekTo(end);
            try w.out.flush();
        }
    }
};

const testing = std.testing;
const demux = @import("flac.zig");

fn testSamples(comptime T: type, buffer: []u8, frames: usize, channels: usize) []u8 {
    var x: u32 = 12345;
    for (0..frames * channels) |i| {
        x = x *% 1103515245 +% 12345;
        const v: T = @truncate(@as(i32, @bitCast(x)) >> 18);
        std.mem.writeInt(T, buffer[i * @sizeOf(T) ..][0..@sizeOf(T)], v, .little);
    }
    return buffer[0 .. frames * channels * @sizeOf(T)];
}

test "a written stream reads back through the demuxer and decoder, STREAMINFO rewritten" {
    const gpa = testing.allocator;
    var bytes: [1 << 16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    try tags.put(gpa, "title", "Song", .replace);
    try tags.put(gpa, "track", "3", .replace);
    const format: audio.Format = .{ .sample_rate = 44100, .layout = .stereo, .sample_format = .s16 };
    var w: Writer = try .begin(gpa, &out, .fixed(&out), .s16le, format, 16, 1152, .{ .tags = &tags });
    defer w.deinit();
    var input: [3000 * 4]u8 = undefined;
    const data = testSamples(i16, &input, 3000, 2);
    try w.writeData(data[0..1000]);
    try w.writeData(data[1000..]);
    try w.finish();

    var reader: std.Io.Reader = .fixed(out.buffered());
    var r: demux.DecodedReader = .init(gpa, &reader, null);
    r.verify_md5 = true;
    defer r.deinit();
    const header = try r.readHeader();
    try testing.expectEqual(3000, header.frame_count);
    try testing.expectEqualStrings("Song", r.demuxer.?.info.tags.get("title").?);
    // TRACKNUMBER reads back as FFmpeg's `track`.
    try testing.expectEqualStrings("3", r.demuxer.?.info.tags.get("track").?);
    try testing.expectEqual(1152, r.demuxer.?.info.stream_info.?.max_blocksize);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = try r.readData(&chunk);
        if (got.len == 0) break;
        try decoded.appendSlice(gpa, got);
    }
    try r.finish();
    try testing.expectEqualSlices(u8, data, decoded.items);
}

test "the header: fLaC, STREAMINFO, the comment and the padding; no rewrite on a pipe" {
    const gpa = testing.allocator;
    var bytes: [1 << 15]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    const format: audio.Format = .{ .sample_rate = 8000, .layout = .{ .native = 0x3 | 0x8 }, .sample_format = .s32 };
    var w: Writer = try .begin(gpa, &out, null, .s32le, format, 24, null, .{});
    defer w.deinit();
    var input: [40 * 12]u8 = undefined;
    try w.writeData(testSamples(i32, &input, 40, 3));
    try w.finish();
    const written = out.buffered();
    try testing.expectEqualStrings("fLaC\x00\x00\x00\x22", written[0..8]);
    // First written, not rewritten: no sample count or MD5.
    try testing.expectEqual(40, std.mem.readInt(u16, written[8..10], .big));
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), written[26..42]);
    // FL FR LFE is not a FLAC layout: its mask is a tag.
    const comment = "\x04\x00\x00\x37\x06\x00\x00\x00ffmpeg\x01\x00\x00\x00\x25\x00\x00\x00WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0xb";
    try testing.expectEqualStrings(comment, written[42..][0..comment.len]);
    const padding = written[42 + comment.len ..][0 .. 4 + 8192];
    try testing.expectEqualSlices(u8, "\x81\x00\x20\x00", padding[0..4]);
    try testing.expect(std.mem.allEqual(u8, padding[4..], 0));
}

test "a stream shorter than 16 samples is refused, as FFmpeg's encoder refuses its block" {
    const gpa = testing.allocator;
    var bytes: [1 << 14]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    const format: audio.Format = .{ .sample_rate = 8000, .layout = .mono, .sample_format = .s16 };
    var w: Writer = try .begin(gpa, &out, null, .s16le, format, 16, 4096, .{});
    defer w.deinit();
    var input: [8 * 2]u8 = undefined;
    try w.writeData(testSamples(i16, &input, 8, 1));
    try testing.expectError(error.UnsupportedFormat, w.finish());
    try testing.expectEqual(0, out.buffered().len);
    try testing.expectError(error.UnsupportedFormat, Writer.check(gpa, .s24le, .{ .sample_rate = 8000, .layout = .mono, .sample_format = .s32 }, 24, .{}));
    try testing.expectError(error.UnsupportedFormat, Writer.check(gpa, .s16le, .{ .sample_rate = 8000, .layout = .{ .unspecified = 9 }, .sample_format = .s16 }, 16, .{}));
}

test "a header the output refuses fails once, and deinit frees each part once" {
    const gpa = testing.allocator;
    const format: audio.Format = .{ .sample_rate = 8000, .layout = .mono, .sample_format = .s16 };
    var input: [32 * 2]u8 = undefined;
    const data = testSamples(i16, &input, 32, 1);
    for ([_]WriteOptions.Container{ .flac, .{ .ogg = .{} } }) |container| {
        // Too small for the header (fLaC and STREAMINFO alone are 42
        // bytes; an Ogg page header is 27).
        var bytes: [16]u8 = undefined;
        var out: std.Io.Writer = .fixed(&bytes);
        var w: Writer = try .begin(gpa, &out, null, .s16le, format, 16, 16, .{ .container = container });
        defer w.deinit();
        // The first whole block opens the encoder and writes the header.
        try testing.expectError(error.WriteFailed, w.writeData(data));
        try testing.expectEqual(null, w.encoder);
        try testing.expectEqual(null, w.ogg);
    }
}
