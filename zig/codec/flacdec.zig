// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/flacdec.c (flac_decode_frame, decode_frame, decode_subframe,
// decode_residuals, decode_subframe_fixed, decode_subframe_lpc,
// lpc_analyze_remodulate), flacdsp.c (flac_lpc_16_c, flac_lpc_32_c,
// flac_wasted_32_c), flacdsp_template.c (the s16 decorrelations) and
// decode.c (decode_simple_internal's packet remainders) at the pinned
// reference revision describe the behavior, restated here.
//! The FLAC decoder for 16-bit streams (TODO.md T26a), as FFmpeg's decoder
//! decodes them to interleaved s16 with its default options.
//!
//! A packet is decoded as libavcodec feeds an audio decoder: the decoder
//! reads one frame and reports the bytes it used, and what remains of the
//! packet is decoded again, without a timestamp, until it is used up or
//! fails. So a packet with junk after a frame gives the frame and then an
//! error, as FFmpeg's does. A failure drops the rest of the packet; the
//! next packet decodes normally. The CRC-16 is not checked, FFmpeg's
//! default.
//!
//! Arithmetic follows FFmpeg's C: prediction wraps at 32 bits where the C
//! code uses unsigned or 32-bit sums, uses 64-bit sums where it does, and
//! the output keeps the low 16 bits of each sample.

const std = @import("std");
const bits = @import("bits.zig");
const flac = @import("flac.zig");

pub const DecodeError = error{
    /// FFmpeg's decoder refuses the frame (`AVERROR_INVALIDDATA`).
    InvalidData,
    /// A frame the FLAC contract leaves to T26b: a variable block size, or
    /// a channel count or rate other than STREAMINFO's.
    UnsupportedFormat,
};

/// A decoded frame, borrowed until the next call on the decoder.
pub const Frame = struct {
    /// Interleaved s16, `nb_samples * channels` values.
    samples: []const i16,
    nb_samples: u32,
    channels: u8,
    /// The packet's timestamp; null for a packet's remainder.
    pts: ?i64,
};

