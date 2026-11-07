// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpegaudiodecheader.c and .h
// (ff_mpa_check_header, ff_mpegaudio_decode_header, ff_mpa_decode_header),
// mpegaudiotabs.h (ff_mpa_bitrate_tab, ff_mpa_freq_tab), mpegaudio_parser.c
// (mpegaudio_parse) and parser.c (ff_combine_frame) at the pinned reference
// revision.
// Copyright (c) 2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! MPEG audio frame headers and FFmpeg's `mpegaudio` parser (TODO.md T29a):
//! the 32-bit header of an MPEG-1, 2 or 2.5 Layer I, II or III frame, its
//! size, rate, channels and bit rate, and the parser that splits a byte
//! stream into frames as `AVSTREAM_PARSE_FULL_RAW` streams use it, filling
//! the codec context (rate, channels, codec, bit rate, the frame's
//! duration) once a header repeats.

const std = @import("std");

/// `MP3_MASK`: the header bits that stay the same in a stream.
pub const mp3_mask: u32 = 0xFFFE0CCF;

/// `ff_mpa_bitrate_tab`: kbit/s by [lsf][layer - 1][index].
pub const bitrate_tab = [2][3][15]u16{
    .{
        .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
        .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
    },
    .{
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
    },
};

/// `ff_mpa_freq_tab`.
pub const freq_tab = [3]u32{ 44100, 48000, 32000 };

/// `ff_mpa_check_header`: the sync word and no reserved version, layer,
/// bit rate or rate.
pub fn checkHeader(header: u32) bool {
    if (header & 0xffe00000 != 0xffe00000) return false;
    if (header & (3 << 19) == 1 << 19) return false;
    if (header & (3 << 17) == 0) return false;
    if (header & (0xf << 12) == 0xf << 12) return false;
    if (header & (3 << 10) == 3 << 10) return false;
    return true;
}

/// `MPADecodeHeader2`.
pub const Header = struct {
    /// The frame's bytes; 0 for free format (bit rate index 0), whose size
    /// FFmpeg does not compute.
    frame_size: u32,
    error_protection: bool,
    /// 1 to 3.
    layer: u2,
    sample_rate: u32,
    /// 0 to 8.
    sample_rate_index: u4,
    bit_rate: u32,
    nb_channels: u2,
    mode: u2,
    mode_ext: u2,
    /// MPEG-2 and 2.5's lower sampling frequencies.
    lsf: bool,
    copyright: bool,
    original: bool,
    emphasis: u2,
    bitrate_index: u4,
    padding: u1,
    private_bit: u1,

    /// Free format: no frame size.
    pub fn freeFormat(h: Header) bool {
        return h.bitrate_index == 0;
    }
};

/// `ff_mpegaudio_decode_header`: null for a header `checkHeader` refuses.
pub fn decodeHeader(header: u32) ?Header {
    if (!checkHeader(header)) return null;
    var lsf: u1 = undefined;
    var mpeg25: u1 = undefined;
    if (header & (1 << 20) != 0) {
        lsf = if (header & (1 << 19) != 0) 0 else 1;
        mpeg25 = 0;
    } else {
        lsf = 1;
        mpeg25 = 1;
    }
    const layer: u2 = @intCast(4 - ((header >> 17) & 3));
    const rate_index: u4 = @intCast((header >> 10) & 3);
    const sample_rate = freq_tab[rate_index] >> (@as(u5, lsf) + mpeg25);
    const bitrate_index: u4 = @intCast((header >> 12) & 0xf);
    const padding: u1 = @intCast((header >> 9) & 1);
    const mode: u2 = @intCast((header >> 6) & 3);
    var h: Header = .{
        .frame_size = 0,
        .error_protection = (header >> 16) & 1 == 0,
        .layer = layer,
        .sample_rate = sample_rate,
        .sample_rate_index = rate_index + 3 * (@as(u4, lsf) + mpeg25),
        .bit_rate = 0,
        .nb_channels = if (mode == 3) 1 else 2,
        .mode = mode,
        .mode_ext = @intCast((header >> 4) & 3),
        .lsf = lsf == 1,
        .copyright = (header >> 3) & 1 != 0,
        .original = (header >> 2) & 1 != 0,
        .emphasis = @intCast(header & 3),
        .bitrate_index = bitrate_index,
        .padding = padding,
        .private_bit = @intCast((header >> 8) & 1),
    };
    if (bitrate_index != 0) {
        const kbps: u32 = bitrate_tab[lsf][layer - 1][bitrate_index];
        h.bit_rate = kbps * 1000;
        h.frame_size = switch (layer) {
            1 => (kbps * 12000 / sample_rate + padding) * 4,
            2 => kbps * 144000 / sample_rate + padding,
            else => kbps * 144000 / (sample_rate << lsf) + padding,
        };
    }
    return h;
}

