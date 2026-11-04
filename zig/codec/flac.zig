// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/flac.c (ff_flac_decode_frame_header, ff_flac_parse_streaminfo,
// ff_flac_set_channel_layout), flacdata.c, flac.h, flac_parse.h and
// libavutil/common.h (GET_UTF8) at the pinned reference revision describe the
// behavior, restated here.
//! What FLAC's parser, decoder and demuxer share (TODO.md T26a): the frame
//! header as FFmpeg reads it, STREAMINFO, and FFmpeg's channel layouts for
//! FLAC's channel counts.

const std = @import("std");
const bits = @import("bits.zig");
const channel_layout = @import("../core/channel_layout.zig");

pub const streaminfo_size = 34;
pub const max_channels = 8;
pub const min_blocksize = 16;
pub const max_blocksize = 65535;
/// The smallest frame FFmpeg's decoder tries to decode.
pub const min_frame_size = 10;

pub const sample_rate_table = [16]u32{ 0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000, 0, 0, 0, 0 };
pub const blocksize_table = [16]u32{ 0, 192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
const sample_size_table = [8]u8{ 0, 8, 12, 0, 16, 20, 24, 32 };

/// How a stereo frame codes its channels (FLAC_CHMODE_*).
pub const ChannelMode = enum(u2) {
    independent = 0,
    left_side = 1,
    right_side = 2,
    mid_side = 3,
};

/// FFmpeg's FLACFrameInfo.
pub const FrameInfo = struct {
    /// 0 when the header defers to STREAMINFO.
    sample_rate: u32 = 0,
    channels: u8 = 0,
    /// 0 when the header defers to STREAMINFO.
    bps: u8 = 0,
    blocksize: u32 = 0,
    ch_mode: ChannelMode = .independent,
    frame_or_sample_num: i64 = 0,
    is_var_size: bool = false,
};

/// Why `decodeFrameHeader` refused a header, FFmpeg's log messages.
pub const HeaderProblem = enum {
    sync_code,
    channel_mode,
    sample_size_code,
    padding,
    utf8,
    blocksize_code,
    sample_rate_code,
    crc,

    pub fn message(problem: HeaderProblem) []const u8 {
        return switch (problem) {
            .sync_code => "invalid sync code",
            .channel_mode => "invalid channel mode",
            .sample_size_code => "invalid sample size code",
            .padding => "broken stream, invalid padding",
            .utf8 => "sample/frame number invalid; utf8 fscked",
            .blocksize_code => "reserved blocksize code: 0",
            .sample_rate_code => "illegal sample rate code",
            .crc => "header crc mismatch",
        };
    }
};

pub const HeaderResult = union(enum) {
    ok: FrameInfo,
    invalid: HeaderProblem,
};

/// GET_UTF8 as get_utf8 uses it: FLAC's frame or sample number, or null.
fn readUtf8(r: *bits.BitReader) ?i64 {
    var val: i64 = r.bits(8);
    var top: u32 = @intCast((val & 128) >> 1);
    if ((val & 0xc0) == 0x80 or val >= 0xfe) return null;
    while (val & top != 0) {
        const tmp = r.bits(8) -% 128;
        if (tmp >> 6 != 0) return null;
        val = (val << 6) + tmp;
        top <<= 5;
    }
    val &= (top << 1) -% 1;
    return val;
}

/// ff_flac_decode_frame_header: reads a frame header from the start of the
/// reader's input, CRC-8 included.
pub fn decodeFrameHeader(r: *bits.BitReader) HeaderResult {
    if (r.bits(15) & 0x7fff != 0x7ffc) return .{ .invalid = .sync_code };
    var fi: FrameInfo = .{};
    fi.is_var_size = r.bit() == 1;
    const bs_code = r.bits(4);
    const sr_code = r.bits(4);
    const mode = r.bits(4);
    if (mode < max_channels) {
        fi.channels = @intCast(mode + 1);
        fi.ch_mode = .independent;
    } else if (mode < max_channels + 3) {
        // Codes 8, 9 and 10: left/side, right/side and mid/side.
        fi.channels = 2;
        fi.ch_mode = @fromBackingInt(@intCast(mode - (max_channels - 1)));
    } else return .{ .invalid = .channel_mode };
    const bps_code = r.bits(3);
    if (bps_code == 3) return .{ .invalid = .sample_size_code };
    fi.bps = sample_size_table[bps_code];
    if (r.bit() == 1) return .{ .invalid = .padding };
    fi.frame_or_sample_num = readUtf8(r) orelse return .{ .invalid = .utf8 };
    fi.blocksize = switch (bs_code) {
        0 => return .{ .invalid = .blocksize_code },
        6 => r.bits(8) + 1,
        7 => r.bits(16) + 1,
        else => blocksize_table[bs_code],
    };
    fi.sample_rate = switch (sr_code) {
        0...11 => sample_rate_table[sr_code],
        12 => r.bits(8) * 1000,
        13 => r.bits(16),
        14 => r.bits(16) * 10,
        else => return .{ .invalid = .sample_rate_code },
    };
    r.skip(8);
    if (crc8Padded(r.bytes, r.count() / 8) != 0) return .{ .invalid = .crc };
    return .{ .ok = fi };
}

/// The CRC-8 of the first `len` bytes of `bytes` followed by zero padding,
/// as FFmpeg computes it over a padded buffer.
fn crc8Padded(bytes: []const u8, len: usize) u8 {
    var crc: bits.Crc8 = .init();
    crc.update(bytes[0..@min(len, bytes.len)]);
    var rest = len -| bytes.len;
    const zeros: [16]u8 = @splat(0);
    while (rest > 0) {
        const n = @min(rest, zeros.len);
        crc.update(zeros[0..n]);
        rest -= n;
    }
    return crc.final();
}

/// FFmpeg's FLACStreaminfo.
pub const StreamInfo = struct {
    min_blocksize: u16,
    max_blocksize: u16,
    min_framesize: u24,
    max_framesize: u24,
    sample_rate: u32,
    channels: u8,
    bps: u8,
    /// Samples per channel, 0 when unknown.
    samples: u64,
    md5: [16]u8,

    /// The 34 bytes of a STREAMINFO block, field by field.
    pub fn parse(body: *const [streaminfo_size]u8) StreamInfo {
        const packed_fields = std.mem.readInt(u64, body[10..18], .big);
        var md5: [16]u8 = undefined;
        @memcpy(&md5, body[18..34]);
        return .{
            .min_blocksize = std.mem.readInt(u16, body[0..2], .big),
            .max_blocksize = std.mem.readInt(u16, body[2..4], .big),
            .min_framesize = std.mem.readInt(u24, body[4..7], .big),
            .max_framesize = std.mem.readInt(u24, body[7..10], .big),
            .sample_rate = @intCast(packed_fields >> 44),
            .channels = @intCast((packed_fields >> 41 & 0x7) + 1),
            .bps = @intCast((packed_fields >> 36 & 0x1f) + 1),
            .samples = packed_fields & ((1 << 36) - 1),
            .md5 = md5,
        };
    }
};

/// ff_flac_set_channel_layout: FFmpeg's layout for a FLAC channel count.
pub fn channelLayout(channels: u8) channel_layout.Layout {
    std.debug.assert(channels >= 1 and channels <= max_channels);
    return .{ .native = layout_masks[channels - 1] };
}

/// `ff_flac_is_native_layout`: whether `mask` is one of FLAC's layouts,
/// whatever its channel count.
pub fn isNativeLayout(mask: u64) bool {
    return std.mem.findScalar(u64, &layout_masks, mask) != null;
}

/// flac.c's flac_channel_layouts: mono, stereo, surround, quad, 5.0, 5.1,
/// 6.1 and 7.1, by FFmpeg's names for them.
const layout_masks = masks: {
    const names = [max_channels][]const u8{ "mono", "stereo", "3.0", "quad", "5.0(side)", "5.1(side)", "6.1", "7.1" };
    var out: [max_channels]u64 = undefined;
    for (names, &out) |name, *m| {
        m.* = for (channel_layout.named_layouts) |n| {
            if (std.mem.eql(u8, n.name, name)) break n.mask;
        } else @compileError("no named layout " ++ name);
    }
    break :masks out;
};

const testing = std.testing;

fn headerOf(bytes: []const u8) HeaderResult {
    var r = bits.BitReader.init(bytes) catch unreachable;
    return decodeFrameHeader(&r);
}

/// A header's bytes with its CRC-8 appended.
fn withCrc(comptime header: []const u8) [header.len + 1]u8 {
    var out: [header.len + 1]u8 = undefined;
    @memcpy(out[0..header.len], header);
    out[header.len] = bits.Crc8.hash(header);
    return out;
}

test "a frame header reads as FFmpeg reads it" {
    // Fixed blocking, 4096 samples, 44.1 kHz, mid/side, 16 bits, frame 5.
    const header = withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa8, 0x05 });
    const fi = headerOf(&header).ok;
    try testing.expectEqual(4096, fi.blocksize);
    try testing.expectEqual(44100, fi.sample_rate);
    try testing.expectEqual(2, fi.channels);
    try testing.expectEqual(ChannelMode.mid_side, fi.ch_mode);
    try testing.expectEqual(16, fi.bps);
    try testing.expectEqual(5, fi.frame_or_sample_num);
    try testing.expectEqual(false, fi.is_var_size);
    // An 8-bit size at the end, a rate in Hz, a two-byte frame number.
    const sized = withCrc(&.{ 0xff, 0xf9, 0x6d, 0x08, 0xc2, 0x80, 0x0f, 0x30, 0x39 });
    const fs = headerOf(&sized).ok;
    try testing.expectEqual(16, fs.blocksize);
    try testing.expectEqual(12345, fs.sample_rate);
    try testing.expectEqual(1, fs.channels);
    try testing.expectEqual(128, fs.frame_or_sample_num);
    try testing.expectEqual(true, fs.is_var_size);
}