/// Why a frame failed, FFmpeg's log message for it.
pub const Problem = enum {
    frame_header,
    bps_switch,
    blocksize,
    subframe_padding,
    wasted_bits,
    coding_type,
    residual_method,
    rice_order,
    predictor_order,
    invalid_residual,
    coeff_precision,
    qlevel,
    overread,
    metadata,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    info: flac.StreamInfo,
    /// One buffer of `max_blocksize` samples per channel.
    decoded: [][]i32,
    output: []i16,
    /// What remains of the packet being decoded, borrowed from the caller.
    pending: []const u8 = &.{},
    pending_pts: ?i64 = null,
    /// The last failure's reason, for diagnostics.
    problem: ?Problem = null,
    blocksize: u32 = 0,
    ch_mode: flac.ChannelMode = .independent,

    /// flac_decode_init with STREAMINFO as extradata.
    pub fn init(gpa: std.mem.Allocator, info: flac.StreamInfo) error{ OutOfMemory, UnsupportedFormat }!Decoder {
        if (info.bps != 16 or info.max_blocksize < flac.min_blocksize) return error.UnsupportedFormat;
        const decoded = try gpa.alloc([]i32, info.channels);
        var made: usize = 0;
        errdefer {
            for (decoded[0..made]) |d| gpa.free(d);
            gpa.free(decoded);
        }
        for (decoded) |*d| {
            d.* = try gpa.alloc(i32, info.max_blocksize);
            made += 1;
        }
        const output = try gpa.alloc(i16, @as(usize, info.max_blocksize) * info.channels);
        return .{ .gpa = gpa, .info = info, .decoded = decoded, .output = output };
    }

    pub fn deinit(d: *Decoder) void {
        for (d.decoded) |c| d.gpa.free(c);
        d.gpa.free(d.decoded);
        d.gpa.free(d.output);
        d.* = undefined;
    }

    /// avcodec_send_packet: `data` is borrowed until `receive` returns null
    /// or an error. The previous packet must be used up.
    pub fn send(d: *Decoder, data: []const u8, pts: ?i64) void {
        std.debug.assert(d.pending.len == 0);
        d.pending = data;
        d.pending_pts = pts;
    }

    /// avcodec_receive_frame: the next frame of the packet, null when it is
    /// used up, or the error that ended it.
    pub fn receive(d: *Decoder) DecodeError!?Frame {
        while (d.pending.len > 0) {
            const pts = d.pending_pts;
            const result = d.decodePacket(d.pending) catch |err| {
                d.pending = &.{};
                return err;
            };
            if (result.consumed >= d.pending.len) {
                d.pending = &.{};
            } else {
                d.pending = d.pending[result.consumed..];
                d.pending_pts = null;
            }
            if (result.frame) {
                return .{
                    .samples = d.output[0 .. @as(usize, d.blocksize) * d.info.channels],
                    .nb_samples = d.blocksize,
                    .channels = d.info.channels,
                    .pts = pts,
                };
            }
        }
        return null;
    }

    fn fail(d: *Decoder, problem: Problem) DecodeError {
        d.problem = problem;
        return error.InvalidData;
    }

    const Decoded = struct { consumed: usize, frame: bool };

    /// flac_decode_frame.
    fn decodePacket(d: *Decoder, buf: []const u8) DecodeError!Decoded {
        if (buf.len > 5 and std.mem.eql(u8, buf[0..5], "\x7fFLAC")) return .{ .consumed = buf.len, .frame = false };
        if (buf.len > 0 and buf[0] & 0x7f == 4) return .{ .consumed = buf.len, .frame = false }; // VORBIS_COMMENT
        // Smaller than the smallest decodable frame.
        if (buf.len < flac.min_frame_size) return .{ .consumed = buf.len, .frame = false };
        if (std.mem.readInt(u32, buf[0..4], .big) == std.mem.readInt(u32, "fLaC", .big)) {
            // An inline header after STREAMINFO: skipped by its size.
            return .{ .consumed = try d.metadataSize(buf), .frame = false };
        }
        var r = bits.BitReader.init(buf) catch return d.fail(.overread);
        try d.decodeFrame(&r);
        const bytes_read = r.count() / 8;
        d.decorrelate();
        if (bytes_read > buf.len) return d.fail(.overread);
        return .{ .consumed = bytes_read, .frame = true };
    }

    /// get_metadata_size: the bytes of `fLaC` and its blocks.
    fn metadataSize(d: *Decoder, buf: []const u8) DecodeError!usize {
        var at: usize = 4;
        while (true) {
            if (buf.len - at < 4) return d.fail(.metadata);
            const last = buf[at] & 0x80 != 0;
            const size = std.mem.readInt(u24, buf[at + 1 ..][0..3], .big);
            at += 4;
            if (buf.len - at < size) return d.fail(.metadata);
            at += size;
            if (last) return at;
        }
    }

    /// decode_frame.
    fn decodeFrame(d: *Decoder, r: *bits.BitReader) DecodeError!void {
        const fi = switch (flac.decodeFrameHeader(r)) {
            .ok => |fi| fi,
            .invalid => return d.fail(.frame_header),
        };
        // T26b: FFmpeg follows a change of channels or rate mid-stream, and
        // reads variable block sizes.
        if (fi.channels != d.info.channels or fi.is_var_size) return error.UnsupportedFormat;
        if (fi.sample_rate != 0 and fi.sample_rate != d.info.sample_rate) return error.UnsupportedFormat;
        d.ch_mode = fi.ch_mode;
        if (fi.bps != 0 and fi.bps != d.info.bps) return d.fail(.bps_switch);
        if (fi.blocksize > d.info.max_blocksize) return d.fail(.blocksize);
        d.blocksize = fi.blocksize;
        for (0..d.info.channels) |ch| try d.decodeSubframe(r, ch);
        r.alignByte();
        r.skip(16); // the CRC-16, unchecked
    }

    /// decode_subframe for a channel of at most 32 bits.
    fn decodeSubframe(d: *Decoder, r: *bits.BitReader, channel: usize) DecodeError!void {
        const decoded = d.decoded[channel][0..d.blocksize];
        var bps: u6 = @intCast(d.info.bps);
        if (channel == 0) {
            if (d.ch_mode == .right_side) bps += 1;
        } else {
            if (d.ch_mode == .left_side or d.ch_mode == .mid_side) bps += 1;
        }
        if (r.bit() != 0) return d.fail(.subframe_padding);
        const subframe_type = r.bits(6);
        var wasted: u6 = 0;
        if (r.bit() != 0) {
            const left = r.left();
            if (left <= 0 or
                (left < bps and r.peek(@intCast(left)) == 0) or
                r.peek(bps - 1) == 0) return d.fail(.wasted_bits);
            wasted = @intCast(1 + r.unary(1, r.left()));
            bps -= wasted;
        }
        switch (subframe_type) {
            0 => @memset(decoded, r.signed(bps)),
            1 => for (decoded) |*s| {
                s.* = r.signed(bps);
            },
            8...12 => try d.decodeFixed(r, decoded, @intCast(subframe_type & ~@as(u32, 0x8)), bps),
            32...63 => try d.decodeLpc(r, decoded, @intCast((subframe_type & ~@as(u32, 0x20)) + 1), bps),
            else => return d.fail(.coding_type),
        }
        if (wasted > 0 and wasted < 32) {
            for (decoded) |*s| s.* = @bitCast(@as(u32, @bitCast(s.*)) << @intCast(wasted));
        }
    }

    /// decode_residuals: the residual after `pred_order` warm-up samples.
    fn decodeResiduals(d: *Decoder, r: *bits.BitReader, decoded: []i32, pred_order: u32) DecodeError!void {
        const method_type = r.bits(2);
        const rice_order: u5 = @intCast(r.bits(4));
        const samples = d.blocksize >> rice_order;
        const rice_bits: u6 = @intCast(4 + method_type);
        const rice_esc = (@as(u32, 1) << @intCast(rice_bits)) - 1;
        if (method_type > 1) return d.fail(.residual_method);
        if (samples << rice_order != d.blocksize) return d.fail(.rice_order);
        if (pred_order > samples) return d.fail(.predictor_order);
        var i: u32 = pred_order;
        var at: usize = pred_order;
        for (0..@as(u32, 1) << rice_order) |_| {
            const tmp = r.bits(rice_bits);
            if (tmp == rice_esc) {
                const raw: u6 = @intCast(r.bits(5));
                while (i < samples) : (i += 1) {
                    decoded[at] = r.signed(raw);
                    at += 1;
                }
            } else {
                const k: u5 = @intCast(tmp);
                const max: i32 = std.math.maxInt(i32);
                const real_limit: i32 = if (k > 1) (max >> (k - 1)) + 2 else max;
                while (i < samples) : (i += 1) {
                    const v = r.riceFlac(k, real_limit, 1);
                    if (v == std.math.minInt(i32)) return d.fail(.invalid_residual);
                    decoded[at] = v;
                    at += 1;
                }
            }
            i = 0;
        }
    }

    /// decode_subframe_fixed: unsigned (wrapping) recurrences, as FFmpeg's.
    fn decodeFixed(d: *Decoder, r: *bits.BitReader, decoded: []i32, order: u32, bps: u6) DecodeError!void {
        for (decoded[0..order]) |*s| s.* = r.signed(bps);
        try d.decodeResiduals(r, decoded, order);
        const u = struct {
            fn of(v: i32) u32 {
                return @bitCast(v);
            }
        }.of;
        var a: u32 = 0;
        var b: u32 = 0;
        var c: u32 = 0;
        var e: u32 = 0;
        if (order > 0) a = u(decoded[order - 1]);
        if (order > 1) b = a -% u(decoded[order - 2]);
        if (order > 2) c = b -% u(decoded[order - 2]) +% u(decoded[order - 3]);
        if (order > 3) e = c -% u(decoded[order - 2]) +% 2 *% u(decoded[order - 3]) -% u(decoded[order - 4]);
        for (decoded[order..]) |*s| {
            switch (order) {
                0 => {},
                1 => a +%= u(s.*),
                2 => {
                    b +%= u(s.*);
                    a +%= b;
                },
                3 => {
                    c +%= u(s.*);
                    b +%= c;
                    a +%= b;
                },
                4 => {
                    e +%= u(s.*);
                    c +%= e;
                    b +%= c;
                    a +%= b;
                },
                else => unreachable,
            }
            if (order > 0) s.* = @bitCast(a);
        }
    }

    /// decode_subframe_lpc, without FFmpeg's `use_buggy_lpc` emulation.
    fn decodeLpc(d: *Decoder, r: *bits.BitReader, decoded: []i32, order: u32, bps: u6) DecodeError!void {
        for (decoded[0..order]) |*s| s.* = r.signed(bps);
        const coeff_prec: u6 = @intCast(r.bits(4) + 1);
        if (coeff_prec == 16) return d.fail(.coeff_precision);
        const qlevel_signed = r.signed(5);
        if (qlevel_signed < 0) return d.fail(.qlevel);
        const qlevel: u5 = @intCast(qlevel_signed);
        var coeffs: [32]i32 = undefined;
        for (0..order) |i| coeffs[order - i - 1] = r.signed(coeff_prec);
        try d.decodeResiduals(r, decoded, order);
        const log2_order: u32 = std.math.log2_int(u32, order);
        if (bps <= 16 and bps + coeff_prec + log2_order <= 32) {
            lpc16(decoded, coeffs[0..order], qlevel);
        } else {
            lpc32(decoded, coeffs[0..order], qlevel);
            if (d.info.bps <= 16) lpcAnalyzeRemodulate(decoded, coeffs[0..order], qlevel, bps);
        }
    }

    /// The s16 decorrelations for the frame's channel mode.
    fn decorrelate(d: *Decoder) void {
        const n = d.blocksize;
        const channels = d.info.channels;
        const out = d.output[0 .. @as(usize, n) * channels];
        switch (d.ch_mode) {
            .independent => for (0..n) |i| {
                for (0..channels) |ch| out[i * channels + ch] = @truncate(d.decoded[ch][i]);
            },
            .left_side => for (0..n) |i| {
                const a: u32 = @bitCast(d.decoded[0][i]);
                const b: u32 = @bitCast(d.decoded[1][i]);
                out[2 * i] = @bitCast(@as(u16, @truncate(a)));
                out[2 * i + 1] = @bitCast(@as(u16, @truncate(a -% b)));
            },
            .right_side => for (0..n) |i| {
                const a: u32 = @bitCast(d.decoded[0][i]);
                const b: u32 = @bitCast(d.decoded[1][i]);
                out[2 * i] = @bitCast(@as(u16, @truncate(a +% b)));
                out[2 * i + 1] = @bitCast(@as(u16, @truncate(b)));
            },
            .mid_side => for (0..n) |i| {
                var a: u32 = @bitCast(d.decoded[0][i]);
                const b: i32 = d.decoded[1][i];
                a -%= @bitCast(b >> 1);
                out[2 * i] = @bitCast(@as(u16, @truncate(a +% @as(u32, @bitCast(b)))));
                out[2 * i + 1] = @bitCast(@as(u16, @truncate(a)));
            },
        }
    }
};