/// The MPEG audio codecs, by layer.
pub const Codec = enum { mp1, mp2, mp3 };

/// What `ff_mpa_decode_header` gives for a header with a frame size.
pub const Info = struct {
    frame_size: u32,
    sample_rate: u32,
    channels: u2,
    /// Samples per channel in the frame.
    frame_samples: u32,
    bit_rate: u32,
    codec: Codec,
};

/// `ff_mpa_decode_header`: null for an invalid or free-format header.
pub fn decodeInfo(header: u32) ?Info {
    const h = decodeHeader(header) orelse return null;
    if (h.freeFormat()) return null;
    return .{
        .frame_size = h.frame_size,
        .sample_rate = h.sample_rate,
        .channels = h.nb_channels,
        .frame_samples = switch (h.layer) {
            1 => 384,
            2 => 1152,
            else => if (h.lsf) 576 else 1152,
        },
        .bit_rate = h.bit_rate,
        .codec = switch (h.layer) {
            1 => .mp1,
            2 => .mp2,
            else => .mp3,
        },
    };
}

/// The codec context fields the parser reads and fills
/// (`AVCodecContext`): the demuxer's codec, then the frames'.
pub const Context = struct {
    codec: Codec = .mp3,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    bit_rate: i64 = 0,
};

/// `ParseContext` with `ff_combine_frame`, for a parser that never
/// overreads (`next` is a frame end at or after the bytes it was given, or
/// none).
const ParseContext = struct {
    buffer: std.ArrayList(u8) = .empty,
    /// `index`: the bytes held of a frame not yet complete.
    held: usize = 0,
    state: u32 = 0,

    /// `ff_combine_frame`: with `next` null (END_NOT_FOUND) the bytes are
    /// held and null returned; otherwise the frame, the held bytes and
    /// `buf[0..next]`.
    fn combine(pc: *ParseContext, gpa: std.mem.Allocator, next_in: ?usize, buf: []const u8) std.mem.Allocator.Error!?[]const u8 {
        var next = next_in;
        // At the end, flush what is held.
        if (buf.len == 0 and next == null) next = 0;
        const n = next orelse {
            try pc.buffer.resize(gpa, pc.held);
            try pc.buffer.appendSlice(gpa, buf);
            pc.held += buf.len;
            return null;
        };
        if (pc.held == 0) return buf[0..n];
        try pc.buffer.resize(gpa, pc.held);
        try pc.buffer.appendSlice(gpa, buf[0..n]);
        pc.held = 0;
        return pc.buffer.items;
    }
};

