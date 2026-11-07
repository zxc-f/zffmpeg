// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/adts_header.c (ff_adts_header_parse),
// aac_parser.c (aac_sync), aac_ac3_parser.c (ff_aac_ac3_parse, its AAC
// path) and mpeg4audio_sample_rates.h at the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// Copyright (c) 2003 Michael Niedermayer
// Copyright (c) 2009 Alex Converse
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! ADTS frame headers and FFmpeg's AAC parser (TODO.md T30a), without
//! decoding: the 7-byte header's fields, and the parser that splits raw
//! bytes into ADTS frames for libavformat's AVSTREAM_PARSE_FULL_RAW. It
//! sets the codec context's profile and average bit rate and marks each
//! frame whose header parses as a keyframe; the sample rate, channels and
//! frame durations are left to the decoder (codec/aacdec.zig, T30b), as in
//! FFmpeg, where HE-AAC makes the header's values unreliable.

const std = @import("std");
const aac_ac3_parser = @import("aac_ac3_parser.zig");

/// `AV_AAC_ADTS_HEADER_SIZE`.
pub const header_size = 7;

/// `ff_mpeg4audio_sample_rates`: by sampling frequency index; 0 for the
/// reserved and escape indexes.
pub const sample_rates = [16]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0 };

/// `AACADTSHeaderInfo`.
pub const Header = struct {
    sample_rate: u32,
    /// 1024 per raw data block.
    samples: u32,
    bit_rate: u32,
    crc_absent: bool,
    /// The MPEG-4 audio object type: the profile plus 1.
    object_type: u8,
    sampling_index: u4,
    chan_config: u3,
    num_aac_frames: u8,
    frame_length: u32,
};

/// `ff_adts_header_parse`'s failures (AAC_PARSE_ERROR_*).
pub const HeaderError = error{
    /// No 12-bit sync word.
    Sync,
    /// A reserved or escape sampling frequency index.
    SampleRate,
    /// A frame length below the header's 7 bytes.
    FrameSize,
};

/// `ff_adts_header_parse` on a frame's first 7 bytes.
pub fn parseHeader(bytes: *const [header_size]u8) HeaderError!Header {
    const v = std.mem.readInt(u56, bytes, .big);
    if (v >> 44 != 0xfff) return error.Sync;
    const crc_absent = (v >> 40) & 1 != 0;
    const aot: u8 = @intCast((v >> 38) & 3);
    const sr: u4 = @intCast((v >> 34) & 0xf);
    if (sample_rates[sr] == 0) return error.SampleRate;
    const ch: u3 = @intCast((v >> 30) & 7);
    const size: u32 = @intCast((v >> 13) & 0x1fff);
    if (size < header_size) return error.FrameSize;
    const rdb: u8 = @intCast(v & 3);
    const samples = (@as(u32, rdb) + 1) * 1024;
    const rate = sample_rates[sr];
    return .{
        .sample_rate = rate,
        .samples = samples,
        // `size * 8 * hdr->sample_rate / hdr->samples`: the int product
        // times a uint32_t, in unsigned 32-bit arithmetic, which wraps.
        .bit_rate = (size * 8 *% rate) / samples,
        .crc_absent = crc_absent,
        .object_type = aot + 1,
        .sampling_index = sr,
        .chan_config = ch,
        .num_aac_frames = rdb + 1,
        .frame_length = size,
    };
}

/// What the AAC parser sets in libavformat's codec context.
pub const Context = struct {
    /// `avctx->profile`, null for AV_PROFILE_UNKNOWN: the first parsed
    /// frame's object type less 1.
    profile: ?u8 = null,
    /// `avctx->bit_rate`: the running average of the frames' bit rates.
    bit_rate: i64 = 0,
};

/// `END_NOT_FOUND`, which the parser returns as its index on the flush.
pub const end_not_found = aac_ac3_parser.end_not_found;

/// FFmpeg's AAC parser (`ff_aac_ac3_parse` with `aac_sync`),
/// `PARSER_FLAG_COMPLETE_FRAMES` off.
pub const Parser = struct {
    splitter: aac_ac3_parser.Splitter(header_size, sync) = .{},
    /// The frames whose header parsed; an int.
    frame_number: i32 = 0,

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.splitter.deinit(gpa);
        p.* = undefined;
    }

    pub const Result = struct {
        /// The parser's index (`av_parser_parse2`'s): the bytes of `buf`
        /// consumed, or a negative count the next call reads again (the
        /// frame ended among held bytes), `end_not_found` on the flush.
        index: i64,
        /// A frame, valid until the next call; null when none is complete.
        frame: ?[]const u8,
        /// `key_frame == 1`: the frame's own header parsed.
        key: bool,
    };

    /// One call: `buf` (empty at the end) scanned for frame starts.
    pub fn parse(p: *Parser, gpa: std.mem.Allocator, ctx: *Context, buf: []const u8) std.mem.Allocator.Error!Result {
        const step = try p.splitter.split(gpa, buf);
        const frame = step.frame orelse return .{ .index = step.index, .frame = null, .key = false };
        if (!step.got_frame or frame.len < header_size) return .{ .index = step.index, .frame = frame, .key = false };
        const hdr = parseHeader(frame[0..header_size]) catch return .{ .index = step.index, .frame = frame, .key = false };
        if (ctx.profile == null) ctx.profile = hdr.object_type - 1;
        // The int frame count wraps after 2^31 frames as on the reference
        // build (notes.md "Follow the reference build"); at 2^32, where
        // FFmpeg divides by zero, the average is left as it is.
        p.frame_number +%= 1;
        if (p.frame_number != 0) ctx.bit_rate += @divTrunc(@as(i64, hdr.bit_rate) - ctx.bit_rate, p.frame_number);
        return .{ .index = step.index, .frame = frame, .key = true };
    }
};