/// flac_lpc_16_c: 32-bit wrapping sums. FFmpeg computes two samples at a
/// time; wrapping addition makes the order irrelevant.
fn lpc16(decoded: []i32, coeffs: []const i32, qlevel: u5) void {
    const order = coeffs.len;
    for (order..decoded.len) |i| {
        var sum: u32 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| sum +%= @as(u32, @bitCast(c)) *% @as(u32, @bitCast(s));
        const shifted: i32 = @as(i32, @bitCast(sum)) >> qlevel;
        decoded[i] = decoded[i] +% shifted;
    }
}

/// flac_lpc_32_c: 64-bit sums, the result wrapped to 32 bits.
fn lpc32(decoded: []i32, coeffs: []const i32, qlevel: u5) void {
    const order = coeffs.len;
    for (order..decoded.len) |i| {
        var sum: i64 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| sum +%= @as(i64, c) * s;
        const wide: i64 = @as(i64, decoded[i]) +% (sum >> qlevel);
        decoded[i] = @truncate(wide);
    }
}

/// lpc_analyze_remodulate: when the 64-bit prediction left a sample outside
/// `bps` bits, FFmpeg undoes it and predicts again with 32-bit wrapping, as
/// the encoder that made the stream did.
fn lpcAnalyzeRemodulate(decoded: []i32, coeffs: []const i32, qlevel: u5, bps: u6) void {
    const order = coeffs.len;
    const ebps: u32 = @as(u32, 1) << @intCast(bps - 1);
    var sigma: u32 = 0;
    for (decoded[order..]) |s| sigma |= @as(u32, @bitCast(s)) +% ebps;
    if (sigma < 2 *% ebps) return;
    var i = decoded.len;
    while (i > order) {
        i -= 1;
        var p: i64 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| p +%= @as(i64, c) * s;
        decoded[i] = @bitCast(@as(u32, @bitCast(decoded[i])) -% @as(u32, @truncate(@as(u64, @bitCast(p >> qlevel)))));
    }
    for (order..decoded.len) |at| {
        var p: u32 = 0;
        for (coeffs, decoded[at - order .. at]) |c, s| p +%= @as(u32, @bitCast(c)) *% @as(u32, @bitCast(s));
        const shifted: i32 = @as(i32, @bitCast(p)) >> qlevel;
        decoded[at] = decoded[at] +% shifted;
    }
}