/// The MPEG audio parser (`mpegaudio_parse`), `PARSER_FLAG_COMPLETE_FRAMES`
/// off.
pub const Parser = struct {
    pc: ParseContext = .{},
    /// The bytes of the current frame still to come.
    frame_size: u32 = 0,
    header: u32 = 0,
    header_count: i32 = 0,
    no_bitrate: bool = false,
    /// `AVCodecParserContext.duration`: the last frame's samples once a
    /// header repeated, 0 before.
    duration: u32 = 0,

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.pc.buffer.deinit(gpa);
        p.* = undefined;
    }

    pub const Result = struct {
        /// The bytes of `buf` consumed.
        consumed: usize,
        /// A frame, valid until the next call; null when none is complete.
        frame: ?[]const u8,
    };

    /// One call: `buf` (empty at the end) scanned for frame boundaries,
    /// `ctx` updated from each header found once a header repeats.
    pub fn parse(p: *Parser, gpa: std.mem.Allocator, ctx: *Context, buf: []const u8) std.mem.Allocator.Error!Result {
        var state = p.pc.state;
        var next: ?usize = null;
        const flush = buf.len == 0;
        var i: usize = 0;
        while (i < buf.len) {
            if (p.frame_size != 0) {
                const inc = @min(buf.len - i, p.frame_size);
                i += inc;
                p.frame_size -= @intCast(inc);
                state = 0;
                if (p.frame_size == 0) {
                    next = i;
                    break;
                }
            } else {
                while (i < buf.len) {
                    state = (state << 8) +% buf[i];
                    i += 1;
                    const info = decodeInfo(state);
                    // ff_mpa_decode_header's size, -1 when there is none.
                    const ret: i64 = if (info) |f| f.frame_size else -1;
                    if (ret < 4) {
                        if (i > 4) p.header_count = -2;
                        continue;
                    }
                    const f = info.?;
                    const threshold: i32 = @intFromBool(ctx.codec != f.codec);
                    if (state & same_header_mask != p.header & same_header_mask and p.header != 0) p.header_count = -3;
                    p.header = state;
                    // An int in FFmpeg: after 2^31 matching headers it
                    // wraps to INT_MIN as the reference build computes it
                    // (notes.md "Follow the reference build"), and the
                    // context stops updating until it climbs back.
                    p.header_count +%= 1;
                    p.frame_size = f.frame_size - 4;
                    if (p.header_count > threshold) {
                        ctx.sample_rate = f.sample_rate;
                        ctx.channels = f.channels;
                        p.duration = f.frame_samples;
                        ctx.codec = f.codec;
                        if (p.no_bitrate or ctx.bit_rate == 0) {
                            p.no_bitrate = true;
                            // C's int64 division truncates toward zero.
                            ctx.bit_rate += @divTrunc(@as(i64, f.bit_rate) - ctx.bit_rate, p.header_count - threshold);
                        }
                    }
                    break;
                }
            }
        }
        p.pc.state = state;
        const frame = try p.pc.combine(gpa, next, buf) orelse return .{ .consumed = buf.len, .frame = null };
        const end = next orelse 0;
        // At the end, an ID3v1 or APE tag is no frame.
        if (flush and frame.len >= 128 and std.mem.startsWith(u8, frame, "TAG")) return .{ .consumed = end, .frame = null };
        if (flush and frame.len >= 32 and std.mem.startsWith(u8, frame, "APETAGEX")) return .{ .consumed = end, .frame = null };
        return .{ .consumed = end, .frame = if (frame.len == 0) null else frame };
    }
};

/// `SAME_HEADER_MASK`: sync, layer, rate and version.
const same_header_mask: u32 = 0xffe00000 | (3 << 17) | (3 << 10) | (3 << 19);

const testing = std.testing;

test "headers decode as FFmpeg's: sizes of each layer and version, free format, reserved fields" {
    // MPEG-1 Layer III, 128 kbit/s, 44100 Hz, padded: 418 bytes.
    const h = decodeHeader(0xFFFB9264).?;
    try testing.expectEqual(3, h.layer);
    try testing.expectEqual(44100, h.sample_rate);
    try testing.expectEqual(418, h.frame_size);
    try testing.expect(!h.error_protection);
    // MPEG-2 Layer III, 64 kbit/s, 22050 Hz: 576 samples a frame.
    const lsf = decodeInfo(0xFFF38000).?;
    try testing.expectEqual(22050, lsf.sample_rate);
    try testing.expectEqual(576, lsf.frame_samples);
    try testing.expectEqual(208, lsf.frame_size);
    // Layer I, 384 kbit/s, 44100 Hz: (384 * 12000 / 44100 + 0) * 4.
    try testing.expectEqual(416, decodeInfo(0xFFFFC000).?.frame_size);
    // Free format has a header but no size.
    try testing.expect(decodeHeader(0xFFFB0000).?.freeFormat());
    try testing.expectEqual(null, decodeInfo(0xFFFB0000));
    // Reserved version, layer, bit rate and rate.
    try testing.expectEqual(null, decodeHeader(0xFFEB9000));
    try testing.expectEqual(null, decodeHeader(0xFFF99000));
    try testing.expectEqual(null, decodeHeader(0xFFFBF000));
    try testing.expectEqual(null, decodeHeader(0xFFFB9C00));
}