/// `aac_sync`: the header in the last 7 bytes of `state`; a new frame,
/// with no next header needed.
fn sync(state: u64) ?aac_ac3_parser.Sync {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, state, .big);
    const hdr = parseHeader(bytes[8 - header_size ..][0..header_size]) catch return null;
    return .{ .frame_size = hdr.frame_length, .new_frame_start = true, .need_next_header = false };
}

const testing = std.testing;

test "ADTS headers: fields, the bit rate and the refusals" {
    // MPEG-4 LC, 44.1 kHz, stereo, 333 bytes, one raw data block.
    const h = try parseHeader(&.{ 0xff, 0xf1, 0x50, 0x80, 0x29, 0xbf, 0xfc });
    try testing.expectEqual(44100, h.sample_rate);
    try testing.expectEqual(2, h.object_type);
    try testing.expectEqual(2, h.chan_config);
    try testing.expectEqual(333, h.frame_length);
    try testing.expectEqual(1024, h.samples);
    try testing.expectEqual(333 * 8 * 44100 / 1024, h.bit_rate);
    try testing.expect(h.crc_absent);
    try testing.expectError(error.Sync, parseHeader(&.{ 0xff, 0xe1, 0x50, 0x80, 0x29, 0xbf, 0xfc }));
    try testing.expectError(error.SampleRate, parseHeader(&.{ 0xff, 0xf1, 0x74, 0x80, 0x29, 0xbf, 0xfc }));
    try testing.expectError(error.FrameSize, parseHeader(&.{ 0xff, 0xf1, 0x50, 0x80, 0x00, 0xdf, 0xfc }));
    // 96 kHz and the longest frame: 8191 * 8 * 96000 wraps in 32 bits.
    const big = try parseHeader(&.{ 0xff, 0xf1, 0x40, 0x83, 0xff, 0xff, 0xfc });
    try testing.expectEqual(8191, big.frame_length);
    try testing.expectEqual((@as(u32, 8191 * 8) *% 96000) / 1024, big.bit_rate);
}

/// An ADTS frame of `len` bytes at 44.1 kHz with a filler payload.
fn testFrame(comptime len: u13) [len]u8 {
    var f: [len]u8 = @splat(0x21);
    const v: u56 = (0xfff << 44) | (1 << 40) | (1 << 38) | (4 << 34) | (2 << 30) | (@as(u56, len) << 13) | (0x7ff << 2);
    std.mem.writeInt(u56, f[0..7], v, .big);
    return f;
}

test "the parser splits frames across any read sizes and averages the bit rate" {
    const gpa = testing.allocator;
    const stream = testFrame(40) ++ testFrame(25) ++ testFrame(31);
    for ([_]usize{ 1, 3, 7, 40, 96 }) |step| {
        var p: Parser = .{};
        defer p.deinit(gpa);
        var ctx: Context = .{};
        var sizes: [4]usize = undefined;
        var keys: [4]bool = undefined;
        var n: usize = 0;
        var at: usize = 0;
        while (true) {
            const chunk = stream[at..@min(stream.len, at + step)];
            const res = try p.parse(gpa, &ctx, chunk);
            if (res.frame) |f| {
                sizes[n] = f.len;
                keys[n] = res.key;
                n += 1;
            }
            if (chunk.len == 0) break;
            if (res.index > 0) at += @intCast(res.index);
        }
        try testing.expectEqualSlices(usize, &.{ 40, 25, 31 }, sizes[0..n]);
        // A frame is a keyframe when the call that completes it found its
        // header: always with whole frames, never with one byte at a time.
        if (step >= 40) try testing.expectEqualSlices(bool, &.{ true, true, true }, keys[0..n]);
        if (step == 1) try testing.expectEqualSlices(bool, &.{ false, false, false }, keys[0..n]);
        if (step < 40) continue;
        try testing.expectEqual(1, ctx.profile);
        // The running average in integer steps.
        var avg: i64 = 0;
        for ([_]i64{ 40, 25, 31 }, 1..) |len, count| {
            const frames: i64 = @intCast(count);
            avg += @divTrunc(@divTrunc(len * 8 * 44100, 1024) - avg, frames);
        }
        try testing.expectEqual(avg, ctx.bit_rate);
    }
}