const testing = std.testing;

/// MSB-first bits for hand-made test frames.
const TestBits = struct {
    bytes: [256]u8 = @splat(0),
    count: usize = 0,

    fn put(t: *TestBits, n: u6, value: u64) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            const b: u8 = @intCast((value >> i) & 1);
            t.bytes[t.count / 8] |= b << @intCast(7 - t.count % 8);
            t.count += 1;
        }
    }

    fn signed(t: *TestBits, n: u6, value: i64) void {
        const mask = (@as(u64, 1) << n) - 1;
        t.put(n, @as(u64, @bitCast(value)) & mask);
    }

    /// A mono 16-bit frame header of `blocksize` (8-bit size code) at 44.1
    /// kHz, frame 0, with its CRC-8.
    fn header(t: *TestBits, blocksize: u32, channel_code: u4, bps_code: u3, var_size: bool) void {
        t.put(15, 0x7ffc);
        t.put(1, @intFromBool(var_size));
        t.put(4, 6);
        t.put(4, 9);
        t.put(4, channel_code);
        t.put(3, bps_code);
        t.put(1, 0);
        t.put(8, 0);
        t.put(8, blocksize - 1);
        t.put(8, bits.Crc8.hash(t.bytes[0 .. t.count / 8]));
    }

    /// Pads to a byte, adds the CRC-16, and returns the frame.
    fn finish(t: *TestBits) []const u8 {
        t.put(@intCast((8 - t.count % 8) % 8), 0);
        t.put(16, bits.Crc16.hash(t.bytes[0 .. t.count / 8]));
        return t.bytes[0 .. t.count / 8];
    }
};