test "every refusal of the frame header" {
    try testing.expectEqual(HeaderProblem.sync_code, headerOf(&withCrc(&.{ 0xff, 0xf0, 0xc9, 0xa8, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.channel_mode, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xb8, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.sample_size_code, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa6, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.padding, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa9, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.utf8, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa8, 0x85 })).invalid);
    try testing.expectEqual(HeaderProblem.utf8, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa8, 0xfe })).invalid);
    try testing.expectEqual(HeaderProblem.utf8, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xc9, 0xa8, 0xc2, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.blocksize_code, headerOf(&withCrc(&.{ 0xff, 0xf8, 0x09, 0xa8, 0x05 })).invalid);
    try testing.expectEqual(HeaderProblem.sample_rate_code, headerOf(&withCrc(&.{ 0xff, 0xf8, 0xcf, 0xa8, 0x05 })).invalid);
    const bad_crc = [_]u8{ 0xff, 0xf8, 0xc9, 0xa8, 0x05, 0x00 };
    try testing.expectEqual(HeaderProblem.crc, headerOf(&bad_crc).invalid);
}

test "the frame number's extended UTF-8, up to FFmpeg's six bytes" {
    const cases = [_]struct { bytes: []const u8, value: ?i64 }{
        .{ .bytes = &.{0x7f}, .value = 0x7f },
        .{ .bytes = &.{ 0xdf, 0xbf }, .value = 0x7ff },
        .{ .bytes = &.{ 0xef, 0xbf, 0xbf }, .value = 0xffff },
        .{ .bytes = &.{ 0xf7, 0xbf, 0xbf, 0xbf }, .value = 0x1fffff },
        .{ .bytes = &.{ 0xfb, 0xbf, 0xbf, 0xbf, 0xbf }, .value = 0x3ffffff },
        .{ .bytes = &.{ 0xfd, 0xbf, 0xbf, 0xbf, 0xbf, 0xbf }, .value = 0x7fffffff },
        .{ .bytes = &.{0xbf}, .value = null },
        .{ .bytes = &.{0xff}, .value = null },
        .{ .bytes = &.{ 0xc2, 0x40 }, .value = null },
    };
    for (cases) |case| {
        var r = try bits.BitReader.init(case.bytes);
        try testing.expectEqual(case.value, readUtf8(&r));
    }
}

test "STREAMINFO fields" {
    var body: [streaminfo_size]u8 = @splat(0xaa);
    body[0..18].* = .{ 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x12, 0x34, 0x0a, 0xc4, 0x42, 0xf0, 0x00, 0x01, 0x23, 0x45 };
    const info = StreamInfo.parse(&body);
    try testing.expectEqual(4096, info.min_blocksize);
    try testing.expectEqual(4096, info.max_blocksize);
    try testing.expectEqual(14, info.min_framesize);
    try testing.expectEqual(0x1234, info.max_framesize);
    try testing.expectEqual(44100, info.sample_rate);
    try testing.expectEqual(2, info.channels);
    try testing.expectEqual(16, info.bps);
    try testing.expectEqual(0x12345, info.samples);
    try testing.expectEqual(0xaa, info.md5[15]);
}