test "the parser's header count wraps after 2^31 matching headers, as the reference build's int" {
    const gpa = testing.allocator;
    var p: Parser = .{ .header = 0xFFFB9264, .header_count = std.math.maxInt(i32) };
    defer p.deinit(gpa);
    var ctx: Context = .{};
    // One header like the last: the count wraps instead of overflowing,
    // so the context is not updated from it.
    _ = try p.parse(gpa, &ctx, &.{ 0xFF, 0xFB, 0x92, 0x64 });
    try testing.expectEqual(std.math.minInt(i32), p.header_count);
    try testing.expectEqual(0, ctx.sample_rate);
}

const fixtures = @import("../testing/fixtures.zig");
const hostile = @import("../testing/hostile.zig");

/// parse_packet's loop over `bytes` given in pieces of `chunk` bytes, then
/// the flush; the frames returned. Every call consumes bytes or returns a
/// frame, so the calls are bounded by the bytes.
fn parseAll(gpa: std.mem.Allocator, bytes: []const u8, chunk: usize, codec: Codec) !u32 {
    var p: Parser = .{};
    defer p.deinit(gpa);
    var ctx: Context = .{ .codec = codec };
    var frames: u32 = 0;
    var calls: usize = 0;
    var rest = bytes;
    while (rest.len > 0) {
        var data = rest[0..@min(chunk, rest.len)];
        rest = rest[data.len..];
        while (data.len > 0) : (calls += 1) {
            if (calls > 2 * bytes.len + 2) return error.TestUnboundedParse;
            const r = try p.parse(gpa, &ctx, data);
            if (r.consumed == 0 and r.frame == null) return error.TestUnboundedParse;
            data = data[r.consumed..];
            if (r.frame) |f| {
                try testing.expect(f.len > 0);
                frames += 1;
            }
        }
    }
    while (true) : (calls += 1) {
        if (calls > 2 * bytes.len + 4) return error.TestUnboundedParse;
        const r = try p.parse(gpa, &ctx, &.{});
        if (r.frame == null) break;
        frames += 1;
    }
    return frames;
}

test "the parser frees everything under every allocation failure, fed in pieces" {
    inline for (.{ "mp3_junk_between", "mp3_layer_change", "mp3_free_format", "mp3_ape_tag", "mp3_id3v1" }) |name| {
        for ([_]usize{ 1000, 4096 }) |chunk| {
            try hostile.checkAll(parseAll, .{ fixtures.mp3.bytes(name), chunk, Codec.mp3 });
        }
    }
}

/// Arbitrary bytes through the parser, in pieces of 1 to 4096 bytes (the
/// first value), the context's codec first the second value's.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

fn fuzzRun(smith: *std.testing.Smith) !u32 {
    var input: [16710 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const chunk = smith.valueRangeAtMost(u16, 1, 4096);
    const codec: Codec = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .mp3,
        1 => .mp2,
        else => .mp1,
    };
    return parseAll(testing.allocator, input[0..len], chunk, codec);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_mpeg1_l3_stereo"), &.{ 1024, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_junk_between"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_layer_change"), &.{ 333, 2 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_rate_change"), &.{ 4096, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_header_emulation"), &.{ 17, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_ape_tag"), &.{ 4096, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp2_layer2_48k"), &.{ 512, 1 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_mpeg25_l3_8k"), &.{ 100, 0 }),
};

test "fuzz: the MPEG audio parser on arbitrary bytes in arbitrary pieces" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the MPEG audio parser's fuzz entry gives frames" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 5);
    }
}

test "mutation smoke: the MPEG audio parser on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 256, 0x6d7061);
}