const test_info: flac.StreamInfo = .{
    .min_blocksize = 16,
    .max_blocksize = 192,
    .min_framesize = 0,
    .max_framesize = 0,
    .sample_rate = 44100,
    .channels = 1,
    .bps = 16,
    .samples = 0,
    .md5 = @splat(0),
};

fn decodeOne(info: flac.StreamInfo, frame: []const u8) !Decoder.Decoded {
    var d = try Decoder.init(testing.allocator, info);
    defer d.deinit();
    return d.decodePacket(frame);
}

fn expectProblem(problem: Problem, frame: []const u8) !void {
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    try testing.expectError(error.InvalidData, d.decodePacket(frame));
    try testing.expectEqual(problem, d.problem.?);
}

test "a constant frame decodes, and a verbatim one with wasted bits" {
    var t: TestBits = .{};
    t.header(16, 0, 4, false);
    t.put(1, 0);
    t.put(6, 0);
    t.put(1, 0);
    t.signed(16, -1234);
    const frame = t.finish();
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    d.send(frame, 7);
    const got = (try d.receive()).?;
    try testing.expectEqual(16, got.nb_samples);
    try testing.expectEqual(7, got.pts);
    for (got.samples) |s| try testing.expectEqual(-1234, s);
    try testing.expectEqual(null, try d.receive());

    var w: TestBits = .{};
    w.header(16, 0, 4, false);
    w.put(1, 0);
    w.put(6, 1);
    w.put(1, 1);
    w.put(3, 0b001); // three wasted bits: unary 2, then the 1
    for (0..16) |i| w.signed(13, @as(i64, @intCast(i)) - 8);
    const verbatim = w.finish();
    d.send(verbatim, null);
    const v = (try d.receive()).?;
    for (v.samples, 0..) |s, i| try testing.expectEqual((@as(i16, @intCast(i)) - 8) * 8, s);
}

test "two frames in one packet: the second has no timestamp" {
    var t: TestBits = .{};
    t.header(16, 0, 4, false);
    t.put(1, 0);
    t.put(6, 0);
    t.put(1, 0);
    t.signed(16, 5);
    const one = t.finish();
    var both: [64]u8 = undefined;
    @memcpy(both[0..one.len], one);
    @memcpy(both[one.len..][0..one.len], one);
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    d.send(both[0 .. 2 * one.len], 100);
    try testing.expectEqual(100, (try d.receive()).?.pts);
    try testing.expectEqual(null, (try d.receive()).?.pts);
    try testing.expectEqual(null, try d.receive());
}

test "packets the decoder skips" {
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    for ([_][]const u8{ "\x7fFLAC\x01\x00", "\x84abcdefghijkl", "\xff\xf8\x00", "fLaC\x80\x00\x00\x02ab" }) |p| {
        d.send(p, 0);
        try testing.expectEqual(null, try d.receive());
    }
    // An inline header whose blocks run past the packet is refused.
    d.send("fLaC\x80\x00\x00\x09abcdef", 0);
    try testing.expectError(error.InvalidData, d.receive());
    try testing.expectEqual(Problem.metadata, d.problem.?);
}

test "every refusal of a frame" {
    {
        var t: TestBits = .{};
        t.put(16, 0xfff8);
        t.put(48, 0);
        try expectProblem(.frame_header, t.finish());
    }
    {
        // A 12-bit header in a 16-bit stream (padded past the 10 bytes the
        // decoder needs to try a frame).
        var t: TestBits = .{};
        t.header(16, 0, 2, false);
        t.put(16, 0);
        try expectProblem(.bps_switch, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(200, 0, 4, false);
        t.put(16, 0);
        try expectProblem(.blocksize, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 1);
        try expectProblem(.subframe_padding, t.finish());
    }
    {
        // The wasted-bits flag with no 1 bit in reach.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 0);
        t.put(1, 1);
        t.put(24, 0);
        try expectProblem(.wasted_bits, t.finish());
    }
    for ([_]u6{ 2, 7, 13, 31 }) |reserved| {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, reserved);
        t.put(1, 0);
        try expectProblem(.coding_type, t.finish());
    }
    {
        // Fixed order 1: a warm-up sample, then residual method 2.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 9);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(2, 2);
        try expectProblem(.residual_method, t.finish());
    }
    {
        // 24 samples do not split into 16 partitions.
        var t: TestBits = .{};
        t.header(24, 0, 4, false);
        t.put(1, 0);
        t.put(6, 8);
        t.put(1, 0);
        t.put(2, 0);
        t.put(4, 4);
        try expectProblem(.rice_order, t.finish());
    }
    {
        // Order 4 with partitions of 2 samples.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 12);
        t.put(1, 0);
        for (0..4) |_| t.signed(16, 0);
        t.put(2, 0);
        t.put(4, 3);
        try expectProblem(.predictor_order, t.finish());
    }
    {
        // A Rice quotient that runs past the frame.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 8);
        t.put(1, 0);
        t.put(2, 0);
        t.put(4, 0);
        t.put(4, 0);
        t.put(40, 0);
        try expectProblem(.invalid_residual, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 32);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(4, 15);
        try expectProblem(.coeff_precision, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 32);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(4, 11);
        t.signed(5, -1);
        try expectProblem(.qlevel, t.finish());
    }
    {
        // Verbatim samples cut short: the reader runs past the packet.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 1);
        t.put(1, 0);
        for (0..4) |_| t.signed(16, 1);
        const whole = t.finish();
        try expectProblem(.overread, whole[0 .. whole.len - 2]);
    }
}

test "frames left to T26b" {
    {
        // Stereo in a mono stream.
        var t: TestBits = .{};
        t.header(16, 1, 4, false);
        t.put(16, 0);
        try testing.expectError(error.UnsupportedFormat, decodeOne(test_info, t.finish()));
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, true);
        t.put(16, 0);
        try testing.expectError(error.UnsupportedFormat, decodeOne(test_info, t.finish()));
    }
    var info = test_info;
    info.bps = 24;
    try testing.expectError(error.UnsupportedFormat, Decoder.init(testing.allocator, info));
}

test "allocation failures leave nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var info = test_info;
            info.channels = 3;
            var d = try Decoder.init(gpa, info);
            d.deinit();
        }
    }.run, .{});
}

test "LPC prediction: the 32-bit path wraps, the 64-bit path remodulates" {
    // lpc16 with coefficients 2 and -1 and no shift is a second-order
    // fixed predictor.
    var decoded = [_]i32{ 10, 20, 0, 0, 0 };
    lpc16(&decoded, &.{ -1, 2 }, 0);
    try testing.expectEqualSlices(i32, &.{ 10, 20, 30, 40, 50 }, &decoded);
    // Within `bps` bits the remodulation leaves the 64-bit result alone.
    var wide = [_]i32{ 100, -100, 7, 7 };
    lpc32(&wide, &.{ 1, 1 }, 1);
    const before = wide;
    lpcAnalyzeRemodulate(&wide, &.{ 1, 1 }, 1, 17);
    try testing.expectEqualSlices(i32, &before, &wide);
    // Outside them, the samples are predicted again with 32-bit wrapping,
    // which differs once the sums overflow.
    var big = [_]i32{ 0x7fff_0000, 0x7fff_0000, 0, 0 };
    var big32 = big;
    lpc32(&big, &.{ 1, 1 }, 0);
    lpc16(&big32, &.{ 1, 1 }, 0);
    lpcAnalyzeRemodulate(&big, &.{ 1, 1 }, 0, 17);
    try testing.expectEqualSlices(i32, &big32, &big);
}
